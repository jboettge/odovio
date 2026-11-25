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

/// Fahrten eines Fahrzeugs: Statuskarten, Start/Stopp, Liste nach Tag.
@MainActor
struct TripsListView: View {
    @Environment(TenantStore.self) private var store
    @Environment(TripCoordinator.self) private var coordinator
    let vehicle: Vehicle

    @State private var form: EditTarget<Trip>?
    @State private var toDelete: Trip?
    @State private var route: TripRoute?
    @State private var startPrivate = false

    init(vehicle: Vehicle) {
        self.vehicle = vehicle
    }

    var body: some View {
        let list = store.trips(for: vehicle.id)
        let reviewCount = store.reviewTrips(for: vehicle.id).count
        let gaps = store.gaps(for: vehicle.id, month: nil)
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
                Section {
                    recordingControls
                    if coordinator.isFinishing {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Fahrt wird ausgewertet …").foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    if let err = coordinator.lastError {
                        Text(err).foregroundStyle(.orange)
                    }
                }
            }
            if list.isEmpty {
                Section {
                    Text(emptyText).foregroundStyle(.secondary)
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
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button { route = .review } label: { Label("Fahrten bestätigen", systemImage: "checklist") }
                    Button { route = .gaps } label: { Label("Lücken", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                    Button { route = .close } label: { Label("Monatsabschluss", systemImage: "lock.doc") }
                    Button { route = .reports } label: { Label("Berichte", systemImage: "chart.bar.doc.horizontal") }
                    Divider()
                    Button { route = .places } label: { Label("Orte", systemImage: "mappin.and.ellipse") }
                    Button { route = .customers } label: { Label("Kunden", systemImage: "person.2") }
                    Button { route = .rules } label: { Label("Regeln", systemImage: "wand.and.stars") }
                    Button { route = .taxParams } label: { Label("Steuerparameter", systemImage: "percent") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Fahrtenbuch-Funktionen")
                if store.canWrite {
                    Button { form = EditTarget(value: nil) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Fahrt manuell erfassen")
                }
            }
        }
        .sheet(item: $form) { target in
            TripFormView(vehicle: vehicle, trip: target.value)
        }
        .sheet(item: $route) { r in
            ModalNavigation { routeView(r) }
        }
        .tripStornoDialog($toDelete) { store.delete($0) }
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

    private func tripRow(_ t: Trip) -> some View {
        let closed = store.isMonthClosed(vehicleId: t.vehicleId, month: t.monthKey)
        let quick = store.canWrite && !t.isLocked && !closed
        let hint: String = (t.isLocked || !store.canWrite) ? "Ansehen" : "Bearbeiten"
        return Button { form = EditTarget(value: t) } label: {
            TripRow(trip: t, route: store.routeText(t), pending: store.isPending(t.id))
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
                    Label("Privat", systemImage: TripCategory.personal.systemImage)
                }
                .tint(.gray)
                Button { quickConfirm(t, .business) } label: {
                    Label("Geschäftlich", systemImage: TripCategory.business.systemImage)
                }
                .tint(.orange)
            }
        }
    }

    /// Wischen: als privat/geschäftlich bestätigen; passender Vorschlag liefert Zweck/Kunde.
    private func quickConfirm(_ t: Trip, _ category: TripCategory) {
        let matches = t.suggestionCategory == category.rawValue
        let purpose: String? = (matches && t.purpose == nil) ? t.suggestionPurpose : nil
        let customer: String? = (matches && t.customerId == nil) ? t.suggestionCustomerId : nil
        store.confirm(t, as: category, purpose: purpose, customerId: customer)
    }

    // MARK: Start/Stopp

    @ViewBuilder
    private var recordingControls: some View {
        if coordinator.isRecording {
            let here = coordinator.recordingVehicleId == nil || coordinator.recordingVehicleId == vehicle.id
            let title: String = here ? "Aufzeichnung läuft" : "Aufzeichnung läuft (anderes Fahrzeug)"
            HStack(spacing: 12) {
                Image(systemName: "record.circle")
                    .font(.title2)
                    .symbolEffect(.pulse)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(recordingDetail).font(.subheadline.monospacedDigit())
                }
                Spacer()
                Button {
                    stop()
                } label: {
                    Label("Stopp", systemImage: "stop.fill").font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.red)
                .accessibilityLabel("Fahrt beenden")
            }
            .foregroundStyle(.white)
            .listRowBackground(Color.red)
            .accessibilityElement(children: .contain)
        } else {
            HStack(spacing: 12) {
                Button {
                    start()
                } label: {
                    Label("Fahrt starten", systemImage: "play.fill").font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .disabled(AppMode.isDemo)
                Spacer()
                Toggle(isOn: $startPrivate) {
                    Label("Privat", systemImage: "eye.slash")
                }
                .fixedSize()
                .accessibilityLabel("Privatmodus für die nächste Fahrt")
                .accessibilityHint("Speichert nur Zeit und Kilometer, keine Orte")
            }
        }
    }

    private var recordingDetail: String {
        var text = Fmt.kmD(coordinator.liveDistanceKm)
        if let since = coordinator.recordingStartedAt {
            text += " · seit \(Fmt.time(since))"
        }
        return text
    }

    private func start() {
        guard !AppMode.isDemo else { return }
        let v = store.vehicle(id: vehicle.id) ?? vehicle
        let privateMode = startPrivate
        store.defaultVehicleId = v.id
        Task { await coordinator.start(vehicle: v, privateMode: privateMode) }
    }

    private func stop() {
        Task {
            if let t = await coordinator.stop() {
                form = EditTarget(value: store.trip(id: t.id) ?? t)
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
        HStack(spacing: 10) {
            if reviewCount > 0 {
                card(reviewText, "checklist", .orange, action: onReview)
                    .accessibilityHint("Fahrten der Reihe nach bestätigen")
            }
            if !gaps.isEmpty {
                card(gapText, "exclamationmark.triangle.fill", .red, action: onGaps)
                    .accessibilityHint("Lücken in der Kilometerkette anzeigen")
            }
        }
    }

    private func card(_ title: String, _ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.bold))
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

/// Zeile einer Fahrt: Kategorie-Balken, Zeit, Strecke, km, Status, Vorschlag.
struct TripRow: View {
    let trip: Trip
    let route: String
    var pending = false

    private var timeText: String {
        guard let start = trip.startDate else { return "–" }
        var text = Fmt.time(start)
        if let end = trip.endDate { text += "–" + Fmt.time(end) }
        return text
    }

    private var kmText: String { trip.distanceKm.map { Fmt.kmD($0) } ?? "– km" }

    private var statusIcon: String {
        switch trip.status {
        case "confirmed": "checkmark.circle.fill"
        case "suggested": "questionmark.circle.fill"
        case "locked": "lock.fill"
        default: "pencil.circle"
        }
    }

    private var statusColor: Color {
        switch trip.status {
        case "confirmed": .green
        case "suggested": .orange
        case "locked": .secondary
        default: .gray
        }
    }

    private var suggestionText: String? {
        guard trip.needsReview, let s = trip.suggestionCategory else { return nil }
        var parts = ["Vorschlag: \(TripCategory.of(s).label)"]
        if let p = trip.suggestionPurpose?.nilIfEmpty { parts.append("«\(p)»") }
        parts.append(Trip.suggestionSourceLabel(trip.suggestionSource))
        return parts.joined(separator: " · ")
    }

    private var detailText: String {
        var parts = [trip.categoryValue.label]
        if let p = trip.purpose?.nilIfEmpty { parts.append(p) }
        if trip.source == "gap" { parts.append("Lücke") }
        return parts.joined(separator: " · ")
    }

    private var spokenText: String {
        var parts = [timeText, route, kmText, trip.categoryValue.label, Trip.statusLabel(trip.status)]
        if let p = trip.purpose?.nilIfEmpty { parts.append("Zweck \(p)") }
        if let s = suggestionText { parts.append(s) }
        if trip.privateMode { parts.append("Privatmodus") }
        if pending { parts.append("noch nicht synchronisiert") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        let cat = trip.categoryValue
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(cat.color)
                .frame(width: 4)
            Image(systemName: cat.systemImage)
                .foregroundStyle(cat.color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(timeText)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if trip.privateMode {
                        Image(systemName: "eye.slash").font(.caption).foregroundStyle(.secondary)
                    }
                    if pending { PendingBadge() }
                }
                Text(route).lineLimit(1)
                Text(detailText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let s = suggestionText {
                    Text(s).font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                Text(kmText).font(.subheadline.monospacedDigit().weight(.semibold))
                Image(systemName: statusIcon).foregroundStyle(statusColor)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenText)
    }
}

extension View {
    /// Storno-Bestätigung für Fahrten; bei gesperrten Fahrten mit Hinweis auf den Monatsabschluss.
    func tripStornoDialog(_ item: Binding<Trip?>, action: @escaping (Trip) -> Void) -> some View {
        confirmationDialog(
            "Fahrt stornieren?",
            isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: item.wrappedValue
        ) { trip in
            Button("Stornieren", role: .destructive) { action(trip) }
        } message: { trip in
            Text(TripStorno.message(trip))
        }
    }
}

enum TripStorno {
    static func message(_ trip: Trip) -> String {
        if trip.isLocked {
            return "Die Fahrt gehört zu einem abgeschlossenen Monat. Die Stornierung wird im Änderungsprotokoll "
                + "als Korrektur sichtbar; eine Ersatzfahrt braucht eine Korrekturbegründung."
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
    @State private var confirmStorno = false

    init(vehicle: Vehicle, trip: Trip?) {
        self.vehicle = vehicle
        self.trip = trip
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
    private var noteRequired: Bool { monthClosed && !locked }

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
    private var notePrompt: String { noteRequired ? "Pflicht: Grund der Korrektur" : "optional" }

    // MARK: Validierung

    private var errors: [String] {
        var e: [String] = []
        if let d = distance, d < 0 { e.append("km-Stand Ende ist kleiner als km-Stand Beginn.") }
        if hasEnd && endDate < startDate { e.append("Das Ende liegt vor dem Start.") }
        if noteRequired && note.trimmed.isEmpty {
            e.append("\(TripMonth.label(monthKey)) ist abgeschlossen – eine Korrekturbegründung (Notiz) ist Pflicht.")
        }
        if purpose.trimmed.count > Trip.maxPurpose { e.append("Zweck höchstens \(Trip.maxPurpose) Zeichen.") }
        if startLabel.trimmed.count > Trip.maxLabel || endLabel.trimmed.count > Trip.maxLabel {
            e.append("Ortsbezeichnung höchstens \(Trip.maxLabel) Zeichen.")
        }
        if !kmStart.trimmed.isEmpty && kmStartValue == nil { e.append("km-Stand Beginn ungültig.") }
        if !kmEnd.trimmed.isEmpty && kmEndValue == nil { e.append("km-Stand Ende ungültig.") }
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
            w.append("Ohne km-Stand Beginn und Ende ist die km-Kette unvollständig.")
        }
        if let d = distance, d > 1500 { w.append("Distanz \(Fmt.km(d)) ungewöhnlich gross.") }
        if category == .business && purpose.trimmed.isEmpty && customerId == nil {
            w.append("Geschäftliche Fahrt: Zweck oder Kunde angeben.")
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
                    UnitField("km-Stand Beginn", text: $kmStart, unit: "km", keyboard: .numberPad)
                    UnitField("km-Stand Ende", text: $kmEnd, unit: "km", keyboard: .numberPad)
                    LabeledContent("Distanz", value: distance.map { Fmt.km($0) } ?? "–")
                    if let t = stored ?? trip, let gps = t.distanceGps {
                        LabeledContent("GPS-Distanz", value: Fmt.kmD(gps))
                    }
                    if let t = stored ?? trip, let routeKm = t.distanceRoute {
                        LabeledContent("Routendistanz", value: Fmt.kmD(routeKm))
                    }
                } header: {
                    Text("Kilometer")
                } footer: {
                    Text("Massgebend ist der km-Stand (Tacho); GPS und Route dienen nur der Kontrolle.")
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
                            Label(c.label, systemImage: c.systemImage).tag(c)
                        }
                    }
                    TextField("Zweck (z. B. Offerte Meier)", text: $purpose, axis: .vertical)
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
                }
                .disabled(!editable)

                Group {
                    if !errors.isEmpty && editable {
                        Section {
                            ForEach(errors, id: \.self) { e in
                                Label(e, systemImage: "xmark.octagon").foregroundStyle(.red)
                            }
                        }
                    }
                    if !warnings.isEmpty && editable {
                        Section {
                            ForEach(warnings, id: \.self) { w in
                                Label(w, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
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
                                confirmStorno = true
                            } label: {
                                Label("Fahrt stornieren", systemImage: "xmark.bin")
                            }
                        }
                    }
                    HistorySection(entity: Trip.entityName, id: t.id)
                }
            }
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(cancelTitle) { dismiss() }
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
            .onAppear(perform: prefill)
            .onChange(of: category) { _, newValue in
                if newValue == .unknown { confirmed = false }
            }
            .sheet(isPresented: $showSplit) {
                if let t = stored {
                    TripSplitView(trip: t) { dismiss() }
                }
            }
            .confirmationDialog("Fahrt stornieren?", isPresented: $confirmStorno, titleVisibility: .visible) {
                Button("Stornieren", role: .destructive) {
                    if let t = stored { store.delete(t) }
                    dismiss()
                }
            } message: {
                Text(stored.map { TripStorno.message($0) } ?? "")
            }
        }
    }

    private func suggestionSection(_ t: Trip) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Label("Vorschlag: \(TripCategory.of(t.suggestionCategory).label)",
                      systemImage: TripCategory.of(t.suggestionCategory).systemImage)
                    .font(.subheadline.weight(.semibold))
                if let p = t.suggestionPurpose?.nilIfEmpty { Text("Zweck: \(p)").font(.caption) }
                if let r = t.suggestionReason?.nilIfEmpty { Text("Grund: \(r)").font(.caption) }
                Text(TripSuggestionText.meta(t)).font(.caption).foregroundStyle(.secondary)
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
        store.save(t)
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
                e.append("km-Grenze muss zwischen \(Fmt.km(kmFrom)) und \(Fmt.km(kmTo)) liegen.")
            }
        } else {
            e.append("km-Grenze angeben.")
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
                    UnitField("km-Grenze", text: $boundaryKm, unit: "km", keyboard: .numberPad)
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
                        ForEach(errors, id: \.self) { Text($0).foregroundStyle(.red) }
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
                Label(c.label, systemImage: c.systemImage).tag(c)
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

        store.delete(trip)
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
