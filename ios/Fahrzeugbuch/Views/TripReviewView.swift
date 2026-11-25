import SwiftUI

/// Review Karte für Karte (Kap. 7): Vorschlag prüfen, Kategorie wählen, bestätigen.
/// Ohne eigenen NavigationStack (wird gepusht oder in `ModalNavigation` gezeigt).
@MainActor
struct TripReviewView: View {
    @Environment(TenantStore.self) private var store
    @Environment(TripCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    let vehicle: Vehicle

    @State private var queue: [String] = []
    @State private var index = 0
    @State private var started = false
    @State private var confirmedCount = 0
    @State private var category: TripCategory = .unknown
    @State private var purpose = ""
    @State private var customerId: String?
    @State private var confirmBulk = false
    @State private var ruleOffer: PurposeRule?
    @State private var offeredRules: Set<String> = []
    @State private var edit: EditTarget<Trip>?
    @State private var suggesting = false

    init(vehicle: Vehicle) {
        self.vehicle = vehicle
    }

    private var current: Trip? {
        guard index < queue.count else { return nil }
        return store.trip(id: queue[index])
    }

    private var progressText: String {
        guard !queue.isEmpty else { return "" }
        return "\(min(index + 1, queue.count))/\(queue.count)"
    }

    private var titleText: String {
        queue.isEmpty || index >= queue.count ? "Fahrten bestätigen" : "Bestätigen (\(progressText))"
    }

    /// Verbleibende Fahrten (ab aktueller Karte), die als Arbeitsweg vorgeschlagen/eingestuft sind.
    private var commuteIds: [String] {
        queue.dropFirst(index).filter { id in
            guard let t = store.trip(id: id), !t.deleted, t.needsReview,
                  !store.isMonthClosed(vehicleId: t.vehicleId, month: t.monthKey) else { return false }
            return t.category == TripCategory.commute.rawValue || t.suggestionCategory == TripCategory.commute.rawValue
        }
    }

    private var bulkTitle: String {
        let n = commuteIds.count
        return n == 1 ? "1 Arbeitsweg bestätigen" : "Alle \(n) Arbeitswege bestätigen"
    }

    private var doneText: String {
        confirmedCount == 0
            ? "Keine Fahrten zu bestätigen."
            : (confirmedCount == 1 ? "1 Fahrt bestätigt." : "\(confirmedCount) Fahrten bestätigt.")
    }

    var body: some View {
        Group {
            if let t = current {
                ScrollView {
                    VStack(spacing: 16) {
                        ProgressView(value: Double(index), total: Double(max(queue.count, 1)))
                            .accessibilityLabel("Fortschritt \(progressText)")
                        card(t)
                        classification(t)
                        actions(t)
                        if store.canWrite && commuteIds.count > 1 {
                            Button {
                                confirmBulk = true
                            } label: {
                                Label(bulkTitle, systemImage: TripCategory.commute.systemImage)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(TripCategory.commute.color)
                        }
                    }
                    .padding()
                }
                .background(Color(uiColor: .systemGroupedBackground))
            } else {
                ContentUnavailableView {
                    Label("Alles bestätigt", systemImage: "checkmark.seal.fill")
                } description: {
                    Text(doneText)
                } actions: {
                    Button("Fertig") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle(titleText)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: begin)
        .sheet(item: $edit, onDismiss: refreshCurrent) { target in
            TripFormView(vehicle: vehicle, trip: target.value)
        }
        .confirmationDialog(bulkTitle + "?", isPresented: $confirmBulk, titleVisibility: .visible) {
            Button(bulkTitle) { confirmAllCommutes() }
        } message: {
            Text("Die Fahrten werden als Arbeitsweg bestätigt (Zweck aus dem Vorschlag).")
        }
        .alert("Regel vorschlagen?", isPresented: Binding(
            get: { ruleOffer != nil }, set: { if !$0 { ruleOffer = nil } }), presenting: ruleOffer) { rule in
            Button("Regel speichern") { saveRule(rule) }
            Button("Nein", role: .cancel) {}
        } message: { rule in
            Text(ruleQuestion(rule))
        }
    }

    // MARK: Karte

    private func card(_ t: Trip) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(dateLine(t))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(store.routeText(t))
                .font(.title3.weight(.semibold))
            HStack(spacing: 8) {
                Label(t.distanceKm.map { Fmt.kmD($0) } ?? "– km", systemImage: "road.lanes")
                if let a = t.kmStart, let b = t.kmEnd {
                    Text("\(Fmt.km(a)) → \(Fmt.km(b))").foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            HStack(spacing: 6) {
                StatusTag(text: Trip.sourceLabel(t.source), color: .blue)
                StatusTag(text: Trip.statusLabel(t.status), color: .secondary)
                if t.privateMode { StatusTag(text: "Privatmodus", color: .gray, systemImage: "eye.slash") }
            }
            Divider()
            if let s = t.suggestionCategory {
                let cat = TripCategory.of(s)
                VStack(alignment: .leading, spacing: 4) {
                    Label("Vorschlag: \(cat.label.uppercased())", systemImage: cat.systemImage)
                        .font(.headline)
                        .foregroundStyle(cat.color)
                    if let p = t.suggestionPurpose?.nilIfEmpty { Text("Zweck: \(p)") }
                    if let c = t.suggestionCustomerId {
                        Text("Kunde: \(store.customer(id: c)?.name ?? "Unbekannt")")
                    }
                    if let r = t.suggestionReason?.nilIfEmpty { Text("Grund: \(r)") }
                    Text(TripSuggestionText.meta(t)).font(.caption).foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
            } else {
                HStack {
                    Text("Kein Vorschlag").foregroundStyle(.secondary)
                    Spacer()
                    if store.canWrite {
                        Button {
                            Task { await requestSuggestion(t) }
                        } label: {
                            if suggesting { ProgressView() } else { Text("Vorschlag holen") }
                        }
                        .disabled(suggesting)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func dateLine(_ t: Trip) -> String {
        guard let s = t.startDate else { return t.startAt }
        var text = "\(Fmt.weekdayDay(s)) \(Fmt.time(s))"
        if let e = t.endDate { text += "–\(Fmt.time(e))" }
        return text
    }

    // MARK: Zuordnung

    private func classification(_ t: Trip) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(TripCategory.selectable) { c in
                    categoryButton(c)
                }
            }
            if category == .business || category == .field {
                TextField("Zweck (z. B. Offerte Meier)", text: $purpose)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text("Kunde")
                    Spacer()
                    CustomerPicker(selection: $customerId)
                        .labelsHidden()
                        .pickerStyle(.menu)
                }
            }
        }
        .disabled(!store.canWrite)
    }

    private func categoryButton(_ c: TripCategory) -> some View {
        let selected = category == c
        return Button {
            category = c
        } label: {
            Label(c.label, systemImage: c.systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(selected ? Color.white : c.color)
                .background(selected ? c.color : c.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : [])
    }

    private func actions(_ t: Trip) -> some View {
        let closed = store.isMonthClosed(vehicleId: t.vehicleId, month: t.monthKey)
        return VStack(spacing: 8) {
            if closed {
                Label("Monat abgeschlossen – über «Bearbeiten» mit Korrekturbegründung bestätigen.",
                      systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                Button("Überspringen") { advance() }
                    .buttonStyle(.bordered)
                Button("Bearbeiten") { edit = EditTarget(value: t) }
                    .buttonStyle(.bordered)
                    .disabled(!store.canWrite)
                Spacer()
                Button {
                    confirm(t)
                } label: {
                    Label("OK", systemImage: "checkmark").frame(minWidth: 70)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canWrite || category == .unknown || closed)
                .accessibilityLabel("Als \(category.label) bestätigen")
            }
        }
    }

    // MARK: Ablauf

    private func begin() {
        guard !started else { return }
        started = true
        queue = store.reviewTrips(for: vehicle.id).map(\.id)
        index = 0
        skipResolved()
        load()
    }

    /// Übersprungene/anderswo erledigte Fahrten überspringen.
    private func skipResolved() {
        while index < queue.count {
            guard let t = store.trip(id: queue[index]), !t.deleted, t.needsReview else {
                index += 1
                continue
            }
            break
        }
    }

    private func load() {
        guard let t = current else { return }
        let own = t.categoryValue
        category = own != .unknown ? own : TripCategory.of(t.suggestionCategory)
        purpose = t.purpose ?? t.suggestionPurpose ?? ""
        customerId = t.customerId ?? t.suggestionCustomerId
    }

    private func refreshCurrent() {
        skipResolved()
        load()
    }

    private func advance() {
        index += 1
        skipResolved()
        load()
    }

    private func confirm(_ t: Trip) {
        guard category != .unknown else { return }
        var n = store.trip(id: t.id) ?? t
        n.category = category.rawValue
        n.status = "confirmed"
        if category == .business || category == .field {
            n.purpose = purpose.nilIfEmpty
            n.customerId = customerId
        } else if category == .personal {
            n.customerId = nil
        } else if n.purpose == nil {
            n.purpose = n.suggestionPurpose
        }
        store.save(n)
        confirmedCount += 1
        offerRule()
        advance()
    }

    private func confirmAllCommutes() {
        let ids = commuteIds
        for id in ids {
            guard let t = store.trip(id: id) else { continue }
            store.confirm(t, as: .commute, purpose: t.purpose == nil ? t.suggestionPurpose : nil)
        }
        confirmedCount += ids.count
        let done = Set(ids)
        let head = Array(queue.prefix(index))
        let tail = queue.dropFirst(index).filter { !done.contains($0) }
        queue = head + tail
        skipResolved()
        load()
    }

    private func requestSuggestion(_ t: Trip) async {
        suggesting = true
        defer { suggesting = false }
        guard let s = await coordinator.suggest(for: t) else { return }
        var n = store.trip(id: t.id) ?? t
        n.suggestionCategory = s.category
        n.suggestionPurpose = s.purpose
        n.suggestionCustomerId = s.customerId
        n.suggestionConfidence = s.confidence
        n.suggestionReason = s.reason
        n.suggestionSource = s.source
        if n.status == "draft" { n.status = "suggested" }
        store.save(n)
        load()
    }

    // MARK: Regelvorschlag

    private func offerRule() {
        guard store.canWrite else { return }
        let candidates = coordinator.ruleCandidates().filter { r in
            !offeredRules.contains(TenantStore.ruleSignature(r)) && !store.hasSimilarRule(r)
        }
        guard let rule = candidates.first else { return }
        offeredRules.insert(TenantStore.ruleSignature(rule))
        ruleOffer = rule
    }

    private func ruleQuestion(_ r: PurposeRule) -> String {
        "\(store.ruleConditionText(r)): immer als «\(store.ruleResultText(r))» vorschlagen? "
            + "Die Regel bestätigt nie automatisch."
    }

    private func saveRule(_ r: PurposeRule) {
        var rule = r
        rule.autoConfirm = false   // nie automatisch bestätigen ohne explizite Zustimmung
        store.save(rule)
    }
}
