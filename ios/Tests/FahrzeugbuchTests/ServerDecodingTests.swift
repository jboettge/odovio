import XCTest
@testable import Fahrzeugbuch

/// Dekodierung echter Server-Antworten (Feldnamen wie `server/app`), null-tolerant.
final class ServerDecodingTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try APIClient.decoder.decode(T.self, from: Data(json.utf8))
    }

    // MARK: Monatsabschluss (E1)

    /// Antwort von `trips.close_period` (gaps als Liste, anchor als Objekt).
    func testCloseResponseWithGapList() throws {
        let json = """
        {"period": {"id": "p-1", "version": 1, "vehicle_id": "v-1", "month": "2026-10", "status": "closed",
                    "closed_by": "Jakob", "closed_at": "2026-11-02T08:00:00+00:00", "anchor_seq": 42,
                    "km_start": 53000, "km_end": 53400, "trips_count": 12, "business_km": 250.5,
                    "private_km": 100, "commute_km": 49.5, "field_km": 0, "note": null},
         "locked_trips": 12,
         "gaps": [{"after_trip_id": "a", "before_trip_id": "b", "km_from": 100, "km_to": 120, "km": 20}],
         "forced": true, "cursor": 77,
         "anchor": {"seq": 43, "head_hash": "abc", "created_at": "2026-11-02T08:00:00+00:00", "key_id": "k1"}}
        """
        let r = try decode(PeriodCloseResponse.self, json)
        XCTAssertEqual(r.period.vehicleId, "v-1")
        XCTAssertEqual(r.period.month, "2026-10")
        XCTAssertEqual(r.period.tripsCount, 12)
        XCTAssertEqual(r.period.businessKm, 250.5)
        XCTAssertTrue(r.period.isClosed)
        XCTAssertEqual(r.lockedTrips, 12)
        XCTAssertEqual(r.gaps, 1)
        XCTAssertEqual(r.forced, true)
        XCTAssertEqual(r.cursor, 77)
    }

    /// Neuer Vertrag: gaps als Zahl, Periode mit `corrections`, anchor null.
    func testCloseResponseWithGapCount() throws {
        let json = """
        {"period": {"id": "p-2", "vehicle_id": "v-1", "month": "2026-09", "corrections": 2},
         "locked_trips": 0, "gaps": 0, "forced": false, "cursor": 5, "anchor": null}
        """
        let r = try decode(PeriodCloseResponse.self, json)
        XCTAssertEqual(r.gaps, 0)
        XCTAssertEqual(r.forced, false)
        XCTAssertEqual(r.period.corrections, 2)
        XCTAssertEqual(r.period.status, "closed")
    }

    /// Früherer Fehler: Antwort direkt als `TripPeriod` dekodiert → muss scheitern (kein vehicle_id oben).
    func testCloseResponseIsNotAPeriod() {
        let json = #"{"period": {"id": "p", "vehicle_id": "v", "month": "2026-10"}, "locked_trips": 1}"#
        XCTAssertThrowsError(try decode(TripPeriod.self, json))
    }

    // MARK: /changes

    func testChangesWithPagingAndMaskedPrivateTrip() throws {
        let json = """
        {"cursor": 120, "has_more": true,
         "vehicles": [{"id": "v-1", "version": 1, "deleted": false, "name": "Golf", "make": null, "model": null,
                       "plate": "ZH 1", "fuel_type": "benzin", "initial_km": 1000, "purchase_price": null,
                       "ownership": null, "private_use_method": null, "annual_fixed_costs": null}],
         "trips": [{"id": "t-1", "version": 3, "vehicle_id": "v-1", "start_at": "2026-11-03T07:30:00+01:00",
                    "end_at": "2026-11-03T08:00:00+01:00", "km_start": 100, "km_end": 118, "km_estimated": true,
                    "start_place_id": null, "end_place_id": null, "start_label": null, "end_label": null,
                    "category": "private", "purpose": null, "customer_id": null, "customer_name": null,
                    "status": "confirmed", "source": "auto", "suggestion_category": null, "suggestion_purpose": null,
                    "suggestion_customer_id": null, "suggestion_confidence": null, "suggestion_reason": null,
                    "suggestion_source": null, "track_hash": null, "split_of": null, "private_mode": true,
                    "note": null, "driver_sub": "abc", "driver_name": "Jakob"}],
         "places": [{"id": "pl-1", "version": 1, "name": "Privater Ort", "kind": "other", "lat": null, "lon": null,
                     "radius_m": 150, "customer_id": null, "default_category": null, "private": true},
                    {"id": "pl-2", "version": 1, "name": null, "kind": null, "lat": null, "lon": null}],
         "trip_periods": []}
        """
        let ch = try decode(ChangesResponse.self, json)
        XCTAssertEqual(ch.cursor, 120)
        XCTAssertTrue(ch.hasMore)
        XCTAssertEqual(ch.vehicles.first?.name, "Golf")
        XCTAssertTrue(ch.fuel.isEmpty)                 // fehlende Schlüssel → leer
        let t = try XCTUnwrap(ch.trips?.first)
        XCTAssertTrue(t.kmEstimated)
        XCTAssertNil(t.startLabel)
        XCTAssertNil(t.purpose)
        XCTAssertTrue(t.privateMode)
        XCTAssertEqual(t.distanceKm, 18)
        XCTAssertNotNil(t.startDate)                   // beim Dekodieren geparst
        XCTAssertEqual(ch.places?.count, 2)
        XCTAssertEqual(ch.places?.first?.isPrivate, true)
        XCTAssertEqual(ch.places?.last?.name, "Privater Ort")
        XCTAssertEqual(ch.places?.last?.kind, "other")
    }

    func testChangesFromOlderServerWithoutHasMore() throws {
        let ch = try decode(ChangesResponse.self, #"{"cursor": 3, "vehicles": [], "odometer": []}"#)
        XCTAssertFalse(ch.hasMore)
        XCTAssertNil(ch.trips)
    }

    func testSyncResponse() throws {
        let r = try decode(SyncResponse.self, """
        {"results": [{"op_id": "o1", "status": "rejected", "entity": "trip", "id": "t1", "version": null,
                      "error": "Begründung erforderlich"}], "cursor": 9}
        """)
        XCTAssertEqual(r.results.first?.status, "rejected")
        XCTAssertEqual(r.results.first?.error, "Begründung erforderlich")
    }

    // MARK: Trip

    func testTripDateCacheFollowsChanges() {
        var t = Trip(vehicleId: "v", startAt: "2026-11-03T07:30:00+01:00")
        XCTAssertEqual(t.startDate, ISODate.parse("2026-11-03T07:30:00+01:00"))
        t.startAt = "2026-11-04T07:30:00+01:00"
        XCTAssertEqual(t.startDate, ISODate.parse("2026-11-04T07:30:00+01:00"))
        XCTAssertNil(t.endDate)
        t.endAt = "2026-11-04T08:00:00.500+01:00"
        XCTAssertNotNil(t.endDate)
    }

    func testTripPayloadOmitsServerFieldsAndSanitizesPrivateMode() throws {
        var t = Trip(vehicleId: "v", startAt: "2026-11-03T07:30:00+01:00", kmEstimated: true,
                     startPlaceId: "p1", endPlaceId: "p2",
                     startLabel: "Musterstrasse 5, 8000 Zürich – sehr lange Bezeichnung über sechzig Zeichen hinaus",
                     purpose: "Arzt", customerId: "c1", customerName: "Meier AG",
                     suggestionPurpose: "Termin", suggestionCustomerId: "c1",
                     trackHash: String(repeating: "a", count: 64), privateMode: true)
        t.note = "Notiz"
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: t.payload()) as? [String: Any])
        XCTAssertNil(dict["customer_name"])
        XCTAssertNil(dict["start_place_id"])
        XCTAssertNil(dict["end_place_id"])
        XCTAssertNil(dict["purpose"])
        XCTAssertNil(dict["customer_id"])
        XCTAssertNil(dict["track_hash"])
        XCTAssertNil(dict["suggestion_purpose"])
        XCTAssertNil(dict["suggestion_customer_id"])
        XCTAssertNil(dict["id"])
        XCTAssertEqual(dict["km_estimated"] as? Bool, true)
        XCTAssertLessThanOrEqual((dict["start_label"] as? String)?.count ?? 0, Trip.maxPrivateLabel)

        t.privateMode = false
        let business = try XCTUnwrap(JSONSerialization.jsonObject(with: t.payload()) as? [String: Any])
        XCTAssertEqual(business["purpose"] as? String, "Arzt")
        XCTAssertNil(business["customer_name"])
    }

    func testHomeAndPrivatePlacesNeverSendCoordinates() throws {
        for (kind, isPrivate) in [("home", false), ("other", true)] {
            let p = Place(name: "X", kind: kind, lat: 47.1, lon: 8.5, isPrivate: isPrivate)
            let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: p.payload()) as? [String: Any])
            XCTAssertNil(dict["lat"], kind)
            XCTAssertNil(dict["lon"], kind)
        }
        let work = Place(name: "Büro", kind: "work", lat: 47.1, lon: 8.5)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: work.payload()) as? [String: Any])
        XCTAssertEqual(dict["lat"] as? Double, 47.1)
    }

    // MARK: Fehlertexte (U7)

    func testErrorMessagesNeverShowHTML() {
        let html = APIError(status: 502, message: "<html><body><h1>502 Bad Gateway</h1></body></html>")
        XCTAssertFalse(html.userMessage.contains("<"))
        XCTAssertTrue(html.userMessage.contains("vorübergehend"))
        XCTAssertFalse((html.errorDescription ?? "").contains("<html"))

        let html404 = APIError(status: 404, message: "<!DOCTYPE html><html>…</html>")
        XCTAssertFalse(html404.userMessage.contains("<"))
    }

    func testErrorMessagesForStatusCodes() {
        XCTAssertTrue(APIError(status: 429, message: "").userMessage.contains("Zu viele Anfragen – bitte kurz warten"))
        XCTAssertTrue(APIError(status: 429, message: "", retryAfter: 30).userMessage.contains("30 s"))
        XCTAssertTrue(APIError(status: 401, message: "x").userMessage.contains("anmelden"))
        XCTAssertTrue(APIError(status: 503, message: "x").userMessage.contains("Server vorübergehend nicht erreichbar"))
        XCTAssertEqual(APIError(status: 422, message: "Nur abgelaufene Monate").userMessage, "Nur abgelaufene Monate")
        let validation = APIError(status: 422, message: #"{"detail": [{"loc": ["body"], "msg": "field required"}]}"#)
        XCTAssertEqual(validation.userMessage, "field required")
    }

    func testStructured409IsSummarized() {
        let body = """
        {"detail": {"message": "Abschluss nicht möglich", "unconfirmed": [{"id": "a"}, {"id": "b"}],
                    "gaps": [{"km": 12}, {"km": 3}],
                    "mismatches": [{"trip_id": "t", "reason": "Zweck fehlt"}, {"trip_id": "u", "reason": "Zweck fehlt"}]}}
        """
        let text = APIError(status: 409, message: body).userMessage
        XCTAssertTrue(text.contains("Abschluss nicht möglich"))
        XCTAssertTrue(text.contains("2 Fahrt(en) offen"))
        XCTAssertTrue(text.contains("2 km-Lücke(n), 15 km"))
        XCTAssertTrue(text.contains("2 unvollständige Fahrt(en): Zweck fehlt"))
        XCTAssertFalse(text.contains("{"))
    }

    func testURLErrorMessages() {
        XCTAssertTrue(URLError(.notConnectedToInternet).userMessage.contains("Keine Internetverbindung"))
        XCTAssertTrue(URLError(.timedOut).userMessage.contains("Zeitüberschreitung"))
        XCTAssertTrue(URLError(.serverCertificateUntrusted).userMessage.contains("Zertifikat"))
    }
}
