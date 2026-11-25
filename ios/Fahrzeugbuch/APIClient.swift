import Foundation

struct APIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? {
        switch status {
        case 401: "Nicht autorisiert – bitte neu anmelden."
        case 403: "Keine Berechtigung (Rolle fehlt?)."
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

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .formatted(dayFormatter)
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .formatted(dayFormatter)
        return e
    }()

    func get<T: Decodable>(_ path: String) async throws -> T {
        let data = try await raw("GET", path, nil)
        return try Self.decoder.decode(T.self, from: data)
    }

    func post<T: Decodable>(_ path: String, _ body: any Encodable) async throws -> T {
        let data = try await raw("POST", path, body)
        return try Self.decoder.decode(T.self, from: data)
    }

    func put<T: Decodable>(_ path: String, _ body: any Encodable) async throws -> T {
        let data = try await raw("PUT", path, body)
        return try Self.decoder.decode(T.self, from: data)
    }

    func patch<T: Decodable>(_ path: String, _ body: any Encodable) async throws -> T {
        let data = try await raw("PATCH", path, body)
        return try Self.decoder.decode(T.self, from: data)
    }

    func delete(_ path: String) async throws {
        _ = try await raw("DELETE", path, nil)
    }

    private func raw(_ method: String, _ path: String, _ body: (any Encodable)?) async throws -> Data {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.httpMethod = method
        req.timeoutInterval = 15
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try Self.encoder.encode(body)
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
        guard (200..<300).contains(http.statusCode) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let detail = json?["detail"] as? String ?? String(data: data, encoding: .utf8) ?? ""
            throw APIError(status: http.statusCode, message: detail)
        }
        return data
    }
}
