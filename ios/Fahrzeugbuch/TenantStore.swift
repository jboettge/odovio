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

    func maintenance(id: String) -> Maintenance? { maintenance[id] }
    func vehicle(id: String) -> Vehicle? { vehicles[id] }

    func stats(for v: Vehicle) -> VehicleStats {
        StatsCalculator.stats(vehicle: v, odometer: odometer(for: v.id), fuel: fuel(for: v.id),
                              maintenance: maintenance(for: v.id))
    }

    func currentKm(_ v: Vehicle) -> Int {
        StatsCalculator.currentKm(vehicle: v, odometer: odometer(for: v.id), fuel: fuel(for: v.id),
                                  maintenance: maintenance(for: v.id))
    }

    func isPending(_ id: String) -> Bool { outbox.contains { $0.entityId == id } }

    // MARK: Schreiben (offline)

    func save(_ v: Vehicle) { upsert(v, in: \.vehicles) }
    func delete(_ v: Vehicle) { remove(v, in: \.vehicles) }
    func save(_ o: OdometerReading) { upsert(o, in: \.odometer) }
    func delete(_ o: OdometerReading) { remove(o, in: \.odometer) }
    func save(_ f: FuelEntry) { upsert(f, in: \.fuel) }
    func delete(_ f: FuelEntry) { remove(f, in: \.fuel) }
    func delete(_ m: Maintenance) { remove(m, in: \.maintenance) }

    /// Wartung inkl. Checkliste speichern; entfernte Punkte werden storniert.
    func save(_ m: Maintenance, items newItems: [MaintenanceItem]) {
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
        let ch: ChangesResponse = try await apiProvider().get(
            "api/t/\(tenant.slug)/changes", query: [URLQueryItem(name: "since", value: String(since))])
        if full {
            vehicles = vehicles.filter { isPending($0.key) }
            odometer = odometer.filter { isPending($0.key) }
            fuel = fuel.filter { isPending($0.key) }
            maintenance = maintenance.filter { isPending($0.key) }
            items = items.filter { isPending($0.key) }
        }
        merge(ch.vehicles, into: \.vehicles)
        merge(ch.odometer, into: \.odometer)
        merge(ch.fuel, into: \.fuel)
        merge(ch.maintenance, into: \.maintenance)
        merge(ch.maintenanceItems, into: \.items)
        cursor = ch.cursor
    }

    private func merge<T: SyncEntity>(_ list: [T], into kp: ReferenceWritableKeyPath<TenantStore, [String: T]>) {
        guard !list.isEmpty else { return }
        var dict = self[keyPath: kp]
        for e in list where !isPending(e.id) { dict[e.id] = e }
        self[keyPath: kp] = dict
    }

    private func setVersion(_ entity: String, _ id: String, _ v: Int) {
        guard !isPending(id) else { return }
        switch entity {
        case Vehicle.entityName: vehicles[id]?.version = v
        case OdometerReading.entityName: odometer[id]?.version = v
        case FuelEntry.entityName: fuel[id]?.version = v
        case Maintenance.entityName: maintenance[id]?.version = v
        case MaintenanceItem.entityName: items[id]?.version = v
        default: break
        }
    }

    #if DEBUG
    func demoSeed(vehicles v: [Vehicle], odometer o: [OdometerReading], fuel f: [FuelEntry],
                  maintenance m: [Maintenance], items i: [MaintenanceItem], pending: [FuelEntry]) {
        vehicles = Dictionary(uniqueKeysWithValues: v.map { ($0.id, $0) })
        odometer = Dictionary(uniqueKeysWithValues: o.map { ($0.id, $0) })
        fuel = Dictionary(uniqueKeysWithValues: f.map { ($0.id, $0) })
        maintenance = Dictionary(uniqueKeysWithValues: m.map { ($0.id, $0) })
        items = Dictionary(uniqueKeysWithValues: i.map { ($0.id, $0) })
        outbox = pending.map { PendingOp(entity: FuelEntry.entityName, entityId: $0.id, action: "upsert",
                                         baseVersion: nil, data: nil, clientTs: "") }
        lastSync = Date().addingTimeInterval(-600)
    }
    #endif

    // MARK: Persistenz

    private struct Snapshot: Codable {
        var vehicles: [String: Vehicle]
        var odometer: [String: OdometerReading]
        var fuel: [String: FuelEntry]
        var maintenance: [String: Maintenance]
        var items: [String: MaintenanceItem]
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
                            items: items, outbox: outbox, cursor: cursor, lastSync: lastSync)
        do {
            let data = try Self.fileEncoder.encode(snap)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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
        outbox = snap.outbox
        cursor = snap.cursor
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
