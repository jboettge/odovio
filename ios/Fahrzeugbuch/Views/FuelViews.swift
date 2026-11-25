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
                .foregroundStyle(.primary)
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
        Image(systemName: "icloud.and.arrow.up")
            .font(.caption2)
            .foregroundStyle(.orange)
            .accessibilityLabel("Noch nicht synchronisiert")
    }
}

private struct FuelRow: View {
    let entry: FuelEntry
    let consumption: Double?
    let pending: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Fmt.day(entry.date)).font(.headline)
                if !entry.fullTank {
                    Text("Teilbetankung")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange.opacity(0.2), in: Capsule())
                }
                if pending { PendingBadge() }
                Spacer()
                Text(Fmt.chf(entry.priceTotal)).font(.headline)
            }
            HStack {
                Text("\(Fmt.km(entry.km)) · \(Fmt.num(entry.liters)) l · \(Fmt.num(entry.pricePerLiter, 3))/l")
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
    }
}

struct FuelFormView: View {
    @Environment(TenantStore.self) private var store
    let vehicle: Vehicle
    let entry: FuelEntry?

    @State private var date = Date()
    @State private var km = ""
    @State private var liters = ""
    @State private var price = ""
    @State private var fullTank = true
    @State private var station = ""
    @State private var note = ""

    private var pricePerLiter: Double? {
        guard let l = liters.asDouble, l > 0, let p = price.asDouble else { return nil }
        return p / l
    }

    private var valid: Bool {
        store.canWrite && km.asInt != nil && (liters.asDouble ?? 0) > 0 && price.asDouble != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Datum", selection: $date, displayedComponents: .date)
                    LabeledContent("Kilometerstand") {
                        TextField("km", text: $km).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Liter") {
                        TextField("0.00", text: $liters).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Betrag (CHF)") {
                        TextField("0.00", text: $price).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    if let ppl = pricePerLiter {
                        LabeledContent("Preis pro Liter", value: "CHF \(Fmt.num(ppl, 3))")
                    }
                    Toggle("Vollgetankt", isOn: $fullTank)
                } footer: {
                    Text("Für die Verbrauchsberechnung immer voll tanken oder Teilbetankungen als solche markieren.")
                }
                Section("Optional") {
                    TextField("Tankstelle", text: $station)
                    TextField("Notiz", text: $note, axis: .vertical)
                }
                if let e = entry {
                    HistorySection(entity: FuelEntry.entityName, id: e.id)
                }
            }
            .navigationTitle(entry == nil ? "Tankvorgang" : "Tankvorgang bearbeiten")
            .formToolbar(canSave: valid, save: save)
            .onAppear(perform: prefill)
        }
    }

    private func prefill() {
        guard let e = entry else {
            let current = store.currentKm(store.vehicle(id: vehicle.id) ?? vehicle)
            if current > 0 { km = String(current) }
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
    }
}
