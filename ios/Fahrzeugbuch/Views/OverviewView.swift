import Charts
import SwiftUI

struct OverviewView: View {
    @Environment(TenantStore.self) private var store
    let vehicle: Vehicle

    var body: some View {
        let s = store.stats(for: store.vehicle(id: vehicle.id) ?? vehicle)
        List {
            Section("Kilometer") {
                LabeledContent("Aktueller Stand", value: Fmt.km(s.currentKm))
                LabeledContent("Seit Erfassung", value: Fmt.km(s.drivenKm))
            }

            Section {
                LabeledContent("Ø pro 100 km", value: s.avgConsumption.map { "\(Fmt.num($0)) l" } ?? "–")
                LabeledContent("Ø pro km", value: s.avgLitersPerKm.map { "\(Fmt.num($0, 3)) l" } ?? "–")
                LabeledContent("Kosten pro km", value: s.avgCostPerKm.map { "CHF \(Fmt.num($0, 3))" } ?? "–")
                if s.points.count >= 2 {
                    consumptionChart(s.points)
                }
            } header: {
                Text("Verbrauch")
            } footer: {
                if s.avgConsumption == nil {
                    Text("Der Verbrauch wird ab zwei Volltankungen berechnet (Voll-zu-voll).")
                }
            }

            if !s.due.isEmpty {
                Section("Wartung") {
                    ForEach(s.due) { d in
                        Label {
                            VStack(alignment: .leading) {
                                Text(d.title)
                                Text(d.dueText).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: d.overdue ? "exclamationmark.triangle.fill" : "clock")
                                .foregroundStyle(d.overdue ? .red : .orange)
                        }
                    }
                }
            }

            Section("Kosten") {
                LabeledContent("Treibstoff", value: Fmt.chf(s.totalFuelCost))
                LabeledContent("Wartung", value: Fmt.chf(s.totalMaintenanceCost))
                LabeledContent("Getankt", value: "\(Fmt.num(s.totalLiters, 1)) l")
            }
        }
        .refreshable { await store.sync() }
    }

    private func consumptionChart(_ points: [ConsumptionPoint]) -> some View {
        Chart(points) { p in
            LineMark(x: .value("Datum", p.date), y: .value("l/100 km", p.consumption))
                .interpolationMethod(.monotone)
            PointMark(x: .value("Datum", p.date), y: .value("l/100 km", p.consumption))
        }
        .chartYAxisLabel("l/100 km")
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 180)
        .padding(.vertical, 8)
    }
}
