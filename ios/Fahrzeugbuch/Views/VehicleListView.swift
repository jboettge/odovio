import SwiftUI

/// Schnellerfassung direkt aus der Liste/Übersicht.
enum QuickEntry: Identifiable {
    case fuel(Vehicle), odometer(Vehicle), maintenance(Vehicle)
    var id: String {
        switch self {
        case .fuel(let v): "fuel-\(v.id)"
        case .odometer(let v): "odo-\(v.id)"
        case .maintenance(let v): "maint-\(v.id)"
        }
    }

    @ViewBuilder var form: some View {
        switch self {
        case .fuel(let v): FuelFormView(vehicle: v, entry: nil)
        case .odometer(let v): OdometerFormView(vehicle: v, reading: nil)
        case .maintenance(let v): MaintenanceFormView(vehicle: v, maintenance: nil)
        }
    }
}

struct VehicleListView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TenantStore.self) private var store
    @State private var form: EditTarget<Vehicle>?
    @State private var quick: QuickEntry?
    @State private var toDelete: Vehicle?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.vehicleList) { v in
                        NavigationLink(value: v.id) { VehicleRow(vehicle: v) }
                            .swipeActions(edge: .leading) {
                                if store.canWrite {
                                    Button { quick = .fuel(v) } label: { Label("Tanken", systemImage: "fuelpump") }
                                        .tint(.green)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                if store.canWrite {
                                    Button("Stornieren", role: .destructive) { toDelete = v }
                                    Button("Bearbeiten") { form = EditTarget(value: v) }.tint(.blue)
                                }
                            }
                            .contextMenu {
                                if store.canWrite {
                                    Button { quick = .fuel(v) } label: { Label("Tanken", systemImage: "fuelpump") }
                                    Button { quick = .odometer(v) } label: {
                                        Label("Kilometerstand", systemImage: "gauge.with.dots.needle.67percent")
                                    }
                                    Button { quick = .maintenance(v) } label: {
                                        Label("Wartung", systemImage: "wrench.and.screwdriver")
                                    }
                                }
                            }
                    }
                } header: {
                    if !store.canWrite {
                        Label("Nur Lesezugriff auf \(store.tenant.slug)", systemImage: "eye")
                            .textCase(nil)
                    }
                } footer: {
                    if store.canWrite && !store.vehicleList.isEmpty {
                        Text("Tipp: Fahrzeug nach rechts wischen oder lange drücken, um direkt zu tanken.")
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
            .navigationTitle("Fahrzeuge")
            .navigationDestination(for: String.self) { id in
                if let v = store.vehicle(id: id) { VehicleDetailView(vehicle: v) }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Einstellungen")
                    TenantMenu()
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    SyncStatusButton()
                    if store.canWrite {
                        Button { form = EditTarget(value: nil) } label: { Image(systemName: "plus") }
                            .accessibilityLabel("Fahrzeug hinzufügen")
                    }
                }
            }
            .refreshable { await store.sync() }
            .sheet(item: $form) { target in VehicleFormView(vehicle: target.value) }
            .sheet(item: $quick) { $0.form }
            .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
            .stornoDialog($toDelete, title: "Fahrzeug stornieren?") { store.delete($0) }
            .modifier(SyncNoticeModifier())
            .task(id: store.dueSignature) { await DueNotifications.reschedule(store) }
        }
    }
}

private struct VehicleRow: View {
    @Environment(TenantStore.self) private var store
    let vehicle: Vehicle

    var body: some View {
        let stats = store.stats(for: vehicle)
        let overdue = stats.due.filter(\.overdue).count
        VStack(alignment: .leading, spacing: 3) {
            Text(vehicle.name).font(.headline)
            if !vehicle.subtitle.isEmpty {
                Text(vehicle.subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Label(Fmt.km(stats.currentKm), systemImage: "gauge.with.dots.needle.67percent")
                if let c = stats.avgConsumption {
                    Label("\(Fmt.num(c, 1)) l/100 km", systemImage: "fuelpump")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if overdue > 0 {
                Label(overdue == 1 ? "1 Wartung überfällig" : "\(overdue) Wartungen überfällig",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Mandantenwechsel als beschriftetes Menü (nur bei mehreren Mandanten).
struct TenantMenu: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TenantStore.self) private var store

    var body: some View {
        if settings.tenants.count > 1 {
            Menu {
                Picker("Mandant", selection: Binding(
                    get: { store.tenant.slug },
                    set: { slug in
                        if let t = settings.tenants.first(where: { $0.slug == slug }) { settings.selectTenant(t) }
                    })) {
                    ForEach(settings.tenants) { t in
                        Label(t.slug, systemImage: t.canWrite ? "pencil" : "eye").tag(t.slug)
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(store.tenant.slug).font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                }
            }
            .accessibilityLabel("Mandant: \(store.tenant.slug), wechseln")
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
    @State private var ownership = "private"
    @State private var method = "flat"
    @State private var purchasePrice = ""
    @State private var fixedCosts = ""

    private var titleText: String { vehicle == nil ? "Neues Fahrzeug" : "Fahrzeug bearbeiten" }

    private var costsValid: Bool {
        let price = purchasePrice.trimmed.isEmpty || (purchasePrice.asDouble.map { $0 >= 0 } ?? false)
        let fixed = fixedCosts.trimmed.isEmpty || (fixedCosts.asDouble.map { $0 >= 0 } ?? false)
        return price && fixed
    }

    private var taxFooter: String {
        ownership == "business"
            ? "Geschäftsfahrzeug: Privatanteil pauschal (0.9 % des Kaufpreises pro Monat) oder effektiv mit "
                + "Fahrtenbuch. Der Jahresbericht rechnet beides zum Vergleich – Annahmen mit Treuhand prüfen."
            : "Privatfahrzeug: Geschäftsfahrten ergeben eine Kilometerentschädigung, der Arbeitsweg einen Abzug."
    }

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
                    UnitField("Kilometerstand", text: $initialKm, unit: "km", keyboard: .numberPad)
                } header: {
                    Text("Startkilometerstand")
                } footer: {
                    Text("Stand bei Beginn der Erfassung.")
                }
                Section {
                    Picker("Halter", selection: $ownership) {
                        Text("Privat").tag("private")
                        Text("Geschäftlich").tag("business")
                    }
                    if ownership == "business" {
                        Picker("Privatanteil", selection: $method) {
                            Text("Pauschal").tag("flat")
                            Text("Effektiv (Fahrtenbuch)").tag("effective")
                        }
                    }
                    UnitField("Kaufpreis exkl. MWST", text: $purchasePrice, unit: "CHF", placeholder: "optional")
                    UnitField("Fixkosten pro Jahr", text: $fixedCosts, unit: "CHF", placeholder: "optional")
                } header: {
                    Text("Steuer & Kosten")
                } footer: {
                    if costsValid {
                        Text(taxFooter)
                    } else {
                        Text("Beträge ungültig.").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(titleText)
            .formToolbar(canSave: store.canWrite && !name.trimmed.isEmpty && costsValid, save: save)
            .onAppear {
                guard let v = vehicle else { return }
                name = v.name
                make = v.make ?? ""
                model = v.model ?? ""
                plate = v.plate ?? ""
                fuelType = v.fuelType
                initialKm = String(v.initialKm)
                ownership = v.ownership ?? "private"
                method = v.privateUseMethod ?? "flat"
                purchasePrice = v.purchasePrice.map { Fmt.edit($0) } ?? ""
                fixedCosts = v.annualFixedCosts.map { Fmt.edit($0) } ?? ""
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
        // nil bleibt nil, solange der Standard (privat/pauschal) nicht geändert wird
        if !(v.ownership == nil && ownership == "private") { v.ownership = ownership }
        if ownership == "business" {
            if !(v.privateUseMethod == nil && method == "flat") { v.privateUseMethod = method }
        }
        v.purchasePrice = purchasePrice.asDouble
        v.annualFixedCosts = fixedCosts.asDouble
        store.save(v)
    }
}
