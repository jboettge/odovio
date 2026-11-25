import SwiftUI

/// Schnellerfassung direkt aus der Liste/Übersicht (auch aus Quick Actions/Mitteilungen).
enum QuickEntry: Identifiable {
    case fuel(Vehicle), odometer(Vehicle), maintenance(Vehicle), trip(Vehicle), review(Vehicle)
    var id: String {
        switch self {
        case .fuel(let v): "fuel-\(v.id)"
        case .odometer(let v): "odo-\(v.id)"
        case .maintenance(let v): "maint-\(v.id)"
        case .trip(let v): "trip-\(v.id)"
        case .review(let v): "review-\(v.id)"
        }
    }

    @MainActor @ViewBuilder var form: some View {
        switch self {
        case .fuel(let v): FuelFormView(vehicle: v, entry: nil)
        case .odometer(let v): OdometerFormView(vehicle: v, reading: nil)
        case .maintenance(let v): MaintenanceFormView(vehicle: v, maintenance: nil)
        case .trip(let v): TripFormView(vehicle: v, trip: nil)
        case .review(let v): ModalNavigation { TripReviewView(vehicle: v) }
        }
    }
}

struct VehicleListView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TenantStore.self) private var store
    @State private var path: [String] = []
    @State private var form: EditTarget<Vehicle>?
    @State private var quick: QuickEntry?
    @State private var toDelete: Vehicle?
    @State private var showSettings = false
    /// Statistik je Fahrzeug (E14: nicht bei jedem Zeichnen neu rechnen)
    @State private var statsCache: [String: VehicleStats] = [:]
    @State private var lastDueSignature: String?

    /// Ändert sich bei jeder lokalen Änderung (Outbox) und jedem Sync (Cursor/Zeitpunkt).
    private var dataKey: String {
        let ids = store.vehicleList.map(\.id).joined(separator: ",")
        let synced = store.lastSync?.timeIntervalSince1970 ?? 0
        return "\(ids)|\(store.outbox.count)|\(store.cursor)|\(synced)"
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                StoreIssueSection()
                Section {
                    ForEach(store.vehicleList) { v in
                        vehicleRow(v)
                    }
                } header: {
                    if !store.canWrite {
                        Label("Nur Lesezugriff auf «\(store.tenant.slug)»", systemImage: "eye")
                            .textCase(nil)
                    }
                }
            }
            .overlay {
                if store.vehicleList.isEmpty {
                    ContentUnavailableView("Keine Fahrzeuge", systemImage: "car",
                                           description: Text(store.canWrite ? "Mit + ein Fahrzeug anlegen."
                                                             : "Nur Lesezugriff auf dieses Fahrzeugbuch."))
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
            .task(id: dataKey) { await refreshStats() }
            .onAppear { handleRoute() }
            .onChange(of: AppRouter.shared.pending) { _, _ in handleRoute() }
        }
    }

    private func vehicleRow(_ v: Vehicle) -> some View {
        HStack(spacing: 10) {
            Button { path.append(v.id) } label: {
                HStack(spacing: 6) {
                    VehicleRow(vehicle: v, stats: statsCache[v.id] ?? store.stats(for: v))
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Öffnet das Fahrzeug")
            if store.canWrite {
                Button { quick = .fuel(v) } label: {
                    Label("Tanken", systemImage: "fuelpump.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.successText)
                .accessibilityLabel("Tankvorgang für \(v.name) erfassen")
            }
        }
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
                Button { quick = .fuel(v) } label: { Label("Tankvorgang", systemImage: "fuelpump") }
                Button { quick = .trip(v) } label: { Label("Fahrt erfassen", systemImage: "car") }
                Button { quick = .odometer(v) } label: {
                    Label("Kilometerstand", systemImage: "gauge.with.dots.needle.67percent")
                }
                Button { quick = .maintenance(v) } label: {
                    Label("Wartung", systemImage: "wrench.and.screwdriver")
                }
            }
        }
    }

    /// Statistik neu rechnen und Fälligkeits-Mitteilungen nur bei Änderungen neu planen.
    private func refreshStats() async {
        var next: [String: VehicleStats] = [:]
        for v in store.vehicleList { next[v.id] = store.stats(for: v) }
        statsCache = next
        var parts: [String] = []
        for v in store.vehicleList {
            for d in next[v.id]?.due ?? [] {
                parts.append("\(v.id)|\(d.id)|\(d.nextDueDate?.timeIntervalSince1970 ?? 0)|\(d.overdue)")
            }
        }
        let signature = parts.joined(separator: ",")
        if signature != lastDueSignature {
            lastDueSignature = signature
            await DueNotifications.reschedule(store)
        }
    }

    // MARK: Quick Actions / Mitteilungen

    private func vehicleForRoute(_ id: String?) -> Vehicle? {
        if let id, let v = store.vehicle(id: id), !v.deleted { return v }
        return store.defaultVehicleId.flatMap { store.vehicle(id: $0) }
    }

    private func handleRoute() {
        guard let route = AppRouter.shared.pending else { return }
        AppRouter.shared.pending = nil
        switch route {
        case .addFuel(let id):
            if store.canWrite, let v = vehicleForRoute(id) { quick = .fuel(v) }
        case .addTrip(let id):
            if store.canWrite, let v = vehicleForRoute(id) { quick = .trip(v) }
        case .review(let id):
            if let v = vehicleForRoute(id) { quick = .review(v) }
        }
    }
}

private struct VehicleRow: View {
    let vehicle: Vehicle
    let stats: VehicleStats

    var body: some View {
        let overdue = stats.due.filter(\.overdue).count
        VStack(alignment: .leading, spacing: 3) {
            Text(vehicle.name).font(.headline)
            if !vehicle.subtitle.isEmpty {
                Text(vehicle.subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { facts }
                VStack(alignment: .leading, spacing: 2) { facts }
            }
            .font(.footnote)
            .foregroundStyle(Color.neutralText)
            if overdue > 0 {
                Label(overdue == 1 ? "1 Wartung überfällig" : "\(overdue) Wartungen überfällig",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.bold())
                    .foregroundStyle(Color.dangerText)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var facts: some View {
        Label(Fmt.km(stats.currentKm), systemImage: "gauge.with.dots.needle.67percent")
        if let c = stats.avgConsumption {
            Label("\(Fmt.num(c, 1)) l/100 km", systemImage: "fuelpump")
        }
    }
}

/// Wechsel des Fahrzeugbuchs (technisch: Mandant) als beschriftetes Menü (nur bei mehreren).
struct TenantMenu: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TenantStore.self) private var store

    var body: some View {
        if settings.tenants.count > 1 {
            Menu {
                Picker("Fahrzeugbuch", selection: Binding(
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
            .accessibilityLabel("Fahrzeugbuch: \(store.tenant.slug), wechseln")
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
    @State private var initial = ""

    private var snapshot: String {
        FormSnapshot.make([name, make, model, plate, fuelType, initialKm, ownership, method, purchasePrice, fixedCosts])
    }

    private var hasChanges: Bool { snapshot != initial }

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
                        Text("Privatfahrzeug").tag("private")
                        Text("Geschäftsfahrzeug").tag("business")
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
                        Text("Beträge ungültig.").foregroundStyle(Color.dangerText)
                    }
                }
            }
            .navigationTitle(titleText)
            .formToolbar(canSave: store.canWrite && !name.trimmed.isEmpty && costsValid, hasChanges: hasChanges,
                         save: save)
            .onAppear {
                defer { if initial.isEmpty { initial = snapshot } }
                guard let v = vehicle, initial.isEmpty else { return }
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
