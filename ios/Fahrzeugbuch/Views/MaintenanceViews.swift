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
        .reasonedStorno($toDelete, title: "Wartung stornieren?",
                        message: { _ in "Die Wartung wird als storniert markiert und bleibt im Änderungsprotokoll erhalten." },
                        requiresReason: { store.requiresReason(maintenance: $0) }) { m, reason in
            store.delete(m, reason: reason)
        }
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
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(maintenance.title).font(.headline)
                Spacer()
                if let c = maintenance.cost {
                    Text(Fmt.chf(c))
                } else if hasMaterialPrice {
                    // ohne Rechnungsbetrag zählt die Materialsumme
                    let total = MaintenanceMaterial.total(materials)
                    Text(Fmt.chf(total))
                        .foregroundStyle(Color.neutralText)
                        .accessibilityLabel("Material \(Fmt.chf(total))")
                }
            }
            if pending || due?.overdue == true || due?.dueSoon == true {
                HStack(spacing: 6) {
                    if let due {
                        if due.overdue {
                            StatusTag(text: "Überfällig", color: .red, systemImage: "exclamationmark.triangle.fill")
                        } else if due.dueSoon {
                            StatusTag(text: "Bald fällig", color: .orange, systemImage: "clock")
                        }
                    }
                    if pending { PendingBadge() }
                }
            }
            HStack(spacing: 8) {
                Text(Fmt.day(maintenance.date) + (maintenance.km.map { " · " + Fmt.km($0) } ?? ""))
                Spacer(minLength: 4)
                if !materials.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "shippingbox")
                        Text("\(materials.count)")
                    }
                    .fixedSize()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(materials.count == 1 ? "1 Materialposition"
                                        : "\(materials.count) Materialpositionen")
                }
                if !items.isEmpty {
                    let complete = doneCount == items.count
                    Label("\(doneCount)/\(items.count)",
                          systemImage: complete ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(complete ? Color.successText : Color.neutralText)
                        .fixedSize()
                }
            }
            .font(.subheadline)
            .foregroundStyle(Color.neutralText)
            if !items.isEmpty {
                ProgressView(value: Double(doneCount), total: Double(items.count))
                    .tint(doneCount == items.count ? .green : .accentColor)
            }
            if let due {
                Text(due.dueText).font(.footnote)
                    .foregroundStyle(due.overdue ? Color.dangerText : Color.neutralText)
            }
            AuthorNote(createdBy: maintenance.createdBy)
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
                    if m.deleted { Label("Storniert", systemImage: "xmark.circle").foregroundStyle(Color.dangerText) }
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

                AuthorshipSection(createdBy: m.createdBy, updatedBy: m.updatedBy)
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
        /// Verknüpfter Stammartikel
        var articleId: String?
        /// Neuer Stammartikel („In Materialstamm speichern“) – wird erst beim Sichern der Wartung angelegt,
        /// damit Abbrechen nichts im Stamm hinterlässt.
        var pendingArticle: MaterialArticle?
        /// Einzelpreis beim Sichern der Wartung in den verknüpften Stammartikel übernehmen
        var updateCatalogPrice = false

        var lineTotal: Double? {
            guard let q = quantity.asDouble, let p = unitPrice.asDouble else { return nil }
            return q * p
        }

        static func from(_ m: MaintenanceMaterial) -> DraftMaterial {
            DraftMaterial(id: m.id, version: m.version, name: m.name, partNumber: m.partNumber ?? "",
                          quantity: Fmt.editQty(m.quantity), unit: m.unit,
                          unitPrice: m.unitPrice.map { priceText($0) } ?? "", articleId: m.articleId)
        }

        /// Zwei Nachkommastellen, ausser der Preis hat mehr (sonst gälte er beim Sichern als geändert).
        static func priceText(_ p: Double) -> String {
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
    @State private var reason = ""
    @State private var initial = ""
    @State private var lastKm = 0

    private var materialTotal: Double {
        materials.reduce(0.0) { $0 + ($1.lineTotal ?? 0) }
    }

    private var costMatchesMaterial: Bool {
        guard let c = cost.asDouble else { return false }
        return abs(c - materialTotal) < 0.005
    }

    private var snapshot: String {
        var parts = [title, FormSnapshot.date(date), km, cost, note, String(hasDueKm), dueKm, String(hasDueDate),
                     FormSnapshot.date(dueDate), reason]
        parts += items.map { "\($0.id)|\($0.label)|\($0.done)" }
        parts += materials.map { "\($0.id)|\($0.name)|\($0.partNumber)|\($0.quantity)|\($0.unit)|\($0.unitPrice)" }
        return FormSnapshot.make(parts)
    }

    private var hasChanges: Bool { didPrefill && snapshot != initial }

    private var candidate: Maintenance {
        var m = maintenance ?? Maintenance(vehicleId: vehicle.id, date: date, title: title.trimmed)
        m.date = date
        return m
    }

    private var reasonRequired: Bool { store.requiresReason(maintenance: candidate) }

    private var kmPlaceholder: String {
        lastKm > 0 ? "zuletzt \(lastKm.formatted(.number))" : "optional"
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
                    UnitField("Kilometerstand", text: $km, unit: "km", keyboard: .numberPad, placeholder: kmPlaceholder)
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

                if reasonRequired && store.canWrite {
                    ReasonSection(reason: $reason, monthLabel: TripMonth.label(TripMonth.key(date)))
                }
            }
            .sheet(item: $editingMaterial) { draft in
                MaterialEditView(material: draft, isNew: !materials.contains { $0.id == draft.id },
                                 vehicleId: vehicle.id) { updated in
                    commitMaterial(updated)
                }
            }
            .navigationTitle(maintenance == nil ? "Neue Wartung" : "Wartung bearbeiten")
            .formToolbar(canSave: store.canWrite && !title.trimmed.isEmpty
                            && (!reasonRequired || CorrectionReason.isValid(reason)),
                         hasChanges: hasChanges, save: save)
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
        defer { initial = snapshot }
        guard let m = maintenance else {
            // Letzter Stand nur als Platzhalter (U6)
            lastKm = store.lastKnownKm(for: vehicle.id)
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
                                       unit: d.unit.nilIfEmpty ?? "Stk", unitPrice: d.unitPrice.asDouble,
                                       articleId: d.articleId)
        }
        // Stammartikel zuerst, damit die Positionen auf bereits angelegte Artikel verweisen
        saveCatalogChanges()
        store.save(m, items: newItems, materials: newMaterials, reason: reasonRequired ? reason.trimmed : nil)
    }

    /// Neue Stammartikel anlegen bzw. Stammpreise aktualisieren (nur für Positionen, die gesichert werden).
    private func saveCatalogChanges() {
        guard store.canWrite else { return }
        for d in materials {
            guard d.name.nilIfEmpty != nil, let quantity = d.quantity.asDouble, quantity > 0,
                  let articleId = d.articleId else { continue }
            if let newArticle = d.pendingArticle, newArticle.id == articleId {
                store.save(newArticle)
            } else if d.updateCatalogPrice, let price = d.unitPrice.asDouble,
                      var article = store.article(id: articleId), !article.deleted,
                      !MaterialArticle.samePrice(article.unitPrice, price) {
                article.unitPrice = price
                store.save(article)
            }
        }
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
/// Werte können aus dem Materialstamm übernommen werden; sie bleiben eine Kopie zum Erfassungszeitpunkt.
private struct MaterialEditView: View {
    typealias Draft = MaintenanceFormView.DraftMaterial

    @Environment(\.dismiss) private var dismiss
    @Environment(TenantStore.self) private var store
    @State private var draft: Draft
    /// Neuen Stammartikel anlegen (nur ohne verknüpften Artikel)
    @State private var saveToCatalog: Bool
    @State private var newCategory: String
    @State private var onlyThisVehicle: Bool
    @State private var showPicker = false
    @State private var askDiscard = false
    private let original: Draft
    let isNew: Bool
    let vehicleId: String?
    let onCommit: (Draft) -> Void

    private let units = ["Stk", "l", "kg", "m", "Set", "Paar"]
    private static let maxSuggestions = 5

    init(material: Draft, isNew: Bool, vehicleId: String? = nil, onCommit: @escaping (Draft) -> Void) {
        _draft = State(initialValue: material)
        _saveToCatalog = State(initialValue: material.pendingArticle != nil)
        _newCategory = State(initialValue: material.pendingArticle?.category ?? "")
        _onlyThisVehicle = State(initialValue: material.pendingArticle?.vehicleId != nil)
        self.original = material
        self.isNew = isNew
        self.vehicleId = vehicleId
        self.onCommit = onCommit
    }

    // MARK: Materialstamm

    /// Mit einem bestehenden Stammartikel verknüpft (nicht: neu anzulegender Artikel)
    private var isLinked: Bool { draft.articleId != nil && draft.pendingArticle == nil }

    private var linkedArticle: MaterialArticle? {
        guard isLinked, let id = draft.articleId else { return nil }
        return store.article(id: id)
    }

    private var linkedTitle: String {
        guard let a = linkedArticle else { return "Artikel nicht verfügbar" }
        if a.deleted { return a.name + " (storniert)" }
        return a.name
    }

    private var pickerTitle: String {
        isLinked ? "Anderen Artikel wählen" : "Aus Materialstamm wählen"
    }

    private var vehicleName: String? {
        guard let id = vehicleId else { return nil }
        return store.vehicle(id: id)?.name
    }

    /// Vorschläge beim Tippen der Bezeichnung (nur ohne Verknüpfung)
    private var suggestions: [MaterialArticle] {
        guard !isLinked else { return [] }
        let query = draft.name.trimmed
        guard query.count >= 2 else { return [] }
        let matches = store.articles(for: vehicleId).filter { $0.matches(query) }
        // Treffer am Wortanfang zuerst
        let ranked = matches.sorted { a, b in
            let pa = a.name.lowercased().hasPrefix(query.lowercased())
            let pb = b.name.lowercased().hasPrefix(query.lowercased())
            if pa != pb { return pa }
            return MaterialArticle.catalogOrder(a, b)
        }
        return Array(ranked.prefix(Self.maxSuggestions))
    }

    /// Gleichnamiger Stammartikel (Hinweis beim Anlegen, um Doppelte zu vermeiden)
    private var duplicateArticle: MaterialArticle? {
        let n = draft.name.trimmed
        guard !n.isEmpty else { return nil }
        let part = draft.partNumber.trimmed
        return store.articles(for: nil).first { a in
            a.name.compare(n, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                && (a.partNumber ?? "").compare(part, options: [.caseInsensitive]) == .orderedSame
        }
    }

    /// Einzelpreis weicht vom (gültigen) Stammpreis ab → Aktualisieren anbieten
    private var canUpdatePrice: Bool {
        guard store.canWrite, let a = linkedArticle, !a.deleted, priceValid,
              let price = draft.unitPrice.asDouble else { return false }
        return !MaterialArticle.samePrice(a.unitPrice, price)
    }

    private var priceFooter: String {
        var oldText = "ohne Preis"
        if let a = linkedArticle, let p = a.unitPrice { oldText = Fmt.chf(p) }
        var newText = "–"
        if let p = draft.unitPrice.asDouble { newText = Fmt.chf(p) }
        return "Stammpreis \(oldText) → \(newText). Wird beim Sichern der Wartung übernommen."
    }

    private var catalogFooter: String {
        if let d = duplicateArticle {
            return "Im Materialstamm gibt es bereits «\(d.name)». Zum Verknüpfen den Vorschlag oben wählen."
        }
        return "Der Artikel wird beim Sichern der Wartung angelegt und steht danach zur Auswahl."
    }

    /// Stepper-Bindung an die Texteingabe: −/+ um 1, nie unter 1 (leere/ungültige Eingabe zählt als 1)
    private var quantityStep: Binding<Double> {
        Binding(
            get: { max(1, draft.quantity.asDouble ?? 1) },
            set: { draft.quantity = Fmt.editQty(max(1, $0)) }
        )
    }

    // MARK: Validierung

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
    private var categoryValid: Bool {
        isLinked || !saveToCatalog || newCategory.trimmed.count <= MaterialArticle.maxCategory
    }

    private var canCommit: Bool {
        nameValid && quantityValid && priceValid && partNumberValid && unitValid && categoryValid
    }

    /// Hinweis nur für tatsächlich fehlerhafte Eingaben (leerer Name sperrt bloss den Button).
    private var validationMessage: String? {
        if draft.name.trimmed.count > MaintenanceMaterial.maxName {
            return "Bezeichnung höchstens \(MaintenanceMaterial.maxName) Zeichen."
        }
        if !partNumberValid { return "Art.-Nr. höchstens \(MaintenanceMaterial.maxPartNumber) Zeichen." }
        if !draft.quantity.trimmed.isEmpty && !quantityValid { return "Menge muss grösser als 0 sein." }
        if !unitValid { return "Einheit höchstens \(MaintenanceMaterial.maxUnit) Zeichen." }
        if !priceValid { return "Einzelpreis ungültig." }
        if !categoryValid { return "Kategorie höchstens \(MaterialArticle.maxCategory) Zeichen." }
        return nil
    }

    // MARK: Ansicht

    var body: some View {
        NavigationStack {
            Form {
                catalogSection

                Section {
                    TextField("Bezeichnung (z. B. Motoröl 5W-30)", text: $draft.name)
                    ForEach(suggestions) { a in
                        suggestionRow(a)
                    }
                    TextField("Art.-Nr. (optional)", text: $draft.partNumber)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                }

                Section {
                    LabeledContent("Menge") {
                        HStack(spacing: 8) {
                            TextField("Menge", text: $draft.quantity)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                            Text(draft.unit.nilIfEmpty ?? "Stk").foregroundStyle(.secondary)
                            // Menge ohne Tastatur ändern (ganze Schritte; Dezimalwerte bleiben per Eingabe möglich)
                            Stepper("Menge", value: quantityStep, in: 1...MaintenanceMaterial.maxQuantity, step: 1)
                                .labelsHidden()
                                .fixedSize()
                        }
                    }
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
                        Text(message).foregroundStyle(Color.dangerText)
                    }
                }

                catalogOptionsSection
            }
            .navigationTitle(isNew ? "Neues Material" : "Material bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        if draft != original {
                            askDiscard = true
                        } else {
                            dismiss()
                        }
                    }
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
            .sheet(isPresented: $showPicker) {
                MaterialPickerView(vehicleId: vehicleId) { article in
                    apply(article)
                }
            }
            .discardGuard(hasChanges: draft != original, isAsking: $askDiscard)
        }
        // volle Höhe: bei halber Höhe verdeckte die Zahlentastatur das Mengenfeld
        .presentationDetents([.large])
    }

    private var catalogSection: some View {
        Section {
            if isLinked {
                HStack(spacing: 12) {
                    Image(systemName: "link")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Aus Materialstamm").font(.caption).foregroundStyle(.secondary)
                        Text(linkedTitle)
                    }
                    Spacer(minLength: 8)
                    Button("Lösen") { unlink() }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Verknüpfung mit Materialstamm lösen")
                }
                .accessibilityElement(children: .contain)
            }
            Button { showPicker = true } label: {
                Label(pickerTitle, systemImage: "magnifyingglass")
            }
            .accessibilityHint("Öffnet die Suche im Materialstamm")
        } footer: {
            if isLinked {
                Text("Die Werte sind eine Kopie des Stammartikels und können hier angepasst werden.")
            }
        }
    }

    @ViewBuilder
    private var catalogOptionsSection: some View {
        if !isLinked {
            if store.canWrite {
                Section {
                    Toggle("In Materialstamm speichern", isOn: $saveToCatalog)
                    if saveToCatalog {
                        ArticleCategoryField(text: $newCategory)
                        if let name = vehicleName {
                            Toggle("Nur für \(name)", isOn: $onlyThisVehicle)
                        }
                    }
                } footer: {
                    if saveToCatalog {
                        Text(catalogFooter)
                    }
                }
            }
        } else if canUpdatePrice {
            Section {
                Toggle("Preis im Stamm aktualisieren", isOn: $draft.updateCatalogPrice)
            } footer: {
                Text(priceFooter)
            }
        }
    }

    private func suggestionRow(_ article: MaterialArticle) -> some View {
        Button { apply(article) } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.left.circle")
                    .foregroundStyle(.tint)
                MaterialArticleRow(article: article)
            }
            .font(.subheadline)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Vorschlag übernehmen: \(article.name)")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Aktionen

    /// Übernimmt die Werte des Stammartikels; die Menge bleibt.
    private func apply(_ article: MaterialArticle) {
        draft.name = article.name
        draft.partNumber = article.partNumber ?? ""
        draft.unit = article.unit
        draft.unitPrice = article.unitPrice.map { Draft.priceText($0) } ?? ""
        if draft.quantity.trimmed.isEmpty { draft.quantity = "1" }
        draft.articleId = article.id
        draft.pendingArticle = nil
        draft.updateCatalogPrice = false
        saveToCatalog = false
    }

    private func unlink() {
        draft.articleId = nil
        draft.pendingArticle = nil
        draft.updateCatalogPrice = false
    }

    private func commit() {
        var d = draft
        d.name = d.name.trimmed
        d.partNumber = d.partNumber.trimmed
        d.quantity = d.quantity.trimmed
        d.unit = d.unit.nilIfEmpty ?? "Stk"
        d.unitPrice = d.unitPrice.trimmed
        if isLinked {
            d.pendingArticle = nil
            if !canUpdatePrice { d.updateCatalogPrice = false }
        } else if saveToCatalog && store.canWrite {
            // Artikel vormerken; angelegt wird er erst beim Sichern der Wartung
            var article = d.pendingArticle ?? MaterialArticle(name: d.name)
            article.name = d.name
            article.partNumber = d.partNumber.nilIfEmpty
            article.unit = d.unit
            article.unitPrice = d.unitPrice.asDouble
            article.category = newCategory.nilIfEmpty
            article.vehicleId = onlyThisVehicle && vehicleName != nil ? vehicleId : nil
            d.pendingArticle = article
            d.articleId = article.id
            d.updateCatalogPrice = false
        } else {
            d.pendingArticle = nil
            d.articleId = nil
            d.updateCatalogPrice = false
        }
        onCommit(d)
    }
}
