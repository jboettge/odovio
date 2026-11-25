import Foundation

/// Ergebnis eines Imports (bzw. Inhalt einer Sicherung).
struct BackupSummary: Equatable {
    /// Zeitpunkt der Sicherung (ISO-8601)
    var createdAt: String
    /// Anzahl Objekte je Entity (inkl. stornierte)
    var counts: [String: Int]
    var journalEntries: Int
    var attachments: Int
    var headHash: String
    var warnings: [String]

    var totalObjects: Int { counts.values.reduce(0, +) }
}

enum BackupError: LocalizedError, Equatable {
    case notLocal
    case invalidFormat(String)
    case unsupportedVersion(Int)
    case journalBroken(String)
    case dataMismatch([String])
    case attachment(String)

    var errorDescription: String? {
        switch self {
        case .notLocal:
            return "Sicherungen sind nur im Lokalmodus möglich."
        case .invalidFormat(let s):
            return "Die Datei ist keine gültige Fahrzeugbuch-Sicherung (\(s))."
        case .unsupportedVersion(let v):
            return "Die Sicherung stammt von einer neueren App-Version (Format \(v)) – bitte die App aktualisieren."
        case .journalBroken(let s):
            return "Das Änderungsprotokoll der Sicherung ist beschädigt oder verändert: \(s)"
        case .dataMismatch(let list):
            return "Die Daten der Sicherung passen nicht zum Änderungsprotokoll: "
                + list.prefix(3).joined(separator: "; ") + (list.count > 3 ? " …" : "")
        case .attachment(let s):
            return "Beleg in der Sicherung fehlerhaft: \(s)"
        }
    }
}

/// Datensicherung des Lokalmodus als **eine** JSON-Datei `Fahrzeugbuch_Sicherung_<datum>.json`:
/// Formatversion, alle Objekte (Format der Mandantendatei), Journal (Hash-Kette), Belege als Base64.
/// Import prüft Format, Journal-Kette, Abgleich Daten ↔ Journal und Prüfsummen der Belege und ersetzt dann den
/// lokalen Bestand (der bisherige Stand wird vorher unter `Lokal/Archiv/<datum>/` abgelegt).
@MainActor
enum LocalBackup {
    static let format = "fahrzeugbuch-sicherung"
    static let schemaVersion = 1

    // MARK: Export

    static func exportBackup(store: TenantStore) throws -> URL {
        let data = try backupData(store: store)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = LogbookRules.timeZone
        f.dateFormat = "yyyy-MM-dd_HHmm"
        return try LocalReports.writeExport(data, name: "Fahrzeugbuch_Sicherung_\(f.string(from: Date()))", ext: "json")
    }

    static func backupData(store: TenantStore, now: Date = Date()) throws -> Data {
        guard store.isLocal, let journal = store.localJournal else { throw BackupError.notLocal }
        store.flush()
        let snap = store.contentSnapshot()
        let content = try JSONNode.from(snap, encoder: TenantStore.fileEncoder)
        var blobs: [String: JSONNode] = [:]
        for a in snap.attachments?.values.sorted(by: { $0.id < $1.id }) ?? [] {
            if let d = AttachmentFiles.read(a.id, directory: store.attachmentDirectory) {
                blobs[a.id] = .string(d.base64EncodedString())
            }
        }
        let root: JSONNode = .object([
            "format": .string(format),
            "schema_version": .int(Int64(schemaVersion)),
            "store_schema_version": .int(Int64(TenantStore.schemaVersion)),
            "created_at": .string(LocalJournal.timestamp(now)),
            "data": content,
            "journal": .array(journal.entries.map(\.node)),
            "journal_head": .string(journal.headHash),
            "attachments": .object(blobs),
        ])
        return root.canonicalData
    }

    // MARK: Prüfen

    struct Parsed {
        var snapshot: TenantStore.Snapshot
        var journal: [JournalEntry]
        var blobs: [String: Data]
        var summary: BackupSummary
    }

    /// Sicherung lesen und vollständig prüfen (ohne etwas zu verändern).
    static func parse(_ data: Data) throws -> Parsed {
        guard let root = try? JSONNode.parse(data), root.objectValue != nil else {
            throw BackupError.invalidFormat("kein JSON-Objekt")
        }
        guard root["format"]?.stringValue == format else { throw BackupError.invalidFormat("Kennung fehlt") }
        guard let version = root["schema_version"]?.intValue else { throw BackupError.invalidFormat("Version fehlt") }
        guard version <= schemaVersion else { throw BackupError.unsupportedVersion(version) }
        guard let content = root["data"],
              let snap = try? content.decode(TenantStore.Snapshot.self, decoder: TenantStore.fileDecoder) else {
            throw BackupError.invalidFormat("Daten nicht lesbar")
        }
        let nodes = root["journal"]?.arrayValue ?? []
        var entries: [JournalEntry] = []
        for (n, node) in nodes.enumerated() {
            guard let e = JournalEntry(node: node) else { throw BackupError.journalBroken("Eintrag \(n + 1) nicht lesbar") }
            entries.append(e)
        }
        let (chain, _) = LocalJournal.verify(entries: entries)
        guard chain.ok else { throw BackupError.journalBroken(chain.problems.prefix(3).joined(separator: "; ")) }
        if let head = root["journal_head"]?.stringValue, head != chain.headHash {
            throw BackupError.journalBroken("Kettenkopf stimmt nicht mit der Sicherung überein")
        }
        let mismatches = TenantStore.recordMismatches(snap, entries)
        guard mismatches.isEmpty else { throw BackupError.dataMismatch(mismatches) }

        var blobs: [String: Data] = [:]
        var warnings: [String] = []
        for (id, node) in root["attachments"]?.objectValue ?? [:] {
            guard AttachmentFiles.isValidId(id), let b64 = node.stringValue,
                  let d = Data(base64Encoded: b64) else { throw BackupError.attachment("Datei \(id.prefix(8)) nicht lesbar") }
            guard let meta = snap.attachments?[id] else {
                warnings.append("Beleg-Datei ohne Beleg ignoriert (\(id.prefix(8))).")
                continue
            }
            guard AttachmentFiles.sha256(d) == meta.sha256.lowercased() else {
                throw BackupError.attachment("Prüfsumme von Beleg \(id.prefix(8)) stimmt nicht")
            }
            blobs[id] = d
        }
        let missing = (snap.attachments ?? [:]).values.filter { !$0.deleted && blobs[$0.id] == nil }.count
        if missing > 0 { warnings.append("\(missing) Beleg(e) ohne Datei in der Sicherung.") }

        let summary = BackupSummary(createdAt: root["created_at"]?.stringValue ?? "", counts: counts(snap),
                                    journalEntries: entries.count, attachments: blobs.count,
                                    headHash: chain.headHash, warnings: warnings)
        return Parsed(snapshot: snap, journal: entries, blobs: blobs, summary: summary)
    }

    static func counts(_ s: TenantStore.Snapshot) -> [String: Int] {
        var c: [String: Int] = [
            Vehicle.entityName: s.vehicles.count, OdometerReading.entityName: s.odometer.count,
            FuelEntry.entityName: s.fuel.count, Maintenance.entityName: s.maintenance.count,
            MaintenanceItem.entityName: s.items.count, MaintenanceMaterial.entityName: s.materials?.count ?? 0,
            MaterialArticle.entityName: s.articles?.count ?? 0, Trip.entityName: s.trips?.count ?? 0,
            Place.entityName: s.places?.count ?? 0, Customer.entityName: s.customers?.count ?? 0,
            PurposeRule.entityName: s.rules?.count ?? 0, TaxParam.entityName: s.taxParams?.count ?? 0,
            "trip_period": s.periods?.count ?? 0, Attachment.entityName: s.attachments?.count ?? 0,
        ]
        c = c.filter { $0.value > 0 }
        return c
    }

    // MARK: Import

    /// Sicherung in einen lokalen Store einspielen (ersetzt dessen Bestand; vorheriger Stand → Archiv).
    @discardableResult
    static func importBackup(from url: URL, into store: TenantStore) throws -> BackupSummary {
        guard store.isLocal else { throw BackupError.notLocal }
        #if os(iOS) || os(macOS)
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        #endif
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BackupError.invalidFormat("Datei nicht lesbar")
        }
        let parsed = try parse(data)
        store.flush()
        archiveCurrent(store)
        if let dir = store.attachmentDirectory { try? FileManager.default.removeItem(at: dir) }
        for (id, blob) in parsed.blobs {
            try AttachmentFiles.write(blob, id: id, directory: store.attachmentDirectory)
        }
        try store.replaceLocalContent(parsed.snapshot, journal: parsed.journal, reason: nil)
        return parsed.summary
    }

    /// Bisherige lokale Dateien (Mandantendatei, Journal, Belege) nach `Archiv/<datum>/` kopieren.
    static func archiveCurrent(_ store: TenantStore) {
        guard let journal = store.localJournal else { return }
        let dir = journal.fileURL.deletingLastPathComponent()
        let fm = FileManager.default
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let target = dir.appending(path: "Archiv", directoryHint: .isDirectory)
            .appending(path: f.string(from: Date()), directoryHint: .isDirectory)
        let names = ["\(store.tenant.slug).json", "journal.jsonl", "Belege"]
        guard names.contains(where: { fm.fileExists(atPath: dir.appending(path: $0).path) }) else { return }
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        for name in names where fm.fileExists(atPath: dir.appending(path: name).path) {
            try? fm.copyItem(at: dir.appending(path: name), to: target.appending(path: name))
        }
    }
}

extension TenantStore {
    /// Abgleich letzter Journal-Stand ↔ Datensätze eines Snapshots.
    static func recordMismatches(_ snap: Snapshot, _ entries: [JournalEntry]) -> [String] {
        var latest: [String: JournalEntry] = [:]
        for e in entries { latest[e.key] = e }
        var problems: [String] = []
        var seen = Set<String>()
        let enc = fileEncoder

        func check<T: Encodable>(_ entity: String, _ id: String, _ value: T) {
            let key = "\(entity)|\(id)"
            seen.insert(key)
            let label = "\(entityLabel(entity)) \(id.prefix(8))"
            guard let last = latest[key] else {
                problems.append("\(label): Datensatz ohne Journal-Eintrag")
                return
            }
            guard let node = try? JSONNode.from(value, encoder: enc), node.canonical == last.data.canonical else {
                problems.append("\(label): Datensatz weicht vom letzten Journal-Stand (Eintrag \(last.seq)) ab")
                return
            }
        }
        func all<T: SyncEntity>(_ dict: [String: T]?) {
            for (id, v) in dict ?? [:] { check(T.entityName, id, v) }
        }
        all(snap.vehicles); all(snap.odometer); all(snap.fuel); all(snap.maintenance); all(snap.items)
        all(snap.materials); all(snap.articles); all(snap.trips); all(snap.places); all(snap.customers)
        all(snap.rules); all(snap.taxParams); all(snap.attachments)
        for (id, p) in snap.periods ?? [:] { check("trip_period", id, p) }
        for (key, e) in latest where !seen.contains(key) {
            problems.append("\(entityLabel(e.entity)) \(e.entityId.prefix(8)): im Journal (Eintrag \(e.seq)), "
                            + "Datensatz fehlt")
        }
        return problems.sorted()
    }
}
