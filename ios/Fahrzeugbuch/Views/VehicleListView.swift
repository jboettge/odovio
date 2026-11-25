import SwiftUI

struct VehicleListView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TenantStore.self) private var store
    @State private var form: EditTarget<Vehicle>?
    @State private var toDelete: Vehicle?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.vehicleList) { v in
                    NavigationLink(value: v.id) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.name).font(.headline)
                            if !v.subtitle.isEmpty {
                                Text(v.subtitle).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Text(Fmt.km(store.currentKm(v))).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        if store.canWrite {
                            Button("Stornieren", role: .destructive) { toDelete = v }
                            Button("Bearbeiten") { form = EditTarget(value: v) }.tint(.blue)
                        }
                    }
                }
            }
            .overlay {
                if store.vehicleList.isEmpty {
                    ContentUnavailableView("Keine Fahrzeuge", systemImage: "car",
                                           description: Text(store.canWrite ? "Mit + ein Fahrzeug anlegen."
                                                             : "Nur Lesezugriff auf diesen Mandanten."))
                }
            }
            .navigationTitle(store.tenant.slug)
            .navigationDestination(for: String.self) { id in
                if let v = store.vehicle(id: id) { VehicleDetailView(vehicle: v) }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    if settings.tenants.count > 1 {
                        Menu {
                            Picker("Mandant", selection: Binding(
                                get: { store.tenant.slug },
                                set: { slug in
                                    if let t = settings.tenants.first(where: { $0.slug == slug }) {
                                        settings.selectTenant(t)
                                    }
                                })) {
                                ForEach(settings.tenants) { t in
                                    Label(t.slug, systemImage: t.canWrite ? "pencil" : "eye").tag(t.slug)
                                }
                            }
                        } label: {
                            Image(systemName: "building.2")
                        }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    SyncStatusButton()
                    if store.canWrite {
                        Button { form = EditTarget(value: nil) } label: { Image(systemName: "plus") }
                    }
                }
            }
            .refreshable { await store.sync() }
            .sheet(item: $form) { target in
                VehicleFormView(vehicle: target.value)
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack { SettingsView() }
            }
            .stornoDialog($toDelete, title: "Fahrzeug stornieren?") { store.delete($0) }
            .modifier(SyncNoticeModifier())
        }
    }
}

struct VehicleFormView: View {
    @Environment(TenantStore.self) private var store
    let vehicle: Vehicle?

    @State private var name = ""
    @State private var make = ""
    @State private var model = ""
    @State private var plate = ""
    @State private var fuelType = FuelType.benzin.rawValue
    @State private var initialKm = ""

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
            .formToolbar(canSave: !name.trimmed.isEmpty, save: save)
            .onAppear {
                guard let v = vehicle else { return }
                name = v.name
                make = v.make ?? ""
                model = v.model ?? ""
                plate = v.plate ?? ""
                fuelType = v.fuelType
                initialKm = String(v.initialKm)
            }
        }
    }

    private func save() {
        var v = vehicle ?? Vehicle(name: "")
        v.name = name.trimmed
        v.make = make.nilIfEmpty
        v.model = model.nilIfEmpty
        v.plate = plate.nilIfEmpty
        v.fuelType = fuelType
        v.initialKm = initialKm.asInt ?? 0
        store.save(v)
    }
}
