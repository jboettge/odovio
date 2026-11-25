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
        // wird während der Fahrt bei gesperrtem Gerät geschrieben
        write(data, to: activeURL, strict: false)
    }

    /// Neue Punkte seit dem letzten Zwischenspeicher als eigenes Segment anhängen.
    func appendActivePoints(_ points: [TrackPoint]) {
        guard !points.isEmpty, let data = try? Self.encoder.encode(points) else { return }
        ensureDirectory()
        let n = nextSegment()
        write(data, to: directory.appending(path: String(format: "active-%06d.pts.json", n)), strict: false)
    }

    /// Laufende Aufzeichnung inkl. aller Punkt-Segmente (ältere Dateien mit Punkten in `active.json` bleiben lesbar).
    func loadActive() -> ActiveRecording? {
        guard let data = try? Data(contentsOf: activeURL),
              var a = try? Self.decoder.decode(ActiveRecording.self, from: data) else { return nil }
        for url in segmentURLs() {
            if let d = try? Data(contentsOf: url), let pts = try? Self.decoder.decode([TrackPoint].self, from: d) {
                a.points.append(contentsOf: pts)
            }
        }
        return a
    }

    /// Entfernt die laufende Aufzeichnung samt Segmenten (auch vor dem Start einer neuen).
    func clearActive() {
        try? fm.removeItem(at: activeURL)
        for url in segmentURLs() { try? fm.removeItem(at: url) }
        segmentCounter = 0
    }

    private func segmentURLs() -> [URL] {
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("active-") && $0.lastPathComponent.hasSuffix(".pts.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func nextSegment() -> Int {
        if segmentCounter == nil {
            segmentCounter = segmentURLs().compactMap { url -> Int? in
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

    /// Im Vordergrund (Daten zugänglich) alle Dateien ausser der laufenden Aufzeichnung auf `complete` setzen.
    private func upgradeProtection() {
        #if os(iOS)
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files where !url.lastPathComponent.hasPrefix("active") {
            try? fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        }
        #endif
    }
}
