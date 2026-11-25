import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Security
import SwiftUI

struct AuthConfig: Decodable {
    let issuer: String
    let clientId: String
    let scopes: String
}

private struct OIDCDiscovery: Decodable {
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let revocationEndpoint: URL?
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int?
    let refreshToken: String?
}

enum AuthError: LocalizedError {
    case notLoggedIn
    case sessionExpired
    case callback(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: "Nicht angemeldet."
        case .sessionExpired: "Sitzung abgelaufen – bitte neu anmelden."
        case .callback(let m): "Anmeldung fehlgeschlagen: \(m)"
        case .server(let m): "Keycloak-Fehler: \(m)"
        }
    }
}

/// OIDC Authorization Code Flow mit PKCE (S256) gegen Keycloak.
/// Refresh-Token (offline_access) liegt in der Keychain, Access-Token nur im Speicher.
@MainActor
@Observable
final class AuthManager {
    static let callbackScheme = "net.jmb.fahrzeugbuch"
    static let redirectURI = "net.jmb.fahrzeugbuch:/oauth2redirect"

    private(set) var isLoggedIn: Bool
    private(set) var userName: String?

    @ObservationIgnored private var refreshToken: String?
    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var expiry = Date.distantPast
    @ObservationIgnored private var refreshTask: Task<String, Error>?
    @ObservationIgnored private var cache: (server: URL, config: AuthConfig, discovery: OIDCDiscovery)?

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init() {
        refreshToken = Keychain.get("refreshToken")
        isLoggedIn = refreshToken != nil
        userName = UserDefaults.standard.string(forKey: "userName")
    }

    // MARK: Öffentliche API

    func login(server: URL, session: WebAuthenticationSession) async throws {
        let (cfg, disc) = try await loadConfig(server)
        let verifier = Self.random(32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.random(16)

        var comps = URLComponents(url: disc.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: cfg.clientId),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: cfg.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        let callback = try await session.authenticate(using: comps.url!, callbackURLScheme: Self.callbackScheme)

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let err = item("error") {
            throw AuthError.callback(item("error_description") ?? err)
        }
        guard item("state") == state else { throw AuthError.callback("state stimmt nicht überein") }
        guard let code = item("code") else { throw AuthError.callback("kein Code erhalten") }

        let tokens = try await tokenRequest(disc.tokenEndpoint, [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": cfg.clientId,
            "code_verifier": verifier,
        ])
        store(tokens)
    }

    /// Gültiges Access-Token; erneuert bei Bedarf (parallele Aufrufe teilen sich einen Refresh).
    func validAccessToken(server: URL, forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let t = accessToken, expiry > Date().addingTimeInterval(30) { return t }
        if let running = refreshTask { return try await running.value }
        let task = Task { try await self.refresh(server: server) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    func logout(server: URL?) async {
        if let server, let rt = refreshToken,
           let loaded = try? await loadConfig(server),
           let revoke = loaded.1.revocationEndpoint {
            _ = try? await tokenRequest(revoke, [
                "token": rt, "token_type_hint": "refresh_token", "client_id": loaded.0.clientId,
            ])
        }
        clearSession()
    }

    func clearSession() {
        accessToken = nil
        expiry = .distantPast
        refreshToken = nil
        cache = nil
        Keychain.set("", for: "refreshToken")
        UserDefaults.standard.removeObject(forKey: "userName")
        userName = nil
        isLoggedIn = false
    }

    #if DEBUG
    func demoLogin(name: String) {
        userName = name
        isLoggedIn = true
    }
    #endif

    // MARK: Intern

    private func refresh(server: URL) async throws -> String {
        guard let rt = refreshToken else { throw AuthError.notLoggedIn }
        let (cfg, disc) = try await loadConfig(server)
        do {
            let tokens = try await tokenRequest(disc.tokenEndpoint, [
                "grant_type": "refresh_token", "refresh_token": rt, "client_id": cfg.clientId,
            ])
            store(tokens)
            return tokens.accessToken
        } catch AuthError.sessionExpired {
            clearSession()
            throw AuthError.sessionExpired
        }
    }

    private func store(_ tokens: TokenResponse) {
        accessToken = tokens.accessToken
        expiry = Date().addingTimeInterval(TimeInterval(tokens.expiresIn ?? 60))
        if let rt = tokens.refreshToken {
            refreshToken = rt
            Keychain.set(rt, for: "refreshToken")
        }
        if let name = Self.claim(tokens.accessToken, "preferred_username") ?? Self.claim(tokens.accessToken, "name") {
            userName = name
            UserDefaults.standard.set(name, forKey: "userName")
        }
        isLoggedIn = true
    }

    private func loadConfig(_ server: URL) async throws -> (AuthConfig, OIDCDiscovery) {
        if let c = cache, c.server == server { return (c.config, c.discovery) }
        let (cfgData, cfgResp) = try await URLSession.shared.data(from: server.appending(path: "auth/config"))
        guard (cfgResp as? HTTPURLResponse)?.statusCode == 200 else {
            throw AuthError.server("Server liefert keine OIDC-Konfiguration (/auth/config)")
        }
        let cfg = try Self.decoder.decode(AuthConfig.self, from: cfgData)
        guard let issuer = URL(string: cfg.issuer) else { throw AuthError.server("Ungültiger Issuer") }
        let (discData, _) = try await URLSession.shared.data(
            from: issuer.appending(path: ".well-known/openid-configuration"))
        let disc = try Self.decoder.decode(OIDCDiscovery.self, from: discData)
        cache = (server, cfg, disc)
        return (cfg, disc)
    }

    private func tokenRequest(_ url: URL, _ form: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if json?["error"] as? String == "invalid_grant" { throw AuthError.sessionExpired }
            throw AuthError.server(json?["error_description"] as? String ?? "HTTP \(status)")
        }
        // Revocation liefert leeren Body
        if data.isEmpty { return TokenResponse(accessToken: "", expiresIn: nil, refreshToken: nil) }
        return try Self.decoder.decode(TokenResponse.self, from: data)
    }

    private static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func random(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URL
    }

    private static func claim(_ jwt: String, _ key: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count > 1, let data = Data(base64URL: String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj[key] as? String
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}
