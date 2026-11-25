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
        case .some(true): .green
        case .some(false): .red
        case .none: .secondary
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
                    Text(detail).font(.caption).foregroundStyle(.secondary)
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
                    Label("Keine Lücken in der km-Kette", systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                }
                ForEach(gaps) { g in
                    gapRow(g)
                }
            } header: {
                Text("km-Kette")
            } footer: {
                Text("Eine Lücke entsteht, wenn der km-Stand am Ende einer Fahrt nicht dem Beginn der nächsten "
                     + "entspricht. Fehlende Kilometer als Fahrt erfassen oder den km-Stand korrigieren.")
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
                    Text(checkError).font(.caption).foregroundStyle(.orange)
                }
                if let check {
                    serverResult(check)
                }
            } header: {
                Text("Server-Prüfung")
            } footer: {
                Text("Prüft zusätzlich fehlende km-Stände, Abweichungen GPS/Route und den Abgleich mit Tank- "
                     + "und Kilometerständen (nur online).")
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
                                    Label(c.label, systemImage: c.systemImage)
                                }
                            }
                        } label: {
                            Label("Als Fahrt erfassen", systemImage: "plus.circle")
                        }
                    }
                    Menu {
                        if let a = after, !a.isLocked {
                            Button("km-Ende der vorherigen Fahrt") { form = EditTarget(value: a) }
                        }
                        if let b = before, !b.isLocked {
                            Button("km-Beginn der nächsten Fahrt") { form = EditTarget(value: b) }
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
        CheckRow(title: "Keine km-Lücken", ok: c.gaps.isEmpty, detail: gapDetail)
        CheckRow(title: "Alle Fahrten bestätigt", ok: openCount == 0, detail: openDetail)
        if let o = c.odometerCheck {
            CheckRow(title: "km-Abgleich Tank/Odometer", ok: o.ok, detail: OdometerText.describe(o))
        }
        ForEach(c.mismatches) { m in
            Button {
                if let id = m.tripId, let t = store.trip(id: id) { form = EditTarget(value: t) }
            } label: {
                Label(mismatchText(m), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
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
            checkError = "Nur online verfügbar: \(error.localizedDescription)"
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
        if let k = o.odometerKm { parts.append("km-Stände \(Fmt.kmD(k))") }
        if let d = o.diffKm { parts.append("Differenz \(Fmt.kmD(d))") }
        return parts.isEmpty ? "Keine Angaben" : parts.joined(separator: " · ")
    }
}

// MARK: Monatsabschluss

/// Monatsabschluss: Checkliste, Abschliessen (POST close, ggf. erzwungen), Fahrtenbuch-PDF.
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
    @State private var forceAllowed = false
    @State private var forceReason = ""
    @State private var fileURL: URL?
    @State private var previewURL: URL?
    @State private var loadingPDF = false
    @State private var error: String?
    @State private var form: EditTarget<Trip>?

    init(vehicle: Vehicle, month: String? = nil) {
        self.vehicle = vehicle
        _month = State(initialValue: month ?? TripMonth.previous())
    }

    private var months: [String] {
        var set = Set(TripMonth.recent(13))
        for t in store.trips(for: vehicle.id) { set.insert(t.monthKey) }
        return set.sorted(by: >)
    }

    private var period: TripPeriod? { store.period(vehicleId: vehicle.id, month: month) }

    private var reasonValid: Bool { forceReason.trimmed.count >= 10 }

    var body: some View {
        let trips = store.trips(for: vehicle.id, month: month)
        let open = trips.filter(\.needsReview)
        let gaps = store.gaps(for: vehicle.id, month: month)
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
                Section {
                    CheckRow(title: "Alle Fahrten bestätigt", ok: open.isEmpty,
                             detail: open.isEmpty ? nil : "\(open.count) offen")
                    if !open.isEmpty {
                        ForEach(open) { t in
                            Button {
                                form = EditTarget(value: t)
                            } label: {
                                Text("\(dayText(t)) · \(store.routeText(t))")
                                    .font(.caption)
                            }
                        }
                    }
                    CheckRow(title: "Keine km-Lücke", ok: gaps.isEmpty,
                             detail: gaps.isEmpty ? nil : GapText.summary(gaps))
                    CheckRow(title: "km-Abgleich mit Tank-/km-Ständen", ok: check?.odometerCheck?.ok,
                             detail: odometerDetail)
                    CheckRow(title: "Alles synchronisiert", ok: store.outbox.isEmpty,
                             detail: store.outbox.isEmpty ? nil : "\(store.outbox.count) Änderung(en) ausstehend")
                    if let c = check, !c.mismatches.isEmpty {
                        ForEach(c.mismatches) { m in
                            Label(m.reason ?? "Abweichung", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
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
                        Text(checkError).font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Checkliste")
                } footer: {
                    if month == TripMonth.current() {
                        Text("Der Monat läuft noch – üblich ist der Abschluss im Folgemonat.")
                    }
                }

                if store.canWrite {
                    closeSection
                }
            }

            pdfSection
        }
        .navigationTitle("Monatsabschluss")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: month) {
            conflict = nil
            forceAllowed = false
            fileURL = nil
            check = nil
            if !AppMode.isDemo && period == nil { await loadCheck() }
        }
        .sheet(item: $form) { target in
            TripFormView(vehicle: vehicle, trip: target.value)
        }
        .quickLookPreview($previewURL)
        .errorAlert($error)
    }

    private var odometerDetail: String {
        if let o = check?.odometerCheck { return OdometerText.describe(o) }
        return AppMode.isDemo ? "Server-Prüfung im Demo-Modus nicht verfügbar" : "Server-Prüfung ausstehend (online)"
    }

    private func monthTitle(_ m: String) -> String {
        store.isMonthClosed(vehicleId: vehicle.id, month: m) ? "\(TripMonth.label(m)) (abgeschlossen)" : TripMonth.label(m)
    }

    private func dayText(_ t: Trip) -> String {
        guard let d = t.startDate else { return t.startAt }
        return "\(Fmt.weekdayDay(d)) \(Fmt.time(d))"
    }

    private func closedSection(_ p: TripPeriod) -> some View {
        Section {
            Label("Abgeschlossen", systemImage: "lock.fill").foregroundStyle(.green)
            if let d = p.closedDate {
                LabeledContent("Am", value: Fmt.dateTime(d))
            }
            if let by = p.closedBy { LabeledContent("Durch", value: by) }
            if let a = p.kmStart, let b = p.kmEnd {
                LabeledContent("km-Stand", value: "\(Fmt.km(a)) – \(Fmt.km(b))")
            }
            LabeledContent("Fahrten", value: "\(p.tripsCount)")
            LabeledContent(TripCategory.business.label, value: Fmt.kmD(p.businessKm))
            LabeledContent(TripCategory.personal.label, value: Fmt.kmD(p.privateKm))
            LabeledContent(TripCategory.commute.label, value: Fmt.kmD(p.commuteKm))
            LabeledContent(TripCategory.field.label, value: Fmt.kmD(p.fieldKm))
            if let note = p.note?.nilIfEmpty {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Status")
        } footer: {
            Text("Fahrten dieses Monats sind gesperrt. Korrekturen nur per Storno und neuer Fahrt mit Begründung; "
                 + "der Abschluss ist mit einem Integritätsanker gesichert.")
        }
    }

    private var closeSection: some View {
        Section {
            Button {
                Task { await close(force: false) }
            } label: {
                HStack {
                    Label("Monat abschliessen", systemImage: "lock.doc")
                    if closing { Spacer(); ProgressView() }
                }
            }
            .disabled(closing || AppMode.isDemo)
            if let conflict {
                Label(conflict, systemImage: "exclamationmark.octagon")
                    .foregroundStyle(.red)
                    .font(.subheadline)
            }
            if forceAllowed {
                TextField("Begründung (mind. 10 Zeichen)", text: $forceReason, axis: .vertical)
                Button(role: .destructive) {
                    Task { await close(force: true) }
                } label: {
                    Label("Trotz Lücken abschliessen", systemImage: "exclamationmark.lock")
                }
                .disabled(closing || !reasonValid)
            }
        } header: {
            Text("Abschliessen")
        } footer: {
            Text("Nach dem Abschluss sind die Fahrten unveränderlich. Ein erzwungener Abschluss trotz Lücken "
                 + "wird mit Begründung im Fahrtenbuch vermerkt.")
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
                    .foregroundStyle(.orange)
            }
        }
    }

    private func loadCheck() async {
        guard !AppMode.isDemo else { return }
        loadingCheck = true
        defer { loadingCheck = false }
        do {
            check = try await TripServer.check(settings, store, vehicleId: vehicle.id, month: month)
            checkError = nil
        } catch {
            checkError = "Nur online verfügbar: \(error.localizedDescription)"
        }
    }

    private func close(force: Bool) async {
        guard !AppMode.isDemo else { return }
        closing = true
        defer { closing = false }
        await store.sync()   // ausstehende Fahrten zuerst übertragen
        var payload: [String: Any] = ["force": force]
        if force { payload["reason"] = forceReason.trimmed }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            let closed: TripPeriod = try await settings.api.send(
                "POST", "api/t/\(store.tenant.slug)/vehicles/\(vehicle.id)/periods/\(month)/close", body: data)
            store.storePeriod(closed)
            conflict = nil
            forceAllowed = false
            forceReason = ""
            await store.sync()   // gesperrte Fahrten holen
        } catch let e as APIError where e.status == 409 {
            conflict = e.detailText
            forceAllowed = e.detailHasGaps
        } catch {
            self.error = "Abschluss nur online möglich: \(error.localizedDescription)"
        }
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
            self.error = "PDF nur online verfügbar: \(error.localizedDescription)"
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
                    Text(reportError).font(.caption).foregroundStyle(.orange)
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
                        .foregroundStyle(.orange)
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
            Label(c.label, systemImage: c.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(c.color)
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
        .accessibilityLabel("\(c.label): \(share.map { Fmt.pct($0) } ?? "keine Angabe"), \(km.map { Fmt.kmD($0) } ?? "keine Kilometer")")
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
            reportError = "Steuerposten nur online verfügbar: \(error.localizedDescription)"
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
            self.error = "PDF nur online verfügbar: \(error.localizedDescription)"
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
            self.error = "CSV nur online verfügbar: \(error.localizedDescription)"
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
            self.error = "PDF nur online verfügbar: \(error.localizedDescription)"
        }
    }
}
