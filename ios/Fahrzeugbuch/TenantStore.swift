import Foundation
import Observation

/// Lokaler Datenbestand eines Mandanten (offline-fähig) inkl. Outbox und Sync.
///
/// - Jede Änderung wird sofort lokal übernommen und als `PendingOp` in die Outbox gestellt.
/// - `sync()` sendet die Outbox (Push) und holt danach Änderungen seit `cursor` (Pull).
/// - Objekte mit ausstehenden Änderungen werden beim Pull nicht überschrieben.
@MainActor
@Observable
final class TenantStore {
    let tenant: TenantInfo
    @ObservationIgnored private let apiProvider: @MainActor () -> APIClient
    @ObservationIgnored private let fileURL: URL

    private(set) var vehicles: [String: Vehicle] = [:]
    private(set) var odometer: [String: OdometerReading] = [:]
    private(set) var fuel: [String: FuelEntry] = [:]
    private(set) var maintenance: [String: Maintenance] = [:]
    private(set) var items: [String: MaintenanceItem] = [:]
    private(set) var materials: [String: MaintenanceMaterial] = [:]
    /// Materialstamm (mandantenweit)
    private(set) var articles: [String: MaterialArticle] = [:]
    /// Fahrtenbuch
    private(set) var trips: [String: Trip] = [:]
    private(set) var places: [String: Place] = [:]
    private(set) var customers: [String: Customer] = [:]
    private(set) var rules: [String: PurposeRule] = [:]
    private(set) var taxParams: [String: TaxParam] = [:]
    /// Monatsabschlüsse (nur vom Server, nie in der Outbox)
    private(set) var periods: [String: TripPeriod] = [:]
    private(set) var outbox: [PendingOp] = []
    private(set) var cursor = 0
    private(set) var lastSync: Date?

    private(set) var isSyncing = false
    private(set) var syncError: String?
    /// Hinweise aus dem letzten Sync (Konflikte, abgelehnte Änderungen)
    var notices: [String] = []

    @ObservationIgnored private var rerunRequested = false

    var canWrite: Bool { tenant.canWrite }

    init(tenant: TenantInfo, api: @escaping @MainActor () -> APIClient) {
        self.tenant = tenant
        self.apiProvider = api
        self.fileURL = Self.fileURL(for: tenant.slug)
        load()
    }

    // MARK: Lesen

    var vehicleList: [Vehicle] {
        vehicles.values.filter { !$0.deleted }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func fuel(for vehicleId: String) -> [FuelEntry] {
        fuel.values.filter { $0.vehicleId == vehicleId && !$0.deleted }
            .sorted { ($0.km, $0.date) > ($1.km, $1.date) }
    }

    func odometer(for vehicleId: String) -> [OdometerReading] {
        odometer.values.filter { $0.vehicleId == vehicleId && !$0.deleted }
            .sorted { ($0.date, $0.km) > ($1.date, $1.km) }
    }

    func maintenance(for vehicleId: String) -> [Maintenance] {
        maintenance.values.filter { $0.vehicleId == vehicleId && !$0.deleted }
            .sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }

    func items(for maintenanceId: String) -> [MaintenanceItem] {
        items.values.filter { $0.maintenanceId == maintenanceId && !$0.deleted }
            .sorted { ($0.position, $0.label) < ($1.position, $1.label) }
    }

    func materials(for maintenanceId: String) -> [MaintenanceMaterial] {
        materials.values.filter { $0.maintenanceId == maintenanceId && !$0.deleted }
            .sorted { ($0.position, $0.name) < ($1.position, $1.name) }
    }

    /// Σ Menge × Einzelpreis (nicht stornierte Positionen mit Preis)
    func materialTotal(for maintenanceId: String) -> Double {
        MaintenanceMaterial.total(materials(for: maintenanceId))
    }

    func maintenance(id: String) -> Maintenance? { maintenance[id] }
    func article(id: String) -> MaterialArticle? { articles[id] }

    /// Nicht stornierte Stammartikel, die für das Fahrzeug gelten (Artikel ohne Fahrzeug gelten für alle).
    /// `vehicleId == nil` liefert den ganzen Stamm. Sortiert nach Kategorie, Name.
    func articles(for vehicleId: String?) -> [MaterialArticle] {
        articles.values.filter { a in
            if a.deleted { return false }
            guard let wanted = vehicleId, let own = a.vehicleId else { return true }
            return own == wanted
        }
        .sorted(by: MaterialArticle.catalogOrder)
    }

    /// Verwendung je Stammartikel: nicht stornierte Positionen nicht stornierter Wartungen.
    func articleUsage() -> [String: ArticleUsage] {
        var result: [String: ArticleUsage] = [:]
        for m in materials.values where !m.deleted {
            guard let articleId = m.articleId, let parent = maintenance[m.maintenanceId], !parent.deleted else { continue }
            var usage = result[articleId] ?? ArticleUsage()
            usage.count += 1
            if let last = usage.lastUsed {
                if parent.date > last { usage.lastUsed = parent.date }
            } else {
                usage.lastUsed = parent.date
            }
            result[articleId] = usage
        }
        return result
    }

    /// Häufig verwendete Artikel (Anzahl, dann zuletzt verwendet) für die Materialauswahl.
    func frequentArticles(for vehicleId: String?, limit: Int = 5) -> [MaterialArticle] {
        let usage = articleUsage()
        let used = articles(for: vehicleId).filter { (usage[$0.id]?.count ?? 0) > 0 }
        let sorted = used.sorted { a, b in
            let ua = usage[a.id] ?? ArticleUsage()
            let ub = usage[b.id] ?? ArticleUsage()
            if ua.count != ub.count { return ua.count > ub.count }
            let da = ua.lastUsed ?? Date.distantPast
            let db = ub.lastUsed ?? Date.distantPast
            if da != db { return da > db }
            return MaterialArticle.catalogOrder(a, b)
        }
        return Array(sorted.prefix(limit))
    }

    /// Kategorie-Vorschläge: Standardkategorien, danach weitere bereits verwendete.
    var articleCategories: [String] {
        var seen = Set<String>()
        var result: [String] = []
        let used = articles.values.filter { !$0.deleted }.compactMap { $0.category?.nilIfEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for c in MaterialArticle.defaultCategories + used {
            let key = c.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            result.append(c)
        }
        return result
    }
    func vehicle(id: String) -> Vehicle? { vehicles[id] }

    // MARK: Fahrtenbuch – Lesen

    /// Chronologisch (Start aufsteigend, bei Gleichstand id).
    static func chronological(_ a: Trip, _ b: Trip) -> Bool {
        let da = a.startDate ?? Date.distantPast
        let db = b.startDate ?? Date.distantPast
        if da != db { return da < db }
        return a.id < b.id
    }

    /// Nicht stornierte Fahrten des Fahrzeugs, neueste zuerst.
    func trips(for vehicleId: String) -> [Trip] {
        trips.values.filter { $0.vehicleId == vehicleId && !$0.deleted }
            .sorted { Self.chronological($1, $0) }
    }

    /// Nicht stornierte Fahrten eines Monats ("YYYY-MM"), chronologisch.
    func trips(for vehicleId: String, month: String) -> [Trip] {
        trips.values.filter { $0.vehicleId == vehicleId && !$0.deleted && $0.monthKey == month }
            .sorted(by: Self.chronological)
    }

    /// Zu bestätigende Fahrten (Entwurf/vorgeschlagen/ohne Kategorie, nicht gesperrt), älteste zuerst.
    func reviewTrips(for vehicleId: String) -> [Trip] {
        trips.values.filter { $0.vehicleId == vehicleId && !$0.deleted && $0.needsReview }
            .sorted(by: Self.chronological)
    }

    func trip(id: String) -> Trip? { trips[id] }

    /// Höchster bekannter km-Stand: Tank/Odometer/Wartung sowie km-Ende der Fahrten.
    func lastKnownKm(for vehicleId: String) -> Int {
        let base = vehicles[vehicleId].map { currentKm($0) } ?? 0
        let tripMax = trips.values
            .filter { $0.vehicleId == vehicleId && !$0.deleted }
            .compactMap { $0.kmEnd ?? $0.kmStart }
            .max() ?? 0
        return max(base, tripMax)
    }

    /// Lokale Lückenerkennung über die km-Kette (km-Ende Fahrt n ≠ km-Beginn Fahrt n+1).
    /// `month` filtert auf Lücken vor Fahrten dieses Monats (Kette inkl. letzter Fahrt des Vormonats).
    func gaps(for vehicleId: String, month: String?) -> [TripGap] {
        let chain = trips.values.filter { $0.vehicleId == vehicleId && !$0.deleted }
            .sorted(by: Self.chronological)
        var result: [TripGap] = []
        for (a, b) in zip(chain, chain.dropFirst()) {
            guard let from = a.kmEnd, let to = b.kmStart, from != to else { continue }
            if let month, b.monthKey != month { continue }
            result.append(TripGap(afterTripId: a.id, beforeTripId: b.id, kmFrom: from, kmTo: to))
        }
        return result
    }

    /// Nicht stornierte Orte, nach Art (Wohnort, Arbeit, Kunde, andere) und Name.
    var placeList: [Place] {
        let order = Dictionary(uniqueKeysWithValues: PlaceKind.allCases.enumerated().map { ($0.element.rawValue, $0.offset) })
        return places.values.filter { !$0.deleted }.sorted { a, b in
            let ka = order[a.kind] ?? 99
            let kb = order[b.kind] ?? 99
            if ka != kb { return ka < kb }
            let n = a.name.localizedStandardCompare(b.name)
            if n != .orderedSame { return n == .orderedAscending }
            return a.id < b.id
        }
    }

    func place(id: String) -> Place? { places[id] }

    var customerList: [Customer] {
        customers.values.filter { !$0.deleted }.sorted { a, b in
            let n = a.name.localizedStandardCompare(b.name)
            if n != .orderedSame { return n == .orderedAscending }
            return a.id < b.id
        }
    }

    func customer(id: String) -> Customer? { customers[id] }

    /// Alle nicht stornierten Regeln (auch inaktive), nach Priorität.
    var allRules: [PurposeRule] {
        rules.values.filter { !$0.deleted }.sorted { ($0.priority, $0.id) < ($1.priority, $1.id) }
    }

    /// Aktive, nicht stornierte Regeln nach Priorität (kleiner = zuerst).
    var ruleList: [PurposeRule] { allRules.filter(\.active) }

    var taxParamList: [TaxParam] {
        taxParams.values.filter { !$0.deleted }.sorted { a, b in
            if a.year != b.year { return a.year > b.year }
            if a.scope != b.scope { return a.scope < b.scope }
            let ia = TaxParam.keys.firstIndex(of: a.key) ?? 99
            let ib = TaxParam.keys.firstIndex(of: b.key) ?? 99
            if ia != ib { return ia < ib }
            return a.id < b.id
        }
    }

    /// Monatsabschlüsse des Fahrzeugs, neueste zuerst.
    func periods(for vehicleId: String) -> [TripPeriod] {
        periods.values.filter { $0.vehicleId == vehicleId && !$0.deleted }
            .sorted { ($0.month, $0.id) > ($1.month, $1.id) }
    }

    func period(vehicleId: String, month: String) -> TripPeriod? {
        periods.values.first { $0.vehicleId == vehicleId && $0.month == month && $0.isClosed }
    }

    func isMonthClosed(vehicleId: String, month: String) -> Bool {
        period(vehicleId: vehicleId, month: month) != nil
    }

    /// Zuletzt gewähltes Fahrzeug je Mandant (für Start/Automatik); sonst erstes Fahrzeug.
    var defaultVehicleId: String? {
        get {
            if let id = UserDefaults.standard.string(forKey: defaultVehicleKey),
               let v = vehicles[id], !v.deleted {
                return id
            }
            return vehicleList.first?.id
        }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultVehicleKey)
        }
    }

    private var defaultVehicleKey: String { "defaultVehicle-\(tenant.slug)" }

    /// Anzeigename eines Orts: benannter Ort, sonst gespeicherte Bezeichnung.
    func placeName(id: String?, label: String?) -> String? {
        if let id, let p = places[id] { return p.name }
        return label?.nilIfEmpty
    }

    func startText(_ t: Trip) -> String {
        if t.privateMode { return "Privat" }
        return placeName(id: t.startPlaceId, label: t.startLabel) ?? "Start unbekannt"
    }

    func endText(_ t: Trip) -> String {
        if t.privateMode { return "Privat" }
        return placeName(id: t.endPlaceId, label: t.endLabel) ?? "Ziel unbekannt"
    }

    /// "Wohnort → Büro" bzw. "Privatfahrt" im Privatmodus.
    func routeText(_ t: Trip) -> String {
        if t.privateMode { return "Privatfahrt" }
        let a = placeName(id: t.startPlaceId, label: t.startLabel) ?? "?"
        let b = placeName(id: t.endPlaceId, label: t.endLabel) ?? "?"
        return "\(a) → \(b)"
    }

    /// Bedingungen einer Regel als Text: "Wohnort → Büro · Mo–Fr · 06:00–09:30".
    func ruleConditionText(_ r: PurposeRule) -> String {
        var parts: [String] = []
        let from = r.fromPlaceId.map { placeName(id: $0, label: nil) ?? "Unbekannter Ort" } ?? "überall"
        let to = r.toPlaceId.map { placeName(id: $0, label: nil) ?? "Unbekannter Ort" } ?? "überall"
        if r.fromPlaceId != nil || r.toPlaceId != nil { parts.append("\(from) → \(to)") }
        parts.append(PurposeRule.weekdayText(r.weekdaySet))
        if r.timeFrom != nil || r.timeTo != nil {
            parts.append("\(r.timeFrom ?? "00:00")–\(r.timeTo ?? "23:59")")
        }
        if let vid = r.vehicleId { parts.append(vehicles[vid]?.name ?? "Unbekanntes Fahrzeug") }
        return parts.joined(separator: " · ")
    }

    /// Ergebnis einer Regel als Text: "Geschäftlich · Kundentermin · Meier AG".
    func ruleResultText(_ r: PurposeRule) -> String {
        var parts = [TripCategory.of(r.resultCategory).label]
        if let p = r.resultPurpose?.nilIfEmpty { parts.append(p) }
        if let c = r.resultCustomerId { parts.append(customers[c]?.name ?? "Unbekannter Kunde") }
        return parts.joined(separator: " · ")
    }

    /// Gleiche Bedingungen + Ergebniskategorie (zur Vermeidung doppelter Regelvorschläge).
    static func ruleSignature(_ r: PurposeRule) -> String {
        [r.fromPlaceId ?? "-", r.toPlaceId ?? "-", PurposeRule.weekdayString(r.weekdaySet) ?? "-",
         r.timeFrom ?? "-", r.timeTo ?? "-", r.vehicleId ?? "-", r.resultCategory].joined(separator: "|")
    }

    func hasSimilarRule(_ r: PurposeRule) -> Bool {
        let sig = Self.ruleSignature(r)
        return allRules.contains { $0.id == r.id || Self.ruleSignature($0) == sig }
    }

    /// Anzahl nicht stornierter Fahrten je Kunde (für Listen).
    func tripCount(customerId: String) -> Int {
        trips.values.filter { !$0.deleted && $0.customerId == customerId }.count
    }

    func stats(for v: Vehicle) -> VehicleStats {
        let list = maintenance(for: v.id)
        let ids = Set(list.map(\.id))
        let mats = materials.values.filter { !$0.deleted && ids.contains($0.maintenanceId) }
        return StatsCalculator.stats(vehicle: v, odometer: odometer(for: v.id), fuel: fuel(for: v.id),
                                     maintenance: list, materials: mats)
    }

    func currentKm(_ v: Vehicle) -> Int {
        StatsCalculator.currentKm(vehicle: v, odometer: odometer(for: v.id), fuel: fuel(for: v.id),
                                  maintenance: maintenance(for: v.id))
    }

    func isPending(_ id: String) -> Bool { outbox.contains { $0.entityId == id } }

    /// Fälligkeiten aller Fahrzeuge (für Benachrichtigungen)
    var dueItems: [(vehicle: Vehicle, item: DueItem)] {
        vehicleList.flatMap { v in stats(for: v).due.map { (vehicle: v, item: $0) } }
    }

    /// Ändert sich, sobald sich Fälligkeiten ändern → Benachrichtigungen neu planen
    var dueSignature: String {
        dueItems.map { "\($0.item.id)|\($0.item.nextDueDate?.timeIntervalSince1970 ?? 0)|\($0.item.overdue)" }
            .joined(separator: ",")
    }

    // MARK: Schreiben (offline)

    func save(_ v: Vehicle) { upsert(v, in: \.vehicles) }
    func delete(_ v: Vehicle) { remove(v, in: \.vehicles) }
    func save(_ o: OdometerReading) { upsert(o, in: \.odometer) }
    func delete(_ o: OdometerReading) { remove(o, in: \.odometer) }
    func save(_ f: FuelEntry) { upsert(f, in: \.fuel) }
    func delete(_ f: FuelEntry) { remove(f, in: \.fuel) }
    func delete(_ m: Maintenance) { remove(m, in: \.maintenance) }
    func save(_ a: MaterialArticle) { upsert(a, in: \.articles) }
    func delete(_ a: MaterialArticle) { remove(a, in: \.articles) }
    func save(_ p: Place) { upsert(p, in: \.places) }
    func delete(_ p: Place) { remove(p, in: \.places) }
    func save(_ c: Customer) { upsert(c, in: \.customers) }
    func delete(_ c: Customer) { remove(c, in: \.customers) }
    func save(_ r: PurposeRule) { upsert(r, in: \.rules) }
    func delete(_ r: PurposeRule) { remove(r, in: \.rules) }
    func save(_ p: TaxParam) { upsert(p, in: \.taxParams) }
    func delete(_ p: TaxParam) { remove(p, in: \.taxParams) }

    /// Fahrt speichern. Gesperrte Fahrten (abgeschlossener Monat) sind unveränderlich – nur Storno.
    func save(_ t: Trip) {
        if let existing = trips[t.id], existing.isLocked {
            notices.append("Die Fahrt gehört zu einem abgeschlossenen Monat und kann nicht geändert werden. "
                           + "Stornieren und mit Korrekturbegründung neu erfassen.")
            return
        }
        var e = t
        if e.status == "locked" { e.status = "confirmed" }   // „locked“ setzt nur der Server
        upsert(e, in: \.trips)
    }

    /// Storno ist auch bei gesperrten Fahrten erlaubt (wird protokolliert).
    func delete(_ t: Trip) { remove(t, in: \.trips) }

    /// Fahrt bestätigen (Kategorie setzen). `purpose`/`customerId` = nil → unverändert.
    func confirm(_ trip: Trip, as category: TripCategory, purpose: String? = nil, customerId: String? = nil) {
        var t = trips[trip.id] ?? trip
        guard !t.isLocked, category != .unknown else { return }
        t.category = category.rawValue
        t.status = "confirmed"
        if let purpose { t.purpose = purpose.nilIfEmpty }
        if category == .personal {
            t.customerId = nil
        } else if let customerId {
            t.customerId = customerId
        }
        save(t)
    }

    /// Monatsabschluss aus der Server-Antwort übernehmen (POST …/close).
    func storePeriod(_ p: TripPeriod) {
        for (key, old) in periods where old.vehicleId == p.vehicleId && old.month == p.month && key != p.id {
            periods.removeValue(forKey: key)
        }
        periods[p.id] = p
        persist()
    }

    /// Wartung inkl. Checkliste und Material speichern; entfernte Punkte/Positionen werden storniert,
    /// unveränderte nicht erneut gesendet.
    func save(_ m: Maintenance, items newItems: [MaintenanceItem], materials newMaterials: [MaintenanceMaterial]) {
        upsert(m, in: \.maintenance)
        let keep = Set(newItems.map(\.id))
        for old in items(for: m.id) where !keep.contains(old.id) {
            remove(old, in: \.items)
        }
        for (n, var item) in newItems.enumerated() {
            item.position = n
            item.maintenanceId = m.id
            if let existing = items[item.id], !existing.deleted,
               existing.label == item.label, existing.done == item.done, existing.position == item.position {
                continue // unverändert → keine Revision
            }
            upsert(item, in: \.items)
        }
        let keepMaterials = Set(newMaterials.map(\.id))
        for old in materials(for: m.id) where !keepMaterials.contains(old.id) {
            remove(old, in: \.materials)
        }
        for (n, var material) in newMaterials.enumerated() {
            material.position = n
            material.maintenanceId = m.id
            if let existing = materials[material.id], !existing.deleted {
                var compare = material
                compare.version = existing.version
                compare.deleted = existing.deleted
                if compare == existing { continue } // unverändert → keine Revision
            }
            upsert(material, in: \.materials)
        }
    }

    func toggle(_ item: MaintenanceItem) {
        guard var current = items[item.id] else { return }
        current.done.toggle()
        upsert(current, in: \.items)
    }

    private func upsert<T: SyncEntity>(_ entity: T, in kp: ReferenceWritableKeyPath<TenantStore, [String: T]>) {
        guard canWrite else { return }
        var e = entity
        let existing = self[keyPath: kp][e.id]
        let base = existing.map(\.version)         // nil → neu
        e.version = (base ?? 0) + 1                 // optimistisch, Server bestätigt
        e.deleted = false
        self[keyPath: kp][e.id] = e
        enqueue(PendingOp(entity: T.entityName, entityId: e.id, action: "upsert",
                          baseVersion: base, data: try? e.payload(), clientTs: Self.now()))
    }

    private func remove<T: SyncEntity>(_ entity: T, in kp: ReferenceWritableKeyPath<TenantStore, [String: T]>) {
        guard canWrite, var e = self[keyPath: kp][entity.id], !e.deleted else { return }
        let base = e.version
        e.deleted = true
        e.version += 1
        self[keyPath: kp][e.id] = e
        enqueue(PendingOp(entity: T.entityName, entityId: e.id, action: "delete",
                          baseVersion: base, data: nil, clientTs: Self.now()))
    }

    private func enqueue(_ op: PendingOp) {
        outbox.append(op)
        persist()
        Task { await sync() }
    }

    // MARK: Sync

    func sync() async {
        #if DEBUG
        if Demo.isActive { return }
        #endif
        if isSyncing { rerunRequested = true; return }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            rerunRequested = false
            do {
                let needsFullPull = try await push()
                try await pull(full: needsFullPull)
                syncError = nil
                lastSync = Date()
                persist()
            } catch {
                syncError = Self.describe(error)
                return
            }
        } while rerunRequested
    }

    /// Sendet die Outbox. Rückgabe `true`, wenn Ops abgelehnt wurden (→ vollständiger Abgleich nötig).
    private func push() async throws -> Bool {
        var rejected = false
        while !outbox.isEmpty {
            let batch = Array(outbox.prefix(200))
            let ops: [[String: Any]] = batch.map { op in
                var d: [String: Any] = [
                    "op_id": op.opId, "entity": op.entity, "id": op.entityId,
                    "action": op.action, "client_ts": op.clientTs,
                ]
                d["base_version"] = op.baseVersion ?? NSNull()
                if let data = op.data, let obj = try? JSONSerialization.jsonObject(with: data) {
                    d["data"] = obj
                }
                return d
            }
            let body = try JSONSerialization.data(withJSONObject: ["ops": ops])
            let response: SyncResponse = try await apiProvider().send(
                "POST", "api/t/\(tenant.slug)/sync", body: body)

            let done = Set(response.results.map(\.opId))
            outbox.removeAll { done.contains($0.opId) }
            for r in response.results {
                switch r.status {
                case "conflict":
                    notices.append("Konflikt bei \(Self.entityLabel(r.entity)): deine Version wurde übernommen, "
                                   + "die vorherige bleibt im Verlauf.")
                case "rejected":
                    rejected = true
                    notices.append("\(Self.entityLabel(r.entity)) abgelehnt: \(r.error ?? "unbekannt")")
                default:
                    break
                }
                if let v = r.version { setVersion(r.entity, r.id, v) }
            }
            persist()
            if done.isEmpty { break } // Schutz vor Endlosschleife
        }
        return rejected
    }

    private func pull(full: Bool) async throws {
        let since = full ? 0 : cursor
        let previousPlaces = places   // Wohnort-Koordinaten bleiben lokal
        let ch: ChangesResponse = try await apiProvider().get(
            "api/t/\(tenant.slug)/changes", query: [URLQueryItem(name: "since", value: String(since))])
        if full {
            vehicles = vehicles.filter { isPending($0.key) }
            odometer = odometer.filter { isPending($0.key) }
            fuel = fuel.filter { isPending($0.key) }
            maintenance = maintenance.filter { isPending($0.key) }
            items = items.filter { isPending($0.key) }
            materials = materials.filter { isPending($0.key) }
            articles = articles.filter { isPending($0.key) }
            trips = trips.filter { isPending($0.key) }
            places = places.filter { isPending($0.key) }
            customers = customers.filter { isPending($0.key) }
            rules = rules.filter { isPending($0.key) }
            taxParams = taxParams.filter { isPending($0.key) }
            if ch.tripPeriods != nil { periods = [:] }
        }
        merge(ch.vehicles, into: \.vehicles)
        merge(ch.odometer, into: \.odometer)
        merge(ch.fuel, into: \.fuel)
        merge(ch.maintenance, into: \.maintenance)
        merge(ch.maintenanceItems, into: \.items)
        merge(ch.maintenanceMaterials, into: \.materials)
        merge(ch.materialArticles ?? [], into: \.articles)
        merge(ch.customers ?? [], into: \.customers)
        mergePlaces(ch.places ?? [], previous: previousPlaces)
        merge(ch.trips ?? [], into: \.trips)
        merge(ch.purposeRules ?? [], into: \.rules)
        merge(ch.taxParams ?? [], into: \.taxParams)
        for p in ch.tripPeriods ?? [] {
            for (key, old) in periods where old.vehicleId == p.vehicleId && old.month == p.month && key != p.id {
                periods.removeValue(forKey: key)
            }
            periods[p.id] = p
        }
        cursor = ch.cursor
    }

    private func merge<T: SyncEntity>(_ list: [T], into kp: ReferenceWritableKeyPath<TenantStore, [String: T]>) {
        guard !list.isEmpty else { return }
        var dict = self[keyPath: kp]
        for e in list where !isPending(e.id) { dict[e.id] = e }
        self[keyPath: kp] = dict
    }

    /// Orte übernehmen; ohne Koordinaten vom Server (Wohnort: App sendet sie nie) → lokale behalten.
    private func mergePlaces(_ list: [Place], previous: [String: Place]) {
        guard !list.isEmpty else { return }
        var dict = places
        for var p in list where !isPending(p.id) {
            if p.lat == nil, p.lon == nil, let old = previous[p.id], old.hasCoordinate {
                p.lat = old.lat
                p.lon = old.lon
            }
            dict[p.id] = p
        }
        places = dict
    }

    private func setVersion(_ entity: String, _ id: String, _ v: Int) {
        guard !isPending(id) else { return }
        switch entity {
        case Vehicle.entityName: vehicles[id]?.version = v
        case OdometerReading.entityName: odometer[id]?.version = v
        case FuelEntry.entityName: fuel[id]?.version = v
        case Maintenance.entityName: maintenance[id]?.version = v
        case MaintenanceItem.entityName: items[id]?.version = v
        case MaintenanceMaterial.entityName: materials[id]?.version = v
        case MaterialArticle.entityName: articles[id]?.version = v
        case Trip.entityName: trips[id]?.version = v
        case Place.entityName: places[id]?.version = v
        case Customer.entityName: customers[id]?.version = v
        case PurposeRule.entityName: rules[id]?.version = v
        case TaxParam.entityName: taxParams[id]?.version = v
        default: break
        }
    }

    #if DEBUG
    func demoSeed(vehicles v: [Vehicle], odometer o: [OdometerReading], fuel f: [FuelEntry],
                  maintenance m: [Maintenance], items i: [MaintenanceItem], materials mat: [MaintenanceMaterial],
                  articles art: [MaterialArticle] = [], pending: [FuelEntry]) {
        vehicles = Dictionary(uniqueKeysWithValues: v.map { ($0.id, $0) })
        odometer = Dictionary(uniqueKeysWithValues: o.map { ($0.id, $0) })
        fuel = Dictionary(uniqueKeysWithValues: f.map { ($0.id, $0) })
        maintenance = Dictionary(uniqueKeysWithValues: m.map { ($0.id, $0) })
        items = Dictionary(uniqueKeysWithValues: i.map { ($0.id, $0) })
        materials = Dictionary(uniqueKeysWithValues: mat.map { ($0.id, $0) })
        articles = Dictionary(uniqueKeysWithValues: art.map { ($0.id, $0) })
        outbox = pending.map { PendingOp(entity: FuelEntry.entityName, entityId: $0.id, action: "upsert",
                                         baseVersion: nil, data: nil, clientTs: "") }
        lastSync = Date().addingTimeInterval(-600)
    }

    func demoSeedTrips(trips t: [Trip], places p: [Place], customers c: [Customer], rules r: [PurposeRule],
                       taxParams tp: [TaxParam], periods pe: [TripPeriod]) {
        trips = Dictionary(uniqueKeysWithValues: t.map { ($0.id, $0) })
        places = Dictionary(uniqueKeysWithValues: p.map { ($0.id, $0) })
        customers = Dictionary(uniqueKeysWithValues: c.map { ($0.id, $0) })
        rules = Dictionary(uniqueKeysWithValues: r.map { ($0.id, $0) })
        taxParams = Dictionary(uniqueKeysWithValues: tp.map { ($0.id, $0) })
        periods = Dictionary(uniqueKeysWithValues: pe.map { ($0.id, $0) })
    }
    #endif

    // MARK: Persistenz

    private struct Snapshot: Codable {
        var vehicles: [String: Vehicle]
        var odometer: [String: OdometerReading]
        var fuel: [String: FuelEntry]
        var maintenance: [String: Maintenance]
        var items: [String: MaintenanceItem]
        /// Optional, damit Dateien älterer App-Versionen (ohne Material) weiter laden
        var materials: [String: MaintenanceMaterial]?
        /// Optional, damit Dateien älterer App-Versionen (ohne Materialstamm) weiter laden
        var articles: [String: MaterialArticle]?
        /// Fahrtenbuch – optional, damit Dateien älterer App-Versionen weiter laden
        var trips: [String: Trip]?
        var places: [String: Place]?
        var customers: [String: Customer]?
        var rules: [String: PurposeRule]?
        var taxParams: [String: TaxParam]?
        var periods: [String: TripPeriod]?
        var outbox: [PendingOp]
        var cursor: Int
        var lastSync: Date?
    }

    private static let fileEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .formatted(APIClient.dayFormatter)
        return e
    }()

    private static let fileDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .formatted(APIClient.dayFormatter)
        return d
    }()

    private func persist() {
        let snap = Snapshot(vehicles: vehicles, odometer: odometer, fuel: fuel, maintenance: maintenance,
                            items: items, materials: materials, articles: articles,
                            trips: trips, places: places, customers: customers, rules: rules,
                            taxParams: taxParams, periods: periods,
                            outbox: outbox, cursor: cursor, lastSync: lastSync)
        do {
            let data = try Self.fileEncoder.encode(snap)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            syncError = "Lokales Speichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let snap = try? Self.fileDecoder.decode(Snapshot.self, from: data) else { return }
        vehicles = snap.vehicles
        odometer = snap.odometer
        fuel = snap.fuel
        maintenance = snap.maintenance
        items = snap.items
        materials = snap.materials ?? [:]
        articles = snap.articles ?? [:]
        trips = snap.trips ?? [:]
        places = snap.places ?? [:]
        customers = snap.customers ?? [:]
        rules = snap.rules ?? [:]
        taxParams = snap.taxParams ?? [:]
        periods = snap.periods ?? [:]
        outbox = snap.outbox
        // Datei ohne Material, Materialstamm bzw. Fahrtenbuch (ältere App-Version): ab 0 holen,
        // damit bereits erfasste Positionen/Artikel/Fahrten ankommen
        cursor = (snap.materials == nil || snap.articles == nil || snap.trips == nil) ? 0 : snap.cursor
        lastSync = snap.lastSync
    }

    static func directory() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Mandanten", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fileURL(for slug: String) -> URL {
        directory().appending(path: "\(slug).json")
    }

    /// Löscht alle lokalen Mandantendaten (Abmelden / Serverwechsel).
    static func deleteAll() {
        try? FileManager.default.removeItem(at: directory())
    }

    /// Anzahl unsynchronisierter Änderungen über alle Mandanten (für Warnung beim Abmelden).
    static func pendingCountOnDisk() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory(), includingPropertiesForKeys: nil)) ?? []
        return files.reduce(0) { sum, url in
            guard let data = try? Data(contentsOf: url),
                  let snap = try? fileDecoder.decode(Snapshot.self, from: data) else { return sum }
            return sum + snap.outbox.count
        }
    }

    // MARK: Hilfen

    private static func now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    static func entityLabel(_ entity: String) -> String {
        switch entity {
        case Vehicle.entityName: "Fahrzeug"
        case OdometerReading.entityName: "Kilometerstand"
        case FuelEntry.entityName: "Tankvorgang"
        case Maintenance.entityName: "Wartung"
        case MaintenanceItem.entityName: "Checkpunkt"
        case MaintenanceMaterial.entityName: "Material"
        case MaterialArticle.entityName: "Materialstamm"
        case Trip.entityName: "Fahrt"
        case Place.entityName: "Ort"
        case Customer.entityName: "Kunde"
        case PurposeRule.entityName: "Zweckregel"
        case TaxParam.entityName: "Steuerparameter"
        case "trip_period": "Monatsabschluss"
        default: entity
        }
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed:
                return "Offline – Änderungen werden später übertragen."
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
