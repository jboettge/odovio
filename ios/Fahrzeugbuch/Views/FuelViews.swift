import SwiftUI

/// Filter der Tankliste.
enum FuelFilter: String, CaseIterable, Identifiable {
    case all, full, partial, pending
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "Alle"
        case .full: "Volltankungen"
        case .partial: "Teilbetankungen"
        case .pending: "Nicht synchronisiert"
        }
    }
}

struct FuelListView: View {
    @Environment(TenantStore.self) private var store
    let vehicle: Vehicle
    @State private var form: EditTarget<FuelEntry>?
    @State private var toDelete: FuelEntry?
    @State private var search = ""
    @State private var filter: FuelFilter = .all
    @State private var monthFilter: String?

    private var filterActive: Bool { filter != .all || monthFilter != nil || !search.trimmed.isEmpty }

    var body: some View {
        let all = store.fuel(for: vehicle.id)
        let consumption = Dictionary(
            StatsCalculator.consumptionPoints(all).map { ($0.km, $0.consumption) },
            uniquingKeysWith: { a, _ in a })
        let entries = filtered(all)
        List {
            if !all.isEmpty {
                Section {
                    filterBar(Self.months(all))
                } footer: {
                    if filterActive {
                        Text(entries.count == 1 ? "1 Tankvorgang gefunden" : "\(entries.count) Tankvorgänge gefunden")
                    }
                }
            }
            if !all.isEmpty && entries.isEmpty {
                Section {
                    Text("Keine Tankvorgänge für diese Suche bzw. diesen Filter.").foregroundStyle(.secondary)
                }
            }
            ForEach(entries) { e in
                Button { form = EditTarget(value: e) } label: {
                    FuelRow(entry: e, consumption: consumption[e.km], pending: store.isPending(e.id))
                }
                .buttonStyle(.plain)
                .swipeActions {
                    if store.canWrite {
                        Button("Stornieren", role: .destructive) { toDelete = e }
                    }
                }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Tankstelle oder Notiz suchen")
        .overlay {
            if all.isEmpty {
                ContentUnavailableView("Keine Tankvorgänge", systemImage: "fuelpump",
                                       description: Text("Mit + den ersten Tankvorgang erfassen."))
            }
        }
        .toolbar {
            if store.canWrite {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { form = EditTarget(value: nil) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Tankvorgang hinzufügen")
                }
            }
        }
        .sheet(item: $form) { target in
            FuelFormView(vehicle: vehicle, entry: target.value)
        }
        .reasonedStorno($toDelete, title: "Tankvorgang stornieren?",
                        message: { _ in "Der Tankvorgang wird als storniert markiert und bleibt im Änderungsprotokoll erhalten." },
                        requiresReason: { store.requiresReason(fuel: $0) }) { entry, reason in
            store.delete(entry, reason: reason)
        }
        .refreshable { await store.sync() }
    }

    static func months(_ entries: [FuelEntry]) -> [String] {
        Array(Set(entries.map { TripMonth.key($0.date) })).sorted(by: >)
    }

    private func filtered(_ all: [FuelEntry]) -> [FuelEntry] {
        let q = search.trimmed
        return all.filter { e in
            if let m = monthFilter, TripMonth.key(e.date) != m { return false }
            switch filter {
            case .all: break
            case .full: if !e.fullTank { return false }
            case .partial: if e.fullTank { return false }
            case .pending: if !store.isPending(e.id) { return false }
            }
            if q.isEmpty { return true }
            let fields: [String] = [e.station ?? "", e.note ?? "", Fmt.day(e.date), String(e.km)]
            return fields.contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    private func filterBar(_ months: [String]) -> some View {
        HStack(spacing: 8) {
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
                Picker("Filter", selection: $filter) {
                    ForEach(FuelFilter.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }
            } label: {
                FilterChip(title: filter == .all ? "Filter" : filter.label,
                           icon: "line.3.horizontal.decrease.circle", active: filter != .all)
            }
            .accessibilityLabel("Tankvorgänge filtern")
            Spacer(minLength: 0)
        }
    }
}

struct PendingBadge: View {
    var body: some View {
        StatusTag(text: "Ausstehend", color: .orange, systemImage: "icloud.and.arrow.up")
            .accessibilityLabel("Noch nicht synchronisiert")
    }
}

private struct FuelRow: View {
    let entry: FuelEntry
    let consumption: Double?
    let pending: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.day(entry.date)).font(.headline)
                Spacer(minLength: 6)
                Text(Fmt.chf(entry.priceTotal)).font(.headline)
            }
            if !entry.fullTank || pending {
                HStack(spacing: 6) {
                    if !entry.fullTank { StatusTag(text: "Teilbetankung", systemImage: "drop.halffull") }
                    if pending { PendingBadge() }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("\(Fmt.km(entry.km)) · \(Fmt.num(entry.liters)) l · CHF \(Fmt.num(entry.pricePerLiter, 3))/l")
                    Spacer()
                    if let c = consumption {
                        Text("\(Fmt.num(c, 1)) l/100 km").bold()
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(Fmt.km(entry.km))
                    Text("\(Fmt.num(entry.liters)) l · CHF \(Fmt.num(entry.pricePerLiter, 3))/l")
                    if let c = consumption {
                        Text("\(Fmt.num(c, 1)) l/100 km").bold()
                    }
                }
            }
            .font(.subheadline)
            .foregroundStyle(Color.neutralText)
            if let s = entry.station, !s.isEmpty {
                Text(s).font(.footnote).foregroundStyle(Color.neutralText)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct FuelFormView: View {
    @Environment(TenantStore.self) private var store
    let vehicle: Vehicle
    let entry: FuelEntry?

    enum Field { case km, liters, price }
    @FocusState private var focus: Field?
    @State private var date = Date()
    @State private var km = ""
    @State private var liters = ""
    @State private var price = ""
    @State private var fullTank = true
    @State private var station = ""
    @State private var note = ""
    @State private var didPrefill = false
    @State private var reason = ""
    @State private var initial = ""
    /// Letzter bekannter Kilometerstand (Platzhalter statt Vorbelegung, U6)
    @State private var lastKm = 0
    /// Scan (Zapfsäule/Quittung bzw. Tacho)
    @State private var scan: ScanRequest?
    /// Belege, die beim Sichern angelegt werden (nach der Tankung → Reihenfolge in der Outbox)
    @State private var newAttachments: [PendingAttachment] = []

    private var savedAttachments: [Attachment] {
        entry.map { store.attachments(forFuel: $0.id) } ?? []
    }

    /// Plausibilität des Tacho-Scans: höchster bekannter Stand (nur bei neuer Tankung)
    private var lastKmForScan: Int? {
        guard entry == nil else { return nil }
        let last = store.lastKnownKm(for: vehicle.id)
        return last > 0 ? last : nil
    }

    private var snapshot: String {
        FormSnapshot.make([FormSnapshot.date(date), km, liters, price, String(fullTank), station, note,
                           String(newAttachments.count), reason])
    }

    private var hasChanges: Bool { didPrefill && snapshot != initial }

    /// Eintrag mit den aktuellen Eingaben (für die Begründungspflicht)
    private var candidate: FuelEntry {
        var e = entry ?? FuelEntry(vehicleId: vehicle.id, date: date, km: km.asInt ?? 0, liters: liters.asDouble ?? 0,
                                   priceTotal: price.asDouble ?? 0)
        e.date = date
        return e
    }

    private var reasonRequired: Bool { store.requiresReason(fuel: candidate) }

    private var kmPlaceholder: String {
        lastKm > 0 ? "zuletzt \(lastKm.formatted(.number))" : "vom Tacho"
    }

    private var pricePerLiter: Double? {
        guard let l = liters.asDouble, l > 0, let p = price.asDouble else { return nil }
        return p / l
    }

    private var missing: [String] {
        var m: [String] = []
        if km.asInt == nil { m.append("Kilometerstand") }
        if (liters.asDouble ?? 0) <= 0 { m.append("Liter") }
        if price.asDouble == nil { m.append("Betrag") }
        return m
    }

    /// Plausibilitätsprüfung – warnt, blockiert nicht.
    private var warnings: [String] {
        var w: [String] = []
        let others = store.fuel(for: vehicle.id).filter { $0.id != entry?.id }
        if let k = km.asInt {
            if entry == nil && lastKm > 0 && k == lastKm {
                w.append("Kilometerstand unverändert gegenüber dem letzten Eintrag – bitte vom Tacho ablesen.")
            }
            let earlier = others.filter { $0.date <= date }.map(\.km).max() ?? 0
            if k < earlier { w.append("Kilometerstand kleiner als bei einer früheren Tankung (\(Fmt.km(earlier))).") }
            if let l = liters.asDouble, l > 0, fullTank,
               let prevFull = others.filter({ $0.fullTank && $0.km < k }).max(by: { $0.km < $1.km }) {
                let partial = others.filter { !$0.fullTank && $0.km > prevFull.km && $0.km < k }.reduce(0) { $0 + $1.liters }
                let dist = Double(k - prevFull.km)
                let cons = (l + partial) / dist * 100
                if cons > 25 || cons < 2 {
                    w.append("Ergibt \(Fmt.num(cons, 1)) l/100 km – Eingaben prüfen (Teilbetankung?).")
                }
            }
        }
        if let ppl = pricePerLiter, ppl > 4 || ppl < 0.8 {
            w.append("Literpreis CHF \(Fmt.num(ppl, 3)) ungewöhnlich.")
        }
        return w
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Datum", selection: $date, displayedComponents: .date)
                    HStack(spacing: 8) {
                        UnitField("Kilometerstand", text: $km, unit: "km", keyboard: .numberPad,
                                  placeholder: kmPlaceholder)
                            .focused($focus, equals: .km)
                        if store.canWrite {
                            Button { scan = ScanRequest(kind: .odometer) } label: {
                                Image(systemName: "camera")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Kilometerstand vom Tacho scannen")
                        }
                    }
                    UnitField("Liter", text: $liters, unit: "l", placeholder: "0.00").focused($focus, equals: .liters)
                    UnitField("Betrag", text: $price, unit: "CHF", placeholder: "0.00").focused($focus, equals: .price)
                    if let ppl = pricePerLiter {
                        LabeledContent("Preis pro Liter", value: "CHF \(Fmt.num(ppl, 3))")
                    }
                    Toggle("Vollgetankt", isOn: $fullTank)
                } header: {
                    if store.canWrite {
                        Button { scan = ScanRequest(kind: .pump) } label: {
                            Label("Zapfsäule/Quittung scannen", systemImage: "camera.viewfinder")
                                .font(.subheadline.weight(.semibold))
                        }
                        .textCase(nil)
                        .accessibilityHint("Liter, Betrag und Preis pro Liter per Kamera erfassen")
                    }
                } footer: {
                    if !missing.isEmpty && (!liters.isEmpty || !price.isEmpty) {
                        Text("Erforderlich: \(missing.joined(separator: ", "))").foregroundStyle(Color.warningText)
                    } else {
                        Text("Für die Verbrauchsberechnung immer voll tanken oder Teilbetankungen als solche markieren.")
                    }
                }
                if !warnings.isEmpty {
                    Section {
                        ForEach(warnings, id: \.self) { w in
                            Label(w, systemImage: "exclamationmark.triangle").foregroundStyle(Color.warningText)
                        }
                    }
                }
                if reasonRequired && store.canWrite {
                    ReasonSection(reason: $reason, monthLabel: TripMonth.label(TripMonth.key(date)))
                }
                Section("Optional") {
                    TextField("Tankstelle", text: $station)
                    TextField("Notiz", text: $note, axis: .vertical)
                }
                if !savedAttachments.isEmpty || !newAttachments.isEmpty {
                    Section {
                        AttachmentStrip(attachments: savedAttachments, pending: newAttachments) { p in
                            newAttachments.removeAll { $0.id == p.id }
                        }
                    } header: {
                        Text("Belege")
                    } footer: {
                        if !newAttachments.isEmpty {
                            Text("Neue Belege werden beim Sichern gespeichert. Gedrückt halten zum Entfernen bzw. Stornieren.")
                        } else {
                            Text("Tippen zum Anzeigen, gedrückt halten zum Stornieren.")
                        }
                    }
                }
                if let e = entry {
                    HistorySection(entity: FuelEntry.entityName, id: e.id)
                }
                if !store.canWrite {
                    Section { Label("Nur Lesezugriff", systemImage: "eye").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(entry == nil ? "Tankvorgang" : "Tankvorgang bearbeiten")
            .formToolbar(canSave: store.canWrite && missing.isEmpty
                            && (!reasonRequired || CorrectionReason.isValid(reason)),
                         hasChanges: hasChanges, save: save)
            .onAppear(perform: prefill)
            .sheet(item: $scan) { request in
                ScannerView(kinds: request.kind == .odometer ? [.odometer] : [.pump, .receipt],
                            initialKind: request.kind,
                            lastKnownKm: request.kind == .odometer ? lastKmForScan : nil) { outcome in
                    apply(outcome)
                }
            }
        }
    }

    /// Scan-Ergebnis übernehmen; die Plausibilitätswarnungen greifen danach wie bei manueller Eingabe.
    private func apply(_ outcome: ScanOutcome) {
        if let l = outcome.liters { liters = Fmt.edit(l) }
        if let a = outcome.amount { price = Fmt.edit(a) }
        if let k = outcome.km { km = String(k) }
        if let d = outcome.date { date = d }
        if let s = outcome.station?.nilIfEmpty { station = s }
        if let data = outcome.attachmentJPEG {
            newAttachments.append(PendingAttachment(kind: outcome.kind, data: data))
        }
    }

    private func prefill() {
        // nur einmal (Vollbild-Ansichten lösen onAppear erneut aus)
        guard !didPrefill else { return }
        didPrefill = true
        defer { initial = snapshot }
        guard let e = entry else {
            // Letzter Stand nur als Platzhalter – der Kilometerstand muss abgelesen werden (U6)
            lastKm = store.lastKnownKm(for: vehicle.id)
            focus = .km
            return
        }
        date = e.date
        km = String(e.km)
        liters = Fmt.edit(e.liters)
        price = Fmt.edit(e.priceTotal)
        fullTank = e.fullTank
        station = e.station ?? ""
        note = e.note ?? ""
    }

    private func save() {
        guard let kmValue = km.asInt, let l = liters.asDouble, let p = price.asDouble else { return }
        var e = entry ?? FuelEntry(vehicleId: vehicle.id, date: date, km: kmValue, liters: l, priceTotal: p)
        e.date = date
        e.km = kmValue
        e.liters = l
        e.priceTotal = p
        e.fullTank = fullTank
        e.station = station.nilIfEmpty
        e.note = note.nilIfEmpty
        store.save(e, reason: reasonRequired ? reason.trimmed : nil)
        // Belege erst nach der Tankung anlegen (Server kennt fuel_id dann bereits)
        for attachment in newAttachments {
            store.addAttachment(imageData: attachment.data, kind: attachment.kind.rawValue, fuelId: e.id,
                                maintenanceId: nil, vehicleId: vehicle.id)
        }
        newAttachments = []
    }
}
