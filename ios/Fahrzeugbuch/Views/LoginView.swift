import AuthenticationServices
import SwiftUI

struct LoginView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var busy = false
    @State private var showSettings = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "car.side.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                Text("Fahrzeugbuch").font(.largeTitle.bold())
                Text(settings.serverURL).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await login() }
                } label: {
                    Group {
                        if busy { ProgressView() } else { Text("Mit Keycloak anmelden") }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(busy)
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack { SettingsView() }
            }
            .errorAlert($error)
        }
    }

    private func login() async {
        busy = true
        defer { busy = false }
        do {
            try await settings.auth.login(server: settings.baseURL, session: webAuth)
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            // Benutzer hat abgebrochen
        } catch {
            self.error = error.localizedDescription
        }
    }
}
