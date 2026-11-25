import SwiftUI

@main
struct FahrzeugbuchApp: App {
    @State private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
        }
    }
}

struct RootView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if settings.isConfigured {
            VehicleListView()
        } else {
            NavigationStack { SettingsView() }
        }
    }
}
