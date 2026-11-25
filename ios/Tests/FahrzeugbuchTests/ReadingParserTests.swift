import XCTest
@testable import Fahrzeugbuch

/// Auswertung erkannter Textzeilen (Zapfsäule, Quittung, Tacho) ohne Kamera/Vision.
final class ReadingParserTests: XCTestCase {

    // MARK: Hilfen

    /// Zeile mit Position (normalisiert, Ursprung oben links).
    private func line(_ text: String, y: Double, x: Double = 0.1, width: Double = 0.6, height: Double = 0.05,
                      confidence: Double = 0.9, alternatives: [String] = []) -> RecognizedLine {
        RecognizedLine(text: text, candidates: [text] + alternatives, confidence: confidence,
                       box: TextBox(x: x, y: y, width: width, height: height))
    }

    /// Zeilen untereinander (Quittung)
    private func receipt(_ texts: [String]) -> [RecognizedLine] {
        texts.enumerated().map { n, t in line(t, y: 0.05 + Double(n) * 0.04, height: 0.03) }
    }

    private let now: Date = {
        var c = DateComponents()
        c.year = 2026
        c.month = 11
        c.day = 25
        c.hour = 12
        return Calendar.current.date(from: c)!
    }()

    private func ymd(_ date: Date?) -> String? {
        guard let date else { return nil }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: Normalisierung

    func testNormalizesSevenSegmentErrors() {
        XCTAssertEqual(ReadingParser.parseNumber("77.8O")?.value ?? 0, 77.80, accuracy: 0.0001)
        XCTAssertEqual(ReadingParser.parseNumber("43,6O")?.value ?? 0, 43.60, accuracy: 0.0001)
        XCTAssertEqual(ReadingParser.parseNumber("I.784")?.value ?? 0, 1.784, accuracy: 0.0001)
        XCTAssertEqual(ReadingParser.parseNumber("S3.4l")?.value ?? 0, 53.41, accuracy: 0.0001)
        XCTAssertEqual(ReadingParser.parseNumber("B,ZO")?.value ?? 0, 8.20, accuracy: 0.0001)
        XCTAssertEqual(ReadingParser.parseNumber("|D5")?.value ?? 0, 105, accuracy: 0.0001)
        XCTAssertEqual(ReadingParser.parseNumber("1'234.50")?.value ?? 0, 1234.50, accuracy: 0.0001)
        XCTAssertEqual(ReadingParser.parseNumber("1.234,50")?.value ?? 0, 1234.50, accuracy: 0.0001)
        XCTAssertEqual(ReadingParser.parseNumber("53’410")?.value ?? 0, 53410, accuracy: 0.0001)
        XCTAssertEqual(ReadingParser.parseNumber("1.784")?.decimals, 3)
        XCTAssertEqual(ReadingParser.parseNumber("105.832.766")?.decimals, 0)
        XCTAssertNil(ReadingParser.parseNumber("Total"))
    }

    func testNumbersInLineIgnoreWordsAndUnits() {
        let found = ReadingParser.numbers(in: "Menge 41,30Ltr x 1.746 CHF/l", kind: .receipt)
        XCTAssertEqual(found.map(\.parsed.value), [41.30, 1.746])
        let liters = ReadingParser.numbers(in: "43.60l", kind: .pump)
        XCTAssertEqual(liters.first?.parsed.value ?? 0, 43.60, accuracy: 0.0001)
        XCTAssertTrue(ReadingParser.numbers(in: "Bleifrei Total", kind: .receipt).isEmpty)
        let km = ReadingParser.numbers(in: "53 410 km", kind: .odometer)
        XCTAssertEqual(km.first?.parsed.value ?? 0, 53410, accuracy: 0.5)
        let dated = ReadingParser.numbers(in: "24.11.2026 14:32 77.80", kind: .receipt)
        XCTAssertEqual(dated.map(\.parsed.value), [77.80])
    }

    // MARK: Zapfsäule

    func testPumpWithSevenSegmentErrorsAndLabels() {
        let lines = [
            line("Betrag CHF", y: 0.10, height: 0.04),
            line("77.8O", y: 0.16, height: 0.08, confidence: 0.6),
            line("Liter", y: 0.30, height: 0.04),
            line("43,6O", y: 0.36, height: 0.08, confidence: 0.6),
            line("CHF/Liter", y: 0.52, height: 0.04),
            line("1.784", y: 0.58, height: 0.05, confidence: 0.8),
            line("Säule 4", y: 0.80, height: 0.04),
        ]
        let r = ReadingParser.parse(lines, kind: .pump)
        let fuel = try? XCTUnwrap(r.fuel)
        XCTAssertEqual(fuel?.amount ?? 0, 77.80, accuracy: 0.001)
        XCTAssertEqual(fuel?.liters ?? 0, 43.60, accuracy: 0.001)
        XCTAssertEqual(fuel?.pricePerLiter ?? 0, 1.784, accuracy: 0.0001)
        XCTAssertNil(fuel?.computed)
        XCTAssertTrue(r.isUnambiguous, "Konfidenz \(r.confidence)")
        XCTAssertEqual(r.token(fuel?.amountToken)?.raw, "77.8O")
    }

    func testPumpWithoutLabelsInSwappedOrder() {
        // Preis pro Liter oben, Betrag unten – Zuordnung allein über Betrag = Liter × Preis
        let lines = [
            line("1.784", y: 0.10, height: 0.05),
            line("43.60", y: 0.30, height: 0.08),
            line("77.80", y: 0.50, height: 0.08),
            line("Bleifrei 95", y: 0.75, height: 0.04),
        ]
        let r = ReadingParser.parse(lines, kind: .pump)
        XCTAssertEqual(r.fuel?.amount ?? 0, 77.80, accuracy: 0.001)
        XCTAssertEqual(r.fuel?.liters ?? 0, 43.60, accuracy: 0.001)
        XCTAssertEqual(r.fuel?.pricePerLiter ?? 0, 1.784, accuracy: 0.0001)
        XCTAssertTrue(r.isUnambiguous, "Konfidenz \(r.confidence)")
    }

    func testPumpPicksConsistentPriceAmongOtherGrades() {
        // Preistafel mit mehreren Sorten – nur 1.784 passt zu Betrag und Liter
        let lines = [
            line("77.80", y: 0.10, height: 0.08),
            line("43.60", y: 0.25, height: 0.08),
            line("1.784", y: 0.40, height: 0.05),
            line("Diesel 1.899", y: 0.60, height: 0.04),
            line("Super 98 1.929", y: 0.66, height: 0.04),
        ]
        let r = ReadingParser.parse(lines, kind: .pump)
        XCTAssertEqual(r.fuel?.pricePerLiter ?? 0, 1.784, accuracy: 0.0001)
        XCTAssertTrue(r.isUnambiguous, "Konfidenz \(r.confidence)")
    }

    func testPumpWithOnlyAmountAndLiters() {
        let lines = [
            line("77.80", y: 0.10, height: 0.08),
            line("43.60", y: 0.30, height: 0.08),
        ]
        let r = ReadingParser.parse(lines, kind: .pump)
        XCTAssertEqual(r.fuel?.amount ?? 0, 77.80, accuracy: 0.001)
        XCTAssertEqual(r.fuel?.liters ?? 0, 43.60, accuracy: 0.001)
        XCTAssertEqual(r.fuel?.pricePerLiter ?? 0, 1.784, accuracy: 0.001)
        XCTAssertEqual(r.fuel?.computed, .pricePerLiter)
        XCTAssertFalse(r.isUnambiguous, "nur zwei Werte → bestätigen lassen")
    }

    func testPumpUsesAlternativeCandidate() {
        // Bester Kandidat falsch gelesen ("71.80"), zweiter richtig
        let lines = [
            line("71.80", y: 0.10, height: 0.08, alternatives: ["77.80"]),
            line("43.60", y: 0.30, height: 0.08),
            line("1.784", y: 0.50, height: 0.05),
        ]
        let r = ReadingParser.parse(lines, kind: .pump)
        XCTAssertEqual(r.fuel?.amount ?? 0, 77.80, accuracy: 0.001)
        XCTAssertNil(r.fuel?.computed)
    }

    func testImplausiblePumpValuesGiveNoResult() {
        let lines = [
            line("Betrag 20.00", y: 0.10),
            line("Liter 40.00", y: 0.30),
            line("Preis/l 0.500", y: 0.50),
        ]
        let r = ReadingParser.parse(lines, kind: .pump)
        XCTAssertNil(r.fuel)
        XCTAssertFalse(r.isUnambiguous)
        XCTAssertFalse(r.chips(for: .amount).isEmpty, "erkannte Zahlen bleiben als Auswahl")
    }

    func testPumpTooLargeAmountRejected() {
        let lines = [
            line("1500.00", y: 0.10, height: 0.08),
            line("300.50", y: 0.30, height: 0.08),
            line("4.992", y: 0.50, height: 0.05),
        ]
        let r = ReadingParser.parse(lines, kind: .pump)
        XCTAssertFalse(r.isUnambiguous)
        XCTAssertNil(r.fuel)
    }

    // MARK: Quittung

    func testMigrolReceiptIgnoresVATLines() {
        let lines = receipt([
            "MIGROL",
            "Migrol Service Zürich-Altstetten",
            "Badenerstrasse 600",
            "8048 Zürich",
            "MWST-Nr. CHE-105.832.766 MWST",
            "24.11.2026 14:32",
            "Säule 3  Bleifrei 95",
            "43.60 l x 1.784 CHF/l",
            "Total CHF 77.80",
            "MWST 8.1% von 77.80 CHF 5.83",
            "Netto CHF 71.97",
            "Visa CHF 77.80",
        ])
        let r = ReadingParser.parse(lines, kind: .receipt, now: now)
        XCTAssertEqual(r.fuel?.amount ?? 0, 77.80, accuracy: 0.001)
        XCTAssertEqual(r.fuel?.liters ?? 0, 43.60, accuracy: 0.001)
        XCTAssertEqual(r.fuel?.pricePerLiter ?? 0, 1.784, accuracy: 0.0001)
        XCTAssertTrue(r.isUnambiguous, "Konfidenz \(r.confidence)")
        XCTAssertEqual(ymd(r.date), "2026-11-24")
        XCTAssertEqual(r.station, "Migrol")
        XCTAssertNotEqual(r.token(r.fuel?.amountToken)?.lineIndex, 9, "nicht aus der MWST-Zeile")
    }

    func testCoopProntoReceiptWithShortDate() {
        let lines = receipt([
            "Coop Pronto",
            "Tankstelle Wallisellen",
            "Industriestrasse 10, 8304 Wallisellen",
            "Beleg-Nr. 004512   Kasse 2",
            "Datum: 28.01.26  Zeit: 08:14",
            "Zapfsäule 07",
            "Diesel",
            "Menge           41,30 Ltr",
            "Preis/Ltr     CHF 1.746",
            "Betrag        CHF 72.10",
            "MWST 8.1% inkl.          5.40",
            "Total CHF               72.10",
            "Bezahlt Maestro      72.10",
            "Supercard Punkte 72",
        ])
        let r = ReadingParser.parse(lines, kind: .receipt, now: now)
        XCTAssertEqual(r.fuel?.amount ?? 0, 72.10, accuracy: 0.001)
        XCTAssertEqual(r.fuel?.liters ?? 0, 41.30, accuracy: 0.001)
        XCTAssertEqual(r.fuel?.pricePerLiter ?? 0, 1.746, accuracy: 0.0001)
        XCTAssertTrue(r.isUnambiguous, "Konfidenz \(r.confidence)")
        XCTAssertEqual(ymd(r.date), "2026-01-28")
        XCTAssertEqual(r.station, "Coop Pronto")
    }

    func testReceiptVATAmountNotUsedAsTotal() {
        // MWST-Betrag 5.83 und Netto 71.97 dürfen nicht als Betrag gelten
        let lines = receipt([
            "TAMOIL",
            "MWST 8.1% CHF 5.83",
            "Netto CHF 71.97",
            "Bleifrei 95  43.60 l",
            "CHF/l 1.784",
            "Total CHF 77.80",
        ])
        let r = ReadingParser.parse(lines, kind: .receipt, now: now)
        XCTAssertEqual(r.fuel?.amount ?? 0, 77.80, accuracy: 0.001)
        XCTAssertEqual(r.station, "Tamoil")
        XCTAssertNil(r.date)
    }

    func testFutureReceiptDateIgnored() {
        let lines = receipt(["Shell", "Datum 24.12.2027", "40.00 l x 1.800 CHF/l", "Total CHF 72.00"])
        let r = ReadingParser.parse(lines, kind: .receipt, now: now)
        XCTAssertNil(r.date)
        XCTAssertEqual(r.fuel?.amount ?? 0, 72.00, accuracy: 0.001)
    }

    // MARK: Tacho

    func testOdometerIgnoresTripMeter() {
        let lines = [
            line("TRIP A 1234.5 km", y: 0.20, height: 0.04),
            line("53410 km", y: 0.50, height: 0.07),
            line("21°C  12:34", y: 0.80, height: 0.03),
        ]
        let r = ReadingParser.parse(lines, kind: .odometer, lastKnownKm: 53_000)
        XCTAssertEqual(r.km, 53_410)
        XCTAssertTrue(r.isUnambiguous, "Konfidenz \(r.confidence)")
    }

    func testOdometerWithSpaceSeparatorAndOCRErrors() {
        let lines = [
            line("ODO 53 4IO km", y: 0.40, height: 0.06),
            line("Reichweite 450 km", y: 0.60, height: 0.03),
        ]
        let r = ReadingParser.parse(lines, kind: .odometer, lastKnownKm: 53_380)
        XCTAssertEqual(r.km, 53_410)
    }

    func testOdometerImplausibleValueNotTaken() {
        let lines = [line("12345 km", y: 0.5, height: 0.06)]
        let r = ReadingParser.parse(lines, kind: .odometer, lastKnownKm: 53_000)
        XCTAssertNil(r.km)
        XCTAssertFalse(r.isUnambiguous)
        XCTAssertEqual(r.kmAlternatives, [12_345])
        XCTAssertEqual(r.chips(for: .km).map(\.value), [12_345])
    }

    func testOdometerPrefersPlausibleOverLarger() {
        // Serviceanzeige mit grösserer Zahl – Plausibilität gegen letzten Stand entscheidet
        let lines = [
            line("Service in 15000 km", y: 0.2, height: 0.03),
            line("98765", y: 0.4, height: 0.03),
            line("53412", y: 0.6, height: 0.06),
        ]
        let r = ReadingParser.parse(lines, kind: .odometer, lastKnownKm: 53_300)
        XCTAssertEqual(r.km, 53_412)
    }

    func testOdometerWithoutHistory() {
        let lines = [line("12 345 km", y: 0.5, height: 0.06), line("123.4", y: 0.7, height: 0.03)]
        let r = ReadingParser.parse(lines, kind: .odometer, lastKnownKm: nil)
        XCTAssertEqual(r.km, 12_345)
    }
}
