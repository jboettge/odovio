import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TripCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var status: String?
    @State private var testing = false
    @State private var audit: String?
    @State private var confirmLogout = false
    @State private var confirmServerChange = false

    private var parsedURL: URL? {
        guard let u = URL(string: url.trimmed), AuthManager.isSecure(u) else { return nil }
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
                Text("Nur HTTPS. Anmeldung über Keycloak (OIDC); Issuer und Client-ID liefert der Server "
                     + "und werden nach der ersten Anmeldung fest hinterlegt.")
            }

            if settings.auth.isLoggedIn {
                Section("Konto") {
                    LabeledContent("Angemeldet als", value: settings.auth.userName ?? "–")
                    ForEach(settings.tenants) { t in
                        LabeledContent(t.slug, value: t.canWrite ? "Schreiben" : "Lesen")
                    }
                    Button("Abmelden", role: .destructive) { confirmLogout = true }
                }

                if let store = settings.store {
                    Section {
                        NavigationLink {
                            MaterialCatalogView()
                                .environment(store)
                        } label: {
                            Label("Materialstamm (\(store.articles(for: nil).count))", systemImage: "shippingbox")
                        }
                        NavigationLink {
                            PlacesView()
                                .environment(store)
                        } label: {
                            Label("Orte (\(store.placeList.count))", systemImage: "mappin.and.ellipse")
                        }
                        NavigationLink {
                            CustomersView()
                                .environment(store)
                        } label: {
                            Label("Kunden (\(store.customerList.count))", systemImage: "person.2")
                        }
                        NavigationLink {
                            RulesView()
                                .environment(store)
                        } label: {
                            Label("Zweckregeln (\(store.allRules.count))", systemImage: "wand.and.stars")
                        }
                        NavigationLink {
                            TaxParamsView()
                                .environment(store)
                        } label: {
                            Label("Steuerparameter (\(store.taxParamList.count))", systemImage: "percent")
                        }
                    } header: {
                        Text("Stammdaten")
                    } footer: {
                        Text(catalogFooter(store))
                    }

                    tripSection

                    Section {
                        LabeledContent("Mandant", value: store.tenant.slug)
                        LabeledContent("Ausstehend", value: "\(store.outbox.count) Änderung(en)")
                        if let last = store.lastSync {
                            LabeledContent("Zuletzt synchronisiert",
                                           value: last.formatted(date: .abbreviated, time: .shortened))
                        }
                        Button("Integrität prüfen") { Task { await verify(store) } }
                        if let audit {
                            Text(audit).font(.caption.monospaced())
                        }
                    } header: {
                        Text("Daten & Revisionssicherheit")
                    } footer: {
                        Text("Alle Änderungen werden serverseitig unveränderlich in einer Hash-Kette protokolliert.")
                    }
                }
            }
        }
        .navigationTitle("Einstellungen")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(settings.isConfigured ? "Fertig" : "Weiter") {
                    let new = url.trimmed
                    if new != settings.serverURL && !settings.serverURL.isEmpty {
                        confirmServerChange = true
                    } else {
                        settings.serverURL = new
                        dismiss()
                    }
                }
                .disabled(parsedURL == nil)
            }
        }
        .confirmationDialog("Server wechseln?", isPresented: $confirmServerChange, titleVisibility: .visible) {
            Button("Wechseln und lokale Daten löschen", role: .destructive) {
                settings.auth.clearSession()
                settings.resetLocalData()
                settings.serverURL = url.trimmed
                dismiss()
            }
        } message: {
            Text(pendingWarning)
        }
        .confirmationDialog("Abmelden?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Abmelden und lokale Daten löschen", role: .destructive) {
                Task {
                    await settings.logout()   // inkl. Tracks löschen (AppSettings.resetLocalData)
                    dismiss()
                }
            }
        } message: {
            Text(pendingWarning)
        }
        .onAppear { url = settings.serverURL }
    }

    private func catalogFooter(_ store: TenantStore) -> String {
        store.canWrite
            ? "Artikel für die Materialerfassung bei Wartungen; Orte, Kunden, Regeln und Steuerparameter "
                + "für das Fahrtenbuch."
            : "Nur ansehen – dein Zugang für diesen Mandanten ist schreibgeschützt."
    }

    /// Fahrtenbuch: Automatik, Berechtigungen, Datenschutz.
    private var tripSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { coordinator.autoDetectEnabled },
                set: { value in if !AppMode.isDemo { coordinator.autoDetectEnabled = value } })) {
                Label("Fahrten automatisch erkennen", systemImage: "car.side.arrowtriangle.up.arrowtriangle.down")
            }
            .disabled(AppMode.isDemo)
            Button {
                Task { await coordinator.requestPermissions() }
            } label: {
                Label("Berechtigungen anfragen", systemImage: "location.circle")
            }
            .disabled(AppMode.isDemo)
            if let err = coordinator.lastError {
                Text(err).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Fahrtenbuch")
        } footer: {
            Text("Datenschutz: GPS wird nur während einer Fahrt aufgezeichnet. Die Rohdaten (Tracks) bleiben "
                 + "verschlüsselt auf diesem Gerät und werden 30 Tage nach der Bestätigung gelöscht; ins "
                 + "Änderungsprotokoll gelangt nur eine Prüfsumme. Im Privatmodus werden nur Zeit und Kilometer "
                 + "gespeichert – keine Orte, kein Track. Automatik benötigt Standort «Immer» und "
                 + "«Bewegung & Fitness»; Vorschläge werden nie ohne deine Bestätigung übernommen.")
        }
    }

    private var pendingWarning: String {
        let n = TenantStore.pendingCountOnDisk()
        return n > 0
            ? "Achtung: \(n) Änderung(en) sind noch nicht synchronisiert und gehen verloren."
            : "Lokal gespeicherte Daten werden vom Gerät entfernt."
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
            let cfg = try APIClient.decoder.decode(AuthConfig.self, from: data)
            status = "✅ Server erreichbar\nIssuer: \(cfg.issuer)\nClient: \(cfg.clientId)"
        } catch {
            status = "❌ \(error.localizedDescription)"
        }
    }

    private func verify(_ store: TenantStore) async {
        do {
            let r: AuditResult = try await settings.api.get("api/t/\(store.tenant.slug)/audit/verify")
            audit = r.ok
                ? "✅ Kette intakt · \(r.count) Revisionen\n\(r.headHash)"
                : "❌ Kette gebrochen ab Seq \(r.brokenAt ?? 0): \(r.reason ?? "")"
        } catch {
            audit = "Nur online verfügbar: \(error.localizedDescription)"
        }
    }
}
