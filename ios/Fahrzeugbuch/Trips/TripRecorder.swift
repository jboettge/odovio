import CoreLocation
import Foundation

/// GPS-Aufzeichnung einer Fahrt (nur während der Fahrt aktiv).
///
/// - `CLLocationUpdate.liveUpdates(.automotiveNavigation)`: das System pausiert bei Stillstand selbst.
/// - `CLBackgroundActivitySession` hält die Updates im Hintergrund am Leben (blaue Statusanzeige).
///   Eine neue Session lässt sich nur im Vordergrund sicher starten; nach einem Neustart der App
///   im Hintergrund wird sie durch erneutes Anlegen wieder aufgenommen. Mit Berechtigung „Immer“
///   liefern `liveUpdates` auch bei Start aus dem Hintergrund (Automatik, Kurzbefehl).
/// - Genauigkeitsfilter (≤ 50 m), Sprung- und Zitterfilter, Distanzsumme; beim Stopp
///   Douglas-Peucker-Reduktion und SHA-256 über die kanonischen Punkte.
@MainActor
final class TripRecorder {
    static let maxAccuracy: CLLocationAccuracy = 50
    /// > 250 km/h zwischen zwei Fixes = Ausreisser
    static let maxSpeed = 70.0
    /// Toleranz der Douglas-Peucker-Reduktion in Metern
    static let simplifyEpsilon = 8.0

    private(set) var isRunning = false
    private(set) var distanceMeters: Double = 0
    private(set) var startedAt: Date?
    private(set) var points: [TrackPoint] = []
    private(set) var firstPoint: TrackPoint?
    private(set) var lastPoint: TrackPoint?
    private(set) var lastError: String?
    private(set) var keepPoints = true

    /// Jeder Fix mit brauchbarer Genauigkeit (auch bei Stillstand) – für Live-Distanz und Stopp-Erkennung.
    var onLocation: ((CLLocation) -> Void)?

    private var session: CLBackgroundActivitySession?
    private var task: Task<Void, Never>?

    /// Neue Aufzeichnung. `keepPoints == false` (Privatmodus): nur Distanz, kein Track.
    func start(at date: Date = Date(), keepPoints: Bool) {
        stopUpdates()
        self.keepPoints = keepPoints
        distanceMeters = 0
        points = []
        firstPoint = nil
        lastPoint = nil
        startedAt = date
        startUpdates()
    }

    /// Nach Neustart der App fortsetzen (Zwischenstand aus `TrackStore.ActiveRecording`).
    func resume(_ a: TrackStore.ActiveRecording) {
        stopUpdates()
        keepPoints = !a.privateMode
        distanceMeters = a.distanceMeters
        points = keepPoints ? a.points : []
        firstPoint = keepPoints ? a.first : nil
        lastPoint = keepPoints ? a.last : nil
        startedAt = a.startedAt
        startUpdates()
    }

    /// Beendet die Aufzeichnung und liefert das Ergebnis.
    func stop(at date: Date = Date()) -> RecordedTrack {
        stopUpdates()
        let track = Self.makeTrack(points: points, distanceMeters: distanceMeters,
                                   startAt: startedAt ?? date, endAt: date,
                                   first: firstPoint, last: lastPoint, privateMode: !keepPoints)
        points = []
        firstPoint = nil
        lastPoint = nil
        distanceMeters = 0
        startedAt = nil
        return track
    }

    /// Verwerfen ohne Ergebnis (z. B. Abmelden).
    func cancel() {
        stopUpdates()
        points = []
        firstPoint = nil
        lastPoint = nil
        distanceMeters = 0
        startedAt = nil
    }

    static func makeTrack(points: [TrackPoint], distanceMeters: Double, startAt: Date, endAt: Date,
                          first: TrackPoint?, last: TrackPoint?, privateMode: Bool) -> RecordedTrack {
        let distanceKm = (distanceMeters / 10).rounded() / 100   // 10 m Auflösung
        if privateMode {
            // Kein Track, keine genauen Koordinaten – nur ~1 km für die optionale Gemeinde
            return RecordedTrack(points: [], distanceKm: distanceKm, startAt: startAt, endAt: max(endAt, startAt),
                                 start: first?.coarse(1000), end: last?.coarse(1000), hash: nil, privateMode: true)
        }
        var reduced = GeoMath.simplify(points, epsilon: simplifyEpsilon).map(\.canonical)
        if reduced.count == 1, let only = reduced.first, let l = last?.canonical, l != only {
            reduced.append(l)
        }
        let hash = reduced.count >= 2 ? GeoMath.sha256Hex(GeoMath.canonicalData(reduced)) : nil
        return RecordedTrack(points: reduced, distanceKm: distanceKm, startAt: startAt, endAt: max(endAt, startAt),
                             start: first?.canonical, end: last?.canonical, hash: hash, privateMode: false)
    }

    // MARK: Intern

    private func startUpdates() {
        isRunning = true
        lastError = nil
        session = CLBackgroundActivitySession()
        task = Task { [weak self] in
            do {
                let updates = CLLocationUpdate.liveUpdates(.automotiveNavigation)
                for try await update in updates {
                    if Task.isCancelled { break }
                    guard let self else { break }
                    if let location = update.location { self.ingest(location) }
                }
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    private func stopUpdates() {
        task?.cancel()
        task = nil
        session?.invalidate()
        session = nil
        isRunning = false
    }

    private func ingest(_ location: CLLocation) {
        let acc = location.horizontalAccuracy
        guard acc >= 0, acc <= Self.maxAccuracy else { return }
        if let start = startedAt, location.timestamp < start.addingTimeInterval(-5) { return } // alter Cache-Fix
        let p = TrackPoint(lat: location.coordinate.latitude, lon: location.coordinate.longitude,
                           ts: location.timestamp.timeIntervalSince1970, accuracy: acc)
        defer { onLocation?(location) }
        guard let last = lastPoint else {
            firstPoint = p
            lastPoint = p
            if keepPoints { points.append(p) }
            return
        }
        let dt = p.ts - last.ts
        guard dt > 0 else { return }
        let d = GeoMath.distance(last, p)
        if d / dt > Self.maxSpeed { return }              // Sprung
        if d < max(5, min(acc, 25)) { return }            // Zittern im Stand
        distanceMeters += d
        lastPoint = p
        if keepPoints { points.append(p) }
    }
}
