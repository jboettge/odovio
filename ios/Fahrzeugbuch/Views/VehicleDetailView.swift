import SwiftUI

struct VehicleDetailView: View {
    @Environment(TenantStore.self) private var store
    let vehicle: Vehicle

    enum Pane: String, CaseIterable, Identifiable {
        case overview = "Übersicht"
        case fuel = "Tanken"
        case maintenance = "Wartung"
        case odometer = "km-Stand"
        var id: Self { self }
    }

    @State private var pane: Pane
    @State private var showReport = false

    init(vehicle: Vehicle, pane: Pane = .overview) {
        self.vehicle = vehicle
        _pane = State(initialValue: pane)
    }

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
        .navigationTitle(store.vehicle(id: vehicle.id)?.name ?? vehicle.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showReport = true } label: { Image(systemName: "doc.richtext") }
                    .accessibilityLabel("PDF-Export")
            }
        }
        .sheet(isPresented: $showReport) {
            ReportView(vehicle: vehicle)
        }
    }
}
