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
/// der Server erhält Start/Ziel als Ortsbezeichnung (Reverse-Geocoding mit auf ~50 m gerundeten
/// Koordinaten auf dem eigenen Server), die Distanzen und den SHA-256 des Tracks. Für die Strassendistanz
/// geht der reduzierte Track an den eigenen Server (`/api/geo/match`, dort nicht gespeichert).
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

    /// Automatische Fahrterkennung (Default aus)
    var autoDetectEnabled: Bool {
        didSet {
            guard oldValue != autoDetectEnabled else { return }
            UserDefaults.standard.set(autoDetectEnabled, forKey: Keys.autoDetect)
            refreshDetector()
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

    @ObservationIgnored private weak var settings: AppSettings?
    @ObservationIgnored private let recorder = TripRecorder()
    @ObservationIgnored private let tracks = TrackStore()
    @ObservationIgnored private let detector = TripDetector()
    @ObservationIgnored private let calendarMatcher = CalendarMatcher()
    @ObservationIgnored private let authorizer = LocationAuthorizer()
    @ObservationIgnored private var active: TrackStore.ActiveRecording?
    @ObservationIgnored private var recordingStore: TenantStore?
    @ObservationIgnored private var lastCheckpoint = Date.distantPast
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
        if !settings.auth.isLoggedIn && !isRecording && UIApplication.shared.isProtectedDataAvailable {
            tracks.deleteAll()   // keine Rohdaten ohne angemeldeten Benutzer
        }
        configured = true
        resumeIfNeeded()
        housekeeping(force: true)
        refreshDetector()
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
            apply(s, to: &current)
            store.save(current)
        }
    }

    /// Standort (zuerst „Beim Verwenden“, dann „Immer“), Bewegung & Fitness, Kalender.
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
        await calendarMatcher.requestAccess()
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
        return "Fahrt beendet (\(km) km). Bitte im Fahrtenbuch prüfen und bestätigen."
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
        tracks.saveActive(a)
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
        checkpoint()
    }

    /// Zwischenstand sichern (alle 30 s), damit ein Beenden der App nichts verliert.
    private func checkpoint() {
        guard var a = active else { return }
        let now = Date()
        guard now.timeIntervalSince(lastCheckpoint) >= 30 else { return }
        lastCheckpoint = now
        a.distanceMeters = recorder.distanceMeters
        if !a.privateMode {
            a.points = recorder.points
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
        active = a
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
        trip.driverName = settings.auth.userName
        trip.driverSub = UserDefaults.standard.string(forKey: "dataOwnerSub")
        trip.distanceGps = track.distanceKm
        trip.trackHash = track.hash

        // Tacho bleibt massgebend: Vorschlag ab letztem bekannten Stand, Nutzer bestätigt/ändert
        if let store, store.vehicle(id: a.vehicleId) != nil {
            let km = store.lastKnownKm(for: a.vehicleId)
            trip.kmStart = km
            trip.kmEnd = km + Int(track.distanceKm.rounded())
        }

        if !a.privateMode {
            if let s = track.start, let p = PlaceLearner.match(lat: s.lat, lon: s.lon, places: places) {
                trip.startPlaceId = p.id
                trip.startLabel = p.name
            }
            if let e = track.end, let p = PlaceLearner.match(lat: e.lat, lon: e.lon, places: places) {
                trip.endPlaceId = p.id
                trip.endLabel = p.name
            }
        }

        // Online-Anreicherung (offline/Fehler → bleibt leer)
        let geo = GeoClient(api: settings.api)
        if a.privateMode {
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
            let points = track.points
            let startPoint = trip.startLabel == nil ? track.start : nil
            let endPoint = trip.endLabel == nil ? track.end : nil
            async let m = geo.match(points)
            async let rs = geo.reverse(startPoint, roundingMeters: 50)
            async let re = geo.reverse(endPoint, roundingMeters: 50)
            let (match, revStart, revEnd) = await (m, rs, re)
            if let match { trip.distanceRoute = (match.distanceKm * 100).rounded() / 100 }
            if let r = revStart { trip.startLabel = Self.label(r) }
            if let r = revEnd { trip.endLabel = Self.label(r) }
        }

        if let store, store.isMonthClosed(vehicleId: a.vehicleId, month: TripTime.month(track.startAt)) {
            trip.note = "Nachtrag nach Monatsabschluss"
        }

        if let store, let s = await suggestion(for: trip, store: store, endPoint: track.end, allowLLM: true) {
            apply(s, to: &trip)
        }

        if let store, store.canWrite {
            store.save(trip)
            tracks.save(track, tripId: trip.id, tenant: a.tenant, vehicleId: a.vehicleId,
                        confirmed: trip.status == "confirmed")
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

    private static func label(_ r: GeoClient.ReverseResult) -> String? {
        let text = r.label?.nilIfEmpty ?? r.municipality?.nilIfEmpty
        return text.map { String($0.prefix(200)) }
    }

    private func apply(_ s: TripSuggestion, to trip: inout Trip) {
        trip.suggestionCategory = s.category
        trip.suggestionPurpose = s.purpose.map { String($0.prefix(300)) }
        trip.suggestionCustomerId = s.customerId
        trip.suggestionConfidence = (min(1, max(0, s.confidence)) * 100).rounded() / 100
        trip.suggestionReason = String(s.reason.prefix(300))
        trip.suggestionSource = s.source
        if s.source == "rule" && s.autoConfirm {
            // Regel mit Auto-Bestätigung (pro Regel aktivierbar, im Review sichtbar)
            trip.category = s.category
            trip.purpose = s.purpose
            trip.customerId = s.customerId
            trip.status = "confirmed"
        } else {
            trip.status = "suggested"
        }
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
        // (4) LLM auf dem eigenen Server – nur pseudonymisierte Merkmale, nie Koordinaten
        guard allowLLM, let settings else { return nil }
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
        let recent = history
            .filter { t in
                t.id != trip.id && !t.deleted && !t.privateMode
                    && (t.status == "confirmed" || t.status == "locked")
                    && TripCategoryText.all.contains(t.category)
            }
            .sorted { (TripTime.parse($0.startAt) ?? .distantPast) > (TripTime.parse($1.startAt) ?? .distantPast) }
            .prefix(20)
            .map { t in
                GeoClient.SuggestRequest.Recent(startLabel: cut(t.startLabel), endLabel: cut(t.endLabel),
                                                category: t.category, purpose: cut(t.purpose))
            }
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
                store.save(trip)
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
