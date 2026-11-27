import SwiftUI

@main
@MainActor
struct FahrzeugbuchApp: App {
    /// Quick Actions / Mitteilungen → `AppRouter.shared.pending`
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var settings: AppSettings
    @State private var pendingServer: String?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let initial = AppSettings()
        _settings = State(initialValue: initial)
        // Früh konfigurieren: Start im Hintergrund durch Standort-Ereignisse/Kurzbefehl (Demo: nur Anzeige)
        TripCoordinator.shared.configure(settings: initial)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(TripCoordinator.shared)
                .onChange(of: settings.store?.tenant.slug) { _, _ in
                    TripCoordinator.shared.configure(settings: settings)   // Mandantenwechsel
                }
                .alert("Hinweis", isPresented: Binding(
                    get: { settings.loginNotice != nil },
                    set: { if !$0 { settings.loginNotice = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(settings.loginNotice ?? "")
                }
                // Hinweis nach einem Wechsel der Betriebsart (z. B. Übernahme der Daten)
                .alert("Betriebsart", isPresented: Binding(
                    get: { settings.modeNotice != nil },
                    set: { if !$0 { settings.modeNotice = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(settings.modeNotice ?? "")
                }
                // Einrichtungslink fahrzeugbuch://setup?server=https://… (Schema in project.yml registrieren)
                // Ein Link wechselt den Server nie ohne Rückfrage (I1) – Host im Titel deutlich sichtbar
                .onOpenURL { url in handleOpenURL(url) }
                .alert(serverAlertTitle, isPresented: Binding(
                    get: { pendingServer != nil },
                    set: { if !$0 { pendingServer = nil } }), presenting: pendingServer) { server in
                    Button("Abbrechen", role: .cancel) {}
                    Button(acceptTitle, role: .destructive) {
                        Task { await acceptServer(server) }
                    }
                } message: { server in
                    Text(serverChangeText(server))
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await settings.store?.sync() } }
        }
    }
}

extension FahrzeugbuchApp {
    private var acceptTitle: String {
        settings.serverURL.trimmed.isEmpty ? "Server übernehmen" : "Wechseln"
    }

    private var serverAlertTitle: String {
        guard let server = pendingServer else { return "Server übernehmen?" }
        return "Server «\(ServerLink.host(server))» übernehmen?"
    }

    private func serverChangeText(_ server: String) -> String {
        var text = "Adresse: \(server)\n\n"
        let current = settings.serverURL.trimmed
        if current.isEmpty {
            text += "Die App verbindet sich mit diesem Server; die Anmeldung erfolgt dort. Nur bestätigen, wenn du "
                + "den Link vom Betreiber deines Fahrzeugbuchs erhalten hast."
        } else {
            text += "Bisher: \(ServerLink.host(current)). Du wirst abgemeldet und die lokalen Daten des bisherigen "
                + "Servers werden vom Gerät entfernt."
            let n = TenantStore.pendingCountOnDisk()
            if n > 0 { text += " Achtung: \(n) Änderung(en) sind noch nicht synchronisiert und gehen verloren." }
        }
        return text
    }

    /// Bestätigter Einrichtungslink: abmelden, Daten des bisherigen Servers entfernen, neuen Server setzen
    /// und (falls noch nicht gewählt) die Betriebsart «Mit Server» wählen.
    private func acceptServer(_ server: String) async {
        await settings.changeServer(to: server)
        if settings.mode != .server { settings.chooseServer() }
    }

    private func handleOpenURL(_ url: URL) {
        guard ServerLink.isSetupLink(url) else { return }
        switch ServerLink.setupDecision(link: url, mode: settings.mode, currentServer: settings.serverURL) {
        case .invalid:
            settings.loginNotice = "Der Einrichtungslink enthält keine gültige HTTPS-Serveradresse."
        case .suggestForTransfer(let server):
            // Lokalmodus: nichts umstellen, Server im Übertragungs-Assistenten vorbelegen
            ModeUIState.shared.suggestedServer = server
            settings.loginNotice = "Die App läuft «Nur auf diesem iPhone». Um deine Daten auf \(ServerLink.host(server)) "
                + "zu übertragen: Einstellungen › Betriebsart › Auf Server übertragen …"
        case .alreadyConfigured:
            if settings.mode == nil {
                settings.chooseServer()   // bekannter Server: nur Betriebsart wieder wählen
            } else {
                settings.loginNotice = "Dieser Server ist bereits eingerichtet."
            }
        case .confirm(let server, _, _):
            pendingServer = server
        }
    }
}

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @State private var ui = ModeUIState.shared

    var body: some View {
        Group {
            #if DEBUG
            if Demo.isActive {
                DemoScreen()
            } else {
                content
            }
            #else
            content
            #endif
        }
        // Bericht einer Übertragung Lokal → Server (die Ansichten wurden beim Wechsel neu aufgebaut)
        .sheet(item: $ui.presentReport) { result in
            ModalNavigation { MigrationReportView(result: result) }
        }
    }

    /// Betriebsart: nicht gewählt → Auswahl; lokal → direkt die Fahrzeugliste; Server → Einrichtung/Anmeldung.
    @ViewBuilder
    private var content: some View {
        if settings.mode == nil {
            ModeChoiceView()
        } else if settings.isLocal {
            localContent
        } else {
            serverContent
        }
    }

    @ViewBuilder
    private var localContent: some View {
        if let store = settings.store {
            VehicleListView()
                .environment(store)
                .id(store.tenant.slug)
        } else {
            ProgressView("Lade lokale Daten …")
                .task { settings.startLocal() }
        }
    }

    @ViewBuilder
    private var serverContent: some View {
        if !settings.isConfigured {
            NavigationStack { SettingsView() }
        } else if !settings.auth.isLoggedIn {
            LoginView()
        } else if let store = settings.store {
            VehicleListView()
                .environment(store)
                .id(store.tenant.slug)   // Mandantenwechsel → Ansicht neu aufbauen
        } else if settings.tenantsLoaded {
            NavigationStack {
                ContentUnavailableView {
                    Label("Kein Fahrzeugbuch", systemImage: "person.2.slash")
                } description: {
                    Text(settings.tenantError ?? "Dein Konto hat noch keinen Zugriff auf ein Fahrzeugbuch. "
                         + "Bitte den Betreiber um Freigabe bitten (technisch: Gruppe /fahrzeugbuch/<name>).")
                } actions: {
                    Button("Erneut versuchen") { Task { await settings.loadTenants() } }
                }
                .toolbar {
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Einstellungen")
                }
            }
        } else {
            ProgressView("Lade Fahrzeugbücher …")
                .task { await settings.loadTenants() }
        }
    }
}
