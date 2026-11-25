import Foundation

/// Orte lernen (rein, on-device): Endpunkte clustern, Ortszuordnung, Regelvorschläge.
enum PlaceLearner {
    static let clusterRadius = 150.0
    static let minVisits = 3
    static let ruleWindow: TimeInterval = 28 * 86_400

    struct Sample {
        var lat: Double
        var lon: Double
        var label: String?
    }

    private struct Cluster {
        var lat: Double
        var lon: Double
        var count: Int
        var labels: [String: Int]
    }

    /// Nächster bekannter Ort, dessen Radius den Punkt enthält (`slack` = zusätzliche Toleranz).
    static func match(lat: Double, lon: Double, places: [Place], slack: Double = 0) -> Place? {
        var best: Place?
        var bestDistance = Double.greatestFiniteMagnitude
        for p in places where !p.deleted {
            guard let plat = p.lat, let plon = p.lon else { continue }
            let d = GeoMath.distance(lat1: lat, lon1: lon, lat2: plat, lon2: plon)
            // Server rundet Ortskoordinaten auf ~100 m → mindestens 100 m Radius
            if d <= max(Double(p.radiusM), 100) + slack && d < bestDistance {
                best = p
                bestDistance = d
            }
        }
        return best
    }

    /// Cluster (150 m) mit ≥ 3 Besuchen, zu denen noch kein Ort passt; häufigste zuerst.
    static func candidates(samples: [Sample], places: [Place]) -> [PlaceCandidate] {
        var clusters: [Cluster] = []
        for s in samples {
            var bestIndex: Int?
            var bestDistance = Double.greatestFiniteMagnitude
            for (i, c) in clusters.enumerated() {
                let d = GeoMath.distance(lat1: c.lat, lon1: c.lon, lat2: s.lat, lon2: s.lon)
                if d < bestDistance {
                    bestDistance = d
                    bestIndex = i
                }
            }
            let label = s.label?.nilIfEmpty
            if let i = bestIndex, bestDistance <= clusterRadius {
                var c = clusters[i]
                let n = Double(c.count)
                c.lat = (c.lat * n + s.lat) / (n + 1)
                c.lon = (c.lon * n + s.lon) / (n + 1)
                c.count += 1
                if let label { c.labels[label, default: 0] += 1 }
                clusters[i] = c
            } else {
                clusters.append(Cluster(lat: s.lat, lon: s.lon, count: 1, labels: label.map { [$0: 1] } ?? [:]))
            }
        }
        return clusters
            .filter { $0.count >= minVisits && match(lat: $0.lat, lon: $0.lon, places: places, slack: 50) == nil }
            .sorted { $0.count > $1.count }
            .map { c in
                let lat = (c.lat * 1e4).rounded() / 1e4
                let lon = (c.lon * 1e4).rounded() / 1e4
                let label = c.labels.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
                return PlaceCandidate(id: "cand-\(Int((lat * 1e4).rounded()))-\(Int((lon * 1e4).rounded()))",
                                      lat: lat, lon: lon, visits: c.count, suggestedLabel: label)
            }
    }

    /// Ortspaare, die in 4 Wochen ≥ 3× an Werktagen (Mo–Fr) mit gleicher Kategorie bestätigt wurden
    /// und noch keine Regel haben → Regelvorschlag (`origin` "learned", `autoConfirm` aus; nicht gespeichert).
    static func ruleCandidates(trips: [Trip], rules: [PurposeRule], now: Date = Date(),
                               calendar: Calendar = .current) -> [PurposeRule] {
        let since = now.addingTimeInterval(-ruleWindow)
        struct Hit {
            var trip: Trip
            var minute: Int
        }
        var groups: [String: [Hit]] = [:]
        for t in trips {
            guard !t.deleted, !t.privateMode, t.status == "confirmed" || t.status == "locked",
                  TripCategoryText.all.contains(t.category),
                  let from = t.startPlaceId, let to = t.endPlaceId, from != to,
                  let d = TripTime.parse(t.startAt), d >= since, d <= now,
                  (1...5).contains(TripTime.isoWeekday(d, calendar: calendar)) else { continue }
            groups["\(from)|\(to)", default: []].append(Hit(trip: t, minute: TripTime.minuteOfDay(d, calendar: calendar)))
        }
        var result: [PurposeRule] = []
        for (_, hits) in groups.sorted(by: { $0.key < $1.key }) {
            guard hits.count >= minVisits, let first = hits.first?.trip,
                  let from = first.startPlaceId, let to = first.endPlaceId else { continue }
            let categories = Set(hits.map(\.trip.category))
            guard categories.count == 1, let category = categories.first else { continue }
            let exists = rules.contains { r in !r.deleted && r.fromPlaceId == from && r.toPlaceId == to }
            if exists { continue }
            let minutes = hits.map(\.minute)
            var timeFrom: String?
            var timeTo: String?
            if let lo = minutes.min(), let hi = minutes.max(), hi - lo <= 240 {   // „zu ähnlichen Zeiten“
                timeFrom = TripTime.hhmm(lo - 30)
                timeTo = TripTime.hhmm(hi + 30)
            }
            let vehicles = Set(hits.map(\.trip.vehicleId))
            // Priorität 200: gelernte Regeln nach den eigenen (Default 100; kleiner = zuerst)
            let rule = PurposeRule(priority: 200,
                                   fromPlaceId: from,
                                   toPlaceId: to,
                                   weekdays: "1,2,3,4,5",
                                   timeFrom: timeFrom,
                                   timeTo: timeTo,
                                   vehicleId: vehicles.count == 1 ? vehicles.first : nil,
                                   resultCategory: category,
                                   resultPurpose: RuleEngine.mostCommon(hits.compactMap { $0.trip.purpose?.nilIfEmpty }),
                                   resultCustomerId: RuleEngine.mostCommon(hits.compactMap { $0.trip.customerId }),
                                   autoConfirm: false,
                                   origin: "learned",
                                   active: true)
            result.append(rule)
        }
        return result
    }
}
