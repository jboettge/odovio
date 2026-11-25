import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct APIError: LocalizedError {
    let status: Int
    /// Detail des Servers: Text (`detail` als String) bzw. roher Body (strukturiertes `detail`, HTML …)
    let message: String
    /// Sekunden aus `Retry-After` (429/503), falls geliefert
    var retryAfter: TimeInterval? = nil

    /// Verständlicher deutscher Text (nie rohes HTML); siehe `Error.userMessage`.
    var errorDescription: String? { ErrorText.apiMessage(self) }
}

/// Zentrale ISO-8601-Zeitpunkte (Fahrten, Belege, client_ts): ein Formatter-Satz für die ganze App.
enum ISODate {
    private static let local: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// ISO-8601 mit lokalem Offset, z. B. 2026-11-24T07:42:00+01:00
    static func string(_ date: Date) -> String { local.string(from: date) }

    /// Mit oder ohne Sekundenbruchteile, beliebiger Offset.
    static func parse(_ value: String) -> Date? {
        local.date(from: value) ?? fractional.date(from: value)
    }
}

struct APIClient {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    let baseURL: URL
    /// Liefert ein Access-Token; `true` erzwingt Refresh (nach 401).
    let tokenProvider: (_ forceRefresh: Bool) async throws -> String
    /// Netzwerkzugriff (Tests ersetzen ihn); Standard: `APIClient.session` ohne Cache/Cookies.
    private(set) var transport: Transport = APIClient.defaultTransport

    init(baseURL: URL, tokenProvider: @escaping (_ forceRefresh: Bool) async throws -> String) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
    }

    /// Lokalmodus: Platzhalter ohne Server – jeder Aufruf schlägt sofort fehl (kein Netzwerkzugriff).
    static let localPlaceholder = APIClient(baseURL: URL(string: "lokal://geraet")!) { _ in
        throw APIError(status: 503, message: "Im Lokalmodus nicht verfügbar (kein Server).")
    }

    /// Platzhalter des Lokalmodus (Scan-KI, Geodienste, Berichte des Servers nicht verfügbar)
    var isLocalPlaceholder: Bool { baseURL.scheme == "lokal" }

    /// Kopie mit anderem Transport (Tests).
    func with(transport: @escaping Transport) -> APIClient {
        var copy = self
        copy.transport = transport
        return copy
    }

    /// Eigene Session ohne URL-Cache und ohne Cookies: API-Antworten (auch Belege) landen nie in
    /// `Caches/…/Cache.db` und bleiben nach Abmelden/Benutzerwechsel nicht liegen.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()

    static let defaultTransport: Transport = { request in
        try await APIClient.session.data(for: request)
    }

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
        /// Sekunden aus `Retry-After`
        var retryAfter: TimeInterval? = nil
    }

    /// Request ohne Statusprüfung (für tolerante Aufrufe mit 204/503 usw.), inkl. einmaligem Refresh nach 401.
    func rawResponse(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
                     contentType: String = "application/json", timeout: TimeInterval = 20) async throws -> RawResponse {
        if isLocalPlaceholder {
            throw APIError(status: 503, message: "Im Lokalmodus nicht verfügbar (kein Server).")
        }
        guard var comps = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        let token = try await tokenProvider(false)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var (data, response) = try await transport(req)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            // Token evtl. serverseitig widerrufen/abgelaufen → einmal erneuern und wiederholen
            let fresh = try await tokenProvider(true)
            req.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            (data, response) = try await transport(req)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError(status: 0, message: "Keine HTTP-Antwort")
        }
        let retry = (http.value(forHTTPHeaderField: "Retry-After")).flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
        return RawResponse(data: data, status: http.statusCode, retryAfter: retry)
    }

    private func raw(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async throws -> Data {
        try Self.check(try await rawResponse(method, path, query: query, body: body))
    }

    /// 2xx → Daten, sonst `APIError` mit Detailtext des Servers (`detail` als Text, sonst roher Body,
    /// damit strukturierte Details wie beim Monatsabschluss lesbar bleiben – siehe `APIError.detailObject`).
    static func check(_ response: RawResponse) throws -> Data {
        guard (200..<300).contains(response.status) else {
            let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]
            let detail = json?["detail"] as? String ?? String(data: response.data, encoding: .utf8) ?? ""
            throw APIError(status: response.status, message: detail, retryAfter: response.retryAfter)
        }
        return response.data
    }
}

// MARK: - Fehlertexte (U7)

extension Error {
    /// Verständlicher deutscher Text für Alerts/Inline-Hinweise. Nie roher Server-Body (HTML),
    /// Details des Servers nur als kurzer Text bzw. lesbar zusammengefasst (409-Listen).
    var userMessage: String { ErrorText.message(for: self) }
}

enum ErrorText {
    static func message(for error: Error) -> String {
        if let api = error as? APIError { return apiMessage(api) }
        if let url = error as? URLError { return urlMessage(url) }
        if error is DecodingError { return "Unerwartete Antwort vom Server – bitte App und Server aktualisieren." }
        if error is CancellationError { return "Abgebrochen." }
        return error.localizedDescription
    }

    static func urlMessage(_ e: URLError) -> String {
        switch e.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
             .callIsActive:
            return "Keine Internetverbindung – bitte später erneut versuchen."
        case .timedOut:
            return "Zeitüberschreitung – der Server antwortet nicht. Bitte später erneut versuchen."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "Server nicht erreichbar – Adresse prüfen oder später erneut versuchen."
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            return "Sichere Verbindung fehlgeschlagen – das Zertifikat des Servers ist ungültig."
        case .cancelled:
            return "Abgebrochen."
        case .badURL, .unsupportedURL:
            return "Ungültige Serveradresse."
        case .appTransportSecurityRequiresSecureConnection:
            return "Der Server muss per HTTPS erreichbar sein."
        default:
            return "Netzwerkfehler – bitte später erneut versuchen."
        }
    }

    static func apiMessage(_ e: APIError) -> String {
        let detail = readableDetail(e)
        switch e.status {
        case 0:
            return "Keine gültige Antwort vom Server."
        case 401:
            return "Sitzung abgelaufen – bitte neu anmelden."
        case 403:
            return "Keine Berechtigung für diese Aktion." + (detail.map { " (\($0))" } ?? "")
        case 404:
            return detail.map { "Nicht gefunden: \($0)" } ?? "Nicht gefunden – evtl. storniert oder nicht mehr vorhanden."
        case 409:
            return detail ?? "Konflikt mit dem Stand auf dem Server – bitte synchronisieren und erneut versuchen."
        case 413:
            return "Die Daten sind zu gross für den Server."
        case 415:
            return "Dateiformat vom Server nicht akzeptiert."
        case 422, 400:
            return detail ?? "Eingabe vom Server abgelehnt."
        case 429:
            if let s = e.retryAfter, s > 0, s < 3600 {
                return "Zu viele Anfragen – bitte kurz warten (ca. \(Int(s.rounded(.up))) s)."
            }
            return "Zu viele Anfragen – bitte kurz warten."
        case 500...599:
            return "Server vorübergehend nicht erreichbar – bitte später erneut versuchen."
        default:
            return detail.map { "Fehler \(e.status): \($0)" } ?? "Fehler \(e.status) vom Server."
        }
    }

    /// Detail des Servers, falls kurz und lesbar (Text) bzw. strukturiert (409: Meldung + Listen).
    static func readableDetail(_ e: APIError) -> String? {
        let raw = e.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if let data = raw.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) {
            return structuredDetail(obj)
        }
        return plainText(raw)
    }

    private static func plainText(_ s: String) -> String? {
        let lower = s.lowercased()
        if lower.hasPrefix("<") || lower.contains("<html") || lower.contains("<!doctype") || lower.contains("<body") {
            return nil
        }
        guard s.count <= 240 else { return nil }
        return s.replacingOccurrences(of: "\n", with: " ")
    }

    /// `{"detail": …}`, `{"message": …, "unconfirmed"/"trips": […], "gaps": […], "mismatches": […]}`
    /// oder FastAPI-Validierungsfehler (`[{"msg": …}]`).
    private static func structuredDetail(_ obj: Any) -> String? {
        if let dict = obj as? [String: Any] {
            if let detail = dict["detail"] {
                if let text = detail as? String { return plainText(text) }
                return structuredDetail(detail)
            }
            var parts: [String] = []
            if let m = dict["message"] as? String, let t = plainText(m) { parts.append(t) }
            let open = (dict["unconfirmed"] as? [Any]) ?? (dict["trips"] as? [Any])
            if let open, !open.isEmpty { parts.append("\(open.count) Fahrt(en) offen") }
            if let n = dict["unconfirmed"] as? Int, n > 0 { parts.append("\(n) Fahrt(en) offen") }
            if let gaps = dict["gaps"] as? [[String: Any]], !gaps.isEmpty {
                let km = gaps.compactMap { ($0["km"] as? NSNumber)?.intValue }.reduce(0, +)
                parts.append("\(gaps.count) km-Lücke(n), \(km) km")
            }
            if let mismatches = dict["mismatches"] as? [[String: Any]], !mismatches.isEmpty {
                let reasons = mismatches.compactMap { $0["reason"] as? String }
                let unique = Array(NSOrderedSet(array: reasons)) as? [String] ?? reasons
                var text = "\(mismatches.count) unvollständige Fahrt(en)"
                if !unique.isEmpty { text += ": " + unique.prefix(3).joined(separator: ", ") }
                parts.append(text)
            }
            return parts.isEmpty ? nil : parts.joined(separator: " – ")
        }
        if let list = obj as? [[String: Any]] {
            let messages = list.compactMap { $0["msg"] as? String }.compactMap(plainText)
            return messages.isEmpty ? nil : messages.prefix(2).joined(separator: "; ")
        }
        if let text = obj as? String { return plainText(text) }
        return nil
    }
}
