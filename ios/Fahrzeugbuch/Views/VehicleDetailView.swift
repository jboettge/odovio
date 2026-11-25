import SwiftUI

struct VehicleDetailView: View {
    @Environment(TenantStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    let vehicle: Vehicle

    /// Vier Bereiche; Kilometerstände sind über die Übersicht erreichbar.
    enum Pane: String, CaseIterable, Identifiable {
        case overview = "Übersicht"
        case trips = "Fahrten"
        case fuel = "Tanken"
        case maintenance = "Wartung"
        var id: Self { self }

        var systemImage: String {
            switch self {
            case .overview: "gauge.with.dots.needle.67percent"
            case .trips: "car"
            case .fuel: "fuelpump"
            case .maintenance: "wrench.and.screwdriver"
            }
        }
    }

    enum Export: String, Identifiable {
        case logbook, vehicle
        var id: String { rawValue }
    }

    @State private var pane: Pane
    @State private var export: Export?

    init(vehicle: Vehicle, pane: Pane = .overview) {
        self.vehicle = vehicle
        _pane = State(initialValue: pane)
    }

    private var current: Vehicle { store.vehicle(id: vehicle.id) ?? vehicle }

    var body: some View {
        VStack(spacing: 0) {
            panePicker
                .padding(.horizontal)
                .padding(.bottom, 8)

            switch pane {
            case .overview: OverviewView(vehicle: current)
            case .trips: TripsListView(vehicle: current)
            case .fuel: FuelListView(vehicle: current)
            case .maintenance: MaintenanceListView(vehicle: current)
            }
        }
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if pane == .trips {
                        exportButton(.logbook)
                        exportButton(.vehicle)
                    } else {
                        exportButton(.vehicle)
                        exportButton(.logbook)
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel(pane == .trips ? "Fahrtenbuch exportieren" : "Fahrzeug-PDF exportieren")
            }
        }
        .sheet(item: $export) { e in
            switch e {
            case .vehicle: ReportView(vehicle: current)
            case .logbook: ModalNavigation { TripReportsView(vehicle: current) }
            }
        }
        .onAppear { store.defaultVehicleId = vehicle.id }   // zuletzt gewählt → Start/Automatik
    }

    private func exportButton(_ e: Export) -> some View {
        Button { export = e } label: {
            switch e {
            case .logbook: Label("Fahrtenbuch (PDF/CSV)", systemImage: "car.side")
            case .vehicle: Label("Fahrzeug-PDF (Tanken, Wartung)", systemImage: "doc.richtext")
            }
        }
    }

    /// Segmente; bei sehr grosser Schrift als Menü (Segmente skalieren nicht mit Dynamic Type).
    @ViewBuilder
    private var panePicker: some View {
        if typeSize.isAccessibilitySize {
            Picker(selection: $pane) {
                ForEach(Pane.allCases) { p in
                    Label(p.rawValue, systemImage: p.systemImage).tag(p)
                }
            } label: {
                Text("Bereich")
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Picker("Bereich", selection: $pane) {
                ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }
}
