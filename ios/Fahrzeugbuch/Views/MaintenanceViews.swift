import SwiftUI

struct MaintenanceListView: View {
    @Environment(TenantStore.self) private var store
    let vehicle: Vehicle
    @State private var showNew = false
    @State private var toDelete: Maintenance?

    var body: some View {
        let entries = store.maintenance(for: vehicle.id)
        let due = Dictionary(store.stats(for: store.vehicle(id: vehicle.id) ?? vehicle).due.map { ($0.maintenanceId, $0) },
                             uniquingKeysWith: { a, _ in a })
        List {
            ForEach(entries) { m in
                NavigationLink {
                    MaintenanceDetailView(maintenanceId: m.id, vehicle: vehicle)
                } label: {
                    MaintenanceRow(maintenance: m, items: store.items(for: m.id),
                                   materials: store.materials(for: m.id), pending: store.isPending(m.id),
                                   due: due[m.id])
                }
                .swipeActions {
                    if store.canWrite {
                        Button("Stornieren", role: .destructive) { toDelete = m }
                    }
                }
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("Keine Wartungen", systemImage: "wrench.and.screwdriver",
                                       description: Text("Mit + eine Wartung mit Checkliste erfassen."))
            }
        }
        .toolbar {
            if store.canWrite {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Wartung hinzufügen")
                }
            }
        }
        .sheet(isPresented: $showNew) {
            MaintenanceFormView(vehicle: vehicle, maintenance: nil)
        }
        .stornoDialog($toDelete, title: "Wartung stornieren?") { store.delete($0) }
        .refreshable { await store.sync() }
    }
}

private struct MaintenanceRow: View {
    let maintenance: Maintenance
    let items: [MaintenanceItem]
    let materials: [MaintenanceMaterial]
    let pending: Bool
    let due: DueItem?

    private var doneCount: Int { items.filter(\.done).count }
    private var hasMaterialPrice: Bool { materials.contains { $0.unitPrice != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(maintenance.title).font(.headline)
                if let due {
                    if due.overdue {
                        StatusTag(text: "Überfällig", color: .red, systemImage: "exclamationmark.triangle.fill")
                    } else if due.dueSoon {
                        StatusTag(text: "Bald fällig", color: .orange, systemImage: "clock")
                    }
                }
                if pending { PendingBadge() }
                Spacer()
                if let c = maintenance.cost {
                    Text(Fmt.chf(c))
                } else if hasMaterialPrice {
                    // ohne Rechnungsbetrag zählt die Materialsumme
                    let total = MaintenanceMaterial.total(materials)
                    Text(Fmt.chf(total))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Material \(Fmt.chf(total))")
                }
            }
            HStack {
                Text(Fmt.day(maintenance.date))
                if let km = maintenance.km { Text("· \(Fmt.km(km))") }
                Spacer()
                if !materials.isEmpty {
                    Label("\(materials.count)", systemImage: "shippingbox")
                        .accessibilityLabel(materials.count == 1 ? "1 Materialposition"
                                            : "\(materials.count) Materialpositionen")
                }
                if !items.isEmpty {
                    let complete = doneCount == items.count
                    Label("\(doneCount)/\(items.count)",
                          systemImage: complete ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(complete ? .green : .secondary)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if !items.isEmpty {
                ProgressView(value: Double(doneCount), total: Double(items.count))
                    .tint(doneCount == items.count ? .green : .accentColor)
            }
            if let due {
                Text(due.dueText).font(.caption).foregroundStyle(due.overdue ? .red : .secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct MaintenanceDetailView: View {
    @Environment(TenantStore.self) private var store
    let maintenanceId: String
    let vehicle: Vehicle
    @State private var editing = false

    var body: some View {
        if let m = store.maintenance(id: maintenanceId) {
            let items = store.items(for: m.id)
            let materials = store.materials(for: m.id)
            List {
                Section {
                    LabeledContent("Datum", value: Fmt.day(m.date))
                    if let km = m.km { LabeledContent("Kilometerstand", value: Fmt.km(km)) }
                    if let c = m.cost {
                        LabeledContent("Kosten", value: Fmt.chf(c))
                    } else if materials.contains(where: { $0.unitPrice != nil }) {
                        LabeledContent("Kosten", value: "Material \(Fmt.chf(MaintenanceMaterial.total(materials)))")
                    }
                    if let n = m.nextDueKm { LabeledContent("Nächste bei", value: Fmt.km(n)) }
                    if let d = m.nextDueDate { LabeledContent("Nächste bis", value: Fmt.day(d)) }
                    if m.deleted { Label("Storniert", systemImage: "xmark.circle").foregroundStyle(.red) }
                }

                if !items.isEmpty {
                    Section {
                        ForEach(items) { item in
                            Button { store.toggle(item) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(item.done ? Color.green : Color.secondary)
                                    Text(item.label)
                                        .foregroundStyle(item.done ? Color.secondary : Color.primary)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!store.canWrite || m.deleted)
                            .accessibilityLabel(item.label)
                            .accessibilityValue(item.done ? "erledigt" : "offen")
                            .accessibilityAddTraits(.isButton)
                        }
                    } header: {
                        Text("Checkliste")
                    } footer: {
                        Text("\(items.filter(\.done).count) von \(items.count) erledigt – jedes Abhaken wird protokolliert.")
                    }
                }

                if !materials.isEmpty {
                    MaterialDetailSection(materials: materials, costMissing: m.cost == nil)
                }

                if let note = m.note, !note.isEmpty {
                    Section("Notiz") { Text(note) }
                }

                HistorySection(entity: Maintenance.entityName, id: m.id)
            }
            .navigationTitle(m.title)
            .toolbar {
                if store.canWrite && !m.deleted {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Bearbeiten") { editing = true }
                    }
                }
            }
            .sheet(isPresented: $editing) {
                MaintenanceFormView(vehicle: vehicle, maintenance: m)
            }
        } else {
            ContentUnavailableView("Wartung nicht gefunden", systemImage: "questionmark")
        }
    }
}

struct MaintenanceFormView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TenantStore.self) private var store
    let vehicle: Vehicle
    let maintenance: Maintenance?

    struct DraftItem: Identifiable {
        var id: String = UUID().uuidString.lowercased()
        var label: String
        var done: Bool
        var version = 0
    }

    /// Materialposition im Formular (Eingaben als Text, Komma oder Punkt erlaubt).
    struct DraftMaterial: Identifiable, Equatable {
        var id: String = UUID().uuidString.lowercased()
        var version = 0
        var name = ""
        var partNumber = ""
        var quantity = "1"
        var unit = "Stk"
        var unitPrice = ""

        var lineTotal: Double? {
            guard let q = quantity.asDouble, let p = unitPrice.asDouble else { return nil }
            return q * p
        }

        static func from(_ m: MaintenanceMaterial) -> DraftMaterial {
            DraftMaterial(id: m.id, version: m.version, name: m.name, partNumber: m.partNumber ?? "",
                          quantity: Fmt.editQty(m.quantity), unit: m.unit,
                          unitPrice: m.unitPrice.map { priceText($0) } ?? "")
        }

        /// Zwei Nachkommastellen, ausser der Preis hat mehr (sonst gälte er beim Sichern als geändert).
        private static func priceText(_ p: Double) -> String {
            let twoDigits = Fmt.edit(p)
            return twoDigits.asDouble == p ? twoDigits : Fmt.editQty(p)
        }
    }

    @State private var title = ""
    @State private var date = Date()
    @State private var km = ""
    @State private var cost = ""
    @State private var note = ""
    @State private var hasDueKm = false
    @State private var dueKm = ""
    @State private var hasDueDate = false
    @State private var dueDate = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()
    @State private var items: [DraftItem] = []
    @State private var newItem = ""
    @State private var templates: [ChecklistTemplate] = []
    @State private var materials: [DraftMaterial] = []
    @State private var editingMaterial: DraftMaterial?
    @State private var didPrefill = false

    private var materialTotal: Double {
        materials.reduce(0.0) { $0 + ($1.lineTotal ?? 0) }
    }

    private var costMatchesMaterial: Bool {
        guard let c = cost.asDouble else { return false }
        return abs(c - materialTotal) < 0.005
    }

    var body: some View {
        NavigationStack {
            Form {
                if maintenance == nil && !templates.isEmpty {
                    Section {
                        Menu {
                            ForEach(templates) { t in
                                Button(t.title) { apply(t) }
                            }
                        } label: {
                            Label("Vorlage übernehmen", systemImage: "list.bullet.clipboard")
                        }
                    }
                }

                Section("Wartung") {
                    TextField("Titel (z. B. Service)", text: $title)
                    DatePicker("Datum", selection: $date, displayedComponents: .date)
                    UnitField("Kilometerstand", text: $km, unit: "km", keyboard: .numberPad)
                    UnitField("Kosten", text: $cost, unit: "CHF", placeholder: "optional")
                }

                materialSection

                Section("Nächste Fälligkeit") {
                    Toggle("Nach Kilometerstand", isOn: $hasDueKm)
                    if hasDueKm {
                        UnitField("Fällig bei", text: $dueKm, unit: "km", keyboard: .numberPad)
                    }
                    Toggle("Nach Datum", isOn: $hasDueDate)
                    if hasDueDate {
                        DatePicker("Fällig bis", selection: $dueDate, displayedComponents: .date)
                    }
                }

                Section {
                    ForEach($items) { $item in
                        HStack {
                            Button { item.done.toggle() } label: {
                                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(item.done ? .green : .secondary)
                                    .imageScale(.large)
                            }
                            .buttonStyle(.plain)
                            TextField("Punkt", text: $item.label)
                        }
                    }
                    .onDelete { items.remove(atOffsets: $0) }
                    .onMove { items.move(fromOffsets: $0, toOffset: $1) }

                    HStack {
                        TextField("Neuer Punkt", text: $newItem)
                            .onSubmit(addItem)
                        Button(action: addItem) { Image(systemName: "plus.circle.fill") }
                            .disabled(newItem.trimmed.isEmpty)
                    }
                } header: {
                    Text("Checkliste")
                }

                Section("Notiz") {
                    TextField("optional", text: $note, axis: .vertical)
                }
            }
            .sheet(item: $editingMaterial) { draft in
                MaterialEditView(material: draft, isNew: !materials.contains { $0.id == draft.id }) { updated in
                    commitMaterial(updated)
                }
            }
            .navigationTitle(maintenance == nil ? "Neue Wartung" : "Wartung bearbeiten")
            .formToolbar(canSave: store.canWrite && !title.trimmed.isEmpty, save: save)
            .onAppear(perform: prefill)
            .task { await loadTemplates() }
        }
    }

    private var materialSection: some View {
        Section {
            ForEach(materials) { material in
                Button { editingMaterial = material } label: {
                    MaterialLine(name: material.name.trimmed, partNumber: material.partNumber.nilIfEmpty,
                                 quantity: material.quantity.asDouble, unit: material.unit.nilIfEmpty ?? "Stk",
                                 unitPrice: material.unitPrice.asDouble)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Bearbeiten")
            }
            .onDelete { materials.remove(atOffsets: $0) }
            .onMove { materials.move(fromOffsets: $0, toOffset: $1) }

            Button { editingMaterial = DraftMaterial() } label: {
                Label("Material hinzufügen", systemImage: "plus.circle.fill")
            }
            .accessibilityLabel("Material hinzufügen")

            if !materials.isEmpty {
                LabeledContent("Summe Material") {
                    Text(Fmt.chf(materialTotal)).fontWeight(.semibold).monospacedDigit()
                }
                if materialTotal > 0 {
                    Button { cost = Fmt.edit(materialTotal) } label: {
                        Label("Als Kosten übernehmen", systemImage: "arrow.up.square")
                    }
                    .disabled(costMatchesMaterial)
                    .accessibilityLabel("Materialsumme \(Fmt.chf(materialTotal)) als Kosten übernehmen")
                }
            }
        } header: {
            Text("Material")
        } footer: {
            if !materials.isEmpty {
                Text("Ohne Kostenbetrag zählt die Materialsumme in der Statistik.")
            }
        }
    }

    private func commitMaterial(_ material: DraftMaterial) {
        if let i = materials.firstIndex(where: { $0.id == material.id }) {
            materials[i] = material
        } else {
            materials.append(material)
        }
    }

    private func prefill() {
        // nur einmal: Rückkehr aus dem Material-Sheet darf Eingaben nicht überschreiben
        guard !didPrefill else { return }
        didPrefill = true
        guard let m = maintenance else {
            if km.isEmpty {
                let current = store.currentKm(store.vehicle(id: vehicle.id) ?? vehicle)
                if current > 0 { km = String(current) }
            }
            return
        }
        title = m.title
        date = m.date
        km = m.km.map { String($0) } ?? ""
        cost = m.cost.map { Fmt.edit($0) } ?? ""
        note = m.note ?? ""
        hasDueKm = m.nextDueKm != nil
        dueKm = m.nextDueKm.map { String($0) } ?? ""
        hasDueDate = m.nextDueDate != nil
        if let d = m.nextDueDate { dueDate = d }
        items = store.items(for: m.id).map { DraftItem(id: $0.id, label: $0.label, done: $0.done, version: $0.version) }
        materials = store.materials(for: m.id).map { DraftMaterial.from($0) }
    }

    private func apply(_ t: ChecklistTemplate) {
        if title.trimmed.isEmpty { title = t.title }
        let existing = Set(items.map(\.label))
        items += t.items.filter { !existing.contains($0) }.map { DraftItem(label: $0, done: false) }
    }

    private func addItem() {
        guard let label = newItem.nilIfEmpty else { return }
        items.append(DraftItem(label: label, done: false))
        newItem = ""
    }

    /// Vorlagen online laden, offline aus Cache.
    private func loadTemplates() async {
        guard maintenance == nil else { return }
        let key = "checklistTemplates"
        if let data = UserDefaults.standard.data(forKey: key),
           let cached = try? JSONDecoder().decode([ChecklistTemplate].self, from: data) {
            templates = cached
        }
        if let fresh: [ChecklistTemplate] = try? await settings.api.get("api/checklist-templates") {
            templates = fresh
            UserDefaults.standard.set(try? JSONEncoder().encode(fresh), forKey: key)
        }
    }

    private func save() {
        var m = maintenance ?? Maintenance(vehicleId: vehicle.id, date: date, title: title.trimmed)
        m.title = title.trimmed
        m.date = date
        m.km = km.asInt
        m.cost = cost.asDouble
        m.note = note.nilIfEmpty
        m.nextDueKm = hasDueKm ? dueKm.asInt : nil
        m.nextDueDate = hasDueDate ? dueDate : nil
        let newItems = items.compactMap { d -> MaintenanceItem? in
            guard let label = d.label.nilIfEmpty else { return nil }
            return MaintenanceItem(id: d.id, version: d.version, maintenanceId: m.id, label: label, done: d.done)
        }
        let newMaterials = materials.compactMap { d -> MaintenanceMaterial? in
            guard let name = d.name.nilIfEmpty, let quantity = d.quantity.asDouble, quantity > 0 else { return nil }
            return MaintenanceMaterial(id: d.id, version: d.version, maintenanceId: m.id, name: name,
                                       partNumber: d.partNumber.nilIfEmpty, quantity: quantity,
                                       unit: d.unit.nilIfEmpty ?? "Stk", unitPrice: d.unitPrice.asDouble)
        }
        store.save(m, items: newItems, materials: newMaterials)
    }
}

// MARK: Material

/// Eine Materialzeile: Name, darunter Art.-Nr. und „Menge Einheit × Einzelpreis“, rechts das Total.
private struct MaterialLine: View {
    let name: String
    let partNumber: String?
    let quantity: Double?
    let unit: String
    let unitPrice: Double?
    var pending = false

    private var total: Double? {
        guard let quantity, let unitPrice else { return nil }
        return quantity * unitPrice
    }

    private var quantityText: String {
        "\(quantity.map { Fmt.qty($0) } ?? "–") \(unit)"
    }

    private var detailText: String {
        var parts: [String] = []
        if let partNumber, !partNumber.isEmpty { parts.append("Art.-Nr. \(partNumber)") }
        if let unitPrice {
            parts.append("\(quantityText) × \(Fmt.chf(unitPrice))")
        } else {
            parts.append(quantityText)
        }
        return parts.joined(separator: " · ")
    }

    private var spokenText: String {
        var parts = [name.isEmpty ? "Material" : name, quantityText]
        if let unitPrice { parts.append("zu je \(Fmt.chf(unitPrice))") }
        if let total { parts.append("Total \(Fmt.chf(total))") }
        if let partNumber, !partNumber.isEmpty { parts.append("Artikelnummer \(partNumber)") }
        if pending { parts.append("noch nicht synchronisiert") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name.isEmpty ? "Material" : name)
                    if pending { PendingBadge() }
                }
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let total {
                Text(Fmt.chf(total)).monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenText)
    }
}

/// Materialliste in der Detailansicht inkl. Summe.
private struct MaterialDetailSection: View {
    @Environment(TenantStore.self) private var store
    let materials: [MaintenanceMaterial]
    let costMissing: Bool

    var body: some View {
        Section {
            ForEach(materials) { material in
                MaterialLine(name: material.name, partNumber: material.partNumber, quantity: material.quantity,
                             unit: material.unit, unitPrice: material.unitPrice,
                             pending: store.isPending(material.id))
            }
            LabeledContent("Summe Material") {
                Text(Fmt.chf(MaintenanceMaterial.total(materials))).fontWeight(.semibold).monospacedDigit()
            }
        } header: {
            Text("Material")
        } footer: {
            if costMissing {
                Text("Ohne Rechnungsbetrag zählt die Materialsumme als Kosten.")
            }
        }
    }
}

/// Kleines Sheet zum Erfassen/Bearbeiten einer Materialposition (wird erst mit der Wartung gesichert).
private struct MaterialEditView: View {
    typealias Draft = MaintenanceFormView.DraftMaterial

    @Environment(\.dismiss) private var dismiss
    @State private var draft: Draft
    let isNew: Bool
    let onCommit: (Draft) -> Void

    private let units = ["Stk", "l", "kg", "m", "Set", "Paar"]

    init(material: Draft, isNew: Bool, onCommit: @escaping (Draft) -> Void) {
        _draft = State(initialValue: material)
        self.isNew = isNew
        self.onCommit = onCommit
    }

    private var nameValid: Bool {
        let n = draft.name.trimmed
        return !n.isEmpty && n.count <= MaintenanceMaterial.maxName
    }

    private var quantityValid: Bool {
        guard let q = draft.quantity.asDouble else { return false }
        return q > 0 && q <= MaintenanceMaterial.maxQuantity
    }

    private var priceValid: Bool {
        if draft.unitPrice.trimmed.isEmpty { return true }
        guard let p = draft.unitPrice.asDouble else { return false }
        return p >= 0 && p <= MaintenanceMaterial.maxUnitPrice
    }

    private var partNumberValid: Bool { draft.partNumber.trimmed.count <= MaintenanceMaterial.maxPartNumber }
    private var unitValid: Bool { draft.unit.trimmed.count <= MaintenanceMaterial.maxUnit }

    private var canCommit: Bool { nameValid && quantityValid && priceValid && partNumberValid && unitValid }

    /// Hinweis nur für tatsächlich fehlerhafte Eingaben (leerer Name sperrt bloss den Button).
    private var validationMessage: String? {
        if draft.name.trimmed.count > MaintenanceMaterial.maxName {
            return "Bezeichnung höchstens \(MaintenanceMaterial.maxName) Zeichen."
        }
        if !partNumberValid { return "Art.-Nr. höchstens \(MaintenanceMaterial.maxPartNumber) Zeichen." }
        if !draft.quantity.trimmed.isEmpty && !quantityValid { return "Menge muss grösser als 0 sein." }
        if !unitValid { return "Einheit höchstens \(MaintenanceMaterial.maxUnit) Zeichen." }
        if !priceValid { return "Einzelpreis ungültig." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Bezeichnung (z. B. Motoröl 5W-30)", text: $draft.name)
                    TextField("Art.-Nr. (optional)", text: $draft.partNumber)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                }

                Section {
                    UnitField("Menge", text: $draft.quantity, unit: draft.unit.nilIfEmpty ?? "Stk")
                    LabeledContent("Einheit") {
                        HStack(spacing: 8) {
                            TextField("Stk", text: $draft.unit)
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            Menu {
                                ForEach(units, id: \.self) { u in
                                    Button(u) { draft.unit = u }
                                }
                            } label: {
                                Image(systemName: "chevron.up.chevron.down")
                            }
                            .accessibilityLabel("Einheit auswählen")
                        }
                    }
                    UnitField("Einzelpreis", text: $draft.unitPrice, unit: "CHF", placeholder: "optional")
                    if let total = draft.lineTotal {
                        LabeledContent("Total") {
                            Text(Fmt.chf(total)).fontWeight(.semibold).monospacedDigit()
                        }
                    }
                } footer: {
                    if let message = validationMessage {
                        Text(message).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isNew ? "Neues Material" : "Material bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Hinzufügen" : "Übernehmen") {
                        commit()
                        dismiss()
                    }
                    .disabled(!canCommit)
                    .accessibilityLabel(isNew ? "Material hinzufügen" : "Änderungen übernehmen")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func commit() {
        var d = draft
        d.name = d.name.trimmed
        d.partNumber = d.partNumber.trimmed
        d.quantity = d.quantity.trimmed
        d.unit = d.unit.nilIfEmpty ?? "Stk"
        d.unitPrice = d.unitPrice.trimmed
        onCommit(d)
    }
}
