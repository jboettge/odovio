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
    /// Client-ID des Webfrontends (neuere Server; von der App nicht verwendet)
    let webClientId: String?
}

private struct OIDCDiscovery: Decodable {
    let issuer: String
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
    /// Der Server meldet einen anderen Anmeldeserver als beim ersten Login (Pin). Ausweg:
    /// `AuthManager.resetIssuerPin()` („Anmeldeserver zurücksetzen“) und neu anmelden.
    case issuerChanged(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: "Nicht angemeldet."
        case .sessionExpired: "Sitzung abgelaufen – bitte neu anmelden."
        case .callback(let m): "Anmeldung fehlgeschlagen: \(m)"
        case .server(let m): "Anmeldeserver-Fehler: \(m)"
        case .issuerChanged(let issuer):
            "Der Anmeldeserver hat sich geändert (\(issuer)). Wenn das beabsichtigt ist: "
                + "„Anmeldeserver zurücksetzen“ wählen und neu anmelden."
        }
    }
}

/// Bindung der Anmeldung an Server und Anmeldeserver (I1): Access-/Refresh-Token gelten nur für den Server,
/// an dem angemeldet wurde, und den Issuer/Client, den dieser damals meldete. Token eines anderen Servers werden
/// nie verwendet oder gesendet (Schutz vor manipulierten Einrichtungslinks).
struct TokenBinding: Codable, Equatable {
    /// Normalisierte Server-URL (`normalize`)
    var server: String
    var issuer: String
    var clientId: String

    /// Vergleichsform einer Server-URL: Schema/Host klein, ohne abschliessende «/». Port und Pfad bleiben.
    static func normalize(_ server: String) -> String {
        var text = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard var comps = URLComponents(string: text), comps.host != nil else { return text.lowercased() }
        comps.scheme = comps.scheme?.lowercased()
        comps.host = comps.host?.lowercased()
        while comps.path.hasSuffix("/") { comps.path.removeLast() }
        return comps.string ?? text
    }

    static func normalize(_ server: URL) -> String { normalize(server.absoluteString) }

    /// Darf ein Token dieser Anmeldung an `server` gehen?
    func allows(server other: URL) -> Bool {
        server == Self.normalize(other)
    }

    /// Meldet der Server (noch) denselben Anmeldeserver?
    func allows(issuer otherIssuer: String, clientId otherClient: String) -> Bool {
        issuer == otherIssuer && clientId == otherClient
    }
}

/// OIDC Authorization Code Flow mit PKCE (S256) gegen Keycloak.
/// Refresh-Token (offline_access) liegt in der Keychain, Access-Token nur im Speicher; beide sind an Server
/// und Issuer gebunden (`TokenBinding`, Keychain-Eintrag `tokenBinding`).
@MainActor
@Observable
final class AuthManager {
    static let callbackScheme = "ch.odovio"
    static let redirectURI = "ch.odovio:/oauth2redirect"

    private(set) var isLoggedIn: Bool
    private(set) var userName: String?

    @ObservationIgnored private var refreshToken: String?
    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var binding: TokenBinding?
    @ObservationIgnored private var expiry = Date.distantPast
    @ObservationIgnored private var refreshTask: Task<String, Error>?
    @ObservationIgnored private var cache: (server: URL, config: AuthConfig, discovery: OIDCDiscovery)?

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init() {
        Keychain.removeAllAfterFreshInstall()
        var token = Keychain.get("refreshToken")
        let stored = Keychain.get(AuthManager.bindingKey).flatMap { try? JSONDecoder().decode(TokenBinding.self, from: Data($0.utf8)) }
        if token != nil && stored == nil {
            // Token älterer Versionen ohne Bindung: Server unbekannt → nicht verwenden, neu anmelden (I1)
            Keychain.set("", for: "refreshToken")
            token = nil
        }
        refreshToken = token
        binding = token == nil ? nil : stored
        isLoggedIn = token != nil
        userName = token == nil ? nil : UserDefaults.standard.string(forKey: "userName")
    }

    // MARK: Öffentliche API

    /// Meldet an und liefert die `sub` des Benutzers.
    @discardableResult
    func login(server: URL, session: WebAuthenticationSession) async throws -> String {
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
        // Ephemer: kein geteiltes Safari-SSO-Cookie → auf geteilten Geräten kein Login ohne Passwort
        let callback = try await session.authenticate(using: comps.url!, callbackURLScheme: Self.callbackScheme,
                                                      preferredBrowserSession: .ephemeral)

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
        let newBinding = TokenBinding(server: TokenBinding.normalize(server), issuer: cfg.issuer, clientId: cfg.clientId)
        binding = newBinding
        if let data = try? JSONEncoder().encode(newBinding), let text = String(data: data, encoding: .utf8) {
            Keychain.set(text, for: Self.bindingKey)
        }
        store(tokens)
        UserDefaults.standard.set(cfg.issuer, forKey: Self.pinnedIssuerKey)
        UserDefaults.standard.set(cfg.clientId, forKey: Self.pinnedClientKey)
        guard let sub = Self.claim(tokens.accessToken, "sub") else { throw AuthError.callback("Token ohne sub") }
        return sub
    }

    /// Gültiges Access-Token für `server`; erneuert bei Bedarf (parallele Aufrufe teilen sich einen Refresh).
    /// Nur für den Server, an dem angemeldet wurde – sonst `notLoggedIn`, ohne ein Token zu senden (I1).
    func validAccessToken(server: URL, forceRefresh: Bool = false) async throws -> String {
        guard let binding, binding.allows(server: server) else { throw AuthError.notLoggedIn }
        if !forceRefresh, let t = accessToken, expiry > Date().addingTimeInterval(30) { return t }
        if let running = refreshTask { return try await running.value }
        let task = Task { try await self.refresh(server: server) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    /// Explizites Abmelden: Tokens widerrufen, Issuer-Pin lösen.
    func logout(server: URL?) async {
        // Widerruf nur beim eigenen Anmeldeserver (nie das Token an einen anderen Server senden)
        if let server, let rt = refreshToken, let binding, binding.allows(server: server),
           let loaded = try? await loadConfig(server),
           binding.allows(issuer: loaded.0.issuer, clientId: loaded.0.clientId),
           let revoke = loaded.1.revocationEndpoint {
            _ = try? await tokenRequest(revoke, [
                "token": rt, "token_type_hint": "refresh_token", "client_id": loaded.0.clientId,
            ])
        }
        clearSession()
        resetIssuerPin()
    }

    /// Issuer-Pin lösen (z. B. „Anmeldeserver zurücksetzen“ im Login nach einem Realm-/Serverwechsel).
    /// Danach akzeptiert die nächste Anmeldung den Issuer, den der Server meldet.
    func resetIssuerPin() {
        UserDefaults.standard.removeObject(forKey: Self.pinnedIssuerKey)
        UserDefaults.standard.removeObject(forKey: Self.pinnedClientKey)
        cache = nil
    }

    /// Ein Issuer ist gepinnt (für den Hinweis „Anmeldeserver zurücksetzen“).
    var hasPinnedIssuer: Bool { UserDefaults.standard.string(forKey: Self.pinnedIssuerKey) != nil }

    func clearSession() {
        accessToken = nil
        expiry = .distantPast
        refreshToken = nil
        binding = nil
        cache = nil
        Keychain.set("", for: "refreshToken")
        Keychain.set("", for: Self.bindingKey)
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
        guard let rt = refreshToken, let binding, binding.allows(server: server) else { throw AuthError.notLoggedIn }
        let (cfg, disc) = try await loadConfig(server)
        // Meldet der Server einen anderen Anmeldeserver, geht das Refresh-Token nicht dorthin
        guard binding.allows(issuer: cfg.issuer, clientId: cfg.clientId) else { throw AuthError.issuerChanged(cfg.issuer) }
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

    /// Lädt Issuer/Client vom Server und die Discovery vom Issuer – mit Prüfungen gegen
    /// manipulierte Antworten: nur HTTPS, Issuer gepinnt (nach erstem Login), Endpoints auf dem Issuer-Host.
    private func loadConfig(_ server: URL) async throws -> (AuthConfig, OIDCDiscovery) {
        if let c = cache, c.server == server { return (c.config, c.discovery) }
        guard Self.isSecure(server) else { throw AuthError.server("Server muss per HTTPS erreichbar sein") }
        let (cfgData, cfgResp) = try await APIClient.session.data(from: server.appending(path: "auth/config"))
        guard (cfgResp as? HTTPURLResponse)?.statusCode == 200 else {
            throw AuthError.server("Server liefert keine OIDC-Konfiguration (/auth/config)")
        }
        let cfg = try Self.decoder.decode(AuthConfig.self, from: cfgData)
        guard let issuer = URL(string: cfg.issuer), Self.isSecure(issuer), let issuerHost = issuer.host else {
            throw AuthError.server("Ungültiger oder unsicherer Issuer")
        }
        let defaults = UserDefaults.standard
        if let pinned = defaults.string(forKey: Self.pinnedIssuerKey),
           pinned != cfg.issuer || defaults.string(forKey: Self.pinnedClientKey) != cfg.clientId {
            throw AuthError.issuerChanged(cfg.issuer)
        }
        let (discData, _) = try await APIClient.session.data(
            from: issuer.appending(path: ".well-known/openid-configuration"))
        let disc = try Self.decoder.decode(OIDCDiscovery.self, from: discData)
        let endpoints = [disc.authorizationEndpoint, disc.tokenEndpoint] + [disc.revocationEndpoint].compactMap { $0 }
        guard disc.issuer == cfg.issuer,
              endpoints.allSatisfy({ Self.isSecure($0) && $0.host == issuerHost }) else {
            throw AuthError.server("OIDC-Discovery passt nicht zum Issuer")
        }
        cache = (server, cfg, disc)
        return (cfg, disc)
    }

    static let pinnedIssuerKey = "pinnedIssuer"
    static let pinnedClientKey = "pinnedClientId"
    /// Keychain: `TokenBinding` als JSON
    static let bindingKey = "tokenBinding"

    /// HTTPS Pflicht; Debug-Builds erlauben zusätzlich http://localhost (Simulator/Entwicklung).
    nonisolated static func isSecure(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https" { return url.host != nil }
        #if DEBUG
        return url.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1"].contains(url.host ?? "")
        #else
        return false
        #endif
    }

    private func tokenRequest(_ url: URL, _ form: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await APIClient.session.data(for: req)
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
