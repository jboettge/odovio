import AuthenticationServices
import Foundation
import Network
import SwiftUI
import Observation
import Security
import UserNotifications

@MainActor
@Observable
final class AppSettings {
    /// Jede Änderung der Server-URL meldet vollständig ab (Tokens, Sitzung, Issuer-Pin; I1) – Tokens sind
    /// zusätzlich an den Server gebunden (`TokenBinding`). Lokale Daten entfernt `changeServer(to:)`.
    var serverURL: String {
        didSet {
            guard persists else { return }   // Nachladen nach der ersten Entsperrung (Q6)
            UserDefaults.standard.set(serverURL, forKey: "serverURL")
            if TokenBinding.normalize(oldValue) != TokenBinding.normalize(serverURL) {
                auth.clearSession()
                auth.resetIssuerPin()
            }
        }
    }
    let auth = AuthManager()

    /// Betriebsart; `nil` = noch nicht gewählt (UI zeigt die Auswahl). Bestehende Installationen mit
    /// Server-URL gelten als `.server`.
    var mode: AppMode? {
        didSet { if persists { UserDefaults.standard.set(mode?.rawValue, forKey: Keys.mode) } }
    }

    /// Lokalmodus: Start/Ziel per Apple-Geocoding (nur Gemeinde/Strasse; Default aus)
    var useAppleGeocoding: Bool {
        didSet { if persists { UserDefaults.standard.set(useAppleGeocoding, forKey: Keys.appleGeocoding) } }
    }

    /// Hinweis nach einem Moduswechsel (z. B. verworfene ausstehende Änderungen)
    var modeNotice: String?

    /// Anzeigename des angemeldeten Benutzers (aus /api/me, neuere Server)
    private(set) var displayName: String?

    /// Start vor der ersten Entsperrung nach einem Neustart (Q6): Einstellungen und Anmeldung sind noch nicht
    /// lesbar. Die UI wartet (keine Betriebsart-Auswahl), nichts wird gespeichert; `finishFirstUnlock()` lädt nach.
    private(set) var awaitingFirstUnlock = false
    /// Werte werden gerade aus den UserDefaults übernommen (didSet schreibt nicht zurück)
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var unlockObserver: NSObjectProtocol?

    /// Änderungen speichern? Nicht während des Wartens auf die erste Entsperrung bzw. beim Nachladen.
    private var persists: Bool { !restoring && !awaitingFirstUnlock }

    private enum Keys {
        static let mode = "appMode"
        static let appleGeocoding = "useAppleGeocoding"
        static let displayName = "displayName"
    }

    var isLocal: Bool { mode == .local }

    /// Verfügbare Funktionen der aktuellen Betriebsart
    var capabilities: ModeCapabilities { .of(mode) }

    /// Mandanten des Benutzers (aus /api/me, offline aus Cache)
    private(set) var tenants: [TenantInfo] = []
    private(set) var tenantsLoaded = false
    private(set) var tenantError: String?
    private(set) var store: TenantStore?

    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        // Vor der ersten Entsperrung (Q6) liefern die UserDefaults nur Standardwerte → nichts ableiten/speichern
        let locked = FirstUnlock.isActive
        let defaults = UserDefaults.standard
        let storedURL = defaults.string(forKey: "serverURL") ?? ""
        serverURL = storedURL
        let storedMode = defaults.string(forKey: Keys.mode).flatMap(AppMode.init(rawValue:))
        let initialMode: AppMode? = storedMode ?? (storedURL.isEmpty ? nil : .server)   // bestehende Installation → Server
        mode = initialMode
        awaitingFirstUnlock = locked
        if !locked, storedMode == nil, let initialMode { defaults.set(initialMode.rawValue, forKey: Keys.mode) }
        useAppleGeocoding = defaults.bool(forKey: Keys.appleGeocoding)
        displayName = defaults.string(forKey: Keys.displayName)
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
        if Demo.isActive {
            Demo.setUp(self)
            return
        }
        #endif
        if locked {
            observeFirstUnlock()
            return
        }
        if initialMode == .local { openLocalStore() }
    }

    // MARK: Erste Entsperrung (Q6)

    private func observeFirstUnlock() {
        unlockObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishFirstUnlock() }
        }
    }

    /// Nach der ersten Entsperrung: Einstellungen, Mandanten-Cache und Anmeldung laden, danach Lokalmodus bzw.
    /// Fahrtenbuch (Automatik) neu einrichten. Ohne Wirkung, solange die Daten noch gesperrt sind.
    func finishFirstUnlock() {
        guard awaitingFirstUnlock, UIApplication.shared.isProtectedDataAvailable else { return }
        if let unlockObserver { NotificationCenter.default.removeObserver(unlockObserver) }
        unlockObserver = nil
        let defaults = UserDefaults.standard
        let storedURL = defaults.string(forKey: "serverURL") ?? ""
        let storedMode = defaults.string(forKey: Keys.mode).flatMap(AppMode.init(rawValue:))
        let initialMode: AppMode? = storedMode ?? (storedURL.isEmpty ? nil : .server)
        restoring = true
        serverURL = storedURL   // ohne Abmelden (didSet): gespeicherter Stand, keine Änderung
        mode = initialMode
        useAppleGeocoding = defaults.bool(forKey: Keys.appleGeocoding)
        restoring = false
        if storedMode == nil, let initialMode { defaults.set(initialMode.rawValue, forKey: Keys.mode) }
        displayName = defaults.string(forKey: Keys.displayName)
        if let data = defaults.data(forKey: "tenants"),
           let cached = try? JSONDecoder().decode([TenantInfo].self, from: data) {
            tenants = cached
        }
        auth.reloadAfterFirstUnlock()
        awaitingFirstUnlock = false
        if initialMode == .local { openLocalStore() }
        TripCoordinator.shared.reloadAfterFirstUnlock(settings: self)
    }

    #if DEBUG
    func demoTenants(_ list: [TenantInfo]) {
        if mode == nil { mode = .server }
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
            store?.flush()
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
        if isLocal { return .localPlaceholder }   // Lokalmodus: kein Server
        return serverAPI
    }

    /// API-Client des konfigurierten Servers unabhängig von der Betriebsart (Übertragung Lokal → Server).
    var serverAPI: APIClient {
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
        if isLocal {
            openLocalStore()
            return
        }
        do {
            let me: MeResponse = try await api.get("api/me")
            tenants = me.tenants
            tenantError = nil
            displayName = me.displayName?.nilIfEmpty ?? me.name?.nilIfEmpty
            UserDefaults.standard.set(displayName, forKey: Keys.displayName)
            UserDefaults.standard.set(try? JSONEncoder().encode(me.tenants), forKey: "tenants")
        } catch {
            if tenants.isEmpty { tenantError = error.userMessage }
        }
        tenantsLoaded = true
        let chosen = currentTenantSlug.flatMap { s in tenants.first { $0.slug == s } } ?? tenants.first
        if let chosen { selectTenant(chosen) } else { store = nil }
    }

    func selectTenant(_ t: TenantInfo) {
        if isLocal { return }   // Lokalmodus: nur das lokale Fahrzeugbuch
        if store?.tenant == t && store?.isLocal == false { return }
        store?.flush()   // Mandantenwechsel: ausstehende Änderungen des bisherigen Mandanten sofort sichern (Q14)
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
        await auth.logout(server: isConfigured ? baseURL : nil)
        resetLocalData()
    }

    /// Serverwechsel: Abmelden inkl. Token-Widerruf beim bisherigen Server, Issuer-Pin entfernen,
    /// lokale Daten löschen, neue URL setzen (danach Anmeldung am neuen Server).
    func changeServer(to url: String) async {
        let new = url.trimmed
        if auth.isLoggedIn {
            await auth.logout(server: isConfigured ? baseURL : nil)
        } else {
            auth.clearSession()
        }
        auth.resetIssuerPin()
        resetLocalData()
        serverURL = new
    }

    /// Alle lokalen Daten entfernen: Mandantendateien, Belege, Tracks, Exporte (PDF/CSV),
    /// geplante/zugestellte Mitteilungen, URL-Cache und Cookies.
    func resetLocalData() {
        TripCoordinator.shared.resetLocalData()   // laufende Aufzeichnung verwerfen, Tracks löschen
        CrashReporter.deleteAll()   // Absturzberichte gehören zum Gerätezustand des bisherigen Benutzers (I5)
        store = nil
        tenants = []
        tenantsLoaded = false
        for key in ["tenants", "tenant", "dataOwnerSub", "checklistTemplates", Keys.displayName] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        displayName = nil
        let localKey = "defaultVehicle-\(LocalIdentity.slug)"   // lokales Fahrzeugbuch bleibt unberührt
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where key.hasPrefix("defaultVehicle-") && key != localKey {
            UserDefaults.standard.removeObject(forKey: key)
        }
        TenantStore.deleteAll()
        Self.cleanupExports(olderThan: 0)
        URLCache.shared.removeAllCachedResponses()
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()   // Fälligkeiten, Fahrt-Mitteilungen, Wochenerinnerung
        center.removeAllDeliveredNotifications()
        AppRouter.shared.pending = nil
        if isLocal { openLocalStore() }   // lokale Daten sind nicht betroffen
    }

    // MARK: Betriebsart

    /// Lokalmodus starten: lokales Fahrzeugbuch öffnen (ohne Server, ohne Login).
    func startLocal() {
        if let s = store, !s.isLocal { s.flush() }
        mode = .local
        openLocalStore()
    }

    /// Servermodus wählen (weiter mit dem bestehenden Server-Flow: Server-URL, Anmeldung, Mandant).
    /// Lokale Daten bleiben erhalten (für `migrateLocalToServer`).
    func chooseServer() {
        if let s = store, s.isLocal {
            s.flush()
            store = nil
        }
        mode = .server
        restoreCachedTenants()
        if isConfigured && auth.isLoggedIn {
            Task { await loadTenants() }
        }
    }

    /// Zurück zur Auswahl der Betriebsart. Daten (lokal und Server-Kopie) bleiben, bis sie gelöscht werden.
    func resetMode() {
        store?.flush()
        store = nil
        mode = nil
        restoreCachedTenants()
    }

    /// Lokale Daten (Lokalmodus) vorhanden – z. B. für den Wechsel zum Server.
    var hasLocalData: Bool { TenantStore.hasLocalData() }

    /// Lokale Daten endgültig löschen (nach der Übertragung auf den Server oder auf Wunsch).
    func deleteLocalData() {
        if let s = store, s.isLocal { store = nil }
        TenantStore.deleteLocalData()
        UserDefaults.standard.removeObject(forKey: "defaultVehicle-\(LocalIdentity.slug)")
        if isLocal { openLocalStore() }
    }

    /// Ausstehende Änderungen des Server-Mandanten (Warnung vor `switchToLocal`).
    var pendingServerChanges: Int {
        guard let s = store, !s.isLocal else { return 0 }
        return s.outbox.count + s.pendingBlobs.count
    }

    /// Link ins Webfrontend (Server-URL + Pfad), nur im Servermodus mit konfiguriertem Server.
    /// Beispiel: `webURL(path: "t/firma/settings/tax")`.
    func webURL(path: String) -> URL? {
        guard mode == .server, isConfigured else { return nil }
        var base = serverURL.trimmed
        while base.hasSuffix("/") { base.removeLast() }
        var clean = path.trimmed
        while clean.hasPrefix("/") { clean.removeFirst() }
        return URL(string: clean.isEmpty ? base + "/" : base + "/" + clean)
    }

    /// Wechsel Lokal → Server nach der Anmeldung: alle lokalen Objekte mit gleichen IDs in den Server-Mandanten
    /// `target` übertragen (Abhängigkeitsreihenfolge; gesperrte Fahrten als „bestätigt“, Belege als Datei-Upload)
    /// und synchronisieren. Die Betriebsart bleibt bis zum Ende unverändert: erst nach erfolgreicher Übernahme
    /// wechselt die App in den Servermodus (Mandant `target` geöffnet). Schlägt der erste Abgleich mit dem Server
    /// fehl, wird nichts übertragen und der Fehler geworfen. Lokale Daten bleiben als Sicherung, bis
    /// `deleteLocalData()` aufgerufen wird.
    func migrateLocalToServer(target: TenantInfo) async throws -> MigrationReport {
        guard isConfigured, auth.isLoggedIn else { throw AuthError.notLoggedIn }
        guard target.canWrite else {
            throw APIError(status: 403, message: "Keine Schreibberechtigung für Mandant «\(target.slug)».")
        }
        guard TenantStore.hasLocalData() else {
            throw APIError(status: 404, message: "Keine lokalen Daten vorhanden.")
        }
        let local: TenantStore
        if let s = store, s.isLocal {
            local = s
        } else {
            local = TenantStore(localDirectory: nil)
        }
        local.flush()
        let provider: @MainActor () -> APIClient = { [weak self] in
            self?.serverAPI ?? APIClient(baseURL: URL(string: "http://localhost")!) { _ in throw AuthError.notLoggedIn }
        }
        let server = TenantStore(tenant: target, api: provider)
        server.autoSyncEnabled = false
        await Self.completeSync(server)   // aktuellen Server-Stand holen
        if server.lastSync == nil {
            throw APIError(status: 503, message: server.syncError ?? "Server nicht erreichbar.")
        }
        var report = LocalMigration.enqueue(from: local, into: server)
        await Self.completeSync(server)
        LocalMigration.finish(&report, server: server, ids: LocalMigration.ids(local.contentSnapshot()))
        server.autoSyncEnabled = true

        // Erst jetzt umschalten: Servermodus mit dem Zielmandanten
        if let me: MeResponse = try? await serverAPI.get("api/me") {
            tenants = me.tenants
            displayName = me.displayName?.nilIfEmpty ?? me.name?.nilIfEmpty
            UserDefaults.standard.set(displayName, forKey: Keys.displayName)
            UserDefaults.standard.set(try? JSONEncoder().encode(me.tenants), forKey: "tenants")
            if UserDefaults.standard.string(forKey: "dataOwnerSub") == nil {
                UserDefaults.standard.set(me.sub, forKey: "dataOwnerSub")
            }
        }
        if !tenants.contains(where: { $0.slug == target.slug }) { tenants = [target] + tenants.filter { !$0.isLocal } }
        tenantsLoaded = true
        tenantError = nil
        currentTenantSlug = target.slug
        mode = .server
        store = server
        return report
    }

    /// Wechsel Server → Lokal: optional den aktuellen Stand des geöffneten Mandanten als lokale Daten übernehmen
    /// (ohne Outbox; Hinweis bei ausstehenden Änderungen in `modeNotice`), danach abmelden.
    func switchToLocal(copyCurrent: Bool) async {
        var notes: [String] = []
        if copyCurrent, let server = store, !server.isLocal {
            let local = TenantStore(localDirectory: nil)
            do {
                notes += try LocalMigration.copyServerState(server, into: local)
            } catch {
                modeNotice = "Übernahme der Daten fehlgeschlagen: \(error.localizedDescription)"
                return
            }
        }
        if auth.isLoggedIn || store != nil {
            await logout()
        }
        mode = .local
        openLocalStore()
        modeNotice = notes.isEmpty ? nil : notes.joined(separator: "\n")
    }

    /// Sicherung einspielen (nur Lokalmodus).
    @discardableResult
    func importBackup(from url: URL) throws -> BackupSummary {
        guard isLocal else { throw BackupError.notLocal }
        openLocalStore()
        guard let s = store, s.isLocal else { throw BackupError.notLocal }
        return try LocalBackup.importBackup(from: url, into: s)
    }

    private func openLocalStore() {
        if let s = store, s.isLocal { return }
        store?.flush()
        tenants = [.local]
        tenantsLoaded = true
        tenantError = nil
        store = TenantStore(localDirectory: nil)
    }

    private func restoreCachedTenants() {
        if let data = UserDefaults.standard.data(forKey: "tenants"),
           let cached = try? JSONDecoder().decode([TenantInfo].self, from: data) {
            tenants = cached
        } else {
            tenants = []
        }
        tenantsLoaded = false
    }

    /// Sync ausführen und warten, bis auch ein bereits laufender Sync fertig ist (max. ~2 min).
    private static func completeSync(_ s: TenantStore) async {
        await s.sync()
        var waited = 0
        while s.isSyncing && waited < 600 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            waited += 1
        }
        if !s.outbox.isEmpty && s.syncError == nil { await s.sync() }
    }

    /// Exportierte Dateien (PDF, CSV …, Präfix `Fahrzeugbuch_`) im temporären Verzeichnis entfernen.
    static func cleanupExports(olderThan seconds: TimeInterval) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files where url.lastPathComponent.hasPrefix("Fahrzeugbuch_") {
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

    /// Wert setzen (leer = löschen). Rückgabe: gespeichert bzw. gelöscht (Q14). Ein bestehender Eintrag wird
    /// aktualisiert statt zuerst gelöscht – schlägt das Schreiben fehl, bleibt der bisherige Wert erhalten.
    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        guard !value.isEmpty else {
            let status = SecItemDelete(query(key) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        // Nur dieses Gerät: Token wandert nicht in Backups/auf andere Geräte
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let updated = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var add = query(key)
        for (k, v) in attributes { add[k] = v }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
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

    /// UserDefaults-Marker: App wurde auf diesem Gerät schon gestartet (fehlt nach einer Neuinstallation).
    static let installMarkerKey = "keychainInstallMarker"

    /// Keychain-Einträge überleben das Löschen der App. Beim ersten Start nach einer (Neu-)Installation alle
    /// Einträge der App entfernen (I1: kein Refresh-Token einer früheren Installation/eines früheren Servers).
    /// Nur bei entsperrtem Gerät: vor der ersten Entsperrung sind UserDefaults nicht lesbar (Marker fehlte
    /// scheinbar) – dann beim nächsten Start.
    @MainActor
    static func removeAllAfterFreshInstall() {
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: installMarkerKey) else { return }
        SecItemDelete([kSecClass as String: kSecClassGenericPassword] as CFDictionary)
        defaults.set(true, forKey: installMarkerKey)
    }
}


extension LocalBackup {
    /// Sicherung in die lokalen Daten einspielen (nur Lokalmodus; ersetzt den lokalen Bestand).
    @discardableResult
    static func importBackup(from url: URL, into settings: AppSettings) throws -> BackupSummary {
        try settings.importBackup(from: url)
    }
}
