import SwiftUI

struct MaintenanceListView: View {
    @Environment(TenantStore.self) private var store
    let vehicle: Vehicle
    @State private var showNew = false
    @State private var toDelete: Maintenance?

    var body: some View {
        let entries = store.maintenance(for: vehicle.id)
        List {
            ForEach(entries) { m in
                NavigationLink {
                    MaintenanceDetailView(maintenanceId: m.id, vehicle: vehicle)
                } label: {
                    MaintenanceRow(maintenance: m, items: store.items(for: m.id), pending: store.isPending(m.id))
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
    let pending: Bool

    private var doneCount: Int { items.filter(\.done).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(maintenance.title).font(.headline)
                if pending { PendingBadge() }
                Spacer()
                if let c = maintenance.cost { Text(Fmt.chf(c)) }
            }
            HStack {
                Text(Fmt.day(maintenance.date))
                if let km = maintenance.km { Text("· \(Fmt.km(km))") }
                Spacer()
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
        }
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
            List {
                Section {
                    LabeledContent("Datum", value: Fmt.day(m.date))
                    if let km = m.km { LabeledContent("Kilometerstand", value: Fmt.km(km)) }
                    if let c = m.cost { LabeledContent("Kosten", value: Fmt.chf(c)) }
                    if let n = m.nextDueKm { LabeledContent("Nächste bei", value: Fmt.km(n)) }
                    if let d = m.nextDueDate { LabeledContent("Nächste bis", value: Fmt.day(d)) }
                    if m.deleted { Label("Storniert", systemImage: "xmark.circle").foregroundStyle(.red) }
                }

                if !items.isEmpty {
                    Section {
                        ForEach(items) { item in
                            Button { store.toggle(item) } label: {
                                Label {
                                    Text(item.label)
                                        .strikethrough(item.done)
                                        .foregroundStyle(item.done ? .secondary : .primary)
                                } icon: {
                                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(item.done ? .green : .secondary)
                                        .imageScale(.large)
                                }
                            }
                            .disabled(!store.canWrite || m.deleted)
                        }
                    } header: {
                        Text("Checkliste")
                    } footer: {
                        Text("\(items.filter(\.done).count) von \(items.count) erledigt – jedes Abhaken wird protokolliert.")
                    }
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
                    LabeledContent("Kilometerstand") {
                        TextField("km", text: $km).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Kosten (CHF)") {
                        TextField("optional", text: $cost).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                }

                Section("Nächste Fälligkeit") {
                    Toggle("Nach Kilometerstand", isOn: $hasDueKm)
                    if hasDueKm {
                        LabeledContent("Fällig bei") {
                            TextField("km", text: $dueKm).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        }
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
            .navigationTitle(maintenance == nil ? "Neue Wartung" : "Wartung bearbeiten")
            .formToolbar(canSave: store.canWrite && !title.trimmed.isEmpty, save: save)
            .onAppear(perform: prefill)
            .task { await loadTemplates() }
        }
    }

    private func prefill() {
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
        store.save(m, items: newItems)
    }
}
