import AuthenticationServices
import Foundation
import Network
import SwiftUI
import Observation
import Security

@MainActor
@Observable
final class AppSettings {
    var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }
    let auth = AuthManager()

    /// Mandanten des Benutzers (aus /api/me, offline aus Cache)
    private(set) var tenants: [TenantInfo] = []
    private(set) var tenantsLoaded = false
    private(set) var tenantError: String?
    private(set) var store: TenantStore?

    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        if let data = UserDefaults.standard.data(forKey: "tenants"),
           let cached = try? JSONDecoder().decode([TenantInfo].self, from: data) {
            tenants = cached
        }
        // Verbindung wieder da → ausstehende Änderungen übertragen
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await self?.store?.sync() }
        }
        monitor.start(queue: DispatchQueue(label: "fahrzeugbuch.network"))
        Self.cleanupExports(olderThan: 3600)
        #if DEBUG
        if Demo.isActive { Demo.setUp(self) }
        #endif
    }

    #if DEBUG
    func demoTenants(_ list: [TenantInfo]) {
        tenants = list
        tenantsLoaded = true
        let s = TenantStore(tenant: list[0], api: { APIClient(baseURL: URL(string: "http://localhost")!) { _ in
            throw AuthError.notLoggedIn } })
        Demo.seed(s)
        store = s
    }
    #endif

    var isConfigured: Bool { URL(string: serverURL).map(AuthManager.isSecure) ?? false }

    /// Hinweis nach dem Login (z. B. verworfene Daten eines anderen Benutzers)
    var loginNotice: String?

    /// Login inkl. Schutz geteilter Geräte: gehören die lokalen Daten einem anderen Benutzer,
    /// werden sie verworfen, bevor irgendetwas unter der neuen Identität synchronisiert wird.
    func login(session: WebAuthenticationSession) async throws {
        let sub = try await auth.login(server: baseURL, session: session)
        let owner = UserDefaults.standard.string(forKey: "dataOwnerSub")
        if let owner, owner != sub {
            let pending = TenantStore.pendingCountOnDisk()
            resetLocalData()
            loginNotice = "Lokale Daten des vorherigen Benutzers wurden vom Gerät entfernt"
                + (pending > 0 ? " (\(pending) nicht synchronisierte Änderung(en) verworfen)." : ".")
        }
        UserDefaults.standard.set(sub, forKey: "dataOwnerSub")
        await loadTenants()   // Rollen/Mandanten nach jedem Login neu laden
    }

    var baseURL: URL { URL(string: serverURL) ?? URL(string: "http://localhost")! }

    var api: APIClient {
        let url = baseURL
        let auth = auth
        return APIClient(baseURL: url) { force in
            try await auth.validAccessToken(server: url, forceRefresh: force)
        }
    }

    var currentTenantSlug: String? {
        get { UserDefaults.standard.string(forKey: "tenant") }
        set { UserDefaults.standard.set(newValue, forKey: "tenant") }
    }

    /// Mandanten laden (online) bzw. Cache verwenden (offline) und Store öffnen.
    func loadTenants() async {
        do {
            let me: MeResponse = try await api.get("api/me")
            tenants = me.tenants
            tenantError = nil
            UserDefaults.standard.set(try? JSONEncoder().encode(me.tenants), forKey: "tenants")
        } catch {
            if tenants.isEmpty { tenantError = error.localizedDescription }
        }
        tenantsLoaded = true
        let chosen = currentTenantSlug.flatMap { s in tenants.first { $0.slug == s } } ?? tenants.first
        if let chosen { selectTenant(chosen) } else { store = nil }
    }

    func selectTenant(_ t: TenantInfo) {
        if store?.tenant == t { return }
        currentTenantSlug = t.slug
        let provider: @MainActor () -> APIClient = { [weak self] in
            self?.api ?? APIClient(baseURL: URL(string: "http://localhost")!) { _ in throw AuthError.notLoggedIn }
        }
        store = TenantStore(tenant: t, api: provider)
        #if DEBUG
        if Demo.isActive { Demo.seed(store!); return }
        #endif
        Task { await store?.sync() }
    }

    /// Abmelden: Tokens widerrufen und lokale Daten entfernen.
    func logout() async {
        await auth.logout(server: baseURL)
        resetLocalData()
    }

    func resetLocalData() {
        TripCoordinator.shared.resetLocalData()   // laufende Aufzeichnung verwerfen, Tracks löschen
        store = nil
        tenants = []
        tenantsLoaded = false
        for key in ["tenants", "tenant", "dataOwnerSub", "checklistTemplates"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        TenantStore.deleteAll()
        Self.cleanupExports(olderThan: 0)
    }

    /// Exportierte PDFs im temporären Verzeichnis entfernen.
    static func cleanupExports(olderThan seconds: TimeInterval) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files where url.lastPathComponent.hasPrefix("Fahrzeugbuch_") && url.pathExtension == "pdf" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if seconds == 0 || (date.map { Date().timeIntervalSince($0) > seconds } ?? true) {
                try? fm.removeItem(at: url)
            }
        }
    }
}

enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "fahrzeugbuch",
         kSecAttrAccount as String: key]
    }

    static func set(_ value: String, for key: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query(key)
        add[kSecValueData as String] = Data(value.utf8)
        // Nur dieses Gerät: Token wandert nicht in Backups/auf andere Geräte
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
