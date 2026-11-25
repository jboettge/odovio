import AuthenticationServices
import SwiftUI

struct LoginView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var busy = false
    @State private var showSettings = false
    @State private var error: String?
    @State private var confirmReset = false
    @State private var resetDone = false

    private var host: String { ServerLink.host(settings.serverURL) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: "car.side.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.tint)
                        .padding(.top, 48)
                        .accessibilityHidden(true)
                    Text("Fahrzeugbuch").font(.largeTitle.bold())
                    Text(host).font(.footnote).foregroundStyle(Color.neutralText)
                    Text("Anmeldung mit deinem Konto für \(host). Danach funktioniert die App auch offline.")
                        .font(.subheadline)
                        .foregroundStyle(Color.neutralText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
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
                    .padding(.top, 24)
                    if resetDone {
                        Label("Anmeldeserver zurückgesetzt – bitte neu anmelden.", systemImage: "checkmark.circle")
                            .font(.footnote)
                            .foregroundStyle(Color.successText)
                    }
                    Button("Probleme bei der Anmeldung?") { confirmReset = true }
                        .font(.footnote)
                        .padding(.top, 8)
                }
                .padding()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Einstellungen")
                }
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack { SettingsView() }
            }
            .confirmationDialog("Anmeldeserver zurücksetzen?", isPresented: $confirmReset,
                                titleVisibility: .visible) {
                Button("Anmeldeserver zurücksetzen", role: .destructive) {
                    settings.auth.resetIssuerPin()
                    resetDone = true
                }
                Button("Server-Adresse ändern") { showSettings = true }
            } message: {
                Text("Hilft, wenn die Anmeldung mit «Anmeldeserver hat sich geändert» scheitert (z. B. nach einem "
                     + "Serverwechsel). Achtung: Der Anmeldeserver wird bei der nächsten Anmeldung neu vom Server "
                     + "übernommen – nur zurücksetzen, wenn du der Server-Adresse vertraust.")
            }
            .errorAlert($error)
        }
    }

    private func login() async {
        busy = true
        defer { busy = false }
        do {
            try await settings.login(session: webAuth)
            resetDone = false
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            // Benutzer hat abgebrochen
        } catch let e as AuthError {
            if case .issuerChanged = e {
                confirmReset = true   // direkt den Ausweg anbieten (S8)
            } else {
                self.error = e.userMessage
            }
        } catch {
            self.error = error.userMessage
        }
    }
}
