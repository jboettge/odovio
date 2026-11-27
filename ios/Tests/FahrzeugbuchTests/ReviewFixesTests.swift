import XCTest
@testable import Fahrzeugbuch

/// Befunde aus docs/REVIEW-2026-11.md (iOS): Q6, Q7, Q8, Q10, Q11, Q12, Q14.
final class ReviewFixesTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = Fixture.tempDirectory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Q6 – Start vor der ersten Entsperrung

    func testBeforeFirstUnlockOnlyWithoutProtectedDataAndMarker() {
        // Vor der ersten Entsperrung: geschützte Daten fehlen, UserDefaults (Marker) nicht lesbar
        XCTAssertTrue(FirstUnlock.isBeforeFirstUnlock(protectedDataAvailable: false, installMarker: false))
        // Gesperrt nach der ersten Entsperrung: UserDefaults lesbar → normaler Start (Aufzeichnung im Hintergrund)
        XCTAssertFalse(FirstUnlock.isBeforeFirstUnlock(protectedDataAvailable: false, installMarker: true))
        // Entsperrt (auch Erststart ohne Marker)
        XCTAssertFalse(FirstUnlock.isBeforeFirstUnlock(protectedDataAvailable: true, installMarker: false))
        XCTAssertFalse(FirstUnlock.isBeforeFirstUnlock(protectedDataAvailable: true, installMarker: true))
    }

    // MARK: Q7 – CLMonitor auch ohne Orte öffnen

    func testMonitorOpensWithoutPlacesWhenEnabled() {
        XCTAssertTrue(TripDetector.shouldOpenMonitor(enabled: true, authorized: true))
        XCTAssertFalse(TripDetector.shouldOpenMonitor(enabled: true, authorized: false))
        XCTAssertFalse(TripDetector.shouldOpenMonitor(enabled: false, authorized: true))
    }

    func testMonitoredPlacesRoundTrip() throws {
        let places = [MonitoredPlace(id: "a-1", lat: 47.37, lon: 8.54, radius: 150)]
        let decoded = try JSONDecoder().decode([MonitoredPlace].self, from: JSONEncoder().encode(places))
        XCTAssertEqual(decoded, places)
    }

    // MARK: Q8 / Q14 – Journal: Nebendatei, halbe Zeile

    private var journalURL: URL { directory.appendingPathComponent("journal.jsonl") }

    private func overflowURL(_ name: String) -> URL {
        directory.appendingPathComponent("journal.overflow-\(name).jsonl")
    }

    private func entry(seq: Int, after prev: String, version: Int) -> JournalEntry {
        JournalEntry(seq: seq, at: "2026-11-27T10:00:0\(seq)Z", entity: "vehicle", entityId: "v1", version: version,
                     action: "update", data: .object(["name": .string("Golf \(seq)")]), reason: nil, actor: nil,
                     prevHash: prev)
    }

    @MainActor
    func testOverflowLinesAreMergedIntoJournal() throws {
        let gate = StorageGate()
        let first = LocalJournal(fileURL: journalURL, gate: gate)
        first.append(entity: "vehicle", entityId: "v1", version: 1, action: "create", data: .object([:]))
        first.flush()
        let e1 = try XCTUnwrap(first.entries.first)
        // Während einer Sperre gesichert (App danach beendet): Eintrag 1 (schon in der Datei) und 2 (fehlt)
        let e2 = entry(seq: 2, after: e1.hash, version: 2)
        try Data((e1.line + "\n" + e2.line + "\n").utf8).write(to: overflowURL("alt"))

        let reopened = LocalJournal(fileURL: journalURL, gate: gate)
        XCTAssertEqual(reopened.count, 2)
        XCTAssertEqual(reopened.headHash, e2.hash)
        XCTAssertTrue(reopened.loadProblems.isEmpty, reopened.loadProblems.description)
        XCTAssertFalse(FileManager.default.fileExists(atPath: overflowURL("alt").path), "Nebendatei entfernt")
        let (integrity, entries) = reopened.verifyFile()
        XCTAssertTrue(integrity.ok, integrity.problems.description)
        XCTAssertEqual(entries.count, 2)
    }

    @MainActor
    func testOverflowNotMatchingChainIsReportedAndKept() throws {
        let gate = StorageGate()
        let first = LocalJournal(fileURL: journalURL, gate: gate)
        first.append(entity: "vehicle", entityId: "v1", version: 1, action: "create", data: .object([:]))
        first.flush()
        let foreign = entry(seq: 5, after: JournalEntry.genesisHash, version: 5)
        try Data((foreign.line + "\n").utf8).write(to: overflowURL("fremd"))

        let reopened = LocalJournal(fileURL: journalURL, gate: gate)
        XCTAssertEqual(reopened.count, 1)
        XCTAssertFalse(reopened.loadProblems.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: overflowURL("fremd").path), "nicht still verworfen")
    }

    @MainActor
    func testContinuationSkipsKnownAndRejectsGaps() {
        let a = entry(seq: 1, after: JournalEntry.genesisHash, version: 1)
        let b = entry(seq: 2, after: a.hash, version: 2)
        let c = entry(seq: 3, after: b.hash, version: 3)
        var result = LocalJournal.continuation(of: [a], with: [c, b, a])
        XCTAssertEqual(result.added.map(\.seq), [2, 3])
        XCTAssertTrue(result.problems.isEmpty)
        result = LocalJournal.continuation(of: [a], with: [c])
        XCTAssertTrue(result.added.isEmpty)
        XCTAssertEqual(result.problems.count, 1)
    }

    func testAppendAfterTornLineStartsOnNewLine() throws {
        let url = directory.appendingPathComponent("torn.jsonl")
        try Data("{\"seq\":1}\n{\"se".utf8).write(to: url)   // Abbruch mitten in der Zeile
        try JournalWriter.append(Data("{\"seq\":2}\n".utf8), to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, "{\"seq\":1}\n{\"se\n{\"seq\":2}\n")
        // Normale Datei: ohne zusätzliche Leerzeile
        try JournalWriter.append(Data("{\"seq\":3}\n".utf8), to: url)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).hasSuffix("{\"seq\":2}\n{\"seq\":3}\n"))
    }

    // MARK: Q10 – Absturzberichte nach Datum

    func testCrashReportsSortedByDateNotKind() {
        let dir = URL(fileURLWithPath: "/tmp/Diagnostics", isDirectory: true)
        let olderHang = dir.appendingPathComponent("odovio-haenger-20261101-080000.json")
        let newerCrash = dir.appendingPathComponent("odovio-absturz-20261126-120000.json")
        let oldCrash = dir.appendingPathComponent("odovio-absturz-20261020-090000.json")
        let sorted = CrashReporter.newestFirst([olderHang, oldCrash, newerCrash])
        XCTAssertEqual(sorted, [newerCrash, olderHang, oldCrash])
        XCTAssertTrue(CrashReporter.title(of: newerCrash).hasPrefix("Absturz vom "))
        XCTAssertTrue(CrashReporter.title(of: olderHang).hasPrefix("Hänger vom "))
        XCTAssertNil(CrashReporter.date(of: dir.appendingPathComponent("anders.json")))
    }

    // MARK: Q11 – Zeitpunkt der Ablehnung

    func testRejectedOpKeepsTimeInStoreFile() throws {
        let when = try XCTUnwrap(ISODate.parse("2026-11-24T14:37:00+01:00"))
        let op = RejectedOp(id: "op-1", entity: "fuel", entityId: "f1", action: "upsert", label: "Tankvorgang 24.11.",
                            error: "Begründung fehlt", date: when, snapshot: nil, reason: nil)
        let data = try StoreFiles.encoder.encode([op])
        let decoded = try StoreFiles.decoder.decode([RejectedOp].self, from: data)
        XCTAssertEqual(decoded.first?.date, when)
        // Ältere Datei ohne `at`: nur der Tag
        let old = #"[{"id":"op-1","entity":"fuel","entityId":"f1","action":"upsert","label":"x","error":"y","date":"2026-11-24"}]"#
        let legacy = try StoreFiles.decoder.decode([RejectedOp].self, from: Data(old.utf8))
        XCTAssertEqual(legacy.first.map { APIClient.dayFormatter.string(from: $0.date) }, "2026-11-24")
    }

    // MARK: Q12 – Monatszuordnung in Zürcher Zeit

    func testTripMonthUsesZurichTime() {
        // Tokio 1.11. 06:30 = Zürich 31.10. 22:30
        XCTAssertEqual(Fixture.trip("t1", start: "2026-11-01T06:30:00+09:00").monthKey, "2026-10")
        // New York 31.10. 23:30 = Zürich 1.11. 04:30
        XCTAssertEqual(Fixture.trip("t2", start: "2026-10-31T23:30:00-04:00").monthKey, "2026-11")
        XCTAssertEqual(Fixture.trip("t3", start: "2026-11-24T07:30:00+01:00").monthKey, "2026-11")
        let t = Fixture.trip("t4", start: "2026-11-01T06:30:00+09:00")
        XCTAssertEqual(LogbookRules.localMonth(t), t.monthKey)
        XCTAssertEqual(LogbookRules.localMonth(t.startAt), t.monthKey)
    }

    // MARK: Q14 – höchstens 64 geplante Mitteilungen

    func testDueNotificationsRespectSystemLimit() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let candidates = (0..<100).map { i in
            DueNotifications.Planned(id: "n\(i)", fire: now.addingTimeInterval(Double(100 - i) * 3600 - 7200),
                                     title: "t", body: "b")
        }
        let free = DueNotifications.budget(otherPending: 10)
        XCTAssertEqual(free, DueNotifications.systemLimit - DueNotifications.reserved - 10)
        let planned = DueNotifications.plan(candidates, now: now, budget: free)
        XCTAssertEqual(planned.count, free)
        XCTAssertTrue(planned.allSatisfy { $0.fire > now }, "nur künftige")
        XCTAssertEqual(planned.map(\.fire), planned.map(\.fire).sorted(), "früheste zuerst")
        XCTAssertEqual(DueNotifications.budget(otherPending: 80), 0)
        XCTAssertTrue(DueNotifications.plan(candidates, now: now, budget: 0).isEmpty)
    }
}
