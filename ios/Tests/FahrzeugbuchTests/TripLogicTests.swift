import XCTest
@testable import Fahrzeugbuch

/// Regeln, Vorschläge, Ortslernen, Datenschutz-Kappung, Track-Aufbewahrung, Statistik.
final class TripLogicTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Zurich")!
        return c
    }()

    private func date(_ s: String) -> Date { ISODate.parse(s)! }

    private func facts(start: String, from: String? = "home", to: String? = "office") -> TripFacts {
        TripFacts(tripId: "new", vehicleId: "v", start: date(start), end: nil, startPlaceId: from, endPlaceId: to)
    }

    // MARK: RuleEngine

    func testRulePriorityAndConditions() {
        let general = PurposeRule(id: "r1", priority: 100, fromPlaceId: "home", toPlaceId: "office",
                                  weekdays: "1,2,3,4,5", resultCategory: "commute")
        let morning = PurposeRule(id: "r2", priority: 50, toPlaceId: "office", timeFrom: "06:00", timeTo: "09:00",
                                  resultCategory: "business", resultPurpose: "Frühtermin")
        let inactive = PurposeRule(id: "r3", priority: 1, toPlaceId: "office", resultCategory: "private", active: false)
        let rules = [general, morning, inactive]

        // Dienstag 07:30 → Regel mit kleinerer Priorität gewinnt
        let s1 = RuleEngine.ruleSuggestion(rules: rules, facts: facts(start: "2026-11-24T07:30:00+01:00"),
                                           calendar: calendar)
        XCTAssertEqual(s1?.category, "business")
        XCTAssertEqual(s1?.ruleId, "r2")
        // Dienstag 12:00 → nur die allgemeine Regel passt
        let s2 = RuleEngine.ruleSuggestion(rules: rules, facts: facts(start: "2026-11-24T12:00:00+01:00"),
                                           calendar: calendar)
        XCTAssertEqual(s2?.category, "commute")
        // Samstag 12:00 → keine Regel
        XCTAssertNil(RuleEngine.ruleSuggestion(rules: rules, facts: facts(start: "2026-11-28T12:00:00+01:00"),
                                               calendar: calendar))
        // Regel ohne Bedingung wird ignoriert
        XCTAssertFalse(RuleEngine.matches(PurposeRule(resultCategory: "business"),
                                          facts(start: "2026-11-24T12:00:00+01:00"), calendar: calendar))
    }

    func testNightRuleOverMidnight() {
        let night = PurposeRule(toPlaceId: "office", timeFrom: "22:00", timeTo: "02:00", resultCategory: "field")
        XCTAssertTrue(RuleEngine.matches(night, facts(start: "2026-11-24T23:30:00+01:00"), calendar: calendar))
        XCTAssertTrue(RuleEngine.matches(night, facts(start: "2026-11-25T01:00:00+01:00"), calendar: calendar))
        XCTAssertFalse(RuleEngine.matches(night, facts(start: "2026-11-25T03:00:00+01:00"), calendar: calendar))
    }

    func testAutoConfirmSkipsEstimatedKm() {
        let s = TripSuggestion(category: "commute", purpose: "Arbeitsweg", customerId: nil, confidence: 0.97,
                               reason: "Regel", source: "rule", autoConfirm: true, ruleId: "r")
        var exact = Trip(vehicleId: "v", startAt: "2026-11-24T07:30:00+01:00")
        RuleEngine.apply(s, to: &exact)
        XCTAssertEqual(exact.status, "confirmed")
        XCTAssertEqual(exact.category, "commute")

        var estimated = Trip(vehicleId: "v", startAt: "2026-11-24T07:30:00+01:00", kmEstimated: true)
        RuleEngine.apply(s, to: &estimated)
        XCTAssertEqual(estimated.status, "suggested")
        XCTAssertEqual(estimated.category, "unknown")
        XCTAssertEqual(estimated.suggestionCategory, "commute")
    }

    func testPatternSuggestion() {
        var history: [Trip] = []
        for (n, day) in ["2026-11-10", "2026-11-12", "2026-11-17", "2026-11-19"].enumerated() {
            history.append(Trip(id: "h\(n)", vehicleId: "v", startAt: "\(day)T07:30:00+01:00", startPlaceId: "home",
                                endPlaceId: "office", category: "commute", status: "confirmed"))
        }
        let s = RuleEngine.patternSuggestion(facts: facts(start: "2026-11-24T07:30:00+01:00"), history: history)
        XCTAssertEqual(s?.category, "commute")
        XCTAssertEqual(s?.source, "pattern")
        XCTAssertNil(RuleEngine.patternSuggestion(facts: facts(start: "2026-11-24T07:30:00+01:00"),
                                                  history: Array(history.prefix(2))))
    }

    func testLLMContextNeverContainsPrivateTrips() {
        let trips = [
            Trip(id: "a", vehicleId: "v", startAt: "2026-11-20T08:00:00+01:00", startLabel: "Büro",
                 category: "business", purpose: "Kunde", status: "confirmed"),
            Trip(id: "b", vehicleId: "v", startAt: "2026-11-21T08:00:00+01:00", startLabel: "Praxis",
                 category: "private", purpose: "Arzt", status: "confirmed"),
            Trip(id: "c", vehicleId: "v", startAt: "2026-11-22T08:00:00+01:00", category: "business",
                 status: "confirmed", privateMode: true),
            Trip(id: "d", vehicleId: "v", startAt: "2026-11-23T08:00:00+01:00", category: "business",
                 status: "suggested"),
        ]
        let recent = GeoClient.SuggestRequest.recentContext(history: trips, excluding: nil)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.purpose, "Kunde")
    }

    // MARK: PlaceLearner

    func testPlaceMatchAndCandidates() {
        let office = Place(id: "office", name: "Büro", kind: "work", lat: 47.3770, lon: 8.5400, radiusM: 150)
        XCTAssertEqual(PlaceLearner.match(lat: 47.3775, lon: 8.5401, places: [office])?.id, "office")
        XCTAssertNil(PlaceLearner.match(lat: 47.39, lon: 8.54, places: [office]))

        let gym = (47.4000, 8.5000)
        var samples: [PlaceLearner.Sample] = []
        for n in 0..<3 { samples.append(.init(lat: gym.0 + Double(n) * 0.0001, lon: gym.1, label: "Fitness")) }
        samples.append(.init(lat: 47.3771, lon: 8.5400, label: "Büro"))   // bekannter Ort
        samples.append(.init(lat: 46.0, lon: 7.0, label: nil))            // einmalig
        let candidates = PlaceLearner.candidates(samples: samples, places: [office])
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.visits, 3)
        XCTAssertEqual(candidates.first?.suggestedLabel, "Fitness")
    }

    func testRuleCandidatesFromRepeatedTrips() {
        let now = date("2026-11-25T12:00:00+01:00")
        var trips: [Trip] = []
        for (n, day) in ["2026-11-16", "2026-11-18", "2026-11-20"].enumerated() {
            trips.append(Trip(id: "t\(n)", vehicleId: "v", startAt: "\(day)T07:\(1 + n)0:00+01:00",
                              startPlaceId: "home", endPlaceId: "office", category: "commute", status: "confirmed"))
        }
        let rules = PlaceLearner.ruleCandidates(trips: trips, rules: [], now: now, calendar: calendar)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.origin, "learned")
        XCTAssertEqual(rules.first?.autoConfirm, false)
        XCTAssertEqual(rules.first?.resultCategory, "commute")
        XCTAssertNotNil(rules.first?.timeFrom)
        // Regel existiert bereits → kein Vorschlag
        let existing = PurposeRule(fromPlaceId: "home", toPlaceId: "office", resultCategory: "commute")
        XCTAssertTrue(PlaceLearner.ruleCandidates(trips: trips, rules: [existing], now: now, calendar: calendar).isEmpty)
    }

    // MARK: Datenschutz-Kappung (S2)

    func testTrackTrimmingCutsEndsAndHomeZone() {
        // Gerade Strecke nach Norden, ~111 m je 0.001°
        let points = (0...30).map { TrackPoint(lat: 47.0 + Double($0) * 0.001, lon: 8.5, ts: Double($0) * 10, accuracy: 5) }
        let trimmed = GeoPrivacy.trimmed(points, zones: [])
        XCTAssertGreaterThanOrEqual(GeoMath.distance(points[0], trimmed[0]), GeoPrivacy.cutMeters)
        XCTAssertGreaterThanOrEqual(GeoMath.distance(points.last!, trimmed.last!), GeoPrivacy.cutMeters)

        let home = Place(name: "Zuhause", kind: "home", lat: 47.015, lon: 8.5, radiusM: 100)
        let zones = GeoPrivacy.zones([home])
        XCTAssertEqual(zones.first?.radius, GeoPrivacy.minHomeRadius)
        let withHome = GeoPrivacy.trimmed(points, zones: zones)
        XCTAssertFalse(withHome.contains { GeoPrivacy.isProtected($0, zones: zones) })
        XCTAssertLessThan(withHome.count, trimmed.count)

        // Zu kurz → nichts übertragen
        XCTAssertTrue(GeoPrivacy.trimmed(Array(points.prefix(3)), zones: []).isEmpty)
        // Andere Orte erzeugen keine Schutzzone
        XCTAssertTrue(GeoPrivacy.zones([Place(name: "Büro", kind: "work", lat: 47.0, lon: 8.5)]).isEmpty)
    }

    // MARK: Statistik

    func testConsumptionFullToFull() {
        let v = Vehicle(name: "Golf", initialKm: 1000)
        let fuel = [
            FuelEntry(vehicleId: v.id, date: Fixture.day("2026-10-01"), km: 1000, liters: 40, priceTotal: 70),
            FuelEntry(vehicleId: v.id, date: Fixture.day("2026-10-10"), km: 1300, liters: 10, priceTotal: 18,
                      fullTank: false),
            FuelEntry(vehicleId: v.id, date: Fixture.day("2026-10-20"), km: 1600, liters: 26, priceTotal: 46),
        ]
        let points = StatsCalculator.consumptionPoints(fuel)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].distance, 600)
        XCTAssertEqual(points[0].liters, 36, accuracy: 0.001)
        XCTAssertEqual(points[0].consumption, 6, accuracy: 0.001)
        let stats = StatsCalculator.stats(vehicle: v, odometer: [], fuel: fuel, maintenance: [], materials: [],
                                          today: Fixture.day("2026-11-25"))
        XCTAssertEqual(stats.currentKm, 1600)
        XCTAssertEqual(stats.drivenKm, 600)
        XCTAssertEqual(stats.avgConsumption ?? 0, 6, accuracy: 0.001)
    }

    func testDueItems() {
        let v = Vehicle(name: "Golf", initialKm: 1000)
        let old = Maintenance(vehicleId: v.id, date: Fixture.day("2025-11-01"), km: 1000, title: "Service",
                              nextDueKm: 20000)
        let latest = Maintenance(vehicleId: v.id, date: Fixture.day("2026-11-01"), km: 15000, title: "service",
                                 nextDueKm: 15500, nextDueDate: Fixture.day("2027-11-01"))
        let tires = Maintenance(vehicleId: v.id, date: Fixture.day("2026-04-01"), title: "Reifen",
                                nextDueDate: Fixture.day("2026-11-10"))
        let stats = StatsCalculator.stats(vehicle: v, odometer: [], fuel: [], maintenance: [old, latest, tires],
                                          materials: [], today: Fixture.day("2026-11-25"))
        XCTAssertEqual(stats.due.count, 2)                 // nur die neueste Wartung je Titel
        XCTAssertEqual(stats.due.first?.title, "Reifen")   // überfällig zuerst
        XCTAssertTrue(stats.due.first?.overdue ?? false)
        XCTAssertTrue(stats.due.last?.dueSoon ?? false)    // 500 km vor Fälligkeit
    }
}

/// Track-Aufbewahrung (30 Tage nach Bestätigung, Endpunkte 90 Tage, Storno sofort) und Segment-Log.
final class TrackStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = Fixture.tempDirectory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    private func track(start: Date) -> RecordedTrack {
        let pts = (0..<5).map { TrackPoint(lat: 47 + Double($0) * 0.001, lon: 8.5, ts: start.timeIntervalSince1970 + Double($0), accuracy: 5) }
        return RecordedTrack(points: pts, distanceKm: 0.5, startAt: start, endAt: start.addingTimeInterval(600),
                             start: pts.first, end: pts.last, hash: "h", privateMode: false)
    }

    @MainActor
    func testRetention() async {
        let tracks = TrackStore(directory: directory.appendingPathComponent("Tracks"))
        let api = MockServer().api()
        let store = TenantStore(tenant: TenantInfo(slug: "firma", role: "write"), api: { api },
                                directory: directory)
        store.autoSyncEnabled = false
        let now = Date()
        let tripStart = now.addingTimeInterval(-40 * 86_400)
        let ids = ["aaaaaaaa-0000-4000-8000-000000000001", "aaaaaaaa-0000-4000-8000-000000000002",
                   "aaaaaaaa-0000-4000-8000-000000000003", "aaaaaaaa-0000-4000-8000-000000000004"]
        // 1: bestätigt vor 40 Tagen → Track weg, Endpunkte bleiben
        store.save(Trip(id: ids[0], vehicleId: "v", startAt: ISODate.string(tripStart), category: "business",
                        status: "confirmed"))
        tracks.save(track(start: tripStart), tripId: ids[0], tenant: "firma", vehicleId: "v", confirmed: false)
        // 2: storniert → alles weg
        let cancelled = Trip(id: ids[1], vehicleId: "v", startAt: ISODate.string(now), category: "business",
                             status: "confirmed")
        store.save(cancelled)
        store.delete(cancelled)
        tracks.save(track(start: now), tripId: ids[1], tenant: "firma", vehicleId: "v", confirmed: false)
        // 3: Entwurf, frisch → bleibt
        store.save(Trip(id: ids[2], vehicleId: "v", startAt: ISODate.string(now)))
        tracks.save(track(start: now), tripId: ids[2], tenant: "firma", vehicleId: "v", confirmed: false)
        // 4: älter als 90 Tage → alles weg
        let ancient = now.addingTimeInterval(-100 * 86_400)
        tracks.save(track(start: ancient), tripId: ids[3], tenant: "firma", vehicleId: "v", confirmed: true)

        // Bestätigung wird beim ersten Aufräumen vermerkt; 31 Tage später ist der Track weg
        tracks.purge(store: store, now: now)
        XCTAssertNotNil(tracks.track(tripId: ids[0]))
        XCTAssertNil(tracks.meta(tripId: ids[1]))
        XCTAssertNotNil(tracks.track(tripId: ids[2]))
        XCTAssertNil(tracks.meta(tripId: ids[3]))

        tracks.purge(store: store, now: now.addingTimeInterval(31 * 86_400))
        XCTAssertNil(tracks.track(tripId: ids[0]))
        XCTAssertNotNil(tracks.meta(tripId: ids[0]))
        XCTAssertEqual(tracks.meta(tripId: ids[0])?.hasTrack, false)
    }

    @MainActor
    func testPrivateModeStoresNothing() async {
        let tracks = TrackStore(directory: directory.appendingPathComponent("Tracks"))
        var t = track(start: Date())
        t.privateMode = true
        tracks.save(t, tripId: "bbbbbbbb-0000-4000-8000-000000000001", tenant: "firma", vehicleId: "v", confirmed: false)
        XCTAssertNil(tracks.meta(tripId: "bbbbbbbb-0000-4000-8000-000000000001"))
    }

    @MainActor
    func testActiveRecordingSegmentsAppendAndClear() async {
        let tracks = TrackStore(directory: directory.appendingPathComponent("Tracks"))
        let start = Date()
        let a = TrackStore.ActiveRecording(tenant: "firma", vehicleId: "v", startedAt: start, privateMode: false,
                                           source: "manual", distanceMeters: 0, points: [], first: nil, last: nil,
                                           finished: nil)
        tracks.saveActive(a)
        let p1 = (0..<3).map { TrackPoint(lat: 47, lon: 8 + Double($0) * 0.001, ts: Double($0), accuracy: 5) }
        let p2 = (3..<5).map { TrackPoint(lat: 47, lon: 8 + Double($0) * 0.001, ts: Double($0), accuracy: 5) }
        tracks.appendActivePoints(p1)
        tracks.appendActivePoints(p2)
        var meta = a
        meta.distanceMeters = 300
        tracks.saveActive(meta)
        let loaded = tracks.loadActive()
        XCTAssertEqual(loaded?.points, p1 + p2)
        XCTAssertEqual(loaded?.distanceMeters, 300)

        // Neue Instanz (App-Neustart) setzt die Nummerierung fort
        let restarted = TrackStore(directory: directory.appendingPathComponent("Tracks"))
        restarted.appendActivePoints([TrackPoint(lat: 47, lon: 8.01, ts: 9, accuracy: 5)])
        XCTAssertEqual(restarted.loadActive()?.points.count, 6)

        restarted.clearActive()
        XCTAssertNil(restarted.loadActive())
        let left = (try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Tracks").path)) ?? []
        XCTAssertFalse(left.contains { $0.hasPrefix("active") })
    }
}

/// CoreLocation akzeptiert für `CLMonitor` nur Buchstaben/Ziffern im Namen (sonst Absturz beim Start).
final class TripDetectorTests: XCTestCase {
    @MainActor
    func testMonitorNameIsAlphanumeric() {
        let name = TripDetector.monitorName
        XCTAssertFalse(name.isEmpty)
        XCTAssertTrue(name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII },
                      "Ungültiger CLMonitor-Name: \(name)")
    }
}
