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
                Text("Anmeldung über dein j-mb.net-Konto. Danach funktioniert die App auch offline.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
                Button {
                    Task { await login() }
                } label: {
                    Group {
                        if busy { ProgressView() } else { Text("Anmelden") }
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
                        .accessibilityLabel("Einstellungen")
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
            try await settings.login(session: webAuth)
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            // Benutzer hat abgebrochen
        } catch {
            self.error = error.localizedDescription
        }
    }
}
