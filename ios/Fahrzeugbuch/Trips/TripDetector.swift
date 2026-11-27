import CoreLocation
import CoreMotion
import Foundation

/// Ort, um den eine CLMonitor-Region als Weck-Trigger gelegt wird.
struct MonitoredPlace {
    var id: String
    var lat: Double
    var lon: Double
    var radius: Double
}

/// Momentaufnahme einer CoreMotion-Aktivität (wertbasiert, damit sie den Thread wechseln darf).
struct MotionSample {
    var automotive: Bool
    var stationary: Bool
    var onFoot: Bool
    /// 0 = tief, 1 = mittel, 2 = hoch
    var confidence: Int
    var date: Date

    init(_ a: CMMotionActivity) {
        automotive = a.automotive
        stationary = a.stationary
        onFoot = a.walking || a.running || a.cycling
        confidence = a.confidence.rawValue
        date = a.startDate
    }

    /// Wertbasiert (Tests, Auswertung von Lücken)
    init(automotive: Bool, stationary: Bool = false, onFoot: Bool = false, confidence: Int = 2, date: Date) {
        self.automotive = automotive
        self.stationary = stationary
        self.onFoot = onFoot
        self.confidence = confidence
        self.date = date
    }

    var isCar: Bool { automotive && confidence >= CMMotionActivityConfidence.medium.rawValue }
    var isOnFoot: Bool { onFoot && confidence >= CMMotionActivityConfidence.medium.rawValue }
}

/// Automatische Fahrterkennung (nur wenn eingeschaltet).
///
/// - Start: CoreMotion „automotive“ (Konfidenz ≥ mittel) seit ≥ 60 s. Bei Rotlicht meldet iOS oft
///   automotive + stationary gleichzeitig → das zählt weiter als Fahrt; nur Gehen/Laufen/Velo setzt zurück.
/// - Stopp (automatisch gestartete Fahrten, `TripStopRule`): > 3 min kein automotive und keine Bewegung im
///   GPS (stillstehend/gehend) bzw. iOS meldet Stillstand (`isStationary`) seit 1 min und CoreMotion nicht mehr
///   «automotive». Ohne GPS-Bewegung, aber «automotive» (Stau) läuft die Fahrt weiter (Q4). Wird die App
///   beim Parkieren suspendiert, gilt als Ende der letzte Bewegungspunkt (`TripTiming`), und eine Bewegung
///   nach > 10 min Lücke beginnt eine neue Fahrt (`RecordingGap`, im Coordinator).
/// - Manuell gestartete Fahrten (Knopf/Kurzbefehl): nach 10 min Stillstand nur ein Vorschlag
///   (`onIdleDetected` → Mitteilung „Fahrt beenden?“), kein automatisches Beenden.
/// - Weck-Trigger, wenn die App suspendiert oder beendet ist: wesentliche Standortänderungen,
///   `CLVisit`-Abfahrt und `CLMonitor`-Regionen (max. 20) um bekannte Orte. Danach wird die
///   Motion-Historie der letzten Minuten abgefragt; ist man im Auto, startet die Aufzeichnung sofort
///   (zu kurze Auto-Fahrten verwirft der Coordinator).
/// - Force-Quit durch den Nutzer verhindert das Wecken (iOS-Verhalten) → Lückenerkennung/Kurzbefehl.
@MainActor
final class TripDetector: NSObject, CLLocationManagerDelegate {
    static let startAfter: TimeInterval = 60
    static let stopWithoutMovement = TripStopRule.stopWithoutMovement
    static let cooldown: TimeInterval = 120
    static let maxRegions = 20
    /// Nur Buchstaben/Ziffern: CoreLocation bricht bei anderen Zeichen (Punkt, Bindestrich) mit
    /// «Monitor name is not valid» ab (NSInternalInconsistencyException in `CLMonitor.init`).
    static let monitorName = "fahrzeugbuchOrte"

    /// Bedingungs-Identifier ebenfalls nur aus Buchstaben/Ziffern (Q13: Orts-IDs sind UUIDs mit Bindestrich).
    nonisolated static func monitorIdentifier(_ placeId: String) -> String {
        String(String.UnicodeScalarView(placeId.unicodeScalars.filter {
            $0.isASCII && CharacterSet.alphanumerics.contains($0)
        }))
    }

    var onStartDetected: (() -> Void)?
    var onStopDetected: (() -> Void)?
    /// Manuelle Fahrt steht seit `stopWithoutMovement` still (einmal je Stillstand)
    var onIdleDetected: (() -> Void)?

    private(set) var isEnabled = false

    private let motion = CMMotionActivityManager()
    private var motionRunning = false
    private var manager: CLLocationManager?
    private var monitor: CLMonitor?
    private var monitorTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var places: [MonitoredPlace] = []
    /// Regionsabgleich seriell: nie zwei gleichzeitig (sonst zwei `CLMonitor` gleichen Namens → Absturz)
    private var regionSyncTask: Task<Void, Never>?
    private var regionSyncPending = false

    private var lastActivity: MotionSample?
    private var automotiveSince: Date?
    private var lastAutomotiveAt: Date?
    private var lastMovingAt: Date?
    private var watchingStop = false
    /// Stopp-Erkennung beendet die Fahrt selbst (nur automatisch gestartete Fahrten)
    private var stopsAutomatically = false
    private var idleNotified = false
    private var watchStartedAt: Date?
    private var cooldownUntil = Date.distantPast
    private var lastKnownLocation: CLLocation?
    /// iOS meldet Stillstand (`CLLocationUpdate.isStationary`) seit
    private var stationarySince: Date?

    /// Letzte CoreMotion-Aktivität (Startbedingung der Auto-Erkennung: «widerspricht Motion?»)
    var latestMotion: MotionSample? { lastActivity }

    override init() {
        super.init()
    }

    // MARK: Steuerung

    func enable(places: [MonitoredPlace]) {
        self.places = places
        if !isEnabled {
            isEnabled = true
            startMotionUpdates()
        }
        startLocationTriggers()
        scheduleRegionSync()
    }

    func disable() {
        let wasEnabled = isEnabled
        isEnabled = false
        automotiveSince = nil
        if !watchingStop { stopMotionUpdates() }
        manager?.stopMonitoringSignificantLocationChanges()
        manager?.stopMonitoringVisits()
        if wasEnabled || monitor != nil {
            scheduleRegionSync()
        }
    }

    /// Orte geändert (Regionen neu setzen).
    func updatePlaces(_ places: [MonitoredPlace]) {
        self.places = places
        guard isEnabled else { return }
        scheduleRegionSync()
    }

    /// Aufzeichnung läuft; `auto == true` → automatischer Stopp, sonst nur Stillstands-Vorschlag.
    func recordingStarted(auto: Bool) {
        automotiveSince = nil
        watchingStop = true
        stopsAutomatically = auto
        idleNotified = false
        let now = Date()
        watchStartedAt = now
        lastMovingAt = now
        stationarySince = nil
        if auto || CMMotionActivityManager.authorizationStatus() == .authorized {
            startMotionUpdates()   // manuell: keine unvermittelte Abfrage „Bewegung & Fitness“
        }
        ensureTicking()
    }

    func recordingEnded() {
        watchingStop = false
        stopsAutomatically = false
        idleNotified = false
        automotiveSince = nil
        stationarySince = nil
        cooldownUntil = Date().addingTimeInterval(Self.cooldown)
        if !isEnabled { stopMotionUpdates() }
    }

    /// GPS-Fix während der Aufzeichnung (Bewegung zählt als „fährt noch“).
    func noteLocation(_ location: CLLocation) {
        lastKnownLocation = location
        if location.speed >= TripStopRule.movingSpeed {
            lastMovingAt = Date()
            stationarySince = nil
            idleNotified = false   // fährt wieder → nächster Stillstand meldet erneut
        }
    }

    /// `CLLocationUpdate.isStationary` der laufenden Aufzeichnung (Stopp-Signal, Q2).
    func noteStationary(_ stationary: Bool) {
        if stationary {
            if stationarySince == nil { stationarySince = Date() }
            guard watchingStop else { return }
            if evaluate() { ensureTicking() }
        } else {
            stationarySince = nil
        }
    }

    /// Bewegte sich das Fahrzeug in den letzten `seconds` (GPS ≥ 1 m/s)?
    func movedRecently(within seconds: TimeInterval) -> Bool {
        lastMovingAt.map { Date().timeIntervalSince($0) < seconds } ?? false
    }

    /// CoreMotion-Historie (inkl. der Aktivität, die vor `from` begann: Abfrage ab 15 min früher).
    /// `nil` ohne Berechtigung/Verfügbarkeit oder bei Fehler.
    func motionHistory(from: Date, to: Date) async -> [MotionSample]? {
        guard CMMotionActivityManager.isActivityAvailable(),
              CMMotionActivityManager.authorizationStatus() == .authorized, to > from else { return nil }
        let manager = motion
        return await withCheckedContinuation { (continuation: CheckedContinuation<[MotionSample]?, Never>) in
            manager.queryActivityStarting(from: from.addingTimeInterval(-900), to: to,
                                          to: OperationQueue.main) { activities, error in
                continuation.resume(returning: error == nil ? (activities ?? []).map { MotionSample($0) } : nil)
            }
        }
    }

    // MARK: Motion

    private func startMotionUpdates() {
        guard !motionRunning, CMMotionActivityManager.isActivityAvailable() else { return }
        let status = CMMotionActivityManager.authorizationStatus()
        guard status == .authorized || status == .notDetermined else { return }
        motionRunning = true
        motion.startActivityUpdates(to: OperationQueue.main) { [weak self] activity in
            guard let self, let activity else { return }
            let sample = MotionSample(activity)
            Task { @MainActor in self.handle(sample) }
        }
    }

    private func stopMotionUpdates() {
        guard motionRunning else { return }
        motion.stopActivityUpdates()
        motionRunning = false
    }

    private func handle(_ sample: MotionSample) {
        lastActivity = sample
        let now = Date()
        if sample.isCar {
            lastAutomotiveAt = now
            if automotiveSince == nil { automotiveSince = min(sample.date, now) }
        } else if sample.isOnFoot {
            automotiveSince = nil
        }
        // nur „stationary“ (Rotlicht, Stau): Kandidat bleibt bestehen
        if evaluate() { ensureTicking() }
    }

    /// Prüft Start/Stopp; Rückgabe: weiter periodisch prüfen?
    @discardableResult
    private func evaluate() -> Bool {
        let now = Date()
        if watchingStop {
            let lastActive = [lastAutomotiveAt, lastMovingAt, watchStartedAt].compactMap { $0 }.max() ?? now
            let idle = now.timeIntervalSince(lastActive)
            guard stopsAutomatically else {
                // Manuelle Fahrt: 10 min Stillstand (kein GPS-Fortschritt, kein „im Auto“) → Vorschlag
                if idle > Self.stopWithoutMovement && !idleNotified {
                    idleNotified = true
                    onIdleDetected?()
                }
                return true
            }
            let stillInCar = lastActivity?.automotive ?? false
            if TripStopRule.shouldStop(now: now, lastAutomotiveAt: lastAutomotiveAt, lastMovingAt: lastMovingAt,
                                       watchStartedAt: watchStartedAt, stillInCar: stillInCar,
                                       stationarySince: stationarySince) {
                watchingStop = false
                stopsAutomatically = false
                onStopDetected?()
                return false
            }
            return true
        }
        guard isEnabled, let since = automotiveSince else { return false }
        if now < cooldownUntil { return true }
        if let lastCar = lastAutomotiveAt, now.timeIntervalSince(lastCar) > 120 {
            automotiveSince = nil   // Kandidat veraltet
            return false
        }
        if now.timeIntervalSince(since) >= Self.startAfter {
            automotiveSince = nil
            onStartDetected?()
            return false
        }
        return true
    }

    private func ensureTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self else { return }
                if !self.evaluate() {
                    self.tickTask = nil
                    return
                }
            }
        }
    }

    /// Geweckt (SLC, Visit, Region): Motion-Historie der letzten 5 min prüfen.
    private func wake() {
        guard isEnabled, !watchingStop, Date() >= cooldownUntil,
              CMMotionActivityManager.isActivityAvailable(),
              CMMotionActivityManager.authorizationStatus() == .authorized else { return }
        startMotionUpdates()
        let now = Date()
        motion.queryActivityStarting(from: now.addingTimeInterval(-300), to: now,
                                     to: OperationQueue.main) { [weak self] activities, _ in
            guard let self else { return }
            let samples = (activities ?? []).map { MotionSample($0) }
            Task { @MainActor in self.handleWake(samples) }
        }
    }

    private func handleWake(_ samples: [MotionSample]) {
        guard isEnabled, !watchingStop, let last = samples.last else { return }
        if last.isCar {
            // Im Hintergrund bleibt nach dem Wecken keine Zeit, die 60 s abzuwarten → sofort starten;
            // zu kurze Auto-Fahrten (Fehlalarm, Umparkieren) verwirft der Coordinator beim Stopp.
            lastActivity = last
            lastAutomotiveAt = Date()
            automotiveSince = nil
            onStartDetected?()
        } else {
            handle(last)
        }
    }

    // MARK: Standort-Trigger

    private func startLocationTriggers() {
        if manager == nil {
            let m = CLLocationManager()
            m.delegate = self
            manager = m
        }
        guard isEnabled, let m = manager else { return }
        let status = m.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else { return }
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            m.startMonitoringSignificantLocationChanges()
        }
        m.startMonitoringVisits()
    }

    private func authorizationChanged() {
        guard isEnabled else { return }
        startLocationTriggers()
        scheduleRegionSync()
    }

    /// Abgleich anstossen; läuft schon einer, wird danach genau einmal nachgezogen.
    private func scheduleRegionSync() {
        if regionSyncTask != nil {
            regionSyncPending = true
            return
        }
        regionSyncTask = Task { [weak self] in
            while let self {
                self.regionSyncPending = false
                await self.syncRegions()
                if !self.regionSyncPending {
                    self.regionSyncTask = nil
                    return
                }
            }
        }
    }

    /// Regionen auf die (max. 20 nächstgelegenen) Orte abgleichen; deaktiviert → alle entfernen.
    /// Nur über `scheduleRegionSync()` aufrufen.
    private func syncRegions() async {
        let status = manager?.authorizationStatus ?? .notDetermined
        let authorized = status == .authorizedAlways || status == .authorizedWhenInUse
        var wanted: [MonitoredPlace] = []
        if isEnabled && authorized {
            var list = places
            if let here = lastKnownLocation {
                list.sort {
                    GeoMath.distance(lat1: $0.lat, lon1: $0.lon, lat2: here.coordinate.latitude, lon2: here.coordinate.longitude)
                        < GeoMath.distance(lat1: $1.lat, lon1: $1.lon, lat2: here.coordinate.latitude, lon2: here.coordinate.longitude)
                }
            }
            wanted = Array(list.prefix(Self.maxRegions))
        }
        if monitor == nil {
            guard !wanted.isEmpty else { return }
            let m = await CLMonitor(Self.monitorName)
            monitor = m
            monitorTask = Task { [weak self] in
                do {
                    for try await event in await m.events {
                        // Ort verlassen → evtl. Fahrtbeginn
                        if event.state == .unsatisfied { self?.wake() }
                    }
                } catch {
                    // Monitor beendet – beim nächsten Aktivieren neu
                }
            }
        }
        guard let monitor else { return }
        let wantedIds = Set(wanted.map { Self.monitorIdentifier($0.id) })
        let existing = await monitor.identifiers
        for id in existing where !wantedIds.contains(id) {
            await monitor.remove(id)
        }
        let existingIds = Set(existing)
        for p in wanted where !existingIds.contains(Self.monitorIdentifier(p.id)) {
            let condition = CLMonitor.CircularGeographicCondition(
                center: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon), radius: max(p.radius, 150))
            await monitor.add(condition, identifier: Self.monitorIdentifier(p.id))
        }
    }

    // MARK: CLLocationManagerDelegate (nicht isoliert → auf den MainActor wechseln)

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in
            self.lastKnownLocation = last
            self.wake()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let departed = visit.departureDate != Date.distantFuture
        Task { @MainActor in
            if departed { self.wake() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.authorizationChanged() }
    }
}
