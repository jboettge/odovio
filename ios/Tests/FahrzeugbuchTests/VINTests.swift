import XCTest
@testable import Fahrzeugbuch

/// VIN: Normalisierung/Validierung (wie Server und Web), Prüfziffer-Hinweis, Scan-Kandidaten mit OCR-Korrektur und
/// unveränderte Journal-Hashes für Fahrzeuge ohne VIN.
final class VINTests: XCTestCase {
    private let golf = "WVWZZZ1KZ6W000001"

    // MARK: Normalisieren / Prüfen

    func testNormalize() {
        XCTAssertEqual(VIN.normalize(" wvw-zzz 1kz6w0\t00001 "), golf)
        XCTAssertEqual(VIN.normalize("WVW\u{00A0}ZZZ1KZ6W000001"), golf)
        XCTAssertEqual(VIN.normalize(" - "), "")
        XCTAssertNil(VIN.normalized("   "))
        XCTAssertNil(VIN.normalized(nil))
        XCTAssertEqual(VIN.normalized("wvwzzz1kz6w000001"), golf)
    }

    func testValidation() {
        XCTAssertTrue(VIN.isValid(golf))
        XCTAssertTrue(VIN.isValid("1M8GDM9AXKP042788"))
        for bad in ["WVWZZZ1KZ6W00000", "WVWZZZ1KZ6W0000012", "WVWZZZ1KZ6W00000I", "WVWZZZ1KZ6W00000O",
                    "WVWZZZ1KZ6W00000Q", "WVWZZZ1KZ6W00000_", "WVWZZZ1KZ6W00000Ä", "wvwzzz1kz6w000001"] {
            XCTAssertFalse(VIN.isValid(bad), bad)
        }
        XCTAssertTrue(VIN.isAcceptable(""))
        XCTAssertTrue(VIN.isAcceptable("wvw zzz 1kz 6w0 00001"))
        XCTAssertFalse(VIN.isAcceptable("WVWZZZ1KZ6W00000O"))
        XCTAssertTrue(VIN.errorText.contains("17 Zeichen"))
    }

    func testCheckDigitOnlyWarnsForNorthAmerica() {
        XCTAssertEqual(VIN.checkDigit("1M8GDM9AXKP042788"), "X")
        XCTAssertNil(VIN.warning("1M8GDM9AXKP042788"))
        XCTAssertEqual(VIN.warning("1M8GDM9A1KP042788"),
                       "Prüfziffer (Stelle 9) passt nicht – erwartet «X». Bitte VIN kontrollieren.")
        XCTAssertNil(VIN.warning(golf), "Europa: Prüfziffer nicht massgebend")
        XCTAssertNil(VIN.warning("WVWZZZ1KZ6W00000O"), "ungültig → Fehler statt Hinweis")
        XCTAssertNil(VIN.checkDigit("ZU KURZ"))
    }

    // MARK: Scan-Kandidaten

    func testOCRCorrection() {
        XCTAssertEqual(VIN.correctOCR("WVWZZZIKZ6WOOOOQ1"), golf)
    }

    func testCandidatesFromText() {
        XCTAssertEqual(VIN.candidates(in: "VIN: \(golf)"), [golf])
        XCTAssertEqual(VIN.candidates(in: "FIN \(golf)"), [golf], "Beschriftung nicht mitnehmen")
        XCTAssertEqual(VIN.candidates(in: "wvwzzzikz6wooooo1"), [golf], "OCR: I/O → 1/0")
        XCTAssertEqual(VIN.candidates(in: "WVW ZZZ 1KZ 6W 000001"), [golf], "in Gruppen gedruckt")
        XCTAssertEqual(VIN.candidates(in: "WVW-ZZZ-1KZ-6W0-00001"), [golf])
        XCTAssertEqual(VIN.candidates(in: "I1M8GDM9AXKP042788"), ["1M8GDM9AXKP042788"], "Code 39 mit Import-„I“")
    }

    func testNoCandidatesInUnrelatedText() {
        XCTAssertEqual(VIN.candidates(in: "Total CHF 72.40 Bleifrei 95"), [])
        XCTAssertEqual(VIN.candidates(in: "12345678901234567"), [], "reine Ziffernfolge")
        XCTAssertEqual(VIN.candidates(in: "WVWZZZ1KZ6W00000"), [], "16 Zeichen")
        XCTAssertEqual(VIN.candidates(in: "WVW: ZZZ1KZ6W000001"), [], "Doppelpunkt trennt Gruppen")
        XCTAssertEqual(VIN.candidates(in: "TOTAL 1234 5678 9012"), [], "Wort mit O: Gruppen ohne OCR-Korrektur")
        XCTAssertEqual(VIN.candidates(in: "WVW ZZZ 1KZ 6W 00000A"), [], "Gruppen: letzte vier Stellen numerisch")
    }

    func testBestCandidatePrefersPlausibleCheckDigit() {
        XCTAssertEqual(VIN.bestCandidate(in: ["1M8GDM9A1KP042788", "1M8GDM9AXKP042788"]), "1M8GDM9AXKP042788")
        XCTAssertEqual(VIN.bestCandidate(in: ["Fahrzeugausweis", "23 \(golf)"]), golf)
        XCTAssertNil(VIN.bestCandidate(in: ["Kein Treffer"]))
    }

    // MARK: Journal/Hash-Stabilität

    /// Kanonische Darstellung eines Fahrzeugs ohne VIN wie vor Einführung des Felds (fester Vektor):
    /// `nil` wird nicht kodiert → Hash bestehender Journal-Einträge unverändert.
    @MainActor
    func testVehicleWithoutVINEncodesAsBefore() async throws {
        let v = Vehicle(id: "v-1", name: "Golf", plate: "ZH 1", initialKm: 1000)
        let node = try JSONNode.from(v, encoder: TenantStore.fileEncoder)
        XCTAssertNil(node["vin"])
        let legacy = #"{"deleted":false,"fuelType":"benzin","id":"v-1","initialKm":1000,"name":"Golf","plate":"ZH 1","version":0}"#
        XCTAssertEqual(node.canonical, legacy)
        XCTAssertEqual(Hashing.sha256Hex(node.canonical),
                       "425a64b3b5a79c1c28f0d66dc043bda2610fa3abf7a19ec2df52de48225e9b67")

        // Alter Datenstand (ohne Schlüssel vin) → dekodiert mit vin nil → identisch kodiert
        let decoded = try JSONNode.parse(Data(legacy.utf8)).decode(Vehicle.self, decoder: TenantStore.fileDecoder)
        XCTAssertNil(decoded.vin)
        XCTAssertEqual(try JSONNode.from(decoded, encoder: TenantStore.fileEncoder).canonical, legacy)

        var withVIN = v
        withVIN.vin = golf
        let node2 = try JSONNode.from(withVIN, encoder: TenantStore.fileEncoder)
        XCTAssertEqual(node2["vin"]?.stringValue, golf)
        XCTAssertEqual(node2.canonical, String(legacy.dropLast()) + #","vin":"WVWZZZ1KZ6W000001"}"#)
    }

    /// Server-Nutzdaten: ohne VIN kein Schlüssel (Server: None), mit VIN snake_case `vin`.
    func testPayload() throws {
        var v = Vehicle(id: "v-1", name: "Golf")
        let without = try XCTUnwrap(JSONSerialization.jsonObject(with: v.payload()) as? [String: Any])
        XCTAssertNil(without["vin"])
        v.vin = golf
        let withVIN = try XCTUnwrap(JSONSerialization.jsonObject(with: v.payload()) as? [String: Any])
        XCTAssertEqual(withVIN["vin"] as? String, golf)
    }

    func testServerVehicleWithVINDecodes() throws {
        let base = """
        {"id": "v-1", "version": 2, "deleted": false, "name": "Golf", "make": null, "model": null, "plate": null,
         "fuel_type": "benzin", "initial_km": 0, "purchase_price": null, "ownership": null,
         "private_use_method": null, "annual_fixed_costs": null
        """
        let v = try APIClient.decoder.decode(Vehicle.self, from: Data((base + #", "vin": "\#(golf)"}"#).utf8))
        XCTAssertEqual(v.vin, golf)
        let explicitNull = try APIClient.decoder.decode(Vehicle.self, from: Data((base + #", "vin": null}"#).utf8))
        XCTAssertNil(explicitNull.vin)
        let legacy = try APIClient.decoder.decode(Vehicle.self, from: Data((base + "}").utf8))
        XCTAssertNil(legacy.vin, "Server ohne vin (älterer Stand)")
    }

    @MainActor
    func testLocalJournalWithVIN() async throws {
        let dir = Fixture.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TenantStore(localDirectory: dir)
        var v = Vehicle(id: Fixture.vehicleId, name: "Golf", plate: "ZH 1", initialKm: 1000)
        store.save(v)
        XCTAssertTrue(store.verifyLocalJournal().ok)
        v = try XCTUnwrap(store.vehicle(id: v.id))
        v.vin = golf
        store.save(v)
        let integrity = store.verifyLocalJournal()
        XCTAssertTrue(integrity.ok, integrity.problems.joined(separator: "; "))
        let history = store.localHistory(entity: Vehicle.entityName, id: v.id)
        XCTAssertEqual(history.count, 2)
        XCTAssertNil(history.first?.data["vin"], "erster Eintrag ohne vin")
        XCTAssertNotNil(history.last?.data["vin"])
        XCTAssertEqual(store.vehicle(id: v.id)?.vin, golf)

        let csv = String(decoding: LocalReports.tripsCSVData(store: store, vehicle: v, from: Fixture.day("2026-10-01"),
                                                             to: Fixture.day("2026-10-31")).dropFirst(3), as: UTF8.self)
        XCTAssertTrue(csv.hasPrefix("Datum;"))
        XCTAssertTrue(csv.contains(";Fahrzeug;Kennzeichen;VIN;ID\r\n"), csv)
        XCTAssertTrue(LocalReports.vehicleHead(v).contains("VIN: \(golf)"))
        v.vin = nil
        XCTAssertFalse(LocalReports.vehicleHead(v).contains("VIN"))
    }
}
