import Foundation

/// Regeln des Fahrtenbuchs wie auf dem Server (server/app/trips.py, timeutil.py, sync.frozen_names) –
/// für Lokalmodus und Offline-Prüfung. Monatszuordnung nach lokaler Zeit in Europe/Zurich.
enum LogbookRules {
    static let timeZone = TimeZone(identifier: "Europe/Zurich") ?? .current
    static let kmCategories = ["business", "private", "commute", "field"]
    static let allCategories = ["business", "private", "commute", "field", "unknown"]
    static let toleranceKm = 5.0
    static let tolerancePct = 0.02

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: Zeit

    /// Lokales Datum (Zürich) "yyyy-MM-dd" eines ISO-Zeitpunkts.
    static func localDay(_ iso: String) -> String? {
        ISODate.parse(iso).map { dayFormatter.string(from: $0) }
    }

    /// Lokaler Monat (Zürich) "yyyy-MM" eines ISO-Zeitpunkts.
    static func localMonth(_ iso: String) -> String? {
        localDay(iso).map { String($0.prefix(7)) }
    }

    static func localMonth(_ t: Trip) -> String { localMonth(t.startAt) ?? t.monthKey }

    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// Laufender Monat in Zürich.
    static func currentMonth(now: Date = Date()) -> String { String(day(now).prefix(7)) }

    static func isMonth(_ s: String) -> Bool {
        let parts = s.split(separator: "-")
        guard s.count == 7, parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]) else { return false }
        return (1900...9999).contains(y) && (1...12).contains(m)
    }

    /// Erster/letzter Tag eines Monats als "yyyy-MM-dd".
    static func monthBounds(_ month: String) -> (first: String, last: String)? {
        guard isMonth(month) else { return nil }
        let parts = month.split(separator: "-").compactMap { Int($0) }
        var comps = DateComponents()
        comps.year = parts[0]
        comps.month = parts[1]
        comps.day = 1
        comps.hour = 12
        let cal = calendar
        guard let first = cal.date(from: comps),
              let days = cal.range(of: .day, in: .month, for: first)?.count else { return nil }
        return ("\(month)-01", "\(month)-" + String(format: "%02d", days))
    }

    static func months(from: String, to: String) -> [String] {
        guard isMonth(String(from.prefix(7))), isMonth(String(to.prefix(7))) else { return [] }
        var y = Int(from.prefix(4)) ?? 0, m = Int(from.dropFirst(5).prefix(2)) ?? 1
        let ty = Int(to.prefix(4)) ?? 0, tm = Int(to.dropFirst(5).prefix(2)) ?? 1
        var out: [String] = []
        while (y, m) <= (ty, tm) && out.count < 1200 {
            out.append(String(format: "%04d-%02d", y, m))
            if m == 12 { y += 1; m = 1 } else { m += 1 }
        }
        return out
    }

    // MARK: Fahrten

    /// km je Fahrt: Tacho, sonst Route, sonst GPS (wie Server `trip_km`).
    static func tripKm(_ t: Trip) -> Double {
        if let a = t.kmStart, let b = t.kmEnd { return Double(b - a) }
        if let r = t.distanceRoute { return r }
        return t.distanceGps ?? 0
    }

    /// Wie Server `needs_review`: nicht bestätigt/gesperrt oder Kategorie unbekannt.
    static func needsReview(_ t: Trip) -> Bool {
        !(t.status == "confirmed" || t.status == "locked") || t.category == TripCategory.unknown.rawValue
    }

    static func chronological(_ a: Trip, _ b: Trip) -> Bool {
        let da = a.startDate ?? .distantPast
        let db = b.startDate ?? .distantPast
        if da != db { return da < db }
        return a.id < b.id
    }

    /// Nicht stornierte Fahrten mit lokalem Startdatum im Zeitraum (inklusive), chronologisch.
    static func trips(_ all: [Trip], vehicleId: String, from: String, to: String) -> [Trip] {
        all.filter { t in
            guard !t.deleted, t.vehicleId == vehicleId, let d = localDay(t.startAt) else { return false }
            return from <= d && d <= to
        }
        .sorted(by: chronological)
    }

    static func trips(_ all: [Trip], vehicleId: String, month: String) -> [Trip] {
        guard let b = monthBounds(month) else { return [] }
        return trips(all, vehicleId: vehicleId, from: b.first, to: b.last)
    }

    /// Letzte Fahrt mit lokalem Datum vor `before` ("yyyy-MM-dd").
    static func previousTrip(_ all: [Trip], vehicleId: String, before: String) -> Trip? {
        all.filter { t in
            guard !t.deleted, t.vehicleId == vehicleId, let d = localDay(t.startAt) else { return false }
            return d < before
        }
        .sorted(by: chronological).last
    }

    /// Lücke, wenn km_end(n) ≠ km_start(n+1) (negativ = Überschneidung).
    static func gaps(_ trips: [Trip], previous: Trip?) -> [TripGap] {
        let chain = (previous.map { [$0] } ?? []) + trips
        var out: [TripGap] = []
        for (a, b) in zip(chain, chain.dropFirst()) {
            guard let from = a.kmEnd, let to = b.kmStart, from != to else { continue }
            out.append(TripGap(afterTripId: a.id, beforeTripId: b.id, kmFrom: from, kmTo: to))
        }
        return out
    }

    /// Plausibilität je Fahrt; `blocking` verhindert den Abschluss (ausser force + Begründung).
    static func mismatches(_ trips: [Trip]) -> [TripMismatch] {
        var out: [TripMismatch] = []
        func add(_ t: Trip, _ reason: String, blocking: Bool = true) {
            out.append(TripMismatch(tripId: t.id, reason: reason, blocking: blocking))
        }
        for t in trips {
            if let a = t.kmStart, let b = t.kmEnd {
                let tacho = Double(b - a)
                for (label, d) in [("Routendistanz", t.distanceRoute), ("GPS-Distanz", t.distanceGps)] {
                    if let d, abs(d - tacho) > max(toleranceKm, 0.1 * tacho) {
                        add(t, "\(label) \(String(format: "%.1f", d)) km weicht vom km-Stand (\(b - a) km) ab",
                            blocking: false)
                    }
                }
                if t.kmEstimated { add(t, "km-Stand geschätzt (nicht abgelesen)") }
            } else {
                add(t, "km-Stand Beginn/Ende fehlt")
            }
            if t.endAt == nil { add(t, "Endzeit fehlt") }
            if t.category == "business" || t.category == "field",
               (t.purpose ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add(t, "Zweck fehlt (\(t.category == "business" ? "geschäftlich" : "Aussendienst"))")
            }
        }
        return out
    }

    /// Odometer-Abgleich (wie Server `odometer_check`). Ablesungen als (Tag "yyyy-MM-dd", km).
    static func odometerCheck(readings all: [(day: String, km: Int)], trips: [Trip], first: String,
                              last: String) -> OdometerCheck {
        let readings = all.filter { first <= $0.day && $0.day <= last }
            .sorted { ($0.day, $0.km) < ($1.day, $1.km) }
        let tripSum = round1(trips.reduce(0) { $0 + tripKm($1) })
        guard readings.count >= 2, let lo = readings.map(\.km).min(), let hi = readings.map(\.km).max(), hi != lo else {
            return OdometerCheck(tripKm: tripSum, odometerKm: nil, diffKm: nil, ok: nil, readings: readings.count,
                                 note: "Zu wenige km-Stände im Monat für den Abgleich")
        }
        let dLo = readings.first!.day, dHi = readings.last!.day
        var covered = 0.0
        for t in trips {
            if let a = t.kmStart, let b = t.kmEnd {
                covered += Double(max(0, min(b, hi) - max(a, lo)))
            } else if let d = localDay(t.startAt), dLo < d && d < dHi {
                covered += tripKm(t)
            }
        }
        let odo = Double(hi - lo)
        let diff = round1(covered - odo)
        return OdometerCheck(tripKm: round1(covered), odometerKm: odo, diffKm: diff,
                             ok: abs(diff) <= max(toleranceKm, tolerancePct * odo), readings: readings.count, note: nil)
    }

    /// km je Kategorie (gerundet auf 0.1).
    static func kmByCategory(_ trips: [Trip]) -> [String: Double] {
        var out: [String: Double] = [:]
        for c in allCategories { out[c] = 0 }
        for t in trips { out[t.category, default: 0] += tripKm(t) }
        return out.mapValues(round1)
    }

    /// Namen beim Abschluss einfrieren: Kundenname (mit Referenz) und leere Start-/Zielbezeichnungen aus dem
    /// Ort. Privatfahrten erhalten keine Orte, private Orte keine Bezeichnung.
    static func frozenNames(_ trip: Trip, places: [String: Place], customers: [String: Customer]) -> Trip {
        var t = trip
        let isPrivate = t.category == TripCategory.personal.rawValue || t.privateMode
        if t.privateMode || t.customerId == nil {
            t.customerName = nil
        } else if let c = t.customerId.flatMap({ customers[$0] }) {
            t.customerName = customerDisplay(c)
        } else {
            t.customerName = nil
        }
        if !isPrivate {
            if (t.startLabel ?? "").isEmpty, let p = t.startPlaceId.flatMap({ places[$0] }), !p.isPrivate {
                t.startLabel = String(p.name.prefix(200))
            }
            if (t.endLabel ?? "").isEmpty, let p = t.endPlaceId.flatMap({ places[$0] }), !p.isPrivate {
                t.endLabel = String(p.name.prefix(200))
            }
        }
        return t
    }

    static func customerDisplay(_ c: Customer) -> String {
        let text = c.ref?.nilIfEmpty.map { "\(c.name) (\($0))" } ?? c.name
        return String(text.prefix(150))
    }

    // MARK: Runden wie Python `round` (halbe Werte zur geraden Ziffer)

    static func round(_ v: Double, _ digits: Int) -> Double {
        let f = pow(10.0, Double(digits))
        return (v * f).rounded(.toNearestOrEven) / f
    }

    static func round1(_ v: Double) -> Double { round(v, 1) }
    static func round2(_ v: Double) -> Double { round(v, 2) }
}

/// Ergebnis der lokalen Monatsprüfung (`TenantStore.monthCheck(vehicleId:month:)`), Aufbau wie
/// GET …/trips/check des Servers.
struct MonthCheckResult {
    var month: String
    /// Fahrten des Monats (lokale Zeit Zürich), chronologisch
    var trips: [Trip]
    var gaps: [TripGap]
    /// Alle Auffälligkeiten (`blocking` = verhindert den Abschluss)
    var mismatches: [TripMismatch]
    var odometerCheck: OdometerCheck
    /// Unbestätigte Fahrten bzw. ohne Kategorie
    var unconfirmed: [Trip]
    var closed: Bool
    var corrections: Int
    /// Monat bereits abgelaufen (nur dann abschliessbar)
    var isPast: Bool

    var blockingMismatches: [TripMismatch] { mismatches.filter { $0.blocking ?? true } }
    /// Abschluss ohne `force` möglich
    var canCloseWithoutForce: Bool { isPast && !closed && unconfirmed.isEmpty && gaps.isEmpty && blockingMismatches.isEmpty }
    /// Abschluss nur mit `force` + Begründung möglich
    var needsForce: Bool { isPast && !closed && unconfirmed.isEmpty && !(gaps.isEmpty && blockingMismatches.isEmpty) }

    /// Gleiches Modell wie die Server-Antwort (für bestehende Ansichten).
    var tripCheck: TripCheck {
        TripCheck(month: month, trips: trips.count, gaps: gaps, mismatches: mismatches, odometerCheck: odometerCheck,
                  unconfirmed: unconfirmed.count, closed: closed)
    }
}
