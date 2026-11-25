import XCTest
@testable import Fahrzeugbuch

/// Store: Outbox/Sync, Ablehnungen, Paging, Merge, Monatsabschluss, Begründungspflicht, Persistenz, Caches.
final class TenantStoreTests: XCTestCase {
    private var directory: URL!
    private var server: MockServer!

    override func setUp() async throws {
        directory = Fixture.tempDirectory()
        server = MockServer()
        server.onJSON("/changes", Fixture.changes(cursor: 10))
        server.on("/sync", Fixture.acceptAll)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    private func makeStore(role: String = "write") -> TenantStore {
        let api = server.api()
        let store = TenantStore(tenant: TenantInfo(slug: "firma", role: role), api: { api }, directory: directory)
        store.autoSyncEnabled = false
        return store
    }

    @MainActor
    private func vehicle(_ store: TenantStore) -> Vehicle {
        let v = Vehicle(id: Fixture.vehicleId, name: "Golf", initialKm: 1000)
        store.save(v)
        return v
    }

    /// Periode als Server-Antwort übernehmen (abgeschlossener Monat).
    @MainActor
    private func close(_ store: TenantStore, month: String) {
        store.storePeriod(TripPeriod(id: "p-\(month)", vehicleId: Fixture.vehicleId, month: month))
    }

    // MARK: Sync

    @MainActor
    func testPushSendsOpsAndClearsOutbox() async throws {
        let store = makeStore()
        _ = vehicle(store)
        store.save(FuelEntry(vehicleId: Fixture.vehicleId, date: Fixture.day("2026-11-20"), km: 1200, liters: 40,
                             priceTotal: 70))
        XCTAssertEqual(store.outbox.count, 2)
        XCTAssertTrue(store.isPending(Fixture.vehicleId))
        await store.sync()
        XCTAssertTrue(store.outbox.isEmpty)
        XCTAssertFalse(store.isPending(Fixture.vehicleId))
        XCTAssertNil(store.syncError)
        XCTAssertEqual(store.cursor, 10)
        let ops = try XCTUnwrap(server.requests(path: "/sync").first?.json?["ops"] as? [[String: Any]])
        XCTAssertEqual(ops.map { $0["entity"] as? String }, ["vehicle", "fuel"])
        XCTAssertNil(ops[0]["reason"])
    }

    @MainActor
    func testTransientServerErrorKeepsOutbox() async {
        server.onJSON("/sync", status: 503, #"{"detail": "Datenbank vorübergehend nicht verfügbar"}"#)
        let store = makeStore()
        _ = vehicle(store)
        await store.sync()
        XCTAssertEqual(store.outbox.count, 1)
        XCTAssertNotNil(store.syncError)
        XCTAssertTrue(store.rejectedOps.isEmpty)
    }

    @MainActor
    func testPayloadTooLargeHalvesBatch() async throws {
        server.on("/sync") { r in
            let ops = r.json?["ops"] as? [[String: Any]] ?? []
            return ops.count > 2 ? (413, Data(#"{"detail": "zu gross"}"#.utf8), [:]) : Fixture.acceptAll(r)
        }
        let store = makeStore()
        _ = vehicle(store)
        for n in 0..<4 {
            store.save(OdometerReading(vehicleId: Fixture.vehicleId, date: Fixture.day("2026-11-2\(n)"), km: 1100 + n))
        }
        await store.sync()
        XCTAssertTrue(store.outbox.isEmpty)
        let sizes = server.requests(path: "/sync").map { ($0.json?["ops"] as? [Any])?.count ?? 0 }
        XCTAssertEqual(sizes.first, 5)
        XCTAssertTrue(sizes.dropFirst().allSatisfy { $0 <= 2 })
    }

    @MainActor
    func testRejectedOpStaysVisibleWithSnapshotAndCanBeRetried() async throws {
        server.on("/sync") { r in
            let ops = r.json?["ops"] as? [[String: Any]] ?? []
            let results: [[String: Any]] = ops.map { op in
                ["op_id": op["op_id"]!, "status": "rejected", "entity": op["entity"]!, "id": op["id"]!,
                 "error": "Notiz zu lang"]
            }
            return (200, try! JSONSerialization.data(withJSONObject: ["results": results, "cursor": 1]), [:])
        }
        let store = makeStore()
        let fuel = FuelEntry(vehicleId: Fixture.vehicleId, date: Fixture.day("2026-11-24"), km: 1200, liters: 40,
                             priceTotal: 70, note: "lang")
        store.save(fuel)
        await store.sync()

        XCTAssertTrue(store.outbox.isEmpty)
        let rejected = try XCTUnwrap(store.rejectedOps.first)
        XCTAssertEqual(rejected.entity, "fuel")
        XCTAssertEqual(rejected.entityId, fuel.id)
        XCTAssertEqual(rejected.error, "Notiz zu lang")
        XCTAssertTrue(rejected.label.hasPrefix("Tankvorgang 24.11."), rejected.label)
        // Vollabgleich hat das (serverseitig unbekannte) Objekt entfernt – die lokale Kopie bleibt
        XCTAssertNil(store.fuelEntry(id: fuel.id))
        XCTAssertEqual(store.rejectedObject(rejected.id, as: FuelEntry.self)?.note, "lang")
        XCTAssertNotNil(store.rejectedSnapshot(id: rejected.id))
        XCTAssertTrue(server.requests(path: "/changes").contains { $0.query["since"] == "0" })

        // Erneut senden → wieder in der Outbox, Eintrag verschwindet
        store.retryRejected(rejected.id)
        XCTAssertTrue(store.rejectedOps.isEmpty)
        XCTAssertEqual(store.outbox.last?.entityId, fuel.id)
        XCTAssertNotNil(store.fuelEntry(id: fuel.id))

        // Verwerfen
        await store.sync()
        let again = try XCTUnwrap(store.rejectedOps.first)
        store.dismissRejected(again.id)
        XCTAssertTrue(store.rejectedOps.isEmpty)
    }

    @MainActor
    func testPullLoopsOverPages() async throws {
        server.on("/changes") { r in
            let since = Int(r.query["since"] ?? "0") ?? 0
            let json: String
            switch since {
            case 0:
                json = Fixture.changes(cursor: 50, hasMore: true).replacingOccurrences(
                    of: #""vehicles": []"#,
                    with: #""vehicles": [{"id": "v-1", "version": 1, "deleted": false, "name": "Golf", "fuel_type": "benzin", "initial_km": 0}]"#)
            case 50:
                json = Fixture.changes(cursor: 80, hasMore: true).replacingOccurrences(
                    of: #""vehicles": []"#,
                    with: #""vehicles": [{"id": "v-2", "version": 1, "deleted": false, "name": "Polo", "fuel_type": "diesel", "initial_km": 0}]"#)
            default:
                json = Fixture.changes(cursor: 90)
            }
            return (200, Data(json.utf8), [:])
        }
        let store = makeStore()
        await store.sync()
        XCTAssertEqual(store.cursor, 90)
        XCTAssertEqual(Set(store.vehicleList.map(\.name)), ["Golf", "Polo"])
        let pages = server.requests(path: "/changes")
        XCTAssertEqual(pages.map { $0.query["since"] }, ["0", "50", "80"])
        XCTAssertTrue(pages.allSatisfy { $0.query["limit"] != nil })
    }

    @MainActor
    func testPendingObjectsAreNotOverwrittenAndHomeKeepsCoordinates() async throws {
        let store = makeStore()
        let home = Place(id: "home-1", version: 0, name: "Zuhause", kind: "home", lat: 47.36, lon: 8.53)
        store.save(home)
        await store.sync()
        // Server liefert den Wohnort ohne Koordinaten zurück, ausserdem eine fremde Fahrt
        server.onJSON("/changes", Fixture.changes(cursor: 20).replacingOccurrences(
            of: #""places": []"#,
            with: #""places": [{"id": "home-1", "version": 2, "name": "Zuhause", "kind": "home", "lat": null, "lon": null, "radius_m": 150, "private": false}]"#))
        await store.sync()
        XCTAssertEqual(store.place(id: "home-1")?.lat, 47.36)
        XCTAssertEqual(store.place(id: "home-1")?.version, 2)

        // Ausstehende lokale Änderung wird beim Pull nicht überschrieben
        var edited = try XCTUnwrap(store.place(id: "home-1"))
        edited.name = "Daheim"
        store.save(edited)
        let syncBefore = server.requests(path: "/sync").count
        server.onJSON("/sync", status: 503, "{}")   // Push scheitert → bleibt ausstehend
        await store.sync()
        XCTAssertEqual(server.requests(path: "/sync").count, syncBefore + 1)
        XCTAssertEqual(store.place(id: "home-1")?.name, "Daheim")
        let body = try XCTUnwrap(server.requests(path: "/sync").last?.json?["ops"] as? [[String: Any]])
        let data = try XCTUnwrap(body.first?["data"] as? [String: Any])
        XCTAssertNil(data["lat"])
    }

    // MARK: Monatsabschluss

    @MainActor
    func testCloseMonthStoresPeriodAndSyncs() async throws {
        server.onJSON("/periods/2026-10/close", """
        {"period": {"id": "p-1", "version": 1, "vehicle_id": "\(Fixture.vehicleId)", "month": "2026-10",
                    "status": "closed", "trips_count": 3, "business_km": 50, "private_km": 0, "commute_km": 0,
                    "field_km": 0},
         "locked_trips": 3, "gaps": [], "forced": false, "cursor": 30, "anchor": null}
        """)
        let store = makeStore()
        let r = try await store.closeMonth(vehicleId: Fixture.vehicleId, month: "2026-10", force: false, reason: nil)
        XCTAssertEqual(r.lockedTrips, 3)
        XCTAssertEqual(r.gaps, 0)
        XCTAssertTrue(store.isMonthClosed(vehicleId: Fixture.vehicleId, month: "2026-10"))
        let request = try XCTUnwrap(server.requests(path: "/close").first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.json?["force"] as? Bool, false)
        XCTAssertGreaterThanOrEqual(server.requests(path: "/changes").count, 2)   // vorher und nachher
    }

    @MainActor
    func testCloseMonthConflictIsAPIError() async {
        server.onJSON("/periods/2026-10/close", status: 409,
                      #"{"detail": {"message": "Nicht alle Fahrten bestätigt", "unconfirmed": [{"id": "t"}]}}"#)
        let store = makeStore()
        do {
            _ = try await store.closeMonth(vehicleId: Fixture.vehicleId, month: "2026-10", force: false, reason: nil)
            XCTFail("409 erwartet")
        } catch let e as APIError {
            XCTAssertEqual(e.status, 409)
            XCTAssertTrue(e.userMessage.contains("1 Fahrt(en) offen"))
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertFalse(store.isMonthClosed(vehicleId: Fixture.vehicleId, month: "2026-10"))
    }

    @MainActor
    func testCurrentMonthCannotBeClosed() async {
        let store = makeStore()
        do {
            _ = try await store.closeMonth(vehicleId: Fixture.vehicleId, month: TripTime.month(Date()), force: false,
                                           reason: nil)
            XCTFail("422 erwartet")
        } catch let e as APIError {
            XCTAssertEqual(e.status, 422)
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertTrue(server.requests(path: "/close").isEmpty)
    }

    // MARK: Begründungspflicht

    @MainActor
    func testChangesInClosedMonthNeedReason() async throws {
        let store = makeStore()
        _ = vehicle(store)
        let fuel = FuelEntry(vehicleId: Fixture.vehicleId, date: Fixture.day("2026-10-12"), km: 1200, liters: 40,
                             priceTotal: 70)
        store.save(fuel)
        let trip = Fixture.trip("t-1", start: "2026-10-12T08:00:00+02:00", kmStart: 1, kmEnd: 2, status: "locked")
        close(store, month: "2026-10")
        XCTAssertTrue(store.requiresReason(fuel: fuel))
        XCTAssertTrue(store.requiresReason(for: trip))
        XCTAssertFalse(store.requiresReason(for: Fixture.trip("t-2", start: "2026-11-02T08:00:00+01:00")))

        let before = store.outbox.count
        store.delete(fuel)                                   // ohne Begründung → abgewiesen
        XCTAssertEqual(store.outbox.count, before)
        XCTAssertFalse(store.notices.isEmpty)
        store.delete(fuel, reason: "kurz")                   // < 10 Zeichen
        XCTAssertEqual(store.outbox.count, before)
        store.delete(fuel, reason: "Doppelt erfasst, Beleg fehlt")
        XCTAssertEqual(store.outbox.count, before + 1)
        XCTAssertEqual(store.outbox.last?.reason, "Doppelt erfasst, Beleg fehlt")
        await store.sync()
        let ops = try XCTUnwrap(server.requests(path: "/sync").last?.json?["ops"] as? [[String: Any]])
        XCTAssertEqual(ops.last?["reason"] as? String, "Doppelt erfasst, Beleg fehlt")
    }

    @MainActor
    func testLockedTripCannotBeEditedOnlyCancelledWithReason() async {
        let store = makeStore()
        let locked = Fixture.trip("t-1", start: "2026-10-12T08:00:00+02:00", kmStart: 1, kmEnd: 2, status: "locked")
        store.save(Fixture.trip("t-1", start: "2026-10-12T08:00:00+02:00", kmStart: 1, kmEnd: 2))
        // `locked` = Stand nach dem Abschluss (setzt nur der Server)
        XCTAssertTrue(store.requiresReason(for: locked))
        store.delete(locked)
        XCTAssertFalse(store.outbox.contains { $0.action == "delete" })
        store.delete(locked, reason: "Fahrt doppelt erfasst")
        XCTAssertEqual(store.outbox.last?.action, "delete")
        XCTAssertEqual(store.outbox.last?.reason, "Fahrt doppelt erfasst")
    }

    @MainActor
    func testPrivateModeTripIsSanitizedLocally() async {
        let store = makeStore()
        var t = Fixture.trip("t-p", start: "2026-11-02T08:00:00+01:00", category: "private")
        t.privateMode = true
        t.purpose = "Arzt"
        t.startPlaceId = "home"
        t.startLabel = String(repeating: "x", count: 100)
        store.save(t)
        let saved = store.trip(id: "t-p")
        XCTAssertNil(saved?.purpose)
        XCTAssertNil(saved?.startPlaceId)
        XCTAssertEqual(saved?.startLabel?.count, Trip.maxPrivateLabel)
    }

    // MARK: Caches, Batch, km-Schätzung

    @MainActor
    func testTripCachesInvalidateOnChange() async {
        let store = makeStore()
        store.save(Fixture.trip("a", start: "2026-11-02T08:00:00+01:00", kmStart: 100, kmEnd: 110))
        store.save(Fixture.trip("b", start: "2026-11-03T08:00:00+01:00", kmStart: 115, kmEnd: 120, status: "suggested"))
        XCTAssertEqual(store.trips(for: Fixture.vehicleId).map(\.id), ["b", "a"])
        XCTAssertEqual(store.reviewTrips(for: Fixture.vehicleId).map(\.id), ["b"])
        XCTAssertEqual(store.gaps(for: Fixture.vehicleId, month: nil).first?.km, 5)

        store.performBatch {
            store.save(Fixture.trip("c", start: "2026-11-01T08:00:00+01:00", kmStart: 90, kmEnd: 100))
            store.confirm(store.trip(id: "b")!, as: .business)
        }
        XCTAssertEqual(store.trips(for: Fixture.vehicleId).map(\.id), ["b", "a", "c"])
        XCTAssertTrue(store.reviewTrips(for: Fixture.vehicleId).isEmpty)
        XCTAssertEqual(store.trips(for: Fixture.vehicleId, month: "2026-11").map(\.id), ["c", "a", "b"])
        XCTAssertEqual(store.lastKnownKm(for: Fixture.vehicleId), 120)
    }

    @MainActor
    func testOdometerPromptForEstimatedLastTrip() async {
        let store = makeStore()
        _ = vehicle(store)
        var t = Fixture.trip("a", start: "2026-11-02T08:00:00+01:00", end: "2026-11-02T08:30:00+01:00",
                             kmStart: 1000, kmEnd: 1018, status: "suggested")
        t.kmEstimated = true
        store.save(t)
        XCTAssertTrue(store.odometerPromptNeeded(vehicleId: Fixture.vehicleId))
        store.confirmOdometer(tripId: "a", kmEnd: 1021)
        XCTAssertFalse(store.odometerPromptNeeded(vehicleId: Fixture.vehicleId))
        XCTAssertEqual(store.trip(id: "a")?.kmEnd, 1021)
        XCTAssertEqual(store.trip(id: "a")?.kmEstimated, false)
    }

    @MainActor
    func testStatsAreCachedAndInvalidated() async {
        let store = makeStore()
        let v = vehicle(store)
        XCTAssertEqual(store.stats(for: v).currentKm, 1000)
        store.save(OdometerReading(vehicleId: v.id, date: Fixture.day("2026-11-20"), km: 1500))
        XCTAssertEqual(store.stats(for: v).currentKm, 1500)
        XCTAssertEqual(store.currentKm(v), 1500)
    }

    // MARK: Persistenz

    @MainActor
    func testPersistAndReload() async throws {
        let store = makeStore()
        _ = vehicle(store)
        store.save(Fixture.trip("a", start: "2026-11-02T08:00:00+01:00", kmStart: 100, kmEnd: 110))
        store.flush()
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.vehicleList.count, 1)
        XCTAssertEqual(reloaded.trip(id: "a")?.kmEnd, 110)
        XCTAssertNotNil(reloaded.trip(id: "a")?.startDate)
        XCTAssertEqual(reloaded.outbox.count, 2)
        XCTAssertNil(reloaded.storeLoadIssue)
    }

    @MainActor
    func testDebouncedPersistWritesEventually() async throws {
        let store = makeStore()
        _ = vehicle(store)
        try await Task.sleep(nanoseconds: 800_000_000)
        StoreFiles.queue.sync {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("firma.json").path))
    }

    @MainActor
    func testCorruptFileIsQuarantinedNotOverwritten() async throws {
        let file = directory.appendingPathComponent("firma.json")
        try Data("{ kaputt".utf8).write(to: file)
        let store = makeStore()
        XCTAssertNotNil(store.storeLoadIssue)
        XCTAssertEqual(store.cursor, 0)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let backup = try XCTUnwrap(files.first { $0.hasPrefix("firma.corrupt-") })
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(backup)), Data("{ kaputt".utf8))
    }

    @MainActor
    func testOlderFileWithoutNewFieldsLoads() async throws {
        let legacy = """
        {"vehicles": {}, "odometer": {}, "fuel": {}, "maintenance": {}, "items": {}, "materials": {}, "articles": {},
         "trips": {"t": {"id": "t", "version": 1, "deleted": false, "vehicleId": "v", "startAt": "2026-11-02T08:00:00+01:00",
                         "category": "business", "status": "confirmed", "source": "manual", "privateMode": false}},
         "attachments": {},
         "outbox": [{"opId": "o1", "entity": "trip", "entityId": "t", "action": "upsert", "clientTs": "x"}],
         "cursor": 7}
        """
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("firma.json"))
        let store = makeStore()
        XCTAssertNil(store.storeLoadIssue)
        XCTAssertEqual(store.cursor, 7)
        XCTAssertEqual(store.trip(id: "t")?.kmEstimated, false)
        XCTAssertNil(store.outbox.first?.reason)
        XCTAssertTrue(store.rejectedOps.isEmpty)
    }
}
