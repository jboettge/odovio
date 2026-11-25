import XCTest
@testable import Fahrzeugbuch

/// Servermodus „gemeinsam“: Rollen, Mitglieder, Aktivitäten, created_by/updated_by, Fähigkeiten je Betriebsart.
final class SharedModeTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try APIClient.decoder.decode(T.self, from: Data(json.utf8))
    }

    func testAdminRoleImpliesWrite() throws {
        let admin = TenantInfo(slug: "firma", role: "admin")
        XCTAssertTrue(admin.isAdmin)
        XCTAssertTrue(admin.canWrite)
        XCTAssertEqual(admin.roleLabel, "Verwalten")
        XCTAssertTrue(TenantInfo(slug: "firma", role: "write").canWrite)
        XCTAssertFalse(TenantInfo(slug: "firma", role: "write").isAdmin)
        XCTAssertFalse(TenantInfo(slug: "firma", role: "read").canWrite)
        XCTAssertTrue(TenantInfo.local.canWrite)
        XCTAssertEqual(TenantInfo.local.slug, "lokal")

        let me = try decode(MeResponse.self, """
            {"sub": "u1", "name": "anna", "display_name": "Anna Muster",
             "tenants": [{"slug": "firma", "role": "admin"}, {"slug": "verein", "role": "read"}]}
            """)
        XCTAssertEqual(me.displayName, "Anna Muster")
        XCTAssertEqual(me.tenants.map(\.isAdmin), [true, false])
        let old = try decode(MeResponse.self, #"{"sub": "u1", "tenants": []}"#)
        XCTAssertNil(old.displayName)
    }

    func testMembersDecoding() throws {
        let r = try decode(MembersResponse.self, """
            {"members": [
              {"id": 7, "username": "anna", "name": "Anna Muster", "email": "anna@example.org", "role": "admin",
               "source": "local", "last_activity_at": "2026-11-24T08:00:00+01:00"},
              {"id": "kc-2", "username": "beat", "name": "", "role": null, "source": "keycloak"}
            ], "manageable": true}
            """)
        XCTAssertTrue(r.manageable)
        XCTAssertEqual(r.members.map(\.id), ["7", "kc-2"])
        XCTAssertTrue(r.members[0].isAdmin)
        XCTAssertNotNil(r.members[0].lastActivityDate)
        XCTAssertEqual(r.members[1].name, "beat", "leerer Name → Benutzername")
        XCTAssertNil(r.members[1].role)
        XCTAssertEqual(r.members[1].roleLabel, "–")
        let empty = try decode(MembersResponse.self, "{}")
        XCTAssertTrue(empty.members.isEmpty)
        XCTAssertFalse(empty.manageable)
    }

    func testActivityDecoding() throws {
        let page = try decode(ActivityPage.self, """
            {"items": [{"seq": 42, "at": "2026-11-24T08:00:00Z", "actor_name": "Anna", "action": "update",
                        "entity": "fuel", "entity_id": "f1", "vehicle_id": "v1", "summary": "Tankvorgang 24.11."},
                       {"seq": 41, "at": "2026-11-23T08:00:00Z", "actor_name": null, "action": "create",
                        "entity": "vehicle", "entity_id": "v1", "summary": "Fahrzeug Golf"}],
             "next_before_seq": 41}
            """)
        XCTAssertEqual(page.items.map(\.seq), [42, 41])
        XCTAssertEqual(page.items[0].actorName, "Anna")
        XCTAssertEqual(page.items[0].vehicleId, "v1")
        XCTAssertEqual(page.items[0].actionLabel, "Geändert")
        XCTAssertNil(page.items[1].vehicleId)
        XCTAssertEqual(page.nextBeforeSeq, 41)
        XCTAssertNil(try decode(ActivityPage.self, #"{"items": []}"#).nextBeforeSeq)
    }

    @MainActor
    func testCreatedByDecodedButNeverSent() async throws {
        let ch = try decode(ChangesResponse.self, """
            {"cursor": 3,
             "vehicles": [{"id": "v1", "version": 2, "deleted": false, "name": "Golf", "fuel_type": "benzin",
                           "initial_km": 0, "created_by": "Anna", "updated_by": "Beat"}],
             "fuel": [{"id": "f1", "version": 1, "deleted": false, "vehicle_id": "v1", "date": "2026-11-20",
                       "km": 1200, "liters": 40, "price_total": 70, "full_tank": true, "created_by": "Anna"}],
             "trips": [{"id": "t1", "version": 1, "vehicle_id": "v1", "start_at": "2026-11-20T08:00:00+01:00",
                        "created_by": "Anna", "updated_by": "Anna"}],
             "places": [{"id": "p1", "version": 1, "name": "Büro", "kind": "work", "created_by": "Beat"}],
             "tax_params": [{"id": "x1", "version": 1, "deleted": false, "year": 2026, "scope": "tenant", "key": "km_rate",
                             "value": 0.7, "updated_by": "Anna"}]}
            """)
        XCTAssertEqual(ch.vehicles.first?.createdBy, "Anna")
        XCTAssertEqual(ch.vehicles.first?.updatedBy, "Beat")
        XCTAssertEqual(ch.fuel.first?.createdBy, "Anna")
        XCTAssertNil(ch.fuel.first?.updatedBy)
        XCTAssertEqual(ch.trips?.first?.createdBy, "Anna")
        XCTAssertEqual(ch.places?.first?.createdBy, "Beat")
        XCTAssertEqual(ch.taxParams?.first?.updatedBy, "Anna")

        func keys(_ data: Data) throws -> Set<String> {
            Set((try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]).keys)
        }
        for payload in [try ch.vehicles[0].payload(), try ch.fuel[0].payload(), try ch.trips![0].payload(),
                        try ch.places![0].payload(), try ch.taxParams![0].payload()] {
            let k = try keys(payload)
            XCTAssertFalse(k.contains("created_by"))
            XCTAssertFalse(k.contains("updated_by"))
            XCTAssertFalse(k.contains("id"))
        }
        // Lokale Datei behält die Angaben (Anzeige offline)
        let file = try TenantStore.fileEncoder.encode(ch.trips![0])
        let back = try TenantStore.fileDecoder.decode(Trip.self, from: file)
        XCTAssertEqual(back.createdBy, "Anna")
        XCTAssertEqual(back.updatedBy, "Anna")
    }

    func testCapabilitiesPerMode() {
        let local = ModeCapabilities.of(.local)
        XCTAssertTrue(local.history)
        XCTAssertTrue(local.localReports)
        XCTAssertTrue(local.editTaxParams)
        XCTAssertFalse(local.serverReports || local.aiScan || local.aiSuggestions || local.geocodingServer
                       || local.members || local.activity || local.attachmentsSync || local.integrityServer)
        let server = ModeCapabilities.of(.server)
        XCTAssertTrue(server.history && server.members && server.activity && server.aiScan && server.attachmentsSync)
        XCTAssertFalse(server.editTaxParams, "Steuerparameter nur im Webfrontend")
        XCTAssertEqual(ModeCapabilities.of(nil), .server)
        XCTAssertEqual(AppMode(rawValue: "local"), .local)
    }

    @MainActor
    func testFetchMembersAndActivityRequests() async throws {
        let server = MockServer()
        server.onJSON("/members", #"{"members": [{"id": 1, "username": "anna", "name": "Anna", "source": "local"}], "manageable": false}"#)
        server.onJSON("/activity", #"{"items": [], "next_before_seq": null}"#)
        let api = server.api()
        let store = TenantStore(tenant: TenantInfo(slug: "firma", role: "read"), api: { api },
                                directory: Fixture.tempDirectory())
        store.autoSyncEnabled = false
        let members = try await store.fetchMembers()
        XCTAssertEqual(members.members.first?.username, "anna")
        let page = try await store.fetchActivity(beforeSeq: 99)
        XCTAssertTrue(page.items.isEmpty)
        let req = try XCTUnwrap(server.requests(path: "/activity").first)
        XCTAssertEqual(req.path, "/api/t/firma/activity")
        XCTAssertEqual(req.query["before_seq"], "99")
        XCTAssertNotNil(req.query["limit"])

        let local = TenantStore(localDirectory: Fixture.tempDirectory())
        do {
            _ = try await local.fetchMembers()
            XCTFail("Lokalmodus ohne Mitglieder")
        } catch {
            XCTAssertEqual((error as? APIError)?.status, 501)
        }
    }
}
