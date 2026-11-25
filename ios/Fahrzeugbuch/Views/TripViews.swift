import SwiftUI

// MARK: Navigation

/// Ziele aus der Fahrtenliste (als Sheet mit eigenem NavigationStack).
enum TripRoute: String, Identifiable {
    case review, gaps, close, reports, places, customers, rules, taxParams
    var id: String { rawValue }
}

/// Tage für die Gruppierung der Fahrtenliste.
struct TripDay: Identifiable {
    let id: String
    let date: Date
    var trips: [Trip]

    var title: String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Heute" }
        if cal.isDateInYesterday(date) { return "Gestern" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// Gruppiert eine (neueste zuerst sortierte) Liste nach lokalem Starttag; Reihenfolge bleibt erhalten.
    static func group(_ list: [Trip]) -> [TripDay] {
        var days: [TripDay] = []
        var index: [String: Int] = [:]
        let cal = Calendar.current
        for t in list {
            let day = cal.startOfDay(for: t.startDate ?? Date.distantPast)
            let key = APIClient.dayFormatter.string(from: day)
            if let i = index[key] {
                days[i].trips.append(t)
            } else {
                index[key] = days.count
                days.append(TripDay(id: key, date: day, trips: [t]))
            }
        }
        return days
    }
}

// MARK: Fahrtenliste

/// Statusfilter der Fahrtenliste.
enum TripStatusFilter: String, CaseIterable, Identifiable {
    case all, open, confirmed, locked, estimated
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "Alle Status"
        case .open: "Zu bestätigen"
        case .confirmed: "Bestätigt"
        case .locked: "Abgeschlossen"
        case .estimated: "Kilometer geschätzt"
        }
    }

    func matches(_ t: Trip) -> Bool {
        switch self {
        case .all: true
        case .open: t.needsReview
        case .confirmed: t.status == "confirmed" && !t.needsReview
        case .locked: t.isLocked
        case .estimated: t.kmEstimated
        }
    }
}

/// Fahrten eines Fahrzeugs: Statuskarten, Start/Stopp, Fahrtenbuch-Funktionen, Suche/Filter, Liste nach Tag.
@MainActor
struct TripsListView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TenantStore.self) private var store
    @Environment(TripCoordinator.self) private var coordinator
    let vehicle: Vehicle

    @State private var form: EditTarget<Trip>?
    /// Kategorie, die das Formular vorbelegt (Wischen „Geschäftlich“ ohne Zweck)
    @State private var formPreset: TripCategory?
    @State private var toDelete: Trip?
    @State private var route: TripRoute?
    @State private var startPrivate = false
    @State private var search = ""
    @State private var categoryFilter: TripCategory?
    @State private var statusFilter: TripStatusFilter = .all
    @State private var monthFilter: String?
    @State private var showSetup = false
    @State private var startAfterSetup = false
    /// Wohnort-Hinweis in dieser Sitzung übersprungen
    @State private var homeDeclined = false
    @AppStorage(TripSetupKeys.seen) private var setupSeen = false

    init(vehicle: Vehicle) {
        self.vehicle = vehicle
    }

    private var filterActive: Bool {
        categoryFilter != nil || statusFilter != .all || monthFilter != nil || !search.trimmed.isEmpty
    }

    var body: some View {
        let all = store.trips(for: vehicle.id)
        let reviewCount = all.filter(\.needsReview).count
        let gaps = store.gaps(for: vehicle.id, month: nil)
        let list = filtered(all)
        let days = TripDay.group(list)
        List {
            if reviewCount > 0 || !gaps.isEmpty {
                Section {
                    TripStatusCards(reviewCount: reviewCount, gaps: gaps,
                                    onReview: { route = .review }, onGaps: { route = .gaps })
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            if store.canWrite {
                TripRecordingSection(vehicle: vehicle, startPrivate: $startPrivate,
                                     onStart: { requestStart() },
                                     onStopped: { t in form = EditTarget(value: t) })
            }
            logbookSection(reviewCount: reviewCount, gapCount: gaps.count)
            if !all.isEmpty {
                Section {
                    filterBar(Self.months(all))
                } footer: {
                    if filterActive {
                        Text(list.count == 1 ? "1 Fahrt gefunden" : "\(list.count) Fahrten gefunden")
                    }
                }
            }
            if list.isEmpty {
                Section {
                    Text(all.isEmpty ? emptyText : "Keine Fahrten für diese Suche bzw. diesen Filter.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(days) { day in
                Section {
                    ForEach(day.trips) { t in
                        tripRow(t)
                    }
                } header: {
                    Text(day.title)
                }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Ort, Zweck oder Kunde suchen")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Section("Stammdaten") {
                        Button { route = .places } label: { Label("Orte", systemImage: "mappin.and.ellipse") }
                        Button { route = .customers } label: { Label("Kunden", systemImage: "person.2") }
                        Button { route = .rules } label: { Label("Regeln", systemImage: "wand.and.stars") }
                        Button { route = .taxParams } label: { Label("Steuerparameter", systemImage: "percent") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Stammdaten des Fahrtenbuchs")
                if store.canWrite {
                    Button { form = EditTarget(value: nil) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Fahrt manuell erfassen")
                }
            }
        }
        .sheet(item: $form, onDismiss: { formPreset = nil }) { target in
            TripFormView(vehicle: vehicle, trip: target.value, presetCategory: formPreset)
        }
        .sheet(item: $route) { r in
            ModalNavigation { routeView(r) }
        }
        .sheet(isPresented: $showSetup, onDismiss: {
            if startAfterSetup {
                startAfterSetup = false
                beginRecording()
            }
        }) {
            NavigationStack {
                TripSetupView(continueTitle: "Fahrt starten", onContinue: {
                    homeDeclined = true
                    startAfterSetup = true
                })
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Abbrechen") { showSetup = false }
                    }
                }
            }
        }
        .reasonedStorno($toDelete, title: "Fahrt stornieren?",
                        message: { TripStorno.message($0) },
                        requiresReason: { store.requiresReason(for: $0) }) { trip, reason in
            store.delete(trip, reason: reason)
        }
        .refreshable { await store.sync() }
        .task {
            // Entwürfe mit Vorschlägen anreichern (Regel → Kalender → Muster → LLM); nie im Demo
            if !AppMode.isDemo && store.canWrite { await coordinator.applySuggestions() }
        }
    }

    private var emptyText: String {
        store.canWrite
            ? "Noch keine Fahrten. Mit «Fahrt starten» aufzeichnen oder mit + manuell erfassen."
            : "Noch keine Fahrten erfasst."
    }

    // MARK: Fahrtenbuch-Funktionen (sichtbar statt im Menü)

    private func logbookSection(reviewCount: Int, gapCount: Int) -> some View {
        let previous = TripMonth.previous()
        let previousClosed = store.isMonthClosed(vehicleId: vehicle.id, month: previous)
        let closeDetail: String = previousClosed
            ? "\(TripMonth.label(previous)) abgeschlossen"
            : "\(TripMonth.label(previous)) noch offen"
        return Section {
            logbookRow("Fahrten bestätigen", icon: "checklist",
                       detail: reviewCount == 0 ? "Alles bestätigt" : "\(reviewCount) offen",
                       highlight: reviewCount > 0) { route = .review }
            logbookRow("Lücken", icon: "point.topleft.down.to.point.bottomright.curvepath",
                       detail: gapCount == 0 ? "Keine" : (gapCount == 1 ? "1 Lücke" : "\(gapCount) Lücken"),
                       highlight: gapCount > 0) { route = .gaps }
            logbookRow("Monatsabschluss", icon: "lock.doc", detail: closeDetail,
                       highlight: !previousClosed && store.canWrite) { route = .close }
            logbookRow("Berichte & Export", icon: "chart.bar.doc.horizontal", detail: "PDF, CSV, Jahresbericht",
                       highlight: false) { route = .reports }
        } header: {
            Text("Fahrtenbuch")
        }
    }

    private func logbookRow(_ title: String, icon: String, detail: String, highlight: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(Color.infoText)
                    .frame(minWidth: 24)
                    .accessibilityHidden(true)
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text(title).foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Text(detail).foregroundStyle(highlight ? Color.warningText : Color.neutralText)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).foregroundStyle(.primary)
                        Text(detail).font(.footnote)
                            .foregroundStyle(highlight ? Color.warningText : Color.neutralText)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(detail)")
    }

    @ViewBuilder
    private func routeView(_ r: TripRoute) -> some View {
        switch r {
        case .review: TripReviewView(vehicle: vehicle)
        case .gaps: GapListView(vehicle: vehicle)
        case .close: MonthCloseView(vehicle: vehicle)
        case .reports: TripReportsView(vehicle: vehicle)
        case .places: PlacesView()
        case .customers: CustomersView()
        case .rules: RulesView()
        case .taxParams: TaxParamsView()
        }
    }

    // MARK: Suche / Filter / Monatssprung

    static func months(_ trips: [Trip]) -> [String] {
        Array(Set(trips.map(\.monthKey))).sorted(by: >)
    }

    private func filtered(_ all: [Trip]) -> [Trip] {
        let q = search.trimmed
        return all.filter { t in
            if let m = monthFilter, t.monthKey != m { return false }
            if let c = categoryFilter, t.categoryValue != c { return false }
            if !statusFilter.matches(t) { return false }
            if q.isEmpty { return true }
            let fields: [String] = [store.routeLabel(t), t.purpose ?? "", store.customerLabel(t) ?? "",
                                    t.note ?? "", t.categoryValue.uiLabel]
            return fields.contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    private func filterBar(_ months: [String]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                filterMenus(months)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                filterMenus(months)
            }
        }
    }

    @ViewBuilder
    private func filterMenus(_ months: [String]) -> some View {
        Menu {
            Picker("Monat", selection: $monthFilter) {
                Text("Alle Monate").tag(String?.none)
                ForEach(months, id: \.self) { m in
                    Text(TripMonth.label(m)).tag(String?.some(m))
                }
            }
        } label: {
            FilterChip(title: monthFilter.map { TripMonth.label($0) } ?? "Alle Monate", icon: "calendar",
                       active: monthFilter != nil)
        }
        .accessibilityLabel("Monat wählen")
        Menu {
            Picker("Kategorie", selection: $categoryFilter) {
                Text("Alle Kategorien").tag(TripCategory?.none)
                ForEach(TripCategory.allCases) { c in
                    Label(c.uiLabel, systemImage: c.systemImage).tag(TripCategory?.some(c))
                }
            }
        } label: {
            FilterChip(title: categoryFilter?.uiLabel ?? "Kategorie", icon: "line.3.horizontal.decrease.circle",
                       active: categoryFilter != nil)
        }
        .accessibilityLabel("Nach Kategorie filtern")
        Menu {
            Picker("Status", selection: $statusFilter) {
                ForEach(TripStatusFilter.allCases) { f in
                    Text(f.label).tag(f)
                }
            }
            if filterActive {
                Divider()
                Button("Filter zurücksetzen", role: .destructive) { resetFilters() }
            }
        } label: {
            FilterChip(title: statusFilter == .all ? "Status" : statusFilter.label, icon: "checkmark.circle",
                       active: statusFilter != .all)
        }
        .accessibilityLabel("Nach Status filtern")
    }

    private func resetFilters() {
        categoryFilter = nil
        statusFilter = .all
        monthFilter = nil
        search = ""
    }

    // MARK: Zeilen

    private func tripRow(_ t: Trip) -> some View {
        let closed = store.isMonthClosed(vehicleId: t.vehicleId, month: t.monthKey)
        let quick = store.canWrite && !t.isLocked && !closed
        let hint: String = (t.isLocked || !store.canWrite) ? "Ansehen" : "Bearbeiten"
        return Button { form = EditTarget(value: t) } label: {
            TripRow(trip: t, route: store.routeLabel(t), customer: store.customerLabel(t),
                    pending: store.isPending(t.id), author: Authorship.foreign(t.createdBy, settings: settings))
        }
        .buttonStyle(.plain)
        .accessibilityHint(hint)
        .swipeActions(edge: .trailing) {
            if store.canWrite {
                Button("Stornieren", role: .destructive) { toDelete = t }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if quick {
                Button { quickConfirm(t, .personal) } label: {
                    Label(TripCategory.personal.uiLabel, systemImage: TripCategory.personal.systemImage)
                }
                .tint(.gray)
                Button { quickConfirm(t, .business) } label: {
                    Label(TripCategory.business.uiLabel, systemImage: TripCategory.business.systemImage)
                }
                .tint(.orange)
            }
        }
    }

    /// Wischen: als privat/geschäftlich bestätigen; passender Vorschlag liefert Zweck/Kunde.
    /// Geschäftlich ohne Zweck/Kunde → Formular öffnen (U11).
    private func quickConfirm(_ t: Trip, _ category: TripCategory) {
        let matches = t.suggestionCategory == category.rawValue
        let purpose: String? = (matches && t.purpose == nil) ? t.suggestionPurpose : nil
        let customer: String? = (matches && t.customerId == nil) ? t.suggestionCustomerId : nil
        if category == .business && (t.purpose ?? purpose)?.nilIfEmpty == nil && (t.customerId ?? customer) == nil {
            formPreset = category
            form = EditTarget(value: t)
            return
        }
        store.confirm(t, as: category, purpose: purpose, customerId: customer)
    }

    // MARK: Start

    private func requestStart() {
        guard !AppMode.isDemo else { return }
        if !setupSeen || (coordinator.needsHomePlace && !homeDeclined) {
            showSetup = true
        } else {
            beginRecording()
        }
    }

    private func beginRecording() {
        guard !AppMode.isDemo else { return }
        let v = store.vehicle(id: vehicle.id) ?? vehicle
        let privateMode = startPrivate
        store.defaultVehicleId = v.id
        Task { await coordinator.start(vehicle: v, privateMode: privateMode) }
    }
}

/// Kleiner Filter-Knopf (Text + Symbol, aktiv hervorgehoben).
struct FilterChip: View {
    let title: String
    let icon: String
    let active: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).accessibilityHidden(true)
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2.weight(.bold)).accessibilityHidden(true)
        }
        .font(.subheadline.weight(active ? .semibold : .regular))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(active ? Color(uiColor: .systemBackground) : Color.infoText)
        .background(active ? Color.infoText : Color.infoText.opacity(0.10), in: Capsule())
    }
}

/// Start/Stopp und laufende Aufzeichnung (eigene View: die Live-Distanz zeichnet nur diesen Abschnitt neu).
@MainActor
struct TripRecordingSection: View {
    @Environment(TenantStore.self) private var store
    @Environment(TripCoordinator.self) private var coordinator
    let vehicle: Vehicle
    @Binding var startPrivate: Bool
    let onStart: () -> Void
    let onStopped: (Trip) -> Void

    var body: some View {
        Section {
            controls
            if coordinator.isRecording && coordinator.stopSuggested {
                Label("Das Fahrzeug steht seit einigen Minuten still – Fahrt beenden?",
                      systemImage: "parkingsign.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.warningText)
                Button {
                    stop()
                } label: {
                    Label("Fahrt jetzt beenden", systemImage: "stop.circle")
                }
            }
            if coordinator.isFinishing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Fahrt wird ausgewertet …").foregroundStyle(.secondary)
                }
            }
        } footer: {
            if let err = coordinator.lastError {
                Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(Color.warningText)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        if coordinator.isRecording {
            let here = coordinator.recordingVehicleId == nil || coordinator.recordingVehicleId == vehicle.id
            let title: String = here ? "Aufzeichnung läuft" : "Aufzeichnung läuft (anderes Fahrzeug)"
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    recordingInfo(title)
                    Spacer()
                    stopButton
                }
                VStack(alignment: .leading, spacing: 10) {
                    recordingInfo(title)
                    stopButton
                }
            }
            .foregroundStyle(.white)
            .listRowBackground(Color(red: 0.70, green: 0.11, blue: 0.10))
            .accessibilityElement(children: .contain)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    startButton
                    Spacer()
                    privateToggle
                }
                VStack(alignment: .leading, spacing: 10) {
                    startButton
                    privateToggle
                }
            }
        }
    }

    private func recordingInfo(_ title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "record.circle")
                .font(.title2)
                .symbolEffect(.pulse)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(recordingDetail).font(.subheadline.monospacedDigit())
            }
        }
    }

    private var stopButton: some View {
        Button {
            stop()
        } label: {
            Label("Stopp", systemImage: "stop.fill").font(.headline)
        }
        .buttonStyle(.borderedProminent)
        .tint(.white)
        .foregroundStyle(Color(red: 0.70, green: 0.11, blue: 0.10))
        .accessibilityLabel("Fahrt beenden")
    }

    private var startButton: some View {
        Button {
            onStart()
        } label: {
            Label("Fahrt starten", systemImage: "play.fill").font(.headline)
        }
        .buttonStyle(.borderedProminent)
        .disabled(AppMode.isDemo)
    }

    private var privateToggle: some View {
        Toggle(isOn: $startPrivate) {
            Label("Privatmodus", systemImage: "eye.slash")
        }
        .fixedSize()
        .accessibilityLabel("Privatmodus für die nächste Fahrt")
        .accessibilityHint("Speichert nur Zeit und Kilometer, keine Orte")
    }

    private var recordingDetail: String {
        var text = Fmt.kmD(coordinator.liveDistanceKm)
        if let since = coordinator.recordingStartedAt {
            text += " · seit \(Fmt.time(since))"
        }
        if coordinator.recordingPrivate { text += " · Privatmodus" }
        return text
    }

    private func stop() {
        Task {
            if let t = await coordinator.stop() {
                onStopped(store.trip(id: t.id) ?? t)
            }
        }
    }
}

/// Statuskarten „n zu bestätigen“ und „Lücke x km“.
struct TripStatusCards: View {
    let reviewCount: Int
    let gaps: [TripGap]
    let onReview: () -> Void
    let onGaps: () -> Void

    private var reviewText: String {
        reviewCount == 1 ? "1 zu bestätigen" : "\(reviewCount) zu bestätigen"
    }

    private var gapText: String {
        let km = gaps.reduce(0) { $0 + abs($1.km) }
        return gaps.count == 1 ? "Lücke \(Fmt.km(km))" : "\(gaps.count) Lücken · \(Fmt.km(km))"
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { cards }
            VStack(spacing: 10) { cards }
        }
    }

    @ViewBuilder
    private var cards: some View {
        if reviewCount > 0 {
            card(reviewText, "checklist", .warningText, action: onReview)
                .accessibilityHint("Fahrten der Reihe nach bestätigen")
        }
        if !gaps.isEmpty {
            card(gapText, "exclamationmark.triangle.fill", .dangerText, action: onGaps)
                .accessibilityHint("Lücken in der Kilometerkette anzeigen")
        }
    }

    private func card(_ title: String, _ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).accessibilityHidden(true)
                Text(title).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).accessibilityHidden(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

/// Zeile einer Fahrt: Kategorie-Balken, Zeit, Strecke, km, Status (Symbol + Text), Vorschlag.
struct TripRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let trip: Trip
    let route: String
    var customer: String?
    var pending = false
    /// „von Anna“, wenn eine andere Person die Fahrt erfasst hat (Servermodus)
    var author: String?

    private var timeText: String {
        guard let start = trip.startDate else { return "–" }
        var text = Fmt.time(start)
        if let end = trip.endDate { text += "–" + Fmt.time(end) }
        return text
    }

    private var kmText: String { KmText.distance(trip) }

    private var statusIcon: String {
        switch trip.status {
        case "confirmed": "checkmark.circle.fill"
        case "suggested": "questionmark.circle.fill"
        case "locked": "lock.fill"
        default: "pencil.circle"
        }
    }

    private var statusText: String {
        switch trip.status {
        case "confirmed": trip.needsReview ? "Offen" : "Bestätigt"
        case "suggested": "Vorschlag"
        case "locked": "Gesperrt"
        default: "Entwurf"
        }
    }

    private var statusColor: Color {
        switch trip.status {
        case "confirmed": .successText
        case "suggested": .warningText
        case "locked": .neutralText
        default: .neutralText
        }
    }

    private var suggestionText: String? {
        guard trip.needsReview, let s = trip.suggestionCategory else { return nil }
        var parts = ["Vorschlag: \(TripCategory.of(s).uiLabel)"]
        if let p = trip.suggestionPurpose?.nilIfEmpty { parts.append("«\(p)»") }
        parts.append(Trip.suggestionSourceLabel(trip.suggestionSource))
        return parts.joined(separator: " · ")
    }

    private var detailText: String {
        var parts = [trip.categoryValue.uiLabel]
        if let p = trip.purpose?.nilIfEmpty { parts.append(p) }
        if let customer, !customer.isEmpty { parts.append(customer) }
        if trip.source == "gap" { parts.append("Lücke") }
        return parts.joined(separator: " · ")
    }

    private var missingPurpose: Bool {
        let c = trip.categoryValue
        // Server verlangt für Geschäfts-/Aussendienstfahrten einen Zweck (Kunde allein genügt nicht)
        return (c == .business || c == .field) && trip.purpose?.nilIfEmpty == nil && !trip.isMaskedPrivate
    }

    private var spokenText: String {
        var parts = [timeText, route, kmText, trip.categoryValue.uiLabel, statusText]
        if let p = trip.purpose?.nilIfEmpty { parts.append("Zweck \(p)") }
        if let customer { parts.append("Kunde \(customer)") }
        if missingPurpose { parts.append("Zweck fehlt") }
        if trip.kmEstimated { parts.append("Kilometerstand geschätzt") }
        if let s = suggestionText { parts.append(s) }
        if trip.privateMode { parts.append("Privatmodus") }
        if pending { parts.append("noch nicht synchronisiert") }
        if let author { parts.append("erfasst \(author)") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        let cat = trip.categoryValue
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(cat.color)
                .frame(width: 4)
            Image(systemName: cat.systemImage)
                .foregroundStyle(cat.textColor)
                .frame(minWidth: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(timeText)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Color.neutralText)
                    if trip.privateMode {
                        Image(systemName: "eye.slash").font(.footnote).foregroundStyle(Color.neutralText)
                    }
                    if pending { PendingBadge() }
                    if let author {
                        Text(author)
                            .font(.footnote)
                            .foregroundStyle(Color.neutralText)
                            .lineLimit(1)
                    }
                }
                Text(route).fixedSize(horizontal: false, vertical: true)
                Text(detailText).font(.footnote).foregroundStyle(Color.neutralText)
                    .fixedSize(horizontal: false, vertical: true)
                if trip.kmEstimated || missingPurpose {
                    HStack(spacing: 6) {
                        if trip.kmEstimated {
                            StatusTag(text: "km geschätzt", color: .orange, systemImage: "gauge.with.dots.needle.33percent")
                        }
                        if missingPurpose {
                            StatusTag(text: "Zweck fehlt", color: .red, systemImage: "text.badge.xmark")
                        }
                    }
                }
                if let s = suggestionText {
                    Text(s).font(.footnote).foregroundStyle(Color.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if typeSize.isAccessibilitySize {
                    HStack(spacing: 10) {
                        Text(kmText).font(.subheadline.monospacedDigit().weight(.semibold))
                        statusLabel
                    }
                }
            }
            if !typeSize.isAccessibilitySize {
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(kmText).font(.subheadline.monospacedDigit().weight(.semibold))
                    statusLabel
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenText)
    }

    private var statusLabel: some View {
        Label(statusText, systemImage: statusIcon)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(statusColor)
    }
}

enum TripStorno {
    static func message(_ trip: Trip) -> String {
        if trip.isLocked {
            return "Die Fahrt gehört zu einem abgeschlossenen Monat. Die Stornierung braucht eine Begründung und "
                + "wird im Änderungsprotokoll und im Fahrtenbuch als Korrektur sichtbar."
        }
        return "Die Fahrt wird als storniert markiert und bleibt im Änderungsprotokoll erhalten."
    }
}

// MARK: Formular

/// Fahrt erfassen/bearbeiten. `trip` kann auch eine noch nicht gespeicherte Vorlage sein (z. B. aus einer Lücke).
@MainActor
struct TripFormView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TenantStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let vehicle: Vehicle
    let trip: Trip?

    @State private var startDate = Date().addingTimeInterval(-1800)
    @State private var endDate = Date()
    @State private var hasEnd = true
    @State private var kmStart = ""
    @State private var kmEnd = ""
    @State private var startPlaceId: String?
    @State private var startLabel = ""
    @State private var endPlaceId: String?
    @State private var endLabel = ""
    @State private var category: TripCategory = .unknown
    @State private var purpose = ""
    @State private var customerId: String?
    @State private var privateMode = false
    @State private var confirmed = true
    @State private var note = ""
    @State private var didPrefill = false
    @State private var showSplit = false
    @State private var stornoTarget: Trip?
    /// km-Stände aus GPS geschätzt (Vorbelegung); manuelle Änderung = abgelesen
    @State private var kmEstimated = false
    @State private var prefilledKmStart = ""
    @State private var prefilledKmEnd = ""
    @State private var initial = ""
    @State private var askDiscard = false

    /// Kategorie vorbelegen (z. B. nach Wischen „Geschäftlich“, wenn der Zweck fehlt)
    let presetCategory: TripCategory?

    init(vehicle: Vehicle, trip: Trip?, presetCategory: TripCategory? = nil) {
        self.vehicle = vehicle
        self.trip = trip
        self.presetCategory = presetCategory
    }

    // MARK: Zustand

    private var stored: Trip? {
        guard let id = trip?.id else { return nil }
        return store.trip(id: id)
    }

    private var isNew: Bool { stored == nil }
    private var locked: Bool { stored?.isLocked ?? false }
    private var editable: Bool { store.canWrite && !locked }
    private var monthKey: String { TripMonth.key(startDate) }
    private var monthClosed: Bool { store.isMonthClosed(vehicleId: vehicle.id, month: monthKey) }
    /// Änderung/Neuerfassung in einem abgeschlossenen Monat → Korrekturbegründung (≥ 10 Zeichen)
    private var noteRequired: Bool {
        guard !locked else { return false }
        if monthClosed { return true }
        let probe = Trip(vehicleId: vehicle.id, startAt: Trip.isoString(startDate))
        if store.requiresReason(for: probe) { return true }
        return stored.map { store.requiresReason(for: $0) } ?? false
    }

    /// Kilometer weiterhin geschätzt (Vorbelegung unverändert und nicht als abgelesen markiert)
    private var stillEstimated: Bool {
        kmEstimated && kmStart == prefilledKmStart && kmEnd == prefilledKmEnd
    }

    /// Abweichung Kilometerstand Ende gegenüber der GPS-Schätzung
    private var estimateDeviation: Int? {
        guard let a = prefilledKmEnd.asInt, let b = kmEndValue else { return nil }
        return b - a
    }

    private var distanceText: String {
        guard let d = distance else { return "–" }
        return stillEstimated ? "ca. " + Fmt.km(d) : Fmt.km(d)
    }

    private var snapshot: String {
        FormSnapshot.make([FormSnapshot.date(startDate), FormSnapshot.date(endDate), String(hasEnd), kmStart, kmEnd,
                           startPlaceId ?? "", startLabel, endPlaceId ?? "", endLabel, category.rawValue, purpose,
                           customerId ?? "", String(privateMode), String(confirmed), note, String(kmEstimated)])
    }

    private var hasChanges: Bool { editable && didPrefill && snapshot != initial }

    private var kmStartValue: Int? { kmStart.asInt }
    private var kmEndValue: Int? { kmEnd.asInt }

    private var distance: Int? {
        guard let a = kmStartValue, let b = kmEndValue else { return nil }
        return b - a
    }

    private var previousTrip: Trip? {
        let own = trip?.id
        return store.trips(for: vehicle.id).first { t in
            t.id != own && (t.startDate ?? Date.distantPast) < startDate
        }
    }

    private var titleText: String {
        if isNew { return trip?.source == "gap" ? "Lücke erfassen" : "Neue Fahrt" }
        return editable ? "Fahrt bearbeiten" : "Fahrt"
    }

    private var cancelTitle: String { editable ? "Abbrechen" : "Fertig" }
    private var noteHeader: String { noteRequired ? "Korrekturbegründung" : "Notiz" }
    private var notePrompt: String { noteRequired ? "Pflicht: Grund der Korrektur (mind. 10 Zeichen)" : "optional" }
    private var needsPurpose: Bool {
        (category == .business || category == .field) && purpose.trimmed.isEmpty
    }

    // MARK: Validierung

    private var errors: [String] {
        var e: [String] = []
        if let d = distance, d < 0 { e.append("Kilometerstand Ende ist kleiner als Kilometerstand Beginn.") }
        if hasEnd && endDate < startDate { e.append("Das Ende liegt vor dem Start.") }
        if noteRequired && !CorrectionReason.isValid(note) {
            e.append("\(TripMonth.label(monthKey)) ist abgeschlossen – eine Korrekturbegründung "
                     + "(mind. \(CorrectionReason.minLength) Zeichen) ist Pflicht.")
        }
        if purpose.trimmed.count > Trip.maxPurpose { e.append("Zweck höchstens \(Trip.maxPurpose) Zeichen.") }
        if note.trimmed.count > Trip.maxNote { e.append("Notiz höchstens \(Trip.maxNote) Zeichen.") }
        if startLabel.trimmed.count > Trip.maxLabel || endLabel.trimmed.count > Trip.maxLabel {
            e.append("Ortsbezeichnung höchstens \(Trip.maxLabel) Zeichen.")
        }
        if !kmStart.trimmed.isEmpty && kmStartValue == nil { e.append("Kilometerstand Beginn ungültig.") }
        if !kmEnd.trimmed.isEmpty && kmEndValue == nil { e.append("Kilometerstand Ende ungültig.") }
        return e
    }

    /// Plausibilität – warnt, blockiert nicht.
    private var warnings: [String] {
        var w: [String] = []
        if let k = kmStartValue, let prev = previousTrip, let prevEnd = prev.kmEnd, prevEnd != k {
            let diff = k - prevEnd
            if diff > 0 {
                w.append("Lücke: Die vorherige Fahrt endete bei \(Fmt.km(prevEnd)) – \(Fmt.km(diff)) sind nicht erfasst.")
            } else {
                w.append("Überschneidung: Die vorherige Fahrt endete bereits bei \(Fmt.km(prevEnd)).")
            }
        }
        if kmStartValue == nil || kmEndValue == nil {
            w.append("Ohne Kilometerstand Beginn und Ende ist die Kilometerkette unvollständig.")
        }
        if stillEstimated {
            w.append("Kilometerstand aus GPS geschätzt – bitte Tacho ablesen. Geschätzte Werte verhindern den "
                     + "Monatsabschluss.")
        }
        if !hasEnd { w.append("Ohne Endzeit ist der Monatsabschluss nicht möglich.") }
        if let d = distance, d > 1500 { w.append("Distanz \(Fmt.km(d)) ungewöhnlich gross.") }
        if needsPurpose {
            w.append("\(category.uiLabel): Zweck angeben – sonst ist der Monatsabschluss nicht möglich.")
        }
        if category == .unknown { w.append("Ohne Kategorie bleibt die Fahrt ein Entwurf.") }
        return w
    }

    private var canSave: Bool { editable && errors.isEmpty }

    private var canSplit: Bool {
        guard let t = stored, editable, !monthClosed, let a = t.kmStart, let b = t.kmEnd else { return false }
        return b - a >= 2
    }

    // MARK: Ansicht

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Fahrzeug", value: vehicle.name)
                    if let t = stored ?? trip {
                        LabeledContent("Status", value: Trip.statusLabel(t.status))
                        LabeledContent("Quelle", value: Trip.sourceLabel(t.source))
                    }
                }

                Section("Zeit") {
                    DatePicker("Start", selection: $startDate)
                    Toggle("Fahrt beendet", isOn: $hasEnd)
                    if hasEnd {
                        DatePicker("Ende", selection: $endDate, in: startDate...)
                    }
                }
                .disabled(!editable)

                Section {
                    UnitField("Kilometerstand Beginn", text: $kmStart, unit: "km", keyboard: .numberPad)
                    UnitField("Kilometerstand Ende", text: $kmEnd, unit: "km", keyboard: .numberPad)
                    LabeledContent("Distanz", value: distanceText)
                    if kmEstimated && editable {
                        if stillEstimated {
                            Button {
                                kmEstimated = false
                            } label: {
                                Label("Tacho abgelesen – Werte stimmen", systemImage: "checkmark.circle")
                            }
                        } else if let deviation = estimateDeviation, deviation != 0 {
                            LabeledContent("Abweichung zur Schätzung", value: KmText.signed(deviation))
                        }
                    }
                    if let t = stored ?? trip, let gps = t.distanceGps {
                        LabeledContent("GPS-Distanz", value: Fmt.kmD(gps))
                    }
                    if let t = stored ?? trip, let routeKm = t.distanceRoute {
                        LabeledContent("Routendistanz", value: Fmt.kmD(routeKm))
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("Kilometer")
                        if stillEstimated {
                            StatusTag(text: "geschätzt", color: .orange, systemImage: "gauge.with.dots.needle.33percent")
                                .textCase(nil)
                        }
                    }
                } footer: {
                    if stillEstimated {
                        Text("Die Werte sind aus der GPS-Distanz geschätzt («ca.»). Massgebend ist der Kilometerstand "
                             + "laut Tacho – bitte ablesen und eintragen.")
                    } else {
                        Text("Massgebend ist der Kilometerstand laut Tacho; GPS und Route dienen nur der Kontrolle.")
                    }
                }
                .disabled(!editable)

                if !privateMode {
                    Section("Strecke") {
                        TripPlaceField(title: "Start", placeId: $startPlaceId, label: $startLabel)
                        TripPlaceField(title: "Ziel", placeId: $endPlaceId, label: $endLabel)
                    }
                    .disabled(!editable)
                }

                Section {
                    Picker("Kategorie", selection: $category) {
                        ForEach(TripCategory.allCases) { c in
                            Label(c.uiLabel, systemImage: c.systemImage).tag(c)
                        }
                    }
                    TextField("Zweck (z. B. Offerte Meier)", text: $purpose, axis: .vertical)
                    if needsPurpose {
                        Label("Zweck fehlt", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(Color.warningText)
                    }
                    CustomerPicker(selection: $customerId)
                    Toggle(isOn: $privateMode) {
                        Label("Privatmodus", systemImage: "eye.slash")
                    }
                    Toggle("Bestätigt", isOn: $confirmed)
                        .disabled(category == .unknown)
                } header: {
                    Text("Zuordnung")
                } footer: {
                    if privateMode {
                        Text("Privatmodus: Es werden nur Zeit und Kilometer gespeichert, keine Orte.")
                    } else {
                        Text("Bestätigte Fahrten zählen im Fahrtenbuch und in den Berichten.")
                    }
                }
                .disabled(!editable)

                if let t = stored ?? trip, t.hasSuggestion, editable {
                    suggestionSection(t)
                }

                Section {
                    TextField(notePrompt, text: $note, axis: .vertical)
                } header: {
                    Text(noteHeader)
                } footer: {
                    if noteRequired && editable {
                        Text(CorrectionReason.hint(note))
                            .foregroundStyle(CorrectionReason.isValid(note) ? Color.secondary : Color.warningText)
                    }
                }
                .disabled(!editable)

                Group {
                    if !errors.isEmpty && editable {
                        Section {
                            ForEach(errors, id: \.self) { e in
                                Label(e, systemImage: "xmark.octagon").foregroundStyle(Color.dangerText)
                            }
                        }
                    }
                    if !warnings.isEmpty && editable {
                        Section {
                            ForEach(warnings, id: \.self) { w in
                                Label(w, systemImage: "exclamationmark.triangle").foregroundStyle(Color.warningText)
                            }
                        }
                    }

                    if locked {
                        Section {
                            Label("Monat abgeschlossen – die Fahrt ist schreibgeschützt. Korrekturen nur über Storno "
                                  + "und neue Fahrt mit Begründung.", systemImage: "lock.fill")
                                .foregroundStyle(.secondary)
                        }
                    } else if !store.canWrite {
                        Section { Label("Nur Lesezugriff", systemImage: "eye").foregroundStyle(.secondary) }
                    }
                }

                if let t = stored {
                    if store.canWrite {
                        Section {
                            if canSplit {
                                Button {
                                    showSplit = true
                                } label: {
                                    Label("Aufteilen (Umweg/Zwischenhalt)", systemImage: "scissors")
                                }
                            }
                            Button(role: .destructive) {
                                stornoTarget = t
                            } label: {
                                Label("Fahrt stornieren", systemImage: "xmark.bin")
                            }
                        }
                    }
                    AuthorshipSection(createdBy: t.createdBy, updatedBy: t.updatedBy)
                    HistorySection(entity: Trip.entityName, id: t.id)
                }
            }
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(cancelTitle) {
                        if hasChanges {
                            askDiscard = true
                        } else {
                            dismiss()
                        }
                    }
                }
                if editable {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Sichern") {
                            save()
                            dismiss()
                        }
                        .disabled(!canSave)
                    }
                }
            }
            .discardGuard(hasChanges: hasChanges, isAsking: $askDiscard)
            .onAppear(perform: prefill)
            .onChange(of: category) { _, newValue in
                if newValue == .unknown { confirmed = false }
            }
            .sheet(isPresented: $showSplit) {
                if let t = stored {
                    TripSplitView(trip: t) { dismiss() }
                }
            }
            .reasonedStorno($stornoTarget, title: "Fahrt stornieren?",
                            message: { TripStorno.message($0) },
                            requiresReason: { store.requiresReason(for: $0) }) { trip, reason in
                store.delete(trip, reason: reason)
                dismiss()
            }
        }
    }

    private func suggestionSection(_ t: Trip) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Label("Vorschlag: \(TripCategory.of(t.suggestionCategory).uiLabel)",
                      systemImage: TripCategory.of(t.suggestionCategory).systemImage)
                    .font(.subheadline.weight(.semibold))
                if let p = t.suggestionPurpose?.nilIfEmpty { Text("Zweck: \(p)").font(.footnote) }
                if let r = t.suggestionReason?.nilIfEmpty { Text("Grund: \(r)").font(.footnote) }
                Text(TripSuggestionText.meta(t)).font(.footnote).foregroundStyle(Color.neutralText)
            }
            .accessibilityElement(children: .combine)
            Button("Vorschlag übernehmen") {
                category = TripCategory.of(t.suggestionCategory)
                if let p = t.suggestionPurpose { purpose = p }
                if let c = t.suggestionCustomerId { customerId = c }
                confirmed = category != .unknown
            }
        } header: {
            Text("Vorschlag")
        }
    }

    // MARK: Laden/Sichern

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        defer { initial = snapshot }
        guard let template = trip else {
            let last = store.lastKnownKm(for: vehicle.id)
            if last > 0 { kmStart = String(last) }
            confirmed = false
            return
        }
        let t = store.trip(id: template.id) ?? template
        startDate = t.startDate ?? Date()
        if let e = t.endDate {
            endDate = e
            hasEnd = true
        } else {
            endDate = max(Date(), startDate)
            hasEnd = false
        }
        kmStart = t.kmStart.map { String($0) } ?? ""
        kmEnd = t.kmEnd.map { String($0) } ?? ""
        kmEstimated = t.kmEstimated
        prefilledKmStart = kmStart
        prefilledKmEnd = kmEnd
        startPlaceId = t.startPlaceId
        startLabel = t.startLabel ?? ""
        endPlaceId = t.endPlaceId
        endLabel = t.endLabel ?? ""
        category = t.categoryValue
        purpose = t.purpose ?? ""
        customerId = t.customerId
        privateMode = t.privateMode
        note = t.note ?? ""
        // Speichern einer zu prüfenden Fahrt mit Kategorie = bestätigen (abwählbar)
        confirmed = category != .unknown
        if let p = startPlaceId, startLabel.isEmpty { startLabel = store.place(id: p)?.name ?? "" }
        if let p = endPlaceId, endLabel.isEmpty { endLabel = store.place(id: p)?.name ?? "" }
        if let preset = presetCategory, editable {
            category = preset
            confirmed = true
        }
    }

    private func save() {
        let base = stored ?? trip
        var t = base ?? Trip(vehicleId: vehicle.id, startAt: Trip.isoString(startDate))
        t.vehicleId = vehicle.id
        if t.startDate != startDate { t.startAt = Trip.isoString(startDate) }
        if hasEnd {
            if t.endDate != endDate { t.endAt = Trip.isoString(endDate) }
        } else {
            t.endAt = nil
        }
        t.kmStart = kmStartValue
        t.kmEnd = kmEndValue
        t.kmEstimated = stillEstimated
        t.privateMode = privateMode
        if privateMode {
            t.startPlaceId = nil
            t.endPlaceId = nil
            t.startLabel = nil
            t.endLabel = nil
        } else {
            t.startPlaceId = startPlaceId
            t.endPlaceId = endPlaceId
            t.startLabel = startLabel.nilIfEmpty
            t.endLabel = endLabel.nilIfEmpty
        }
        t.category = category.rawValue
        t.purpose = purpose.nilIfEmpty
        t.customerId = customerId
        if confirmed && category != .unknown {
            t.status = "confirmed"
        } else if t.status != "suggested" {
            t.status = "draft"
        }
        t.note = note.nilIfEmpty
        if isNew && t.driverName == nil { t.driverName = settings.auth.userName }
        if let old = stored {
            var compare = t
            compare.version = old.version
            compare.deleted = old.deleted
            if compare == old { return }   // unverändert → keine Revision
        }
        // Abgeschlossener Monat: die Notiz ist die Korrekturbegründung
        let reason: String? = noteRequired ? note.trimmed : nil
        store.save(t, reason: reason)
    }
}

enum TripSuggestionText {
    /// "Quelle: Regel · Konfidenz 95 %"
    static func meta(_ t: Trip) -> String {
        var parts = ["Quelle: \(Trip.suggestionSourceLabel(t.suggestionSource))"]
        if let c = t.suggestionConfidence { parts.append("Konfidenz \(Fmt.pct(c * 100))") }
        return parts.joined(separator: " · ")
    }
}

/// Ort aus der Ortsliste wählen oder frei eingeben.
struct TripPlaceField: View {
    @Environment(TenantStore.self) private var store
    let title: String
    @Binding var placeId: String?
    @Binding var label: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                TextField("Ort oder Adresse", text: Binding(get: { label }, set: { value in
                    label = value
                    if let id = placeId, store.place(id: id)?.name != value { placeId = nil }
                }))
                .multilineTextAlignment(.trailing)
                Menu {
                    ForEach(store.placeList) { p in
                        Button {
                            placeId = p.id
                            label = p.name
                        } label: {
                            Label(p.name, systemImage: p.kindValue.systemImage)
                        }
                    }
                    if placeId != nil || !label.isEmpty {
                        Divider()
                        Button("Leeren", role: .destructive) {
                            placeId = nil
                            label = ""
                        }
                    }
                } label: {
                    Image(systemName: placeId == nil ? "mappin.circle" : "mappin.circle.fill")
                }
                .accessibilityLabel("\(title): bekannten Ort auswählen")
            }
        }
    }
}

/// Kundenauswahl (optional).
struct CustomerPicker: View {
    @Environment(TenantStore.self) private var store
    @Binding var selection: String?

    var body: some View {
        Picker("Kunde", selection: $selection) {
            Text("Kein Kunde").tag(String?.none)
            ForEach(store.customerList) { c in
                Text(c.name).tag(String?.some(c.id))
            }
            if let current = selection, !store.customerList.contains(where: { $0.id == current }) {
                Text(store.customer(id: current)?.name ?? "Unbekannter Kunde").tag(String?.some(current))
            }
        }
    }
}

// MARK: Aufteilen

/// Fahrt aufteilen (Umweg/Zwischenhalt): Original wird storniert, zwei neue Fahrten mit `split_of`.
@MainActor
struct TripSplitView: View {
    @Environment(TenantStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let trip: Trip
    let onDone: () -> Void

    @State private var boundaryKm = ""
    @State private var splitTime = Date()
    @State private var midPlaceId: String?
    @State private var midLabel = ""
    @State private var firstCategory: TripCategory = .unknown
    @State private var secondCategory: TripCategory = .unknown
    @State private var firstPurpose = ""
    @State private var secondPurpose = ""
    @State private var didPrefill = false

    init(trip: Trip, onDone: @escaping () -> Void) {
        self.trip = trip
        self.onDone = onDone
    }

    private var kmFrom: Int { trip.kmStart ?? 0 }
    private var kmTo: Int { trip.kmEnd ?? 0 }
    private var boundary: Int? { boundaryKm.asInt }

    private var errors: [String] {
        var e: [String] = []
        if let b = boundary {
            if b <= kmFrom || b >= kmTo {
                e.append("Kilometerstand der Teilung muss zwischen \(Fmt.km(kmFrom)) und \(Fmt.km(kmTo)) liegen.")
            }
        } else {
            e.append("Kilometerstand der Teilung angeben.")
        }
        if let s = trip.startDate, splitTime < s { e.append("Zeitpunkt liegt vor dem Start.") }
        if let end = trip.endDate, splitTime > end { e.append("Zeitpunkt liegt nach dem Ende.") }
        return e
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Original", value: "\(Fmt.km(kmFrom)) – \(Fmt.km(kmTo))")
                    UnitField("Kilometerstand Teilung", text: $boundaryKm, unit: "km", keyboard: .numberPad)
                    DatePicker("Zeitpunkt", selection: $splitTime)
                    if !trip.privateMode {
                        TripPlaceField(title: "Zwischenhalt", placeId: $midPlaceId, label: $midLabel)
                    }
                } header: {
                    Text("Teilung")
                } footer: {
                    Text("Die ursprüngliche Fahrt wird storniert und bleibt im Änderungsprotokoll; "
                         + "beide Teile verweisen auf sie.")
                }
                Section("Teil 1 (bis Zwischenhalt)") {
                    categoryPicker($firstCategory)
                    TextField("Zweck", text: $firstPurpose)
                }
                Section("Teil 2 (ab Zwischenhalt)") {
                    categoryPicker($secondCategory)
                    TextField("Zweck", text: $secondPurpose)
                }
                if !errors.isEmpty {
                    Section {
                        ForEach(errors, id: \.self) { Text($0).foregroundStyle(Color.dangerText) }
                    }
                }
            }
            .navigationTitle("Fahrt aufteilen")
            .formToolbar(canSave: store.canWrite && errors.isEmpty, save: save)
            .onAppear(perform: prefill)
        }
    }

    private func categoryPicker(_ binding: Binding<TripCategory>) -> some View {
        Picker("Kategorie", selection: binding) {
            ForEach(TripCategory.allCases) { c in
                Label(c.uiLabel, systemImage: c.systemImage).tag(c)
            }
        }
    }

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        boundaryKm = String(kmFrom + (kmTo - kmFrom) / 2)
        if let s = trip.startDate {
            let e = trip.endDate ?? s
            splitTime = s.addingTimeInterval(e.timeIntervalSince(s) / 2)
        }
        firstCategory = trip.categoryValue
        secondCategory = trip.categoryValue
        firstPurpose = trip.purpose ?? ""
        secondPurpose = trip.purpose ?? ""
    }

    private func save() {
        guard let b = boundary else { return }
        let splitAt = Trip.isoString(splitTime)
        let mid: String? = midLabel.nilIfEmpty

        var first = trip
        first.id = UUID().uuidString.lowercased()
        first.version = 0
        first.deleted = false
        first.splitOf = trip.id
        first.kmEnd = b
        first.endAt = splitAt
        first.endPlaceId = trip.privateMode ? nil : midPlaceId
        first.endLabel = trip.privateMode ? nil : mid
        first.category = firstCategory.rawValue
        first.purpose = firstPurpose.nilIfEmpty
        first.status = firstCategory == .unknown ? "draft" : "confirmed"
        Self.clearDerived(&first)

        var second = trip
        second.id = UUID().uuidString.lowercased()
        second.version = 0
        second.deleted = false
        second.splitOf = trip.id
        second.kmStart = b
        second.startAt = splitAt
        second.startPlaceId = trip.privateMode ? nil : midPlaceId
        second.startLabel = trip.privateMode ? nil : mid
        second.category = secondCategory.rawValue
        second.purpose = secondPurpose.nilIfEmpty
        second.status = secondCategory == .unknown ? "draft" : "confirmed"
        Self.clearDerived(&second)

        store.delete(trip, reason: nil)
        store.save(first)
        store.save(second)
        onDone()
    }

    /// Distanzen/Track/Vorschlag gelten nur für das Original.
    private static func clearDerived(_ t: inout Trip) {
        t.distanceGps = nil
        t.distanceRoute = nil
        t.trackHash = nil
        t.suggestionCategory = nil
        t.suggestionPurpose = nil
        t.suggestionCustomerId = nil
        t.suggestionConfidence = nil
        t.suggestionReason = nil
        t.suggestionSource = nil
        if t.category == TripCategory.personal.rawValue { t.customerId = nil }
    }
}
