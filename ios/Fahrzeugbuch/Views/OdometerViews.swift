import SwiftUI

struct OdometerListView: View {
    @Environment(TenantStore.self) private var store
    let vehicle: Vehicle
    @State private var form: EditTarget<OdometerReading>?
    @State private var toDelete: OdometerReading?

    var body: some View {
        let readings = store.odometer(for: vehicle.id)
        List {
            ForEach(readings) { r in
                Button { form = EditTarget(value: r) } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            HStack {
                                Text(Fmt.km(r.km)).font(.headline)
                                if store.isPending(r.id) { PendingBadge() }
                            }
                            if let n = r.note, !n.isEmpty {
                                Text(n).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(Fmt.day(r.date)).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
                .swipeActions {
                    if store.canWrite {
                        Button("Stornieren", role: .destructive) { toDelete = r }
                    }
                }
            }
        }
        .overlay {
            if readings.isEmpty {
                ContentUnavailableView("Keine Kilometerstände", systemImage: "gauge.with.dots.needle.67percent",
                                       description: Text("Tankvorgänge und Wartungen zählen ebenfalls als Kilometerstand."))
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
            OdometerFormView(vehicle: vehicle, reading: target.value)
        }
        .stornoDialog($toDelete, title: "Kilometerstand stornieren?") { store.delete($0) }
        .refreshable { await store.sync() }
    }
}

struct OdometerFormView: View {
    @Environment(TenantStore.self) private var store
    let vehicle: Vehicle
    let reading: OdometerReading?

    @State private var date = Date()
    @State private var km = ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Datum", selection: $date, displayedComponents: .date)
                    LabeledContent("Kilometerstand") {
                        TextField("km", text: $km).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    TextField("Notiz (optional)", text: $note, axis: .vertical)
                }
                if let r = reading {
                    HistorySection(entity: OdometerReading.entityName, id: r.id)
                }
            }
            .navigationTitle(reading == nil ? "Kilometerstand" : "Kilometerstand bearbeiten")
            .formToolbar(canSave: store.canWrite && km.asInt != nil, save: save)
            .onAppear {
                if let r = reading {
                    date = r.date
                    km = String(r.km)
                    note = r.note ?? ""
                } else {
                    let current = store.currentKm(store.vehicle(id: vehicle.id) ?? vehicle)
                    if current > 0 { km = String(current) }
                }
            }
        }
    }

    private func save() {
        guard let kmValue = km.asInt else { return }
        var r = reading ?? OdometerReading(vehicleId: vehicle.id, date: date, km: kmValue)
        r.date = date
        r.km = kmValue
        r.note = note.nilIfEmpty
        store.save(r)
    }
}
