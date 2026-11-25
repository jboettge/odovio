import CoreLocation
import Foundation
import Observation
import UIKit

/// Zentrale des intelligenten Fahrtenbuchs: Aufzeichnung (Knopf, Kurzbefehl, Automatik),
/// Entwurf anlegen, Orte zuordnen, Vorschläge (Regel → Kalender → Muster → LLM).
///
/// Einbindung: beim App-Start `TripCoordinator.shared.configure(settings:)` aufrufen (auch bei einem
/// Start im Hintergrund durch Standort-Ereignisse/Kurzbefehl, also z. B. im `init` der App) und nach
/// Mandantenwechsel erneut. Beim Abmelden `resetLocalData()` aufrufen.
///
/// Datenschutz: GPS-Rohdaten bleiben auf dem Gerät (`TrackStore`, 30 Tage nach Bestätigung);
/// der Server erhält Start/Ziel als Ortsbezeichnung (Reverse-Geocoding per POST mit auf ~50 m gerundeten
/// Koordinaten auf dem eigenen Server), die Distanzen und den SHA-256 des Tracks. Für die Strassendistanz
/// geht der reduzierte Track an den eigenen Server (`/api/geo/match`, dort nicht gespeichert) – ohne Punkte
/// im Wohnort-Radius und ohne die ersten/letzten 200 m. Start/Ziel im Wohnort-Radius heissen „Wohnort“
/// (keine Adresse); solange kein Wohnort erfasst ist, nur die Gemeinde (`needsHomePlace`).
/// Das LLM erhält nie Koordinaten. Privatmodus: kein Track, keine Adressen, keine Orte, kein LLM –
/// nur km, Zeit und optional die Gemeinde.
@MainActor
@Observable
final class TripCoordinator {
    static let shared = TripCoordinator()

    private(set) var isRecording = false
    private(set) var recordingVehicleId: String?
    private(set) var liveDistanceKm: Double = 0
    private(set) var recordingStartedAt: Date?
    /// Laufende Fahrt im Privatmodus
    private(set) var recordingPrivate = false
    /// "auto" (Automatik) oder "manual" (Knopf/Kurzbefehl)
    private(set) var recordingSource: String?
    /// Fahrt gestoppt, Entwurf wird gerade erstellt (Geodienste, Vorschlag)
    private(set) var isFinishing = false
    /// Manuelle Fahrt steht seit 10 min still → UI zeigt „Fahrt beenden?“ (zusätzlich Mitteilung)
    private(set) var stopSuggested = false

    /// Automatische Fahrterkennung (Default aus). Einschalten fragt fehlende Berechtigungen selbst an
    /// (Standort „Beim Verwenden“ → „Immer“, Bewegung & Fitness, Mitteilungen).
    var autoDetectEnabled: Bool {
        didSet {
            guard oldValue != autoDetectEnabled else { return }
            UserDefaults.standard.set(autoDetectEnabled, forKey: Keys.autoDetect)
            refreshDetector()
            if autoDetectEnabled && configured {
                Task { await self.ensureAutomationPermissions() }
            }
        }
    }

    /// Automatisch erkannte Fahrten im Privatmodus aufzeichnen (Default aus)
    var autoPrivateMode: Bool {
        didSet { UserDefaults.standard.set(autoPrivateMode, forKey: Keys.autoPrivate) }
    }

    /// Privatmodus: Gemeinde als Start/Ziel speichern (Default an; aus = nur km + Zeit)
    var privateMunicipalityEnabled: Bool {
        didSet { UserDefaults.standard.set(privateMunicipalityEnabled, forKey: Keys.privateMunicipality) }
    }

    var lastError: String?

    /// Standortberechtigung „Immer“ erteilt (für Hinweise in der UI)
    var hasAlwaysLocationAccess: Bool { authorizer.status == .authorizedAlways }

    private enum Keys {
        static let autoDetect = "tripAutoDetect"
        static let autoPrivate = "tripAutoPrivate"
        static let privateMunicipality = "tripPrivateMunicipality"
        static let askedAlways = "tripAskedAlwaysLocation"
    }

    /// Auto-Fahrten unter dieser Distanz/Dauer gelten als Fehlalarm (Bus, Umparkieren)
    static let minAutoDistanceKm = 0.3
    static let minAutoDuration: TimeInterval = 90
    /// Laufende Aufzeichnung, die älter ist, wird nach einem Neustart abgeschlossen statt fortgesetzt
    static let maxResumeAge: TimeInterval = 12 * 3600
    /// Begründung für automatisch erfasste Fahrten in bereits abgeschlossenen Monaten (Server verlangt ≥ 10 Zeichen)
    static let lateEntryReason = "Nachtrag nach Monatsabschluss (automatisch aufgezeichnet)"

    @ObservationIgnored private weak var settings: AppSettings?
    @ObservationIgnored private let recorder = TripRecorder()
    @ObservationIgnored private let tracks = TrackStore()
    @ObservationIgnored private let detector = TripDetector()
    @ObservationIgnored private let calendarMatcher = CalendarMatcher()
    @ObservationIgnored private let authorizer = LocationAuthorizer()
    @ObservationIgnored private var active: TrackStore.ActiveRecording?
    @ObservationIgnored private var recordingStore: TenantStore?
    @ObservationIgnored private var lastCheckpoint = Date.distantPast
    /// Anzahl Punkte, die bereits als Segment gesichert sind (anhängendes Log)
    @ObservationIgnored private var checkpointedPoints = 0
    @ObservationIgnored private var configured = false
    @ObservationIgnored private var lastHousekeeping: (slug: String, at: Date)?
    @ObservationIgnored private var isSuggesting = false
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init() {
        let defaults = UserDefaults.standard
        autoDetectEnabled = defaults.bool(forKey: Keys.autoDetect)
        autoPrivateMode = defaults.bool(forKey: Keys.autoPrivate)
        privateMunicipalityEnabled = defaults.object(forKey: Keys.privateMunicipality) as? Bool ?? true
        recorder.onLocation = { [weak self] location in self?.recorderDidUpdate(location) }
        detector.onStartDetected = { [weak self] in
            Task { await self?.autoStart() }
        }
        detector.onStopDetected = { [weak self] in
            Task { await self?.autoStop() }
        }
        detector.onIdleDetected = { [weak self] in
            Task { await self?.handleIdle() }
        }
    }

    // MARK: Öffentliche API

    func configure(settings: AppSettings) {
        self.settings = settings
        #if DEBUG
        if Demo.isActive {
            configured = true
            return
        }
        #endif
        if !settings.auth.isLoggedIn && !settings.isLocal && !isRecording
            && UIApplication.shared.isProtectedDataAvailable {
            tracks.deleteAll()   // keine Rohdaten ohne angemeldeten Benutzer
        }
        configured = true
        TripNotifications.shared.register()
        resumeIfNeeded()
        housekeeping(force: true)
        refreshDetector()
        refreshReminders()
    }

    func start(vehicle: Vehicle, privateMode: Bool) async {
        await startRecording(vehicle: vehicle, privateMode: privateMode, source: "manual")
    }

    /// Stoppt die Aufzeichnung, legt den Entwurf im Store an und gibt ihn zurück
    /// (`nil`, wenn nichts lief, eine Auto-Fahrt zu kurz war oder kein Mandant verfügbar ist).
    func stop() async -> Trip? {
        guard isRecording, var a = active else { return nil }
        let track = recorder.stop()
        detector.recordingEnded()
        a.finished = track
        a.points = []
        a.distanceMeters = track.distanceKm * 1000
        tracks.saveActive(a)   // übersteht ein Beenden der App während der Nachbearbeitung
        active = nil
        isRecording = false
        recordingVehicleId = nil
        recordingStartedAt = nil
        recordingPrivate = false
        recordingSource = nil
        liveDistanceKm = 0
        stopSuggested = false
        TripNotifications.shared.clearIdle()
        isFinishing = true
        beginBackgroundWork()
        let trip = await finalize(a, track: track)
        if !isRecording { tracks.clearActive() }
        recordingStore = nil
        isFinishing = false
        endBackgroundWork()
        return trip
    }

    /// Vorschlag für eine (bestehende) Fahrt, Stufen Regel → Kalender → Muster → LLM.
    func suggest(for trip: Trip) async -> TripSuggestion? {
        guard let store = settings?.store else { return nil }
        return await suggestion(for: trip, store: store, endPoint: tracks.meta(tripId: trip.id)?.end, allowLLM: true)
    }

    /// Füllt `suggestion_*` aller Entwürfe des aktuellen Mandanten (status "draft" → "suggested").
    func applySuggestions() async {
        guard !isSuggesting else { return }
        isSuggesting = true
        defer { isSuggesting = false }
        guard let store = await currentStore(), store.canWrite else { return }
        housekeeping(force: false)
        var llmBudget = 20   // Server/LLM nicht fluten
        for trip in allTrips(store) where trip.status == "draft" && !trip.deleted {
            if let d = TripTime.parse(trip.startAt),
               store.isMonthClosed(vehicleId: trip.vehicleId, month: TripTime.month(d)) { continue }
            guard let s = await suggestion(for: trip, store: store, endPoint: tracks.meta(tripId: trip.id)?.end,
                                           allowLLM: llmBudget > 0) else { continue }
            if s.source == "llm" { llmBudget -= 1 }
            guard var current = store.trip(id: trip.id), !current.deleted, current.status == "draft" else { continue }
            RuleEngine.apply(s, to: &current)
            store.save(current)
        }
        refreshReminders()
    }

    // MARK: Berechtigungen (einzeln, mit Status – U8)

    /// Aktueller Stand aller Berechtigungen (für Einrichtung/Einstellungen).
    func permissionStatus() async -> PermissionStatus {
        await PermissionStatus.current(location: authorizer.status)
    }

    /// Standort „Beim Verwenden der App“ (nur wenn noch nicht entschieden).
    @discardableResult
    func requestLocationWhenInUse() async -> PermissionStatus {
        _ = await authorizer.requestWhenInUse()
        refreshDetector()
        return await permissionStatus()
    }

    /// Standort „Immer“ (iOS zeigt den Dialog höchstens einmal; danach nur über die Einstellungen).
    @discardableResult
    func requestLocationAlways() async -> PermissionStatus {
        if authorizer.status == .notDetermined { _ = await authorizer.requestWhenInUse() }
        UserDefaults.standard.set(true, forKey: Keys.askedAlways)
        _ = await authorizer.requestAlways()
        refreshDetector()
        return await permissionStatus()
    }

    /// Bewegung & Fitness (Fahrterkennung).
    @discardableResult
    func requestMotion() async -> PermissionStatus {
        await MotionPermission.request()
        refreshDetector()
        return await permissionStatus()
    }

    /// Kalender (Zweckvorschläge aus Terminen) – erst bei Nutzung anfragen.
    @discardableResult
    func requestCalendar() async -> PermissionStatus {
        await calendarMatcher.requestAccess()
        return await permissionStatus()
    }

    /// Mitteilungen (Fahrt beenden?, erkannte Fahrten, Wochenerinnerung, Fälligkeiten).
    @discardableResult
    func requestNotifications() async -> PermissionStatus {
        await NotificationPermission.request()
        refreshReminders()
        return await permissionStatus()
    }

    /// Kamera (Scan von Zapfsäule/Quittung/Tacho).
    @discardableResult
    func requestCamera() async -> PermissionStatus {
        _ = await CameraPermission.request()
        return await permissionStatus()
    }

    /// Beim Einschalten der Automatik: fehlende Berechtigungen der Reihe nach anfragen.
    private func ensureAutomationPermissions() async {
        #if DEBUG
        if Demo.isActive { return }
        #endif
        var status = authorizer.status
        if status == .notDetermined { status = await authorizer.requestWhenInUse() }
        if status == .authorizedWhenInUse && !UserDefaults.standard.bool(forKey: Keys.askedAlways) {
            UserDefaults.standard.set(true, forKey: Keys.askedAlways)
            status = await authorizer.requestAlways()
        }
        await MotionPermission.request()
        await NotificationPermission.request()
        switch status {
        case .authorizedAlways:
            if !MotionPermission.isAuthorized {
                lastError = "Für die automatische Erkennung „Bewegung & Fitness“ erlauben (Einstellungen › Fahrzeugbuch)."
            }
        case .denied, .restricted:
            lastError = "Standortzugriff ist nicht erlaubt – Einstellungen › Fahrzeugbuch › Standort."
        default:
            lastError = "Für die automatische Erkennung „Standort: Immer“ erlauben (Einstellungen › Fahrzeugbuch › Standort)."
        }
        refreshDetector()
        refreshReminders()
    }

    /// Standort (zuerst „Beim Verwenden“, dann „Immer“), Bewegung & Fitness, Mitteilungen.
    /// Der Kalender wird erst bei Nutzung angefragt (`requestCalendar()`).
    func requestPermissions() async {
        var status = authorizer.status
        if status == .notDetermined {
            status = await authorizer.requestWhenInUse()
        }
        if status == .authorizedWhenInUse && !UserDefaults.standard.bool(forKey: Keys.askedAlways) {
            UserDefaults.standard.set(true, forKey: Keys.askedAlways)
            status = await authorizer.requestAlways()
        }
        await MotionPermission.request()
        await NotificationPermission.request()
        switch status {
        case .denied, .restricted:
            lastError = "Standortzugriff ist nicht erlaubt – Einstellungen › Fahrzeugbuch › Standort."
        case .authorizedWhenInUse:
            if autoDetectEnabled {
                lastError = "Für die automatische Erkennung „Standort: Immer“ erlauben (Einstellungen › Fahrzeugbuch)."
            }
        default:
            break
        }
        refreshDetector()
        refreshReminders()
    }

    // MARK: Mitteilungen, Hinweise

    /// Wöchentliche Erinnerung an offene Bestätigungen neu planen (nach Review/Sync aufrufen).
    func refreshReminders() {
        #if DEBUG
        if Demo.isActive { return }
        #endif
        guard let store = settings?.store else { return }
        let open = store.reviewCount
        let slug = store.tenant.slug
        Task { await TripNotifications.shared.refreshWeeklyReminder(openCount: open, tenant: slug) }
    }

    /// Aktion „Geschäftlich“/„Privat“ aus der Mitteilung einer erkannten Fahrt: bestätigt mit der Kategorie
    /// (Zweck/Kunde aus dem Vorschlag, falls er dieselbe Kategorie hat); sonst Review öffnen.
    func classifyFromNotification(tripId: String, tenant: String?, as category: TripCategory) async {
        guard let store = await currentStore(), store.canWrite,
              tenant == nil || store.tenant.slug == tenant,
              let trip = store.trip(id: tripId), !trip.deleted, !trip.isLocked else {
            AppRouter.shared.pending = .review(vehicleId: nil)
            return
        }
        var purpose: String?
        var customerId: String?
        if trip.suggestionCategory == category.rawValue {
            purpose = trip.suggestionPurpose
            customerId = trip.suggestionCustomerId
        }
        let reason = store.requiresReason(for: trip) ? "Bestätigt über Mitteilung (Nachtrag nach Monatsabschluss)" : nil
        store.confirm(trip, as: category, purpose: purpose, customerId: customerId, reason: reason)
        store.flush()
        refreshReminders()
    }

    /// Kein Wohnort erfasst → Bezeichnungen nur als Gemeinde; UI fordert zur Erfassung des Wohnorts auf.
    var needsHomePlace: Bool { settings?.store?.needsHomePlace ?? false }

    /// Tachostand abfragen (letzte Fahrt des Fahrzeugs nur mit geschätzten km).
    func odometerPromptNeeded(vehicleId: String) -> Bool {
        settings?.store?.odometerPromptNeeded(vehicleId: vehicleId) ?? false
    }

    private func handleIdle() async {
        guard isRecording, recordingSource != "auto", !stopSuggested else { return }
        stopSuggested = true
        let name = recordingVehicleId.flatMap { settings?.store?.vehicle(id: $0)?.name }
        await TripNotifications.shared.notifyIdle(vehicleName: name)
    }

    /// Häufige Endpunkte ohne Ort (≥ 3 Besuche, 150 m).
    func placeCandidates() -> [PlaceCandidate] {
        guard let store = settings?.store else { return [] }
        housekeeping(force: false)
        var samples: [PlaceLearner.Sample] = []
        for meta in tracks.metas(tenant: store.tenant.slug) {
            let trip = store.trip(id: meta.tripId)
            if let trip, trip.deleted || trip.privateMode { continue }
            if let s = meta.start { samples.append(.init(lat: s.lat, lon: s.lon, label: trip?.startLabel)) }
            if let e = meta.end { samples.append(.init(lat: e.lat, lon: e.lon, label: trip?.endLabel)) }
        }
        return PlaceLearner.candidates(samples: samples, places: store.placeList)
    }

    /// Regelvorschläge aus Wiederholungen (nicht gespeichert; `origin` "learned", `autoConfirm` aus).
    func ruleCandidates() -> [PurposeRule] {
        guard let store = settings?.store else { return [] }
        return PlaceLearner.ruleCandidates(trips: allTrips(store), rules: store.ruleList)
    }

    /// Passender bekannter Ort zu einer Koordinate.
    func matchPlace(lat: Double, lon: Double) -> Place? {
        PlaceLearner.match(lat: lat, lon: lon, places: settings?.store?.placeList ?? [])
    }

    /// Lokal gespeicherter Track einer Fahrt (z. B. Kartenansicht); `nil` nach Ablauf/Privatmodus.
    func track(for tripId: String) -> RecordedTrack? { tracks.track(tripId: tripId) }

    /// Abmelden/Benutzerwechsel: laufende Aufzeichnung verwerfen, alle Rohdaten löschen.
    func resetLocalData() {
        recorder.cancel()
        detector.recordingEnded()
        active = nil
        recordingStore = nil
        isRecording = false
        recordingVehicleId = nil
        recordingStartedAt = nil
        recordingPrivate = false
        recordingSource = nil
        liveDistanceKm = 0
        stopSuggested = false
        checkpointedPoints = 0
        tracks.deleteAll()
        lastHousekeeping = nil
        refreshDetector()
    }

    /// Für App-Intents: Fahrt mit dem Standardfahrzeug starten; Rückgabe = Text für Siri/Kurzbefehle.
    func startFromIntent(privateMode: Bool) async -> String {
        guard configured, settings != nil else { return "Bitte die Fahrzeugbuch-App einmal öffnen." }
        if isRecording { return "Es läuft bereits eine Fahrt." }
        guard let store = await currentStore() else { return "Kein Fahrzeugbuch-Mandant verfügbar – bitte anmelden." }
        guard let vehicle = defaultVehicle(store) else {
            return "Kein Standardfahrzeug festgelegt – bitte in der App ein Fahrzeug wählen."
        }
        await startRecording(vehicle: vehicle, privateMode: privateMode, source: "manual")
        if isRecording {
            return privateMode ? "Privatfahrt mit \(vehicle.name) gestartet." : "Fahrt mit \(vehicle.name) gestartet."
        }
        return lastError ?? "Die Fahrt konnte nicht gestartet werden."
    }

    /// Für App-Intents: Fahrt beenden; Rückgabe = Text für Siri/Kurzbefehle.
    func stopFromIntent() async -> String {
        guard isRecording else { return "Es läuft keine Fahrt." }
        guard let trip = await stop() else {
            return lastError ?? "Fahrt beendet – zu kurz, nichts gespeichert."
        }
        let km = trip.distanceGps.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "0"
        return "Fahrt beendet (ca. \(km) km). Bitte im Fahrtenbuch prüfen, Tachostand eintragen und bestätigen."
    }

    #if DEBUG
    /// Nur Screenshots/Demo: Anzeige einer laufenden Fahrt ohne GPS.
    func demoSetRecording(vehicleId: String?, distanceKm: Double = 12.4, startedAt: Date = Date().addingTimeInterval(-1260)) {
        isRecording = vehicleId != nil
        recordingVehicleId = vehicleId
        liveDistanceKm = vehicleId == nil ? 0 : distanceKm
        recordingStartedAt = vehicleId == nil ? nil : startedAt
        recordingSource = vehicleId == nil ? nil : "manual"
    }
    #endif

    // MARK: Aufzeichnung

    private func startRecording(vehicle: Vehicle, privateMode: Bool, source: String) async {
        lastError = nil
        #if DEBUG
        if Demo.isActive {
            lastError = "Im Demo-Modus nicht verfügbar."
            return
        }
        #endif
        guard !isRecording else { return }
        guard let store = await currentStore() else {
            lastError = "Kein Mandant geladen."
            return
        }
        guard store.canWrite else {
            lastError = "Keine Schreibberechtigung für diesen Mandanten."
            return
        }
        guard store.vehicle(id: vehicle.id) != nil else {
            lastError = "Das Fahrzeug gehört nicht zum geöffneten Mandanten."
            return
        }
        var status = authorizer.status
        if status == .notDetermined { status = await authorizer.requestWhenInUse() }
        guard status == .authorizedAlways || status == .authorizedWhenInUse else {
            lastError = "Standortzugriff fehlt – Einstellungen › Fahrzeugbuch › Standort."
            return
        }
        guard !isRecording else { return }   // während der Abfrage gestartet
        let now = Date()
        recorder.start(at: now, keepPoints: !privateMode)
        let a = TrackStore.ActiveRecording(tenant: store.tenant.slug, vehicleId: vehicle.id, startedAt: now,
                                           privateMode: privateMode, source: source, distanceMeters: 0,
                                           points: [], first: nil, last: nil, finished: nil)
        active = a
        recordingStore = store
        tracks.clearActive()   // alte Segmente entfernen
        tracks.saveActive(a)
        checkpointedPoints = 0
        stopSuggested = false
        lastCheckpoint = now
        isRecording = true
        recordingVehicleId = vehicle.id
        recordingStartedAt = now
        recordingPrivate = privateMode
        recordingSource = source
        liveDistanceKm = 0
        detector.recordingStarted(auto: source == "auto")
    }

    private func recorderDidUpdate(_ location: CLLocation) {
        guard isRecording else { return }
        liveDistanceKm = (recorder.distanceMeters / 10).rounded() / 100
        detector.noteLocation(location)
        if stopSuggested && location.speed >= 3 {
            stopSuggested = false   // fährt wieder
            TripNotifications.shared.clearIdle()
        }
        checkpoint()
    }

    /// Zwischenstand sichern (alle 30 s), damit ein Beenden der App nichts verliert.
    /// Nur neue Punkte werden als Segment angehängt (kein Neuschreiben des ganzen Tracks).
    private func checkpoint() {
        guard var a = active else { return }
        let now = Date()
        guard now.timeIntervalSince(lastCheckpoint) >= 30 else { return }
        lastCheckpoint = now
        a.distanceMeters = recorder.distanceMeters
        if !a.privateMode {
            let points = recorder.points
            if points.count > checkpointedPoints {
                tracks.appendActivePoints(Array(points[checkpointedPoints...]))
                checkpointedPoints = points.count
            }
            a.points = []
            a.first = recorder.firstPoint
            a.last = recorder.lastPoint
        }
        active = a
        tracks.saveActive(a)
    }

    /// Nach Neustart: laufende Aufzeichnung fortsetzen bzw. gestoppte Fahrt fertigstellen.
    private func resumeIfNeeded() {
        guard !isRecording, !isFinishing, let a = tracks.loadActive() else { return }
        if let finished = a.finished {
            isFinishing = true
            Task {
                _ = await self.finalize(a, track: finished)
                if !self.isRecording { self.tracks.clearActive() }
                self.isFinishing = false
            }
            return
        }
        let now = Date()
        if now.timeIntervalSince(a.startedAt) > Self.maxResumeAge {
            // App lange beendet: mit dem Stand des letzten Zwischenspeichers abschliessen
            let end = a.last.map { Date(timeIntervalSince1970: $0.ts) } ?? a.startedAt
            let track = TripRecorder.makeTrack(points: a.points, distanceMeters: a.distanceMeters, startAt: a.startedAt,
                                               endAt: end, first: a.first, last: a.last, privateMode: a.privateMode)
            var stale = a
            stale.finished = track
            let done = stale
            tracks.saveActive(done)
            isFinishing = true
            Task {
                _ = await self.finalize(done, track: track)
                if !self.isRecording { self.tracks.clearActive() }
                self.isFinishing = false
            }
            return
        }
        recorder.resume(a)
        checkpointedPoints = a.privateMode ? 0 : a.points.count
        var resumed = a
        resumed.points = []
        active = resumed
        lastCheckpoint = now
        isRecording = true
        recordingVehicleId = a.vehicleId
        recordingStartedAt = a.startedAt
        recordingPrivate = a.privateMode
        recordingSource = a.source
        liveDistanceKm = (a.distanceMeters / 10).rounded() / 100
        detector.recordingStarted(auto: a.source == "auto")
    }

    // MARK: Automatik

    private func autoStart() async {
        guard autoDetectEnabled, !isRecording, !isFinishing else { return }
        #if DEBUG
        if Demo.isActive { return }
        #endif
        guard let store = await currentStore(), store.canWrite else { return }
        guard let vehicle = defaultVehicle(store) else {
            lastError = "Automatik: kein Standardfahrzeug festgelegt."
            return
        }
        await startRecording(vehicle: vehicle, privateMode: autoPrivateMode, source: "auto")
    }

    private func autoStop() async {
        guard isRecording, recordingSource == "auto" else { return }
        _ = await stop()
    }

    private func refreshDetector() {
        #if DEBUG
        if Demo.isActive {
            detector.disable()
            return
        }
        #endif
        if autoDetectEnabled && configured {
            detector.enable(places: monitoredPlaces())
        } else {
            detector.disable()
        }
    }

    private func monitoredPlaces() -> [MonitoredPlace] {
        (settings?.store?.placeList ?? []).compactMap { p in
            guard !p.deleted, let lat = p.lat, let lon = p.lon else { return nil }
            return MonitoredPlace(id: p.id, lat: lat, lon: lon, radius: Double(p.radiusM))
        }
    }

    // MARK: Entwurf erstellen

    private func finalize(_ a: TrackStore.ActiveRecording, track: RecordedTrack) async -> Trip? {
        // Fehlalarm der Automatik (Bus, Umparkieren) verwerfen
        if a.source == "auto" && (track.distanceKm < Self.minAutoDistanceKm
                                  || track.endAt.timeIntervalSince(track.startAt) < Self.minAutoDuration) {
            return nil
        }
        guard let settings else { return nil }
        let store = await resolveStore(a.tenant)
        let places = store?.placeList ?? []

        var trip = Trip(vehicleId: a.vehicleId, startAt: Trip.isoString(track.startAt))
        trip.endAt = Trip.isoString(track.endAt)
        trip.source = a.source == "auto" ? "auto" : "manual"
        trip.status = "draft"
        trip.privateMode = a.privateMode
        if settings.isLocal {
            trip.driverName = LocalIdentity.actorName
        } else {
            trip.driverName = settings.displayName ?? settings.auth.userName
            trip.driverSub = UserDefaults.standard.string(forKey: "dataOwnerSub")
        }
        trip.distanceGps = track.distanceKm
        trip.trackHash = track.hash

        // Tacho bleibt massgebend: Vorschlag ab letztem bekannten Stand, als Schätzung gekennzeichnet (U3);
        // Auto-Bestätigung greift dann nicht, der Abschluss verlangt den abgelesenen Stand.
        if let store, store.vehicle(id: a.vehicleId) != nil {
            let km = store.lastKnownKm(for: a.vehicleId)
            trip.kmStart = km
            trip.kmEnd = km + Int(track.distanceKm.rounded())
            trip.kmEstimated = true
        }

        let zones = GeoPrivacy.zones(places)
        let homes = places.filter { $0.isHome && $0.hasCoordinate }
        let hasHome = !(store?.needsHomePlace ?? true)
        if !a.privateMode {
            trip.startPlaceId = nil
            if let s = track.start {
                if let p = PlaceLearner.match(lat: s.lat, lon: s.lon, places: places) {
                    trip.startPlaceId = p.id
                    trip.startLabel = p.name
                } else if GeoPrivacy.isProtected(s, zones: zones) {
                    // Wohnort-Radius: nie eine Adresse, sondern der Ort selbst
                    let home = PlaceLearner.match(lat: s.lat, lon: s.lon, places: homes, slack: GeoPrivacy.minHomeRadius)
                    trip.startPlaceId = home?.id
                    trip.startLabel = home?.name ?? GeoPrivacy.homeLabel
                }
            }
            if let e = track.end {
                if let p = PlaceLearner.match(lat: e.lat, lon: e.lon, places: places) {
                    trip.endPlaceId = p.id
                    trip.endLabel = p.name
                } else if GeoPrivacy.isProtected(e, zones: zones) {
                    let home = PlaceLearner.match(lat: e.lat, lon: e.lon, places: homes, slack: GeoPrivacy.minHomeRadius)
                    trip.endPlaceId = home?.id
                    trip.endLabel = home?.name ?? GeoPrivacy.homeLabel
                }
            }
        }

        // Online-Anreicherung (offline/Fehler → bleibt leer)
        let geo = GeoClient(api: settings.api)
        if settings.isLocal {
            // Lokalmodus: keine Server-Geodienste; optional Apple-Geocoding (nur Strasse/Gemeinde)
            if settings.useAppleGeocoding {
                if a.privateMode {
                    if privateMunicipalityEnabled {
                        trip.startLabel = await AppleGeocoder.reverse(track.start, roundingMeters: 1000)?.municipality
                        trip.endLabel = await AppleGeocoder.reverse(track.end, roundingMeters: 1000)?.municipality
                    }
                } else {
                    let rounding: Double = hasHome ? 50 : 1000
                    if trip.startLabel == nil, let r = await AppleGeocoder.reverse(track.start, roundingMeters: rounding) {
                        trip.startLabel = Self.label(r, municipalityOnly: !hasHome)
                    }
                    if trip.endLabel == nil, let r = await AppleGeocoder.reverse(track.end, roundingMeters: rounding) {
                        trip.endLabel = Self.label(r, municipalityOnly: !hasHome)
                    }
                }
            }
        } else if a.privateMode {
            if privateMunicipalityEnabled {
                let startPoint = track.start
                let endPoint = track.end
                async let rs = geo.reverse(startPoint, roundingMeters: 1000)
                async let re = geo.reverse(endPoint, roundingMeters: 1000)
                let (revStart, revEnd) = await (rs, re)
                trip.startLabel = revStart?.municipality
                trip.endLabel = revEnd?.municipality
            }
        } else {
            // Wohnort-Radius und erste/letzte 200 m verlassen das Gerät nicht
            let points = GeoPrivacy.trimmed(track.points, zones: zones)
            let startPoint = trip.startLabel == nil ? track.start : nil
            let endPoint = trip.endLabel == nil ? track.end : nil
            // Ohne erfassten Wohnort: nur Gemeinde (Start könnte zu Hause sein)
            let rounding: Double = hasHome ? 50 : 1000
            async let m = geo.match(points)
            async let rs = geo.reverse(startPoint, roundingMeters: rounding)
            async let re = geo.reverse(endPoint, roundingMeters: rounding)
            let (match, revStart, revEnd) = await (m, rs, re)
            if let match { trip.distanceRoute = (match.distanceKm * 100).rounded() / 100 }
            if let r = revStart { trip.startLabel = Self.label(r, municipalityOnly: !hasHome) }
            if let r = revEnd { trip.endLabel = Self.label(r, municipalityOnly: !hasHome) }
        }

        var reason: String?
        if let store, store.isMonthClosed(vehicleId: a.vehicleId, month: TripTime.month(track.startAt)) {
            trip.note = "Nachtrag nach Monatsabschluss"
            reason = Self.lateEntryReason
        }

        if let store, let s = await suggestion(for: trip, store: store, endPoint: track.end, allowLLM: true) {
            RuleEngine.apply(s, to: &trip)
        }

        if let store, store.canWrite {
            store.save(trip, reason: reason)
            store.flush()   // vor dem Ende der Hintergrundzeit sicher auf die Platte
            if store.isPersistenceBlocked {
                // Mandantendatei gesperrt (Gerät gesperrt) → Fahrt zusätzlich als ausstehend ablegen,
                // damit sie ein Beenden der App vor dem Entsperren übersteht
                tracks.addPending(trip, tenant: a.tenant)
            }
            tracks.save(track, tripId: trip.id, tenant: a.tenant, vehicleId: a.vehicleId,
                        confirmed: trip.status == "confirmed")
            if a.source == "auto", let saved = store.trip(id: trip.id) {
                await TripNotifications.shared.notifyDetected(saved, tenant: a.tenant, route: store.routeText(saved))
            }
            refreshReminders()
            return trip
        }
        if settings.auth.isLoggedIn && settings.tenants.contains(where: { $0.slug == a.tenant }) {
            // Mandant gerade nicht geöffnet → beim nächsten Öffnen übernehmen
            tracks.addPending(trip, tenant: a.tenant)
            tracks.save(track, tripId: trip.id, tenant: a.tenant, vehicleId: a.vehicleId,
                        confirmed: trip.status == "confirmed")
            lastError = "Fahrt gespeichert – erscheint beim Öffnen von Mandant „\(a.tenant)“."
            return trip
        }
        lastError = "Fahrt konnte nicht gespeichert werden (nicht angemeldet oder keine Schreibberechtigung)."
        return nil
    }

    private static func label(_ r: GeoClient.ReverseResult, municipalityOnly: Bool = false) -> String? {
        let text = municipalityOnly ? r.municipality?.nilIfEmpty : (r.label?.nilIfEmpty ?? r.municipality?.nilIfEmpty)
        return text.map { String($0.prefix(200)) }
    }

    // MARK: Vorschläge

    private func suggestion(for trip: Trip, store: TenantStore, endPoint: TrackPoint?, allowLLM: Bool) async -> TripSuggestion? {
        guard let start = TripTime.parse(trip.startAt) else { return nil }
        if trip.privateMode {
            return TripSuggestion(category: "private", purpose: nil, customerId: nil, confidence: 0.9,
                                  reason: "Als Privatfahrt aufgezeichnet (Privatmodus)", source: "rule")
        }
        let places = store.placeList
        let endPlace = trip.endPlaceId.flatMap { id in places.first { $0.id == id } }
        let end = trip.endAt.flatMap { TripTime.parse($0) }
        let facts = TripFacts(tripId: trip.id, vehicleId: trip.vehicleId, start: start, end: end,
                              startPlaceId: trip.startPlaceId, endPlaceId: trip.endPlaceId,
                              startLabel: trip.startLabel, endLabel: trip.endLabel,
                              endPlaceName: endPlace?.name, endPlaceCustomerId: endPlace?.customerId,
                              endPlaceCategory: endPlace?.defaultCategory,
                              endLat: endPoint?.lat ?? endPlace?.lat, endLon: endPoint?.lon ?? endPlace?.lon,
                              privateMode: trip.privateMode, distanceKm: trip.distanceGps)

        // (1) Regeln
        var placeNames: [String: String] = [:]
        for p in places { placeNames[p.id] = p.name }
        if let s = RuleEngine.ruleSuggestion(rules: store.ruleList, facts: facts, placeNames: placeNames) {
            return s
        }
        // (2) Kalender (lokal)
        let customers = store.customerList.filter { !$0.deleted }.map { RuleEngine.CustomerName(id: $0.id, name: $0.name) }
        if CalendarMatcher.isAuthorized {
            let arrival = end ?? start
            let appointments = calendarMatcher.appointments(from: start.addingTimeInterval(-RuleEngine.calendarWindow),
                                                            to: arrival.addingTimeInterval(RuleEngine.calendarWindow))
            if let s = RuleEngine.calendarSuggestion(facts: facts, appointments: appointments, customers: customers) {
                return s
            }
        }
        // (3) Wiederholungsmuster
        let history = allTrips(store)
        if let s = RuleEngine.patternSuggestion(facts: facts, history: history) {
            return s
        }
        // (4) LLM auf dem eigenen Server – nur pseudonymisierte Merkmale, nie Koordinaten (nicht im Lokalmodus)
        guard allowLLM, let settings, !settings.isLocal, !store.isLocal else { return nil }
        let request = suggestRequest(trip: trip, facts: facts, endPlace: endPlace, places: places,
                                     customers: customers, history: history)
        guard var s = await GeoClient(api: settings.api).suggest(tenant: store.tenant.slug, request: request) else {
            return nil
        }
        if let c = s.customerId, !customers.contains(where: { $0.id == c }) { s.customerId = nil }
        return s
    }

    private func suggestRequest(trip: Trip, facts: TripFacts, endPlace: Place?, places: [Place],
                                customers: [RuleEngine.CustomerName], history: [Trip]) -> GeoClient.SuggestRequest {
        func cut(_ s: String?) -> String? { s?.nilIfEmpty.map { String($0.prefix(120)) } }
        let startPlace = trip.startPlaceId.flatMap { id in places.first { $0.id == id } }
        let features = GeoClient.SuggestRequest.Features(
            startAt: trip.startAt, endAt: trip.endAt,
            startLabel: cut(trip.startLabel), endLabel: cut(trip.endLabel),
            startPlaceName: cut(startPlace?.name), endPlaceName: cut(endPlace?.name),
            distanceKm: trip.distanceRoute ?? trip.distanceGps,
            weekday: TripTime.isoWeekday(facts.start), privateMode: false)
        // Nie Privatfahrten (Privatmodus oder Kategorie „privat“) als Kontext
        let recent = GeoClient.SuggestRequest.recentContext(history: history, excluding: trip.id)
        let customerRefs = customers.prefix(200).map {
            GeoClient.SuggestRequest.CustomerRef(id: String($0.id.prefix(64)), name: String($0.name.prefix(120)))
        }
        return GeoClient.SuggestRequest(trip: features, customers: Array(customerRefs), recent: Array(recent))
    }

    // MARK: Hilfen

    /// Geöffneter Mandant; bei Start im Hintergrund (Kurzbefehl/Automatik) ggf. erst laden.
    private func currentStore() async -> TenantStore? {
        guard let settings else { return nil }
        if let store = settings.store { return store }
        if settings.isConfigured && settings.auth.isLoggedIn {
            await settings.loadTenants()
        }
        return settings.store
    }

    private func resolveStore(_ slug: String) async -> TenantStore? {
        if let s = settings?.store, s.tenant.slug == slug { return s }
        if settings?.store == nil, let s = await currentStore(), s.tenant.slug == slug { return s }
        return nil
    }

    private func defaultVehicle(_ store: TenantStore) -> Vehicle? {
        if let id = store.defaultVehicleId, let v = store.vehicle(id: id), !v.deleted { return v }
        let list = store.vehicleList
        return list.count == 1 ? list.first : nil
    }

    private func allTrips(_ store: TenantStore) -> [Trip] {
        store.vehicleList.flatMap { store.trips(for: $0.id) }.filter { !$0.deleted }
    }

    /// Aufräumen (Aufbewahrungsfristen), ausstehende Fahrten übernehmen, Regionen aktualisieren.
    private func housekeeping(force: Bool) {
        guard let store = settings?.store else { return }
        let now = Date()
        if !force, let last = lastHousekeeping, last.slug == store.tenant.slug, now.timeIntervalSince(last.at) < 3600 {
            return
        }
        lastHousekeeping = (store.tenant.slug, now)
        if store.canWrite {
            for trip in tracks.takePending(tenant: store.tenant.slug) where store.trip(id: trip.id) == nil {
                store.save(trip, reason: store.requiresReason(for: trip) ? Self.lateEntryReason : nil)
            }
        }
        tracks.purge(store: store, now: now)
        detector.updatePlaces(monitoredPlaces())
    }

    private func beginBackgroundWork() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Fahrt abschliessen") {
            Task { @MainActor in TripCoordinator.shared.endBackgroundWork() }
        }
    }

    private func endBackgroundWork() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
