import SwiftUI

/// Zeitachse aller Kilometerstände: manuell erfasste (bearbeitbar) sowie aus Tankungen und Wartungen.
struct OdometerListView: View {
    @Environment(TenantStore.self) private var store
    let vehicle: Vehicle
    @State private var form: EditTarget<OdometerReading>?
    @State private var toDelete: OdometerReading?

    private struct Row: Identifiable {
        enum Source { case manual(OdometerReading), fuel, maintenance(String) }
        let id: String
        let date: Date
        let km: Int
        let source: Source
    }

    private var allRows: [Row] {
        var r = store.odometer(for: vehicle.id).map { Row(id: $0.id, date: $0.date, km: $0.km, source: .manual($0)) }
        r += store.fuel(for: vehicle.id).map { Row(id: $0.id, date: $0.date, km: $0.km, source: .fuel) }
        r += store.maintenance(for: vehicle.id).compactMap { m in
            m.km.map { Row(id: m.id, date: m.date, km: $0, source: .maintenance(m.title)) }
        }
        return r.sorted { ($0.date, $0.km) > ($1.date, $1.km) }
    }

    var body: some View {
        let rows = allRows
        List {
            ForEach(rows) { row in
                switch row.source {
                case .manual(let r):
                    Button { form = EditTarget(value: r) } label: {
                        rowView(row, icon: "gauge.with.dots.needle.67percent", color: .blue,
                                detail: r.note ?? "Manuell erfasst", pending: store.isPending(r.id))
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        if store.canWrite {
                            Button("Stornieren", role: .destructive) { toDelete = r }
                        }
                    }
                case .fuel:
                    rowView(row, icon: "fuelpump", color: .green, detail: "Tankvorgang", pending: false)
                case .maintenance(let title):
                    rowView(row, icon: "wrench.and.screwdriver", color: .orange, detail: title, pending: false)
                }
            }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView("Keine Kilometerstände", systemImage: "gauge.with.dots.needle.67percent",
                                       description: Text("Tankvorgänge und Wartungen erscheinen hier automatisch."))
            }
        }
        .toolbar {
            if store.canWrite {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { form = EditTarget(value: nil) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Kilometerstand hinzufügen")
                }
            }
        }
        .sheet(item: $form) { target in
            OdometerFormView(vehicle: vehicle, reading: target.value)
        }
        .stornoDialog($toDelete, title: "Kilometerstand stornieren?") { store.delete($0) }
        .refreshable { await store.sync() }
    }

    private func rowView(_ row: Row, icon: String, color: Color, detail: String, pending: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Fmt.km(row.km)).font(.headline)
                    if pending { PendingBadge() }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Fmt.day(row.date)).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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
                    UnitField("Kilometerstand", text: $km, unit: "km", keyboard: .numberPad)
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
