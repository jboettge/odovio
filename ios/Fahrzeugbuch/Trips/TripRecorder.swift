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
/// - Ende = letzter Bewegungspunkt (`TripTiming.endDate`), nicht der Zeitpunkt des Stopps (Q2).
/// - `splitsOnGap` (Automatik): Bewegung nach > 10 min ohne Bewegungspunkt wird als `pendingGap` vorgemerkt;
///   der Coordinator entscheidet (CoreMotion-Historie) über `splitAtGap()` bzw. `acceptGap()`.
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
    /// `CLLocationUpdate.isStationary` hat gewechselt (iOS pausiert die Updates bei Stillstand).
    var onStationary: ((Bool) -> Void)?

    /// Lücke > `TripGap.splitAfter` zwischen zwei Bewegungspunkten (nur mit `splitsOnGap`).
    struct Gap {
        /// Anzahl gespeicherter Punkte vor der Lücke
        var index: Int
        /// Letzter Bewegungspunkt vor der Lücke
        var lastBefore: TrackPoint
        /// Distanz bis `lastBefore`
        var distanceBefore: Double
        /// Erster Bewegungspunkt nach der Lücke
        var firstAfter: TrackPoint
        /// Distanz `lastBefore` → `firstAfter` (gehört zu keiner der beiden Fahrten, falls geteilt)
        var jumpMeters: Double
    }

    /// Automatik: Lücken erkennen (manuelle Fahrten beendet der Nutzer selbst)
    var splitsOnGap = false
    private(set) var pendingGap: Gap?
    private var lastStationary = false

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
        pendingGap = nil
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
        pendingGap = nil
        startUpdates()
    }

    /// Beendet die Aufzeichnung und liefert das Ergebnis. Ende = letzter Bewegungspunkt (sonst `date`).
    /// Mit offener Lücke endet die Fahrt davor (die Bewegung danach gehört zu einer neuen Fahrt).
    func stop(at date: Date = Date()) -> RecordedTrack {
        stopUpdates()
        let start = startedAt ?? date
        let track: RecordedTrack
        if let gap = pendingGap {
            track = Self.makeTrack(points: keepPoints ? Array(points.prefix(gap.index)) : [],
                                   distanceMeters: gap.distanceBefore, startAt: start,
                                   endAt: TripTiming.endDate(lastMovingTs: gap.lastBefore.ts, startedAt: start, now: date),
                                   first: firstPoint, last: gap.lastBefore, privateMode: !keepPoints)
        } else {
            track = Self.makeTrack(points: points, distanceMeters: distanceMeters, startAt: start,
                                   endAt: TripTiming.endDate(lastMovingTs: lastPoint?.ts, startedAt: start, now: date),
                                   first: firstPoint, last: lastPoint, privateMode: !keepPoints)
        }
        points = []
        firstPoint = nil
        lastPoint = nil
        distanceMeters = 0
        startedAt = nil
        pendingGap = nil
        return track
    }

    /// Lücke gehört zur selben Fahrt (z. B. Stau: CoreMotion meldete «automotive»).
    func acceptGap() {
        pendingGap = nil
    }

    /// Teilt an der offenen Lücke: liefert die Fahrt bis zum letzten Bewegungspunkt davor; die Aufzeichnung
    /// läuft ohne Unterbruch als neue Fahrt ab dem ersten Punkt nach der Lücke weiter.
    func splitAtGap(now: Date = Date()) -> (track: RecordedTrack, newStart: Date)? {
        guard let gap = pendingGap, let start = startedAt else { return nil }
        pendingGap = nil
        let before = keepPoints ? Array(points.prefix(gap.index)) : []
        let track = Self.makeTrack(points: before, distanceMeters: gap.distanceBefore, startAt: start,
                                   endAt: TripTiming.endDate(lastMovingTs: gap.lastBefore.ts, startedAt: start, now: now),
                                   first: firstPoint, last: gap.lastBefore, privateMode: !keepPoints)
        if keepPoints { points = Array(points.dropFirst(gap.index)) }
        firstPoint = gap.firstAfter
        distanceMeters = max(0, distanceMeters - gap.distanceBefore - gap.jumpMeters)
        let newStart = Date(timeIntervalSince1970: gap.firstAfter.ts)
        startedAt = newStart
        return (track, newStart)
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
                    if update.isStationary != self.lastStationary {
                        self.lastStationary = update.isStationary
                        self.onStationary?(update.isStationary)
                    }
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
        lastStationary = false
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
        if splitsOnGap, pendingGap == nil, TripGap.isGap(previousTs: last.ts, nextTs: p.ts) {
            pendingGap = Gap(index: points.count, lastBefore: last, distanceBefore: distanceMeters,
                             firstAfter: p, jumpMeters: d)
        }
        distanceMeters += d
        lastPoint = p
        if keepPoints { points.append(p) }
    }
}
