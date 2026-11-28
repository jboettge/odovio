import Foundation

/// Merkmale einer Fahrt für die Vorschlagslogik (ohne Store-Zugriff → testbar).
struct TripFacts {
    var tripId: String?
    var vehicleId: String
    var start: Date
    var end: Date?
    var startPlaceId: String?
    var endPlaceId: String?
    var startLabel: String?
    var endLabel: String?
    var endPlaceName: String?
    var endPlaceCustomerId: String?
    var endPlaceCategory: String?
    /// Zielkoordinate (nur lokal, für den Kalenderabgleich)
    var endLat: Double?
    var endLon: Double?
    var privateMode: Bool = false
    var distanceKm: Double?
}

/// Vorschlagsstufen (rein, ohne Seiteneffekte):
/// (1) Regeln (`PurposeRule`; kleinere `priority` gewinnt – wie `TenantStore.ruleList`) bzw. Standardkategorie des Zielorts,
/// (2) Kalendertermin ±2 h am Ziel, (3) Wiederholungsmuster (≥ 3× in 4 Wochen gleich bestätigt).
/// Stufe (4) LLM liegt im `GeoClient` und wird vom `TripCoordinator` nur ohne Privatmodus aufgerufen.
enum RuleEngine {
    struct CustomerName {
        var id: String
        var name: String
    }

    static let calendarWindow: TimeInterval = 2 * 3600
    static let patternWindow: TimeInterval = 28 * 86_400
    static let patternMinCount = 3

    // MARK: Vorschlag übernehmen

    /// `suggestion_*` setzen. Eine Regel mit Auto-Bestätigung bestätigt die Fahrt – ausser die km-Stände
    /// sind nur geschätzt (GPS): dann bleibt sie „vorgeschlagen“, damit der Tachostand geprüft wird (U3).
    static func apply(_ s: TripSuggestion, to trip: inout Trip) {
        trip.suggestionCategory = s.category
        trip.suggestionPurpose = s.purpose.map { String($0.prefix(Trip.maxPurpose)) }
        trip.suggestionCustomerId = s.customerId
        trip.suggestionConfidence = (min(1, max(0, s.confidence)) * 100).rounded() / 100
        trip.suggestionReason = String(s.reason.prefix(300))
        trip.suggestionSource = s.source
        if s.source == "rule" && s.autoConfirm && !trip.kmEstimated {
            // Regel mit Auto-Bestätigung (pro Regel aktivierbar, im Review sichtbar)
            trip.category = s.category
            trip.purpose = s.purpose
            trip.customerId = s.customerId
            trip.status = "confirmed"
        } else {
            trip.status = "suggested"
        }
        if trip.privateMode {
            trip.suggestionPurpose = nil
            trip.suggestionCustomerId = nil
        }
    }

    // MARK: Stufe 1 – Regeln

    static func ruleSuggestion(rules: [PurposeRule], facts: TripFacts, placeNames: [String: String] = [:],
                               calendar: Calendar = .current) -> TripSuggestion? {
        let hits = rules.filter { matches($0, facts, calendar: calendar) }
            .sorted { a, b in
                if a.priority != b.priority { return a.priority < b.priority }   // kleiner = zuerst
                let sa = specificity(a), sb = specificity(b)
                if sa != sb { return sa > sb }
                return a.id < b.id
            }
        if let r = hits.first {
            return TripSuggestion(category: r.resultCategory, purpose: r.resultPurpose?.nilIfEmpty,
                                  customerId: r.resultCustomerId?.nilIfEmpty,
                                  confidence: r.autoConfirm ? 0.97 : 0.92,
                                  reason: "Regel: " + describe(r, placeNames: placeNames),
                                  source: "rule", autoConfirm: r.autoConfirm, ruleId: r.id)
        }
        // Zielort mit Standardkategorie (z. B. Kunde → geschäftlich)
        if let cat = facts.endPlaceCategory, TripCategoryText.all.contains(cat) {
            let name = facts.endPlaceName ?? "Zielort"
            return TripSuggestion(category: cat, purpose: nil, customerId: facts.endPlaceCustomerId,
                                  confidence: 0.8,
                                  reason: "Standardkategorie des Orts «\(name)»: \(TripCategoryText.label(cat))",
                                  source: "rule")
        }
        return nil
    }

    static func matches(_ r: PurposeRule, _ f: TripFacts, calendar: Calendar = .current) -> Bool {
        guard r.active, !r.deleted, TripCategoryText.all.contains(r.resultCategory), specificity(r) > 0 else {
            return false
        }
        if let from = r.fromPlaceId, from != f.startPlaceId { return false }
        if let to = r.toPlaceId, to != f.endPlaceId { return false }
        if let v = r.vehicleId, v != f.vehicleId { return false }
        if let days = weekdays(r.weekdays), !days.contains(TripTime.isoWeekday(f.start, calendar: calendar)) {
            return false
        }
        let from = TripTime.minutes(r.timeFrom)
        let to = TripTime.minutes(r.timeTo)
        if from != nil || to != nil {
            let t = TripTime.minuteOfDay(f.start, calendar: calendar)
            let lo = from ?? 0
            let hi = to ?? (24 * 60 - 1)
            let inside = lo <= hi ? (t >= lo && t <= hi) : (t >= lo || t <= hi)   // über Mitternacht
            if !inside { return false }
        }
        return true
    }

    /// Anzahl Bedingungen; eine Regel ganz ohne Bedingung wird ignoriert (würde alles treffen).
    static func specificity(_ r: PurposeRule) -> Int {
        var n = 0
        if r.fromPlaceId != nil { n += 1 }
        if r.toPlaceId != nil { n += 1 }
        if r.vehicleId != nil { n += 1 }
        if weekdays(r.weekdays) != nil { n += 1 }
        if r.timeFrom != nil || r.timeTo != nil { n += 1 }
        return n
    }

    static func weekdays(_ s: String?) -> Set<Int>? {
        guard let s, !s.trimmed.isEmpty else { return nil }
        let days = Set(s.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { (1...7).contains($0) })
        return days.isEmpty ? nil : days
    }

    static func describe(_ r: PurposeRule, placeNames: [String: String]) -> String {
        var parts: [String] = []
        let from = r.fromPlaceId.map { placeNames[$0] ?? "Ort" }
        let to = r.toPlaceId.map { placeNames[$0] ?? "Ort" }
        switch (from, to) {
        case let (.some(a), .some(b)): parts.append("\(a) → \(b)")
        case let (.some(a), .none): parts.append("ab \(a)")
        case let (.none, .some(b)): parts.append("nach \(b)")
        case (.none, .none): break
        }
        if let days = weekdays(r.weekdays) {
            parts.append(days == Set(1...5) ? "Mo–Fr" : weekdayText(days))
        }
        if r.timeFrom != nil || r.timeTo != nil {
            parts.append("\(r.timeFrom ?? "00:00")–\(r.timeTo ?? "23:59")")
        }
        if r.vehicleId != nil { parts.append("Fahrzeug") }
        parts.append("→ \(TripCategoryText.label(r.resultCategory))")
        return parts.joined(separator: ", ")
    }

    static func weekdayText(_ days: Set<Int>) -> String {
        let names = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]
        return days.sorted().map { names[$0 - 1] }.joined(separator: ",")
    }

    // MARK: Stufe 2 – Kalender

    static func calendarSuggestion(facts f: TripFacts, appointments: [CalendarAppointment],
                                   customers: [CustomerName]) -> TripSuggestion? {
        let arrival = f.end ?? f.start
        var best: (score: Double, appointment: CalendarAppointment, customerId: String?, geo: Bool)?
        for a in appointments {
            // Termin beginnt ±2 h um die Ankunft bzw. läuft während der Fahrt
            let near = abs(a.start.timeIntervalSince(arrival)) <= calendarWindow
                || (a.start <= arrival && a.end >= f.start)
            guard near, !a.title.isEmpty else { continue }

            var geoMatch = false
            if let la = a.lat, let lo = a.lon, let el = f.endLat, let en = f.endLon {
                geoMatch = GeoMath.distance(lat1: la, lon1: lo, lat2: el, lon2: en) <= 400
            }
            let text = max(similarity(a.location, f.endLabel), similarity(a.location, f.endPlaceName),
                           similarity(a.title, f.endPlaceName))
            let customer = customers.first { c in
                contains(a.title, word: c.name) || contains(a.location, word: c.name)
            }
            let customerId = customer?.id ?? f.endPlaceCustomerId
            guard geoMatch || text >= 0.65 || customer != nil else { continue }

            var score = geoMatch ? 1.0 : text
            if customer != nil { score += 0.3 }
            score -= abs(a.start.timeIntervalSince(arrival)) / (calendarWindow * 10)   // näher = besser
            if best == nil || score > best!.score {
                best = (score, a, customerId, geoMatch)
            }
        }
        guard let hit = best else { return nil }
        var confidence = 0.7
        if hit.geo { confidence += 0.1 }
        if hit.customerId != nil { confidence += 0.05 }
        let time = hit.appointment.start.formatted(date: .omitted, time: .shortened)
        return TripSuggestion(category: "business", purpose: String(hit.appointment.title.prefix(120)),
                              customerId: hit.customerId, confidence: min(confidence, 0.9),
                              reason: "Kalendertermin um \(time) passt zum Ziel", source: "calendar")
    }

    // MARK: Stufe 3 – Wiederholungsmuster

    static func patternSuggestion(facts f: TripFacts, history: [Trip]) -> TripSuggestion? {
        let since = f.start.addingTimeInterval(-patternWindow)
        let byPlace = f.startPlaceId != nil && f.endPlaceId != nil
        let startKey = normalize(f.startLabel ?? "")
        let endKey = normalize(f.endLabel ?? "")
        guard byPlace || (!startKey.isEmpty && !endKey.isEmpty) else { return nil }

        let similar = history.filter { t in
            guard t.id != f.tripId, !t.deleted, !t.privateMode,
                  t.status == "confirmed" || t.status == "locked",
                  TripCategoryText.all.contains(t.category),
                  let d = TripTime.parse(t.startAt), d >= since, d < f.start else { return false }
            if byPlace { return t.startPlaceId == f.startPlaceId && t.endPlaceId == f.endPlaceId }
            return normalize(t.startLabel ?? "") == startKey && normalize(t.endLabel ?? "") == endKey
        }
        guard similar.count >= patternMinCount else { return nil }
        let counts = Dictionary(grouping: similar, by: \.category)
        guard let top = counts.max(by: { $0.value.count < $1.value.count }),
              top.value.count >= patternMinCount,
              Double(top.value.count) / Double(similar.count) >= 0.8 else { return nil }
        let n = top.value.count
        var confidence = min(0.85, 0.6 + 0.05 * Double(n - patternMinCount))
        if !byPlace { confidence -= 0.1 }
        return TripSuggestion(category: top.key, purpose: mostCommon(top.value.compactMap { $0.purpose?.nilIfEmpty }),
                              customerId: mostCommon(top.value.compactMap { $0.customerId }),
                              confidence: confidence,
                              reason: "\(n)× gleiche Strecke in 4 Wochen als \(TripCategoryText.label(top.key)) bestätigt",
                              source: "pattern")
    }

    // MARK: Text-Hilfen

    static func mostCommon(_ values: [String]) -> String? {
        guard !values.isEmpty else { return nil }
        let counts = Dictionary(grouping: values, by: { $0 }).mapValues(\.count)
        return counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
    }

    /// Kleinbuchstaben, ohne Akzente, nur Buchstaben/Ziffern, einfache Leerzeichen.
    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_CH"))
        let chars: [Character] = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(chars).split(separator: " ").joined(separator: " ")
    }

    static func tokens(_ s: String) -> Set<String> {
        Set(normalize(s).split(separator: " ").map(String.init).filter { $0.count >= 3 })
    }

    /// 0…1: Enthaltensein oder Anteil gemeinsamer Wörter (≥ 3 Zeichen).
    static func similarity(_ a: String?, _ b: String?) -> Double {
        guard let a, let b else { return 0 }
        let na = normalize(a), nb = normalize(b)
        guard !na.isEmpty, !nb.isEmpty else { return 0 }
        if na == nb { return 1 }
        if min(na.count, nb.count) >= 6 && (na.contains(nb) || nb.contains(na)) { return 0.9 }
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        let common = ta.intersection(tb).count
        var score = Double(common) / Double(min(ta.count, tb.count))
        if common < 2 { score *= 0.6 }   // ein einzelnes gemeinsames Wort (z. B. nur „Zürich“) ist schwach
        return score
    }

    /// Ganzes Wort/Wortfolge enthalten (Kundenname im Termintitel)?
    static func contains(_ text: String?, word: String) -> Bool {
        guard let text else { return false }
        let w = normalize(word)
        guard w.count >= 3 else { return false }
        return (" " + normalize(text) + " ").contains(" " + w + " ")
    }
}
