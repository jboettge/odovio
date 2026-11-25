import SwiftUI

struct MaintenanceListView: View {
    @Environment(AppSettings.self) private var settings
    let vehicle: Vehicle
    @State private var entries: [Maintenance] = []
    @State private var loaded = false
    @State private var showNew = false
    @State private var error: String?

    var body: some View {
        List {
            ForEach(entries) { m in
                NavigationLink {
                    MaintenanceDetailView(maintenance: m, vehicle: vehicle) { await load() }
                } label: {
                    MaintenanceRow(maintenance: m)
                }
            }
            .onDelete { offsets in Task { await delete(offsets) } }
        }
        .overlay {
            if loaded && entries.isEmpty {
                ContentUnavailableView("Keine Wartungen", systemImage: "wrench.and.screwdriver",
                                       description: Text("Mit + eine Wartung mit Checkliste erfassen."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNew = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showNew) {
            MaintenanceFormView(vehicle: vehicle, maintenance: nil) { _ in await load() }
        }
        .task { await load() }
        .refreshable { await load() }
        .errorAlert($error)
    }

    private func load() async {
        do {
            entries = try await settings.api.get("api/vehicles/\(vehicle.id)/maintenance")
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func delete(_ offsets: IndexSet) async {
        let ids = offsets.map { entries[$0].id }
        entries.remove(atOffsets: offsets)
        do {
            for id in ids { try await settings.api.delete("api/maintenance/\(id)") }
        } catch {
            self.error = error.localizedDescription
        }
        await load()
    }
}

private struct MaintenanceRow: View {
    let maintenance: Maintenance

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(maintenance.title).font(.headline)
                Spacer()
                if let c = maintenance.cost { Text(Fmt.chf(c)) }
            }
            HStack {
                Text(Fmt.day(maintenance.date))
                if let km = maintenance.km { Text("· \(Fmt.km(km))") }
                Spacer()
                if !maintenance.items.isEmpty {
                    let complete = maintenance.doneCount == maintenance.items.count
                    Label("\(maintenance.doneCount)/\(maintenance.items.count)",
                          systemImage: complete ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(complete ? .green : .secondary)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if !maintenance.items.isEmpty {
                ProgressView(value: Double(maintenance.doneCount), total: Double(maintenance.items.count))
                    .tint(maintenance.doneCount == maintenance.items.count ? .green : .accentColor)
            }
        }
    }
}

struct MaintenanceDetailView: View {
    @Environment(AppSettings.self) private var settings
    @State var maintenance: Maintenance
    let vehicle: Vehicle
    let onChange: () async -> Void

    @State private var editing = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                LabeledContent("Datum", value: Fmt.day(maintenance.date))
                if let km = maintenance.km { LabeledContent("Kilometerstand", value: Fmt.km(km)) }
                if let c = maintenance.cost { LabeledContent("Kosten", value: Fmt.chf(c)) }
                if let n = maintenance.nextDueKm { LabeledContent("Nächste bei", value: Fmt.km(n)) }
                if let d = maintenance.nextDueDate { LabeledContent("Nächste bis", value: Fmt.day(d)) }
            }

            if !maintenance.items.isEmpty {
                Section {
                    ForEach(maintenance.items) { item in
                        Button { Task { await toggle(item) } } label: {
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
                    }
                } header: {
                    Text("Checkliste")
                } footer: {
                    Text("\(maintenance.doneCount) von \(maintenance.items.count) erledigt")
                }
            }

            if let note = maintenance.note, !note.isEmpty {
                Section("Notiz") { Text(note) }
            }
        }
        .navigationTitle(maintenance.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Bearbeiten") { editing = true }
            }
        }
        .sheet(isPresented: $editing) {
            MaintenanceFormView(vehicle: vehicle, maintenance: maintenance) { updated in
                maintenance = updated
                await onChange()
            }
        }
        .errorAlert($error)
    }

    private func toggle(_ item: MaintenanceItem) async {
        let newValue = !item.done
        setDone(item.id, newValue) // optimistisch
        do {
            let updated: MaintenanceItem = try await settings.api.patch(
                "api/maintenance-items/\(item.id)", ItemPatch(done: newValue))
            setDone(item.id, updated.done)
            await onChange()
        } catch {
            setDone(item.id, item.done)
            self.error = error.localizedDescription
        }
    }

    private func setDone(_ id: Int, _ done: Bool) {
        if let i = maintenance.items.firstIndex(where: { $0.id == id }) {
            maintenance.items[i].done = done
        }
    }
}

struct MaintenanceFormView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    let vehicle: Vehicle
    let maintenance: Maintenance?
    let onSaved: (Maintenance) async -> Void

    struct DraftItem: Identifiable {
        let id = UUID()
        var label: String
        var done: Bool
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
    @State private var saving = false
    @State private var error: String?

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
            .formToolbar(canSave: !title.trimmed.isEmpty, saving: saving) { await save() }
            .onAppear(perform: prefill)
            .task { await loadTemplates() }
            .errorAlert($error)
        }
    }

    private func prefill() {
        guard let m = maintenance else {
            if km.isEmpty && vehicle.currentKm > 0 { km = String(vehicle.currentKm) }
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
        items = m.items.map { DraftItem(label: $0.label, done: $0.done) }
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

    private func loadTemplates() async {
        guard maintenance == nil else { return }
        templates = (try? await settings.api.get("api/checklist-templates")) ?? []
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let input = MaintenanceInput(
            date: date,
            km: km.asInt,
            title: title.trimmed,
            cost: cost.asDouble,
            note: note.nilIfEmpty,
            nextDueKm: hasDueKm ? dueKm.asInt : nil,
            nextDueDate: hasDueDate ? dueDate : nil,
            items: items.compactMap { d in
                d.label.nilIfEmpty.map { MaintenanceItemInput(label: $0, done: d.done) }
            }
        )
        do {
            let saved: Maintenance
            if let m = maintenance {
                saved = try await settings.api.put("api/maintenance/\(m.id)", input)
            } else {
                saved = try await settings.api.post("api/vehicles/\(vehicle.id)/maintenance", input)
            }
            await onSaved(saved)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
