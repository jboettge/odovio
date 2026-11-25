import SwiftUI

/// Antwort von `GET …/audit/verify` (Kette, Datenstand, Anker, Belege).
struct IntegrityReport: Decodable {
    var ok: Bool
    var count: Int?
    var headHash: String?
    var brokenAt: Int?
    var reason: String?
    var chainOk: Bool?
    var stateOk: Bool?
    var problems: [String]?
    var signed: Bool?
    var anchors: Int?
    var blobsChecked: Int?
    var blobsMissing: Int?

    private var list: [String] { problems ?? [] }
    var anchorProblems: [String] { list.filter { $0.hasPrefix("Anker") } }
    var blobProblems: [String] { list.filter { $0.hasPrefix("Beleg") } }
    var stateProblems: [String] { list.filter { !$0.hasPrefix("Anker") && !$0.hasPrefix("Beleg") } }
    /// Ältere Server ohne `chain_ok`: `ok` bezieht sich nur auf die Kette
    var chainIntact: Bool { chainOk ?? (ok || brokenAt == nil) }
}

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TripCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var testResult: ServerTestResult?
    @State private var testing = false
    @State private var integrity: IntegrityReport?
    @State private var integrityError: String?
    @State private var verifying = false
    @State private var confirmLogout = false
    @State private var confirmServerChange = false
    @State private var showScanner = false
    @State private var showSetup = false

    struct ServerTestResult {
        var ok: Bool
        var message: String
        var issuer: String?
        var clientId: String?
    }

    private var parsedURL: URL? {
        guard let u = URL(string: url.trimmed), AuthManager.isSecure(u) else { return nil }
        return u
    }

    var body: some View {
        Form {
            serverSection

            if settings.auth.isLoggedIn {
                Section("Konto") {
                    LabeledContent("Angemeldet als", value: settings.auth.userName ?? "–")
                    ForEach(settings.tenants) { t in
                        LabeledContent {
                            Text(t.canWrite ? "Bearbeiten" : "Nur lesen")
                        } label: {
                            Label(t.slug, systemImage: "book.closed")
                        }
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
                            Label("Regeln (\(store.allRules.count))", systemImage: "wand.and.stars")
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

                    dataSection(store)
                }
            }

            Section {
                NavigationLink {
                    GlossaryView()
                } label: {
                    Label("Begriffe", systemImage: "character.book.closed")
                }
            } header: {
                Text("Hilfe")
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
            Button("Wechseln, abmelden und lokale Daten löschen", role: .destructive) {
                let target = url.trimmed
                Task {
                    await settings.changeServer(to: target)
                    dismiss()
                }
            }
        } message: {
            Text("Du wirst abgemeldet (Anmeldung wird widerrufen) und der Anmeldeserver wird neu ermittelt. "
                 + pendingWarning)
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
        .sheet(isPresented: $showScanner) {
            ServerQRScannerView { server in
                url = server
                testResult = nil
            }
        }
        .navigationDestination(isPresented: $showSetup) {
            TripSetupView(forAutomation: true)
        }
        .onAppear { if url.isEmpty { url = settings.serverURL } }
    }

    // MARK: Server

    private var serverSection: some View {
        Section {
            TextField("https://fahrzeugbuch.example.net", text: $url)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                showScanner = true
            } label: {
                Label("QR-Code scannen", systemImage: "qrcode.viewfinder")
            }
            Button {
                Task { await test() }
            } label: {
                HStack {
                    Label("Verbindung testen", systemImage: "network")
                    if testing { Spacer(); ProgressView() }
                }
            }
            .disabled(parsedURL == nil || testing)
            if let r = testResult {
                Label(r.message, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.footnote)
                    .foregroundStyle(r.ok ? Color.successText : Color.dangerText)
            }
            DisclosureGroup("Technische Details") {
                Text("Anmeldung über Keycloak (OpenID Connect). Anmeldeserver (Issuer) und Client-ID liefert der "
                     + "Fahrzeugbuch-Server; sie werden nach der ersten Anmeldung fest hinterlegt.")
                    .font(.footnote)
                    .foregroundStyle(Color.neutralText)
                if let issuer = testResult?.issuer {
                    LabeledContent("Issuer") { Text(issuer).font(.footnote.monospaced()).textSelection(.enabled) }
                }
                if let client = testResult?.clientId {
                    LabeledContent("Client-ID") { Text(client).font(.footnote.monospaced()) }
                }
            }
            .font(.subheadline)
        } header: {
            Text("Server")
        } footer: {
            Text("Nur HTTPS. Am einfachsten per QR-Code oder Einrichtungslink vom Betreiber deines Servers.")
        }
    }

    private func catalogFooter(_ store: TenantStore) -> String {
        store.canWrite
            ? "Artikel für die Materialerfassung bei Wartungen; Orte, Kunden, Regeln und Steuerparameter "
                + "für das Fahrtenbuch."
            : "Nur ansehen – dein Zugang für dieses Fahrzeugbuch ist schreibgeschützt."
    }

    // MARK: Fahrtenbuch

    /// Fahrtenbuch: Einrichtung, Automatik, Datenschutz.
    private var tripSection: some View {
        Section {
            NavigationLink {
                TripSetupView(forAutomation: coordinator.autoDetectEnabled)
            } label: {
                Label("Fahrtenbuch einrichten", systemImage: "checklist")
            }
            Toggle(isOn: Binding(
                get: { coordinator.autoDetectEnabled },
                set: { value in
                    guard !AppMode.isDemo else { return }
                    coordinator.autoDetectEnabled = value
                    // Fehlende Berechtigungen gleich einrichten
                    if value && !TripSetupView.automationReady(coordinator) { showSetup = true }
                })) {
                Label("Fahrten automatisch erkennen", systemImage: "car.side.arrowtriangle.up.arrowtriangle.down")
            }
            .disabled(AppMode.isDemo)
            if coordinator.autoDetectEnabled && !TripSetupView.automationReady(coordinator) {
                Button {
                    showSetup = true
                } label: {
                    Label("Für die Automatik fehlen Berechtigungen – einrichten", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.warningText)
                }
            }
            if let err = coordinator.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Color.warningText)
            }
        } header: {
            Text("Fahrtenbuch")
        } footer: {
            Text("Datenschutz: GPS wird nur während einer Fahrt aufgezeichnet. Die Rohdaten (Tracks) bleiben "
                 + "verschlüsselt auf diesem Gerät und werden 30 Tage nach der Bestätigung gelöscht; ins "
                 + "Änderungsprotokoll gelangt nur eine Prüfsumme. Die Koordinaten des Wohnorts verlassen das Gerät "
                 + "nie. Im Privatmodus werden nur Zeit und Kilometer gespeichert – keine Orte, kein Track. "
                 + "Vorschläge werden nie ohne deine Bestätigung übernommen.")
        }
    }

    // MARK: Daten

    private func dataSection(_ store: TenantStore) -> some View {
        Section {
            LabeledContent("Fahrzeugbuch", value: store.tenant.slug)
            LabeledContent("Ausstehend", value: "\(store.outbox.count) Änderung(en)")
            NavigationLink {
                RejectedOpsView()
                    .environment(store)
            } label: {
                HStack {
                    Label("Abgelehnte Änderungen", systemImage: "exclamationmark.icloud")
                    Spacer()
                    if !store.rejectedOps.isEmpty {
                        Text("\(store.rejectedOps.count)")
                            .font(.footnote.weight(.bold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .foregroundStyle(Color(uiColor: .systemBackground))
                            .background(Color.dangerText, in: Capsule())
                            .accessibilityLabel("\(store.rejectedOps.count) abgelehnt")
                    }
                }
            }
            if let issue = store.storeLoadIssue {
                Label(issue, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(Color.warningText)
            }
            if let last = store.lastSync {
                LabeledContent("Zuletzt synchronisiert",
                               value: last.formatted(date: .abbreviated, time: .shortened))
            }
            Button {
                Task { await verify(store) }
            } label: {
                HStack {
                    Label("Integrität prüfen", systemImage: "checkmark.shield")
                    if verifying { Spacer(); ProgressView() }
                }
            }
            .disabled(verifying || AppMode.isDemo)
            if let integrityError {
                Label(integrityError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Color.warningText)
            }
            if let r = integrity {
                integrityRows(r)
            }
        } header: {
            Text("Daten & Revisionssicherheit")
        } footer: {
            Text("Alle Änderungen werden serverseitig unveränderlich in einer Hash-Kette protokolliert und "
                 + "regelmässig signiert.")
        }
    }

    @ViewBuilder
    private func integrityRows(_ r: IntegrityReport) -> some View {
        let chainDetail: String = r.chainIntact
            ? "\(r.count ?? 0) Revisionen"
            : "Unterbrochen ab Revision \(r.brokenAt ?? 0)" + (r.reason.map { ": \($0)" } ?? "")
        CheckRow(title: "Hash-Kette", ok: r.chainIntact, detail: chainDetail)
        CheckRow(title: "Datenstand entspricht dem Protokoll", ok: r.stateOk ?? r.stateProblems.isEmpty,
                 detail: r.stateProblems.isEmpty ? nil : "\(r.stateProblems.count) Abweichung(en)")
        if r.signed == false {
            CheckRow(title: "Signierte Anker", ok: nil, detail: "Der Server signiert keine Anker.")
        } else {
            CheckRow(title: "Signierte Anker", ok: r.anchorProblems.isEmpty,
                     detail: r.anchorProblems.isEmpty ? "\(r.anchors ?? 0) Anker geprüft"
                         : "\(r.anchorProblems.count) Problem(e)")
        }
        let missing = r.blobsMissing ?? 0
        CheckRow(title: "Belege", ok: r.blobProblems.isEmpty && missing == 0,
                 detail: "\(r.blobsChecked ?? 0) geprüft" + (missing > 0 ? " · \(missing) fehlen" : ""))
        ForEach(Array((r.problems ?? []).prefix(10).enumerated()), id: \.offset) { item in
            Label(item.element, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(Color.warningText)
        }
        if let head = r.headHash {
            DisclosureGroup("Technische Details") {
                LabeledContent("Letzter Hash") {
                    Text(head).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            .font(.footnote)
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
            let (data, resp) = try await APIClient.session.data(from: u.appending(path: "auth/config"))
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                testResult = ServerTestResult(ok: false, message: APIError(status: status, message: "").userMessage)
                return
            }
            let cfg = try APIClient.decoder.decode(AuthConfig.self, from: data)
            testResult = ServerTestResult(ok: true, message: "Server erreichbar", issuer: cfg.issuer,
                                          clientId: cfg.clientId)
        } catch is DecodingError {
            testResult = ServerTestResult(ok: false, message: "Unter dieser Adresse läuft kein Fahrzeugbuch-Server.")
        } catch {
            testResult = ServerTestResult(ok: false, message: error.userMessage)
        }
    }

    private func verify(_ store: TenantStore) async {
        verifying = true
        defer { verifying = false }
        do {
            let report: IntegrityReport = try await settings.api.get("api/t/\(store.tenant.slug)/audit/verify")
            integrity = report
            integrityError = nil
        } catch {
            integrity = nil
            integrityError = "Prüfung nicht möglich: \(error.userMessage)"
        }
    }
}
