import XCTest
@testable import Fahrzeugbuch

/// Lokale Berechnungen gegen die Testvektoren des Servers (server/tests/vectors/*.json, Kopie in `vectors/`).
final class YearReportVectorTests: XCTestCase {
    /// Vektor laden: neben dieser Datei (Simulator/Linux), sonst aus dem Test-Bundle.
    static func vector(_ name: String) throws -> [String: Any] {
        let local = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("vectors").appendingPathComponent("\(name).json")
        var data = try? Data(contentsOf: local)
        #if !os(Linux)
        if data == nil, let url = Bundle(for: YearReportVectorTests.self).url(forResource: name, withExtension: "json") {
            data = try? Data(contentsOf: url)
        }
        #endif
        let d = try XCTUnwrap(data, "Testvektor \(name).json fehlt")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: d) as? [String: Any])
    }

    private static func trip(_ d: [String: Any], id: String, vehicleId: String) -> Trip {
        Trip(id: d["id"] as? String ?? id, version: 1, vehicleId: vehicleId, startAt: d["start_at"] as! String,
             endAt: d["end_at"] as? String, kmStart: d["km_start"] as? Int, kmEnd: d["km_end"] as? Int,
             distanceGps: (d["distance_gps"] as? NSNumber)?.doubleValue,
             distanceRoute: (d["distance_route"] as? NSNumber)?.doubleValue,
             category: d["category"] as? String ?? "unknown", purpose: d["purpose"] as? String,
             status: d["status"] as? String ?? "confirmed")
    }

    private static func number(_ v: Any?) -> Double? {
        if v is NSNull { return nil }
        return (v as? NSNumber)?.doubleValue
    }

    func testYearReportMatchesServerVectors() throws {
        let cases = try XCTUnwrap(Self.vector("year_report")["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let year = try XCTUnwrap(c["year"] as? Int)
            let vd = try XCTUnwrap(c["vehicle"] as? [String: Any])
            var v = Vehicle(id: "veh-\(year)", name: vd["name"] as? String ?? "Auto")
            v.ownership = vd["ownership"] as? String
            v.privateUseMethod = vd["private_use_method"] as? String
            v.purchasePrice = Self.number(vd["purchase_price"])
            v.annualFixedCosts = Self.number(vd["annual_fixed_costs"])
            let trips = (c["trips"] as? [[String: Any]] ?? []).enumerated().map {
                Self.trip($0.element, id: "t\($0.offset)", vehicleId: v.id)
            }
            let fuel = (c["fuel"] as? [[String: Any]] ?? []).map { f in
                FuelEntry(vehicleId: v.id, date: Fixture.day(f["date"] as! String), km: f["km"] as! Int,
                          liters: Self.number(f["liters"]) ?? 0, priceTotal: Self.number(f["price_total"]) ?? 0)
            }
            let maintenance = (c["maintenance"] as? [[String: Any]] ?? []).map { m in
                Maintenance(vehicleId: v.id, date: Fixture.day(m["date"] as! String), km: m["km"] as? Int,
                            title: m["title"] as? String ?? "", cost: Self.number(m["cost"]))
            }
            let params = (c["tax_params"] as? [[String: Any]] ?? []).map { p in
                TaxParam(year: p["year"] as! Int, scope: p["scope"] as? String ?? "tenant", key: p["key"] as! String,
                         value: Self.number(p["value"]) ?? 0)
            }
            let r = YearReportCalculator.compute(vehicle: v, trips: trips, fuel: fuel, odometer: [],
                                                 maintenance: maintenance, materials: [], taxParams: params, year: year)
            let e = try XCTUnwrap(c["expected"] as? [String: Any])
            XCTAssertEqual(r.tripsCount, e["trips_count"] as? Int, name)
            XCTAssertEqual(r.unconfirmed, e["unconfirmed"] as? Int, name)
            XCTAssertEqual(r.monthsUsed, e["months_used"] as? Int, name)
            for (k, val) in e["km"] as? [String: Any] ?? [:] {
                XCTAssertEqual(YearReport.value(r.km, k) ?? -1, Self.number(val) ?? -2, accuracy: 0.001, "\(name) km \(k)")
            }
            for (k, val) in e["shares_pct"] as? [String: Any] ?? [:] {
                if let expected = Self.number(val) {
                    XCTAssertEqual(YearReport.value(r.sharesPct, k) ?? -1, expected, accuracy: 0.001, "\(name) share \(k)")
                } else {
                    XCTAssertNil(YearReport.value(r.sharesPct, k), "\(name) share \(k)")
                }
            }
            for (k, val) in e["costs"] as? [String: Any] ?? [:] {
                XCTAssertEqual(YearReport.value(r.costs, k) ?? -1, Self.number(val) ?? -2, accuracy: 0.001,
                               "\(name) cost \(k)")
            }
            XCTAssertEqual(r.warnings, e["warnings"] as? [String], name)
            for (k, val) in e["items"] as? [String: Any] ?? [:] {
                let exp = try XCTUnwrap(val as? [String: Any])
                let item = try XCTUnwrap(r.item(k), "\(name) item \(k)")
                XCTAssertEqual(item.applicable, exp["applicable"] as? Bool, "\(name) \(k) applicable")
                if let expected = Self.number(exp["value"]) {
                    XCTAssertEqual(item.value ?? -1, expected, accuracy: 0.001, "\(name) \(k) value")
                } else {
                    XCTAssertNil(item.value, "\(name) \(k) value")
                }
            }
            XCTAssertTrue(r.isLocal)
        }
    }

    func testGapsMatchServerVectors() throws {
        let cases = try XCTUnwrap(Self.vector("gaps")["cases"] as? [[String: Any]])
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let trips = (c["trips"] as? [[String: Any]] ?? []).enumerated()
                .map { Self.trip($0.element, id: "t\($0.offset)", vehicleId: "v") }
                .sorted(by: LogbookRules.chronological)
            let previous = (c["previous"] as? [String: Any]).map { Self.trip($0, id: "prev", vehicleId: "v") }
            let e = try XCTUnwrap(c["expected"] as? [String: Any])
            XCTAssertEqual(trips.map(\.id), e["order"] as? [String], name)
            let gaps = LogbookRules.gaps(trips, previous: previous)
            let expected = e["gaps"] as? [[String: Any]] ?? []
            XCTAssertEqual(gaps.count, expected.count, name)
            for (g, x) in zip(gaps, expected) {
                XCTAssertEqual(g.afterTripId, x["after_trip_id"] as? String, name)
                XCTAssertEqual(g.beforeTripId, x["before_trip_id"] as? String, name)
                XCTAssertEqual(g.kmFrom, x["km_from"] as? Int, name)
                XCTAssertEqual(g.kmTo, x["km_to"] as? Int, name)
                XCTAssertEqual(g.km, x["km"] as? Int, name)
            }
        }
    }

    func testTaxParamResolutionPrefersTenantAndFallsBackToDefaults() {
        let params = [
            TaxParam(year: 2026, scope: "federal", key: "km_rate", value: 0.70),
            TaxParam(year: 2026, scope: "tenant", key: "km_rate", value: 0.80),
            TaxParam(year: 2026, scope: "canton:ZH", key: "cap_canton", value: 5000),
            TaxParam(year: 2025, scope: "tenant", key: "commute_rate", value: 0.5),
        ]
        let r = YearReportCalculator.resolveParams(params, year: 2026, canton: "ZH")
        XCTAssertEqual(r["km_rate"]?.value, 0.80)
        XCTAssertEqual(r["km_rate"]?.scope, "tenant")
        XCTAssertEqual(r["cap_canton"]?.value, 5000)
        XCTAssertEqual(r["commute_rate"]?.scope, "default")
        XCTAssertEqual(r["commute_rate"]?.value, 0.75)
        let later = YearReportCalculator.resolveParams([], year: 2030, canton: nil)
        XCTAssertEqual(later["commute_rate"]?.year, 2026)
        XCTAssertNil(later["cap_canton"])
        // Ohne konfigurierten Kanton: genau ein erfasster Kanton wird verwendet
        XCTAssertEqual(YearReportCalculator.inferredCanton(params, year: 2026), "ZH")
    }
}
