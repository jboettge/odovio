import Foundation

struct APIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? {
        switch status {
        case 401: "Nicht autorisiert – bitte neu anmelden."
        case 403: "Keine Berechtigung: \(message)"
        default: "Serverfehler \(status): \(message)"
        }
    }
}

struct APIClient {
    let baseURL: URL
    /// Liefert ein Access-Token; `true` erzwingt Refresh (nach 401).
    let tokenProvider: (_ forceRefresh: Bool) async throws -> String

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .formatted(dayFormatter)
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .formatted(dayFormatter)
        return e
    }()

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await send("GET", path, query: query)
    }

    func send<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [],
                            body: Data? = nil) async throws -> T {
        let data = try await raw(method, path, query: query, body: body)
        return try Self.decoder.decode(T.self, from: data)
    }

    /// Rohdaten (z. B. PDF).
    func download(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await raw("GET", path, query: query, body: nil)
    }

    /// Rohdaten hochladen (z. B. Beleg-JPEG per PUT). Gleiche Token-/401-Logik wie alle Aufrufe.
    @discardableResult
    func upload(path: String, data: Data, contentType: String, method: String = "PUT") async throws -> Data {
        let response = try await rawResponse(method, path, body: data, contentType: contentType, timeout: 60)
        return try Self.check(response)
    }

    /// Antwort eines Requests ohne Statusprüfung.
    struct RawResponse {
        var data: Data
        var status: Int
    }

    /// Request ohne Statusprüfung (für tolerante Aufrufe mit 204/503 usw.), inkl. einmaligem Refresh nach 401.
    func rawResponse(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
                     contentType: String = "application/json", timeout: TimeInterval = 20) async throws -> RawResponse {
        guard var comps = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let body {
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        let token = try await tokenProvider(false)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var (data, response) = try await URLSession.shared.data(for: req)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            // Token evtl. serverseitig widerrufen/abgelaufen → einmal erneuern und wiederholen
            let fresh = try await tokenProvider(true)
            req.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            (data, response) = try await URLSession.shared.data(for: req)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError(status: 0, message: "Keine HTTP-Antwort")
        }
        return RawResponse(data: data, status: http.statusCode)
    }

    private func raw(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async throws -> Data {
        try Self.check(try await rawResponse(method, path, query: query, body: body))
    }

    /// 2xx → Daten, sonst `APIError` mit Detailtext des Servers.
    private static func check(_ response: RawResponse) throws -> Data {
        guard (200..<300).contains(response.status) else {
            let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]
            let detail = json?["detail"] as? String ?? String(data: response.data, encoding: .utf8) ?? ""
            throw APIError(status: response.status, message: detail)
        }
        return response.data
    }
}
