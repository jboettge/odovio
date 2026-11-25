import Charts
import SwiftUI

struct OverviewView: View {
    @Environment(TenantStore.self) private var store
    let vehicle: Vehicle
    @State private var quick: QuickEntry?

    var body: some View {
        let s = store.stats(for: store.vehicle(id: vehicle.id) ?? vehicle)
        let reviewCount = store.reviewTrips(for: vehicle.id).count
        let gaps = store.gaps(for: vehicle.id, month: nil)
        List {
            if store.canWrite {
                Section {
                    HStack(spacing: 10) {
                        quickButton("Tanken", "fuelpump.fill", .green) { quick = .fuel(vehicle) }
                        quickButton("km-Stand", "gauge.with.dots.needle.67percent", .blue) { quick = .odometer(vehicle) }
                        quickButton("Wartung", "wrench.and.screwdriver.fill", .orange) { quick = .maintenance(vehicle) }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            if reviewCount > 0 || !gaps.isEmpty {
                Section("Fahrtenbuch") {
                    if reviewCount > 0 {
                        NavigationLink {
                            TripReviewView(vehicle: vehicle)
                        } label: {
                            Label(TripOverviewText.review(reviewCount), systemImage: "checklist")
                                .foregroundStyle(.orange)
                        }
                    }
                    if !gaps.isEmpty {
                        NavigationLink {
                            GapListView(vehicle: vehicle)
                        } label: {
                            Label(TripOverviewText.gaps(gaps), systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }

            Section("Kilometer") {
                LabeledContent("Aktueller Stand", value: Fmt.km(s.currentKm))
                LabeledContent("Seit Erfassung", value: Fmt.km(s.drivenKm))
            }

            Section {
                LabeledContent("Ø pro 100 km", value: s.avgConsumption.map { "\(Fmt.num($0)) l" } ?? "–")
                LabeledContent("Ø pro km", value: s.avgLitersPerKm.map { "\(Fmt.num($0, 3)) l" } ?? "–")
                LabeledContent("Kosten pro km", value: s.avgCostPerKm.map { "CHF \(Fmt.num($0, 3))" } ?? "–")
                if s.points.count >= 2 {
                    VStack(alignment: .leading, spacing: 2) {
                        consumptionChart(s.points, average: s.avgConsumption)
                        if let avg = s.avgConsumption {
                            Text("- - -  Durchschnitt \(Fmt.num(avg, 2)) l/100 km")
                                .font(.caption2).foregroundStyle(.secondary)
                                .padding(.bottom, 6)
                        }
                    }
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
        .sheet(item: $quick) { $0.form }
    }

    private func quickButton(_ title: String, _ icon: String, _ color: Color,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) erfassen")
    }

    private func consumptionChart(_ points: [ConsumptionPoint], average: Double?) -> some View {
        Chart {
            ForEach(points) { p in
                LineMark(x: .value("Datum", p.date), y: .value("l/100 km", p.consumption))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Datum", p.date), y: .value("l/100 km", p.consumption))
            }
            if let average {
                RuleMark(y: .value("Durchschnitt", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated), centered: false)
            }
        }
        .chartYAxisLabel("l/100 km")
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 180)
        .padding(.vertical, 8)
        .accessibilityLabel("Verbrauchsverlauf, Durchschnitt \(average.map { Fmt.num($0, 1) } ?? "–") Liter pro 100 km")
    }
}

enum TripOverviewText {
    static func review(_ n: Int) -> String {
        n == 1 ? "1 Fahrt bestätigen" : "\(n) Fahrten bestätigen"
    }

    static func gaps(_ gaps: [TripGap]) -> String {
        let km = gaps.reduce(0) { $0 + abs($1.km) }
        return gaps.count == 1 ? "Lücke von \(Fmt.km(km)) in der km-Kette" : "\(gaps.count) Lücken · \(Fmt.km(km))"
    }
}
