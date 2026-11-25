import SwiftUI

/// Vom Server abgelehnte Änderungen: Fehler ansehen, Eintrag bearbeiten, erneut senden oder verwerfen.
@MainActor
struct RejectedOpsView: View {
    @Environment(TenantStore.self) private var store
    @State private var editTrip: EditTarget<Trip>?
    @State private var editFuel: EditTarget<FuelEntry>?
    @State private var editOdometer: EditTarget<OdometerReading>?
    @State private var editMaintenance: EditTarget<Maintenance>?
    @State private var editVehicle: EditTarget<Vehicle>?
    @State private var editPlace: EditTarget<Place>?
    @State private var toDismiss: RejectedOp?
    @State private var retryWithReason: EditTarget<RejectedOp>?

    /// Nur für Demo/Screenshots: feste Einträge statt `store.rejectedOps`
    private let previewOps: [RejectedOp]?

    init(previewOps: [RejectedOp]? = nil) {
        self.previewOps = previewOps
    }

    var body: some View {
        let ops = previewOps ?? store.rejectedOps
        List {
            if ops.isEmpty {
                ContentUnavailableView("Keine abgelehnten Änderungen", systemImage: "checkmark.icloud",
                                       description: Text("Alle Änderungen wurden vom Server übernommen."))
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(ops, id: \.id) { op in
                        row(op)
                    }
                } footer: {
                    Text("Der Server hat diese Änderungen nicht übernommen. Auf dem Gerät gilt wieder der Stand "
                         + "des Servers. «Bearbeiten» öffnet den Eintrag zum Korrigieren, «Erneut senden» "
                         + "überträgt die Änderung noch einmal, «Verwerfen» entfernt den Hinweis.")
                }
            }
        }
        .navigationTitle("Abgelehnte Änderungen")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editTrip) { t in
            if let trip = t.value, let v = store.vehicle(id: trip.vehicleId) {
                TripFormView(vehicle: v, trip: trip)
            }
        }
        .sheet(item: $editFuel) { t in
            if let e = t.value, let v = store.vehicle(id: e.vehicleId) {
                FuelFormView(vehicle: v, entry: e)
            }
        }
        .sheet(item: $editOdometer) { t in
            if let r = t.value, let v = store.vehicle(id: r.vehicleId) {
                OdometerFormView(vehicle: v, reading: r)
            }
        }
        .sheet(item: $editMaintenance) { t in
            if let m = t.value, let v = store.vehicle(id: m.vehicleId) {
                MaintenanceFormView(vehicle: v, maintenance: m)
            }
        }
        .sheet(item: $editVehicle) { t in
            VehicleFormView(vehicle: t.value)
        }
        .sheet(item: $editPlace) { t in
            PlaceFormView(place: t.value)
        }
        .confirmationDialog("Hinweis verwerfen?", isPresented: Binding(
            get: { toDismiss != nil }, set: { if !$0 { toDismiss = nil } }),
                            titleVisibility: .visible, presenting: toDismiss) { op in
            Button("Verwerfen", role: .destructive) { store.dismissRejected(op.id) }
        } message: { _ in
            Text("Die abgelehnte Änderung wird nicht mehr gesendet. Der Eintrag behält den Stand des Servers.")
        }
        .sheet(item: $retryWithReason) { target in
            ReasonSheet(title: "Begründung ergänzen",
                        message: "Der Server verlangt eine Begründung, weil der Monat abgeschlossen ist. Die Änderung "
                            + "wird mit dieser Begründung erneut gesendet.",
                        confirmTitle: "Erneut senden", destructive: false) { reason in
                if let op = target.value { store.retryRejected(op.id, reason: reason) }
            }
        }
    }

    private func row(_ op: RejectedOp) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: Self.icon(op.entity))
                    .foregroundStyle(Color.dangerText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.entityLabel(op.entity)).font(.footnote).foregroundStyle(.secondary)
                    Text(op.label).font(.headline)
                }
            }
            Label(op.error, systemImage: "xmark.octagon")
                .font(.subheadline)
                .foregroundStyle(Color.dangerText)
            Text(op.date.formatted(date: .abbreviated, time: .shortened))
                .font(.footnote)
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { actions(op) }
                VStack(alignment: .leading, spacing: 10) { actions(op) }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.borderless)
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func actions(_ op: RejectedOp) -> some View {
        if canEdit(op) {
            Button { edit(op) } label: { Label("Bearbeiten", systemImage: "pencil") }
        }
        if op.needsReason {
            Button { retryWithReason = EditTarget(value: op) } label: {
                Label("Mit Begründung senden", systemImage: "text.bubble")
            }
            .disabled(!store.canWrite)
        } else {
            Button { store.retryRejected(op.id) } label: { Label("Erneut senden", systemImage: "arrow.clockwise") }
                .disabled(!store.canWrite)
        }
        Button(role: .destructive) { toDismiss = op } label: { Label("Verwerfen", systemImage: "trash") }
    }

    private func odometerEntry(_ id: String) -> OdometerReading? {
        store[keyPath: \TenantStore.odometer][id]
    }

    /// Bearbeiten mit der lokalen Kopie zum Zeitpunkt der Ablehnung (sonst aktueller Stand).
    private func trip(_ op: RejectedOp) -> Trip? {
        store.rejectedObject(op.id, as: Trip.self) ?? store.trip(id: op.entityId)
    }

    private func fuel(_ op: RejectedOp) -> FuelEntry? {
        store.rejectedObject(op.id, as: FuelEntry.self) ?? store.fuelEntry(id: op.entityId)
    }

    private func odometer(_ op: RejectedOp) -> OdometerReading? {
        store.rejectedObject(op.id, as: OdometerReading.self) ?? odometerEntry(op.entityId)
    }

    private func maintenance(_ op: RejectedOp) -> Maintenance? {
        store.rejectedObject(op.id, as: Maintenance.self) ?? store.maintenance(id: op.entityId)
    }

    private func vehicle(_ op: RejectedOp) -> Vehicle? {
        store.rejectedObject(op.id, as: Vehicle.self) ?? store.vehicle(id: op.entityId)
    }

    private func place(_ op: RejectedOp) -> Place? {
        store.rejectedObject(op.id, as: Place.self) ?? store.place(id: op.entityId)
    }

    private func canEdit(_ op: RejectedOp) -> Bool {
        guard store.canWrite, op.action != "delete" else { return false }
        switch op.entity {
        case Trip.entityName: return trip(op).map { !$0.isLocked } ?? false
        case FuelEntry.entityName: return fuel(op) != nil
        case OdometerReading.entityName: return odometer(op) != nil
        case Maintenance.entityName: return maintenance(op) != nil
        case Vehicle.entityName: return vehicle(op) != nil
        case Place.entityName: return place(op) != nil
        default: return false
        }
    }

    private func edit(_ op: RejectedOp) {
        switch op.entity {
        case Trip.entityName: editTrip = EditTarget(value: trip(op))
        case FuelEntry.entityName: editFuel = EditTarget(value: fuel(op))
        case OdometerReading.entityName: editOdometer = EditTarget(value: odometer(op))
        case Maintenance.entityName: editMaintenance = EditTarget(value: maintenance(op))
        case Vehicle.entityName: editVehicle = EditTarget(value: vehicle(op))
        case Place.entityName: editPlace = EditTarget(value: place(op))
        default: break
        }
    }

    static func entityLabel(_ entity: String) -> String {
        switch entity {
        case Trip.entityName: "Fahrt"
        case FuelEntry.entityName: "Tankvorgang"
        case OdometerReading.entityName: "Kilometerstand"
        case Maintenance.entityName: "Wartung"
        case MaintenanceItem.entityName: "Checklistenpunkt"
        case MaintenanceMaterial.entityName: "Material"
        case MaterialArticle.entityName: "Materialstamm"
        case Vehicle.entityName: "Fahrzeug"
        case Place.entityName: "Ort"
        case Customer.entityName: "Kunde"
        case PurposeRule.entityName: "Regel"
        case TaxParam.entityName: "Steuerparameter"
        case Attachment.entityName: "Beleg"
        default: entity
        }
    }

    static func icon(_ entity: String) -> String {
        switch entity {
        case Trip.entityName: "car"
        case FuelEntry.entityName: "fuelpump"
        case OdometerReading.entityName: "gauge.with.dots.needle.67percent"
        case Maintenance.entityName, MaintenanceItem.entityName, MaintenanceMaterial.entityName:
            "wrench.and.screwdriver"
        case Place.entityName: "mappin.and.ellipse"
        case Customer.entityName: "person.2"
        case Attachment.entityName: "doc.viewfinder"
        default: "exclamationmark.triangle"
        }
    }
}

/// Hinweise zum Datenbestand oben in der Fahrzeugliste: Ladeproblem und abgelehnte Änderungen.
struct StoreIssueSection: View {
    @Environment(TenantStore.self) private var store
    @State private var showRejected = false

    var body: some View {
        let rejected = store.rejectedOps.count
        if store.storeLoadIssue != nil || rejected > 0 {
            Section {
                if let issue = store.storeLoadIssue {
                    Label {
                        Text(issue).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                    }
                    .foregroundStyle(Color.warningText)
                }
                if rejected > 0 {
                    Button { showRejected = true } label: {
                        Label(rejected == 1 ? "1 Änderung vom Server abgelehnt"
                              : "\(rejected) Änderungen vom Server abgelehnt",
                              systemImage: "exclamationmark.icloud.fill")
                            .foregroundStyle(Color.dangerText)
                    }
                    .accessibilityHint("Abgelehnte Änderungen ansehen und korrigieren")
                }
            }
            .sheet(isPresented: $showRejected) {
                ModalNavigation { RejectedOpsView() }
            }
        }
    }
}
