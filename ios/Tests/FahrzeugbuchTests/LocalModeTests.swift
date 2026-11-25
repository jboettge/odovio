import XCTest
@testable import Fahrzeugbuch

/// Lokalmodus: Journal (Hash-Kette), Store ohne Outbox, Monatsabschluss, Berichte/CSV, Sicherung, Moduswechsel.
final class LocalModeTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = Fixture.tempDirectory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    private func makeLocal(_ dir: URL? = nil) -> TenantStore {
        TenantStore(localDirectory: dir ?? directory)
    }

    @MainActor
    @discardableResult
    private func vehicle(_ store: TenantStore) -> Vehicle {
        let v = Vehicle(id: Fixture.vehicleId, name: "Golf", plate: "ZH 1", initialKm: 1000)
        store.save(v)
        return v
    }

    private var journalURL: URL { directory.appendingPathComponent("journal.jsonl") }

    // MARK: Journal

    @MainActor
    func testJournalChainAndHistory() async throws {
        let store = makeLocal()
        let v = vehicle(store)
        var f = FuelEntry(vehicleId: v.id, date: Fixture.day("2026-10-02"), km: 1200, liters: 40, priceTotal: 72.4)
        store.save(f)
        f.liters = 41
        store.save(f)
        store.delete(f)
        XCTAssertTrue(store.outbox.isEmpty, "Lokalmodus: keine Outbox")
        XCTAssertTrue(store.pendingIds.isEmpty)
        XCTAssertEqual(store.journalCount, 4)

        let integrity = store.verifyLocalJournal()
        XCTAssertTrue(integrity.ok, integrity.problems.joined(separator: "; "))
        XCTAssertEqual(integrity.count, 4)
        XCTAssertEqual(integrity.headHash.count, 64)
        XCTAssertEqual(integrity.headHash, store.journalHead)

        let history = store.localHistory(entity: FuelEntry.entityName, id: f.id)
        XCTAssertEqual(history.map(\.action), ["create", "update", "delete"])
        XCTAssertEqual(history.map(\.version), [1, 2, 3])
        XCTAssertEqual(history.first?.actorName, "Ich")
        XCTAssertEqual(history[1].data["liters"]?.description, "41")
        XCTAssertEqual(history.last?.data["deleted"]?.description, "ja")

        // Datei: kanonisches JSON je Zeile, Kette über prev_hash
        let lines = LocalJournal.lines(try Data(contentsOf: journalURL))
        XCTAssertEqual(lines.count, 4)
        let first = try XCTUnwrap(JournalEntry(node: try JSONNode.parse(lines[0])))
        let second = try XCTUnwrap(JournalEntry(node: try JSONNode.parse(lines[1])))
        XCTAssertEqual(first.prevHash, JournalEntry.genesisHash)
        XCTAssertEqual(second.prevHash, first.hash)
        XCTAssertEqual(String(decoding: lines[0], as: UTF8.self), first.line)
        XCTAssertEqual(first.hash, Hashing.sha256Hex(first.unsignedNode.canonical))
    }

    @MainActor
    func testJournalManipulationDetected() async throws {
        do {
            let store = makeLocal()
            let v = vehicle(store)
            store.save(FuelEntry(vehicleId: v.id, date: Fixture.day("2026-10-02"), km: 1200, liters: 40, priceTotal: 70))
            store.save(OdometerReading(vehicleId: v.id, date: Fixture.day("2026-10-03"), km: 1300))
            store.flush()
        }
        // Betrag im Journal ändern (ohne Hash anzupassen)
        var text = try String(contentsOf: journalURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"priceTotal\":70"))
        text = text.replacingOccurrences(of: "\"priceTotal\":70", with: "\"priceTotal\":7")
        try text.write(to: journalURL, atomically: true, encoding: .utf8)
        let reopened = makeLocal()
        let broken = reopened.verifyLocalJournal()
        XCTAssertFalse(broken.ok)
        XCTAssertEqual(broken.brokenAt, 2)
        XCTAssertTrue(broken.problems.contains { $0.contains("Prüfsumme") }, broken.problems.joined(separator: "; "))
        XCTAssertTrue(broken.problems.contains { $0.contains("weicht") }, "Datensatz ≠ Journal")

        // Zeile entfernen → Kette unterbrochen
        var lines = LocalJournal.lines(try Data(contentsOf: journalURL))
        lines.remove(at: 1)
        let (chain, _) = LocalJournal.verify(lines: lines)
        XCTAssertFalse(chain.ok)
        XCTAssertTrue(chain.problems.contains { $0.contains("Verkettung") || $0.contains("Nummerierung") })
    }

    @MainActor
    func testRecordChangedOutsideJournalDetected() async throws {
        do {
            let store = makeLocal()
            vehicle(store)
            store.flush()
        }
        // Mandantendatei direkt ändern (Fahrzeugname), Journal unverändert
        let file = directory.appendingPathComponent("lokal.json")
        var text = try String(contentsOf: file, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"name\":\"Golf\"", with: "\"name\":\"Polo\"")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let store = makeLocal()
        let r = store.verifyLocalJournal()
        XCTAssertTrue(store.vehicleList.first?.name == "Polo")
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.problems.contains { $0.contains("weicht vom letzten Journal-Stand") }, r.problems.description)
    }

    @MainActor
    func testPersistenceReloadAndRecoveryFromJournal() async throws {
        do {
            let store = makeLocal()
            let v = vehicle(store)
            store.save(FuelEntry(vehicleId: v.id, date: Fixture.day("2026-10-02"), km: 1200, liters: 40, priceTotal: 70))
            store.flush()
        }
        var reopened = makeLocal()
        XCTAssertEqual(reopened.vehicleList.count, 1)
        XCTAssertEqual(reopened.fuel(for: Fixture.vehicleId).count, 1)
        XCTAssertTrue(reopened.verifyLocalJournal().ok)

        // Mandantendatei verloren (z. B. App vor dem Speichern beendet) → aus dem Journal wiederhergestellt
        try FileManager.default.removeItem(at: directory.appendingPathComponent("lokal.json"))
        reopened = makeLocal()
        XCTAssertEqual(reopened.vehicleList.map(\.name), ["Golf"])
        XCTAssertEqual(reopened.fuel(for: Fixture.vehicleId).first?.priceTotal, 70)
        XCTAssertTrue(reopened.verifyLocalJournal().ok)
    }

    @MainActor
    func testLocalStoreHasNoSyncNoRejectionsAndNoBlobUpload() async throws {
        let store = makeLocal()
        XCTAssertTrue(store.isLocal)
        XCTAssertTrue(store.api.isLocalPlaceholder)
        let v = vehicle(store)
        let f = FuelEntry(vehicleId: v.id, date: Fixture.day("2026-10-02"), km: 1200, liters: 40, priceTotal: 70)
        store.save(f)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4])
        let a = try XCTUnwrap(store.addAttachment(imageData: jpeg, kind: "receipt", fuelId: f.id, maintenanceId: nil,
                                                   vehicleId: v.id))
        XCTAssertTrue(store.pendingBlobs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Belege/\(a.id).jpg").path))
        let read = await store.attachmentData(a)
        XCTAssertEqual(read, jpeg)
        await store.sync()   // no-op
        XCTAssertNil(store.syncError)
        XCTAssertNil(store.lastSync)
        XCTAssertTrue(store.outbox.isEmpty)
        XCTAssertTrue(store.rejectedOps.isEmpty)
        // Scan-KI und Geodienste im Lokalmodus nicht verfügbar
        let scan = await ScanClient(api: store.api, tenant: store.tenant.slug).scan(jpeg: jpeg, kind: .receipt)
        guard case .notConfigured = scan else { return XCTFail("KI-Scan im Lokalmodus") }
        let reverse = await GeoClient(api: store.api).reverse(TrackPoint(lat: 47.37, lon: 8.54, ts: 0, accuracy: 5),
                                                              roundingMeters: 50)
        XCTAssertNil(reverse)
    }

    @MainActor
    func testTaxParamsEditableOnlyLocally() async {
        let local = makeLocal()
        local.save(TaxParam(year: 2026, key: "km_rate", value: 0.8))
        XCTAssertEqual(local.taxParamList.count, 1)
        XCTAssertTrue(local.canEditTaxParams)

        let server = TenantStore(tenant: TenantInfo(slug: "firma", role: "admin"),
                                 api: { APIClient.localPlaceholder }, directory: Fixture.tempDirectory())
        server.autoSyncEnabled = false
        server.save(TaxParam(year: 2026, key: "km_rate", value: 0.8))
        XCTAssertTrue(server.taxParamList.isEmpty)
        XCTAssertTrue(server.outbox.isEmpty, "Servermodus: keine tax_param-Ops")
        XCTAssertTrue(server.notices.contains(TenantStore.taxParamsWebOnly))
        XCTAssertFalse(server.canEditTaxParams)
    }

    // MARK: Monatsabschluss lokal

    /// Fahrten im Oktober 2026 (abgelaufen, „jetzt“ = 25.11.2026).
    private let now = ISODate.parse("2026-11-25T12:00:00+01:00")!

    @MainActor
    private func seedOctober(_ store: TenantStore) -> (Trip, Trip) {
        vehicle(store)
        let c = Customer(name: "Meier AG", ref: "K-7")
        store.save(c)
        let p = Place(name: "Büro", kind: "work", lat: 47.4, lon: 8.5)
        store.save(p)
        var a = Fixture.trip("10000000-0000-4000-8000-000000000001", start: "2026-10-05T08:00:00+02:00",
                             end: "2026-10-05T08:30:00+02:00", kmStart: 1000, kmEnd: 1040)
        a.purpose = "Kundentermin"
        a.customerId = c.id
        a.endPlaceId = p.id
        var b = Fixture.trip("10000000-0000-4000-8000-000000000002", start: "2026-10-06T17:00:00+02:00",
                             end: "2026-10-06T17:30:00+02:00", kmStart: 1040, kmEnd: 1060, category: "private")
        b.version = 0
        a.version = 0
        store.save(a)
        store.save(b)
        return (store.trip(id: a.id)!, store.trip(id: b.id)!)
    }

    private func detail(_ error: Error) -> [String: Any] {
        guard let e = error as? APIError, let data = e.message.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj["detail"] as? [String: Any] ?? [:]
    }

    @MainActor
    func testLocalCloseRejectsCurrentMonthAndUnconfirmed() async throws {
        let store = makeLocal()
        let (a, _) = seedOctober(store)
        XCTAssertThrowsError(try store.closeMonthLocally(vehicleId: a.vehicleId, month: "2026-11", force: false,
                                                         reason: nil, now: now)) { e in
            XCTAssertEqual((e as? APIError)?.status, 422)
        }
        var draft = a
        draft.status = "draft"
        store.save(draft)
        XCTAssertThrowsError(try store.closeMonthLocally(vehicleId: a.vehicleId, month: "2026-10", force: true,
                                                         reason: "Begründung lang genug", now: now)) { e in
            XCTAssertEqual((e as? APIError)?.status, 409)
            XCTAssertEqual(self.detail(e)["message"] as? String, "Nicht alle Fahrten bestätigt")
            XCTAssertEqual((self.detail(e)["trips"] as? [Any])?.count, 1)
        }
    }

    @MainActor
    func testLocalCloseBlockersAndForce() async throws {
        let store = makeLocal()
        let (a, b) = seedOctober(store)
        // Lücke (1060 → 1070), Zweck fehlt (geschäftlich), Endzeit fehlt, km geschätzt
        var c = Fixture.trip("10000000-0000-4000-8000-000000000003", start: "2026-10-07T09:00:00+02:00",
                             kmStart: 1070, kmEnd: 1100, category: "field")
        c.version = 0
        c.kmEstimated = true
        store.save(c)
        let check = store.monthCheck(vehicleId: a.vehicleId, month: "2026-10", now: now)
        XCTAssertEqual(check.trips.map(\.id), [a.id, b.id, c.id])
        XCTAssertEqual(check.gaps.map(\.km), [10])
        let reasons = check.blockingMismatches.compactMap(\.reason)
        XCTAssertTrue(reasons.contains("km-Stand geschätzt (nicht abgelesen)"))
        XCTAssertTrue(reasons.contains("Endzeit fehlt"))
        XCTAssertTrue(reasons.contains("Zweck fehlt (Aussendienst)"))
        XCTAssertTrue(check.needsForce)
        XCTAssertFalse(check.canCloseWithoutForce)
        XCTAssertEqual(check.tripCheck.mismatches.count, check.mismatches.count)

        XCTAssertThrowsError(try store.closeMonthLocally(vehicleId: a.vehicleId, month: "2026-10", force: false,
                                                         reason: nil, now: now)) { e in
            XCTAssertEqual((e as? APIError)?.status, 409)
            XCTAssertEqual(self.detail(e)["message"] as? String, "Fahrten unvollständig (Zweck, km-Stand oder Endzeit)")
            XCTAssertEqual((self.detail(e)["gaps"] as? [Any])?.count, 1)
            XCTAssertFalse((e as? APIError)?.userMessage.isEmpty ?? true)
        }
        XCTAssertThrowsError(try store.closeMonthLocally(vehicleId: a.vehicleId, month: "2026-10", force: true,
                                                         reason: "zu kurz", now: now)) { e in
            XCTAssertEqual(self.detail(e)["message"] as? String,
                           "Erzwungener Abschluss braucht eine Begründung (mind. 10 Zeichen)")
        }
        XCTAssertFalse(store.isMonthClosed(vehicleId: a.vehicleId, month: "2026-10"))

        let r = try store.closeMonthLocally(vehicleId: a.vehicleId, month: "2026-10", force: true,
                                            reason: "Tacho defekt, Werte geschätzt", now: now)
        XCTAssertEqual(r.forced, true)
        XCTAssertEqual(r.lockedTrips, 3)
        XCTAssertEqual(r.gaps, 1)
        XCTAssertEqual(r.period.tripsCount, 3)
        XCTAssertEqual(r.period.businessKm, 40)
        XCTAssertEqual(r.period.privateKm, 20)
        XCTAssertEqual(r.period.fieldKm, 30)
        XCTAssertEqual(r.period.kmStart, 1000)
        XCTAssertEqual(r.period.kmEnd, 1100)
        XCTAssertEqual(r.period.closedBy, "Ich")
        XCTAssertTrue(r.period.note?.contains("Tacho defekt") ?? false)
        XCTAssertTrue(store.isMonthClosed(vehicleId: a.vehicleId, month: "2026-10"))
        let locked = try XCTUnwrap(store.trip(id: a.id))
        XCTAssertTrue(locked.isLocked)
        XCTAssertEqual(locked.customerName, "Meier AG (K-7)", "Kundenname eingefroren")
        XCTAssertEqual(locked.endLabel, "Büro", "Zielbezeichnung aus dem Ort eingefroren")
        XCTAssertTrue(store.verifyLocalJournal().ok, store.verifyLocalJournal().problems.description)
        XCTAssertEqual(store.localHistory(entity: "trip_period", id: r.period.id).count, 1)

        // Bereits abgeschlossen
        XCTAssertThrowsError(try store.closeMonthLocally(vehicleId: a.vehicleId, month: "2026-10", force: true,
                                                         reason: "noch einmal abschliessen", now: now)) { e in
            XCTAssertEqual(self.detail(e)["message"] as? String, "Monat bereits abgeschlossen")
        }

        // Gesperrt: Änderung abgelehnt; Storno nur mit Begründung, zählt als Korrektur
        var edit = locked
        edit.purpose = "anders"
        store.save(edit)
        XCTAssertEqual(store.trip(id: a.id)?.purpose, "Kundentermin")
        store.delete(locked)
        XCTAssertFalse(store.trip(id: a.id)?.deleted ?? true, "Storno ohne Begründung abgelehnt")
        store.delete(locked, reason: "Doppelt erfasst, Korrektur")
        XCTAssertTrue(store.trip(id: a.id)?.deleted ?? false)
        XCTAssertEqual(store.period(vehicleId: a.vehicleId, month: "2026-10")?.corrections, 1)
        // Nachtrag im abgeschlossenen Monat: sofort gesperrt
        let late = Fixture.trip("10000000-0000-4000-8000-000000000009", start: "2026-10-20T09:00:00+02:00",
                                end: "2026-10-20T10:00:00+02:00", kmStart: 1100, kmEnd: 1110, category: "private")
        store.save(late)
        XCTAssertNil(store.trip(id: late.id), "Nachtrag ohne Begründung abgelehnt")
        store.save(late, reason: "Fahrt vergessen, Nachtrag")
        XCTAssertEqual(store.trip(id: late.id)?.status, "locked")
        XCTAssertEqual(store.period(vehicleId: a.vehicleId, month: "2026-10")?.corrections, 2)
        XCTAssertTrue(store.verifyLocalJournal().ok)
    }

    @MainActor
    func testCloseMonthAsyncUsesLocalPathWithoutServer() async throws {
        let store = makeLocal()
        let (a, _) = seedOctober(store)
        // closeMonth (öffentliche API) im Lokalmodus: kein Netzwerk (Platzhalter würde scheitern)
        let r = try await store.closeMonth(vehicleId: a.vehicleId, month: "2026-10", force: false, reason: nil)
        XCTAssertEqual(r.forced, false)
        XCTAssertEqual(r.lockedTrips, 2)
        XCTAssertTrue(store.isMonthClosed(vehicleId: a.vehicleId, month: "2026-10"))
    }

    // MARK: Berichte

    @MainActor
    func testCSVFormulaProtection() async {
        XCTAssertEqual(LocalReports.cell("=SUM(A1)"), "'=SUM(A1)")
        XCTAssertEqual(LocalReports.cell("+41 79"), "'+41 79")
        XCTAssertEqual(LocalReports.cell("-5"), "'-5")
        XCTAssertEqual(LocalReports.cell("@cmd"), "'@cmd")
        XCTAssertEqual(LocalReports.cell("\tx"), "'\tx")
        XCTAssertEqual(LocalReports.cell("Meier AG"), "Meier AG")
        XCTAssertEqual(LocalReports.cell(nil), "")
        XCTAssertEqual(LocalReports.row(["a;b", "say \"hi\"", "x"]), "\"a;b\";\"say \"\"hi\"\"\";x\r\n")
    }

    @MainActor
    func testTripsCSVAndDocuments() async throws {
        let store = makeLocal()
        let (a, _) = seedOctober(store)
        var evil = Fixture.trip("10000000-0000-4000-8000-000000000005", start: "2026-10-08T09:00:00+02:00",
                                end: "2026-10-08T10:00:00+02:00", kmStart: 1060, kmEnd: 1070)
        evil.purpose = "=HYPERLINK(\"x\")"
        evil.version = 0
        store.save(evil)
        let v = try XCTUnwrap(store.vehicle(id: a.vehicleId))
        let data = LocalReports.tripsCSVData(store: store, vehicle: v, from: Fixture.day("2026-10-01"),
                                             to: Fixture.day("2026-10-31"))
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF], "BOM")
        let text = String(decoding: data.dropFirst(3), as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].hasPrefix("Datum;Start;Ende;km Beginn"))
        XCTAssertTrue(lines[1].hasPrefix("05.10.2026;08:00;08:30;1000;1040;40.0;"))
        XCTAssertTrue(lines[1].contains(";Kundentermin;Meier AG (K-7);"))
        XCTAssertTrue(text.contains("\"'=HYPERLINK(\"\"x\"\")\""), text)

        let url = try LocalReports.tripsCSV(store: store, vehicle: v, from: Fixture.day("2026-10-01"),
                                            to: Fixture.day("2026-10-31"))
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Fahrzeugbuch_"))
        XCTAssertEqual(url.pathExtension, "csv")
        try? FileManager.default.removeItem(at: url)

        let logbook = LocalReports.logbookDocument(store: store, vehicle: v, month: "2026-10", from: nil, to: nil)
        XCTAssertTrue(logbook.landscape)
        XCTAssertEqual(logbook.footer, "Fahrzeugbuch · lokal")
        XCTAssertTrue(logbook.plainText.contains("Fahrten (3)"))
        XCTAssertTrue(logbook.plainText.contains("Lokales Journal geprüft"))
        XCTAssertTrue(logbook.fileName.hasPrefix("Fahrzeugbuch_Fahrtenbuch_"))

        store.save(FuelEntry(vehicleId: v.id, date: Fixture.day("2026-10-10"), km: 1065, liters: 40, priceTotal: 72.4))
        let m = Maintenance(vehicleId: v.id, date: Fixture.day("2026-10-12"), km: 1068, title: "Service")
        store.save(m, items: [MaintenanceItem(maintenanceId: m.id, label: "Öl")],
                   materials: [MaintenanceMaterial(maintenanceId: m.id, name: "Motoröl", quantity: 4, unit: "l",
                                                   unitPrice: 12.5)])
        let report = LocalReports.vehicleReportDocument(store: store, vehicle: v, from: Fixture.day("2026-10-01"),
                                                        to: Fixture.day("2026-10-31"))
        XCTAssertFalse(report.landscape)
        XCTAssertTrue(report.plainText.contains("Tankvorgänge (1)"))
        XCTAssertTrue(report.plainText.contains("Motoröl"))
        XCTAssertTrue(report.plainText.contains("50.00 (Material)"))
        let year = LocalReports.yearReport(store: store, vehicle: v, year: 2026)
        XCTAssertEqual(year.tripsCount, 3)
        XCTAssertEqual(YearReport.value(year.costs, "maintenance"), 50)
        XCTAssertTrue(LocalReports.yearReportDocument(store: store, vehicle: v, year: 2026).plainText
            .contains("Kilometerentschädigung"))
        XCTAssertEqual(LocalReports.num(1234567.891, 2), "1'234'567.89")
        XCTAssertEqual(LocalReports.km(-12345), "-12'345")
    }

    // MARK: Sicherung

    @MainActor
    func testBackupRoundtripIncludingAttachments() async throws {
        let store = makeLocal()
        let (a, _) = seedOctober(store)
        let f = FuelEntry(vehicleId: a.vehicleId, date: Fixture.day("2026-10-10"), km: 1065, liters: 40, priceTotal: 72.4)
        store.save(f)
        let jpeg = Data((0..<2000).map { UInt8($0 % 251) })
        let att = try XCTUnwrap(store.addAttachment(imageData: jpeg, kind: "receipt", fuelId: f.id, maintenanceId: nil,
                                                     vehicleId: a.vehicleId))
        store.save(TaxParam(year: 2026, key: "km_rate", value: 0.8))
        _ = try store.closeMonthLocally(vehicleId: a.vehicleId, month: "2026-10", force: false, reason: nil, now: now)
        let head = store.journalHead

        let url = try LocalBackup.exportBackup(store: store)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Fahrzeugbuch_Sicherung_"))
        XCTAssertEqual(url.pathExtension, "json")

        let otherDir = Fixture.tempDirectory()
        defer { try? FileManager.default.removeItem(at: otherDir) }
        let target = makeLocal(otherDir)
        target.save(Vehicle(name: "Wird ersetzt"))
        let summary = try LocalBackup.importBackup(from: url, into: target)
        XCTAssertEqual(summary.headHash, head)
        XCTAssertEqual(summary.attachments, 1)
        XCTAssertEqual(summary.counts["trip"], 2)
        XCTAssertEqual(summary.counts["trip_period"], 1)
        XCTAssertEqual(target.vehicleList.map(\.name), ["Golf"])
        XCTAssertEqual(target.trips(for: a.vehicleId).count, 2)
        XCTAssertTrue(target.isMonthClosed(vehicleId: a.vehicleId, month: "2026-10"))
        XCTAssertEqual(target.taxParamList.count, 1)
        XCTAssertEqual(AttachmentFiles.read(att.id, directory: target.attachmentDirectory), jpeg)
        XCTAssertEqual(target.journalHead, head)
        let integrity = target.verifyLocalJournal()
        XCTAssertTrue(integrity.ok, integrity.problems.description)
        // Vorheriger Stand archiviert
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherDir.appendingPathComponent("Archiv").path))

        // Nach Neustart identisch
        let reopened = makeLocal(otherDir)
        XCTAssertEqual(reopened.journalHead, head)
        XCTAssertTrue(reopened.verifyLocalJournal().ok)

        // Manipulierte Sicherung wird abgelehnt
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"priceTotal\":72.4", with: "\"priceTotal\":7.4")
        let bad = otherDir.appendingPathComponent("bad.json")
        try text.write(to: bad, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try LocalBackup.importBackup(from: bad, into: reopened))
        XCTAssertEqual(reopened.journalHead, head, "abgelehnter Import ändert nichts")
        XCTAssertThrowsError(try LocalBackup.parse(Data("{\"format\":\"x\"}".utf8)))
    }

    // MARK: Moduswechsel

    @MainActor
    func testMigrationEnqueuesOpsInDependencyOrderWithSameIds() async throws {
        let local = makeLocal()
        let (a, b) = seedOctober(local)
        _ = try local.closeMonthLocally(vehicleId: a.vehicleId, month: "2026-10", force: false, reason: nil, now: now)
        let f = FuelEntry(vehicleId: a.vehicleId, date: Fixture.day("2026-11-02"), km: 1100, liters: 30, priceTotal: 50)
        local.save(f)
        let m = Maintenance(vehicleId: a.vehicleId, date: Fixture.day("2026-11-03"), km: 1110, title: "Reifen")
        local.save(m, items: [MaintenanceItem(maintenanceId: m.id, label: "Profil")],
                   materials: [MaintenanceMaterial(maintenanceId: m.id, name: "Ventil")])
        let att = try XCTUnwrap(local.addAttachment(imageData: Data([0xFF, 0xD8, 9, 9]), kind: "receipt", fuelId: f.id,
                                                     maintenanceId: nil, vehicleId: a.vehicleId))
        local.save(PurposeRule(fromPlaceId: nil, toPlaceId: local.placeList.first?.id, resultCategory: "business"))
        local.save(TaxParam(year: 2026, key: "km_rate", value: 0.8))
        let gone = Vehicle(name: "Verkauft")
        local.save(gone)
        local.save(OdometerReading(vehicleId: gone.id, date: Fixture.day("2026-11-01"), km: 5))
        local.delete(gone)

        let server = TenantStore(tenant: TenantInfo(slug: "firma", role: "write"), api: { APIClient.localPlaceholder },
                                 directory: Fixture.tempDirectory())
        server.autoSyncEnabled = false
        let report = LocalMigration.enqueue(from: local, into: server)

        let order = server.outbox.map(\.entity)
        let expected = ["vehicle", "customer", "place", "purpose_rule", "fuel", "maintenance", "maintenance_item",
                        "maintenance_material", "trip", "trip", "attachment"]
        XCTAssertEqual(order, expected)
        XCTAssertEqual(server.outbox.first?.entityId, a.vehicleId)
        XCTAssertTrue(server.outbox.allSatisfy { $0.action == "upsert" && $0.baseVersion == nil })
        XCTAssertEqual(Set(server.outbox.filter { $0.entity == "trip" }.map(\.entityId)), [a.id, b.id])
        XCTAssertEqual(server.outbox.first { $0.entity == "attachment" }?.entityId, att.id)
        XCTAssertEqual(server.pendingBlobs, [att.id])
        XCTAssertEqual(server.trip(id: a.id)?.status, "confirmed", "gesperrt → bestätigt")
        let body = try XCTUnwrap(server.outbox.first { $0.entity == "trip" }?.data)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["status"] as? String, "confirmed")
        XCTAssertNil(json["customer_name"])
        XCTAssertEqual(report.counts["trip"], 2)
        XCTAssertNil(report.counts["tax_param"], "Steuerparameter nur im Webfrontend")
        XCTAssertTrue(report.notes.contains { $0.contains("bestätigt") })
        XCTAssertTrue(report.notes.contains { $0.contains("Monatsabschluss") })
        XCTAssertTrue(report.notes.contains { $0.contains("Steuerparameter") })
        XCTAssertTrue(report.notes.contains { $0.contains("übersprungen") }, report.notes.description)
        // Lokale Daten bleiben unverändert
        XCTAssertEqual(local.trip(id: a.id)?.status, "locked")
        XCTAssertTrue(local.verifyLocalJournal().ok)
        AttachmentFiles.remove(att.id)
    }

    @MainActor
    func testCopyServerStateIntoLocal() async throws {
        let server = TenantStore(tenant: TenantInfo(slug: "firma", role: "read"), api: { APIClient.localPlaceholder },
                                 directory: Fixture.tempDirectory())
        server.autoSyncEnabled = false
        server.storePeriod(TripPeriod(id: "p1", vehicleId: Fixture.vehicleId, month: "2026-09"))
        let local = makeLocal()
        let notes = try LocalMigration.copyServerState(server, into: local)
        XCTAssertTrue(notes.isEmpty)
        XCTAssertTrue(local.isMonthClosed(vehicleId: Fixture.vehicleId, month: "2026-09"))
        XCTAssertEqual(local.journalCount, 1)
        XCTAssertTrue(local.verifyLocalJournal().ok)
        XCTAssertEqual(local.localHistory(entity: "trip_period", id: "p1").first?.action, "create")
    }

    // MARK: Kanonisches JSON

    func testCanonicalJSONIsDeterministicAndIdempotent() throws {
        let node = try JSONNode.parse(Data(#"{"b":1.0,"a":[true,null,"x\n\"y"],"c":0.1,"d":-3,"e":1e20}"#.utf8))
        XCTAssertEqual(node.canonical, #"{"a":[true,null,"x\n\"y"],"b":1,"c":0.1,"d":-3,"e":1e+20}"#)
        XCTAssertEqual(try JSONNode.parse(node.canonicalData).canonical, node.canonical)
    }
}
