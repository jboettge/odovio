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
            guard !restoringDefaults, oldValue != autoDetectEnabled else { return }
            UserDefaults.standard.set(autoDetectEnabled, forKey: Keys.autoDetect)
            refreshDetector()
            if autoDetectEnabled && configured {
                Task { await self.ensureAutomationPermissions() }
            }
        }
    }

    /// Automatisch erkannte Fahrten im Privatmodus aufzeichnen (Default aus)
    var autoPrivateMode: Bool {
        didSet { if !restoringDefaults { UserDefaults.standard.set(autoPrivateMode, forKey: Keys.autoPrivate) } }
    }

    /// Privatmodus: Gemeinde als Start/Ziel speichern (Default an; aus = nur km + Zeit)
    var privateMunicipalityEnabled: Bool {
        didSet {
            if !restoringDefaults { UserDefaults.standard.set(privateMunicipalityEnabled, forKey: Keys.privateMunicipality) }
        }
    }

    var lastError: String? {
        didSet { lastErrorOpensSettings = false }
    }
    /// `lastError` verweist auf die iOS-Einstellungen → UI zeigt «Einstellungen öffnen» (U2)
    private(set) var lastErrorOpensSettings = false

    /// Standortberechtigung „Immer“ erteilt (für Hinweise in der UI)
    var hasAlwaysLocationAccess: Bool { authorizer.status == .authorizedAlways }

    /// Der Dialog «Immer» wurde schon einmal gezeigt – iOS zeigt ihn nicht erneut, nur noch die
    /// iOS-Einstellungen helfen (U3).
    var alwaysPromptUsed: Bool { UserDefaults.standard.bool(forKey: Keys.askedAlways) }

    /// Ergebnis von Start/Stopp für CarPlay (kurz) bzw. Siri/Kurzbefehle und Mitteilung (ausführlich).
    struct ActionOutcome {
        var ok: Bool
        /// Kurz für CarPlay («Fahrt gestartet», «Kein Standardfahrzeug»)
        var short: String
        /// Ausführlich (Siri-Dialog, Mitteilung auf dem iPhone)
        var detail: String
        /// Details auch als Mitteilung aufs iPhone (z. B. Handlung nötig)
        var notify: Bool
    }

    private enum Keys {
        static let autoDetect = "tripAutoDetect"
        static let autoPrivate = "tripAutoPrivate"
        static let privateMunicipality = "tripPrivateMunicipality"
        static let askedAlways = "tripAskedAlwaysLocation"
        /// Orte der Weck-Regionen (Q7): im Hintergrund ohne geöffneten Mandanten aus diesem Cache
        static let monitoredPlaces = "tripMonitoredPlaces"
    }

    /// Auto-Fahrten unter dieser Distanz/Dauer gelten als Fehlalarm (Bus, Umparkieren)
    static let minAutoDistanceKm = 0.3
    static let minAutoDuration: TimeInterval = 90
    /// Laufende Aufzeichnung, die älter ist, wird nach einem Neustart abgeschlossen statt fortgesetzt
    static let maxResumeAge: TimeInterval = 12 * 3600
    /// Begründung für automatisch erfasste Fahrten in bereits abgeschlossenen Monaten (Server verlangt ≥ 10 Zeichen)
    static let lateEntryReason = "Nachtrag nach Monatsabschluss (automatisch aufgezeichnet)"
    /// Auto-Erkennung getrennt (Bluetooth/CarPlay) → automatische Fahrt nach dieser Karenz beenden (Tankstopp)
    static let disconnectGrace: TimeInterval = 120

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
    /// Laufende Aufzeichnung gesperrt (Datei vorhanden, aber nicht lesbar) → beim Entsperren fortsetzen (Q1)
    @ObservationIgnored private var activeLocked = false
    @ObservationIgnored private var gapCheckRunning = false
    @ObservationIgnored private var finishingParked = false
    @ObservationIgnored private var disconnectStopTask: Task<Void, Never>?
    /// Nachprüfen der Auto-Verbindung nach «im Auto» ohne Verbindung (Bluetooth verbindet verzögert)
    @ObservationIgnored private var connectionRecheckTask: Task<Void, Never>?
    /// Einstellungen werden nach der ersten Entsperrung nachgeladen (didSet schreibt nicht zurück, Q6)
    @ObservationIgnored private var restoringDefaults = false

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
        recorder.onStationary = { [weak self] stationary in
            self?.detector.noteStationary(stationary)
        }
        CarConnectionMonitor.shared.onEvent = { [weak self] event in
            Task { await self?.handleCarEvent(event) }
        }
        // Gesperrte Aufzeichnung (Q1) bzw. zurückgestellte Fahrten nach dem Entsperren abschliessen
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in TripCoordinator.shared.protectedDataBecameAvailable() }
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
        if !settings.auth.isLoggedIn && !settings.isLocal && !isRecording && !settings.awaitingFirstUnlock
            && UIApplication.shared.isProtectedDataAvailable {
            tracks.deleteAll()   // keine Rohdaten ohne angemeldeten Benutzer
        }
        configured = true
        TripNotifications.shared.register()
        resumeIfNeeded()
        finalizeParked()
        housekeeping(force: true)
        refreshDetector()
        refreshReminders()
    }

    /// Start vor der ersten Entsperrung (Q6): Einstellungen (Automatik, Privatmodus) waren nicht lesbar und
    /// galten als «aus». Nach der Entsperrung laden und das Fahrtenbuch neu einrichten.
    func reloadAfterFirstUnlock(settings: AppSettings) {
        let defaults = UserDefaults.standard
        restoringDefaults = true
        autoDetectEnabled = defaults.bool(forKey: Keys.autoDetect)
        autoPrivateMode = defaults.bool(forKey: Keys.autoPrivate)
        privateMunicipalityEnabled = defaults.object(forKey: Keys.privateMunicipality) as? Bool ?? true
        restoringDefaults = false
        CarConnectionMonitor.shared.reloadAfterFirstUnlock()
        configure(settings: settings)
    }

    func start(vehicle: Vehicle, privateMode: Bool) async {
        await startRecording(vehicle: vehicle, privateMode: privateMode, source: "manual")
    }

    /// Stoppt die Aufzeichnung, legt den Entwurf im Store an und gibt ihn zurück
    /// (`nil`, wenn nichts lief, eine Auto-Fahrt zu kurz war oder kein Mandant verfügbar ist).
    func stop() async -> Trip? {
        guard isRecording, var a = active else { return nil }
        let track = recorder.stop()   // Ende = letzter Bewegungspunkt (Q2)
        detector.recordingEnded()
        disconnectStopTask?.cancel()
        disconnectStopTask = nil
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
        finalizeParked()
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
               store.isMonthClosed(vehicleId: trip.vehicleId, month: LogbookRules.month(d)) { continue }
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
                setSettingsError("Für die automatische Erkennung «Bewegung & Fitness» erlauben (Einstellungen › odovio).")
            }
        case .denied, .restricted:
            setSettingsError("Standortzugriff ist nicht erlaubt – Einstellungen › odovio › Standort.")
        default:
            setSettingsError("Für die automatische Erkennung «Standort: Immer» erlauben (Einstellungen › odovio › Standort).")
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
            setSettingsError("Standortzugriff ist nicht erlaubt – Einstellungen › odovio › Standort.")
        case .authorizedWhenInUse:
            if autoDetectEnabled {
                setSettingsError("Für die automatische Erkennung «Standort: Immer» erlauben (Einstellungen › odovio › Standort).")
            }
        default:
            break
        }
        refreshDetector()
        refreshReminders()
    }

    /// Fehlertext mit Verweis auf die iOS-Einstellungen (UI bietet «Einstellungen öffnen» an).
    private func setSettingsError(_ text: String) {
        lastError = text
        lastErrorOpensSettings = true
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
        disconnectStopTask?.cancel()
        disconnectStopTask = nil
        activeLocked = false
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
        UserDefaults.standard.removeObject(forKey: Keys.monitoredPlaces)   // Orte des bisherigen Benutzers (Q7)
    }

    /// Für App-Intents: Fahrt mit dem Standardfahrzeug starten; Rückgabe = Text für Siri/Kurzbefehle.
    func startFromIntent(privateMode: Bool) async -> String {
        await startAction(privateMode: privateMode).detail
    }

    /// Für App-Intents: Fahrt beenden; Rückgabe = Text für Siri/Kurzbefehle.
    func stopFromIntent() async -> String {
        await stopAction().detail
    }

    /// Fahrt starten (Siri, Kurzbefehle, Quick Action, CarPlay). Fahrzeug: `preferredVehicleId` (z. B. «Fahrzeug
    /// für CarPlay»), sonst das ausdrücklich gewählte Standardfahrzeug bzw. das einzige Fahrzeug (Q3).
    func startAction(privateMode: Bool, preferredVehicleId: String? = nil) async -> ActionOutcome {
        guard configured, settings != nil else {
            return ActionOutcome(ok: false, short: "App öffnen", detail: "Bitte die odovio-App einmal öffnen.",
                                 notify: true)
        }
        if isRecording {
            return ActionOutcome(ok: false, short: "Fahrt läuft bereits", detail: "Es läuft bereits eine Fahrt.",
                                 notify: false)
        }
        guard let store = await currentStore() else {
            return ActionOutcome(ok: false, short: "Nicht angemeldet",
                                 detail: "Kein Fahrzeugbuch verfügbar – bitte in der odovio-App anmelden.", notify: true)
        }
        guard let vehicle = automationVehicle(store, preferredId: preferredVehicleId) else {
            return ActionOutcome(ok: false, short: "Kein Standardfahrzeug", detail: DefaultVehicleChoice.missingText,
                                 notify: true)
        }
        await startRecording(vehicle: vehicle, privateMode: privateMode, source: "manual")
        if isRecording {
            let text = privateMode ? "Privatfahrt mit \(vehicle.name) gestartet." : "Fahrt mit \(vehicle.name) gestartet."
            return ActionOutcome(ok: true, short: privateMode ? "Privatfahrt gestartet" : "Fahrt gestartet",
                                 detail: text, notify: false)
        }
        return ActionOutcome(ok: false, short: "Start nicht möglich",
                             detail: lastError ?? "Die Fahrt konnte nicht gestartet werden.", notify: true)
    }

    /// Fahrt beenden (Siri, Kurzbefehle, CarPlay).
    func stopAction() async -> ActionOutcome {
        guard isRecording else {
            return ActionOutcome(ok: false, short: "Keine Fahrt aktiv", detail: "Es läuft keine Fahrt.", notify: false)
        }
        guard let trip = await stop() else {
            let detail = lastError ?? "Fahrt beendet – zu kurz, nichts gespeichert."
            return ActionOutcome(ok: false, short: "Fahrt beendet", detail: detail, notify: lastError != nil)
        }
        let km = TripNotifications.kmText(trip.distanceGps ?? 0)
        return ActionOutcome(ok: true, short: "Fahrt beendet · \(km)",
                             detail: "Fahrt beendet (ca. \(km)). Bitte im Fahrtenbuch prüfen, Tachostand eintragen "
                                + "und bestätigen.",
                             notify: true)
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
            setSettingsError("Standortzugriff fehlt – Einstellungen › odovio › Standort.")
            return
        }
        guard !isRecording else { return }   // während der Abfrage gestartet
        let now = Date()
        recorder.splitsOnGap = source == "auto"
        recorder.start(at: now, keepPoints: !privateMode)
        let a = TrackStore.ActiveRecording(tenant: store.tenant.slug, vehicleId: vehicle.id, startedAt: now,
                                           privateMode: privateMode, source: source, distanceMeters: 0,
                                           points: [], first: nil, last: nil, finished: nil)
        active = a
        recordingStore = store
        if case .unreadable = tracks.loadActiveState() {
            // Gesperrte frühere Aufzeichnung nicht löschen (Q1): zurückstellen, beim Entsperren abschliessen
            tracks.parkActive()
            activeLocked = false
        }
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
        if recorder.pendingGap != nil { scheduleGapCheck() }
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
        a.lastMovingAt = recorder.lastPoint.map { Date(timeIntervalSince1970: $0.ts) }
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
    /// Gesperrte Datei (Q1): nichts verwerfen, beim Entsperren (`protectedDataDidBecomeAvailable`) erneut.
    private func resumeIfNeeded() {
        guard !isRecording, !isFinishing else { return }
        let a: TrackStore.ActiveRecording
        switch tracks.loadActiveState() {
        case .none:
            activeLocked = false
            return
        case .unreadable:
            activeLocked = true
            return
        case .recording(let loaded):
            activeLocked = false
            a = loaded
        }
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
        if now.timeIntervalSince(a.startedAt) > Self.maxResumeAge
            || RecordingGap.endsOnResume(source: a.source, lastMovingAt: a.lastMovement, now: now) {
            // App lange beendet bzw. automatische Fahrt seit > 10 min ohne Bewegung (geparkt, Q2): am letzten
            // Bewegungspunkt abschliessen statt fortsetzen – fährt man weiter, beginnt die Automatik eine neue Fahrt
            let track = Self.staleTrack(a, now: now)
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
        recorder.splitsOnGap = a.source == "auto"
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

    /// Abgebrochene Aufzeichnung ohne gespeichertes Ende: Track bis zum letzten Bewegungspunkt.
    private static func staleTrack(_ a: TrackStore.ActiveRecording, now: Date) -> RecordedTrack {
        let end = TripTiming.endDate(lastMovingTs: a.lastMovement.timeIntervalSince1970, startedAt: a.startedAt, now: now)
        return TripRecorder.makeTrack(points: a.points, distanceMeters: a.distanceMeters, startAt: a.startedAt,
                                      endAt: end, first: a.first, last: a.last, privateMode: a.privateMode)
    }

    /// Entsperrt: gesperrte Aufzeichnung fortsetzen/abschliessen, zurückgestellte Fahrten speichern.
    private func protectedDataBecameAvailable() {
        guard configured else { return }
        #if DEBUG
        if Demo.isActive { return }
        #endif
        if activeLocked { resumeIfNeeded() }
        finalizeParked()
    }

    /// Zurückgestellte Aufzeichnungen (gesperrt beim Start einer neuen Fahrt bzw. an einer Lücke abgetrennt)
    /// als Entwurf speichern.
    private func finalizeParked() {
        guard configured, !finishingParked else { return }
        #if DEBUG
        if Demo.isActive { return }
        #endif
        let parked = tracks.parkedRecordings()
        guard !parked.isEmpty else { return }
        finishingParked = true
        Task {
            for item in parked {
                let track = item.recording.finished ?? Self.staleTrack(item.recording, now: Date())
                _ = await self.finalize(item.recording, track: track)
                self.tracks.removeParked(item.directory)
            }
            self.finishingParked = false
        }
    }

    // MARK: Lücken (Q2)

    /// Bewegung nach > 10 min Lücke: CoreMotion-Historie der Lücke prüfen – Stau (überwiegend «automotive»)
    /// bleibt eine Fahrt, sonst endet die alte Fahrt am letzten Punkt und die neue beginnt.
    private func scheduleGapCheck() {
        guard !gapCheckRunning, let gap = recorder.pendingGap else { return }
        gapCheckRunning = true
        let gapStart = Date(timeIntervalSince1970: gap.lastBefore.ts)
        let gapEnd = Date(timeIntervalSince1970: gap.firstAfter.ts)
        Task {
            let samples = await self.detector.motionHistory(from: gapStart, to: gapEnd)
            self.gapCheckRunning = false
            guard self.isRecording, self.recorder.pendingGap != nil else { return }
            if RecordingGap.shouldSplit(gapStart: gapStart, gapEnd: gapEnd, samples: samples) {
                self.splitAtGap()
            } else {
                self.recorder.acceptGap()
            }
        }
    }

    /// Fahrt an der Lücke teilen: erster Teil wird zurückgestellt und gespeichert, die Aufzeichnung läuft als
    /// neue Fahrt (gleiches Fahrzeug, gleiche Quelle) ohne Unterbruch weiter.
    private func splitAtGap() {
        guard isRecording, var old = active, let split = recorder.splitAtGap() else { return }
        old.finished = split.track
        old.points = []
        old.distanceMeters = split.track.distanceKm * 1000
        old.lastMovingAt = split.track.endAt
        tracks.park(old)   // zuerst sichern, dann die laufende Aufzeichnung ersetzen

        var next = TrackStore.ActiveRecording(tenant: old.tenant, vehicleId: old.vehicleId, startedAt: split.newStart,
                                              privateMode: old.privateMode, source: old.source,
                                              distanceMeters: recorder.distanceMeters, points: [], first: nil,
                                              last: nil, finished: nil)
        next.lastMovingAt = recorder.lastPoint.map { Date(timeIntervalSince1970: $0.ts) }
        if !next.privateMode {
            next.first = recorder.firstPoint
            next.last = recorder.lastPoint
        }
        tracks.clearActive()
        if !next.privateMode && !recorder.points.isEmpty { tracks.appendActivePoints(recorder.points) }
        checkpointedPoints = next.privateMode ? 0 : recorder.points.count
        active = next
        tracks.saveActive(next)
        lastCheckpoint = Date()
        recordingStartedAt = split.newStart
        liveDistanceKm = (recorder.distanceMeters / 10).rounded() / 100
        stopSuggested = false
        detector.recordingStarted(auto: next.source == "auto")
        finalizeParked()
    }

    // MARK: Automatik

    /// Start der Automatik (CoreMotion «automotive» bzw. Verbindung zum Auto). Mit Auto-Erkennung startet
    /// «automotive» nur, wenn CarPlay bzw. ein gelerntes Bluetooth-Gerät verbunden ist (Route bei jedem
    /// Weck-Ereignis neu gelesen); `known` = Verbindung, die den Start ausgelöst hat.
    private func autoStart(connection known: CarConnection? = nil) async {
        guard autoDetectEnabled, !isRecording, !isFinishing else { return }
        #if DEBUG
        if Demo.isActive { return }
        #endif
        let car = CarConnectionMonitor.shared
        let connection = known ?? car.connectionNow()
        guard known != nil || CarRouteMatcher.motionStartAllowed(mode: car.mode, connection: connection) else {
            // iOS meldet «im Auto», aber (noch) keine Verbindung: Autoradio/CarPlay verbindet oft erst nach
            // dem Losfahren → Route kurz nachprüfen; eine neue Verbindung startet über handleCarEvent.
            scheduleConnectionRecheck()
            return
        }
        guard let store = await currentStore(), store.canWrite else { return }
        guard let vehicle = automationVehicle(store, preferredId: connection?.vehicleId) else {
            lastError = "Automatik: " + DefaultVehicleChoice.missingText
            return
        }
        await startRecording(vehicle: vehicle, privateMode: autoPrivateMode, source: "auto")
    }

    /// CarPlay/Bluetooth verbunden bzw. getrennt (`CarConnectionMonitor`).
    private func handleCarEvent(_ event: CarConnectionEvent) async {
        guard configured else { return }
        #if DEBUG
        if Demo.isActive { return }
        #endif
        switch event {
        case .connected(let connection):
            disconnectStopTask?.cancel()
            disconnectStopTask = nil
            guard autoDetectEnabled, !isRecording, !isFinishing,
                  CarRouteMatcher.connectStartAllowed(mode: CarConnectionMonitor.shared.mode, connection: connection,
                                                      lastCarMotionAt: detector.lastCarMotionAt) else { return }
            connectionRecheckTask?.cancel()
            connectionRecheckTask = nil
            await autoStart(connection: connection)
        case .disconnected:
            // Starkes Stopp-Signal, aber mit Karenz (Tankstopp, kurz unterbrochene Verbindung)
            guard isRecording, recordingSource == "auto" else { return }
            disconnectStopTask?.cancel()
            disconnectStopTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(TripCoordinator.disconnectGrace * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.stopAfterDisconnect()
            }
        }
    }

    /// Route nach 15 s, 45 s und 90 s erneut lesen (solange die App wach ist). Kommt eine Verbindung hinzu,
    /// meldet der Monitor `.connected` und `handleCarEvent` startet die Fahrt (Fenster `pairingWindow`).
    private func scheduleConnectionRecheck() {
        guard connectionRecheckTask == nil, !CarConnectionMonitor.shared.mode.isOff else { return }
        connectionRecheckTask = Task { [weak self] in
            for delay in [15.0, 30.0, 45.0] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                if self.isRecording { break }
                CarConnectionMonitor.shared.refresh()
            }
            self?.connectionRecheckTask = nil
        }
    }

    private func stopAfterDisconnect() async {
        disconnectStopTask = nil
        guard isRecording, recordingSource == "auto", CarConnectionMonitor.shared.connectionNow() == nil else { return }
        // Fährt noch (Verbindung nur weg)? Dann regulär über die Bewegungserkennung beenden
        guard !detector.movedRecently(within: 60) else { return }
        _ = await stop()   // Ende = letzter Bewegungspunkt
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

    /// Orte für die Weck-Regionen. Ohne geöffneten (bzw. noch gesperrten) Mandanten – z. B. Start im
    /// Hintergrund im Servermodus – die zuletzt bekannten Orte aus dem Cache, damit die Regionen nicht
    /// entfernt werden (Q7).
    private func monitoredPlaces() -> [MonitoredPlace] {
        let defaults = UserDefaults.standard
        guard let store = settings?.store, !store.isPersistenceBlocked else {
            return defaults.data(forKey: Keys.monitoredPlaces)
                .flatMap { try? JSONDecoder().decode([MonitoredPlace].self, from: $0) } ?? []
        }
        let list: [MonitoredPlace] = store.placeList.compactMap { p in
            guard !p.deleted, let lat = p.lat, let lon = p.lon else { return nil }
            return MonitoredPlace(id: p.id, lat: lat, lon: lon, radius: Double(p.radiusM))
        }
        defaults.set(try? JSONEncoder().encode(list), forKey: Keys.monitoredPlaces)
        return list
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
        if let store, store.isMonthClosed(vehicleId: a.vehicleId, month: LogbookRules.month(track.startAt)) {
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
                await TripNotifications.shared.notifyDetected(saved, tenant: a.tenant)
            }
            refreshReminders()
            return trip
        }
        if settings.auth.isLoggedIn && settings.tenants.contains(where: { $0.slug == a.tenant }) {
            // Mandant gerade nicht geöffnet → beim nächsten Öffnen übernehmen
            tracks.addPending(trip, tenant: a.tenant)
            tracks.save(track, tripId: trip.id, tenant: a.tenant, vehicleId: a.vehicleId,
                        confirmed: trip.status == "confirmed")
            lastError = "Fahrt gespeichert – erscheint beim Öffnen von Mandant «\(a.tenant)»."
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

    /// Fahrzeug für Automatik/Siri/CarPlay (Q3): Zuordnung der Auto-Erkennung, sonst ausdrücklich gewähltes
    /// Standardfahrzeug, sonst das einzige Fahrzeug – nie stillschweigend das alphabetisch erste.
    private func automationVehicle(_ store: TenantStore, preferredId: String? = nil) -> Vehicle? {
        let ids = store.vehicleList.map(\.id)
        guard let id = DefaultVehicleChoice.automation(preferredId: preferredId, storedId: store.explicitDefaultVehicleId,
                                                       activeIds: ids) else { return nil }
        return store.vehicle(id: id)
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
