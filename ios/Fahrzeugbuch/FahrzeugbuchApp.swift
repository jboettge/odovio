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
                .onOpenURL { url in handleOpenURL(url) }
                .alert("Server übernehmen?", isPresented: Binding(
                    get: { pendingServer != nil },
                    set: { if !$0 { pendingServer = nil } }), presenting: pendingServer) { server in
                    Button("Abbrechen", role: .cancel) {}
                    Button("Wechseln", role: .destructive) {
                        Task { await settings.changeServer(to: server) }
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
    private func serverChangeText(_ server: String) -> String {
        let target = ServerLink.host(server)
        let n = TenantStore.pendingCountOnDisk()
        var text = "Neuer Server: \(target). Du wirst abgemeldet und die lokalen Daten werden vom Gerät entfernt."
        if n > 0 { text += " Achtung: \(n) Änderung(en) sind noch nicht synchronisiert und gehen verloren." }
        return text
    }

    private func handleOpenURL(_ url: URL) {
        guard ServerLink.isSetupLink(url) else { return }
        guard let server = ServerLink.serverURL(from: url.absoluteString) else {
            settings.loginNotice = "Der Einrichtungslink enthält keine gültige HTTPS-Serveradresse."
            return
        }
        if settings.mode == nil {
            // Noch keine Betriebsart gewählt: Link bedeutet „Mit Server“
            settings.chooseServer()
            settings.serverURL = server
            return
        }
        if settings.isLocal {
            // Lokalmodus: nichts umstellen, Server im Übertragungs-Assistenten vorbelegen
            ModeUIState.shared.suggestedServer = server
            settings.loginNotice = "Die App läuft «Nur auf diesem iPhone». Um deine Daten auf \(ServerLink.host(server)) "
                + "zu übertragen: Einstellungen › Betriebsart › Auf Server übertragen …"
            return
        }
        if !settings.isConfigured || settings.serverURL.isEmpty {
            settings.serverURL = server
        } else if server != settings.serverURL {
            pendingServer = server
        } else {
            settings.loginNotice = "Dieser Server ist bereits eingerichtet."
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
