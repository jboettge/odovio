import SwiftUI

struct VehicleDetailView: View {
    let vehicle: Vehicle

    enum Pane: String, CaseIterable, Identifiable {
        case overview = "Übersicht"
        case fuel = "Tanken"
        case maintenance = "Wartung"
        case odometer = "km-Stand"
        var id: Self { self }
    }

    @State private var pane: Pane = .overview

    var body: some View {
        VStack(spacing: 0) {
            Picker("Bereich", selection: $pane) {
                ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            switch pane {
            case .overview: OverviewView(vehicle: vehicle)
            case .fuel: FuelListView(vehicle: vehicle)
            case .maintenance: MaintenanceListView(vehicle: vehicle)
            case .odometer: OdometerListView(vehicle: vehicle)
            }
        }
        .navigationTitle(vehicle.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
