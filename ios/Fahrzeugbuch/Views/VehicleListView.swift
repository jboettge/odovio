import SwiftUI

struct VehicleListView: View {
    @Environment(AppSettings.self) private var settings
    @State private var vehicles: [Vehicle] = []
    @State private var loaded = false
    @State private var form: EditTarget<Vehicle>?
    @State private var toDelete: Vehicle?
    @State private var showSettings = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(vehicles) { v in
                    NavigationLink(value: v) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.name).font(.headline)
                            if !v.subtitle.isEmpty {
                                Text(v.subtitle).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Text(Fmt.km(v.currentKm)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Löschen", role: .destructive) { toDelete = v }
                        Button("Bearbeiten") { form = EditTarget(value: v) }.tint(.blue)
                    }
                }
            }
            .overlay {
                if loaded && vehicles.isEmpty {
                    ContentUnavailableView("Keine Fahrzeuge", systemImage: "car",
                                           description: Text("Mit + ein Fahrzeug anlegen."))
                }
            }
            .navigationTitle("Fahrzeugbuch")
            .navigationDestination(for: Vehicle.self) { VehicleDetailView(vehicle: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { form = EditTarget(value: nil) } label: { Image(systemName: "plus") }
                }
            }
            .task { await load() }
            .refreshable { await load() }
            .sheet(item: $form) { target in
                VehicleFormView(vehicle: target.value) { await load() }
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack { SettingsView() }
            }
            .confirmationDialog(
                "Fahrzeug löschen?",
                isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                titleVisibility: .visible,
                presenting: toDelete
            ) { v in
                Button("\(v.name) inkl. aller Einträge löschen", role: .destructive) {
                    Task { await delete(v) }
                }
            }
            .errorAlert($error)
        }
    }

    private func load() async {
        do {
            vehicles = try await settings.api.get("api/vehicles")
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func delete(_ v: Vehicle) async {
        do {
            try await settings.api.delete("api/vehicles/\(v.id)")
        } catch {
            self.error = error.localizedDescription
        }
        await load()
    }
}

struct VehicleFormView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    let vehicle: Vehicle?
    let onSaved: () async -> Void

    @State private var name = ""
    @State private var make = ""
    @State private var model = ""
    @State private var plate = ""
    @State private var fuelType = FuelType.benzin.rawValue
    @State private var initialKm = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Fahrzeug") {
                    TextField("Bezeichnung (z. B. Familienauto)", text: $name)
                    TextField("Marke", text: $make)
                    TextField("Modell", text: $model)
                    TextField("Kennzeichen", text: $plate)
                        .textInputAutocapitalization(.characters)
                    Picker("Treibstoff", selection: $fuelType) {
                        ForEach(FuelType.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                }
                Section {
                    TextField("Kilometerstand", text: $initialKm)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Startkilometerstand")
                } footer: {
                    Text("Stand bei Beginn der Erfassung.")
                }
            }
            .navigationTitle(vehicle == nil ? "Neues Fahrzeug" : "Fahrzeug bearbeiten")
            .formToolbar(canSave: !name.trimmed.isEmpty, saving: saving) { await save() }
            .onAppear {
                guard let v = vehicle else { return }
                name = v.name
                make = v.make ?? ""
                model = v.model ?? ""
                plate = v.plate ?? ""
                fuelType = v.fuelType
                initialKm = String(v.initialKm)
            }
            .errorAlert($error)
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let input = VehicleInput(name: name.trimmed, make: make.nilIfEmpty, model: model.nilIfEmpty,
                                 plate: plate.nilIfEmpty, fuelType: fuelType, initialKm: initialKm.asInt ?? 0)
        do {
            if let v = vehicle {
                let _: Vehicle = try await settings.api.put("api/vehicles/\(v.id)", input)
            } else {
                let _: Vehicle = try await settings.api.post("api/vehicles", input)
            }
            await onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
