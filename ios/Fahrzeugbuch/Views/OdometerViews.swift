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
                        rowView(row, icon: "gauge.with.dots.needle.67percent", color: .infoText,
                                detail: r.note ?? "Manuell erfasst", pending: store.isPending(r.id))
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        if store.canWrite {
                            Button("Stornieren", role: .destructive) { toDelete = r }
                        }
                    }
                case .fuel:
                    rowView(row, icon: "fuelpump", color: .successText, detail: "Tankvorgang", pending: false)
                case .maintenance(let title):
                    rowView(row, icon: "wrench.and.screwdriver", color: .warningText, detail: title, pending: false)
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
        .reasonedStorno($toDelete, title: "Kilometerstand stornieren?",
                        message: { _ in "Der Kilometerstand wird als storniert markiert und bleibt im Änderungsprotokoll erhalten." },
                        requiresReason: { store.requiresReason(odometer: $0) }) { reading, reason in
            store.delete(reading, reason: reason)
        }
        .refreshable { await store.sync() }
    }

    private func rowView(_ row: Row, icon: String, color: Color, detail: String, pending: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).frame(minWidth: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Fmt.km(row.km)).font(.headline)
                    if pending { PendingBadge() }
                }
                Text(detail).font(.footnote).foregroundStyle(Color.neutralText)
                Text(Fmt.day(row.date)).font(.footnote).foregroundStyle(Color.neutralText)
            }
            Spacer(minLength: 0)
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
    @State private var didPrefill = false
    @State private var reason = ""
    @State private var initial = ""
    @State private var lastKm = 0
    @State private var scan: ScanRequest?
    /// Tacho-Foto, das beim Sichern als Beleg (mit vehicle_id) angelegt wird
    @State private var newAttachments: [PendingAttachment] = []

    private var snapshot: String {
        FormSnapshot.make([FormSnapshot.date(date), km, note, String(newAttachments.count), reason])
    }

    private var hasChanges: Bool { didPrefill && snapshot != initial }

    private var candidate: OdometerReading {
        var r = reading ?? OdometerReading(vehicleId: vehicle.id, date: date, km: km.asInt ?? 0)
        r.date = date
        return r
    }

    private var reasonRequired: Bool { store.requiresReason(odometer: candidate) }

    private var kmPlaceholder: String {
        lastKm > 0 ? "zuletzt \(lastKm.formatted(.number))" : "vom Tacho"
    }

    private var unchangedWarning: String? {
        guard reading == nil, lastKm > 0, let k = km.asInt else { return nil }
        if k == lastKm { return "Kilometerstand unverändert gegenüber dem letzten Eintrag – bitte vom Tacho ablesen." }
        if k < lastKm { return "Kleiner als der letzte bekannte Kilometerstand (\(Fmt.km(lastKm)))." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Datum", selection: $date, displayedComponents: .date)
                    HStack(spacing: 8) {
                        UnitField("Kilometerstand", text: $km, unit: "km", keyboard: .numberPad,
                                  placeholder: kmPlaceholder)
                        if store.canWrite {
                            Button { scan = ScanRequest(kind: .odometer) } label: {
                                Image(systemName: "camera")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Kilometerstand vom Tacho scannen")
                        }
                    }
                    TextField("Notiz (optional)", text: $note, axis: .vertical)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let w = unchangedWarning {
                            Label(w, systemImage: "exclamationmark.triangle").foregroundStyle(Color.warningText)
                        }
                        if !newAttachments.isEmpty {
                            Text("Das Tacho-Foto wird beim Sichern als Beleg gespeichert.")
                        }
                    }
                }
                if reasonRequired && store.canWrite {
                    ReasonSection(reason: $reason, monthLabel: TripMonth.label(TripMonth.key(date)))
                }
                if !newAttachments.isEmpty {
                    Section("Belege") {
                        AttachmentStrip(attachments: [], pending: newAttachments) { p in
                            newAttachments.removeAll { $0.id == p.id }
                        }
                    }
                }
                if let r = reading {
                    HistorySection(entity: OdometerReading.entityName, id: r.id)
                }
            }
            .navigationTitle(reading == nil ? "Kilometerstand" : "Kilometerstand bearbeiten")
            .formToolbar(canSave: store.canWrite && km.asInt != nil
                            && (!reasonRequired || CorrectionReason.isValid(reason)),
                         hasChanges: hasChanges, save: save)
            .sheet(item: $scan) { request in
                ScannerView(kinds: [.odometer], initialKind: request.kind, lastKnownKm: lastKmForScan) { outcome in
                    if let k = outcome.km { km = String(k) }
                    if let data = outcome.attachmentJPEG {
                        newAttachments.append(PendingAttachment(kind: .odometer, data: data))
                    }
                }
            }
            .onAppear {
                // nur einmal (Vollbild-Ansichten lösen onAppear erneut aus)
                guard !didPrefill else { return }
                didPrefill = true
                if let r = reading {
                    date = r.date
                    km = String(r.km)
                    note = r.note ?? ""
                } else {
                    // Letzter Stand nur als Platzhalter (U6)
                    lastKm = store.lastKnownKm(for: vehicle.id)
                }
                initial = snapshot
            }
        }
    }

    private func save() {
        guard let kmValue = km.asInt else { return }
        var r = reading ?? OdometerReading(vehicleId: vehicle.id, date: date, km: kmValue)
        r.date = date
        r.km = kmValue
        r.note = note.nilIfEmpty
        store.save(r, reason: reasonRequired ? reason.trimmed : nil)
        for attachment in newAttachments {
            store.addAttachment(imageData: attachment.data, kind: attachment.kind.rawValue, fuelId: nil,
                                maintenanceId: nil, vehicleId: vehicle.id)
        }
        newAttachments = []
    }

    /// Plausibilität des Tacho-Scans (nur bei neuem Kilometerstand)
    private var lastKmForScan: Int? {
        guard reading == nil else { return nil }
        let last = store.lastKnownKm(for: vehicle.id)
        return last > 0 ? last : nil
    }
}
