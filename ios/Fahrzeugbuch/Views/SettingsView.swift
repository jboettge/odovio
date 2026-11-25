import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var status: String?
    @State private var testing = false

    private var parsedURL: URL? {
        guard let u = URL(string: url.trimmed), u.host != nil else { return nil }
        return u
    }

    var body: some View {
        Form {
            Section {
                TextField("https://fahrzeugbuch.example.net", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Verbindung testen") { Task { await test() } }
                    .disabled(parsedURL == nil || testing)
                if let status {
                    Text(status).font(.footnote)
                }
            } header: {
                Text("Server")
            } footer: {
                Text("Anmeldung erfolgt über Keycloak (OIDC). Issuer und Client-ID liefert der Server.")
            }

            if settings.auth.isLoggedIn {
                Section("Konto") {
                    LabeledContent("Angemeldet als", value: settings.auth.userName ?? "–")
                    Button("Abmelden", role: .destructive) {
                        Task {
                            await settings.auth.logout(server: settings.baseURL)
                            dismiss()
                        }
                    }
                }
            }
        }
        .navigationTitle("Einstellungen")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Sichern") {
                    let new = url.trimmed
                    if new != settings.serverURL {
                        settings.auth.clearSession()   // Tokens gehören zum alten Server
                        settings.serverURL = new
                    }
                    dismiss()
                }
                .disabled(parsedURL == nil)
            }
        }
        .onAppear { url = settings.serverURL }
    }

    private func test() async {
        guard let u = parsedURL else { return }
        testing = true
        defer { testing = false }
        do {
            let (data, resp) = try await URLSession.shared.data(from: u.appending(path: "auth/config"))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                status = "❌ Server antwortet mit \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
                return
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let cfg = try decoder.decode(AuthConfig.self, from: data)
            status = "✅ Server erreichbar\nIssuer: \(cfg.issuer)\nClient: \(cfg.clientId)"
        } catch {
            status = "❌ \(error.localizedDescription)"
        }
    }
}
