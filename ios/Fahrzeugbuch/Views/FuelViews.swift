import SwiftUI

struct FuelListView: View {
    @Environment(TenantStore.self) private var store
    let vehicle: Vehicle
    @State private var form: EditTarget<FuelEntry>?
    @State private var toDelete: FuelEntry?

    var body: some View {
        let entries = store.fuel(for: vehicle.id)
        let consumption = Dictionary(
            StatsCalculator.consumptionPoints(entries).map { ($0.km, $0.consumption) },
            uniquingKeysWith: { a, _ in a })
        List {
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
        .overlay {
            if entries.isEmpty {
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
        .stornoDialog($toDelete, title: "Tankvorgang stornieren?") { store.delete($0) }
        .refreshable { await store.sync() }
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
            HStack(spacing: 6) {
                Text(Fmt.day(entry.date)).font(.headline)
                if !entry.fullTank { StatusTag(text: "Teilbetankung") }
                if pending { PendingBadge() }
                Spacer()
                Text(Fmt.chf(entry.priceTotal)).font(.headline)
            }
            HStack {
                Text("\(Fmt.km(entry.km)) · \(Fmt.num(entry.liters)) l · CHF \(Fmt.num(entry.pricePerLiter, 3))/l")
                Spacer()
                if let c = consumption {
                    Text("\(Fmt.num(c, 1)) l/100 km").bold()
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if let s = entry.station, !s.isEmpty {
                Text(s).font(.caption).foregroundStyle(.secondary)
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
                        UnitField("Kilometerstand", text: $km, unit: "km", keyboard: .numberPad)
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
                        Text("Erforderlich: \(missing.joined(separator: ", "))").foregroundStyle(.orange)
                    } else {
                        Text("Für die Verbrauchsberechnung immer voll tanken oder Teilbetankungen als solche markieren.")
                    }
                }
                if !warnings.isEmpty {
                    Section {
                        ForEach(warnings, id: \.self) { w in
                            Label(w, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                    }
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
            .formToolbar(canSave: store.canWrite && missing.isEmpty, save: save)
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
        guard let e = entry else {
            let current = store.currentKm(store.vehicle(id: vehicle.id) ?? vehicle)
            if current > 0 { km = String(current) }
            focus = .liters   // an der Säule: zuerst Liter, dann Betrag
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
        store.save(e)
        // Belege erst nach der Tankung anlegen (Server kennt fuel_id dann bereits)
        for attachment in newAttachments {
            store.addAttachment(imageData: attachment.data, kind: attachment.kind.rawValue, fuelId: e.id,
                                maintenanceId: nil, vehicleId: vehicle.id)
        }
        newAttachments = []
    }
}
