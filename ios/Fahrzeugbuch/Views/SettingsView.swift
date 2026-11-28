import SwiftUI
import UniformTypeIdentifiers

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
    // Betriebsart
    @State private var confirmResetMode = false
    @State private var showSwitchLocal = false
    @State private var showMigration = false
    // Lokalmodus: Sicherung und Integrität
    @State private var backupURL: URL?
    @State private var backupBusy = false
    @State private var backupMessage: String?
    @State private var showImporter = false
    @State private var importURL: URL?
    @State private var localIntegrity: LocalIntegrity?

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
            modeSection

            if !settings.isLocal {
                serverSection
            }

            if settings.isLocal, let store = settings.store {
                catalogSection(store)
                tripSection(store)
                geocodingSection
                backupSection(store)
                localIntegritySection(store)
            } else if settings.auth.isLoggedIn {
                Section("Konto") {
                    LabeledContent("Angemeldet als", value: settings.auth.userName ?? "–")
                    ForEach(settings.tenants) { t in
                        LabeledContent {
                            RoleTag(role: t.role)
                        } label: {
                            Label(t.slug, systemImage: "book.closed")
                        }
                    }
                    Button("Abmelden", role: .destructive) { confirmLogout = true }
                }

                if let store = settings.store {
                    sharedSection(store)
                    catalogSection(store)
                    tripSection(store)
                    dataSection(store)
                }
            }

            Section {
                NavigationLink {
                    GlossaryView()
                } label: {
                    Label("Begriffe", systemImage: "character.book.closed")
                }
                NavigationLink {
                    CrashReportsView()
                } label: {
                    Label("Absturzberichte", systemImage: "ladybug")
                }
                // AGPL-3.0: Quellcode der App frei zugänglich
                Link(destination: AppInfo.sourceURL) {
                    Label("Quellcode (AGPL-3.0)", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .accessibilityHint("Öffnet das öffentliche Repository im Browser")
            } header: {
                Text("Hilfe")
            } footer: {
                Text("odovio ist freie Software unter der GNU Affero General Public License 3.0 oder später.")
            }
        }
        .navigationTitle("Einstellungen")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(doneTitle) {
                    if settings.isLocal {
                        dismiss()
                        return
                    }
                    let new = url.trimmed
                    if new != settings.serverURL && !settings.serverURL.isEmpty {
                        confirmServerChange = true
                    } else {
                        settings.serverURL = new
                        dismiss()
                    }
                }
                .disabled(!settings.isLocal && parsedURL == nil)
            }
        }
        .modifier(SettingsDialogs(settings: settings, url: url, pendingWarning: pendingWarning,
                                  confirmServerChange: $confirmServerChange, confirmLogout: $confirmLogout,
                                  confirmResetMode: $confirmResetMode, dismiss: { dismiss() }))
        .sheet(isPresented: $showScanner) {
            ServerQRScannerView { server in
                url = server
                testResult = nil
            }
        }
        .sheet(isPresented: $showSwitchLocal) {
            SwitchToLocalView()
        }
        .sheet(isPresented: $showMigration) {
            if let store = settings.store {
                MigrationWizardView().environment(store)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let picked): importURL = picked
            case .failure(let e): backupMessage = "Datei nicht geöffnet: \(e.localizedDescription)"
            }
        }
        .confirmationDialog("Sicherung importieren?", isPresented: Binding(
            get: { importURL != nil }, set: { if !$0 { importURL = nil } }),
                            titleVisibility: .visible, presenting: importURL) { picked in
            Button("Importieren und lokale Daten ersetzen", role: .destructive) {
                Task { await importBackup(picked) }
            }
        } message: { _ in
            Text("Die Sicherung ersetzt alle Fahrzeuge, Fahrten, Tankvorgänge, Wartungen und Stammdaten auf diesem "
                 + "iPhone. Exportiere vorher eine aktuelle Sicherung, wenn du den heutigen Stand behalten möchtest.")
        }
        .navigationDestination(isPresented: $showSetup) {
            TripSetupView(forAutomation: true)
        }
        .onAppear { if url.isEmpty { url = settings.serverURL } }
    }

    private var doneTitle: String {
        (settings.isConfigured || settings.isLocal) ? "Fertig" : "Weiter"
    }

    // MARK: Betriebsart

    private var modeSection: some View {
        Section {
            LabeledContent {
                Text(ModeText.title(settings.isLocal))
            } label: {
                Label("Aktuell", systemImage: settings.isLocal ? "iphone" : "server.rack")
            }
            Text(ModeText.explanation(settings.isLocal))
                .font(.footnote)
                .foregroundStyle(Color.neutralText)
                .fixedSize(horizontal: false, vertical: true)
            if settings.isLocal {
                Button {
                    showMigration = true
                } label: {
                    Label("Auf Server übertragen …", systemImage: "icloud.and.arrow.up")
                }
                .disabled(settings.store == nil)
            } else if settings.store != nil {
                Button {
                    showSwitchLocal = true
                } label: {
                    Label("Nur noch lokal verwenden …", systemImage: "iphone")
                }
            }
            NavigationLink {
                ScrollView {
                    ModeComparisonTable().padding()
                }
                .navigationTitle("Betriebsarten")
                .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label("Betriebsarten vergleichen", systemImage: "tablecells")
            }
            Button(role: .destructive) {
                confirmResetMode = true
            } label: {
                Label("Betriebsart neu wählen …", systemImage: "arrow.uturn.backward")
            }
            .disabled(AppMode.isDemo)
        } header: {
            Text("Betriebsart")
        }
    }

    // MARK: Gemeinsam (Servermodus)

    @ViewBuilder
    private func sharedSection(_ store: TenantStore) -> some View {
        let caps = settings.capabilities
        Section {
            LabeledContent("Name", value: store.tenant.slug)
            LabeledContent("Deine Rolle") { RoleTag(role: store.tenant.role) }
            if caps.members {
                NavigationLink {
                    MembersView()
                        .environment(store)
                } label: {
                    Label("Mitglieder", systemImage: "person.2")
                }
            }
            if caps.activity {
                NavigationLink {
                    ActivityView()
                        .environment(store)
                } label: {
                    Label("Aktivität", systemImage: "clock.arrow.circlepath")
                }
            }
        } header: {
            Text("Fahrzeugbuch")
        } footer: {
            Text("Alle Mitglieder bewirtschaften dieselben Fahrzeuge. Mitglieder und Rollen werden im Webfrontend "
                 + "deines Servers verwaltet.")
        }
    }

    // MARK: Stammdaten

    private func catalogSection(_ store: TenantStore) -> some View {
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
    }

    // MARK: Lokalmodus

    private var geocodingSection: some View {
        Section {
            Toggle(isOn: Binding(get: { settings.useAppleGeocoding }, set: { settings.useAppleGeocoding = $0 })) {
                Label("Adressen über Apple ermitteln", systemImage: "map")
            }
        } header: {
            Text("Adressen")
        } footer: {
            Text("Datenschutz: Für Start und Ziel einer Fahrt werden die Koordinaten an den Kartendienst von Apple "
                 + "gesendet, um die Adresse zu ermitteln. Ausgeschaltet verlassen keine Standortdaten das iPhone – "
                 + "Fahrten zeigen dann nur deine gespeicherten Orte.")
        }
    }

    private func backupSection(_ store: TenantStore) -> some View {
        Section {
            LabeledContent("Speicherort", value: ModeText.localTitle)
            Button {
                Task { await exportBackup(store) }
            } label: {
                HStack {
                    Label("Datensicherung exportieren", systemImage: "square.and.arrow.up.on.square")
                    if backupBusy { Spacer(); ProgressView() }
                }
            }
            .disabled(backupBusy)
            if let backupURL {
                ShareLink(item: backupURL) {
                    Label("Sicherung teilen / in Dateien sichern", systemImage: "square.and.arrow.up")
                }
            }
            Button {
                showImporter = true
            } label: {
                Label("Sicherung importieren …", systemImage: "square.and.arrow.down")
            }
            .disabled(backupBusy || AppMode.isDemo)
            if let backupMessage {
                Text(backupMessage)
                    .font(.footnote)
                    .foregroundStyle(Color.neutralText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Datensicherung")
        } footer: {
            Text("Die Sicherung enthält alle lokalen Daten inkl. Änderungsprotokoll und Belegen. Bewahre sie z. B. in "
                 + "der Dateien-App (iCloud Drive) auf. Zusätzlich sichert das iCloud-Backup des iPhones die Daten.")
        }
    }

    private func localIntegritySection(_ store: TenantStore) -> some View {
        Section {
            if let issue = store.storeLoadIssue {
                Label(issue, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(Color.warningText)
            }
            Button {
                Task { await verifyLocal(store) }
            } label: {
                HStack {
                    Label("Integrität prüfen", systemImage: "checkmark.shield")
                    if verifying { Spacer(); ProgressView() }
                }
            }
            .disabled(verifying)
            if let r = localIntegrity {
                localIntegrityRows(r)
            }
        } header: {
            Text("Änderungsprotokoll")
        } footer: {
            Text("Jede Änderung wird auf diesem iPhone in einer Hash-Kette protokolliert. Lokal gibt es keine "
                 + "signierten Server-Anker: Die Kette zeigt versehentliche Beschädigungen, schützt aber nicht vor "
                 + "einer vollständigen Neuberechnung auf dem Gerät.")
        }
    }

    @ViewBuilder
    private func localIntegrityRows(_ r: LocalIntegrity) -> some View {
        let count = Present.count(r.count)
        if r.ok {
            CheckRow(title: "Lokales Protokoll intakt · \(count) Einträge", ok: true)
        } else {
            let detail: String? = Present.int(r.brokenAt).map { "Unterbrochen ab Eintrag \($0)" }
            CheckRow(title: "Lokales Protokoll beschädigt", ok: false, detail: detail)
        }
        CheckRow(title: "Signierte Server-Anker", ok: nil, detail: "Lokal nicht vorhanden")
        ForEach(Array(Present.lines(r.problems).prefix(10).enumerated()), id: \.offset) { item in
            Label(item.element, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(Color.warningText)
        }
        if let head = Present.text(r.headHash) {
            DisclosureGroup("Technische Details") {
                LabeledContent("Letzter Hash") {
                    Text(head).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            .font(.footnote)
        }
    }

    private func exportBackup(_ store: TenantStore) async {
        backupBusy = true
        defer { backupBusy = false }
        do {
            backupURL = try LocalBackup.exportBackup(store: store)
            backupMessage = nil
        } catch {
            backupMessage = "Sicherung nicht erstellt: \(error.userMessage)"
        }
    }

    private func importBackup(_ picked: URL) async {
        backupBusy = true
        defer { backupBusy = false }
        let access = picked.startAccessingSecurityScopedResource()
        defer { if access { picked.stopAccessingSecurityScopedResource() } }
        do {
            let summary = try settings.importBackup(from: picked)
            localIntegrity = nil
            backupMessage = BackupText.imported(summary)
        } catch {
            backupMessage = "Import fehlgeschlagen: \(error.userMessage)"
        }
    }

    private func verifyLocal(_ store: TenantStore) async {
        verifying = true
        defer { verifying = false }
        localIntegrity = store.verifyLocalJournal()
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
        if !store.canWrite { return "Nur ansehen – dein Zugang für dieses Fahrzeugbuch ist schreibgeschützt." }
        let base = "Artikel für die Materialerfassung bei Wartungen; Orte, Kunden, Regeln und Steuerparameter "
            + "für das Fahrtenbuch."
        return store.isLocal ? base : base + " Steuerparameter bearbeitest du im Webfrontend deines Servers."
    }

    // MARK: Fahrtenbuch

    /// Fahrtenbuch: Einrichtung, Automatik, Datenschutz.
    private func tripSection(_ store: TenantStore) -> some View {
        Section {
            NavigationLink {
                TripSetupView(forAutomation: coordinator.autoDetectEnabled)
            } label: {
                Label("Fahrtenbuch einrichten", systemImage: "checklist")
            }
            DefaultVehiclePicker(store: store)
            NavigationLink {
                CarDetectionSettingsView(store: store)
            } label: {
                LabeledContent {
                    Text(CarConnectionMonitor.shared.mode.label)
                } label: {
                    Label("Auto erkennen über", systemImage: "antenna.radiowaves.left.and.right")
                }
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
                if coordinator.lastErrorOpensSettings {
                    OpenSystemSettingsButton()
                }
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

/// Rückfragen der Einstellungen (Serverwechsel, Abmelden, Betriebsart neu wählen).
private struct SettingsDialogs: ViewModifier {
    let settings: AppSettings
    let url: String
    let pendingWarning: String
    @Binding var confirmServerChange: Bool
    @Binding var confirmLogout: Bool
    @Binding var confirmResetMode: Bool
    let dismiss: () -> Void

    private var resetModeText: String {
        var text = "Die App zeigt wieder die Auswahl «Nur auf diesem iPhone» oder «Mit Server»."
        if settings.isLocal {
            text += " Exportiere vorher eine Datensicherung, damit deine lokalen Daten sicher erhalten bleiben."
        } else {
            let n = TenantStore.pendingCountOnDisk()
            if n > 0 { text += " Achtung: \(n) Änderung(en) sind noch nicht synchronisiert." }
        }
        return text
    }

    func body(content: Content) -> some View {
        content
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
            .confirmationDialog("Betriebsart neu wählen?", isPresented: $confirmResetMode,
                                titleVisibility: .visible) {
                Button("Zur Auswahl der Betriebsart", role: .destructive) {
                    dismiss()
                    settings.resetMode()
                }
            } message: {
                Text(resetModeText)
            }
    }
}


/// Von MetricKit gelieferte Absturz-/Hänger-Berichte ansehen, teilen, löschen.
struct CrashReportsView: View {
    @State private var reports: [URL] = []
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section {
                if reports.isEmpty {
                    Text("Keine Absturzberichte vorhanden.").foregroundStyle(.secondary)
                }
                ForEach(reports, id: \.self) { url in
                    ShareLink(item: url) {
                        Label(CrashReporter.title(of: url), systemImage: "doc.text")
                    }
                }
            } footer: {
                Text("iOS liefert einen Bericht beim nächsten Start der App nach einem Absturz, manchmal mit "
                     + "einigen Minuten Verzögerung. Er enthält nur technische Angaben (Stacktrace, Gerät, iOS-Version), "
                     + "keine Fahrten oder Standorte, und bleibt auf diesem iPhone, bis du ihn teilst.")
            }
            if !reports.isEmpty {
                Section {
                    Button("Alle löschen", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle("Absturzberichte")
        .onAppear { reports = CrashReporter.reports() }
        .refreshable { reports = CrashReporter.reports() }
        .confirmationDialog("Alle Absturzberichte löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                CrashReporter.deleteAll()
                reports = CrashReporter.reports()
            }
        }
    }
}

/// Feste App-Angaben.
enum AppInfo {
    /// Öffentliches Repository (AGPL-3.0); konstante, gültige URL
    static let sourceURL = URL(string: "https://github.com/jboettge/odovio")!
}
