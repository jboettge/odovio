import AVFoundation
import XCTest
@testable import Fahrzeugbuch

/// Fahrterkennung (Q1–Q4), Auto-Erkennung über CarPlay/Bluetooth, Standardfahrzeug (Q3),
/// Einrichtungslink und Token-Bindung (I1).
final class TripDetectionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Endzeit (Q2)

    func testEndDateIsLastMovingPoint() {
        let now = t0.addingTimeInterval(4 * 3600)   // Auswertung Stunden später (App war suspendiert)
        let last = t0.addingTimeInterval(1800)
        XCTAssertEqual(TripTiming.endDate(lastMovingTs: last.timeIntervalSince1970, startedAt: t0, now: now), last)
        XCTAssertEqual(TripTiming.endDate(lastMovingTs: nil, startedAt: t0, now: now), now, "ohne GPS-Punkt: jetzt")
        XCTAssertEqual(TripTiming.endDate(lastMovingTs: t0.addingTimeInterval(-60).timeIntervalSince1970,
                                          startedAt: t0, now: now), t0, "nie vor dem Start")
        XCTAssertEqual(TripTiming.endDate(lastMovingTs: now.addingTimeInterval(60).timeIntervalSince1970,
                                          startedAt: t0, now: now), now, "nie nach jetzt")
    }

    @MainActor
    func testActiveRecordingLastMovementFallback() {
        var a = TrackStore.ActiveRecording(tenant: "t", vehicleId: "v", startedAt: t0, privateMode: true, source: "auto",
                                           distanceMeters: 0, points: [], first: nil, last: nil, finished: nil)
        XCTAssertEqual(a.lastMovement, t0)
        a.last = TrackPoint(lat: 47.37, lon: 8.54, ts: t0.addingTimeInterval(300).timeIntervalSince1970, accuracy: 5)
        XCTAssertEqual(a.lastMovement, t0.addingTimeInterval(300))
        a.lastMovingAt = t0.addingTimeInterval(400)
        XCTAssertEqual(a.lastMovement, t0.addingTimeInterval(400), "auch im Privatmodus ohne Punkte")
    }

    // MARK: Lücken (Q2, Q4)

    func testGapDetectionAndResume() {
        XCTAssertTrue(RecordingGap.isGap(previousTs: 0, nextTs: 601))
        XCTAssertFalse(RecordingGap.isGap(previousTs: 0, nextTs: 600))
        XCTAssertTrue(RecordingGap.endsOnResume(source: "auto", lastMovingAt: t0.addingTimeInterval(-900), now: t0))
        XCTAssertFalse(RecordingGap.endsOnResume(source: "auto", lastMovingAt: t0.addingTimeInterval(-120), now: t0),
                       "Jetsam während der Fahrt → fortsetzen")
        XCTAssertFalse(RecordingGap.endsOnResume(source: "manual", lastMovingAt: t0.addingTimeInterval(-3600), now: t0),
                       "manuelle Fahrt beendet der Nutzer")
    }

    func testGapSplitsParkedTrips() {
        let end = t0.addingTimeInterval(1800)
        XCTAssertTrue(RecordingGap.shouldSplit(gapStart: t0, gapEnd: end, samples: nil), "ohne CoreMotion: teilen")
        XCTAssertTrue(RecordingGap.shouldSplit(gapStart: t0, gapEnd: end, samples: []))
        // Ausgestiegen und gegangen
        let walked = [MotionSample(automotive: true, date: t0.addingTimeInterval(-600)),
                      MotionSample(automotive: false, onFoot: true, date: t0.addingTimeInterval(60)),
                      MotionSample(automotive: false, stationary: true, date: t0.addingTimeInterval(400))]
        XCTAssertTrue(RecordingGap.shouldSplit(gapStart: t0, gapEnd: end, samples: walked))
        // iPhone im parkierten Auto liegen gelassen: nur «stillstehend»
        let parked = [MotionSample(automotive: true, date: t0.addingTimeInterval(-600)),
                      MotionSample(automotive: false, stationary: true, date: t0.addingTimeInterval(30))]
        XCTAssertTrue(RecordingGap.shouldSplit(gapStart: t0, gapEnd: end, samples: parked))
    }

    func testGapInTrafficJamStaysOneTrip() {
        let end = t0.addingTimeInterval(1800)
        // «automotive» begann vor der Lücke und dauert an (CoreMotion meldet nur Wechsel)
        XCTAssertFalse(RecordingGap.shouldSplit(gapStart: t0, gapEnd: end,
                                           samples: [MotionSample(automotive: true, date: t0.addingTimeInterval(-300))]))
        // «automotive» + «stationary» (Stau, Rotlicht)
        let jam = [MotionSample(automotive: true, date: t0.addingTimeInterval(-300)),
                   MotionSample(automotive: true, stationary: true, date: t0.addingTimeInterval(120))]
        XCTAssertFalse(RecordingGap.shouldSplit(gapStart: t0, gapEnd: end, samples: jam))
        // kurze Fehlerkennung «zu Fuss» (< 60 s) im Stau
        let blip = [MotionSample(automotive: true, date: t0.addingTimeInterval(-300)),
                    MotionSample(automotive: false, onFoot: true, date: t0.addingTimeInterval(100)),
                    MotionSample(automotive: true, date: t0.addingTimeInterval(130))]
        XCTAssertFalse(RecordingGap.shouldSplit(gapStart: t0, gapEnd: end, samples: blip))
        // Lücke ≤ 10 min wird nie geteilt
        XCTAssertFalse(RecordingGap.shouldSplit(gapStart: t0, gapEnd: t0.addingTimeInterval(500), samples: nil))
    }

    // MARK: Stopp (Q2, Q4)

    func testStopRule() {
        let now = t0
        func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }
        // Stau: 15 min ohne GPS-Bewegung, CoreMotion weiterhin «automotive» → weiter (Q4)
        XCTAssertFalse(TripStopRule.shouldStop(now: now, lastAutomotiveAt: ago(900), lastMovingAt: ago(900),
                                               watchStartedAt: ago(3600), stillInCar: true, stationarySince: ago(900)))
        // Parkiert: nicht mehr «automotive», seit 4 min keine Bewegung → Ende
        XCTAssertTrue(TripStopRule.shouldStop(now: now, lastAutomotiveAt: ago(240), lastMovingAt: ago(240),
                                              watchStartedAt: ago(3600), stillInCar: false, stationarySince: nil))
        // iOS meldet Stillstand seit 90 s, CoreMotion seit 2 min nicht mehr «automotive» → früh beenden
        XCTAssertTrue(TripStopRule.shouldStop(now: now, lastAutomotiveAt: ago(120), lastMovingAt: ago(100),
                                              watchStartedAt: ago(3600), stillInCar: false, stationarySince: ago(90)))
        // Stillstand gemeldet, aber «automotive» vor 30 s (Rotlicht) → weiter
        XCTAssertFalse(TripStopRule.shouldStop(now: now, lastAutomotiveAt: ago(30), lastMovingAt: ago(100),
                                               watchStartedAt: ago(3600), stillInCar: false, stationarySince: ago(90)))
        // kurz nach dem Start
        XCTAssertFalse(TripStopRule.shouldStop(now: now, lastAutomotiveAt: nil, lastMovingAt: ago(10),
                                               watchStartedAt: ago(10), stillInCar: false, stationarySince: nil))
    }

    // MARK: Laufende Aufzeichnung gesperrt (Q1)

    @MainActor
    func testLockedActiveRecordingIsParkedNotDeleted() throws {
        let dir = Fixture.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TrackStore(directory: dir)
        guard case .none = store.loadActiveState() else { return XCTFail("leer erwartet") }

        let a = TrackStore.ActiveRecording(tenant: "t", vehicleId: "v", startedAt: t0, privateMode: false, source: "auto",
                                           distanceMeters: 1200, points: [], first: nil, last: nil, finished: nil)
        store.saveActive(a)
        store.appendActivePoints([TrackPoint(lat: 47.37, lon: 8.54, ts: t0.timeIntervalSince1970 + 10, accuracy: 5)])
        guard case .recording(let loaded) = store.loadActiveState() else { return XCTFail("lesbar erwartet") }
        XCTAssertEqual(loaded.points.count, 1)

        // «Datei vorhanden, aber nicht lesbar» (gesperrt) nachstellen: Verzeichnis statt Datei
        store.clearActive()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("active.json"),
                                                withIntermediateDirectories: true)
        guard case .unreadable = store.loadActiveState() else { return XCTFail("unlesbar erwartet") }
        XCTAssertNil(store.loadActive())

        // Neue Fahrt: gesperrte Aufzeichnung wird zurückgestellt statt gelöscht
        store.parkActive()
        guard case .none = store.loadActiveState() else { return XCTFail("Platz für neue Fahrt erwartet") }
        XCTAssertTrue(store.parkedRecordings().isEmpty, "noch gesperrt → bleibt liegen")
        let parked = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Parked").path)
        XCTAssertEqual(parked.count, 1)
    }

    @MainActor
    func testParkedFinishedRecordingRoundTrip() {
        let dir = Fixture.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TrackStore(directory: dir)
        var a = TrackStore.ActiveRecording(tenant: "t", vehicleId: "v", startedAt: t0, privateMode: true, source: "auto",
                                           distanceMeters: 5000, points: [], first: nil, last: nil, finished: nil)
        a.finished = TripRecorder.makeTrack(points: [], distanceMeters: 5000, startAt: t0, endAt: t0.addingTimeInterval(600),
                                            first: nil, last: nil, privateMode: true)
        a.lastMovingAt = t0.addingTimeInterval(600)
        store.park(a)
        let parked = store.parkedRecordings()
        XCTAssertEqual(parked.count, 1)
        XCTAssertEqual(parked.first?.recording.finished?.distanceKm, 5)
        XCTAssertEqual(parked.first?.recording.finished?.endAt, t0.addingTimeInterval(600))
        XCTAssertEqual(parked.first?.recording.lastMovement, t0.addingTimeInterval(600))
        if let first = parked.first { store.removeParked(first.directory) }
        XCTAssertTrue(store.parkedRecordings().isEmpty)
    }

    // MARK: Standardfahrzeug (Q3)

    func testAutomationVehicleChoice() {
        XCTAssertNil(DefaultVehicleChoice.automation(preferredId: nil, storedId: nil, activeIds: ["a", "b"]),
                     "mehrere Fahrzeuge ohne Wahl → kein Raten")
        XCTAssertEqual(DefaultVehicleChoice.automation(preferredId: nil, storedId: nil, activeIds: ["a"]), "a")
        XCTAssertEqual(DefaultVehicleChoice.automation(preferredId: nil, storedId: "b", activeIds: ["a", "b"]), "b")
        XCTAssertEqual(DefaultVehicleChoice.automation(preferredId: "a", storedId: "b", activeIds: ["a", "b"]), "a",
                       "Zuordnung des Bluetooth-Geräts vor Standardfahrzeug")
        XCTAssertEqual(DefaultVehicleChoice.automation(preferredId: "x", storedId: "b", activeIds: ["a", "b"]), "b")
        XCTAssertNil(DefaultVehicleChoice.automation(preferredId: nil, storedId: "x", activeIds: ["a", "b"]),
                     "storniertes Standardfahrzeug")
        XCTAssertNil(DefaultVehicleChoice.automation(preferredId: nil, storedId: nil, activeIds: []))
    }

    @MainActor
    func testExplicitDefaultVehicleOnlyWhenChosen() {
        let dir = Fixture.tempDirectory()
        let store = TenantStore(localDirectory: dir)
        let key = "defaultVehicle-\(store.tenant.slug)"
        let previous = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            UserDefaults.standard.set(previous, forKey: key)
            try? FileManager.default.removeItem(at: dir)
        }
        let second = "22222222-2222-4222-8222-222222222222"
        store.save(Vehicle(id: Fixture.vehicleId, name: "Audi", initialKm: 1000))
        store.save(Vehicle(id: second, name: "BMW", initialKm: 1000))
        XCTAssertNil(store.explicitDefaultVehicleId)
        XCTAssertEqual(store.defaultVehicleId, Fixture.vehicleId, "Anzeige: erstes Fahrzeug")
        store.defaultVehicleId = second
        XCTAssertEqual(store.explicitDefaultVehicleId, second)
    }

    // MARK: Auto-Erkennung (CarPlay / Bluetooth)

    func testDeviceKeyIgnoresBluetoothProfileSuffix() {
        XCTAssertEqual(CarRouteMatcher.deviceKey(uid: "00:11:22:AA:BB:CC-tacl", name: "Golf"), "00:11:22:aa:bb:cc")
        XCTAssertEqual(CarRouteMatcher.deviceKey(uid: "00:11:22:AA:BB:CC-tsco", name: "Golf"), "00:11:22:aa:bb:cc")
        XCTAssertEqual(CarRouteMatcher.deviceKey(uid: "", name: " Mein Auto "), "name:mein auto")
        XCTAssertEqual(CarRouteMatcher.deviceKey(uid: "CarAudio-1234", name: "x"), "caraudio-1234")
    }

    func testRouteMatching() {
        let a2dp = AVAudioSession.Port.bluetoothA2DP.rawValue
        let golf = CarDevice(uid: "00:11:22:AA:BB:CC-tacl", name: "Golf", vehicleId: "v1")
        let speaker = AudioPortInfo(type: AVAudioSession.Port.builtInSpeaker.rawValue, uid: "Speaker", name: "Lautsprecher")
        let carHFP = AudioPortInfo(type: AVAudioSession.Port.bluetoothHFP.rawValue, uid: "00:11:22:aa:bb:cc-tsco",
                                   name: "Golf")
        let airpods = AudioPortInfo(type: a2dp, uid: "AA:AA:AA:AA:AA:AA-tacl", name: "AirPods")
        let carPlay = AudioPortInfo(type: AVAudioSession.Port.carAudio.rawValue, uid: "CarPlay-1", name: "CarPlay")

        // Aus: nur eine verbundene CarPlay-Szene zählt
        XCTAssertNil(CarRouteMatcher.connection(mode: .off, outputs: [carHFP], devices: [golf],
                                                carPlaySceneConnected: false, carPlayVehicleId: nil))
        let scene = CarRouteMatcher.connection(mode: .off, outputs: [], devices: [], carPlaySceneConnected: true,
                                               carPlayVehicleId: "v2")
        XCTAssertEqual(scene?.kind, .carPlayScene)
        XCTAssertEqual(scene?.vehicleId, "v2")
        // Bluetooth: gelerntes Gerät (anderes Profil) → Fahrzeug der Zuordnung
        let bt = CarRouteMatcher.connection(mode: .bluetooth, outputs: [speaker, carHFP], devices: [golf],
                                            carPlaySceneConnected: false, carPlayVehicleId: nil)
        XCTAssertEqual(bt?.kind, .bluetooth)
        XCTAssertEqual(bt?.vehicleId, "v1")
        XCTAssertNil(CarRouteMatcher.connection(mode: .bluetooth, outputs: [airpods], devices: [golf],
                                                carPlaySceneConnected: false, carPlayVehicleId: nil),
                     "Kopfhörer sind kein Auto")
        // CarPlay: Route .carAudio
        let cp = CarRouteMatcher.connection(mode: .carPlay, outputs: [carPlay], devices: [], carPlaySceneConnected: false,
                                            carPlayVehicleId: "v3")
        XCTAssertEqual(cp?.kind, .carPlayRoute)
        XCTAssertEqual(cp?.vehicleId, "v3")
        XCTAssertNil(CarRouteMatcher.connection(mode: .carPlay, outputs: [carHFP], devices: [golf],
                                                carPlaySceneConnected: false, carPlayVehicleId: nil))
        // Lernbar: nur Bluetooth/CarPlay-Audio
        XCTAssertEqual(CarRouteMatcher.learnable([speaker, airpods, carPlay]).map(\.name), ["AirPods", "CarPlay"])
    }

    /// CarPlay und Bluetooth gleichzeitig: Auto ohne CarPlay über Bluetooth, sonst CarPlay-Audio.
    func testCarPlayAndBluetoothCombined() {
        let golf = CarDevice(uid: "00:11:22:AA:BB:CC-tacl", name: "Golf", vehicleId: "v1")
        let carHFP = AudioPortInfo(type: AVAudioSession.Port.bluetoothHFP.rawValue, uid: "00:11:22:aa:bb:cc-tsco",
                                   name: "Golf")
        let carPlay = AudioPortInfo(type: AVAudioSession.Port.carAudio.rawValue, uid: "CarPlay-1", name: "CarPlay")
        let both = CarDetectionMode.carPlayAndBluetooth
        // Auto ohne CarPlay → Bluetooth
        let bt = CarRouteMatcher.connection(mode: both, outputs: [carHFP], devices: [golf],
                                            carPlaySceneConnected: false, carPlayVehicleId: "v3")
        XCTAssertEqual(bt?.kind, .bluetooth)
        XCTAssertEqual(bt?.vehicleId, "v1")
        // Auto mit CarPlay (kein gelerntes Gerät) → CarPlay
        let cp = CarRouteMatcher.connection(mode: both, outputs: [carPlay], devices: [golf],
                                            carPlaySceneConnected: false, carPlayVehicleId: "v3")
        XCTAssertEqual(cp?.kind, .carPlayRoute)
        XCTAssertEqual(cp?.vehicleId, "v3")
        // Nichts verbunden → kein Start auf «automotive»
        let none = CarRouteMatcher.connection(mode: both, outputs: [], devices: [golf],
                                              carPlaySceneConnected: false, carPlayVehicleId: nil)
        XCTAssertNil(none)
        XCTAssertFalse(CarRouteMatcher.motionStartAllowed(mode: both, connection: none))
        XCTAssertTrue(CarRouteMatcher.motionStartAllowed(mode: both, connection: bt))
    }

    /// Gespeicherter Wert: frühere Einzelwerte bleiben gültig, Kombination neu.
    func testCarDetectionModeStorage() {
        XCTAssertEqual(CarDetectionMode(rawValue: "off"), .off)
        XCTAssertEqual(CarDetectionMode(rawValue: "carPlay"), .carPlay)
        XCTAssertEqual(CarDetectionMode(rawValue: "bluetooth"), .bluetooth)
        XCTAssertEqual(CarDetectionMode(rawValue: "carPlay+bluetooth"), .carPlayAndBluetooth)
        XCTAssertNil(CarDetectionMode(rawValue: "wlan"))
        XCTAssertNil(CarDetectionMode(rawValue: ""))
        for m in [CarDetectionMode.off, .carPlay, .bluetooth, .carPlayAndBluetooth] {
            XCTAssertEqual(CarDetectionMode(rawValue: m.rawValue), m)
        }
        XCTAssertTrue(CarDetectionMode.off.isOff)
        XCTAssertEqual(CarDetectionMode.carPlayAndBluetooth.label, "CarPlay und Bluetooth")
    }

    func testStartConditionWithCarDetection() {
        let bt = CarConnection(kind: .bluetooth, name: "Golf", deviceKey: "k", vehicleId: nil)
        let scene = CarConnection(kind: .carPlayScene, name: "CarPlay", deviceKey: nil, vehicleId: nil)
        // CoreMotion «automotive»
        XCTAssertTrue(CarRouteMatcher.motionStartAllowed(mode: .off, connection: nil))
        XCTAssertFalse(CarRouteMatcher.motionStartAllowed(mode: .bluetooth, connection: nil), "Zug/Tram/Bus")
        XCTAssertTrue(CarRouteMatcher.motionStartAllowed(mode: .bluetooth, connection: bt))
        XCTAssertFalse(CarRouteMatcher.motionStartAllowed(mode: .carPlay, connection: nil))
        // Verbinden: direkt starten, ausser CoreMotion meldet «zu Fuss»
        let walking = MotionSample(automotive: false, onFoot: true, date: t0)
        let sitting = MotionSample(automotive: false, stationary: true, date: t0)
        XCTAssertTrue(CarRouteMatcher.connectStartAllowed(mode: .bluetooth, connection: bt, latestMotion: sitting))
        XCTAssertTrue(CarRouteMatcher.connectStartAllowed(mode: .bluetooth, connection: bt, latestMotion: nil))
        XCTAssertFalse(CarRouteMatcher.connectStartAllowed(mode: .bluetooth, connection: bt, latestMotion: walking))
        XCTAssertFalse(CarRouteMatcher.connectStartAllowed(mode: .bluetooth, connection: nil, latestMotion: nil))
        XCTAssertFalse(CarRouteMatcher.connectStartAllowed(mode: .off, connection: bt, latestMotion: sitting))
        XCTAssertTrue(CarRouteMatcher.connectStartAllowed(mode: .off, connection: scene, latestMotion: walking),
                      "CarPlay-Szene verbunden = im Auto")
    }

    // MARK: Einrichtungslink und Token-Bindung (I1)

    func testSetupLinkAlwaysConfirmsNewServer() {
        let link = URL(string: "fahrzeugbuch://setup?server=https://evil.example/")!
        let ask = ServerLink.SetupDecision.confirm(server: "https://evil.example", host: "evil.example", replacing: nil)
        XCTAssertEqual(ServerLink.setupDecision(link: link, mode: nil, currentServer: ""), ask,
                       "auch ohne Betriebsart nur mit Rückfrage")
        XCTAssertEqual(ServerLink.setupDecision(link: link, mode: .server, currentServer: "  "), ask)
        XCTAssertEqual(ServerLink.setupDecision(link: link, mode: .server, currentServer: "https://fzb.example.ch"),
                       .confirm(server: "https://evil.example", host: "evil.example", replacing: "fzb.example.ch"))
        XCTAssertEqual(ServerLink.setupDecision(link: link, mode: nil, currentServer: "https://fzb.example.ch"),
                       .confirm(server: "https://evil.example", host: "evil.example", replacing: "fzb.example.ch"))
        XCTAssertEqual(ServerLink.setupDecision(link: link, mode: .local, currentServer: ""),
                       .suggestForTransfer(server: "https://evil.example"))
        let same = URL(string: "fahrzeugbuch://setup?server=https://FZB.example.ch/")!
        XCTAssertEqual(ServerLink.setupDecision(link: same, mode: .server, currentServer: "https://fzb.example.ch"),
                       .alreadyConfigured)
        XCTAssertEqual(ServerLink.setupDecision(link: URL(string: "fahrzeugbuch://setup?server=http://evil.example")!,
                                                mode: nil, currentServer: ""), .invalid)
        XCTAssertEqual(ServerLink.setupDecision(link: URL(string: "fahrzeugbuch://setup")!, mode: nil, currentServer: ""),
                       .invalid)
    }

    func testTokenBindingToServerAndIssuer() {
        XCTAssertEqual(TokenBinding.normalize("https://Fzb.Example.ch/"), "https://fzb.example.ch")
        XCTAssertEqual(TokenBinding.normalize(" https://fzb.example.ch/api/ "), "https://fzb.example.ch/api")
        let binding = TokenBinding(server: TokenBinding.normalize("https://fzb.example.ch"),
                                   issuer: "https://id.example.ch/realms/fzb", clientId: "fahrzeugbuch-ios")
        XCTAssertTrue(binding.allows(server: URL(string: "https://FZB.example.ch/")!))
        XCTAssertFalse(binding.allows(server: URL(string: "https://evil.example")!))
        XCTAssertFalse(binding.allows(server: URL(string: "https://fzb.example.ch:8443")!))
        XCTAssertTrue(binding.allows(issuer: "https://id.example.ch/realms/fzb", clientId: "fahrzeugbuch-ios"))
        XCTAssertFalse(binding.allows(issuer: "https://id.example.ch/realms/other", clientId: "fahrzeugbuch-ios"))
        XCTAssertFalse(binding.allows(issuer: "https://id.example.ch/realms/fzb", clientId: "anderer-client"))
    }
}
