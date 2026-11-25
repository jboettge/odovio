import QuickLook
import SwiftUI

// MARK: Server-Prüfung

enum TripServer {
    @MainActor
    static func check(_ settings: AppSettings, _ store: TenantStore, vehicleId: String, month: String) async throws -> TripCheck {
        try await settings.api.get("api/t/\(store.tenant.slug)/vehicles/\(vehicleId)/trips/check",
                                   query: [URLQueryItem(name: "month", value: month)])
    }

    @MainActor
    static func download(_ settings: AppSettings, _ store: TenantStore, vehicleId: String, file: String,
                         query: [URLQueryItem], name: String) async throws -> URL {
        let data = try await settings.api.download("api/t/\(store.tenant.slug)/vehicles/\(vehicleId)/\(file)",
                                                   query: query)
        return try ExportFile.write(data, name: name)
    }
}

/// Eine Zeile der Checkliste (erfüllt / offen / unbekannt).
struct CheckRow: View {
    let title: String
    let ok: Bool?
    var detail: String?

    private var icon: String {
        switch ok {
        case .some(true): "checkmark.circle.fill"
        case .some(false): "xmark.circle.fill"
        case .none: "questionmark.circle"
        }
    }

    private var color: Color {
        switch ok {
        case .some(true): .successText
        case .some(false): .dangerText
        case .none: .neutralText
        }
    }

    private var spoken: String {
        let state: String
        switch ok {
        case .some(true): state = "erfüllt"
        case .some(false): state = "offen"
        case .none: state = "nicht geprüft"
        }
        return [title, state, detail ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.footnote).foregroundStyle(Color.neutralText)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }
}

// MARK: Lücken

/// Lücken der km-Kette (lokal) und Server-Prüfung eines Monats.
@MainActor
struct GapListView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TenantStore.self) private var store
    let vehicle: Vehicle

    @State private var form: EditTarget<Trip>?
    @State private var month = TripMonth.current()
    @State private var check: TripCheck?
    @State private var checkError: String?
    @State private var loading = false

    init(vehicle: Vehicle) {
        self.vehicle = vehicle
    }

    var body: some View {
        let gaps = store.gaps(for: vehicle.id, month: nil)
        List {
            Section {
                if gaps.isEmpty {
                    Label("Keine Lücken in der Kilometerkette", systemImage: "checkmark.seal")
                        .foregroundStyle(Color.successText)
                }
                ForEach(gaps) { g in
                    gapRow(g)
                }
            } header: {
                Text("Kilometerkette")
            } footer: {
                Text("Eine Lücke entsteht, wenn der Kilometerstand am Ende einer Fahrt nicht dem Beginn der nächsten "
                     + "entspricht. Fehlende Kilometer als Fahrt erfassen oder den Kilometerstand korrigieren.")
            }

            Section {
                Picker("Monat", selection: $month) {
                    ForEach(TripMonth.recent(13), id: \.self) { m in
                        Text(TripMonth.label(m)).tag(m)
                    }
                }
                Button {
                    Task { await runCheck() }
                } label: {
                    HStack {
                        Label("Mit Server prüfen", systemImage: "checkmark.shield")
                        if loading { Spacer(); ProgressView() }
                    }
                }
                .disabled(loading || AppMode.isDemo)
                if let checkError {
                    Label(checkError, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(Color.warningText)
                }
                if let check {
                    serverResult(check)
                }
            } header: {
                Text("Server-Prüfung")
            } footer: {
                Text("Prüft zusätzlich fehlende Kilometerstände, Abweichungen GPS/Route und den Abgleich mit "
                     + "Tankvorgängen und Kilometerständen (nur online).")
            }
        }
        .navigationTitle("Lücken")
        .sheet(item: $form) { target in
            TripFormView(vehicle: vehicle, trip: target.value)
        }
        .refreshable { await store.sync() }
    }

    private func gapRow(_ g: TripGap) -> some View {
        let after = g.afterTripId.flatMap { store.trip(id: $0) }
        let before = g.beforeTripId.flatMap { store.trip(id: $0) }
        return VStack(alignment: .leading, spacing: 8) {
            Text(GapText.describe(g, after: after, before: before))
            if store.canWrite {
                HStack(spacing: 16) {
                    if g.km > 0 {
                        Menu {
                            ForEach(TripCategory.selectable) { c in
                                Button {
                                    form = EditTarget(value: gapTrip(g, after: after, before: before, category: c))
                                } label: {
                                    Label(c.uiLabel, systemImage: c.systemImage)
                                }
                            }
                        } label: {
                            Label("Als Fahrt erfassen", systemImage: "plus.circle")
                        }
                    }
                    Menu {
                        if let a = after, !a.isLocked {
                            Button("Kilometerstand Ende der vorherigen Fahrt") { form = EditTarget(value: a) }
                        }
                        if let b = before, !b.isLocked {
                            Button("Kilometerstand Beginn der nächsten Fahrt") { form = EditTarget(value: b) }
                        }
                    } label: {
                        Label("Kilometerstand korrigieren", systemImage: "gauge.with.dots.needle.33percent")
                    }
                }
                .font(.subheadline)
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func serverResult(_ c: TripCheck) -> some View {
        let gapDetail: String? = c.gaps.isEmpty ? nil : GapText.summary(c.gaps)
        let openCount = c.unconfirmed ?? 0
        let openDetail: String? = openCount > 0 ? "\(openCount) offen" : nil
        CheckRow(title: "Keine Lücken in der Kilometerkette", ok: c.gaps.isEmpty, detail: gapDetail)
        CheckRow(title: "Alle Fahrten bestätigt", ok: openCount == 0, detail: openDetail)
        if let o = c.odometerCheck {
            CheckRow(title: "Abgleich mit Tankvorgängen/Kilometerständen", ok: o.ok, detail: OdometerText.describe(o))
        }
        ForEach(c.mismatches) { m in
            Button {
                if let id = m.tripId, let t = store.trip(id: id) { form = EditTarget(value: t) }
            } label: {
                Label(mismatchText(m), systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Color.warningText)
            }
            .buttonStyle(.plain)
        }
    }

    private func mismatchText(_ m: TripMismatch) -> String {
        var text = m.reason ?? "Abweichung"
        if let id = m.tripId, let t = store.trip(id: id), let d = t.startDate {
            text = "\(Fmt.weekdayDay(d)) \(Fmt.time(d)): " + text
        }
        return text
    }

    private func gapTrip(_ g: TripGap, after: Trip?, before: Trip?, category: TripCategory) -> Trip {
        let start = after?.endAt ?? after?.startAt ?? before?.startAt ?? Trip.isoString(Date())
        var t = Trip(vehicleId: vehicle.id, startAt: start)
        t.endAt = before?.startAt
        t.kmStart = g.kmFrom
        t.kmEnd = g.kmTo
        t.source = "gap"
        t.category = category.rawValue
        if category == .personal {
            t.privateMode = true
        } else {
            t.startPlaceId = after?.endPlaceId
            t.startLabel = after?.endLabel
            t.endPlaceId = before?.startPlaceId
            t.endLabel = before?.startLabel
        }
        return t
    }

    private func runCheck() async {
        loading = true
        defer { loading = false }
        await store.sync()
        do {
            check = try await TripServer.check(settings, store, vehicleId: vehicle.id, month: month)
            checkError = nil
        } catch {
            checkError = "Server-Prüfung nicht möglich: \(error.userMessage)"
        }
    }
}

enum GapText {
    /// "2 Lücke(n) · 15 km"
    static func summary(_ gaps: [TripGap]) -> String {
        let km = gaps.reduce(0) { $0 + abs($1.km) }
        return "\(gaps.count) Lücke(n) · \(Fmt.km(km))"
    }

    /// "Zwischen Mi. 18.11. 18:30 (km 53'282) und Do. 19.11. 07:40 (km 53'294) fehlen 12 km."
    static func describe(_ g: TripGap, after: Trip?, before: Trip?) -> String {
        let from = point(after?.endDate ?? after?.startDate, km: g.kmFrom)
        let to = point(before?.startDate, km: g.kmTo)
        if g.km < 0 {
            return "Überschneidung: \(from) und \(to) überlappen um \(Fmt.km(-g.km))."
        }
        return "Zwischen \(from) und \(to) fehlen \(Fmt.km(g.km))."
    }

    private static func point(_ date: Date?, km: Int) -> String {
        guard let date else { return "km \(km.formatted(.number))" }
        return "\(Fmt.weekdayDay(date)) \(Fmt.time(date)) (km \(km.formatted(.number)))"
    }
}

enum OdometerText {
    static func describe(_ o: OdometerCheck) -> String {
        if let note = o.note?.nilIfEmpty, o.odometerKm == nil { return note }
        var parts: [String] = []
        if let t = o.tripKm { parts.append("Fahrten \(Fmt.kmD(t))") }
        if let k = o.odometerKm { parts.append("Kilometerstände \(Fmt.kmD(k))") }
        if let d = o.diffKm { parts.append("Differenz \(Fmt.kmD(d))") }
        return parts.isEmpty ? "Keine Angaben" : parts.joined(separator: " · ")
    }
}

// MARK: Monatsabschluss

/// km je Kategorie (für Zusammenfassungen).
struct CategoryKm: Identifiable, Hashable {
    let category: TripCategory
    let km: Double
    var id: String { category.rawValue }
}

/// Checkliste eines Monats (lokal + Server-Prüfung).
struct MonthChecklist {
    var trips: [Trip]
    var open: [Trip]
    var gaps: [TripGap]
    var missingPurpose: [Trip]
    var incomplete: [Trip]
    var estimated: [Trip]
    var pendingOps: Int
    var odometerOk: Bool?
    var mismatches: [TripMismatch]

    init(trips: [Trip], gaps: [TripGap], pendingOps: Int, check: TripCheck?) {
        self.trips = trips
        self.open = trips.filter(\.needsReview)
        self.gaps = gaps
        self.missingPurpose = trips.filter { t in
            let c = t.categoryValue
            return (c == .business || c == .field) && t.purpose?.nilIfEmpty == nil && t.customerId == nil
                && t.customerName?.nilIfEmpty == nil
        }
        self.incomplete = trips.filter { $0.kmStart == nil || $0.kmEnd == nil || $0.endAt == nil }
        self.estimated = trips.filter(\.kmEstimated)
        self.pendingOps = pendingOps
        self.odometerOk = check?.odometerCheck?.ok
        self.mismatches = check?.mismatches ?? []
    }

    var allOk: Bool {
        open.isEmpty && gaps.isEmpty && missingPurpose.isEmpty && incomplete.isEmpty && estimated.isEmpty
            && pendingOps == 0 && odometerOk != false && mismatches.isEmpty
    }

    /// Offene Punkte als Text (Bestätigungsdialog, erzwungener Abschluss)
    var issues: [String] {
        var list: [String] = []
        if !open.isEmpty { list.append("\(open.count) Fahrt(en) nicht bestätigt") }
        if !gaps.isEmpty { list.append(GapText.summary(gaps)) }
        if !missingPurpose.isEmpty { list.append("\(missingPurpose.count) geschäftliche Fahrt(en) ohne Zweck") }
        if !incomplete.isEmpty { list.append("\(incomplete.count) Fahrt(en) ohne Kilometerstand oder Endzeit") }
        if !estimated.isEmpty { list.append("\(estimated.count) Fahrt(en) mit geschätztem Kilometerstand") }
        if pendingOps > 0 { list.append("\(pendingOps) Änderung(en) nicht synchronisiert") }
        if odometerOk == false { list.append("Abweichung zu Tankvorgängen/Kilometerständen") }
        if !mismatches.isEmpty { list.append("\(mismatches.count) Abweichung(en) laut Server") }
        return list
    }
}

/// Inhalt des Bestätigungsdialogs vor dem (irreversiblen) Abschluss.
struct MonthCloseSummary: Identifiable {
    let id = UUID()
    let month: String
    let vehicleName: String
    let tripCount: Int
    let km: [CategoryKm]
    let totalKm: Double
    let gapCount: Int
    let gapKm: Int
    let issues: [String]
    let force: Bool
    let reason: String

    static func make(month: String, vehicleName: String, checklist: MonthChecklist, force: Bool,
                     reason: String) -> MonthCloseSummary {
        var totals: [TripCategory: Double] = [:]
        for t in checklist.trips {
            totals[t.categoryValue, default: 0] += max(t.distanceKm ?? 0, 0)
        }
        let km = TripCategory.allCases.compactMap { c -> CategoryKm? in
            let v = totals[c] ?? 0
            guard v > 0 || TripCategory.selectable.contains(c) else { return nil }
            return CategoryKm(category: c, km: v)
        }
        return MonthCloseSummary(month: month, vehicleName: vehicleName, tripCount: checklist.trips.count, km: km,
                                 totalKm: totals.values.reduce(0, +), gapCount: checklist.gaps.count,
                                 gapKm: checklist.gaps.reduce(0) { $0 + abs($1.km) },
                                 issues: checklist.issues, force: force, reason: reason)
    }
}

/// Bestätigung mit Zusammenfassung; der Abschluss ist nicht umkehrbar.
struct MonthCloseConfirmView: View {
    @Environment(\.dismiss) private var dismiss
    let summary: MonthCloseSummary
    let onConfirm: () -> Void

    private var confirmTitle: String {
        summary.force ? "Trotzdem endgültig abschliessen" : "Endgültig abschliessen"
    }

    private var gapText: String {
        if summary.gapCount == 0 { return "Keine" }
        return "\(summary.gapCount) · \(Fmt.km(summary.gapKm))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Fahrzeug", value: summary.vehicleName)
                    LabeledContent("Monat", value: TripMonth.label(summary.month))
                    LabeledContent("Fahrten", value: "\(summary.tripCount)")
                }
                Section {
                    ForEach(summary.km) { entry in
                        LabeledContent {
                            Text(Fmt.kmD(entry.km)).monospacedDigit()
                        } label: {
                            Label(entry.category.uiLabel, systemImage: entry.category.systemImage)
                        }
                    }
                    LabeledContent {
                        Text(Fmt.kmD(summary.totalKm)).monospacedDigit().fontWeight(.semibold)
                    } label: {
                        Text("Total").fontWeight(.semibold)
                    }
                    LabeledContent("Lücken", value: gapText)
                } header: {
                    Text("Kilometer nach Kategorie")
                }
                if summary.force {
                    Section {
                        ForEach(summary.issues, id: \.self) { issue in
                            Label(issue, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Color.warningText)
                        }
                        LabeledContent("Begründung") {
                            Text(summary.reason).multilineTextAlignment(.trailing)
                        }
                    } header: {
                        Text("Offene Punkte")
                    } footer: {
                        Text("Die offenen Punkte und die Begründung werden im Fahrtenbuch vermerkt.")
                    }
                }
                Section {
                    Label("Nicht umkehrbar: Alle Fahrten des Monats werden gesperrt. Korrekturen sind danach nur "
                          + "per Storno bzw. neuer Fahrt mit Begründung möglich und bleiben im Änderungsprotokoll "
                          + "sichtbar.", systemImage: "lock.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.dangerText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    Button(role: .destructive) {
                        onConfirm()
                        dismiss()
                    } label: {
                        Text(confirmTitle).frame(maxWidth: .infinity).fontWeight(.semibold)
                    }
                    .disabled(AppMode.isDemo)
                    Button("Abbrechen", role: .cancel) { dismiss() }
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Monat abschliessen?")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
    }
}

/// Monatsabschluss: Checkliste, Abschliessen (nur abgelaufene Monate, mit Bestätigung), Fahrtenbuch-PDF.
@MainActor
struct MonthCloseView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TenantStore.self) private var store
    let vehicle: Vehicle

    @State private var month: String
    @State private var check: TripCheck?
    @State private var checkError: String?
    @State private var loadingCheck = false
    @State private var closing = false
    @State private var conflict: String?
    @State private var forceMode = false
    @State private var forceReason = ""
    @State private var confirmation: MonthCloseSummary?
    @State private var resultText: String?
    @State private var fileURL: URL?
    @State private var previewURL: URL?
    @State private var loadingPDF = false
    @State private var error: String?
    @State private var form: EditTarget<Trip>?

    init(vehicle: Vehicle, month: String? = nil) {
        self.vehicle = vehicle
        _month = State(initialValue: month ?? TripMonth.previous())
    }

    /// Nur abgelaufene Monate (der laufende erscheint nur, wenn er ausdrücklich übergeben wurde).
    private var months: [String] {
        let current = TripMonth.current()
        var set = Set(TripMonth.recent(13).filter { $0 < current })
        for t in store.trips(for: vehicle.id) where t.monthKey < current { set.insert(t.monthKey) }
        set.insert(month)
        return set.sorted(by: >)
    }

    private var isPast: Bool { month < TripMonth.current() }

    private var period: TripPeriod? { store.period(vehicleId: vehicle.id, month: month) }

    private var reasonValid: Bool { CorrectionReason.isValid(forceReason) }

    private var nextMonthStart: String {
        guard let d = TripMonth.date(month),
              let next = Calendar.current.date(byAdding: .month, value: 1, to: d) else { return "Monatsende" }
        return Fmt.day(next)
    }

    var body: some View {
        let trips = store.trips(for: vehicle.id, month: month)
        let gaps = store.gaps(for: vehicle.id, month: month)
        let checklist = MonthChecklist(trips: trips, gaps: gaps, pendingOps: store.outbox.count, check: check)
        Form {
            Section {
                Picker("Monat", selection: $month) {
                    ForEach(months, id: \.self) { m in
                        Text(monthTitle(m)).tag(m)
                    }
                }
                LabeledContent("Fahrten", value: "\(trips.count)")
            }

            if let p = period {
                closedSection(p)
            } else {
                checklistSection(checklist)
                if store.canWrite {
                    if isPast {
                        closeSection(checklist)
                        if !checklist.allOk || conflict != nil {
                            forceSection(checklist)
                        }
                    } else {
                        Section {
                            Label("Der laufende Monat kann erst ab \(nextMonthStart) abgeschlossen werden.",
                                  systemImage: "calendar.badge.clock")
                                .foregroundStyle(Color.neutralText)
                        } header: {
                            Text("Abschliessen")
                        }
                    }
                }
            }

            pdfSection
        }
        .navigationTitle("Monatsabschluss")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: month) {
            conflict = nil
            forceMode = false
            fileURL = nil
            check = nil
            checkError = nil
            if !AppMode.isDemo && period == nil { await loadCheck() }
        }
        .sheet(item: $form) { target in
            TripFormView(vehicle: vehicle, trip: target.value)
        }
        .sheet(item: $confirmation) { summary in
            MonthCloseConfirmView(summary: summary) {
                Task { await close(force: summary.force) }
            }
        }
        .quickLookPreview($previewURL)
        .errorAlert($error)
    }

    // MARK: Checkliste

    private func checklistSection(_ c: MonthChecklist) -> some View {
        Section {
            CheckRow(title: "Alle Fahrten bestätigt", ok: c.open.isEmpty,
                     detail: c.open.isEmpty ? nil : "\(c.open.count) offen")
            tripLinks(c.open)
            CheckRow(title: "Geschäftliche Fahrten mit Zweck", ok: c.missingPurpose.isEmpty,
                     detail: c.missingPurpose.isEmpty ? nil : "\(c.missingPurpose.count) ohne Zweck oder Kunde")
            tripLinks(c.missingPurpose)
            CheckRow(title: "Kilometerstand und Endzeit erfasst", ok: c.incomplete.isEmpty,
                     detail: c.incomplete.isEmpty ? nil : "\(c.incomplete.count) unvollständig")
            tripLinks(c.incomplete)
            CheckRow(title: "Kilometerstände abgelesen (nicht geschätzt)", ok: c.estimated.isEmpty,
                     detail: c.estimated.isEmpty ? nil : "\(c.estimated.count) geschätzt")
            tripLinks(c.estimated)
            CheckRow(title: "Keine Lücke in der Kilometerkette", ok: c.gaps.isEmpty,
                     detail: c.gaps.isEmpty ? nil : GapText.summary(c.gaps))
            CheckRow(title: "Abgleich mit Tankvorgängen/Kilometerständen", ok: c.odometerOk, detail: odometerDetail)
            CheckRow(title: "Alles synchronisiert", ok: c.pendingOps == 0,
                     detail: c.pendingOps == 0 ? nil : "\(c.pendingOps) Änderung(en) ausstehend")
            if c.pendingOps > 0 {
                Button("Jetzt synchronisieren") { Task { await store.sync() } }
                    .disabled(store.isSyncing)
            }
            ForEach(c.mismatches) { m in
                Label(m.reason ?? "Abweichung", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Color.warningText)
            }
            Button {
                Task { await loadCheck() }
            } label: {
                HStack {
                    Label("Server-Prüfung aktualisieren", systemImage: "arrow.clockwise")
                    if loadingCheck { Spacer(); ProgressView() }
                }
            }
            .disabled(loadingCheck || AppMode.isDemo)
            if let checkError {
                Label(checkError, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(Color.warningText)
            }
        } header: {
            Text("Checkliste")
        } footer: {
            if !isPast {
                Text("Der Monat läuft noch – der Abschluss ist erst im Folgemonat möglich.")
            }
        }
    }

    @ViewBuilder
    private func tripLinks(_ list: [Trip]) -> some View {
        ForEach(list.prefix(5)) { t in
            Button {
                form = EditTarget(value: t)
            } label: {
                Text("\(dayText(t)) · \(store.routeLabel(t))")
                    .font(.footnote)
            }
        }
        if list.count > 5 {
            Text("… und \(list.count - 5) weitere").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var odometerDetail: String {
        if let o = check?.odometerCheck { return OdometerText.describe(o) }
        return AppMode.isDemo ? "Server-Prüfung im Demo-Modus nicht verfügbar" : "Server-Prüfung ausstehend (online)"
    }

    private func monthTitle(_ m: String) -> String {
        if store.isMonthClosed(vehicleId: vehicle.id, month: m) { return "\(TripMonth.label(m)) (abgeschlossen)" }
        if m >= TripMonth.current() { return "\(TripMonth.label(m)) (läuft)" }
        return TripMonth.label(m)
    }

    private func dayText(_ t: Trip) -> String {
        guard let d = t.startDate else { return t.startAt }
        return "\(Fmt.weekdayDay(d)) \(Fmt.time(d))"
    }

    // MARK: Abgeschlossen

    private func closedSection(_ p: TripPeriod) -> some View {
        Section {
            Label("Abgeschlossen", systemImage: "lock.fill").foregroundStyle(Color.successText)
            if let resultText {
                Text(resultText).font(.footnote).foregroundStyle(Color.neutralText)
            }
            if let d = p.closedDate {
                LabeledContent("Am", value: Fmt.dateTime(d))
            }
            if let by = p.closedBy { LabeledContent("Durch", value: by) }
            if let a = p.kmStart, let b = p.kmEnd {
                LabeledContent("Kilometerstand", value: "\(Fmt.km(a)) – \(Fmt.km(b))")
            }
            LabeledContent("Fahrten", value: "\(p.tripsCount)")
            LabeledContent(TripCategory.business.uiLabel, value: Fmt.kmD(p.businessKm))
            LabeledContent(TripCategory.personal.uiLabel, value: Fmt.kmD(p.privateKm))
            LabeledContent(TripCategory.commute.uiLabel, value: Fmt.kmD(p.commuteKm))
            LabeledContent(TripCategory.field.uiLabel, value: Fmt.kmD(p.fieldKm))
            if let n = p.corrections, n > 0 {
                LabeledContent("Korrekturen nach Abschluss", value: "\(n)")
            }
            if let note = p.note?.nilIfEmpty {
                Label(note, systemImage: "exclamationmark.lock")
                    .font(.footnote)
                    .foregroundStyle(Color.warningText)
            }
        } header: {
            Text("Status")
        } footer: {
            Text("Fahrten dieses Monats sind gesperrt. Korrekturen nur per Storno bzw. neuer Fahrt mit Begründung; "
                 + "der Abschluss ist mit einem Integritätsanker gesichert.")
        }
    }

    // MARK: Abschliessen

    private func closeSection(_ c: MonthChecklist) -> some View {
        Section {
            Button {
                confirmation = MonthCloseSummary.make(month: month, vehicleName: vehicle.name, checklist: c,
                                                      force: false, reason: "")
            } label: {
                HStack {
                    Label("Monat abschliessen …", systemImage: "lock.doc")
                    if closing { Spacer(); ProgressView() }
                }
            }
            .disabled(!c.allOk || closing || AppMode.isDemo)
            if let conflict {
                Label(conflict, systemImage: "exclamationmark.octagon")
                    .foregroundStyle(Color.dangerText)
                    .font(.subheadline)
            }
        } header: {
            Text("Abschliessen")
        } footer: {
            if c.allOk {
                Text("Nach dem Abschluss sind die Fahrten unveränderlich. Vor dem Abschluss folgt eine Zusammenfassung.")
            } else {
                Text("Möglich, sobald alle Punkte der Checkliste erfüllt sind.")
            }
        }
    }

    private func forceSection(_ c: MonthChecklist) -> some View {
        Section {
            if forceMode {
                TextField("Begründung (mind. \(CorrectionReason.minLength) Zeichen)", text: $forceReason,
                          axis: .vertical)
                Text(CorrectionReason.hint(forceReason))
                    .font(.footnote)
                    .foregroundStyle(reasonValid ? Color.secondary : Color.warningText)
                Button(role: .destructive) {
                    confirmation = MonthCloseSummary.make(month: month, vehicleName: vehicle.name, checklist: c,
                                                          force: true, reason: forceReason.trimmed)
                } label: {
                    Label("Trotzdem abschliessen …", systemImage: "exclamationmark.lock")
                }
                .disabled(closing || !reasonValid || AppMode.isDemo)
            } else {
                Button {
                    forceMode = true
                } label: {
                    Label("Trotzdem abschliessen (mit Begründung)", systemImage: "exclamationmark.lock")
                }
                .disabled(AppMode.isDemo)
            }
        } footer: {
            Text("Nur in begründeten Ausnahmen: Offene Punkte und Begründung werden im Fahrtenbuch vermerkt.")
        }
    }

    private var pdfSection: some View {
        Section {
            Button {
                Task { await loadPDF() }
            } label: {
                HStack {
                    Label("Fahrtenbuch-PDF erstellen", systemImage: "doc.richtext")
                    if loadingPDF { Spacer(); ProgressView() }
                }
            }
            .disabled(loadingPDF || AppMode.isDemo)
            if let fileURL {
                Button { previewURL = fileURL } label: { Label("Vorschau", systemImage: "eye") }
                ShareLink(item: fileURL) { Label("Teilen / Sichern", systemImage: "square.and.arrow.up") }
            }
        } header: {
            Text("Fahrtenbuch")
        } footer: {
            if !store.outbox.isEmpty {
                Text("\(store.outbox.count) Änderung(en) noch nicht synchronisiert – sie fehlen im PDF.")
                    .foregroundStyle(Color.warningText)
            }
        }
    }

    // MARK: Server

    private func loadCheck() async {
        guard !AppMode.isDemo else { return }
        loadingCheck = true
        defer { loadingCheck = false }
        do {
            check = try await TripServer.check(settings, store, vehicleId: vehicle.id, month: month)
            checkError = nil
        } catch {
            checkError = "Server-Prüfung nicht möglich: \(error.userMessage)"
        }
    }

    private func close(force: Bool) async {
        guard !AppMode.isDemo, isPast else { return }
        closing = true
        defer { closing = false }
        await store.sync()   // ausstehende Fahrten zuerst übertragen
        let reason: String? = force ? forceReason.trimmed : nil
        do {
            let response = try await store.closeMonth(vehicleId: vehicle.id, month: month, force: force,
                                                      reason: reason)
            store.storePeriod(response.period)
            conflict = nil
            forceMode = false
            forceReason = ""
            resultText = Self.summaryText(response)
            await store.sync()   // gesperrte Fahrten holen
        } catch let e as APIError where e.status == 409 {
            conflict = e.userMessage
            forceMode = true
            await loadCheck()
        } catch {
            self.error = "Abschluss fehlgeschlagen: \(error.userMessage)"
        }
    }

    private static func summaryText(_ r: PeriodCloseResponse) -> String {
        var parts: [String] = []
        if let n = r.lockedTrips { parts.append(n == 1 ? "1 Fahrt gesperrt" : "\(n) Fahrten gesperrt") }
        if let g = r.gaps, g > 0 { parts.append(g == 1 ? "1 Lücke vermerkt" : "\(g) Lücken vermerkt") }
        if r.forced == true { parts.append("mit Begründung erzwungen") }
        return parts.isEmpty ? "Monat abgeschlossen." : parts.joined(separator: " · ")
    }

    private func loadPDF() async {
        loadingPDF = true
        defer { loadingPDF = false }
        await store.sync()
        do {
            let url = try await TripServer.download(
                settings, store, vehicleId: vehicle.id, file: "logbook.pdf",
                query: [URLQueryItem(name: "month", value: month)],
                name: "Fahrzeugbuch_Fahrtenbuch_\(vehicle.name)_\(month).pdf")
            fileURL = url
            previewURL = url
        } catch {
            self.error = "Fahrtenbuch-PDF nicht erstellt: \(error.userMessage)"
        }
    }
}

// MARK: Berichte

/// Fahrtenbuch-PDF, CSV-Export und Jahresbericht (Privatanteil, Kilometerentschädigung, Arbeitsweg-Abzug).
@MainActor
struct TripReportsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TenantStore.self) private var store
    let vehicle: Vehicle

    @State private var month = TripMonth.previous()
    @State private var from = Calendar.current.date(from: Calendar.current.dateComponents([.year], from: Date())) ?? Date()
    @State private var to = Date()
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var report: YearReport?
    @State private var reportError: String?
    @State private var loadingReport = false
    @State private var busy: String?
    @State private var logbookURL: URL?
    @State private var csvURL: URL?
    @State private var yearPDF: URL?
    @State private var previewURL: URL?
    @State private var error: String?

    init(vehicle: Vehicle) {
        self.vehicle = vehicle
    }

    private static let itemOrder = ["private_share_flat", "private_share_effective",
                                    "private_share_effective_incl_commute", "km_compensation",
                                    "commute_deduction_federal", "commute_deduction_canton"]

    var body: some View {
        Form {
            Section {
                Picker("Monat", selection: $month) {
                    ForEach(TripMonth.recent(13), id: \.self) { m in
                        Text(TripMonth.label(m)).tag(m)
                    }
                }
                downloadButton("Fahrtenbuch-PDF erstellen", icon: "doc.richtext", key: "logbook") {
                    await loadLogbook()
                }
                fileLinks(logbookURL)
            } header: {
                Text("Fahrtenbuch (PDF)")
            }

            Section {
                DatePicker("Von", selection: $from, in: ...to, displayedComponents: .date)
                DatePicker("Bis", selection: $to, in: from..., displayedComponents: .date)
                downloadButton("CSV exportieren", icon: "tablecells", key: "csv") {
                    await loadCSV()
                }
                if let csvURL {
                    ShareLink(item: csvURL) { Label("CSV teilen / sichern", systemImage: "square.and.arrow.up") }
                }
            } header: {
                Text("Export (CSV)")
            } footer: {
                Text("Für Spesenabrechnung und Treuhand (z. B. Ablage in Paperless).")
            }

            Section {
                Stepper(value: $year, in: 2000...2100) {
                    LabeledContent("Jahr", value: String(year))
                }
                if loadingReport {
                    HStack { Text("Lade Jahresbericht …"); Spacer(); ProgressView() }
                }
                if let reportError {
                    Label(reportError, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(Color.warningText)
                }
            } header: {
                Text("Jahresbericht")
            }

            if let r = report {
                reportSections(r)
            }

            Section {
                downloadButton("Jahresbericht-PDF erstellen", icon: "doc.text.magnifyingglass", key: "year") {
                    await loadYearPDF()
                }
                fileLinks(yearPDF)
            } footer: {
                Text(report?.disclaimer ?? "Keine Steuer- oder Rechtsberatung. Annahmen – mit Treuhand prüfen.")
            }
        }
        .navigationTitle("Berichte")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: year) { await loadReport() }
        .quickLookPreview($previewURL)
        .errorAlert($error)
    }

    // MARK: Bausteine

    private func downloadButton(_ title: String, icon: String, key: String,
                                action: @escaping () async -> Void) -> some View {
        Button {
            Task {
                busy = key
                await action()
                busy = nil
            }
        } label: {
            HStack {
                Label(title, systemImage: icon)
                if busy == key { Spacer(); ProgressView() }
            }
        }
        .disabled(busy != nil || AppMode.isDemo)
    }

    @ViewBuilder
    private func fileLinks(_ url: URL?) -> some View {
        if let url {
            Button { previewURL = url } label: { Label("Vorschau", systemImage: "eye") }
            ShareLink(item: url) { Label("Teilen / Sichern", systemImage: "square.and.arrow.up") }
        }
    }

    @ViewBuilder
    private func reportSections(_ r: YearReport) -> some View {
        Section {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(TripCategory.allCases) { c in
                    if c != .unknown || (r.km(c) ?? 0) > 0 {
                        categoryTile(c, km: r.km(c), share: r.share(c))
                    }
                }
            }
            .padding(.vertical, 4)
            if let total = r.totalKm {
                LabeledContent("Total", value: Fmt.kmD(total))
            }
            if let n = r.tripsCount {
                LabeledContent("Fahrten", value: "\(n)")
            }
        } header: {
            Text("Kilometer nach Kategorie")
        } footer: {
            if r.isLocal {
                Text("Lokal aus den Fahrten auf diesem Gerät berechnet – Steuerposten nur online.")
            }
        }

        let items = orderedItems(r)
        if !items.isEmpty {
            Section {
                ForEach(items, id: \.key) { entry in
                    itemRow(entry.item)
                }
            } header: {
                Text("Auswertung")
            } footer: {
                Text("Privatanteil: Pauschale vs. effektive Methode zum Vergleich – Entscheid mit Treuhand.")
            }
        }

        if !r.warnings.isEmpty {
            Section("Hinweise") {
                ForEach(r.warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(Color.warningText)
                }
            }
        }

        let params = r.params.values.sorted { ($0.key ?? "") < ($1.key ?? "") }
        if !params.isEmpty {
            Section {
                ForEach(params) { p in
                    paramRow(p)
                }
            } header: {
                Text("Verwendete Parameter")
            } footer: {
                Text("Annahmen – mit Treuhand prüfen. Eigene Werte unter Steuerparameter erfassen.")
            }
        }
    }

    private struct ItemEntry {
        let key: String
        let item: YearReportItem
    }

    private func orderedItems(_ r: YearReport) -> [ItemEntry] {
        var result: [ItemEntry] = []
        var used = Set<String>()
        for key in Self.itemOrder {
            if let item = r.item(key) {
                result.append(ItemEntry(key: key, item: item))
                used.insert(YearReport.normalized(key))
            }
        }
        for (key, item) in r.items.sorted(by: { $0.key < $1.key }) where !used.contains(YearReport.normalized(key)) {
            result.append(ItemEntry(key: key, item: item))
        }
        return result
    }

    private func categoryTile(_ c: TripCategory, km: Double?, share: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(c.uiLabel, systemImage: c.systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(c.textColor)
            Text(share.map { Fmt.pct($0) } ?? "–")
                .font(.title2.weight(.bold).monospacedDigit())
            Text(km.map { Fmt.kmD($0) } ?? "– km")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(c.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(c.uiLabel): \(share.map { Fmt.pct($0) } ?? "keine Angabe"), \(km.map { Fmt.kmD($0) } ?? "keine Kilometer")")
    }

    private func itemRow(_ item: YearReportItem) -> some View {
        let applicable = item.applicable ?? true
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.label ?? "Posten")
                Spacer()
                Text(item.value.map { Fmt.chf($0) } ?? "–")
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(applicable ? Color.primary : Color.secondary)
            }
            if let reason = item.reason?.nilIfEmpty {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            } else if let formula = item.formula?.nilIfEmpty {
                Text(formula).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func paramRow(_ p: YearReportParam) -> some View {
        let key = p.key ?? ""
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(p.label ?? TaxParam.label(key))
                Spacer()
                Text(p.value.map { TaxParam.valueText(key, $0) } ?? "–").monospacedDigit()
            }
            Text(paramMeta(p)).font(.caption).foregroundStyle(.secondary)
            if let s = p.sourceUrl, let url = URL(string: s) {
                Link(destination: url) {
                    Text(url.host() ?? s).font(.caption)
                }
            }
        }
    }

    private func paramMeta(_ p: YearReportParam) -> String {
        var parts: [String] = []
        if let s = p.scope { parts.append(TaxParam.scopeLabel(s)) }
        if let y = p.year { parts.append(String(y)) }
        if let n = p.note?.nilIfEmpty { parts.append(n) }
        return parts.joined(separator: " · ")
    }

    // MARK: Laden

    private var localReport: YearReport {
        YearReport.local(trips: store.trips(for: vehicle.id), year: year)
    }

    private func loadReport() async {
        guard !AppMode.isDemo else {
            report = localReport
            return
        }
        loadingReport = true
        defer { loadingReport = false }
        do {
            let r: YearReport = try await settings.api.get(
                "api/t/\(store.tenant.slug)/vehicles/\(vehicle.id)/year-report",
                query: [URLQueryItem(name: "year", value: String(year))])
            report = r
            reportError = nil
        } catch {
            report = localReport
            reportError = "Steuerposten nicht geladen: \(error.userMessage)"
        }
    }

    private func loadLogbook() async {
        await store.sync()
        do {
            let url = try await TripServer.download(
                settings, store, vehicleId: vehicle.id, file: "logbook.pdf",
                query: [URLQueryItem(name: "month", value: month)],
                name: "Fahrzeugbuch_Fahrtenbuch_\(vehicle.name)_\(month).pdf")
            logbookURL = url
            previewURL = url
        } catch {
            self.error = "Fahrtenbuch-PDF nicht erstellt: \(error.userMessage)"
        }
    }

    private func loadCSV() async {
        await store.sync()
        let f = APIClient.dayFormatter
        do {
            csvURL = try await TripServer.download(
                settings, store, vehicleId: vehicle.id, file: "trips.csv",
                query: [URLQueryItem(name: "from", value: f.string(from: from)),
                        URLQueryItem(name: "to", value: f.string(from: to))],
                name: "Fahrzeugbuch_Fahrten_\(vehicle.name)_\(f.string(from: from))_\(f.string(from: to)).csv")
        } catch {
            self.error = "CSV nicht erstellt: \(error.userMessage)"
        }
    }

    private func loadYearPDF() async {
        await store.sync()
        do {
            let url = try await TripServer.download(
                settings, store, vehicleId: vehicle.id, file: "year-report.pdf",
                query: [URLQueryItem(name: "year", value: String(year))],
                name: "Fahrzeugbuch_Jahresbericht_\(vehicle.name)_\(year).pdf")
            yearPDF = url
            previewURL = url
        } catch {
            self.error = "Jahresbericht-PDF nicht erstellt: \(error.userMessage)"
        }
    }
}
