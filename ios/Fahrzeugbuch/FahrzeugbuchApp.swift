import SwiftUI

@main
@MainActor
struct FahrzeugbuchApp: App {
    @State private var settings = AppSettings()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .alert("Hinweis", isPresented: Binding(
                    get: { settings.loginNotice != nil },
                    set: { if !$0 { settings.loginNotice = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(settings.loginNotice ?? "")
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await settings.store?.sync() } }
        }
    }
}

struct RootView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
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

    @ViewBuilder
    private var content: some View {
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
                    Label("Kein Mandant", systemImage: "person.2.slash")
                } description: {
                    Text(settings.tenantError ?? "Dein Konto ist keinem Fahrzeugbuch-Mandanten zugeordnet "
                         + "(Keycloak-Gruppe /fahrzeugbuch/<mandant>).")
                } actions: {
                    Button("Erneut versuchen") { Task { await settings.loadTenants() } }
                }
                .toolbar {
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                }
            }
        } else {
            ProgressView("Lade Mandanten …")
                .task { await settings.loadTenants() }
        }
    }
}
