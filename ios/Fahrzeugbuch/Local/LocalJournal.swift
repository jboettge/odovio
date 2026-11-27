import Foundation

/// Eintrag im lokalen Journal (eine Zeile der JSON-Lines-Datei).
///
/// Zeile = kanonisches JSON `{action, actor?, at, data, entity, entity_id, hash, prev_hash, reason?, seq, version}`.
/// `hash` = SHA-256 (hex) der kanonischen Darstellung desselben Objekts **ohne** `hash`;
/// `prev_hash` = `hash` des Vorgängers (erster Eintrag: 64 × „0“). `data` = vollständiger Stand des Objekts
/// nach der Änderung (Format der Mandantendatei, inkl. `deleted`).
struct JournalEntry: Hashable {
    static let genesisHash = String(repeating: "0", count: 64)

    var seq: Int
    /// ISO-8601 (UTC)
    var at: String
    var entity: String
    var entityId: String
    var version: Int
    /// create | update | delete | close
    var action: String
    var data: JSONNode
    var reason: String?
    var actor: String?
    var prevHash: String
    var hash: String

    /// Objekt ohne `hash` (Grundlage der Prüfsumme).
    var unsignedNode: JSONNode {
        var o: [String: JSONNode] = [
            "seq": .int(Int64(seq)), "at": .string(at), "entity": .string(entity), "entity_id": .string(entityId),
            "version": .int(Int64(version)), "action": .string(action), "data": data, "prev_hash": .string(prevHash),
        ]
        if let reason { o["reason"] = .string(reason) }
        if let actor { o["actor"] = .string(actor) }
        return .object(o)
    }

    var node: JSONNode {
        guard case .object(var o) = unsignedNode else { return unsignedNode }
        o["hash"] = .string(hash)
        return .object(o)
    }

    /// Prüfsumme dieses Eintrags (aus allen Feldern ausser `hash`).
    var computedHash: String { Hashing.sha256Hex(unsignedNode.canonical) }

    /// Eine Zeile der Journal-Datei (kanonisch, ohne Zeilenumbruch).
    var line: String { node.canonical }

    var key: String { "\(entity)|\(entityId)" }

    init(seq: Int, at: String, entity: String, entityId: String, version: Int, action: String, data: JSONNode,
         reason: String?, actor: String?, prevHash: String, hash: String = "") {
        self.seq = seq
        self.at = at
        self.entity = entity
        self.entityId = entityId
        self.version = version
        self.action = action
        self.data = data
        self.reason = reason
        self.actor = actor
        self.prevHash = prevHash
        self.hash = hash
        if hash.isEmpty { self.hash = computedHash }
    }

    /// Aus einer gelesenen Zeile; `nil` bei fehlenden Pflichtfeldern.
    init?(node: JSONNode) {
        guard let seq = node["seq"]?.intValue, let at = node["at"]?.stringValue,
              let entity = node["entity"]?.stringValue, let id = node["entity_id"]?.stringValue,
              let version = node["version"]?.intValue, let action = node["action"]?.stringValue,
              let data = node["data"], let prev = node["prev_hash"]?.stringValue,
              let hash = node["hash"]?.stringValue else { return nil }
        self.seq = seq
        self.at = at
        self.entity = entity
        self.entityId = id
        self.version = version
        self.action = action
        self.data = data
        self.reason = node["reason"]?.stringValue
        self.actor = node["actor"]?.stringValue
        self.prevHash = prev
        self.hash = hash
    }
}

/// Ergebnis der Prüfung des lokalen Journals (`TenantStore.verifyLocalJournal()`).
struct LocalIntegrity: Equatable {
    var ok: Bool
    /// Anzahl Einträge
    var count: Int
    /// Hash des letzten Eintrags (Kettenkopf); leer ohne Einträge
    var headHash: String
    /// Erste fehlerhafte Zeile (seq bzw. Zeilennummer)
    var brokenAt: Int?
    var problems: [String]

    /// Kurzer Vermerk für Berichte: „Journal geprüft: 123 Einträge, Kettenkopf 3fa9…“.
    var summary: String {
        let head = headHash.isEmpty ? "–" : String(headHash.prefix(16)) + "…"
        if ok { return "Lokales Journal geprüft: \(count) Einträge, Kettenkopf \(head) – unverändert." }
        return "Lokales Journal NICHT in Ordnung (\(problems.count) Problem(e)): "
            + problems.prefix(3).joined(separator: "; ")
    }
}

/// Append-only Journal des Lokalmodus (JSON Lines mit SHA-256-Kette).
///
/// Jede Änderung im Lokalmodus wird als Zeile angehängt (Schreib-Queue der Mandantendateien, Dateischutz
/// „completeUnlessOpen“, **nicht** vom Backup ausgeschlossen). Kann die Datei nicht gelesen werden (Gerät
/// gesperrt), werden neue Einträge zurückgestellt und nach dem Entsperren an die Kette angehängt.
///
/// Gesperrt nach dem Laden (Q8): Die Mandantendatei wird atomar neu geschrieben (neue Datei – erlaubt), das
/// Journal liesse sich aber nicht öffnen. Nicht angehängte Zeilen sichert der Writer deshalb in einer
/// Nebendatei `journal.overflow-<id>.jsonl`; beim nächsten Laden (bzw. Schreiben nach dem Entsperren)
/// werden sie an die Kette angehängt und die Nebendatei entfernt – auch wenn die App inzwischen beendet wurde.
@MainActor
final class LocalJournal {
    let fileURL: URL
    private(set) var entries: [JournalEntry] = []
    /// Probleme beim Laden (defekte Zeilen) – erscheinen in `verify()`
    private(set) var loadProblems: [String] = []
    /// Datei vorhanden, aber nicht lesbar (Gerät gesperrt)
    private(set) var isBlocked = false
    private var deferred: [(entity: String, id: String, version: Int, action: String, data: JSONNode,
                            reason: String?, actor: String?, at: String)] = []
    private let writer: JournalWriter

    init(fileURL: URL, gate: StorageGate) {
        self.fileURL = fileURL
        self.writer = JournalWriter(url: fileURL, gate: gate, generation: gate.current)
        load()
    }

    var headHash: String { entries.last?.hash ?? "" }
    var count: Int { entries.count }
    var lastError: String? { writer.lastError }

    // MARK: Schreiben

    /// Neuen Eintrag anhängen (sofort im Speicher, Datei asynchron auf der Schreib-Queue).
    @discardableResult
    func append(entity: String, entityId: String, version: Int, action: String, data: JSONNode,
                reason: String? = nil, actor: String? = LocalIdentity.actorName, at date: Date = Date()) -> JournalEntry? {
        let at = Self.timestamp(date)
        if isBlocked {
            deferred.append((entity, entityId, version, action, data, reason, actor, at))
            return nil
        }
        let entry = JournalEntry(seq: (entries.last?.seq ?? 0) + 1, at: at, entity: entity, entityId: entityId,
                                 version: version, action: action, data: data, reason: reason, actor: actor,
                                 prevHash: entries.last?.hash ?? JournalEntry.genesisHash)
        entries.append(entry)
        writer.enqueue(Data((entry.line + "\n").utf8))
        return entry
    }

    /// Ausstehende Zeilen sofort schreiben.
    func flush() { writer.flushSynchronously() }

    /// Ganzes Journal ersetzen (Import einer Sicherung, Übernahme eines Server-Stands). Schreibt sofort.
    func replaceAll(_ newEntries: [JournalEntry]) throws {
        deferred = []
        isBlocked = false
        loadProblems = []
        entries = newEntries
        try writer.rewrite(newEntries.map { Data(($0.line + "\n").utf8) })
    }

    /// Nach dem Entsperren: Datei laden und zurückgestellte Einträge an die Kette anhängen.
    func reloadIfBlocked() {
        guard isBlocked else { return }
        load()
        guard !isBlocked else { return }
        let pending = deferred
        deferred = []
        for d in pending {
            let entry = JournalEntry(seq: (entries.last?.seq ?? 0) + 1, at: d.at, entity: d.entity, entityId: d.id,
                                     version: d.version, action: d.action, data: d.data, reason: d.reason,
                                     actor: d.actor, prevHash: entries.last?.hash ?? JournalEntry.genesisHash)
            entries.append(entry)
            writer.enqueue(Data((entry.line + "\n").utf8))
        }
    }

    var hasDeferredEntries: Bool { !deferred.isEmpty }

    // MARK: Lesen

    /// Einträge eines Objekts (älteste zuerst).
    func entries(entity: String, id: String) -> [JournalEntry] {
        entries.filter { $0.entity == entity && $0.entityId == id }
    }

    /// Letzter Eintrag je Objekt („entity|id“).
    func latest() -> [String: JournalEntry] {
        var out: [String: JournalEntry] = [:]
        for e in entries { out[e.key] = e }
        return out
    }

    /// Datei (nicht den Speicherstand) prüfen: Zeilen lesbar, seq fortlaufend, Kette und Prüfsummen.
    func verifyFile() -> (integrity: LocalIntegrity, entries: [JournalEntry]) {
        writer.flushSynchronously()
        if isBlocked {
            return (LocalIntegrity(ok: false, count: entries.count, headHash: headHash, brokenAt: nil,
                                   problems: ["Journal-Datei ist gesperrt (Gerät gesperrt?) – später erneut prüfen."]),
                    entries)
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Self.verify(lines: [])
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return (LocalIntegrity(ok: false, count: 0, headHash: "", brokenAt: nil,
                                   problems: ["Journal-Datei nicht lesbar."]), [])
        }
        return Self.verify(lines: Self.lines(data))
    }

    /// Kette prüfen (auch für Sicherungen). Zeilen = kanonische JSON-Objekte.
    static func verify(lines: [Data]) -> (integrity: LocalIntegrity, entries: [JournalEntry]) {
        var problems: [String] = []
        var brokenAt: Int?
        var parsed: [JournalEntry] = []
        var prev = JournalEntry.genesisHash
        for (n, line) in lines.enumerated() {
            let lineNo = n + 1
            guard let node = try? JSONNode.parse(line), let e = JournalEntry(node: node) else {
                problems.append("Zeile \(lineNo): nicht lesbar")
                brokenAt = brokenAt ?? lineNo
                continue
            }
            if e.seq != parsed.count + 1 {
                problems.append("Eintrag \(e.seq): Nummerierung unterbrochen (erwartet \(parsed.count + 1))")
                brokenAt = brokenAt ?? e.seq
            }
            if e.prevHash != prev {
                problems.append("Eintrag \(e.seq): Verkettung unterbrochen (Vorgänger-Hash passt nicht)")
                brokenAt = brokenAt ?? e.seq
            }
            if e.computedHash != e.hash {
                problems.append("Eintrag \(e.seq): Prüfsumme stimmt nicht (Inhalt verändert)")
                brokenAt = brokenAt ?? e.seq
            }
            prev = e.hash
            parsed.append(e)
        }
        let integrity = LocalIntegrity(ok: problems.isEmpty, count: parsed.count, headHash: parsed.last?.hash ?? "",
                                       brokenAt: brokenAt, problems: problems)
        return (integrity, parsed)
    }

    /// Kette einer Liste von Einträgen prüfen.
    static func verify(entries list: [JournalEntry]) -> (integrity: LocalIntegrity, entries: [JournalEntry]) {
        verify(lines: list.map { Data($0.line.utf8) })
    }

    static func lines(_ data: Data) -> [Data] {
        data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .map { Data($0) }
            .filter { !$0.allSatisfy { $0 == UInt8(ascii: "\r") || $0 == UInt8(ascii: " ") } }
    }

    static func timestamp(_ date: Date) -> String {
        utcFormatter.string(from: date)
    }

    private static let utcFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // MARK: Intern

    private func load() {
        var data = Data()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let d = try? Data(contentsOf: fileURL) else {
                isBlocked = true
                return
            }
            data = d
        }
        isBlocked = false
        var list: [JournalEntry] = []
        var problems: [String] = []
        for (n, line) in Self.lines(data).enumerated() {
            if let node = try? JSONNode.parse(line), let e = JournalEntry(node: node) {
                list.append(e)
            } else {
                problems.append("Zeile \(n + 1) des Journals nicht lesbar")
            }
        }
        entries = list
        loadProblems = problems
        mergeOverflow()
    }

    /// Während einer Sperre gesicherte Zeilen (Nebendateien, Q8) an die Kette anhängen. Übernommen wird nur,
    /// was die Kette lückenlos fortsetzt; bereits enthaltene Einträge werden übersprungen. Die Nebendateien
    /// werden erst entfernt, wenn alles in der Hauptdatei steht.
    private func mergeOverflow() {
        let files = writer.overflowFiles()
        guard !files.isEmpty else { return }
        var candidates: [JournalEntry] = []
        var unreadable = false
        for file in files {
            guard let data = try? Data(contentsOf: file) else { return }   // noch gesperrt → beim nächsten Laden
            for line in Self.lines(data) {
                if let node = try? JSONNode.parse(line), let e = JournalEntry(node: node) {
                    candidates.append(e)
                } else {
                    unreadable = true
                    loadProblems.append("Nebendatei \(file.lastPathComponent): Zeile nicht lesbar")
                }
            }
        }
        let merged = Self.continuation(of: entries, with: candidates)
        loadProblems += merged.problems
        entries += merged.added
        let complete = merged.problems.isEmpty && !unreadable
        writer.merge(merged.added.map { Data(($0.line + "\n").utf8) }, removing: complete ? files : [])
    }

    /// Einträge aus `candidates`, die die Kette `entries` lückenlos fortsetzen (nach `seq`); bereits enthaltene
    /// (gleicher Hash) werden übersprungen, alle anderen als Problem gemeldet.
    nonisolated static func continuation(of entries: [JournalEntry], with candidates: [JournalEntry])
        -> (added: [JournalEntry], problems: [String]) {
        var known = Set(entries.map(\.hash))
        var added: [JournalEntry] = []
        var problems: [String] = []
        for e in candidates.sorted(by: { $0.seq < $1.seq }) where !known.contains(e.hash) {
            let last = added.last ?? entries.last
            guard e.seq == (last?.seq ?? 0) + 1, e.prevHash == (last?.hash ?? JournalEntry.genesisHash),
                  e.computedHash == e.hash else {
                problems.append("Eintrag \(e.seq) aus einer Nebendatei passt nicht an die Kette – nicht übernommen.")
                continue
            }
            added.append(e)
            known.insert(e.hash)
        }
        return (added, problems)
    }
}

/// Schreibt Journal-Zeilen auf der Schreib-Queue der Mandantendateien; nicht geschriebene Zeilen bleiben
/// zurückgestellt und werden beim nächsten Schreiben erneut versucht (Reihenfolge bleibt erhalten).
final class JournalWriter: @unchecked Sendable {
    let url: URL
    /// Nebendatei dieses Writers für Zeilen, die die Hauptdatei (gesperrt) nicht aufnahm (Q8)
    let overflowURL: URL
    private let gate: StorageGate
    private let generation: Int
    private let lock = NSLock()
    private var pending: [Data] = []
    private var error: String?
    /// Nebendatei geschrieben (nur auf `StoreFiles.queue`)
    private var overflowWritten = false

    init(url: URL, gate: StorageGate, generation: Int) {
        self.url = url
        self.overflowURL = url.deletingLastPathComponent()
            .appendingPathComponent(Self.overflowPrefix(url) + UUID().uuidString + ".jsonl")
        self.gate = gate
        self.generation = generation
        Self.liveOverflow.insert(overflowURL.lastPathComponent)
    }

    deinit {
        Self.liveOverflow.remove(overflowURL.lastPathComponent)
    }

    /// Nebendateien lebender Writer dieses Prozesses: deren Zeilen stehen noch in `pending` und werden vom
    /// Besitzer geschrieben – nie von einem anderen Store übernehmen (sonst doppelt in der Kette).
    private static let liveOverflow = NameRegistry()

    /// Namensanfang der Nebendateien, z. B. `journal.overflow-`.
    static func overflowPrefix(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent + ".overflow-"
    }

    /// Nebendateien früherer Prozesse bzw. freigegebener Writer (ohne die eigene und die lebender Writer).
    func overflowFiles() -> [URL] {
        let prefix = Self.overflowPrefix(url)
        let files = (try? FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(),
                                                                  includingPropertiesForKeys: nil)) ?? []
        return files.filter {
            $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "jsonl"
                && !Self.liveOverflow.contains($0.lastPathComponent)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Zeilen aus Nebendateien vor allen ausstehenden Zeilen anhängen; danach `files` entfernen, sofern alles
    /// geschrieben ist.
    func merge(_ lines: [Data], removing files: [URL]) {
        StoreFiles.queue.sync {
            guard gate.isCurrent(generation) else { return }
            lock.lock()
            pending.insert(contentsOf: lines, at: 0)
            lock.unlock()
            writePending()
            lock.lock()
            let written = pending.isEmpty
            lock.unlock()
            guard written else { return }
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    var lastError: String? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }

    func enqueue(_ line: Data) {
        lock.lock()
        pending.append(line)
        lock.unlock()
        StoreFiles.queue.async { self.writePending() }
    }

    func flushSynchronously() {
        StoreFiles.queue.sync { self.writePending() }
    }

    /// Datei durch die angegebenen Zeilen ersetzen (atomar), zurückgestellte Zeilen verwerfen.
    func rewrite(_ lines: [Data]) throws {
        var thrown: Error?
        StoreFiles.queue.sync {
            lock.lock()
            pending = []
            lock.unlock()
            guard gate.isCurrent(generation) else { return }
            do {
                try StoreFiles.ensureDirectory(url.deletingLastPathComponent(), excludeFromBackup: false)
                var data = Data()
                for l in lines { data.append(l) }
                try data.write(to: url, options: StoreFiles.writeOptions)
                // Journal ersetzt → Nebendateien (auch die eigene) sind hinfällig
                for file in overflowFiles() + [overflowURL] { try? FileManager.default.removeItem(at: file) }
                overflowWritten = false
            } catch {
                thrown = error
            }
        }
        if let thrown { throw thrown }
    }

    /// Nur auf `StoreFiles.queue` aufrufen.
    private func writePending() {
        guard gate.isCurrent(generation) else { return }
        lock.lock()
        let lines = pending
        pending = []
        lock.unlock()
        guard !lines.isEmpty else { return }
        var data = Data()
        for l in lines { data.append(l) }
        do {
            try Self.append(data, to: url)
            setError(nil)
            if overflowWritten {
                // Alles Zurückgestellte steht jetzt in der Hauptdatei
                try? FileManager.default.removeItem(at: overflowURL)
                overflowWritten = false
            }
        } catch {
            lock.lock()
            pending.insert(contentsOf: lines, at: 0)
            let unwritten = pending
            lock.unlock()
            // Gesperrt (Q8): bestehende Datei nicht zu öffnen, neue Dateien aber möglich → Nebendatei sichern
            var backup = Data()
            for l in unwritten { backup.append(l) }
            if (try? backup.write(to: overflowURL, options: StoreFiles.writeOptions)) != nil {
                overflowWritten = true
            }
            setError("Journal konnte nicht geschrieben werden: \(error.localizedDescription)")
        }
    }

    /// Zeilen an `url` anhängen (Datei fehlt → neu anlegen). Q14: Schlägt das Schreiben mittendrin fehl, wird
    /// auf die bisherige Länge zurückgeschnitten (keine halbe Zeile); endet die Datei ohne Zeilenumbruch
    /// (Abbruch beim Schreiben), beginnt der neue Block auf einer eigenen Zeile.
    static func append(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try StoreFiles.ensureDirectory(url.deletingLastPathComponent(), excludeFromBackup: false)
            try data.write(to: url, options: StoreFiles.writeOptions)
            return
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        var block = data
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            let last = try handle.read(upToCount: 1)
            if let byte = last?.first, byte != UInt8(ascii: "\n") {
                block = Data([UInt8(ascii: "\n")]) + data
            }
            try handle.seek(toOffset: end)
        }
        do {
            try handle.write(contentsOf: block)
        } catch {
            try? handle.truncate(atOffset: end)
            throw error
        }
    }

    private func setError(_ e: String?) {
        lock.lock()
        error = e
        lock.unlock()
    }
}

/// Thread-sichere Menge von Dateinamen.
private final class NameRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var names = Set<String>()

    func insert(_ name: String) {
        lock.lock()
        names.insert(name)
        lock.unlock()
    }

    func remove(_ name: String) {
        lock.lock()
        names.remove(name)
        lock.unlock()
    }

    func contains(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return names.contains(name)
    }
}
