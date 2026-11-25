import AuthenticationServices
import Observation
import SwiftUI

// MARK: Zustand über Ansichtswechsel hinweg

/// Hält UI-Zustand, der einen Wechsel der Betriebsart überdauern muss (die Ansichten werden dabei neu aufgebaut).
@MainActor
@Observable
final class ModeUIState {
    static let shared = ModeUIState()

    /// Server aus einem Einrichtungslink, während die App lokal läuft (Vorbelegung im Übertragungs-Assistenten)
    var suggestedServer: String?
    /// Ergebnis einer Übertragung, das nach dem Wechsel auf Ebene der Wurzelansicht gezeigt wird
    var presentReport: MigrationResult?

    private init() {}
}

/// Ergebnis der Übertragung (für `.sheet(item:)`).
struct MigrationResult: Identifiable {
    let id = UUID()
    let report: MigrationReport
    let target: String
}

// MARK: Texte

enum ModeText {
    static let localTitle = "Nur auf diesem iPhone"
    static let serverTitle = "Mit Server (gemeinsam)"

    static func title(_ isLocal: Bool) -> String { isLocal ? localTitle : serverTitle }

    static func explanation(_ isLocal: Bool) -> String {
        isLocal
            ? "Ohne Konto und ohne Server: Alle Daten bleiben auf diesem iPhone. Sichern per Export oder "
                + "iCloud-Backup des iPhones; später kannst du alles auf einen Server übertragen."
            : "Deine Daten liegen auf deinem Fahrzeugbuch-Server (mit Kopie für offline). Mehrere Personen "
                + "bewirtschaften die Fahrzeuge gemeinsam – mit Rollen, Aktivität und signiertem Änderungsprotokoll."
    }
}

// MARK: Moduswahl

/// Erster Bildschirm: Betriebsart wählen.
@MainActor
struct ModeChoiceView: View {
    @Environment(AppSettings.self) private var settings
    @State private var starting = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: "car.side.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text("Wie möchtest du das Fahrzeugbuch nutzen?")
                            .font(.title2.bold())
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text("Du kannst die Betriebsart später in den Einstellungen wechseln.")
                            .font(.subheadline)
                            .foregroundStyle(Color.neutralText)
                    }

                    ModeCard(icon: "iphone", title: ModeText.localTitle,
                             subtitle: "Ohne Konto – sofort loslegen",
                             points: ["Kein Konto und kein Server nötig",
                                      "Daten bleiben auf diesem iPhone",
                                      "Sicherung per Export (Dateien) und iCloud-Backup",
                                      "Später auf einen Server übertragbar"],
                             actionTitle: "Lokal starten", busy: starting) {
                        startLocal()
                    }

                    ModeCard(icon: "server.rack", title: ModeText.serverTitle,
                             subtitle: "Mit Konto bei deinem Fahrzeugbuch-Server",
                             points: ["Fahrzeuge gemeinsam bewirtschaften",
                                      "Rollen: Verwalten, Bearbeiten, Nur lesen",
                                      "Revisionssicher mit signierten Server-Ankern",
                                      "KI-Vorschläge und KI-Belegauswertung (falls eingerichtet)"],
                             actionTitle: "Server einrichten", busy: false) {
                        settings.chooseServer()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Vergleich").font(.headline).accessibilityAddTraits(.isHeader)
                        ModeComparisonTable()
                    }
                    .padding()
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

                    NavigationLink {
                        GlossaryView()
                    } label: {
                        Label("Begriffe erklärt (Betriebsart, Verwalter, Mitglied …)", systemImage: "character.book.closed")
                            .font(.subheadline)
                    }
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Betriebsart")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func startLocal() {
        starting = true
        settings.startLocal()
        starting = false
    }
}

/// Grosse Auswahlkarte.
private struct ModeCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let points: [String]
    let actionTitle: String
    let busy: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.title)
                    .foregroundStyle(Color.infoText)
                    .frame(minWidth: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.bold())
                    Text(subtitle).font(.subheadline).foregroundStyle(Color.neutralText)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(points, id: \.self) { p in
                    Label {
                        Text(p).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "checkmark").foregroundStyle(Color.successText)
                    }
                    .font(.subheadline)
                }
            }
            Button(action: action) {
                HStack {
                    Spacer()
                    if busy { ProgressView() } else { Text(actionTitle).fontWeight(.semibold) }
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(busy)
            .accessibilityLabel("\(actionTitle): \(title)")
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.infoText.opacity(0.25)))
        .accessibilityElement(children: .contain)
    }
}

/// Kompakter Vergleich der Betriebsarten.
struct ModeComparisonTable: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    enum Cell {
        case yes(String?), no(String?), text(String)

        var spoken: String {
            switch self {
            case .yes(let t): ["ja", t ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
            case .no(let t): ["nein", t ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
            case .text(let t): t
            }
        }
    }

    struct Row: Identifiable {
        let feature: String
        let local: Cell
        let server: Cell
        var id: String { feature }
    }

    static let rows: [Row] = [
        Row(feature: "Konto", local: .text("Nicht nötig"), server: .text("Bei deinem Server")),
        Row(feature: "Daten liegen", local: .text("Auf diesem iPhone"),
            server: .text("Auf dem Server, Kopie auf dem iPhone")),
        Row(feature: "Mehrere Personen und Geräte", local: .no(nil), server: .yes(nil)),
        Row(feature: "Rollen und Aktivität", local: .no(nil), server: .yes(nil)),
        Row(feature: "Fahrtenbuch, Tanken, Wartung", local: .yes(nil), server: .yes(nil)),
        Row(feature: "Berichte (PDF, CSV)", local: .yes("auf dem iPhone"), server: .yes(nil)),
        Row(feature: "Änderungsprotokoll", local: .yes("lokal"), server: .yes("mit signierten Ankern")),
        Row(feature: "KI-Vorschläge und KI-Belegauswertung", local: .no("nur Regeln"), server: .yes("falls eingerichtet")),
        Row(feature: "Sicherung", local: .text("Export und iCloud-Backup"), server: .text("Auf dem Server")),
        Row(feature: "Später wechseln", local: .text("Auf Server übertragen"), server: .text("Nur noch lokal")),
    ]

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Self.rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.feature).font(.headline)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("iPhone:").foregroundStyle(Color.neutralText)
                            cell(row.local)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("Server:").foregroundStyle(Color.neutralText)
                            cell(row.server)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spoken(row))
                }
            }
        } else {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    Text("iPhone").font(.footnote.weight(.semibold))
                    Text("Server").font(.footnote.weight(.semibold))
                }
                .accessibilityHidden(true)
                Divider()
                ForEach(Self.rows) { row in
                    GridRow(alignment: .firstTextBaseline) {
                        Text(row.feature)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                        cell(row.local)
                        cell(row.server)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spoken(row))
                }
            }
        }
    }

    private func spoken(_ row: Row) -> String {
        "\(row.feature): nur iPhone \(row.local.spoken); mit Server \(row.server.spoken)"
    }

    @ViewBuilder
    private func cell(_ c: Cell) -> some View {
        switch c {
        case .yes(let t):
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.successText)
                if let t { Text(t).foregroundStyle(Color.neutralText) }
            }
            .font(.footnote)
        case .no(let t):
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Image(systemName: "minus.circle").foregroundStyle(Color.neutralText)
                if let t { Text(t).foregroundStyle(Color.neutralText) }
            }
            .font(.footnote)
        case .text(let t):
            Text(t)
                .font(.footnote)
                .foregroundStyle(Color.neutralText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Nur noch lokal verwenden

/// Servermodus → Lokalmodus (optional mit Übernahme der aktuellen Daten).
@MainActor
struct SwitchToLocalView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var copyCurrent = true
    @State private var confirm = false
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(ModeText.explanation(true))
                        .font(.subheadline)
                        .foregroundStyle(Color.neutralText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    Toggle(isOn: $copyCurrent) {
                        Label("Aktuelle Daten übernehmen", systemImage: "doc.on.doc")
                    }
                } footer: {
                    Text(copyFooter)
                }
                if let store = settings.store {
                    warningSection(store)
                }
                Section {
                    Label("Gemeinsame Daten werden danach nicht mehr synchronisiert: Änderungen anderer Personen "
                          + "siehst du nicht mehr, und deine Änderungen erreichen den Server nicht.",
                          systemImage: "person.2.slash")
                        .foregroundStyle(Color.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                    Label("Ohne Server entfallen Mitglieder, Aktivität, KI-Funktionen und signierte Server-Anker.",
                          systemImage: "info.circle")
                        .foregroundStyle(Color.neutralText)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Bitte beachten")
                }
                Section {
                    Button(role: .destructive) {
                        confirm = true
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text("Nur noch lokal verwenden").fontWeight(.semibold) }
                            Spacer()
                        }
                    }
                    .disabled(busy || AppMode.isDemo)
                }
            }
            .navigationTitle("Nur noch lokal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }.disabled(busy)
                }
            }
            .interactiveDismissDisabled(busy)
            .confirmationDialog("Nur noch lokal verwenden?", isPresented: $confirm, titleVisibility: .visible) {
                Button(confirmTitle, role: .destructive) {
                    Task { await switchNow() }
                }
            } message: {
                Text(confirmText)
            }
        }
    }

    private var confirmTitle: String {
        copyCurrent ? "Mit aktuellen Daten wechseln" : "Leer lokal starten"
    }

    private var copyFooter: String {
        let slug = settings.store?.tenant.slug ?? "–"
        return copyCurrent
            ? "Fahrzeuge, Fahrten, Tankvorgänge, Wartungen und Stammdaten aus «\(slug)» werden als lokale Kopie "
                + "übernommen."
            : "Du startest lokal ohne Daten. Die Daten auf dem Server bleiben unverändert."
    }

    private var confirmText: String {
        let pending = settings.store?.outbox.count ?? 0
        var text = "Die App arbeitet danach nur noch auf diesem iPhone. Du wirst vom Server abgemeldet und die "
            + "Server-Kopie auf dem Gerät wird entfernt (die Daten auf dem Server bleiben)."
        if pending > 0 {
            text += " Achtung: \(pending) Änderung(en) sind noch nicht synchronisiert und erreichen den Server nicht mehr."
        }
        return text
    }

    @ViewBuilder
    private func warningSection(_ store: TenantStore) -> some View {
        let pending = store.outbox.count
        let rejected = store.rejectedOps.count
        if pending > 0 || rejected > 0 {
            Section {
                if pending > 0 {
                    Label("\(pending) Änderung(en) noch nicht synchronisiert. Vorher synchronisieren, damit "
                          + "sie auf dem Server ankommen.", systemImage: "icloud.and.arrow.up")
                        .foregroundStyle(Color.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task { await store.sync() }
                    } label: {
                        HStack {
                            Text("Jetzt synchronisieren")
                            if store.isSyncing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(store.isSyncing)
                }
                if rejected > 0 {
                    Label("\(rejected) Änderung(en) vom Server abgelehnt.", systemImage: "exclamationmark.icloud")
                        .foregroundStyle(Color.dangerText)
                }
            } header: {
                Text("Ausstehend")
            }
        }
    }

    private func switchNow() async {
        busy = true
        defer { busy = false }
        await settings.switchToLocal(copyCurrent: copyCurrent)
        dismiss()
    }
}

// MARK: Auf Server übertragen

/// Assistent Lokal → Server: Server → Anmelden → Ziel-Fahrzeugbuch → Zusammenfassung → Übertragen → Bericht.
@MainActor
struct MigrationWizardView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TenantStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuth

    enum Step: Int, CaseIterable {
        case server, login, target, summary, done

        var title: String {
            switch self {
            case .server: "Server"
            case .login: "Anmelden"
            case .target: "Fahrzeugbuch"
            case .summary: "Zusammenfassung"
            case .done: "Fertig"
            }
        }
    }

    @State private var step: Step
    @State private var url: String
    @State private var urlError: String?
    @State private var showScanner = false
    @State private var busy = false
    @State private var error: String?
    @State private var tenants: [TenantInfo]
    @State private var target: TenantInfo?
    @State private var result: MigrationResult?
    @State private var acknowledged = false
    @State private var backupURL: URL?
    @State private var askDiscard = false
    private let isPreview: Bool

    /// - Parameters: Vorschau (Demo): Schritt, Server und Fahrzeugbücher vorgeben – ohne Netzwerk.
    init(previewStep: Step? = nil, previewServer: String? = nil, previewTenants: [TenantInfo]? = nil) {
        _step = State(initialValue: previewStep ?? .server)
        _url = State(initialValue: previewServer ?? ModeUIState.shared.suggestedServer ?? "")
        _tenants = State(initialValue: previewTenants ?? [])
        let writableTenants = (previewTenants ?? []).filter { $0.canWrite || $0.isAdmin }
        _target = State(initialValue: previewStep == nil ? nil : writableTenants.first)
        isPreview = previewStep != nil
    }

    private var server: String? { ServerLink.serverURL(from: url) }
    private var host: String { ServerLink.host(server ?? url) }
    private var writable: [TenantInfo] { tenants.filter { $0.canWrite || $0.isAdmin } }
    private var hasChanges: Bool { busy || (step != .server && step != .done) }
    private var cancelTitle: String { step == .done ? "Fertig" : "Abbrechen" }

    var body: some View {
        NavigationStack {
            Form {
                progressSection
                switch step {
                case .server: serverStep
                case .login: loginStep
                case .target: targetStep
                case .summary: summaryStep
                case .done: doneStep
                }
            }
            .navigationTitle("Auf Server übertragen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(cancelTitle) {
                        if step == .done {
                            acknowledged = true
                            dismiss()
                        } else if hasChanges {
                            askDiscard = true
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(busy)
                }
            }
            .discardGuard(hasChanges: hasChanges, isAsking: $askDiscard)
            .sheet(isPresented: $showScanner) {
                ServerQRScannerView { s in
                    url = s
                    urlError = nil
                }
            }
            .errorAlert($error)
            .onDisappear {
                // Wechselt die App nach der Übertragung die Betriebsart, wird diese Ansicht abgebaut:
                // Bericht dann auf Ebene der Wurzelansicht zeigen.
                guard let result, !acknowledged, !settings.isLocal else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    ModeUIState.shared.presentReport = result
                }
            }
        }
    }

    // MARK: Fortschritt

    private var progressSection: some View {
        let total = Step.allCases.count - 1
        let index = min(step.rawValue + 1, total)
        let label: String = step == .done ? "Übertragung abgeschlossen" : "Schritt \(index) von \(total): \(step.title)"
        return Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.subheadline.weight(.semibold))
                ProgressView(value: Double(step == .done ? total : index), total: Double(total))
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: 1 Server

    @ViewBuilder
    private var serverStep: some View {
        Section {
            TextField("https://fahrzeugbuch.example.net", text: $url)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: url) { _, _ in urlError = nil }
            Button {
                showScanner = true
            } label: {
                Label("QR-Code scannen", systemImage: "qrcode.viewfinder")
            }
            if let urlError {
                Label(urlError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Color.warningText)
            }
        } header: {
            Text("Adresse deines Servers")
        } footer: {
            Text("Nur HTTPS. Die Adresse (oder einen QR-Code) erhältst du vom Betreiber deines Fahrzeugbuch-Servers.")
        }
        Section {
            Button {
                goToLogin()
            } label: {
                Text("Weiter").frame(maxWidth: .infinity).fontWeight(.semibold)
            }
            .disabled(url.trimmed.isEmpty)
        }
    }

    private func goToLogin() {
        guard let s = server else {
            urlError = "Bitte eine gültige HTTPS-Adresse eingeben."
            return
        }
        if s != settings.serverURL {
            if settings.auth.isLoggedIn { settings.auth.clearSession() }
            settings.auth.resetIssuerPin()
            settings.serverURL = s
        }
        step = .login
    }

    // MARK: 2 Anmelden

    @ViewBuilder
    private var loginStep: some View {
        Section {
            Text("Melde dich mit deinem Konto bei \(host) an. Die Person braucht ein Konto bei diesem Server.")
                .fixedSize(horizontal: false, vertical: true)
            if settings.auth.isLoggedIn {
                LabeledContent("Angemeldet als", value: settings.auth.userName ?? "–")
            }
        } header: {
            Text("Anmelden")
        }
        Section {
            if settings.auth.isLoggedIn {
                Button {
                    Task { await loadTenants() }
                } label: {
                    busyLabel("Weiter")
                }
                .disabled(busy)
            }
            Button {
                Task { await login() }
            } label: {
                busyLabel(settings.auth.isLoggedIn ? "Mit anderem Konto anmelden" : "Anmelden")
            }
            .disabled(busy || AppMode.isDemo)
            Button("Zurück") { step = .server }
                .disabled(busy)
        }
    }

    private func busyLabel(_ title: String) -> some View {
        HStack {
            Spacer()
            if busy { ProgressView() } else { Text(title).fontWeight(.semibold) }
            Spacer()
        }
    }

    private func login() async {
        busy = true
        defer { busy = false }
        do {
            if settings.auth.isLoggedIn { settings.auth.clearSession() }
            _ = try await settings.auth.login(server: settings.baseURL, session: webAuth)
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            return
        } catch {
            self.error = "Anmeldung fehlgeschlagen: \(error.userMessage)"
            return
        }
        await fetchTenants()
    }

    private func loadTenants() async {
        busy = true
        defer { busy = false }
        await fetchTenants()
    }

    /// API-Client für den Zielserver (im Lokalmodus liefert `settings.api` nur einen Platzhalter).
    private var serverAPI: APIClient {
        let base = settings.baseURL
        let auth = settings.auth
        return APIClient(baseURL: base) { force in
            try await auth.validAccessToken(server: base, forceRefresh: force)
        }
    }

    private func fetchTenants() async {
        do {
            let me: MeResponse = try await serverAPI.get("api/me")
            tenants = me.tenants
            target = writable.count == 1 ? writable.first : nil
            step = .target
        } catch {
            self.error = "Fahrzeugbücher nicht geladen: \(error.userMessage)"
        }
    }

    // MARK: 3 Ziel

    @ViewBuilder
    private var targetStep: some View {
        Section {
            if writable.isEmpty {
                Label("Dein Konto hat bei \(host) kein Fahrzeugbuch mit der Rolle «Bearbeiten» oder «Verwalten». "
                      + "Bitte die Verwalterin bzw. den Verwalter um Zugriff bitten.",
                      systemImage: "person.2.slash")
                    .foregroundStyle(Color.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(writable) { t in
                targetRow(t)
            }
        } header: {
            Text("Ziel-Fahrzeugbuch")
        } footer: {
            Text(targetFooter)
        }
        Section {
            Button {
                step = .summary
            } label: {
                Text("Weiter").frame(maxWidth: .infinity).fontWeight(.semibold)
            }
            .disabled(target == nil)
            Button("Zurück") { step = .login }
        }
    }

    private func targetRow(_ t: TenantInfo) -> some View {
        let selected = target == t
        let icon: String = selected ? "largecircle.fill.circle" : "circle"
        let traits: AccessibilityTraits = selected ? .isSelected : []
        return Button {
            target = t
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(Color.infoText)
                    .accessibilityHidden(true)
                Label(t.slug, systemImage: "book.closed")
                Spacer()
                RoleTag(role: t.role)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(t.slug), Rolle \(RoleText.label(t.role))")
        .accessibilityAddTraits(traits)
        .accessibilityAddTraits(.isButton)
    }

    private var targetFooter: String {
        let readOnly = tenants.count - writable.count
        var text = "Nur Fahrzeugbücher, in denen du bearbeiten oder verwalten darfst."
        if readOnly > 0 { text += " \(readOnly) weitere(s) nur lesend – nicht wählbar." }
        return text
    }

    // MARK: 4 Zusammenfassung

    private struct CountRow: Identifiable {
        let label: String
        let icon: String
        let count: Int
        var id: String { label }
    }

    private var counts: [CountRow] {
        let vehicles = store.vehicleList
        var trips = 0, fuel = 0, maintenance = 0, odometer = 0
        for v in vehicles {
            trips += store.trips(for: v.id).count
            fuel += store.fuel(for: v.id).count
            maintenance += store.maintenance(for: v.id).count
            odometer += store.odometer(for: v.id).count
        }
        return [
            CountRow(label: "Fahrzeuge", icon: "car.side", count: vehicles.count),
            CountRow(label: "Fahrten", icon: "car", count: trips),
            CountRow(label: "Tankvorgänge", icon: "fuelpump", count: fuel),
            CountRow(label: "Wartungen", icon: "wrench.and.screwdriver", count: maintenance),
            CountRow(label: "Kilometerstände", icon: "gauge.with.dots.needle.67percent", count: odometer),
            CountRow(label: "Orte", icon: "mappin.and.ellipse", count: store.placeList.count),
            CountRow(label: "Kunden", icon: "person.2", count: store.customerList.count),
            CountRow(label: "Regeln", icon: "wand.and.stars", count: store.allRules.count),
            CountRow(label: "Steuerparameter", icon: "percent", count: store.taxParamList.count),
            CountRow(label: "Materialstamm", icon: "shippingbox", count: store.articles(for: nil).count),
        ]
    }

    @ViewBuilder
    private var summaryStep: some View {
        Section {
            LabeledContent("Server", value: host)
            LabeledContent("Fahrzeugbuch", value: target?.slug ?? "–")
            if let t = target {
                LabeledContent("Deine Rolle") { RoleTag(role: t.role) }
            }
            LabeledContent("Angemeldet als", value: settings.auth.userName ?? "–")
        } header: {
            Text("Ziel")
        }
        Section {
            ForEach(counts) { c in
                LabeledContent {
                    Text("\(c.count)").monospacedDigit()
                } label: {
                    Label(c.label, systemImage: c.icon)
                }
            }
        } header: {
            Text("Wird übertragen")
        } footer: {
            Text("Die Einträge kommen zu den vorhandenen Daten in «\(target?.slug ?? "–")» hinzu und werden dort im "
                 + "Änderungsprotokoll vermerkt. GPS-Tracks und die Koordinaten des Wohnorts bleiben auf diesem iPhone. "
                 + "Was der Server nicht übernimmt, steht danach im Bericht.")
        }
        Section {
            Button {
                Task { await exportBackup() }
            } label: {
                Label("Vorher Datensicherung exportieren", systemImage: "square.and.arrow.up.on.square")
            }
            .disabled(busy)
            if let backupURL {
                ShareLink(item: backupURL) {
                    Label("Sicherung teilen / in Dateien sichern", systemImage: "square.and.arrow.up")
                }
            }
        } footer: {
            Text("Empfohlen: So kannst du jederzeit zum heutigen Stand zurück.")
        }
        Section {
            Button {
                Task { await migrate() }
            } label: {
                HStack {
                    Spacer()
                    if busy {
                        ProgressView()
                        Text("Wird übertragen …")
                    } else {
                        Text("Jetzt übertragen").fontWeight(.semibold)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || target == nil || AppMode.isDemo)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            Button("Zurück") { step = .target }
                .disabled(busy)
        } footer: {
            Text("Nach erfolgreicher Übertragung arbeitet die App mit dem Server (Betriebsart «Mit Server»).")
        }
    }

    private func exportBackup() async {
        busy = true
        defer { busy = false }
        do {
            backupURL = try LocalBackup.exportBackup(store: store)
        } catch {
            self.error = "Sicherung nicht erstellt: \(error.userMessage)"
        }
    }

    private func migrate() async {
        guard let t = target, !isPreview else { return }
        busy = true
        defer { busy = false }
        do {
            let report = try await settings.migrateLocalToServer(target: t)
            let r = MigrationResult(report: report, target: t.slug)
            result = r
            step = .done
            // Die App wechselt dabei in den Servermodus und baut die Ansichten neu auf → Bericht an der Wurzel zeigen
            if !settings.isLocal {
                acknowledged = true
                ModeUIState.shared.presentReport = r
            }
        } catch {
            let text = "Übertragung fehlgeschlagen: \(error.userMessage)"
            if settings.isLocal {
                self.error = text
            } else {
                settings.loginNotice = text + " Die lokalen Daten sind unverändert auf diesem iPhone gespeichert."
            }
        }
    }

    // MARK: 5 Fertig

    @ViewBuilder
    private var doneStep: some View {
        if let result {
            MigrationReportSections(report: result.report, target: result.target)
        } else {
            Section {
                Label("Übertragung abgeschlossen.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.successText)
            }
        }
    }
}

/// Bericht der Übertragung (Anzahl je Objekttyp, abgelehnte Einträge, Hinweise).
struct MigrationReportSections: View {
    let report: MigrationReport
    let target: String

    var body: some View {
        let pairs = Present.pairs(report.counts)
        let rejected = report.rejected.count
        let rejectedList = Present.lines(report.rejected)
        let notes = Present.lines(report.notes)
        let pending = report.pending
        let pendingText: String = pending == 1 ? "1 Änderung wird bei der nächsten Verbindung übertragen."
            : "\(pending) Änderungen werden bei der nächsten Verbindung übertragen."
        let headline: String = rejected == 0 ? "Alles übertragen" : "Übertragen – mit Ausnahmen"
        let headIcon: String = rejected == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        let rejectedText: String = rejected == 1 ? "1 Eintrag wurde vom Server abgelehnt."
            : "\(rejected) Einträge wurden vom Server abgelehnt."
        Section {
            Label(headline, systemImage: headIcon)
                .foregroundStyle(rejected == 0 ? Color.successText : Color.warningText)
                .font(.headline)
            LabeledContent("Fahrzeugbuch", value: target)
        }
        if !pairs.isEmpty {
            Section {
                ForEach(Array(pairs.enumerated()), id: \.offset) { item in
                    LabeledContent(item.element.0) {
                        Text("\(item.element.1)").monospacedDigit()
                    }
                }
            } header: {
                Text("Übertragen")
            }
        }
        if rejected > 0 {
            Section {
                Label(rejectedText, systemImage: "exclamationmark.icloud")
                    .foregroundStyle(Color.dangerText)
                ForEach(Array(rejectedList.prefix(20).enumerated()), id: \.offset) { item in
                    Text(item.element)
                        .font(.footnote)
                        .foregroundStyle(Color.neutralText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                Text("Abgelehnte Einträge findest du unter Einstellungen › Abgelehnte Änderungen.")
            }
        }
        if pending > 0 {
            Section {
                Label(pendingText, systemImage: "icloud.and.arrow.up")
                    .foregroundStyle(Color.warningText)
            }
        }
        if !notes.isEmpty {
            Section {
                ForEach(notes, id: \.self) { n in
                    Label(n, systemImage: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(Color.neutralText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Hinweise")
            }
        }
    }
}

enum BackupText {
    /// „Sicherung importiert: 245 Einträge, 3 Beleg(e). Stand …“
    static func imported(_ s: BackupSummary) -> String {
        var text = "Sicherung importiert: \(s.totalObjects) Einträge, \(s.attachments) Beleg(e)."
        if let created = Present.date(s.createdAt) { text += " Stand \(Fmt.dateTime(created))." }
        if !s.warnings.isEmpty { text += " " + s.warnings.joined(separator: " ") }
        return text
    }
}

/// Bericht als eigenes Blatt (nach dem Wechsel der Betriebsart).
struct MigrationReportView: View {
    let result: MigrationResult

    var body: some View {
        Form {
            MigrationReportSections(report: result.report, target: result.target)
        }
        .navigationTitle("Übertragung")
        .navigationBarTitleDisplayMode(.inline)
    }
}
