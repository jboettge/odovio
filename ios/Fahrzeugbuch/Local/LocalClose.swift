import Foundation

/// Monatsprüfung und Monatsabschluss ohne Server (Lokalmodus; Prüfung auch als Offline-Fallback im
/// Servermodus). Gleiche Regeln wie server/app/trips.py: nur abgelaufene Monate (Zeitzone Europe/Zurich),
/// blockiert bei unbestätigten Fahrten, km-Lücken und unvollständigen Fahrten (Zweck bei geschäftlich/
/// Aussendienst, km-Stand, Endzeit, geschätzter km-Stand) – Lücken/Mängel nur mit `force` + Begründung (≥ 10).
extension TenantStore {
    /// Alle Fahrten (auch anderer Fahrzeuge; Filter in den Regeln).
    private var allTripValues: [Trip] { Array(trips.values) }

    /// km-Stände aus km-Ablesungen, Tankungen und Wartungen (Tag "yyyy-MM-dd" wie Server: Datum ohne Zeit).
    func odometerReadings(vehicleId: String) -> [(day: String, km: Int)] {
        let f = APIClient.dayFormatter
        var out: [(day: String, km: Int)] = []
        out += odometer.values.filter { $0.vehicleId == vehicleId && !$0.deleted }.map { (f.string(from: $0.date), $0.km) }
        out += fuel.values.filter { $0.vehicleId == vehicleId && !$0.deleted }.map { (f.string(from: $0.date), $0.km) }
        out += maintenance.values.filter { $0.vehicleId == vehicleId && !$0.deleted }
            .compactMap { m in m.km.map { (f.string(from: m.date), $0) } }
        return out
    }

    /// Lokale Monatsprüfung (km-Kette, Plausibilität, Odometer-Abgleich, offene Fahrten).
    func monthCheck(vehicleId: String, month: String, now: Date = Date()) -> MonthCheckResult {
        let bounds = LogbookRules.monthBounds(month) ?? (first: "\(month)-01", last: "\(month)-31")
        let list = LogbookRules.trips(allTripValues, vehicleId: vehicleId, month: month)
        let previous = LogbookRules.previousTrip(allTripValues, vehicleId: vehicleId, before: bounds.first)
        let closedPeriod = period(vehicleId: vehicleId, month: month)
        return MonthCheckResult(
            month: month, trips: list, gaps: LogbookRules.gaps(list, previous: previous),
            mismatches: LogbookRules.mismatches(list),
            odometerCheck: LogbookRules.odometerCheck(readings: odometerReadings(vehicleId: vehicleId), trips: list,
                                                      first: bounds.first, last: bounds.last),
            unconfirmed: list.filter(LogbookRules.needsReview), closed: closedPeriod != nil,
            corrections: closedPeriod?.corrections ?? 0, isPast: month < LogbookRules.currentMonth(now: now))
    }

    /// Monatsabschluss ohne Server. Fehler wie der Server: `APIError` 422 (Format/laufender Monat), 403, 409 mit
    /// strukturiertem Detail (`{"detail": {"message", "trips" | "gaps", "mismatches"}}`).
    func closeMonthLocally(vehicleId: String, month: String, force: Bool, reason: String?,
                           now: Date = Date()) throws -> PeriodCloseResponse {
        guard isLocal else { throw APIError(status: 409, message: "Nur im Lokalmodus möglich.") }
        guard canWrite else { throw APIError(status: 403, message: "Keine Schreibberechtigung.") }
        guard LogbookRules.isMonth(month) else {
            throw APIError(status: 422, message: "Monat im Format YYYY-MM erwartet")
        }
        guard month < LogbookRules.currentMonth(now: now) else {
            throw APIError(status: 422, message: "Nur abgelaufene Monate können abgeschlossen werden")
        }
        guard vehicle(id: vehicleId).map({ !$0.deleted }) ?? false else {
            throw APIError(status: 404, message: "Fahrzeug nicht gefunden")
        }
        if let existing = period(vehicleId: vehicleId, month: month) {
            throw Self.conflict(["message": "Monat bereits abgeschlossen", "period": ["id": existing.id,
                                                                                       "month": existing.month]])
        }
        let check = monthCheck(vehicleId: vehicleId, month: month, now: now)
        if !check.unconfirmed.isEmpty {
            throw Self.conflict(["message": "Nicht alle Fahrten bestätigt", "trips": check.unconfirmed.map {
                ["id": $0.id, "start_at": $0.startAt, "status": $0.status, "category": $0.category]
            }])
        }
        let blocking = check.blockingMismatches
        let problems: [String: Any] = ["gaps": check.gaps.map(Self.gapJSON), "mismatches": blocking.map(Self.mismatchJSON)]
        let cleanReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let forced = !check.gaps.isEmpty || !blocking.isEmpty
        if forced && !force {
            let msg = blocking.isEmpty ? "km-Lücken vorhanden" : "Fahrten unvollständig (Zweck, km-Stand oder Endzeit)"
            throw Self.conflict(problems.merging(["message": msg]) { a, _ in a })
        }
        if forced && (cleanReason?.count ?? 0) < Self.minReasonLength {
            throw Self.conflict(problems.merging(
                ["message": "Erzwungener Abschluss braucht eine Begründung (mind. 10 Zeichen)"]) { a, _ in a })
        }

        // Fahrten sperren, Namen einfrieren (spätere Umbenennungen ändern den Bericht nicht mehr)
        var changed: [Trip] = []
        var lockedCount = 0
        for t in check.trips {
            var frozen = LogbookRules.frozenNames(t, places: places, customers: customers)
            frozen.status = "locked"
            if t.status != "locked" { lockedCount += 1 }
            if frozen != t { changed.append(frozen) }
        }
        let kms = LogbookRules.kmByCategory(check.trips)
        let starts = check.trips.compactMap(\.kmStart)
        let ends = check.trips.compactMap(\.kmEnd)
        let previous = periods.values.first { $0.vehicleId == vehicleId && $0.month == month }
        var p = TripPeriod(id: previous?.id ?? UUID().uuidString.lowercased(), version: (previous?.version ?? 0) + 1,
                           deleted: false, vehicleId: vehicleId, month: month)
        p.status = "closed"
        p.closedBy = LocalIdentity.actorName
        p.closedAt = LocalJournal.timestamp(now)
        p.anchorSeq = nil
        p.kmStart = starts.min()
        p.kmEnd = ends.max()
        p.tripsCount = check.trips.count
        p.businessKm = kms["business"] ?? 0
        p.privateKm = kms["private"] ?? 0
        p.commuteKm = kms["commute"] ?? 0
        p.fieldKm = kms["field"] ?? 0
        p.corrections = previous?.corrections ?? 0
        if forced, let cleanReason {
            let note = "Erzwungen trotz \(check.gaps.count) km-Lücke(n) und \(blocking.count) unvollständigen Angaben: "
                + cleanReason
            p.note = String(note.prefix(500))
        }
        applyLocalClose(lockedTrips: changed, period: p, reason: forced ? cleanReason : nil)
        return PeriodCloseResponse(period: p, lockedTrips: lockedCount, gaps: check.gaps.count, forced: forced,
                                   cursor: nil)
    }

    // MARK: Hilfen

    static func conflict(_ detail: [String: Any]) -> APIError {
        let body = (try? JSONSerialization.data(withJSONObject: ["detail": detail], options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? (detail["message"] as? String ?? "Konflikt")
        return APIError(status: 409, message: body)
    }

    private static func gapJSON(_ g: TripGap) -> [String: Any] {
        ["after_trip_id": g.afterTripId ?? NSNull(), "before_trip_id": g.beforeTripId ?? NSNull(),
         "km_from": g.kmFrom, "km_to": g.kmTo, "km": g.km]
    }

    private static func mismatchJSON(_ m: TripMismatch) -> [String: Any] {
        ["trip_id": m.tripId ?? NSNull(), "reason": m.reason ?? "", "blocking": m.blocking ?? true]
    }
}
