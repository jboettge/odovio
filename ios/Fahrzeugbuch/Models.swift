import Foundation

enum FuelType: String, CaseIterable, Identifiable {
    case benzin, diesel, hybrid, lpg
    var id: String { rawValue }
    var label: String {
        switch self {
        case .benzin: "Benzin"
        case .diesel: "Diesel"
        case .hybrid: "Hybrid"
        case .lpg: "LPG/CNG"
        }
    }
}

struct Vehicle: Codable, Identifiable, Hashable {
    let id: Int
    var name: String
    var make: String?
    var model: String?
    var plate: String?
    var fuelType: String
    var initialKm: Int
    var currentKm: Int

    var subtitle: String {
        [[make, model].compactMap { $0 }.joined(separator: " "), plate ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct VehicleInput: Encodable {
    var name: String
    var make: String?
    var model: String?
    var plate: String?
    var fuelType: String
    var initialKm: Int
}

struct OdometerReading: Codable, Identifiable {
    let id: Int
    var date: Date
    var km: Int
    var note: String?
}

struct OdometerInput: Encodable {
    var date: Date
    var km: Int
    var note: String?
}

struct FuelEntry: Codable, Identifiable {
    let id: Int
    var date: Date
    var km: Int
    var liters: Double
    var priceTotal: Double
    var pricePerLiter: Double
    var fullTank: Bool
    var station: String?
    var note: String?
}

struct FuelInput: Encodable {
    var date: Date
    var km: Int
    var liters: Double
    var priceTotal: Double
    var fullTank: Bool
    var station: String?
    var note: String?
}

struct MaintenanceItem: Codable, Identifiable, Hashable {
    let id: Int
    var label: String
    var done: Bool
    var position: Int
}

struct Maintenance: Codable, Identifiable {
    let id: Int
    var date: Date
    var km: Int?
    var title: String
    var cost: Double?
    var note: String?
    var nextDueKm: Int?
    var nextDueDate: Date?
    var items: [MaintenanceItem]

    var doneCount: Int { items.filter(\.done).count }
}

struct MaintenanceItemInput: Encodable {
    var label: String
    var done: Bool
}

struct MaintenanceInput: Encodable {
    var date: Date
    var km: Int?
    var title: String
    var cost: Double?
    var note: String?
    var nextDueKm: Int?
    var nextDueDate: Date?
    var items: [MaintenanceItemInput]
}

struct ItemPatch: Encodable {
    var done: Bool
}

struct ChecklistTemplate: Decodable, Identifiable {
    var title: String
    var items: [String]
    var id: String { title }
}

struct ConsumptionPoint: Decodable, Identifiable {
    var date: Date
    var km: Int
    var distance: Int
    var liters: Double
    var cost: Double
    var consumption: Double
    var costPerKm: Double
    var id: Int { km }
}

struct DueItem: Decodable, Identifiable {
    var maintenanceId: Int
    var title: String
    var nextDueKm: Int?
    var nextDueDate: Date?
    var overdue: Bool
    var id: Int { maintenanceId }

    var dueText: String {
        var parts: [String] = []
        if let km = nextDueKm { parts.append("bei \(Fmt.km(km))") }
        if let d = nextDueDate { parts.append("bis \(Fmt.day(d))") }
        return (overdue ? "Überfällig – " : "Fällig ") + parts.joined(separator: " oder ")
    }
}

struct Stats: Decodable {
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
