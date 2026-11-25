import SwiftUI

/// Bestätigen Karte für Karte (Kap. 7): Vorschlag prüfen, Kategorie wählen, Kilometerstand ablesen, bestätigen.
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
    @State private var suggestState: SuggestState = .idle
    /// Abgelesener Kilometerstand Ende (bei geschätzten Werten)
    @State private var odometerText = ""
    /// Geschäftlich/Aussendienst ausdrücklich ohne Zweck bestätigen
    @State private var allowWithoutPurpose = false
    /// Bestätigung in einem abgeschlossenen Monat → Begründung
    @State private var reasonTarget: EditTarget<Trip>?

    enum SuggestState: Equatable {
        case idle, loading, notFound, applied
    }

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

    private var needsPurpose: Bool {
        (category == .business || category == .field) && purpose.trimmed.isEmpty
    }

    private var odometerValue: Int? { odometerText.asInt }

    var body: some View {
        Group {
            if let t = current {
                ScrollView {
                    VStack(spacing: 16) {
                        ProgressView(value: Double(index), total: Double(max(queue.count, 1)))
                            .accessibilityLabel("Fortschritt \(progressText)")
                        card(t)
                        if t.kmEstimated && store.canWrite {
                            odometerPrompt(t)
                        }
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
                            .tint(Color.infoText)
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
        .onDisappear { coordinator.refreshReminders() }   // Erinnerung an offene Bestätigungen aktualisieren
        .sheet(item: $edit, onDismiss: refreshCurrent) { target in
            TripFormView(vehicle: vehicle, trip: target.value)
        }
        .confirmationDialog(bulkTitle + "?", isPresented: $confirmBulk, titleVisibility: .visible) {
            Button(bulkTitle) { confirmAllCommutes() }
        } message: {
            Text("Die Fahrten werden als Arbeitsweg bestätigt (Zweck aus dem Vorschlag). Fahrten mit geschätztem "
                 + "Kilometerstand bleiben zum Ablesen markiert.")
        }
        .sheet(item: $reasonTarget) { target in
            ReasonSheet(title: "Korrektur begründen",
                        message: "Diese Fahrt gehört zu einem abgeschlossenen Monat. Die Bestätigung wird mit "
                            + "Begründung im Änderungsprotokoll vermerkt.",
                        confirmTitle: "Bestätigen", destructive: false) { reason in
                if let t = target.value { confirm(t, reason: reason) }
            }
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
            Text(store.routeLabel(t))
                .font(.title3.weight(.semibold))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { kmFacts(t) }
                VStack(alignment: .leading, spacing: 4) { kmFacts(t) }
            }
            .font(.subheadline)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { tags(t) }
                VStack(alignment: .leading, spacing: 4) { tags(t) }
            }
            Divider()
            if let s = t.suggestionCategory {
                let cat = TripCategory.of(s)
                VStack(alignment: .leading, spacing: 4) {
                    Label("Vorschlag: \(cat.uiLabel.uppercased())", systemImage: cat.systemImage)
                        .font(.headline)
                        .foregroundStyle(cat.textColor)
                    if let p = t.suggestionPurpose?.nilIfEmpty { Text("Zweck: \(p)") }
                    if let c = t.suggestionCustomerId {
                        Text("Kunde: \(store.customer(id: c)?.name ?? "Unbekannt")")
                    }
                    if let r = t.suggestionReason?.nilIfEmpty { Text("Grund: \(r)") }
                    Text(TripSuggestionText.meta(t)).font(.footnote).foregroundStyle(Color.neutralText)
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
            } else {
                suggestionRequest(t)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func kmFacts(_ t: Trip) -> some View {
        Label(KmText.distance(t), systemImage: "road.lanes")
        if let range = KmText.range(t) {
            Text(range).foregroundStyle(Color.neutralText)
        }
    }

    @ViewBuilder
    private func tags(_ t: Trip) -> some View {
        StatusTag(text: Trip.sourceLabel(t.source), color: .blue)
        StatusTag(text: Trip.statusLabel(t.status), color: .secondary)
        if t.kmEstimated {
            StatusTag(text: "km geschätzt", color: .orange, systemImage: "gauge.with.dots.needle.33percent")
        }
        if t.privateMode { StatusTag(text: "Privatmodus", color: .gray, systemImage: "eye.slash") }
    }

    /// „Vorschlag holen“ mit Rückmeldung (lädt / kein Vorschlag).
    @ViewBuilder
    private func suggestionRequest(_ t: Trip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Kein Vorschlag").foregroundStyle(Color.neutralText)
                Spacer()
                if store.canWrite {
                    Button {
                        Task { await requestSuggestion(t) }
                    } label: {
                        if suggestState == .loading {
                            HStack(spacing: 6) {
                                ProgressView()
                                Text("Sucht …")
                            }
                        } else {
                            Text("Vorschlag holen")
                        }
                    }
                    .disabled(suggestState == .loading || AppMode.isDemo)
                }
            }
            if suggestState == .notFound {
                Label("Kein passender Vorschlag gefunden (keine Regel, kein Termin, kein Muster – oder offline). "
                      + "Bitte Kategorie selbst wählen.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(Color.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Kilometerstand ablesen (U3)

    private func odometerPrompt(_ t: Trip) -> some View {
        let urgent = coordinator.odometerPromptNeeded(vehicleId: t.vehicleId)
        let estimatedEnd = t.kmEnd
        return VStack(alignment: .leading, spacing: 8) {
            Label(urgent ? "Bitte jetzt den Kilometerstand ablesen" : "Kilometerstand geschätzt",
                  systemImage: "gauge.with.dots.needle.33percent")
                .font(.headline)
                .foregroundStyle(Color.warningText)
            Text("Der Kilometerstand wurde aus der GPS-Distanz geschätzt. Massgebend ist der Tacho – mit dem "
                 + "abgelesenen Wert bleibt die Kilometerkette korrekt.")
                .font(.footnote)
                .foregroundStyle(Color.neutralText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("Kilometerstand Ende")
                Spacer(minLength: 8)
                TextField(estimatedEnd.map { String($0) } ?? "km", text: $odometerText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 140)
                Text("km").foregroundStyle(.secondary)
            }
            if let entered = odometerValue, let est = estimatedEnd {
                let diff = entered - est
                if let start = t.kmStart, entered < start {
                    Label("Kleiner als der Kilometerstand Beginn (\(Fmt.km(start))).", systemImage: "xmark.octagon")
                        .font(.footnote)
                        .foregroundStyle(Color.dangerText)
                } else if diff != 0 {
                    Text("Abweichung zur Schätzung: " + KmText.signed(diff))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(abs(diff) > 5 ? Color.warningText : Color.neutralText)
                } else {
                    Text("Entspricht der Schätzung.").font(.footnote).foregroundStyle(Color.successText)
                }
            }
            Text("Wird beim Bestätigen übernommen. Ohne Eingabe bleibt der Wert «geschätzt».")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.warningText.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.warningText.opacity(urgent ? 0.6 : 0.25)))
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
                if needsPurpose {
                    purposeHint
                }
            }
        }
        .disabled(!store.canWrite)
    }

    /// Hinweis: geschäftliche Fahrt ohne Zweck (U11)
    private var purposeHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Zweck fehlt. Ohne Zweck ist der Monatsabschluss nicht möglich.",
                  systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(Color.warningText)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Trotzdem ohne Zweck bestätigen", isOn: $allowWithoutPurpose)
                .font(.footnote)
        }
    }

    private func categoryButton(_ c: TripCategory) -> some View {
        let selected = category == c
        return Button {
            category = c
        } label: {
            Label(c.uiLabel, systemImage: c.systemImage)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(selected ? Color(uiColor: .systemBackground) : c.textColor)
                .background(selected ? c.textColor : c.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : [])
    }

    private func actions(_ t: Trip) -> some View {
        let reasonNeeded = store.requiresReason(for: t)
        let odometerInvalid = odometerValue.map { v in t.kmStart.map { v < $0 } ?? false } ?? false
        let blocked = !store.canWrite || category == .unknown || (needsPurpose && !allowWithoutPurpose)
            || odometerInvalid
        return VStack(spacing: 8) {
            if reasonNeeded {
                Label("Monat abgeschlossen – die Bestätigung braucht eine Korrekturbegründung.",
                      systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.warningText)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    secondaryActions(t)
                    Spacer()
                    okButton(t, reasonNeeded: reasonNeeded, blocked: blocked)
                }
                VStack(spacing: 10) {
                    okButton(t, reasonNeeded: reasonNeeded, blocked: blocked)
                    HStack(spacing: 10) { secondaryActions(t) }
                }
            }
        }
    }

    @ViewBuilder
    private func secondaryActions(_ t: Trip) -> some View {
        Button("Überspringen") { advance() }
            .buttonStyle(.bordered)
        Button("Bearbeiten") { edit = EditTarget(value: t) }
            .buttonStyle(.bordered)
            .disabled(!store.canWrite)
    }

    private func okTitle(_ reasonNeeded: Bool) -> String {
        reasonNeeded ? "OK …" : "OK"
    }

    private func okButton(_ t: Trip, reasonNeeded: Bool, blocked: Bool) -> some View {
        Button {
            if reasonNeeded {
                reasonTarget = EditTarget(value: t)
            } else {
                confirm(t, reason: nil)
            }
        } label: {
            Label(okTitle(reasonNeeded), systemImage: "checkmark").frame(minWidth: 70)
        }
        .buttonStyle(.borderedProminent)
        .disabled(blocked)
        .accessibilityLabel("Als \(category.uiLabel) bestätigen")
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
        allowWithoutPurpose = false
        odometerText = ""
        suggestState = .idle
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

    private func confirm(_ t: Trip, reason: String?) {
        guard category != .unknown else { return }
        var n = store.trip(id: t.id) ?? t
        n.category = category.rawValue
        n.status = "confirmed"
        // Tacho abgelesen → Schätzung ersetzen
        if n.kmEstimated, let km = odometerValue, km >= (n.kmStart ?? 0) {
            n.kmEnd = km
            n.kmEstimated = false
        }
        // Korrektur in abgeschlossenem Monat: Begründung (Op) und – falls leer – als Notiz
        if let reason = reason?.nilIfEmpty, n.note?.nilIfEmpty == nil {
            n.note = reason
        }
        if category == .business || category == .field {
            n.purpose = purpose.nilIfEmpty
            n.customerId = customerId
        } else if category == .personal {
            n.customerId = nil
        } else if n.purpose == nil {
            n.purpose = n.suggestionPurpose
        }
        store.save(n, reason: reason)
        confirmedCount += 1
        offerRule()
        advance()
    }

    private func confirmAllCommutes() {
        let ids = commuteIds
        store.performBatch {
            for id in ids {
                guard let t = store.trip(id: id) else { continue }
                store.confirm(t, as: .commute, purpose: t.purpose == nil ? t.suggestionPurpose : nil)
            }
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
        suggestState = .loading
        guard let s = await coordinator.suggest(for: t) else {
            suggestState = .notFound
            return
        }
        suggestState = .applied
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
