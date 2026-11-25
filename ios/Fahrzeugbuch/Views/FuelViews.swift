import SwiftUI

struct FuelListView: View {
    @Environment(AppSettings.self) private var settings
    let vehicle: Vehicle
    @State private var entries: [FuelEntry] = []
    @State private var consumptionByKm: [Int: Double] = [:]
    @State private var loaded = false
    @State private var form: EditTarget<FuelEntry>?
    @State private var error: String?

    private var latestKm: Int { max(vehicle.currentKm, entries.map(\.km).max() ?? 0) }

    var body: some View {
        List {
            ForEach(entries) { e in
                Button { form = EditTarget(value: e) } label: {
                    FuelRow(entry: e, consumption: consumptionByKm[e.km])
                }
                .foregroundStyle(.primary)
            }
            .onDelete { offsets in Task { await delete(offsets) } }
        }
        .overlay {
            if loaded && entries.isEmpty {
                ContentUnavailableView("Keine Tankvorgänge", systemImage: "fuelpump",
                                       description: Text("Mit + den ersten Tankvorgang erfassen."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { form = EditTarget(value: nil) } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $form) { target in
            FuelFormView(vehicleID: vehicle.id, entry: target.value, suggestedKm: latestKm) { await load() }
        }
        .task { await load() }
        .refreshable { await load() }
        .errorAlert($error)
    }

    private func load() async {
        do {
            let api = settings.api
            async let list: [FuelEntry] = api.get("api/vehicles/\(vehicle.id)/fuel")
            async let stats: Stats = api.get("api/vehicles/\(vehicle.id)/stats")
            let (fetched, s) = try await (list, stats)
            entries = fetched
            consumptionByKm = Dictionary(s.points.map { ($0.km, $0.consumption) },
                                         uniquingKeysWith: { a, _ in a })
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func delete(_ offsets: IndexSet) async {
        let ids = offsets.map { entries[$0].id }
        entries.remove(atOffsets: offsets)
        do {
            for id in ids { try await settings.api.delete("api/fuel/\(id)") }
        } catch {
            self.error = error.localizedDescription
        }
        await load()
    }
}

private struct FuelRow: View {
    let entry: FuelEntry
    let consumption: Double?

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
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    let vehicleID: Int
    let entry: FuelEntry?
    let suggestedKm: Int
    let onSaved: () async -> Void

    @State private var date = Date()
    @State private var km = ""
    @State private var liters = ""
    @State private var price = ""
    @State private var fullTank = true
    @State private var station = ""
    @State private var note = ""
    @State private var saving = false
    @State private var error: String?

    private var pricePerLiter: Double? {
        guard let l = liters.asDouble, l > 0, let p = price.asDouble else { return nil }
        return p / l
    }

    private var valid: Bool {
        km.asInt != nil && (liters.asDouble ?? 0) > 0 && price.asDouble != nil
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
            }
            .navigationTitle(entry == nil ? "Tankvorgang" : "Tankvorgang bearbeiten")
            .formToolbar(canSave: valid, saving: saving) { await save() }
            .onAppear(perform: prefill)
            .errorAlert($error)
        }
    }

    private func prefill() {
        guard let e = entry else {
            if suggestedKm > 0 { km = String(suggestedKm) }
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

    private func save() async {
        guard let km = km.asInt, let l = liters.asDouble, let p = price.asDouble else { return }
        saving = true
        defer { saving = false }
        let input = FuelInput(date: date, km: km, liters: l, priceTotal: p, fullTank: fullTank,
                              station: station.nilIfEmpty, note: note.nilIfEmpty)
        do {
            if let e = entry {
                let _: FuelEntry = try await settings.api.put("api/fuel/\(e.id)", input)
            } else {
                let _: FuelEntry = try await settings.api.post("api/vehicles/\(vehicleID)/fuel", input)
            }
            await onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
