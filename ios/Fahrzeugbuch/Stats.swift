import Foundation

/// Lokale Auswertung (offline verfügbar). Gleiche Logik wie server/app/stats.py.
struct ConsumptionPoint: Identifiable {
    var date: Date
    var km: Int
    var distance: Int
    var liters: Double
    var cost: Double
    var consumption: Double   // l/100 km
    var costPerKm: Double
    var id: Int { km }
}

struct DueItem: Identifiable {
    var maintenanceId: String
    var title: String
    var nextDueKm: Int?
    var nextDueDate: Date?
    var overdue: Bool
    var dueSoon = false          // innerhalb 30 Tagen bzw. 1'000 km
    var id: String { maintenanceId }

    var dueText: String {
        var parts: [String] = []
        if let km = nextDueKm { parts.append("bei \(Fmt.km(km))") }
        if let d = nextDueDate { parts.append("bis \(Fmt.day(d))") }
        return (overdue ? "Überfällig – " : "Fällig ") + parts.joined(separator: " oder ")
    }
}

struct VehicleStats {
    var currentKm: Int
    var drivenKm: Int
    var avgConsumption: Double?
    var avgLitersPerKm: Double?
    var avgCostPerKm: Double?
    var totalLiters: Double
    var totalFuelCost: Double
    var totalMaintenanceCost: Double
    var points: [ConsumptionPoint]
    var due: [DueItem]
}

enum StatsCalculator {
    /// Voll-zu-voll: Liter seit der letzten Volltankung (inkl. Teilbetankungen) / km dazwischen.
    /// Erneute Volltankung beim gleichen km (nachgetankt): Liter zählen zur vorigen Etappe (wie Server, Review S7).
    static func consumptionPoints(_ entries: [FuelEntry]) -> [ConsumptionPoint] {
        let sorted = entries.sorted { ($0.km, $0.date, $0.id) < ($1.km, $1.date, $1.id) }
        var points: [ConsumptionPoint] = []
        var prevFull: FuelEntry?
        var accL = 0.0, accC = 0.0
        for e in sorted {
            guard let prev = prevFull else {
                if e.fullTank { prevFull = e }
                continue
            }
            accL += e.liters
            accC += e.priceTotal
            guard e.fullTank else { continue }
            let dist = e.km - prev.km
            if dist > 0 {
                points.append(ConsumptionPoint(
                    date: e.date, km: e.km, distance: dist, liters: accL, cost: accC,
                    consumption: accL / Double(dist) * 100, costPerKm: accC / Double(dist)))
            } else if let last = points.last, last.km == e.km {
                let liters = last.liters + accL
                let cost = last.cost + accC
                points[points.count - 1] = ConsumptionPoint(
                    date: last.date, km: last.km, distance: last.distance, liters: liters, cost: cost,
                    consumption: liters / Double(last.distance) * 100, costPerKm: cost / Double(last.distance))
            }
            accL = 0
            accC = 0
            prevFull = e
        }
        return points
    }

    /// Höchster km-Stand inkl. km-Beginn/-Ende der nicht stornierten Fahrten (wie Server, Review S18).
    static func currentKm(vehicle: Vehicle, odometer: [OdometerReading], fuel: [FuelEntry],
                          maintenance: [Maintenance], trips: [Trip] = []) -> Int {
        let tripKms: [Int] = trips.filter { !$0.deleted }.flatMap { t in [t.kmStart, t.kmEnd].compactMap { $0 } }
        let kms: [Int] = [vehicle.initialKm] + odometer.map(\.km) + fuel.map(\.km) + maintenance.compactMap(\.km)
        return (kms + tripKms).max() ?? 0
    }

    /// Kosten einer Wartung für die Statistik: Rechnungsbetrag, sonst Materialsumme.
    static func maintenanceCost(_ m: Maintenance, materialTotal: Double) -> Double {
        m.cost ?? materialTotal
    }

    static func stats(vehicle: Vehicle, odometer: [OdometerReading], fuel: [FuelEntry],
                      maintenance: [Maintenance], materials: [MaintenanceMaterial], trips: [Trip] = [],
                      today: Date = Date()) -> VehicleStats {
        let current = currentKm(vehicle: vehicle, odometer: odometer, fuel: fuel, maintenance: maintenance,
                                trips: trips)
        let points = consumptionPoints(fuel)
        let dist = Double(points.reduce(0) { $0 + $1.distance })
        let liters = points.reduce(0) { $0 + $1.liters }
        let cost = points.reduce(0) { $0 + $1.cost }

        var latest: [String: Maintenance] = [:]
        for m in maintenance.sorted(by: { ($0.date, $0.id) < ($1.date, $1.id) }) {
            latest[m.title.trimmed.lowercased()] = m
        }
        let materialsByMaintenance = Dictionary(grouping: materials, by: \.maintenanceId)
        let maintenanceTotal = maintenance.reduce(0.0) { sum, m in
            sum + Self.maintenanceCost(m, materialTotal: MaintenanceMaterial.total(materialsByMaintenance[m.id] ?? []))
        }

        let startOfToday = Calendar.current.startOfDay(for: today)
        let due = latest.values.compactMap { m -> DueItem? in
            guard m.nextDueKm != nil || m.nextDueDate != nil else { return nil }
            let overdue = (m.nextDueKm.map { current >= $0 } ?? false)
                || (m.nextDueDate.map { startOfToday >= Calendar.current.startOfDay(for: $0) } ?? false)
            let soonDate = Calendar.current.date(byAdding: .day, value: 30, to: startOfToday) ?? startOfToday
            let soon = !overdue && ((m.nextDueKm.map { current >= $0 - 1000 } ?? false)
                                    || (m.nextDueDate.map { $0 <= soonDate } ?? false))
            return DueItem(maintenanceId: m.id, title: m.title, nextDueKm: m.nextDueKm,
                           nextDueDate: m.nextDueDate, overdue: overdue, dueSoon: soon)
        }
        .sorted { a, b in
            if a.overdue != b.overdue { return a.overdue }
            return (a.nextDueDate ?? .distantFuture) < (b.nextDueDate ?? .distantFuture)
        }

        return VehicleStats(
            currentKm: current,
            drivenKm: current - vehicle.initialKm,
            avgConsumption: dist > 0 ? liters / dist * 100 : nil,
            avgLitersPerKm: dist > 0 ? liters / dist : nil,
            avgCostPerKm: dist > 0 ? cost / dist : nil,
            totalLiters: fuel.reduce(0) { $0 + $1.liters },
            totalFuelCost: fuel.reduce(0) { $0 + $1.priceTotal },
            totalMaintenanceCost: maintenanceTotal,
            points: points,
            due: due
        )
    }
}
