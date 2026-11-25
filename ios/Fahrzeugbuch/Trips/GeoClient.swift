import Foundation

/// Aufrufe an den eigenen Server (OSRM-Match, Photon-Reverse, LLM-Vorschlag).
/// Alle Fehler (offline, 4xx/5xx, 204, Dienst nicht konfiguriert) ergeben `nil` – nie ein Abbruch.
struct GeoClient {
    let api: APIClient

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

    private struct RawResponse {
        var data: Data
        var status: Int
    }

    static let maxMatchPoints = 5000

    // MARK: Aufrufe

    /// Strassendistanz zum Track (der Server verwirft den Track nach dem Abgleich).
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
    func reverse(_ point: TrackPoint?, roundingMeters: Double) async -> ReverseResult? {
        guard let point else { return nil }
        let r = GeoMath.rounded(lat: point.lat, lon: point.lon, meters: roundingMeters)
        let query = [URLQueryItem(name: "lat", value: String(format: "%.5f", r.lat)),
                     URLQueryItem(name: "lon", value: String(format: "%.5f", r.lon))]
        guard let response = try? await request("GET", "api/geo/reverse", query: query, timeout: 8),
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

    /// Eigener Request (statt `APIClient.send`), damit leere Antworten (204) und Statuscodes tolerant
    /// behandelt werden. Gleiche Basis-URL und Token wie die App, inkl. einmaligem Refresh nach 401.
    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
                         timeout: TimeInterval) async throws -> RawResponse {
        guard var comps = URLComponents(url: api.baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        let token = try await api.tokenProvider(false)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var (data, response) = try await URLSession.shared.data(for: req)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            let fresh = try await api.tokenProvider(true)
            req.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            (data, response) = try await URLSession.shared.data(for: req)
        }
        return RawResponse(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
