import Foundation
import Observation

/// Lokaler Datenbestand eines Mandanten (offline-fähig) inkl. Outbox und Sync.
///
/// - Jede Änderung wird sofort lokal übernommen und als `PendingOp` in die Outbox gestellt.
/// - `sync()` sendet die Outbox (Push) und holt danach Änderungen seit `cursor` (Pull, seitenweise).
/// - Objekte mit ausstehenden Änderungen werden beim Pull nicht überschrieben.
/// - Abgelehnte Änderungen bleiben in `rejectedOps` sichtbar (mit lokaler Kopie zum Bearbeiten/erneut Senden).
/// - Persistenz gebündelt (~300 ms), Kodieren/Schreiben ausserhalb des Main-Actors; `flush()` schreibt sofort.
///
/// Lokalmodus (`mode == .local`): keine Outbox, kein Sync, keine Ablehnungen. Jede Änderung wird stattdessen
/// in das append-only `LocalJournal` (SHA-256-Kette) geschrieben; Begründungspflicht und Sperren
/// abgeschlossener Monate prüft der Store selbst (wie der Server). Ablage `Application Support/Lokal/`
/// (nicht vom Geräte-Backup ausgeschlossen, Dateischutz „completeUnlessOpen“).
@MainActor
@Observable
final class TenantStore {
    let tenant: TenantInfo
    /// Betriebsart dieses Stores
    let mode: AppMode
    @ObservationIgnored private let apiProvider: @MainActor () -> APIClient
    @ObservationIgnored private let fileURL: URL
    /// Lokalmodus: Journal aller Änderungen (sonst `nil`)
    @ObservationIgnored let localJournal: LocalJournal?
    /// Ablage der Beleg-Dateien (`nil` = Standard des Servermodus)
    @ObservationIgnored let attachmentDirectory: URL?
    @ObservationIgnored private let gate: StorageGate

    private(set) var vehicles: [String: Vehicle] = [:] { didSet { statsCache.removeAll() } }
    private(set) var odometer: [String: OdometerReading] = [:] { didSet { statsCache.removeAll() } }
    private(set) var fuel: [String: FuelEntry] = [:] { didSet { statsCache.removeAll() } }
    private(set) var maintenance: [String: Maintenance] = [:] { didSet { statsCache.removeAll() } }
    private(set) var items: [String: MaintenanceItem] = [:]
    private(set) var materials: [String: MaintenanceMaterial] = [:] { didSet { statsCache.removeAll() } }
    /// Materialstamm (mandantenweit)
    private(set) var articles: [String: MaterialArticle] = [:]
    /// Fahrtenbuch
    private(set) var trips: [String: Trip] = [:] { didSet { tripCache.invalidate() } }
    private(set) var places: [String: Place] = [:]
    private(set) var customers: [String: Customer] = [:]
    private(set) var rules: [String: PurposeRule] = [:]
    private(set) var taxParams: [String: TaxParam] = [:]
    /// Monatsabschlüsse (nur vom Server, nie in der Outbox)
    private(set) var periods: [String: TripPeriod] = [:]
    /// Belege (Metadaten); die JPEGs liegen in `AttachmentFiles`
    private(set) var attachments: [String: Attachment] = [:]
    /// Belege, deren Datei noch hochgeladen werden muss (nach dem Sync der Metadaten)
    private(set) var pendingBlobs: [String] = []
    private(set) var outbox: [PendingOp] = [] {
        didSet { pendingIds = Set(outbox.map(\.entityId)) }
    }
    /// IDs mit ausstehenden Änderungen (für `isPending`, O(1))
    private(set) var pendingIds: Set<String> = []
    private(set) var cursor = 0
    private(set) var lastSync: Date?

    private(set) var isSyncing = false
    private(set) var syncError: String?
    /// Hinweise aus dem letzten Sync (Konflikte, abgelehnte Änderungen)
    var notices: [String] = []
    /// Vom Server abgelehnte Änderungen (persistiert, bis verworfen oder erneut gesendet)
    private(set) var rejectedOps: [RejectedOp] = []
    /// Problem beim Laden der lokalen Datei (defekt → gesichert; gesperrt → später geladen)
    var storeLoadIssue: String?
    /// Lokalmodus: Anzahl Journal-Einträge und Kettenkopf (für Anzeige; ändert sich mit jeder Änderung)
    private(set) var journalCount = 0
    private(set) var journalHead = ""

    @ObservationIgnored private var rerunRequested = false
    @ObservationIgnored private var syncScheduled = false
    @ObservationIgnored private var batchDepth = 0
    @ObservationIgnored private var batchNeedsSync = false
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var dirty = false
    /// Datei vorhanden, aber nicht lesbar (Gerät gesperrt) → nicht überschreiben
    @ObservationIgnored private var persistBlocked = false
    @ObservationIgnored private let generation: Int
    @ObservationIgnored private let observers = ObserverBag()
    @ObservationIgnored private var tripCache = TripCache()
    @ObservationIgnored private var statsCache: [Vehicle: VehicleStats] = [:]
    @ObservationIgnored private var statsDay: Date?

    /// Server: Op-Begründung mindestens 10, höchstens 300 Zeichen
    static let minReasonLength = 10
    static let maxReasonLength = 300
    /// Ops je `/sync`-Anfrage (bei 413 halbiert)
    static let maxBatch = 200
    /// Einträge je `/changes`-Seite
    static let pageLimit = 1000
    /// Debounce der Persistenz
    static let persistDelay: UInt64 = 300_000_000

    var canWrite: Bool { tenant.canWrite }

    /// Lokalmodus (ohne Server)
    var isLocal: Bool { mode == .local }

    /// API-Client des angemeldeten Benutzers (für Aufrufe ausserhalb des Syncs, z. B. Scan).
    /// Im Lokalmodus ein Platzhalter, dessen Aufrufe sofort fehlschlagen (`APIClient.isLocalPlaceholder`).
    var api: APIClient { isLocal ? .localPlaceholder : apiProvider() }

    /// - Parameter directory: Ablageort der Mandantendatei (Tests); Standard `Application Support/Mandanten`
    ///   bzw. im Lokalmodus `Application Support/Lokal` (dort auch `journal.jsonl` und `Belege/`).
    init(tenant: TenantInfo, api: @escaping @MainActor () -> APIClient, directory: URL? = nil,
         mode: AppMode = .server) {
        self.tenant = tenant
        self.mode = mode
        self.apiProvider = api
        let dir = directory ?? (mode == .local ? Self.localDirectory() : Self.directory())
        self.fileURL = dir.appending(path: "\(tenant.slug).json")
        let gate: StorageGate = mode == .local ? .local : .shared
        self.gate = gate
        self.generation = gate.current
        if mode == .local {
            self.attachmentDirectory = dir.appending(path: "Belege", directoryHint: .isDirectory)
            self.localJournal = LocalJournal(fileURL: dir.appending(path: "journal.jsonl"), gate: gate)
        } else {
            self.attachmentDirectory = nil
            self.localJournal = nil
        }
        load()
        if mode == .local { recoverFromJournal() }
        observeAppLifecycle()
    }

    /// Lokales Fahrzeugbuch (ohne Server).
    convenience init(localDirectory directory: URL? = nil) {
        self.init(tenant: .local, api: { .localPlaceholder }, directory: directory, mode: .local)
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
    func fuelEntry(id: String) -> FuelEntry? { fuel[id] }
    func odometerReading(id: String) -> OdometerReading? { odometer[id] }

    // MARK: Belege – Lesen

    /// Nicht stornierte Belege einer Tankung, älteste zuerst.
    func attachments(forFuel fuelId: String) -> [Attachment] {
        attachments.values.filter { $0.fuelId == fuelId && !$0.deleted }
            .sorted { ($0.takenAt ?? "", $0.id) < ($1.takenAt ?? "", $1.id) }
    }

    /// Nicht stornierte Belege einer Wartung, älteste zuerst.
    func attachments(forMaintenance maintenanceId: String) -> [Attachment] {
        attachments.values.filter { $0.maintenanceId == maintenanceId && !$0.deleted }
            .sorted { ($0.takenAt ?? "", $0.id) < ($1.takenAt ?? "", $1.id) }
    }

    func isBlobPending(_ id: String) -> Bool { pendingBlobs.contains(id) }

    /// JPEG eines Belegs: lokal bzw. vom Server (danach lokal zwischengespeichert). `nil` offline/fehlend
    /// oder wenn die Prüfsumme nicht zum Beleg passt (dann Hinweis in `notices`).
    func attachmentData(_ a: Attachment) async -> Data? {
        if let local = AttachmentFiles.read(a.id, directory: attachmentDirectory) { return local }
        if isLocal { return nil }
        #if DEBUG
        if Demo.isActive { return nil }
        #endif
        guard !isBlobPending(a.id) else { return nil }   // noch nicht hochgeladen (anderes Gerät?)
        guard let data = try? await apiProvider().download("api/t/\(tenant.slug)/attachments/\(a.id)/blob"),
              !data.isEmpty else { return nil }
        guard AttachmentFiles.sha256(data) == a.sha256.lowercased() else {
            notices.append("Beleg «\(a.kindLabel)» wurde nicht angezeigt: Die Prüfsumme der heruntergeladenen Datei "
                           + "stimmt nicht mit dem Beleg überein (Datei beschädigt oder verändert).")
            return nil
        }
        try? AttachmentFiles.write(data, id: a.id)
        return data
    }
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

    // MARK: Fahrtenbuch – Lesen (gecacht je Fahrzeug, invalidiert bei jeder Änderung an `trips`)

    /// Chronologisch (Start aufsteigend, bei Gleichstand id). Nutzt das beim Dekodieren geparste Datum.
    static func chronological(_ a: Trip, _ b: Trip) -> Bool {
        let da = a.startDate ?? Date.distantPast
        let db = b.startDate ?? Date.distantPast
        if da != db { return da < db }
        return a.id < b.id
    }

    /// Nicht stornierte Fahrten des Fahrzeugs, chronologisch (Basis der übrigen Caches).
    private func chain(for vehicleId: String) -> [Trip] {
        let all = trips   // Zugriff registrieren (Observation), auch bei Cache-Treffer
        if let cached = tripCache.chain[vehicleId] { return cached }
        let list = all.values.filter { $0.vehicleId == vehicleId && !$0.deleted }.sorted(by: Self.chronological)
        tripCache.chain[vehicleId] = list
        return list
    }

    /// Nicht stornierte Fahrten des Fahrzeugs, neueste zuerst.
    func trips(for vehicleId: String) -> [Trip] {
        _ = trips
        if let cached = tripCache.newestFirst[vehicleId] { return cached }
        let list = Array(chain(for: vehicleId).reversed())
        tripCache.newestFirst[vehicleId] = list
        return list
    }

    /// Nicht stornierte Fahrten eines Monats ("YYYY-MM"), chronologisch.
    func trips(for vehicleId: String, month: String) -> [Trip] {
        chain(for: vehicleId).filter { $0.monthKey == month }
    }

    /// Zu bestätigende Fahrten (Entwurf/vorgeschlagen/ohne Kategorie, nicht gesperrt), älteste zuerst.
    func reviewTrips(for vehicleId: String) -> [Trip] {
        _ = trips
        if let cached = tripCache.review[vehicleId] { return cached }
        let list = chain(for: vehicleId).filter(\.needsReview)
        tripCache.review[vehicleId] = list
        return list
    }

    /// Anzahl zu bestätigender Fahrten über alle Fahrzeuge (Erinnerungen).
    var reviewCount: Int {
        vehicleList.reduce(0) { $0 + reviewTrips(for: $1.id).count }
    }

    func trip(id: String) -> Trip? { trips[id] }

    /// Höchster bekannter km-Stand: Tank/Odometer/Wartung sowie km-Ende der Fahrten.
    func lastKnownKm(for vehicleId: String) -> Int {
        let base = vehicles[vehicleId].map { currentKm($0) } ?? 0
        let tripMax = chain(for: vehicleId).compactMap { $0.kmEnd ?? $0.kmStart }.max() ?? 0
        return max(base, tripMax)
    }

    /// Lokale Lückenerkennung über die km-Kette (km-Ende Fahrt n ≠ km-Beginn Fahrt n+1).
    /// `month` filtert auf Lücken vor Fahrten dieses Monats (Kette inkl. letzter Fahrt des Vormonats).
    func gaps(for vehicleId: String, month: String?) -> [TripGap] {
        _ = trips
        let key = "\(vehicleId)|\(month ?? "*")"
        if let cached = tripCache.gaps[key] { return cached }
        let chain = chain(for: vehicleId)
        var result: [TripGap] = []
        for (a, b) in zip(chain, chain.dropFirst()) {
            guard let from = a.kmEnd, let to = b.kmStart, from != to else { continue }
            if let month, b.monthKey != month { continue }
            result.append(TripGap(afterTripId: a.id, beforeTripId: b.id, kmFrom: from, kmTo: to))
        }
        tripCache.gaps[key] = result
        return result
    }

    /// Tachostand abfragen: die letzte Fahrt des Fahrzeugs hat nur geschätzte km (GPS) und seither
    /// gibt es keinen abgelesenen Stand (km-Stand/Tankung) – z. B. abends nach der letzten Fahrt des Tages.
    func odometerPromptNeeded(vehicleId: String) -> Bool {
        guard let last = chain(for: vehicleId).last, last.kmEstimated, !last.isLocked,
              let end = last.endDate ?? last.startDate else { return false }
        let day = Calendar.current.startOfDay(for: end)
        let readAfter = odometer.values.contains { o in
            o.vehicleId == vehicleId && !o.deleted && o.date >= day && o.km >= (last.kmStart ?? 0)
        } || fuel.values.contains { f in
            f.vehicleId == vehicleId && !f.deleted && f.date >= day && f.km >= (last.kmStart ?? 0)
        }
        return !readAfter
    }

    /// Geschätzten km-Stand einer Fahrt durch den abgelesenen ersetzen (km-Ende, Schätzung aufheben).
    func confirmOdometer(tripId: String, kmEnd: Int, reason: String? = nil) {
        guard var t = trips[tripId], !t.deleted, !t.isLocked else { return }
        t.kmEnd = kmEnd
        if let s = t.kmStart, s > kmEnd { t.kmStart = kmEnd }
        t.kmEstimated = false
        save(t, reason: reason)
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

    /// Wohnort(e) mit Koordinaten (lokal), für Datenschutz-Kappung und „Wohnort“-Bezeichnung.
    var homePlaces: [Place] {
        places.values.filter { !$0.deleted && $0.isHome && $0.hasCoordinate }
    }

    /// Kein Wohnort erfasst → Start-/Ziel-Bezeichnungen nur als Gemeinde (Datenschutz), UI fordert zur Erfassung auf.
    var needsHomePlace: Bool {
        !places.values.contains { !$0.deleted && $0.isHome }
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

    // MARK: Begründungspflicht (abgeschlossene Monate, gesperrte Fahrten)

    /// Storno/Änderung braucht eine Begründung (≥ 10 Zeichen): Fahrt gesperrt oder Monat abgeschlossen.
    func requiresReason(for t: Trip) -> Bool {
        if t.isLocked || isMonthClosed(vehicleId: t.vehicleId, month: t.monthKey) { return true }
        if let old = trips[t.id], !old.deleted {
            return old.isLocked || isMonthClosed(vehicleId: old.vehicleId, month: old.monthKey)
        }
        return false
    }

    func requiresReason(fuel f: FuelEntry) -> Bool {
        closed(f.vehicleId, f.date) || fuel[f.id].map { closed($0.vehicleId, $0.date) } ?? false
    }

    func requiresReason(odometer o: OdometerReading) -> Bool {
        closed(o.vehicleId, o.date) || odometer[o.id].map { closed($0.vehicleId, $0.date) } ?? false
    }

    func requiresReason(maintenance m: Maintenance) -> Bool {
        closed(m.vehicleId, m.date) || maintenance[m.id].map { closed($0.vehicleId, $0.date) } ?? false
    }

    /// Begründung ausreichend (getrimmt ≥ 10 Zeichen)?
    static func isValidReason(_ reason: String?) -> Bool {
        (reason?.trimmed.count ?? 0) >= minReasonLength
    }

    private func closed(_ vehicleId: String, _ date: Date) -> Bool {
        isMonthClosed(vehicleId: vehicleId, month: TripTime.month(date))
    }

    /// Prüft die Begründung; fehlt sie, Hinweis statt Änderung (der Server würde ablehnen).
    private func checkReason(_ needed: Bool, _ reason: String?) -> Bool {
        guard needed, !Self.isValidReason(reason) else { return true }
        notices.append("Begründung erforderlich (mind. \(Self.minReasonLength) Zeichen): Der Monat ist "
                       + "abgeschlossen – Änderungen und Stornos werden mit Begründung protokolliert.")
        return false
    }

    private static func cleanReason(_ reason: String?) -> String? {
        reason?.nilIfEmpty.map { String($0.prefix(maxReasonLength)) }
    }

    /// Standardfahrzeug je Mandant für die Anzeige (Quick Actions, Vorbelegung); ohne Wahl das erste Fahrzeug.
    /// Automatik/Siri/CarPlay verwenden `explicitDefaultVehicleId` (Q3: nie stillschweigend das erste).
    var defaultVehicleId: String? {
        get {
            explicitDefaultVehicleId ?? vehicleList.first?.id
        }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultVehicleKey)
        }
    }

    /// Ausdrücklich gewähltes Standardfahrzeug (Einstellungen › Fahrtenbuch bzw. zuletzt gestartete Fahrt);
    /// `nil`, wenn keines gewählt oder es storniert ist.
    var explicitDefaultVehicleId: String? {
        guard let id = UserDefaults.standard.string(forKey: defaultVehicleKey),
              let v = vehicles[id], !v.deleted else { return nil }
        return id
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

    /// Statistik je Fahrzeug, gecacht (invalidiert bei Änderungen an Fahrzeugen, km-Ständen, Tankungen,
    /// Wartungen, Material sowie beim Tageswechsel).
    func stats(for v: Vehicle) -> VehicleStats {
        // Zugriffe registrieren, damit Ansichten auch bei Cache-Treffern aktualisiert werden
        _ = (vehicles.count, odometer.count, fuel.count, maintenance.count, materials.count)
        let today = Calendar.current.startOfDay(for: Date())
        if statsDay != today {
            statsCache.removeAll()
            statsDay = today
        }
        if let cached = statsCache[v] { return cached }
        let list = maintenance(for: v.id)
        let ids = Set(list.map(\.id))
        let mats = materials.values.filter { !$0.deleted && ids.contains($0.maintenanceId) }
        let s = StatsCalculator.stats(vehicle: v, odometer: odometer(for: v.id), fuel: fuel(for: v.id),
                                      maintenance: list, materials: mats)
        statsCache[v] = s
        return s
    }

    /// Alias für `stats(for:)` (bereits gecacht).
    func cachedStats(for v: Vehicle) -> VehicleStats { stats(for: v) }

    func currentKm(_ v: Vehicle) -> Int { stats(for: v).currentKm }

    func isPending(_ id: String) -> Bool { pendingIds.contains(id) }

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

    /// Mehrere Änderungen gebündelt: eine Persistenz und ein Sync am Ende (z. B. „alle bestätigen“).
    func performBatch(_ body: () -> Void) {
        batchDepth += 1
        body()
        batchDepth -= 1
        if batchDepth == 0 && batchNeedsSync {
            batchNeedsSync = false
            persist()
            scheduleSync()
        }
    }

    func save(_ v: Vehicle) { upsert(v, in: \.vehicles) }
    func delete(_ v: Vehicle) { remove(v, in: \.vehicles) }

    func save(_ o: OdometerReading, reason: String? = nil) {
        guard checkReason(requiresReason(odometer: o), reason) else { return }
        let touched = datedKeys(o.vehicleId, o.date, odometer[o.id].map { ($0.vehicleId, $0.date) })
        upsert(o, in: \.odometer, reason: reason)
        bumpLocalCorrections(touched)
    }

    func delete(_ o: OdometerReading, reason: String? = nil) {
        guard checkReason(requiresReason(odometer: o), reason) else { return }
        remove(o, in: \.odometer, reason: reason)
        bumpLocalCorrections(datedKeys(o.vehicleId, o.date, nil))
    }

    func save(_ f: FuelEntry, reason: String? = nil) {
        guard checkReason(requiresReason(fuel: f), reason) else { return }
        let touched = datedKeys(f.vehicleId, f.date, fuel[f.id].map { ($0.vehicleId, $0.date) })
        upsert(f, in: \.fuel, reason: reason)
        bumpLocalCorrections(touched)
    }

    func delete(_ f: FuelEntry, reason: String? = nil) {
        guard checkReason(requiresReason(fuel: f), reason) else { return }
        remove(f, in: \.fuel, reason: reason)
        bumpLocalCorrections(datedKeys(f.vehicleId, f.date, nil))
    }

    func delete(_ m: Maintenance, reason: String? = nil) {
        guard checkReason(requiresReason(maintenance: m), reason) else { return }
        remove(m, in: \.maintenance, reason: reason)
        bumpLocalCorrections(datedKeys(m.vehicleId, m.date, nil))
    }

    func save(_ a: MaterialArticle) { upsert(a, in: \.articles) }
    func delete(_ a: MaterialArticle) { remove(a, in: \.articles) }
    func save(_ p: Place) { upsert(p, in: \.places) }
    func delete(_ p: Place) { remove(p, in: \.places) }
    func save(_ c: Customer) { upsert(c, in: \.customers) }
    func delete(_ c: Customer) { remove(c, in: \.customers) }
    func save(_ r: PurposeRule) { upsert(r, in: \.rules) }
    func delete(_ r: PurposeRule) { remove(r, in: \.rules) }
    /// Steuerparameter: im Servermodus nur im Webfrontend bearbeitbar (der Server lehnt App-Änderungen ab).
    func save(_ p: TaxParam) {
        guard canEditTaxParams else { notices.append(Self.taxParamsWebOnly); return }
        upsert(p, in: \.taxParams)
    }

    func delete(_ p: TaxParam) {
        guard canEditTaxParams else { notices.append(Self.taxParamsWebOnly); return }
        remove(p, in: \.taxParams)
    }

    /// Steuerparameter in der App änderbar (nur Lokalmodus)
    var canEditTaxParams: Bool { isLocal && canWrite }

    static let taxParamsWebOnly = "Steuerparameter sind nur im Webfrontend bearbeitbar."

    /// Fahrt speichern. Gesperrte Fahrten (abgeschlossener Monat) sind unveränderlich – nur Storno.
    /// In abgeschlossenen Monaten (z. B. Nachtrag) ist eine Begründung nötig. Im Privatmodus werden
    /// Orts-IDs, Zweck, Kunde, Track-Hash und Vorschläge entfernt (Server lehnt sie ab).
    func save(_ t: Trip, reason: String? = nil) {
        saveTrip(t, reason: reason)
    }

    @discardableResult
    private func saveTrip(_ t: Trip, reason: String?) -> Bool {
        if let existing = trips[t.id], existing.isLocked {
            notices.append("Die Fahrt gehört zu einem abgeschlossenen Monat und kann nicht geändert werden. "
                           + "Stornieren und mit Korrekturbegründung neu erfassen.")
            return false
        }
        guard checkReason(requiresReason(for: t), reason) else { return false }
        var e = t.privacySanitized
        if e.status == "locked" { e.status = "confirmed" }   // „locked“ setzt nur der Server
        var touched = [(e.vehicleId, e.monthKey)]
        if let old = trips[e.id] { touched.append((old.vehicleId, old.monthKey)) }
        let closedKeys = touched.filter { isMonthClosed(vehicleId: $0.0, month: $0.1) }
        if isLocal && !closedKeys.isEmpty {
            // wie Server: Korrektur/Nachtrag im abgeschlossenen Monat → sofort gesperrt, Namen eingefroren
            e.status = "locked"
            e = LogbookRules.frozenNames(e, places: places, customers: customers)
        }
        upsert(e, in: \.trips, reason: reason)
        bumpLocalCorrections(closedKeys)
        return true
    }

    /// Storno ist auch bei gesperrten Fahrten erlaubt (wird protokolliert) – dann mit Begründung (≥ 10 Zeichen).
    func delete(_ t: Trip, reason: String? = nil) {
        guard checkReason(requiresReason(for: t), reason) else { return }
        let old = trips[t.id] ?? t
        remove(t, in: \.trips, reason: reason)
        bumpLocalCorrections([(old.vehicleId, old.monthKey)])
    }

    // MARK: Lokalmodus – Korrekturen in abgeschlossenen Monaten

    private func datedKeys(_ vehicleId: String, _ date: Date, _ old: (String, Date)?) -> [(String, String)] {
        var out = [(vehicleId, TripTime.month(date))]
        if let old { out.append((old.0, TripTime.month(old.1))) }
        return out
    }

    /// Lokalmodus: Korrekturzähler der betroffenen abgeschlossenen Monate erhöhen (wie Server).
    private func bumpLocalCorrections(_ keys: [(String, String)]) {
        guard isLocal else { return }
        var seen = Set<String>()
        for (vehicleId, month) in keys where seen.insert("\(vehicleId)|\(month)").inserted {
            guard var p = period(vehicleId: vehicleId, month: month) else { continue }
            p.corrections = (p.corrections ?? 0) + 1
            p.version += 1
            periods[p.id] = p
            journalRecord("trip_period", p.id, version: p.version, action: "update", value: p, reason: nil)
        }
    }

    /// Fahrt bestätigen (Kategorie setzen). `purpose`/`customerId` = nil → unverändert.
    func confirm(_ trip: Trip, as category: TripCategory, purpose: String? = nil, customerId: String? = nil,
                 reason: String? = nil) {
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
        save(t, reason: reason)
    }

    /// Monatsabschluss aus der Server-Antwort übernehmen (POST …/close).
    func storePeriod(_ p: TripPeriod) {
        for (key, old) in periods where old.vehicleId == p.vehicleId && old.month == p.month && key != p.id {
            periods.removeValue(forKey: key)
        }
        periods[p.id] = p
        persist()
    }

    /// Monat abschliessen (nur online): überträgt zuerst die Outbox, sendet `POST …/periods/{month}/close`,
    /// übernimmt den Abschluss und synchronisiert danach (gesperrte Fahrten). Fehler als `APIError`
    /// (409 mit strukturiertem Detail: offene Fahrten, Lücken, unvollständige Fahrten; 422 laufender Monat).
    func closeMonth(vehicleId: String, month: String, force: Bool, reason: String?) async throws -> PeriodCloseResponse {
        if isLocal { return try closeMonthLocally(vehicleId: vehicleId, month: month, force: force, reason: reason) }
        guard canWrite else { throw APIError(status: 403, message: "Keine Schreibberechtigung für diesen Mandanten.") }
        guard month < TripTime.month(Date()) else {
            throw APIError(status: 422, message: "Nur abgelaufene Monate können abgeschlossen werden.")
        }
        await sync()   // ausstehende Fahrten zuerst übertragen
        var payload: [String: Any] = ["force": force]
        if let r = reason?.nilIfEmpty { payload["reason"] = String(r.prefix(500)) }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let response: PeriodCloseResponse = try await apiProvider().send(
            "POST", "api/t/\(tenant.slug)/vehicles/\(vehicleId)/periods/\(month)/close", body: body)
        storePeriod(response.period)
        await sync()   // gesperrte Fahrten holen
        return response
    }

    /// Wartung inkl. Checkliste und Material speichern; entfernte Punkte/Positionen werden storniert,
    /// unveränderte nicht erneut gesendet. `reason` (abgeschlossener Monat) gilt für alle Ops dieser Speicherung.
    func save(_ m: Maintenance, items newItems: [MaintenanceItem], materials newMaterials: [MaintenanceMaterial],
              reason: String? = nil) {
        guard checkReason(requiresReason(maintenance: m), reason) else { return }
        performBatch {
            upsert(m, in: \.maintenance, reason: reason)
            let keep = Set(newItems.map(\.id))
            for old in items(for: m.id) where !keep.contains(old.id) {
                remove(old, in: \.items, reason: reason)
            }
            for (n, var item) in newItems.enumerated() {
                item.position = n
                item.maintenanceId = m.id
                if let existing = items[item.id], !existing.deleted,
                   existing.label == item.label, existing.done == item.done, existing.position == item.position {
                    continue // unverändert → keine Revision
                }
                upsert(item, in: \.items, reason: reason)
            }
            let keepMaterials = Set(newMaterials.map(\.id))
            for old in materials(for: m.id) where !keepMaterials.contains(old.id) {
                remove(old, in: \.materials, reason: reason)
            }
            for (n, var material) in newMaterials.enumerated() {
                material.position = n
                material.maintenanceId = m.id
                if let existing = materials[material.id], !existing.deleted {
                    var compare = material
                    compare.version = existing.version
                    compare.deleted = existing.deleted
                    compare.createdBy = existing.createdBy
                    compare.updatedBy = existing.updatedBy
                    if compare == existing { continue } // unverändert → keine Revision
                }
                upsert(material, in: \.materials, reason: reason)
            }
        }
    }

    /// Wartung ohne Checkliste/Material speichern (Felder der Wartung selbst).
    func save(_ m: Maintenance, reason: String? = nil) {
        guard checkReason(requiresReason(maintenance: m), reason) else { return }
        upsert(m, in: \.maintenance, reason: reason)
    }

    // MARK: Belege – Schreiben

    /// Beleg anlegen: JPEG lokal speichern, Metadaten in die Outbox, Datei nach dem Sync hochladen.
    /// Bei neuen Einträgen erst nach `save(…)` des Eintrags aufrufen (Reihenfolge in der Outbox).
    @discardableResult
    func addAttachment(imageData: Data, kind: String, fuelId: String?, maintenanceId: String?,
                       vehicleId: String?, note: String? = nil) -> Attachment? {
        guard canWrite else { return nil }
        guard !imageData.isEmpty, imageData.count <= Attachment.maxSize else {
            notices.append("Beleg nicht gespeichert: Das Foto ist grösser als 8 MB.")
            return nil
        }
        let a = Attachment(fuelId: fuelId, maintenanceId: maintenanceId, vehicleId: vehicleId,
                           kind: Attachment.kinds.contains(kind) ? kind : "other",
                           sha256: AttachmentFiles.sha256(imageData), mime: "image/jpeg", size: imageData.count,
                           takenAt: ISODate.string(Date()), note: note?.nilIfEmpty)
        do {
            try AttachmentFiles.write(imageData, id: a.id, directory: attachmentDirectory)
        } catch {
            notices.append("Beleg konnte nicht lokal gespeichert werden: \(error.localizedDescription)")
            return nil
        }
        if !isLocal { pendingBlobs.append(a.id) }
        upsert(a, in: \.attachments)
        return attachments[a.id]
    }

    /// Beleg stornieren (Metadaten bleiben im Änderungsprotokoll).
    func delete(_ a: Attachment) {
        guard canWrite else { return }
        pendingBlobs.removeAll { $0 == a.id }
        remove(a, in: \.attachments)
    }

    func toggle(_ item: MaintenanceItem) {
        guard var current = items[item.id] else { return }
        current.done.toggle()
        upsert(current, in: \.items)
    }

    private func upsert<T: SyncEntity>(_ entity: T, in kp: ReferenceWritableKeyPath<TenantStore, [String: T]>,
                                       reason: String? = nil) {
        guard canWrite else { return }
        var e = entity
        let existing = self[keyPath: kp][e.id]
        let base = existing.map(\.version)         // nil → neu
        e.version = (base ?? 0) + 1                 // optimistisch, Server bestätigt
        e.deleted = false
        self[keyPath: kp][e.id] = e
        if isLocal {
            journalRecord(T.entityName, e.id, version: e.version, action: base == nil ? "create" : "update",
                          value: e, reason: Self.cleanReason(reason))
            return
        }
        enqueue(PendingOp(entity: T.entityName, entityId: e.id, action: "upsert",
                          baseVersion: base, data: try? e.payload(), clientTs: Self.now(),
                          reason: Self.cleanReason(reason)))
    }

    private func remove<T: SyncEntity>(_ entity: T, in kp: ReferenceWritableKeyPath<TenantStore, [String: T]>,
                                       reason: String? = nil) {
        guard canWrite, var e = self[keyPath: kp][entity.id], !e.deleted else { return }
        let base = e.version
        e.deleted = true
        e.version += 1
        self[keyPath: kp][e.id] = e
        if isLocal {
            journalRecord(T.entityName, e.id, version: e.version, action: "delete", value: e,
                          reason: Self.cleanReason(reason))
            return
        }
        enqueue(PendingOp(entity: T.entityName, entityId: e.id, action: "delete",
                          baseVersion: base, data: nil, clientTs: Self.now(), reason: Self.cleanReason(reason)))
    }

    /// Lokalmodus: Änderung ins Journal (statt Outbox) und speichern.
    private func journalRecord<T: Encodable>(_ entity: String, _ id: String, version: Int, action: String, value: T,
                                             reason: String?) {
        guard let journal = localJournal else { return }
        let data = (try? JSONNode.from(value, encoder: Self.fileEncoder)) ?? .null
        journal.append(entity: entity, entityId: id, version: version, action: action, data: data, reason: reason)
        journalCount = journal.count
        journalHead = journal.headHash
        if batchDepth > 0 {
            batchNeedsSync = true
            return
        }
        persist()
    }

    private func enqueue(_ op: PendingOp) {
        guard !isLocal else { return }
        outbox.append(op)
        if batchDepth > 0 {
            batchNeedsSync = true
            return
        }
        persist()
        scheduleSync()
    }

    /// Automatischer Sync nach Änderungen (Tests schalten ihn aus und rufen `sync()` selbst auf).
    @ObservationIgnored var autoSyncEnabled = true

    /// Mehrere Änderungen kurz nacheinander → ein Sync.
    private func scheduleSync() {
        guard autoSyncEnabled, !syncScheduled, !isLocal else { return }
        syncScheduled = true
        Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            self.syncScheduled = false
            await self.sync()
        }
    }

    // MARK: Abgelehnte Änderungen

    /// Abgelehnte Änderung verwerfen (lokale Kopie geht verloren).
    func dismissRejected(_ id: String) {
        rejectedOps.removeAll { $0.id == id }
        persist()
    }

    /// Lokale Kopie des abgelehnten Objekts (JSON wie in der Mandantendatei) – zum Bearbeiten.
    func rejectedSnapshot(id: String) -> Data? {
        rejectedOps.first { $0.id == id }?.snapshot
    }

    /// Abgelehntes Objekt dekodiert, z. B. `rejectedObject(id, as: FuelEntry.self)`.
    func rejectedObject<T: SyncEntity>(_ id: String, as type: T.Type) -> T? {
        guard let r = rejectedOps.first(where: { $0.id == id }), r.entity == T.entityName,
              let data = r.snapshot else { return nil }
        return try? Self.fileDecoder.decode(T.self, from: data)
    }

    /// Erneut senden: Upsert aus dem letzten lokalen Stand (bzw. Storno erneut), optional mit Begründung.
    /// Bleibt die Änderung lokal unzulässig (z. B. Begründung fehlt), bleibt der Eintrag bestehen.
    func retryRejected(_ id: String, reason: String? = nil) {
        guard canWrite, let r = rejectedOps.first(where: { $0.id == id }) else { return }
        let why = reason ?? r.reason
        let ok: Bool
        if r.action == "delete" {
            ok = retryDelete(entity: r.entity, id: r.entityId, reason: why)
        } else if let data = r.snapshot {
            ok = retryUpsert(entity: r.entity, data: data, reason: why)
        } else {
            ok = false
        }
        if ok {
            rejectedOps.removeAll { $0.id == id }
            persist()
        }
    }

    private func retryUpsert(entity: String, data: Data, reason: String?) -> Bool {
        let d = Self.fileDecoder
        func decode<T: SyncEntity>(_ type: T.Type) -> T? { try? d.decode(T.self, from: data) }
        let before = outbox.count
        switch entity {
        case Vehicle.entityName: if let v = decode(Vehicle.self) { save(v) }
        case OdometerReading.entityName: if let o = decode(OdometerReading.self) { save(o, reason: reason) }
        case FuelEntry.entityName: if let f = decode(FuelEntry.self) { save(f, reason: reason) }
        case Maintenance.entityName: if let m = decode(Maintenance.self) { save(m, reason: reason) }
        case MaintenanceItem.entityName: if let i = decode(MaintenanceItem.self) { upsert(i, in: \.items, reason: reason) }
        case MaintenanceMaterial.entityName:
            if let m = decode(MaintenanceMaterial.self) { upsert(m, in: \.materials, reason: reason) }
        case MaterialArticle.entityName: if let a = decode(MaterialArticle.self) { save(a) }
        case Trip.entityName: if let t = decode(Trip.self) { saveTrip(t, reason: reason) }
        case Place.entityName: if let p = decode(Place.self) { save(p) }
        case Customer.entityName: if let c = decode(Customer.self) { save(c) }
        case PurposeRule.entityName: if let r = decode(PurposeRule.self) { save(r) }
        case TaxParam.entityName: if let p = decode(TaxParam.self) { save(p) }
        case Attachment.entityName:
            if let a = decode(Attachment.self) {
                upsert(a, in: \.attachments, reason: reason)
                if AttachmentFiles.exists(a.id), !pendingBlobs.contains(a.id) { pendingBlobs.append(a.id) }
            }
        default: break
        }
        return outbox.count > before
    }

    private func retryDelete(entity: String, id: String, reason: String?) -> Bool {
        let before = outbox.count
        switch entity {
        case Vehicle.entityName: if let v = vehicles[id] { delete(v) }
        case OdometerReading.entityName: if let o = odometer[id] { delete(o, reason: reason) }
        case FuelEntry.entityName: if let f = fuel[id] { delete(f, reason: reason) }
        case Maintenance.entityName: if let m = maintenance[id] { delete(m, reason: reason) }
        case MaintenanceItem.entityName: if let i = items[id] { remove(i, in: \.items, reason: reason) }
        case MaintenanceMaterial.entityName: if let m = materials[id] { remove(m, in: \.materials, reason: reason) }
        case MaterialArticle.entityName: if let a = articles[id] { delete(a) }
        case Trip.entityName: if let t = trips[id] { delete(t, reason: reason) }
        case Place.entityName: if let p = places[id] { delete(p) }
        case Customer.entityName: if let c = customers[id] { delete(c) }
        case PurposeRule.entityName: if let r = rules[id] { delete(r) }
        case TaxParam.entityName: if let p = taxParams[id] { delete(p) }
        case Attachment.entityName: if let a = attachments[id] { delete(a) }
        default: break
        }
        // Lokal bereits storniert/fehlt (Server-Stand nach Abgleich) → nichts mehr zu tun
        return outbox.count > before || !entityExists(entity, id)
    }

    private func entityExists(_ entity: String, _ id: String) -> Bool {
        switch entity {
        case Vehicle.entityName: vehicles[id].map { !$0.deleted } ?? false
        case OdometerReading.entityName: odometer[id].map { !$0.deleted } ?? false
        case FuelEntry.entityName: fuel[id].map { !$0.deleted } ?? false
        case Maintenance.entityName: maintenance[id].map { !$0.deleted } ?? false
        case MaintenanceItem.entityName: items[id].map { !$0.deleted } ?? false
        case MaintenanceMaterial.entityName: materials[id].map { !$0.deleted } ?? false
        case MaterialArticle.entityName: articles[id].map { !$0.deleted } ?? false
        case Trip.entityName: trips[id].map { !$0.deleted } ?? false
        case Place.entityName: places[id].map { !$0.deleted } ?? false
        case Customer.entityName: customers[id].map { !$0.deleted } ?? false
        case PurposeRule.entityName: rules[id].map { !$0.deleted } ?? false
        case TaxParam.entityName: taxParams[id].map { !$0.deleted } ?? false
        case Attachment.entityName: attachments[id].map { !$0.deleted } ?? false
        default: false
        }
    }

    /// Lokales Objekt als JSON (Format der Mandantendatei).
    private func encodedEntity(_ entity: String, _ id: String) -> Data? {
        let e = Self.fileEncoder
        func enc<T: Encodable>(_ v: T?) -> Data? { v.flatMap { try? e.encode($0) } }
        switch entity {
        case Vehicle.entityName: return enc(vehicles[id])
        case OdometerReading.entityName: return enc(odometer[id])
        case FuelEntry.entityName: return enc(fuel[id])
        case Maintenance.entityName: return enc(maintenance[id])
        case MaintenanceItem.entityName: return enc(items[id])
        case MaintenanceMaterial.entityName: return enc(materials[id])
        case MaterialArticle.entityName: return enc(articles[id])
        case Trip.entityName: return enc(trips[id])
        case Place.entityName: return enc(places[id])
        case Customer.entityName: return enc(customers[id])
        case PurposeRule.entityName: return enc(rules[id])
        case TaxParam.entityName: return enc(taxParams[id])
        case Attachment.entityName: return enc(attachments[id])
        default: return nil
        }
    }

    /// „Tankvorgang 24.11.“, „Fahrt 24.11. Wohnort → Büro“, „Ort Büro“ …
    func describeEntity(_ entity: String, _ id: String) -> String {
        let base = Self.entityLabel(entity)
        let day: (Date) -> String = { Self.shortDayFormatter.string(from: $0) }
        switch entity {
        case FuelEntry.entityName: if let f = fuel[id] { return "\(base) \(day(f.date))" }
        case OdometerReading.entityName: if let o = odometer[id] { return "\(base) \(day(o.date))" }
        case Maintenance.entityName: if let m = maintenance[id] { return "\(base) «\(m.title)» \(day(m.date))" }
        case Trip.entityName:
            if let t = trips[id] {
                let when = t.startDate.map(day) ?? String(t.startAt.prefix(10))
                return "\(base) \(when) \(routeText(t))"
            }
        case Vehicle.entityName: if let v = vehicles[id] { return "\(base) \(v.name)" }
        case Place.entityName: if let p = places[id] { return "\(base) \(p.name)" }
        case Customer.entityName: if let c = customers[id] { return "\(base) \(c.name)" }
        case MaterialArticle.entityName: if let a = articles[id] { return "\(base) \(a.name)" }
        case MaintenanceItem.entityName: if let i = items[id] { return "\(base) \(i.label)" }
        case MaintenanceMaterial.entityName: if let m = materials[id] { return "\(base) \(m.name)" }
        case Attachment.entityName: if let a = attachments[id] { return "\(base) (\(a.kindLabel))" }
        default: break
        }
        return base
    }

    private func recordRejection(entity: String, entityId: String, op: PendingOp?, error: String) {
        let opId = op?.opId ?? UUID().uuidString.lowercased()
        guard !rejectedOps.contains(where: { $0.id == opId }) else { return }
        let entry = RejectedOp(id: opId, entity: entity, entityId: entityId, action: op?.action ?? "upsert",
                               label: describeEntity(entity, entityId), error: error, date: Date(),
                               snapshot: encodedEntity(entity, entityId), reason: op?.reason)
        // Ältere Ablehnungen desselben Objekts ersetzen (nur der letzte Stand zählt)
        rejectedOps.removeAll { $0.entity == entity && $0.entityId == entityId }
        rejectedOps.append(entry)
    }

    // MARK: Sync

    func sync() async {
        if isLocal { return }   // Lokalmodus: kein Server
        #if DEBUG
        if Demo.isActive { return }
        #endif
        if persistBlocked {
            reloadIfBlocked()
            if persistBlocked { return }   // lokale Datei noch gesperrt → nichts überschreiben
        }
        if isSyncing { rerunRequested = true; return }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            rerunRequested = false
            do {
                let needsFullPull = try await push()
                try await pull(full: needsFullPull)
                await uploadPendingBlobs()
                syncError = nil
                lastSync = Date()
                persist()
            } catch {
                syncError = Self.describe(error)
                persist()
                return
            }
        } while rerunRequested
    }

    /// JSON-Körper für `/sync`.
    static func syncBody(_ batch: [PendingOp]) throws -> Data {
        let ops: [[String: Any]] = batch.map { op in
            var d: [String: Any] = [
                "op_id": op.opId, "entity": op.entity, "id": op.entityId,
                "action": op.action, "client_ts": op.clientTs,
            ]
            d["base_version"] = op.baseVersion ?? NSNull()
            if let data = op.data, let obj = try? JSONSerialization.jsonObject(with: data) {
                d["data"] = obj
            }
            if let reason = op.reason { d["reason"] = reason }
            return d
        }
        return try JSONSerialization.data(withJSONObject: ["ops": ops])
    }

    /// Sendet die Outbox. Rückgabe `true`, wenn Ops abgelehnt wurden (→ vollständiger Abgleich nötig).
    /// Vorübergehende Serverfehler (503 für die ganze Anfrage) werfen → Ops bleiben in der Outbox.
    /// 413 → Batch halbieren; eine einzelne zu grosse Op wird als abgelehnt abgelegt.
    private func push() async throws -> Bool {
        var rejected = false
        var batchSize = Self.maxBatch
        while !outbox.isEmpty {
            let batch = Array(outbox.prefix(batchSize))
            let body = try Self.syncBody(batch)
            let response: SyncResponse
            do {
                response = try await apiProvider().send("POST", "api/t/\(tenant.slug)/sync", body: body)
            } catch let error as APIError where error.status == 413 {
                if batch.count > 1 {
                    batchSize = max(1, batch.count / 2)
                    continue
                }
                let op = batch[0]
                recordRejection(entity: op.entity, entityId: op.entityId, op: op,
                                error: "Änderung zu gross für den Server")
                notices.append("\(Self.entityLabel(op.entity)) abgelehnt: Änderung zu gross für den Server.")
                outbox.removeAll { $0.opId == op.opId }
                rejected = true
                persist()
                continue
            }

            let ops = Dictionary(batch.map { ($0.opId, $0) }, uniquingKeysWith: { a, _ in a })
            let done = Set(response.results.map(\.opId))
            for r in response.results {
                switch r.status {
                case "conflict":
                    notices.append("Konflikt bei \(Self.entityLabel(r.entity)): deine Version wurde übernommen, "
                                   + "die vorherige bleibt im Verlauf.")
                case "rejected":
                    rejected = true
                    let message = r.error ?? "unbekannt"
                    recordRejection(entity: r.entity, entityId: r.id, op: ops[r.opId], error: message)
                    notices.append("\(describeEntity(r.entity, r.id)) abgelehnt: \(message)")
                    if r.entity == Attachment.entityName { pendingBlobs.removeAll { $0 == r.id } }
                default:
                    break
                }
            }
            outbox.removeAll { done.contains($0.opId) }
            for r in response.results {
                if let v = r.version { setVersion(r.entity, r.id, v) }
            }
            persist()
            if done.isEmpty { break } // Schutz vor Endlosschleife
        }
        return rejected
    }

    /// Holt Änderungen seitenweise (`limit`, `has_more`); Merge und Cursor je Seite.
    /// `full`: ab 0, lokaler Bestand (ausser ausstehenden Änderungen) wird mit der ersten Seite ersetzt.
    private func pull(full: Bool) async throws {
        var since = full ? 0 : cursor
        var firstPage = true
        let previousPlaces = places   // Wohnort-Koordinaten bleiben lokal
        while true {
            let ch: ChangesResponse = try await apiProvider().get(
                "api/t/\(tenant.slug)/changes",
                query: [URLQueryItem(name: "since", value: String(since)),
                        URLQueryItem(name: "limit", value: String(Self.pageLimit))])
            if full && firstPage { clearForFullPull(ch) }
            firstPage = false
            apply(ch, previousPlaces: previousPlaces)
            cursor = ch.cursor
            persist()
            guard ch.hasMore, ch.cursor > since else { break }
            since = ch.cursor
        }
    }

    private func clearForFullPull(_ ch: ChangesResponse) {
        let pending = pendingIds
        vehicles = vehicles.filter { pending.contains($0.key) }
        odometer = odometer.filter { pending.contains($0.key) }
        fuel = fuel.filter { pending.contains($0.key) }
        maintenance = maintenance.filter { pending.contains($0.key) }
        items = items.filter { pending.contains($0.key) }
        materials = materials.filter { pending.contains($0.key) }
        articles = articles.filter { pending.contains($0.key) }
        trips = trips.filter { pending.contains($0.key) }
        places = places.filter { pending.contains($0.key) }
        customers = customers.filter { pending.contains($0.key) }
        rules = rules.filter { pending.contains($0.key) }
        taxParams = taxParams.filter { pending.contains($0.key) }
        if ch.tripPeriods != nil { periods = [:] }
        if ch.attachments != nil { attachments = attachments.filter { pending.contains($0.key) } }
    }

    private func apply(_ ch: ChangesResponse, previousPlaces: [String: Place]) {
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
        merge(ch.attachments ?? [], into: \.attachments)
        let newPeriods = ch.tripPeriods ?? []
        if !newPeriods.isEmpty {
            var dict = periods
            for p in newPeriods {
                for (key, old) in dict where old.vehicleId == p.vehicleId && old.month == p.month && key != p.id {
                    dict.removeValue(forKey: key)
                }
                dict[p.id] = p
            }
            periods = dict
        }
    }

    /// Lädt Beleg-Dateien hoch, deren Metadaten bereits beim Server sind (nicht mehr in der Outbox).
    /// 404 (Metadaten fehlen noch), 5xx, 429 und offline → später erneut; endgültige Fehler → Hinweis.
    private func uploadPendingBlobs() async {
        guard !pendingBlobs.isEmpty else { return }
        var changed = false
        blobs: for id in pendingBlobs {
            if isPending(id) { continue }
            guard let a = attachments[id], !a.deleted else {
                pendingBlobs.removeAll { $0 == id }
                changed = true
                continue
            }
            guard let data = AttachmentFiles.read(id) else {
                pendingBlobs.removeAll { $0 == id }
                changed = true
                notices.append("Beleg-Foto ist nicht mehr auf dem Gerät und konnte nicht hochgeladen werden.")
                continue
            }
            do {
                try await apiProvider().upload(path: "api/t/\(tenant.slug)/attachments/\(id)/blob",
                                               data: data, contentType: a.mime)
                pendingBlobs.removeAll { $0 == id }   // 200 (bereits vorhanden) oder 201 (neu)
                changed = true
            } catch let error as APIError {
                let message: String?
                switch error.status {
                case 404, 429, 500...599:   // inkl. 507 Speicherfehler
                    message = nil   // Metadaten noch nicht da bzw. Server vorübergehend → später erneut
                case 409:
                    message = "Beleg-Foto nicht übertragen: Beleg storniert oder anderer Inhalt vorhanden."
                case 413:
                    message = "Beleg-Foto zu gross (max. 8 MB) – nicht übertragen."
                case 415, 422:
                    message = "Beleg-Foto vom Server abgelehnt (Format/Prüfsumme)."
                case 403:
                    message = "Keine Berechtigung, Beleg-Fotos hochzuladen."
                default:
                    message = nil
                }
                if let message {
                    pendingBlobs.removeAll { $0 == id }
                    changed = true
                    notices.append(message)
                }
            } catch {
                break blobs   // offline → beim nächsten Sync
            }
        }
        if changed { persist() }
    }

    private func merge<T: SyncEntity>(_ list: [T], into kp: ReferenceWritableKeyPath<TenantStore, [String: T]>) {
        guard !list.isEmpty else { return }
        var dict = self[keyPath: kp]
        let pending = pendingIds
        for e in list where !pending.contains(e.id) { dict[e.id] = e }
        self[keyPath: kp] = dict
    }

    /// Orte übernehmen; ohne Koordinaten vom Server (Wohnort/privat: App sendet sie nie) → lokale behalten.
    private func mergePlaces(_ list: [Place], previous: [String: Place]) {
        guard !list.isEmpty else { return }
        var dict = places
        for var p in list where !isPending(p.id) {
            if p.lat == nil, p.lon == nil {
                let old = previous[p.id] ?? dict[p.id]
                if let old, old.hasCoordinate {
                    p.lat = old.lat
                    p.lon = old.lon
                }
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
        case Attachment.entityName: attachments[id]?.version = v
        default: break
        }
    }

    // MARK: Lokalmodus – Journal, Abschluss, Datenaustausch

    /// Lokalmodus beim Laden: Objekte, deren Journal-Stand neuer ist als die Datei (z. B. App beendet vor dem
    /// verzögerten Speichern oder Datei defekt), aus dem Journal übernehmen.
    private func recoverFromJournal() {
        guard let journal = localJournal else { return }
        journalCount = journal.count
        journalHead = journal.headHash
        var restored = 0
        for e in journal.latest().values.sorted(by: { $0.seq < $1.seq }) where applyJournalState(e) {
            restored += 1
        }
        if restored > 0 {
            notices.append("\(restored) Eintrag/Einträge aus dem lokalen Journal wiederhergestellt.")
            persist()
        }
    }

    /// Stand aus dem Journal übernehmen, wenn neuer als der aktuelle Datensatz. Rückgabe: übernommen.
    private func applyJournalState(_ e: JournalEntry) -> Bool {
        let d = Self.fileDecoder
        func take<T: SyncEntity>(_ type: T.Type, _ kp: ReferenceWritableKeyPath<TenantStore, [String: T]>) -> Bool {
            if let current = self[keyPath: kp][e.entityId], current.version >= e.version { return false }
            guard let value = try? e.data.decode(T.self, decoder: d), value.id == e.entityId else { return false }
            self[keyPath: kp][e.entityId] = value
            return true
        }
        switch e.entity {
        case Vehicle.entityName: return take(Vehicle.self, \.vehicles)
        case OdometerReading.entityName: return take(OdometerReading.self, \.odometer)
        case FuelEntry.entityName: return take(FuelEntry.self, \.fuel)
        case Maintenance.entityName: return take(Maintenance.self, \.maintenance)
        case MaintenanceItem.entityName: return take(MaintenanceItem.self, \.items)
        case MaintenanceMaterial.entityName: return take(MaintenanceMaterial.self, \.materials)
        case MaterialArticle.entityName: return take(MaterialArticle.self, \.articles)
        case Trip.entityName: return take(Trip.self, \.trips)
        case Place.entityName: return take(Place.self, \.places)
        case Customer.entityName: return take(Customer.self, \.customers)
        case PurposeRule.entityName: return take(PurposeRule.self, \.rules)
        case TaxParam.entityName: return take(TaxParam.self, \.taxParams)
        case Attachment.entityName: return take(Attachment.self, \.attachments)
        case "trip_period":
            if let current = periods[e.entityId], current.version >= e.version { return false }
            guard let p = try? e.data.decode(TripPeriod.self, decoder: d), p.id == e.entityId else { return false }
            periods[p.id] = p
            return true
        default:
            return false
        }
    }

    /// Lokaler Monatsabschluss: Fahrten sperren (Namen eingefroren) und Abschluss anlegen – je ein Journal-
    /// Eintrag. Die Prüfungen macht `closeMonthLocally`.
    func applyLocalClose(lockedTrips: [Trip], period: TripPeriod, reason: String?) {
        guard isLocal, canWrite else { return }
        performBatch {
            for var t in lockedTrips {
                t.version = (trips[t.id]?.version ?? 0) + 1
                t.deleted = false
                trips[t.id] = t
                journalRecord(Trip.entityName, t.id, version: t.version, action: "update", value: t, reason: nil)
            }
            let previous = periods[period.id]
            for (key, old) in periods where old.vehicleId == period.vehicleId && old.month == period.month
                && key != period.id {
                periods.removeValue(forKey: key)
            }
            periods[period.id] = period
            journalRecord("trip_period", period.id, version: period.version,
                          action: previous == nil ? "create" : "update", value: period,
                          reason: Self.cleanReason(reason))
        }
        flush()
    }

    /// Lokalmodus: gesamten Bestand ersetzen (Import einer Sicherung bzw. Übernahme eines Server-Stands).
    /// `journal` = Einträge der Sicherung (bereits geprüft); `nil` → neues Journal mit je einem Eintrag
    /// „create“ (bzw. „delete“ für stornierte Objekte) pro Objekt, Begründung `reason`.
    func replaceLocalContent(_ snap: Snapshot, journal entries: [JournalEntry]?, reason: String?) throws {
        guard isLocal, let journal = localJournal else {
            throw APIError(status: 409, message: "Nur im Lokalmodus möglich.")
        }
        var clean = snap
        clean.outbox = []
        clean.pendingBlobs = []
        clean.rejectedOps = []
        clean.cursor = 0
        apply(clean)
        if let entries {
            try journal.replaceAll(entries)
        } else {
            try journal.replaceAll([])
            let why = Self.cleanReason(reason)
            func all<T: SyncEntity>(_ dict: [String: T]) {
                for e in dict.values.sorted(by: { $0.id < $1.id }) {
                    journalRecord(T.entityName, e.id, version: e.version, action: e.deleted ? "delete" : "create",
                                  value: e, reason: why)
                }
            }
            performBatch {
                all(vehicles); all(customers); all(places); all(rules); all(taxParams); all(articles)
                all(odometer); all(fuel); all(maintenance); all(items); all(materials); all(trips)
                for p in periods.values.sorted(by: { $0.id < $1.id }) {
                    journalRecord("trip_period", p.id, version: p.version, action: "create", value: p, reason: why)
                }
                all(attachments)
            }
        }
        journalCount = journal.count
        journalHead = journal.headHash
        dirty = true
        persist()
        flush()
    }

    /// Bestand als Snapshot (Datenaustausch, Sicherung, Moduswechsel).
    func contentSnapshot() -> Snapshot { makeSnapshot() }

    /// Moduswechsel Lokal → Server: nicht stornierte Objekte des lokalen Stands mit gleichen IDs als Upsert-Ops
    /// in Abhängigkeitsreihenfolge einreihen (Fahrzeuge, Kunden, Orte, Regeln, Materialstamm, km-Stände,
    /// Tankungen, Wartungen, Checkpunkte, Material, Fahrten, Belege). Gesperrte Fahrten gehen als „confirmed“,
    /// Belege zusätzlich in `pendingBlobs`. Steuerparameter und Monatsabschlüsse werden nicht übertragen.
    /// Rückgabe: Anzahl eingereihter Objekte je Entity bzw. übersprungener (`skipped:<entity>`).
    func enqueueMigration(_ snap: Snapshot, attachmentSource: URL? = nil) -> [String: Int] {
        guard !isLocal, canWrite else { return [:] }
        var counts: [String: Int] = [:]
        let liveVehicles = Set(snap.vehicles.values.filter { !$0.deleted }.map(\.id))
        let liveFuel = Set(snap.fuel.values.filter { !$0.deleted && liveVehicles.contains($0.vehicleId) }.map(\.id))
        let liveMaintenance = Set(snap.maintenance.values.filter { !$0.deleted && liveVehicles.contains($0.vehicleId) }
            .map(\.id))
        func send<T: SyncEntity>(_ list: [T], _ kp: ReferenceWritableKeyPath<TenantStore, [String: T]>,
                                 valid: (T) -> Bool = { _ in true }, transform: (T) -> T = { $0 }) {
            for e in list where !e.deleted {
                guard valid(e) else {
                    counts["skipped:" + T.entityName, default: 0] += 1
                    continue
                }
                upsert(transform(e), in: kp)
                counts[T.entityName, default: 0] += 1
            }
        }
        func byId<T: SyncEntity>(_ d: [String: T]) -> [T] { d.values.sorted { $0.id < $1.id } }
        performBatch {
            send(snap.vehicles.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }, \.vehicles)
            send(byId(snap.customers ?? [:]), \.customers)
            send(byId(snap.places ?? [:]), \.places)
            send((snap.rules ?? [:]).values.sorted { ($0.priority, $0.id) < ($1.priority, $1.id) }, \.rules,
                 valid: { $0.vehicleId.map { liveVehicles.contains($0) } ?? true })
            send(byId(snap.articles ?? [:]), \.articles, valid: { $0.vehicleId.map { liveVehicles.contains($0) } ?? true })
            send(snap.odometer.values.sorted { ($0.date, $0.id) < ($1.date, $1.id) }, \.odometer,
                 valid: { liveVehicles.contains($0.vehicleId) })
            send(snap.fuel.values.sorted { ($0.date, $0.id) < ($1.date, $1.id) }, \.fuel,
                 valid: { liveVehicles.contains($0.vehicleId) })
            send(snap.maintenance.values.sorted { ($0.date, $0.id) < ($1.date, $1.id) }, \.maintenance,
                 valid: { liveVehicles.contains($0.vehicleId) })
            send(snap.items.values.sorted { ($0.maintenanceId, $0.position, $0.id) < ($1.maintenanceId, $1.position, $1.id) },
                 \.items, valid: { liveMaintenance.contains($0.maintenanceId) })
            send((snap.materials ?? [:]).values.sorted {
                ($0.maintenanceId, $0.position, $0.id) < ($1.maintenanceId, $1.position, $1.id)
            }, \.materials, valid: { liveMaintenance.contains($0.maintenanceId) })
            send((snap.trips ?? [:]).values.sorted(by: Self.chronological), \.trips,
                 valid: { liveVehicles.contains($0.vehicleId) },
                 transform: { t in
                     var e = t.privacySanitized
                     if e.status == "locked" { e.status = "confirmed" }
                     return e
                 })
            let attachmentList = byId(snap.attachments ?? [:])
            send(attachmentList, \.attachments, valid: { a in
                if let f = a.fuelId { return liveFuel.contains(f) }
                if let m = a.maintenanceId { return liveMaintenance.contains(m) }
                return a.vehicleId.map { liveVehicles.contains($0) } ?? false
            })
            for a in attachmentList where !a.deleted && attachments[a.id] != nil && !pendingBlobs.contains(a.id) {
                // Datei in die Ablage des Servermodus kopieren (Upload nach dem Sync der Metadaten)
                if !AttachmentFiles.exists(a.id, directory: AttachmentFiles.directory),
                   let data = AttachmentFiles.read(a.id, directory: attachmentSource) ?? AttachmentFiles.read(a.id) {
                    try? AttachmentFiles.write(data, id: a.id)
                }
                if AttachmentFiles.exists(a.id) { pendingBlobs.append(a.id) }
            }
        }
        return counts
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
        if isLocal {
            rebuildDemoJournal()
            return
        }
        outbox = pending.map { PendingOp(entity: FuelEntry.entityName, entityId: $0.id, action: "upsert",
                                         baseVersion: nil, data: nil, clientTs: "") }
        lastSync = Date().addingTimeInterval(-600)
    }

    /// Demo im Lokalmodus: Journal aus dem gesetzten Bestand neu aufbauen (Integritätsprüfung meldet intakt).
    private func rebuildDemoJournal() {
        try? replaceLocalContent(makeSnapshot(), journal: nil, reason: "Demo-Daten")
    }

    func demoSeedTrips(trips t: [Trip], places p: [Place], customers c: [Customer], rules r: [PurposeRule],
                       taxParams tp: [TaxParam], periods pe: [TripPeriod]) {
        trips = Dictionary(uniqueKeysWithValues: t.map { ($0.id, $0) })
        places = Dictionary(uniqueKeysWithValues: p.map { ($0.id, $0) })
        customers = Dictionary(uniqueKeysWithValues: c.map { ($0.id, $0) })
        rules = Dictionary(uniqueKeysWithValues: r.map { ($0.id, $0) })
        taxParams = Dictionary(uniqueKeysWithValues: tp.map { ($0.id, $0) })
        periods = Dictionary(uniqueKeysWithValues: pe.map { ($0.id, $0) })
        if isLocal { rebuildDemoJournal() }
    }

    /// Demo-Beleg: Datei lokal ablegen, ohne Outbox/Upload.
    func demoAddAttachment(_ a: Attachment, data: Data) {
        try? AttachmentFiles.write(data, id: a.id, directory: attachmentDirectory)
        attachments[a.id] = a
        if isLocal { rebuildDemoJournal() }
    }
    #endif

    // MARK: Persistenz

    /// Inhalt der Mandantendatei. Neue Felder optional, damit ältere Dateien weiter laden.
    struct Snapshot: Codable {
        /// Format der Datei (2 = mit abgelehnten Änderungen/Begründungen)
        var schemaVersion: Int?
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
        /// Belege – optional, damit Dateien älterer App-Versionen weiter laden
        var attachments: [String: Attachment]?
        var pendingBlobs: [String]?
        var rejectedOps: [RejectedOp]?
        var outbox: [PendingOp]
        var cursor: Int
        var lastSync: Date?
    }

    static let schemaVersion = 2

    static var fileEncoder: JSONEncoder { StoreFiles.encoder }
    static var fileDecoder: JSONDecoder { StoreFiles.decoder }

    private func makeSnapshot() -> Snapshot {
        // Achtung: `lastSync` wird im Format yyyy-MM-dd gespeichert (dateEncodingStrategy) – wie bisher.
        Snapshot(schemaVersion: Self.schemaVersion,
                 vehicles: vehicles, odometer: odometer, fuel: fuel, maintenance: maintenance,
                 items: items, materials: materials, articles: articles,
                 trips: trips, places: places, customers: customers, rules: rules,
                 taxParams: taxParams, periods: periods,
                 attachments: attachments, pendingBlobs: pendingBlobs, rejectedOps: rejectedOps,
                 outbox: outbox, cursor: cursor, lastSync: lastSync)
    }

    /// Persistenz anstossen (gebündelt, ~300 ms).
    private func persist() {
        dirty = true
        guard !persistBlocked, batchDepth == 0 else { return }
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.persistDelay)
            guard !Task.isCancelled, let self else { return }
            self.persistTask = nil
            self.write(synchronously: false)
        }
    }

    /// Lokale Datei noch gesperrt (Start im Hintergrund bei gesperrtem Gerät) – Änderungen nur im Speicher.
    var isPersistenceBlocked: Bool { persistBlocked }

    /// Sofort schreiben (App geht in den Hintergrund, nach einer automatisch erkannten Fahrt, vor dem Abmelden).
    func flush() {
        persistTask?.cancel()
        persistTask = nil
        if persistBlocked { reloadIfBlocked() }
        localJournal?.flush()
        guard dirty, !persistBlocked else { return }
        write(synchronously: true)
    }

    /// Kodieren und Schreiben auf der Schreib-Queue; nur wenn der Speicher nicht inzwischen gelöscht wurde.
    private func write(synchronously: Bool) {
        guard gate.isCurrent(generation) else { return }
        dirty = false
        let report = ErrorSink { [weak self] message in self?.syncError = message }
        StoreFiles.write(makeSnapshot(), to: fileURL, generation: generation, synchronously: synchronously,
                         report: report, gate: gate, excludeFromBackup: !isLocal)
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // Datei vorhanden, aber nicht lesbar (z. B. Start im Hintergrund bei gesperrtem Gerät):
            // nichts überschreiben, nach dem Entsperren erneut laden.
            persistBlocked = true
            storeLoadIssue = "Lokale Daten sind noch gesperrt (Gerät gesperrt?) – sie werden nach dem Entsperren geladen."
            return
        }
        do {
            let snap = try Self.fileDecoder.decode(Snapshot.self, from: data)
            apply(snap)
        } catch {
            let backup = quarantineFile()
            cursor = 0
            storeLoadIssue = "Die lokale Datei konnte nicht gelesen werden"
                + (backup.map { " und wurde als «\($0)» gesichert" } ?? "")
                + (isLocal ? ". Die Daten werden aus dem lokalen Journal wiederhergestellt."
                   : ". Die Daten werden neu vom Server geladen; nicht synchronisierte Änderungen sind in der Sicherung enthalten.")
        }
    }

    private func apply(_ snap: Snapshot) {
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
        attachments = snap.attachments ?? [:]
        pendingBlobs = snap.pendingBlobs ?? []
        rejectedOps = snap.rejectedOps ?? []
        outbox = snap.outbox
        // Datei ohne Material, Materialstamm, Fahrtenbuch bzw. Belege (ältere App-Version): ab 0 holen,
        // damit bereits erfasste Positionen/Artikel/Fahrten/Belege ankommen
        cursor = (snap.materials == nil || snap.articles == nil || snap.trips == nil || snap.attachments == nil)
            ? 0 : snap.cursor
        lastSync = snap.lastSync
    }

    /// Defekte Datei als `<slug>.corrupt-<datum>.json` sichern (nie still überschreiben). Rückgabe: Dateiname.
    private func quarantineFile() -> String? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(tenant.slug).corrupt-\(f.string(from: Date())).json"
        let target = fileURL.deletingLastPathComponent().appending(path: name)
        do {
            try FileManager.default.moveItem(at: fileURL, to: target)
            return name
        } catch {
            return nil
        }
    }

    /// Nach dem Entsperren: Datei laden und die zwischenzeitlich (nur im Speicher) erfassten Änderungen
    /// darüberlegen, statt die Datei zu überschreiben.
    func reloadIfBlocked() {
        if let journal = localJournal, journal.isBlocked {
            journal.reloadIfBlocked()
            journalCount = journal.count
            journalHead = journal.headHash
        }
        guard persistBlocked else { return }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let memory = makeSnapshot()
        persistBlocked = false
        storeLoadIssue = nil
        do {
            let snap = try Self.fileDecoder.decode(Snapshot.self, from: data)
            apply(snap)
        } catch {
            let backup = quarantineFile()
            cursor = 0
            storeLoadIssue = "Die lokale Datei konnte nicht gelesen werden"
                + (backup.map { " und wurde als «\($0)» gesichert" } ?? "") + "."
        }
        // Während der Sperre erfasste Änderungen übernehmen
        for op in memory.outbox where !outbox.contains(where: { $0.opId == op.opId }) {
            copyEntity(op.entity, op.entityId, from: memory)
            outbox.append(op)
        }
        for id in memory.pendingBlobs ?? [] where !pendingBlobs.contains(id) { pendingBlobs.append(id) }
        if isLocal { recoverFromJournal() }   // Lokalmodus: Journal enthält die zwischenzeitlichen Änderungen
        persist()
    }

    private func copyEntity(_ entity: String, _ id: String, from m: Snapshot) {
        switch entity {
        case Vehicle.entityName: vehicles[id] = m.vehicles[id] ?? vehicles[id]
        case OdometerReading.entityName: odometer[id] = m.odometer[id] ?? odometer[id]
        case FuelEntry.entityName: fuel[id] = m.fuel[id] ?? fuel[id]
        case Maintenance.entityName: maintenance[id] = m.maintenance[id] ?? maintenance[id]
        case MaintenanceItem.entityName: items[id] = m.items[id] ?? items[id]
        case MaintenanceMaterial.entityName: materials[id] = m.materials?[id] ?? materials[id]
        case MaterialArticle.entityName: articles[id] = m.articles?[id] ?? articles[id]
        case Trip.entityName: trips[id] = m.trips?[id] ?? trips[id]
        case Place.entityName: places[id] = m.places?[id] ?? places[id]
        case Customer.entityName: customers[id] = m.customers?[id] ?? customers[id]
        case PurposeRule.entityName: rules[id] = m.rules?[id] ?? rules[id]
        case TaxParam.entityName: taxParams[id] = m.taxParams?[id] ?? taxParams[id]
        case Attachment.entityName: attachments[id] = m.attachments?[id] ?? attachments[id]
        default: break
        }
    }

    /// App geht in den Hintergrund/wird beendet → sofort schreiben; Daten wieder zugänglich → ggf. laden.
    /// (Namen der UIKit-Benachrichtigungen als Text, damit der Store ohne UIKit testbar bleibt.)
    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        for name in ["UIApplicationDidEnterBackgroundNotification", "UIApplicationWillTerminateNotification",
                     "UIApplicationWillResignActiveNotification"] {
            observers.add(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            })
        }
        observers.add(center.addObserver(forName: Notification.Name("UIApplicationProtectedDataDidBecomeAvailable"),
                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.persistBlocked || self.localJournal?.isBlocked == true {
                    self.reloadIfBlocked()
                    Task { await self.sync() }
                }
                // Entsperrt: während der Sperre zurückgestellte Journal-Zeilen sofort anhängen (Q8)
                self.localJournal?.flush()
            }
        })
    }

    static func directory() -> URL {
        let dir = StoreFiles.defaultDirectory
        try? StoreFiles.ensureDirectory(dir)
        return dir
    }

    /// Ablage des Lokalmodus (`Application Support/Lokal`, im Geräte-Backup enthalten).
    static func localDirectory() -> URL {
        let dir = StoreFiles.localDirectory
        try? StoreFiles.ensureDirectory(dir, excludeFromBackup: false)
        return dir
    }

    /// Lokale Daten (Lokalmodus) vorhanden?
    static func hasLocalData(directory: URL? = nil) -> Bool {
        let dir = directory ?? StoreFiles.localDirectory
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appending(path: "\(LocalIdentity.slug).json").path)
            || fm.fileExists(atPath: dir.appending(path: "journal.jsonl").path)
    }

    /// Lokale Daten (Lokalmodus) endgültig löschen; laufende lokale Stores schreiben danach nicht mehr.
    static func deleteLocalData(directory: URL? = nil) {
        StoreFiles.deleteLocal(directory: directory)
    }

    static func fileURL(for slug: String) -> URL {
        directory().appending(path: "\(slug).json")
    }

    /// Löscht alle lokalen Mandantendaten (Abmelden / Serverwechsel). Laufende Stores schreiben danach nicht mehr.
    static func deleteAll() {
        StoreFiles.deleteAll()
        AttachmentFiles.deleteAll()
    }

    /// Anzahl unsynchronisierter Änderungen über alle Mandanten (für Warnung beim Abmelden).
    /// Vorher `flush()` des geöffneten Stores aufrufen, damit der aktuelle Stand auf der Platte liegt.
    static func pendingCountOnDisk() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory(), includingPropertiesForKeys: nil)) ?? []
        return files.reduce(0) { sum, url in
            guard url.pathExtension == "json", !url.lastPathComponent.contains(".corrupt-"),
                  let data = try? Data(contentsOf: url),
                  let snap = try? fileDecoder.decode(Snapshot.self, from: data) else { return sum }
            return sum + snap.outbox.count + (snap.pendingBlobs?.count ?? 0)
        }
    }

    // MARK: Hilfen

    private static func now() -> String {
        ISODate.string(Date())
    }

    private static let shortDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_CH")
        f.dateFormat = "dd.MM."
        return f
    }()

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
        case Attachment.entityName: "Beleg"
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
        if let api = error as? APIError, (500...599).contains(api.status) {
            return "Server vorübergehend nicht erreichbar – Änderungen werden später übertragen."
        }
        return error.userMessage
    }
}

// MARK: - Hilfstypen

/// Abgeleitete Fahrtenlisten je Fahrzeug (ungültig bei jeder Änderung an `trips`).
private struct TripCache {
    var chain: [String: [Trip]] = [:]
    var newestFirst: [String: [Trip]] = [:]
    var review: [String: [Trip]] = [:]
    var gaps: [String: [TripGap]] = [:]

    mutating func invalidate() {
        chain.removeAll(keepingCapacity: true)
        newestFirst.removeAll(keepingCapacity: true)
        review.removeAll(keepingCapacity: true)
        gaps.removeAll(keepingCapacity: true)
    }
}

/// Schreiben der Mandantendateien auf einer seriellen Queue (nicht auf dem Main-Actor).
enum StoreFiles {
    /// Seriell für alle Mandantendateien (auch `deleteAll`, damit danach nichts nachgeschrieben wird)
    static let queue = DispatchQueue(label: "fahrzeugbuch.store.write", qos: .utility)

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .formatted(APIClient.dayFormatter)
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .formatted(APIClient.dayFormatter)
        return d
    }()

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Mandanten", directoryHint: .isDirectory)
    }

    /// Lokalmodus: `Application Support/Lokal` (Mandantendatei, Journal, Belege) – im Geräte-Backup enthalten
    static var localDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Lokal", directoryHint: .isDirectory)
    }

    /// Schreiboptionen der Mandanten-/Journaldateien (Dateischutz „completeUnlessOpen“)
    static var writeOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtectionUnlessOpen]
        #else
        return [.atomic]
        #endif
    }

    /// Exporte (PDF/CSV/Sicherung): Dateischutz „complete“
    static var exportOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtection]
        #else
        return [.atomic]
        #endif
    }

    static func write(_ snapshot: TenantStore.Snapshot, to url: URL, generation: Int, synchronously: Bool,
                      report: ErrorSink, gate: StorageGate = .shared, excludeFromBackup: Bool = true) {
        if synchronously {
            queue.sync { perform(snapshot, url, generation, report, gate, excludeFromBackup) }
        } else {
            queue.async { perform(snapshot, url, generation, report, gate, excludeFromBackup) }
        }
    }

    private static func perform(_ snapshot: TenantStore.Snapshot, _ url: URL, _ generation: Int, _ report: ErrorSink,
                                _ gate: StorageGate, _ excludeFromBackup: Bool) {
        guard gate.isCurrent(generation) else { return }
        do {
            let data = try encoder.encode(snapshot)
            try ensureDirectory(url.deletingLastPathComponent(), excludeFromBackup: excludeFromBackup)
            try data.write(to: url, options: writeOptions)
        } catch {
            report.send("Lokales Speichern fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    /// Verzeichnis anlegen. Servermodus: nicht ins iCloud-/Finder-Backup (Kopie des Servers, enthält u. a.
    /// Wohnort-Koordinaten). Lokalmodus: im Backup (einzige Kopie der Daten → Datenverlust vermeiden).
    static func ensureDirectory(_ dir: URL, excludeFromBackup: Bool = true) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var target = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = excludeFromBackup
        try? target.setResourceValues(values)
    }

    /// Lokale Daten löschen; erhöht die lokale Generation (laufende lokale Stores schreiben nicht mehr).
    static func deleteLocal(directory: URL? = nil) {
        let dir = directory ?? localDirectory
        queue.sync {
            StorageGate.local.bump()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Alle Mandantendateien löschen; erhöht die Generation (laufende Stores schreiben nicht mehr).
    static func deleteAll() {
        let dir = defaultDirectory
        queue.sync {
            StorageGate.shared.bump()
            try? FileManager.default.removeItem(at: dir)
        }
    }
}

/// Generation des lokalen Speichers: `deleteAll()` erhöht sie, ältere Stores schreiben danach nicht mehr.
final class StorageGate: @unchecked Sendable {
    /// Servermodus (Mandantendateien)
    static let shared = StorageGate()
    /// Lokalmodus (eigene Generation: Abmelden vom Server löscht nie lokale Daten)
    static let local = StorageGate()
    private let lock = NSLock()
    private var value = 0

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func isCurrent(_ generation: Int) -> Bool { current == generation }

    func bump() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

/// Fehler von der Schreib-Queue auf den Main-Actor melden.
final class ErrorSink: @unchecked Sendable {
    private let handler: @MainActor (String) -> Void

    init(_ handler: @escaping @MainActor (String) -> Void) {
        self.handler = handler
    }

    func send(_ message: String) {
        let handler = handler
        Task { @MainActor in handler(message) }
    }
}

/// Hält NotificationCenter-Beobachter und entfernt sie beim Freigeben des Stores.
private final class ObserverBag {
    private var tokens: [NSObjectProtocol] = []

    func add(_ token: NSObjectProtocol) { tokens.append(token) }

    deinit {
        for t in tokens { NotificationCenter.default.removeObserver(t) }
    }
}
