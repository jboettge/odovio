import SwiftUI

struct OdometerListView: View {
    @Environment(AppSettings.self) private var settings
    let vehicle: Vehicle
    @State private var readings: [OdometerReading] = []
    @State private var loaded = false
    @State private var form: EditTarget<OdometerReading>?
    @State private var error: String?

    var body: some View {
        List {
            ForEach(readings) { r in
                Button { form = EditTarget(value: r) } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(Fmt.km(r.km)).font(.headline)
                            if let n = r.note, !n.isEmpty {
                                Text(n).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(Fmt.day(r.date)).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            }
            .onDelete { offsets in Task { await delete(offsets) } }
        }
        .overlay {
            if loaded && readings.isEmpty {
                ContentUnavailableView("Keine Kilometerstände", systemImage: "gauge.with.dots.needle.67percent",
                                       description: Text("Tankvorgänge und Wartungen zählen ebenfalls als Kilometerstand."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { form = EditTarget(value: nil) } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $form) { target in
            OdometerFormView(vehicleID: vehicle.id, reading: target.value,
                             suggestedKm: max(vehicle.currentKm, readings.map(\.km).max() ?? 0)) { await load() }
        }
        .task { await load() }
        .refreshable { await load() }
        .errorAlert($error)
    }

    private func load() async {
        do {
            readings = try await settings.api.get("api/vehicles/\(vehicle.id)/odometer")
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func delete(_ offsets: IndexSet) async {
        let ids = offsets.map { readings[$0].id }
        readings.remove(atOffsets: offsets)
        do {
            for id in ids { try await settings.api.delete("api/odometer/\(id)") }
        } catch {
            self.error = error.localizedDescription
        }
        await load()
    }
}

struct OdometerFormView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    let vehicleID: Int
    let reading: OdometerReading?
    let suggestedKm: Int
    let onSaved: () async -> Void

    @State private var date = Date()
    @State private var km = ""
    @State private var note = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Datum", selection: $date, displayedComponents: .date)
                LabeledContent("Kilometerstand") {
                    TextField("km", text: $km).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                TextField("Notiz (optional)", text: $note, axis: .vertical)
            }
            .navigationTitle(reading == nil ? "Kilometerstand" : "Kilometerstand bearbeiten")
            .formToolbar(canSave: km.asInt != nil, saving: saving) { await save() }
            .onAppear {
                if let r = reading {
                    date = r.date
                    km = String(r.km)
                    note = r.note ?? ""
                } else if suggestedKm > 0 {
                    km = String(suggestedKm)
                }
            }
            .errorAlert($error)
        }
    }

    private func save() async {
        guard let kmValue = km.asInt else { return }
        saving = true
        defer { saving = false }
        let input = OdometerInput(date: date, km: kmValue, note: note.nilIfEmpty)
        do {
            if let r = reading {
                let _: OdometerReading = try await settings.api.put("api/odometer/\(r.id)", input)
            } else {
                let _: OdometerReading = try await settings.api.post("api/vehicles/\(vehicleID)/odometer", input)
            }
            await onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
