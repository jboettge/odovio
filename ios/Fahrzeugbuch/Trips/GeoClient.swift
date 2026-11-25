import Foundation

/// Aufrufe an den eigenen Server (OSRM-Match, Photon-Reverse, LLM-Vorschlag).
/// Alle Fehler (offline, 4xx/5xx, 204, Dienst nicht konfiguriert) ergeben `nil` – nie ein Abbruch.
struct GeoClient {
    let api: APIClient

    /// Im Lokalmodus nicht verfügbar
    var isAvailable: Bool { !api.isLocalPlaceholder }

    struct MatchResult: Decodable {
        var distanceKm: Double
        var durationS: Double
        var confidence: Double
        var matchedPoints: Int
    }

    struct ReverseResult: Decodable {
        var label: String?
        var municipality: String?
        var country: String?
    }

    /// Körper für `POST api/t/{tenant}/trips/suggest` – nur pseudonymisierte Merkmale, keine Koordinaten.
    struct SuggestRequest: Encodable {
        struct Features: Encodable {
            var startAt: String
            var endAt: String?
            var startLabel: String?
            var endLabel: String?
            var startPlaceName: String?
            var endPlaceName: String?
            var distanceKm: Double?
            var weekday: Int?
            var privateMode: Bool
        }

        struct CustomerRef: Encodable {
            var id: String
            var name: String
        }

        struct Recent: Encodable {
            var startLabel: String?
            var endLabel: String?
            var category: String?
            var purpose: String?
        }

        var trip: Features
        var customers: [CustomerRef]
        var recent: [Recent]

        /// Kontext für das LLM: zuletzt bestätigte Fahrten – nie Privatfahrten (weder Privatmodus noch
        /// Kategorie „privat“), nie Koordinaten; Texte gekürzt.
        static func recentContext(history: [Trip], excluding tripId: String?, limit: Int = 20) -> [Recent] {
            func cut(_ s: String?) -> String? { s?.nilIfEmpty.map { String($0.prefix(120)) } }
            return history
                .filter { t in
                    t.id != tripId && !t.deleted && !t.privateMode
                        && (t.status == "confirmed" || t.status == "locked")
                        && t.category != TripCategory.personal.rawValue
                        && TripCategoryText.all.contains(t.category)
                }
                .sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }
                .prefix(limit)
                .map { t in
                    Recent(startLabel: cut(t.startLabel), endLabel: cut(t.endLabel), category: t.category,
                           purpose: cut(t.purpose))
                }
        }
    }

    private struct MatchPoint: Encodable {
        var lat: Double
        var lon: Double
        var ts: Double
        var accuracy: Double
    }

    private struct MatchBody: Encodable {
        var points: [MatchPoint]
    }

    private struct SuggestResponse: Decodable {
        var category: String
        var purpose: String?
        var customerId: String?
        var confidence: Double?
        var reason: String?
        var source: String?
    }

    private struct ReverseBody: Encodable {
        var lat: Double
        var lon: Double
    }

    static let maxMatchPoints = 5000

    // MARK: Aufrufe

    /// Strassendistanz zum Track (der Server verwirft den Track nach dem Abgleich).
    /// Aufrufer übergeben den mit `GeoPrivacy.trimmed` gekappten Track (Wohnort, erste/letzte 200 m).
    func match(_ points: [TrackPoint]) async -> MatchResult? {
        guard points.count >= 2 else { return nil }
        let thinned = Self.thin(points, max: Self.maxMatchPoints)
        let body = MatchBody(points: thinned.map {
            MatchPoint(lat: $0.lat, lon: $0.lon, ts: $0.ts, accuracy: $0.accuracy)
        })
        guard let data = try? APIClient.encoder.encode(body),
              let response = try? await request("POST", "api/geo/match", body: data, timeout: 15),
              response.status == 200, !response.data.isEmpty,
              let result = try? APIClient.decoder.decode(MatchResult.self, from: response.data),
              result.distanceKm.isFinite, result.distanceKm >= 0 else { return nil }
        return result
    }

    /// Adresse/Gemeinde zu einem Punkt; die Koordinate wird vorher auf `roundingMeters` gerundet.
    /// POST mit Körper (nicht als Query), damit Koordinaten nicht in Zugriffs-Logs landen.
    func reverse(_ point: TrackPoint?, roundingMeters: Double) async -> ReverseResult? {
        guard let point else { return nil }
        let r = GeoMath.rounded(lat: point.lat, lon: point.lon, meters: roundingMeters)
        guard let body = try? APIClient.encoder.encode(ReverseBody(lat: r.lat, lon: r.lon)),
              let response = try? await request("POST", "api/geo/reverse", body: body, timeout: 8),
              response.status == 200, !response.data.isEmpty else { return nil }
        return try? APIClient.decoder.decode(ReverseResult.self, from: response.data)
    }

    /// LLM-Vorschlag (Stufe 4). 204 = kein Vorschlag, 503 = LLM nicht konfiguriert → `nil`.
    func suggest(tenant: String, request body: SuggestRequest) async -> TripSuggestion? {
        guard !body.trip.privateMode,
              let data = try? APIClient.encoder.encode(body),
              let response = try? await request("POST", "api/t/\(tenant)/trips/suggest", body: data, timeout: 15),
              response.status == 200, !response.data.isEmpty,
              let s = try? APIClient.decoder.decode(SuggestResponse.self, from: response.data),
              TripCategoryText.all.contains(s.category) else { return nil }
        let confidence = min(1, max(0, s.confidence ?? 0.5))
        return TripSuggestion(category: s.category, purpose: s.purpose?.nilIfEmpty, customerId: s.customerId?.nilIfEmpty,
                              confidence: confidence, reason: s.reason?.nilIfEmpty ?? "Vorschlag des Sprachmodells",
                              source: "llm")
    }

    // MARK: Intern

    /// Gleichmässig ausdünnen; erster und letzter Punkt bleiben.
    static func thin(_ points: [TrackPoint], max n: Int) -> [TrackPoint] {
        guard points.count > n, n >= 2 else { return points }
        let step = Double(points.count - 1) / Double(n - 1)
        return (0..<n).map { points[min(points.count - 1, Int((Double($0) * step).rounded()))] }
    }

    /// Tolerant (204/503 usw. ohne Fehler) über `APIClient.rawResponse` – gleiche Session (ohne Cache),
    /// Basis-URL und Token wie die App, inkl. einmaligem Refresh nach 401.
    private func request(_ method: String, _ path: String, body: Data? = nil,
                         timeout: TimeInterval) async throws -> APIClient.RawResponse {
        // Lokalmodus: keine Geodienste/LLM des Servers (Aufrufer erhalten `nil`)
        guard !api.isLocalPlaceholder else { throw URLError(.cannotConnectToHost) }
        return try await api.rawResponse(method, path, body: body, timeout: timeout)
    }
}
