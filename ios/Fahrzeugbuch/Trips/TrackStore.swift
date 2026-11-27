import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Lokale Ablage der GPS-Rohdaten (nur auf dem Gerät, `Application Support/Tracks`, nicht im Backup).
///
/// - Je Fahrt: `<id>.track.json` (reduzierte Punkte) und `<id>.meta.json` (Start/Ziel auf ~10 m gerundet,
///   für das Ortslernen). Getrennte Dateien, damit auch bei gesperrtem Gerät neue Fahrten abgelegt werden
///   können, ohne einen (dann unlesbaren) Index zu überschreiben.
/// - Dateischutz `complete`; ist das Gerät gesperrt (Fahrtende in der Hosentasche), wird mit
///   `completeUnlessOpen` geschrieben und beim nächsten Vordergrund auf `complete` angehoben.
/// - Löschung: Track 30 Tage nach Bestätigung, Endpunkte nach 90 Tagen, stornierte Fahrten sofort.
/// - Privatmodus: es wird nichts abgelegt (nur Distanz in der Fahrt selbst).
/// - Laufende Aufzeichnung: `active.json` (Metadaten) plus anhängende Punkt-Segmente `active-<n>.pts.json`
///   (je Zwischenspeicher nur die neuen Punkte → linearer statt quadratischer Schreibaufwand; neue Dateien
///   lassen sich auch bei gesperrtem Gerät anlegen).
/// - Schutzklasse der laufenden Aufzeichnung (Q1): `completeUntilFirstUserAuthentication`. Mit
///   `completeUnlessOpen` lässt sich eine Datei bei gesperrtem Gerät zwar schreiben, nach dem Schliessen aber
///   nicht mehr lesen – beendet iOS die App während der Fahrt (Jetsam) und weckt sie im Hintergrund wieder,
///   wäre die Aufzeichnung unlesbar und ginge verloren. Die laufende Aufzeichnung muss daher bei gesperrtem
///   Gerät lesbar sein; sie bleibt bis zur ersten Entsperrung nach einem Neustart verschlüsselt und wird nach
///   dem Abschluss der Fahrt gelöscht. Abgelegte Tracks/Endpunkte bleiben `complete` (so bald wie möglich).
/// - «Datei vorhanden, aber nicht lesbar» (vor der ersten Entsperrung, ältere Dateien mit Klasse B) ist nicht
///   «keine Aufzeichnung» (`ActiveLoad.unreadable`): nichts löschen, beim Entsperren erneut versuchen. Muss
///   vorher eine neue Fahrt beginnen, wird die unlesbare Aufzeichnung unverändert nach `Parked/<id>/` verschoben
///   (Umbenennen geht auch gesperrt) und später abgeschlossen. Dorthin kommt auch der erste Teil einer an einer
///   Lücke geteilten Fahrt, bis er gespeichert ist.
@MainActor
final class TrackStore {
    static let trackRetention: TimeInterval = 30 * 86_400
    static let endpointRetention: TimeInterval = 90 * 86_400

    struct Meta: Codable {
        var tripId: String
        var tenant: String
        var vehicleId: String
        var startAt: Date
        var endAt: Date
        var start: TrackPoint?
        var end: TrackPoint?
        var hasTrack: Bool
        var confirmedAt: Date?
    }

    /// Laufende (oder beendete, noch nicht gespeicherte) Aufzeichnung – übersteht einen Neustart der App.
    struct ActiveRecording: Codable {
        var tenant: String
        var vehicleId: String
        var startedAt: Date
        var privateMode: Bool
        /// auto | manual
        var source: String
        var distanceMeters: Double
        var points: [TrackPoint]
        var first: TrackPoint?
        var last: TrackPoint?
        /// gesetzt, sobald gestoppt wurde, die Fahrt aber noch nicht im Store liegt
        var finished: RecordedTrack?
        /// Zeit des letzten Bewegungspunkts (auch im Privatmodus; ältere Dateien: `nil` → `last.ts`)
        var lastMovingAt: Date?

        /// Letzte Bewegung (für Fortsetzen/Abschliessen nach einem Neustart)
        var lastMovement: Date {
            lastMovingAt ?? last.map { Date(timeIntervalSince1970: $0.ts) } ?? startedAt
        }
    }

    /// Ergebnis beim Laden der laufenden Aufzeichnung.
    enum ActiveLoad {
        /// keine Aufzeichnung vorhanden
        case none
        /// Datei vorhanden, aber (noch) nicht lesbar (Gerät gesperrt) – nicht löschen
        case unreadable
        case recording(ActiveRecording)
    }

    /// Fahrt, deren Mandant beim Stopp nicht geöffnet war (wird beim nächsten Öffnen übernommen).
    private struct PendingTrip: Codable {
        var tenant: String
        var trip: Trip
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    private let fm = FileManager.default
    private var metaCache: [String: Meta]?
    let directory: URL

    private var segmentCounter: Int?

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Tracks", directoryHint: .isDirectory)
    }

    // MARK: Tracks

    /// Legt Track + Endpunkte ab (nicht im Privatmodus).
    func save(_ track: RecordedTrack, tripId: String, tenant: String, vehicleId: String, confirmed: Bool) {
        guard !track.privateMode, let name = Self.safeName(tripId) else { return }
        ensureDirectory()
        let hasTrack = track.points.count >= 2
        if hasTrack, let data = try? Self.encoder.encode(track) {
            write(data, to: directory.appending(path: "\(name).track.json"), strict: true)
        }
        let meta = Meta(tripId: tripId, tenant: tenant, vehicleId: vehicleId, startAt: track.startAt, endAt: track.endAt,
                        start: track.start?.coarse(10), end: track.end?.coarse(10), hasTrack: hasTrack,
                        confirmedAt: confirmed ? Date() : nil)
        writeMeta(meta)
    }

    func track(tripId: String) -> RecordedTrack? {
        guard let name = Self.safeName(tripId),
              let data = try? Data(contentsOf: directory.appending(path: "\(name).track.json")) else { return nil }
        return try? Self.decoder.decode(RecordedTrack.self, from: data)
    }

    func meta(tripId: String) -> Meta? { loadMetas()[tripId] }

    func metas(tenant: String) -> [Meta] {
        loadMetas().values.filter { $0.tenant == tenant }.sorted { $0.startAt < $1.startAt }
    }

    func remove(tripId: String) {
        guard let name = Self.safeName(tripId) else { return }
        try? fm.removeItem(at: directory.appending(path: "\(name).track.json"))
        try? fm.removeItem(at: directory.appending(path: "\(name).meta.json"))
        metaCache?[tripId] = nil
    }

    /// Aufräumen gemäss Aufbewahrungsfristen. `store` = aktuell geöffneter Mandant (Status der Fahrten).
    func purge(store: TenantStore?, now: Date = Date()) {
        for var meta in Array(loadMetas().values) {
            if now.timeIntervalSince(meta.endAt) > Self.endpointRetention {
                remove(tripId: meta.tripId)
                continue
            }
            guard let store, store.tenant.slug == meta.tenant else { continue }
            guard let trip = store.trip(id: meta.tripId) else {
                // Fahrt existiert nicht (mehr) – nach einem Tag Karenz entfernen
                if now.timeIntervalSince(meta.endAt) > 86_400 { remove(tripId: meta.tripId) }
                continue
            }
            if trip.deleted || trip.privateMode {
                remove(tripId: meta.tripId)   // storniert oder nachträglich als privat markiert
                continue
            }
            guard trip.status == "confirmed" || trip.status == "locked" else { continue }
            var changed = false
            if meta.confirmedAt == nil {
                meta.confirmedAt = now
                changed = true
            }
            if meta.hasTrack, let c = meta.confirmedAt, now.timeIntervalSince(c) > Self.trackRetention,
               let name = Self.safeName(meta.tripId) {
                try? fm.removeItem(at: directory.appending(path: "\(name).track.json"))
                meta.hasTrack = false
                changed = true
            }
            if changed { writeMeta(meta) }
        }
        upgradeProtection()
    }

    /// Alles entfernen (Abmelden, Benutzerwechsel).
    func deleteAll() {
        try? fm.removeItem(at: directory)
        metaCache = nil
        segmentCounter = nil
    }

    // MARK: Laufende Aufzeichnung

    /// Metadaten der laufenden Aufzeichnung (ohne Punkte – die liegen in den Segmenten).
    func saveActive(_ a: ActiveRecording) {
        ensureDirectory()
        var meta = a
        meta.points = []
        guard let data = try? Self.encoder.encode(meta) else { return }
        // wird während der Fahrt bei gesperrtem Gerät geschrieben und muss dann lesbar bleiben (Q1)
        Self.writeRecordingFile(data, to: activeURL)
    }

    /// Neue Punkte seit dem letzten Zwischenspeicher als eigenes Segment anhängen.
    func appendActivePoints(_ points: [TrackPoint]) {
        guard !points.isEmpty, let data = try? Self.encoder.encode(points) else { return }
        ensureDirectory()
        let n = nextSegment()
        Self.writeRecordingFile(data, to: directory.appending(path: String(format: "active-%06d.pts.json", n)))
    }

    /// Laufende Aufzeichnung inkl. aller Punkt-Segmente (ältere Dateien mit Punkten in `active.json` bleiben lesbar).
    func loadActive() -> ActiveRecording? {
        if case .recording(let a) = loadActiveState() { return a }
        return nil
    }

    /// Wie `loadActive()`, unterscheidet aber «keine Datei» von «Datei gesperrt» (Q1).
    func loadActiveState() -> ActiveLoad {
        Self.loadRecording(in: directory, fm: fm)
    }

    /// Entfernt die laufende Aufzeichnung samt Segmenten (auch vor dem Start einer neuen).
    func clearActive() {
        try? fm.removeItem(at: activeURL)
        for url in Self.segmentURLs(in: directory, fm: fm) { try? fm.removeItem(at: url) }
        segmentCounter = 0
    }

    // MARK: Zurückgestellte Aufzeichnungen (gesperrt bzw. an einer Lücke abgetrennt)

    /// Unlesbare laufende Aufzeichnung unverändert zurückstellen (Umbenennen klappt auch gesperrt), damit eine
    /// neue Fahrt beginnen kann, ohne sie zu überschreiben.
    func parkActive() {
        guard fm.fileExists(atPath: activeURL.path), let dir = newParkedDirectory() else { return }
        try? fm.moveItem(at: activeURL, to: dir.appending(path: "active.json"))
        for url in Self.segmentURLs(in: directory, fm: fm) {
            try? fm.moveItem(at: url, to: dir.appending(path: url.lastPathComponent))
        }
        segmentCounter = 0
    }

    /// Beendete Fahrt (mit `finished`) zurückstellen, bis sie im Store liegt (Teilung an einer Lücke).
    func park(_ a: ActiveRecording) {
        guard let dir = newParkedDirectory(), let data = try? Self.encoder.encode(a) else { return }
        Self.writeRecordingFile(data, to: dir.appending(path: "active.json"))
    }

    /// Lesbare zurückgestellte Aufzeichnungen (ältere zuerst); gesperrte bleiben liegen.
    func parkedRecordings() -> [(directory: URL, recording: ActiveRecording)] {
        let dirs = (try? fm.contentsOfDirectory(at: parkedURL, includingPropertiesForKeys: nil)) ?? []
        var result: [(directory: URL, recording: ActiveRecording)] = []
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            switch Self.loadRecording(in: dir, fm: fm) {
            case .recording(let a): result.append((directory: dir, recording: a))
            case .none: try? fm.removeItem(at: dir)   // leer (z. B. abgebrochenes Verschieben)
            case .unreadable: continue
            }
        }
        return result
    }

    /// Zurückgestellte Aufzeichnung entfernen (nach dem Speichern der Fahrt).
    func removeParked(_ dir: URL) {
        guard dir.deletingLastPathComponent().lastPathComponent == "Parked" else { return }
        try? fm.removeItem(at: dir)
    }

    private var parkedURL: URL { directory.appending(path: "Parked", directoryHint: .isDirectory) }

    private func newParkedDirectory() -> URL? {
        ensureDirectory()
        let stamp = String(format: "%013.0f", Date().timeIntervalSince1970 * 1000)
        let name = stamp + "-" + String(UUID().uuidString.prefix(8))
        let dir = parkedURL.appending(path: name, directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    /// Aufzeichnung (`active.json` + Segmente) in `dir` laden.
    private static func loadRecording(in dir: URL, fm: FileManager) -> ActiveLoad {
        let url = dir.appending(path: "active.json")
        guard fm.fileExists(atPath: url.path) else { return .none }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        guard var a = try? decoder.decode(ActiveRecording.self, from: data) else {
            return .none   // beschädigt (z. B. halb geschrieben): wie keine Aufzeichnung behandeln
        }
        for segment in segmentURLs(in: dir, fm: fm) {
            guard let d = try? Data(contentsOf: segment) else { return .unreadable }
            if let pts = try? decoder.decode([TrackPoint].self, from: d) {
                a.points.append(contentsOf: pts)
            }
        }
        return .recording(a)
    }

    private static func segmentURLs(in dir: URL, fm: FileManager) -> [URL] {
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("active-") && $0.lastPathComponent.hasSuffix(".pts.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func nextSegment() -> Int {
        if segmentCounter == nil {
            segmentCounter = Self.segmentURLs(in: directory, fm: fm).compactMap { url -> Int? in
                let name = url.lastPathComponent
                return Int(name.dropFirst("active-".count).prefix(6))
            }.max() ?? 0
        }
        segmentCounter! += 1
        return segmentCounter!
    }

    // MARK: Ausstehende Fahrten (anderer Mandant)

    func addPending(_ trip: Trip, tenant: String) {
        guard let name = Self.safeName(trip.id),
              let data = try? Self.encoder.encode(PendingTrip(tenant: tenant, trip: trip)) else { return }
        ensureDirectory()
        write(data, to: directory.appending(path: "pending-\(name).json"), strict: true)
    }

    /// Entnimmt die ausstehenden Fahrten eines Mandanten.
    func takePending(tenant: String) -> [Trip] {
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var result: [Trip] = []
        for url in files where url.lastPathComponent.hasPrefix("pending-") {
            guard let data = try? Data(contentsOf: url),
                  let p = try? Self.decoder.decode(PendingTrip.self, from: data),
                  p.tenant == tenant else { continue }
            result.append(p.trip)
            try? fm.removeItem(at: url)
        }
        return result
    }

    // MARK: Intern

    private var activeURL: URL { directory.appending(path: "active.json") }

    /// Nur UUID-artige Namen (kein Pfad-Trick über die Trip-ID).
    private static func safeName(_ id: String) -> String? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard !id.isEmpty, id.count <= 64, id.allSatisfy({ allowed.contains($0) }) else { return nil }
        return id.lowercased()
    }

    private func loadMetas() -> [String: Meta] {
        if let metaCache { return metaCache }
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var result: [String: Meta] = [:]
        var complete = true
        for url in files where url.lastPathComponent.hasSuffix(".meta.json") {
            guard let data = try? Data(contentsOf: url) else { complete = false; continue }  // gesperrt
            if let m = try? Self.decoder.decode(Meta.self, from: data) { result[m.tripId] = m }
        }
        if complete { metaCache = result }
        return result
    }

    private func writeMeta(_ meta: Meta) {
        guard let name = Self.safeName(meta.tripId), let data = try? Self.encoder.encode(meta) else { return }
        ensureDirectory()
        write(data, to: directory.appending(path: "\(name).meta.json"), strict: true)
        metaCache?[meta.tripId] = meta
    }

    private func ensureDirectory() {
        guard !fm.fileExists(atPath: directory.path) else { return }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    /// `strict`: zuerst `complete`, bei gesperrtem Gerät `completeUnlessOpen`.
    private func write(_ data: Data, to url: URL, strict: Bool) {
        #if os(iOS)
        if strict, (try? data.write(to: url, options: [.atomic, .completeFileProtection])) != nil { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        #else
        try? data.write(to: url, options: [.atomic])
        #endif
    }

    /// Laufende/zurückgestellte Aufzeichnung: lesbar nach der ersten Entsperrung (Klasse C, siehe oben);
    /// schlägt das fehl (vor der ersten Entsperrung), mit `completeUnlessOpen` (dann erst entsperrt lesbar).
    private static func writeRecordingFile(_ data: Data, to url: URL) {
        #if os(iOS)
        if (try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil {
            return
        }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        #else
        try? data.write(to: url, options: [.atomic])
        #endif
    }

    /// Im Vordergrund (Daten zugänglich) alle Dateien ausser der laufenden/zurückgestellten Aufzeichnung auf
    /// `complete` setzen.
    private func upgradeProtection() {
        #if os(iOS)
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files where !url.lastPathComponent.hasPrefix("active") && url.lastPathComponent != "Parked" {
            try? fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        }
        #endif
    }
}
