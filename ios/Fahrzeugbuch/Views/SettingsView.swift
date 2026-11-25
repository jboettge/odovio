import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var token = ""
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
                SecureField("API-Token", text: $token)
            } header: {
                Text("Server")
            } footer: {
                Text("Token = API_TOKEN aus dem Portainer-Stack. Wird in der Keychain gespeichert.")
            }
            Section {
                Button("Verbindung testen") { Task { await test() } }
                    .disabled(parsedURL == nil || token.isEmpty || testing)
                if let status {
                    Text(status).font(.footnote)
                }
            }
        }
        .navigationTitle("Einstellungen")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Sichern") {
                    settings.serverURL = url.trimmed
                    settings.token = token.trimmed
                    dismiss()
                }
                .disabled(parsedURL == nil || token.trimmed.isEmpty)
            }
        }
        .onAppear {
            url = settings.serverURL
            token = settings.token
        }
    }

    private func test() async {
        guard let u = parsedURL else { return }
        testing = true
        defer { testing = false }
        do {
            let vehicles: [Vehicle] = try await APIClient(baseURL: u, token: token.trimmed).get("api/vehicles")
            status = "✅ Verbunden – \(vehicles.count) Fahrzeug(e)"
        } catch {
            status = "❌ \(error.localizedDescription)"
        }
    }
}
