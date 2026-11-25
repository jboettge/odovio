import SwiftUI

// MARK: Darstellungshilfen (robust gegenüber optionalen/nicht optionalen Feldern)

/// Kleine Hilfen für die Anzeige von Server-Antworten (Mitglieder, Aktivität, Berichte).
/// Die Überladungen erlauben, dass ein Feld `String` oder `String?` (bzw. `Int`/`Int?` …) ist.
enum Present {
    static func text(_ v: String) -> String? { v.nilIfEmpty }
    static func text(_ v: String?) -> String? { v?.nilIfEmpty }

    static func int(_ v: Int) -> Int? { v }
    static func int(_ v: Int?) -> Int? { v }

    static func count(_ v: Int) -> Int { v }
    static func count(_ v: Int?) -> Int { v ?? 0 }
    static func count<C: Collection>(_ c: C) -> Int { c.count }
    static func count<C: Collection>(_ c: C?) -> Int { c?.count ?? 0 }

    static func lines(_ v: [String]) -> [String] { v.compactMap { $0.nilIfEmpty } }
    static func lines(_ v: [String]?) -> [String] { (v ?? []).compactMap { $0.nilIfEmpty } }
    static func lines(_ v: String) -> [String] { v.nilIfEmpty.map { [$0] } ?? [] }
    static func lines(_ v: String?) -> [String] { v?.nilIfEmpty.map { [$0] } ?? [] }

    /// Anzahl je Objekttyp (z. B. `["trip": 120]`), sortiert nach Bezeichnung.
    static func pairs(_ v: [String: Int]) -> [(String, Int)] {
        v.map { (EntityText.plural($0.key), $0.value) }.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }
    static func pairs(_ v: [String: Int]?) -> [(String, Int)] { pairs(v ?? [:]) }
    static func pairs(_ v: Int) -> [(String, Int)] { [("Einträge", v)] }

    static func date(_ v: Date) -> Date? { v }
    static func date(_ v: Date?) -> Date? { v }
    static func date(_ v: String) -> Date? { parseISO(v) }
    static func date(_ v: String?) -> Date? { v.flatMap { parseISO($0) } }

    /// ISO-8601 mit/ohne Sekundenbruchteile, sonst Tagesdatum.
    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        return APIClient.dayFormatter.date(from: s)
    }

    /// „vor 5 Minuten“, „gestern“ …
    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }
}

// MARK: Rollen

/// Einheitliche Rollenbezeichnungen: admin → „Verwalten“, write → „Bearbeiten“, read → „Nur lesen“.
enum RoleText {
    static func label(_ role: String?) -> String {
        switch role ?? "" {
        case "admin": "Verwalten"
        case "write": "Bearbeiten"
        case "read": "Nur lesen"
        default: "Ohne Rolle"
        }
    }

    static func icon(_ role: String?) -> String {
        switch role ?? "" {
        case "admin": "person.badge.key"
        case "write": "pencil"
        case "read": "eye"
        default: "person"
        }
    }

    static func color(_ role: String?) -> Color {
        switch role ?? "" {
        case "admin": .purpleText
        case "write": .infoText
        default: .neutralText
        }
    }
}

/// Rolle als Etikett (Text + Symbol).
struct RoleTag: View {
    let role: String?

    var body: some View {
        StatusTag(text: RoleText.label(role), color: RoleText.color(role), systemImage: RoleText.icon(role))
            .accessibilityLabel("Rolle: \(RoleText.label(role))")
    }
}

// MARK: Objekttypen

enum EntityText {
    static func icon(_ entity: String) -> String {
        switch entity {
        case "trip", "trip_period": "car"
        case "fuel": "fuelpump"
        case "maintenance", "maintenance_item", "maintenance_material": "wrench.and.screwdriver"
        case "odometer": "gauge.with.dots.needle.67percent"
        case "vehicle": "car.side"
        case "attachment": "doc.viewfinder"
        case "place": "mappin.and.ellipse"
        case "customer": "person.2"
        case "purpose_rule": "wand.and.stars"
        case "tax_param": "percent"
        case "material_article": "shippingbox"
        default: "doc"
        }
    }

    static func plural(_ entity: String) -> String {
        switch entity {
        case "vehicle", "vehicles": "Fahrzeuge"
        case "trip", "trips": "Fahrten"
        case "trip_period", "trip_periods": "Monatsabschlüsse"
        case "fuel": "Tankvorgänge"
        case "odometer": "Kilometerstände"
        case "maintenance": "Wartungen"
        case "maintenance_item", "maintenance_items": "Checklistenpunkte"
        case "maintenance_material", "maintenance_materials": "Materialpositionen"
        case "material_article", "material_articles": "Stammartikel"
        case "attachment", "attachments": "Belege"
        case "place", "places": "Orte"
        case "customer", "customers": "Kunden"
        case "purpose_rule", "purpose_rules": "Regeln"
        case "tax_param", "tax_params": "Steuerparameter"
        default: entity
        }
    }

    static func action(_ action: String) -> String {
        switch action {
        case "create": "erfasst"
        case "update": "geändert"
        case "delete": "storniert"
        default: action
        }
    }
}

// MARK: Webfrontend

/// Verwaltung (Mitglieder/Rollen, Steuerparameter) erfolgt im Webfrontend des Servers.
enum WebFrontend {
    static let membersPath = "verwaltung/mitglieder"
    static let taxParamsPath = "stammdaten/steuerparameter"
}

/// Knopf „Im Webfrontend …“ (öffnet Safari).
struct WebFrontendButton: View {
    @Environment(AppSettings.self) private var settings
    let title: String
    let path: String

    var body: some View {
        if let url = settings.webURL(path: path) {
            Link(destination: url) {
                Label(title, systemImage: "safari")
            }
            .accessibilityHint("Öffnet \(url.host() ?? "den Server") in Safari")
        }
    }
}

// MARK: Erfasst von

enum Authorship {
    /// „von Anna“, wenn jemand anders den Eintrag erfasst hat (nur im Servermodus).
    @MainActor
    static func foreign(_ createdBy: String?, settings: AppSettings) -> String? {
        guard !settings.isLocal, let by = createdBy?.nilIfEmpty else { return nil }
        let mine = [settings.auth.userName, settings.displayName].compactMap { $0?.nilIfEmpty }
        if mine.contains(where: { $0.caseInsensitiveCompare(by) == .orderedSame }) { return nil }
        return "von \(by)"
    }

    /// „Erfasst von Anna · zuletzt geändert von Jakob“
    static func detail(createdBy: String?, updatedBy: String?) -> String? {
        var parts: [String] = []
        if let c = createdBy?.nilIfEmpty { parts.append("Erfasst von \(c)") }
        if let u = updatedBy?.nilIfEmpty, u != createdBy?.nilIfEmpty || parts.isEmpty {
            parts.append(parts.isEmpty ? "Zuletzt geändert von \(u)" : "zuletzt geändert von \(u)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Dezenter Hinweis „von <Name>“ in Listenzeilen.
struct AuthorNote: View {
    @Environment(AppSettings.self) private var settings
    let createdBy: String?

    var body: some View {
        if let text = Authorship.foreign(createdBy, settings: settings) {
            Label(text, systemImage: "person")
                .font(.footnote)
                .foregroundStyle(Color.neutralText)
                .labelStyle(.titleAndIcon)
        }
    }
}

/// Abschnitt „Erfasst von X · zuletzt geändert von Y“ in Detail-/Formularansichten (nur Servermodus).
struct AuthorshipSection: View {
    @Environment(AppSettings.self) private var settings
    let createdBy: String?
    let updatedBy: String?

    var body: some View {
        if !settings.isLocal, let text = Authorship.detail(createdBy: createdBy, updatedBy: updatedBy) {
            Section {
                Label(text, systemImage: "person.2")
                    .font(.subheadline)
                    .foregroundStyle(Color.neutralText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: Mitglieder

/// Mitglieder des Fahrzeugbuchs (nur lesend; Verwaltung im Webfrontend).
@MainActor
struct MembersView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TenantStore.self) private var store
    private let preview: MembersResponse?

    @State private var response: MembersResponse?
    @State private var loading = false
    @State private var error: String?

    init(preview: MembersResponse? = nil) {
        self.preview = preview
        _response = State(initialValue: preview)
    }

    private var isAdmin: Bool { store.tenant.isAdmin }

    var body: some View {
        List {
            if let error {
                Section {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .font(.subheadline)
                        .foregroundStyle(Color.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let r = response {
                Section {
                    ForEach(sorted(r.members), id: \.id) { m in
                        memberRow(m)
                    }
                } header: {
                    Text(r.members.count == 1 ? "1 Person" : "\(r.members.count) Personen")
                } footer: {
                    Text("Rollen: Verwalten (Mitglieder und Einstellungen), Bearbeiten (erfassen und ändern), "
                         + "Nur lesen (ansehen).")
                }
                manageSection(r)
            }
        }
        .overlay {
            if response == nil {
                if loading {
                    ProgressView("Lade Mitglieder …")
                } else if error == nil {
                    ContentUnavailableView("Keine Mitglieder", systemImage: "person.2.slash")
                }
            }
        }
        .navigationTitle("Mitglieder")
        .refreshable { await load() }
        .task {
            if preview == nil && response == nil { await load() }
        }
    }

    private func sorted(_ list: [Member]) -> [Member] {
        list.sorted { a, b in
            displayName(a).localizedStandardCompare(displayName(b)) == .orderedAscending
        }
    }

    private func displayName(_ m: Member) -> String {
        Present.text(m.name) ?? Present.text(m.username) ?? "Unbekannt"
    }

    private func isMe(_ m: Member) -> Bool {
        guard let me = settings.auth.userName?.nilIfEmpty, let user = Present.text(m.username) else { return false }
        return me.caseInsensitiveCompare(user) == .orderedSame
    }

    private func memberRow(_ m: Member) -> some View {
        let name = displayName(m)
        let user = Present.text(m.username)
        let email = Present.text(m.email)
        let last = Present.date(m.lastActivityAt)
        let lastText: String = last.map { "Zuletzt aktiv " + Present.relative($0) } ?? "Noch keine Aktivität"
        let me = isMe(m)
        var spoken = [name]
        if me { spoken.append("du") }
        if let user, user != name { spoken.append("Benutzername \(user)") }
        spoken.append("Rolle \(RoleText.label(m.role))")
        spoken.append(lastText)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: me ? "person.crop.circle.fill" : "person.crop.circle")
                .font(.title2)
                .foregroundStyle(Color.infoText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name).font(.headline)
                    if me {
                        Text("(du)").font(.subheadline).foregroundStyle(Color.neutralText)
                    }
                }
                if let user, user != name {
                    Text(user).font(.subheadline).foregroundStyle(Color.neutralText)
                }
                if let email {
                    Text(email).font(.footnote).foregroundStyle(Color.neutralText)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        RoleTag(role: m.role)
                        Text(lastText).font(.footnote).foregroundStyle(Color.neutralText)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        RoleTag(role: m.role)
                        Text(lastText).font(.footnote).foregroundStyle(Color.neutralText)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken.joined(separator: ", "))
    }

    @ViewBuilder
    private func manageSection(_ r: MembersResponse) -> some View {
        Section {
            if isAdmin && r.manageable {
                Label("Mitglieder einladen, Rollen ändern und entfernen kannst du als Verwalter im Webfrontend "
                      + "deines Servers.", systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(Color.neutralText)
                    .fixedSize(horizontal: false, vertical: true)
                WebFrontendButton(title: "Im Webfrontend verwalten", path: WebFrontend.membersPath)
            } else if !r.manageable {
                Label("Mitglieder werden vom Administrator in Keycloak verwaltet.", systemImage: "person.badge.key")
                    .font(.subheadline)
                    .foregroundStyle(Color.neutralText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Mitglieder und Rollen verwaltet eine Person mit der Rolle «Verwalten».",
                      systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(Color.neutralText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Verwaltung")
        }
    }

    private func load() async {
        guard !AppMode.isDemo else { return }
        loading = true
        defer { loading = false }
        do {
            response = try await store.fetchMembers()
            error = nil
        } catch {
            self.error = "Mitglieder nicht geladen: \(error.userMessage)"
        }
    }
}

// MARK: Aktivität

/// Gemeinsamer Aktivitäts-Feed (wer hat was wann geändert), nach Tag gruppiert.
@MainActor
struct ActivityView: View {
    @Environment(TenantStore.self) private var store
    private let preview: [ActivityItem]?

    @State private var items: [ActivityItem]
    @State private var nextBeforeSeq: Int?
    @State private var loaded: Bool
    @State private var loading = false
    @State private var error: String?
    @State private var vehicleFilter: String?

    init(vehicleId: String? = nil, preview: [ActivityItem]? = nil) {
        self.preview = preview
        _items = State(initialValue: preview ?? [])
        _loaded = State(initialValue: preview != nil)
        _vehicleFilter = State(initialValue: vehicleId)
    }

    private struct Day: Identifiable {
        let date: Date
        let items: [ActivityItem]
        var id: Date { date }
    }

    private var filtered: [ActivityItem] {
        guard let v = vehicleFilter else { return items }
        return items.filter { item in
            item.vehicleId == v || (item.entity == Vehicle.entityName && item.entityId == v)
        }
    }

    private var days: [Day] {
        let cal = Calendar.current
        var groups: [Date: [ActivityItem]] = [:]
        for item in filtered {
            let d = Present.date(item.at) ?? Date.distantPast
            groups[cal.startOfDay(for: d), default: []].append(item)
        }
        return groups.keys.sorted(by: >).map { key in
            Day(date: key, items: (groups[key] ?? []).sorted { $0.seq > $1.seq })
        }
    }

    private var emptyText: String {
        vehicleFilter == nil ? "Noch keine Änderungen im Fahrzeugbuch." : "Keine Änderungen zu diesem Fahrzeug geladen."
    }

    private var filterTitle: String {
        guard let v = vehicleFilter else { return "Alle Fahrzeuge" }
        return store.vehicle(id: v)?.name ?? "Fahrzeug"
    }

    var body: some View {
        List {
            if let error {
                Section {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .font(.subheadline)
                        .foregroundStyle(Color.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(days) { day in
                Section {
                    ForEach(day.items, id: \.seq) { item in
                        row(item)
                    }
                } header: {
                    Text(dayTitle(day.date))
                }
            }
            if nextBeforeSeq != nil {
                Section {
                    Button {
                        Task { await loadMore() }
                    } label: {
                        HStack {
                            Label("Ältere Aktivität laden", systemImage: "clock.arrow.circlepath")
                            if loading { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(loading)
                }
            }
        }
        .overlay {
            if filtered.isEmpty {
                if loading && !loaded {
                    ProgressView("Lade Aktivität …")
                } else if loaded {
                    ContentUnavailableView("Keine Aktivität", systemImage: "clock",
                                           description: Text(emptyText))
                }
            }
        }
        .navigationTitle("Aktivität")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Fahrzeug", selection: $vehicleFilter) {
                        Text("Alle Fahrzeuge").tag(String?.none)
                        ForEach(store.vehicleList) { v in
                            Text(v.name).tag(String?.some(v.id))
                        }
                    }
                } label: {
                    Label(filterTitle, systemImage: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Nach Fahrzeug filtern, aktuell \(filterTitle)")
            }
        }
        .refreshable { await reload() }
        .task {
            if preview == nil && !loaded { await reload() }
        }
    }

    private func row(_ item: ActivityItem) -> some View {
        let actor = Present.text(item.actorName) ?? "Unbekannt"
        let summary = Present.text(item.summary) ?? EntityText.action(item.action)
        let date = Present.date(item.at)
        let time: String = date.map { Fmt.time($0) } ?? ""
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: EntityText.icon(item.entity))
                .foregroundStyle(item.action == "delete" ? Color.dangerText : Color.infoText)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(actor).fontWeight(.semibold).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(time)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Color.neutralText)
                }
                Text(summary)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if vehicleFilter == nil, let vid = item.vehicleId, let v = store.vehicle(id: vid) {
                    Text(v.name).font(.footnote).foregroundStyle(Color.neutralText)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(time), \(actor): \(summary)")
    }

    private func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.component(.year, from: d) < 1971 { return "Ohne Datum" }
        if cal.isDateInToday(d) { return "Heute" }
        if cal.isDateInYesterday(d) { return "Gestern" }
        return d.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    private func reload() async {
        guard !AppMode.isDemo else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await store.fetchActivity(beforeSeq: nil)
            items = page.items
            nextBeforeSeq = page.nextBeforeSeq
            error = nil
        } catch {
            self.error = "Aktivität nicht geladen (offline?): \(error.userMessage)"
        }
        loaded = true
    }

    private func loadMore() async {
        guard !AppMode.isDemo, let before = nextBeforeSeq else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await store.fetchActivity(beforeSeq: before)
            let known = Set(items.map(\.seq))
            items += page.items.filter { !known.contains($0.seq) }
            nextBeforeSeq = page.nextBeforeSeq
            error = nil
        } catch {
            self.error = "Weitere Aktivität nicht geladen: \(error.userMessage)"
        }
    }
}

// MARK: Gemeinsam (Fahrzeugliste)

/// Menü „Mitglieder / Aktivität“ in der Fahrzeugliste (nur Servermodus).
struct SharedMenu: View {
    @Environment(AppSettings.self) private var settings
    @Binding var route: SharedRoute?

    var body: some View {
        let caps = settings.capabilities
        if caps.members || caps.activity {
            Menu {
                if caps.members {
                    Button { route = .members } label: { Label("Mitglieder", systemImage: "person.2") }
                }
                if caps.activity {
                    Button { route = .activity } label: { Label("Aktivität", systemImage: "clock.arrow.circlepath") }
                }
            } label: {
                Image(systemName: "person.2")
            }
            .accessibilityLabel("Gemeinsam: Mitglieder und Aktivität")
        }
    }
}

enum SharedRoute: String, Identifiable {
    case members, activity
    var id: String { rawValue }

    @MainActor @ViewBuilder var view: some View {
        switch self {
        case .members: ModalNavigation { MembersView() }
        case .activity: ModalNavigation { ActivityView() }
        }
    }
}

/// Leiste „Gemeinsam mit n Personen“ (wenn mehr als eine Person Zugriff hat).
struct SharedBanner: View {
    let memberCount: Int
    let onTap: () -> Void

    private var text: String {
        let others = max(memberCount - 1, 0)
        return others == 1 ? "Gemeinsam mit 1 Person" : "Gemeinsam mit \(others) Personen"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(Color.infoText)
                    .accessibilityHidden(true)
                Text(text).font(.subheadline)
                Spacer()
                Text("Mitglieder").font(.footnote).foregroundStyle(Color.infoText)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityHint("Zeigt die Mitglieder des Fahrzeugbuchs")
        .accessibilityAddTraits(.isButton)
    }
}
