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

/// Gemeinsame Eigenschaften aller synchronisierten Objekte.
/// `id` erzeugt die App (UUID) → Erfassen offline möglich.
protocol SyncEntity: Codable, Identifiable, Hashable where ID == String {
    static var entityName: String { get }
    var id: String { get }
    var version: Int { get set }
    var deleted: Bool { get set }
}

extension SyncEntity {
    /// Nutzdaten für den Server (snake_case, ohne id/version/deleted).
    func payload() throws -> Data {
        let data = try APIClient.encoder.encode(self)
        var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        for key in ["id", "version", "deleted"] { dict.removeValue(forKey: key) }
        return try JSONSerialization.data(withJSONObject: dict)
    }
}

struct Vehicle: SyncEntity {
    static let entityName = "vehicle"
    var id = UUID().uuidString.lowercased()
    var version = 0
    var deleted = false
    var name: String
    var make: String?
    var model: String?
    var plate: String?
    var fuelType: String = FuelType.benzin.rawValue
    var initialKm: Int = 0

    var subtitle: String {
        [[make, model].compactMap { $0 }.joined(separator: " "), plate ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct OdometerReading: SyncEntity {
    static let entityName = "odometer"
    var id = UUID().uuidString.lowercased()
    var version = 0
    var deleted = false
    var vehicleId: String
    var date: Date
    var km: Int
    var note: String?
}

struct FuelEntry: SyncEntity {
    static let entityName = "fuel"
    var id = UUID().uuidString.lowercased()
    var version = 0
    var deleted = false
    var vehicleId: String
    var date: Date
    var km: Int
    var liters: Double
    var priceTotal: Double
    var fullTank: Bool = true
    var station: String?
    var note: String?

    var pricePerLiter: Double { liters > 0 ? priceTotal / liters : 0 }
}

struct Maintenance: SyncEntity {
    static let entityName = "maintenance"
    var id = UUID().uuidString.lowercased()
    var version = 0
    var deleted = false
    var vehicleId: String
    var date: Date
    var km: Int?
    var title: String
    var cost: Double?
    var note: String?
    var nextDueKm: Int?
    var nextDueDate: Date?
}

struct MaintenanceItem: SyncEntity {
    static let entityName = "maintenance_item"
    var id = UUID().uuidString.lowercased()
    var version = 0
    var deleted = false
    var maintenanceId: String
    var label: String
    var done: Bool = false
    var position: Int = 0
}

/// Verbautes Material/Ersatzteil einer Wartung.
struct MaintenanceMaterial: SyncEntity {
    static let entityName = "maintenance_material"
    /// Grenzen wie Server (schemas.MaintenanceMaterialData)
    static let maxName = 150
    static let maxPartNumber = 60
    static let maxUnit = 20
    static let maxQuantity = 100_000.0
    static let maxUnitPrice = 100_000.0

    var id = UUID().uuidString.lowercased()
    var version = 0
    var deleted = false
    var maintenanceId: String
    var name: String
    var partNumber: String?
    var quantity: Double = 1
    var unit: String = "Stk"
    var unitPrice: Double?
    var position: Int = 0
    /// Verknüpfter Stammartikel (optional). Name/Preis usw. bleiben eine Kopie zum Erfassungszeitpunkt.
    var articleId: String?

    /// Menge × Einzelpreis; `nil` ohne Preis
    var lineTotal: Double? { unitPrice.map { $0 * quantity } }

    /// Materialsumme: nur nicht stornierte Positionen mit Preis.
    static func total(_ list: [MaintenanceMaterial]) -> Double {
        list.reduce(0.0) { sum, m in m.deleted ? sum : sum + (m.lineTotal ?? 0) }
    }
}

/// Artikel im Materialstamm (mandantenweit) – Vorlage für Materialpositionen einer Wartung.
struct MaterialArticle: SyncEntity {
    static let entityName = "material_article"
    /// Grenzen wie Server
    static let maxName = 150
    static let maxPartNumber = 60
    static let maxUnit = 20
    static let maxUnitPrice = 100_000.0
    static let maxCategory = 50
    static let maxNote = 500
    static let defaultCategories = ["Öl", "Filter", "Reifen", "Bremsen", "Flüssigkeiten", "Elektrik", "Sonstiges"]
    static let commonUnits = ["Stk", "l", "kg", "m", "Set", "Paar"]
    static let uncategorized = "Ohne Kategorie"

    var id = UUID().uuidString.lowercased()
    var version = 0
    var deleted = false
    var name: String
    var partNumber: String?
    var unit: String = "Stk"
    var unitPrice: Double?
    var category: String?
    /// `nil` = für alle Fahrzeuge
    var vehicleId: String?
    var note: String?

    var categoryTitle: String { category?.nilIfEmpty ?? Self.uncategorized }

    /// Suche in Name, Art.-Nr. (auch ohne Leerzeichen) und Kategorie; Gross/Klein und Akzente egal.
    func matches(_ query: String) -> Bool {
        let q = query.trimmed
        if q.isEmpty { return true }
        if name.localizedStandardContains(q) { return true }
        if let c = category, c.localizedStandardContains(q) { return true }
        if let p = partNumber {
            if p.localizedStandardContains(q) { return true }
            let compactQuery = q.replacingOccurrences(of: " ", with: "")
            let compactPart = p.replacingOccurrences(of: " ", with: "")
            if !compactQuery.isEmpty && compactPart.localizedStandardContains(compactQuery) { return true }
        }
        return false
    }

    /// Sortierung: Kategorie (ohne Kategorie zuletzt), dann Name.
    static func catalogOrder(_ a: MaterialArticle, _ b: MaterialArticle) -> Bool {
        let ca: String? = a.category?.nilIfEmpty
        let cb: String? = b.category?.nilIfEmpty
        switch (ca, cb) {
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case let (.some(first), .some(second)):
            let r = first.localizedStandardCompare(second)
            if r != .orderedSame { return r == .orderedAscending }
        case (.none, .none):
            break
        }
        let n = a.name.localizedStandardCompare(b.name)
        if n != .orderedSame { return n == .orderedAscending }
        return a.id < b.id
    }

    /// Gruppiert eine (sortierte) Liste nach Kategorie; Reihenfolge des ersten Auftretens bleibt erhalten.
    static func grouped(_ list: [MaterialArticle]) -> [ArticleGroup] {
        var groups: [ArticleGroup] = []
        var index: [String: Int] = [:]
        for a in list {
            let title = a.categoryTitle
            if let i = index[title] {
                groups[i].articles.append(a)
            } else {
                index[title] = groups.count
                groups.append(ArticleGroup(title: title, articles: [a]))
            }
        }
        return groups
    }

    /// Preise gleich (auf Rappen genau); beide `nil` gilt als gleich.
    static func samePrice(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (.none, .none): return true
        case let (.some(x), .some(y)): return abs(x - y) < 0.005
        default: return false
        }
    }
}

/// Artikel einer Kategorie (Abschnitt in Listen).
struct ArticleGroup: Identifiable {
    var title: String
    var articles: [MaterialArticle]
    var id: String { title }
}

/// Verwendung eines Stammartikels in Materialpositionen.
struct ArticleUsage: Hashable {
    var count = 0
    var lastUsed: Date?
}

// MARK: Server-Antworten

struct TenantInfo: Codable, Hashable, Identifiable {
    var slug: String
    var role: String
    var id: String { slug }
    var canWrite: Bool { role == "write" }
}

struct MeResponse: Decodable {
    var sub: String
    var name: String?
    var tenants: [TenantInfo]
}

struct ChangesResponse: Decodable {
    var cursor: Int
    var vehicles: [Vehicle]
    var odometer: [OdometerReading]
    var fuel: [FuelEntry]
    var maintenance: [Maintenance]
    var maintenanceItems: [MaintenanceItem]
    var maintenanceMaterials: [MaintenanceMaterial]
    /// Optional, damit ältere Server ohne Materialstamm weiter funktionieren
    var materialArticles: [MaterialArticle]?
}

struct OpResult: Decodable {
    var opId: String
    var status: String
    var entity: String
    var id: String
    var version: Int?
    var error: String?
}

struct SyncResponse: Decodable {
    var results: [OpResult]
    var cursor: Int
}

struct ChecklistTemplate: Codable, Identifiable {
    var title: String
    var items: [String]
    var id: String { title }
}

struct AuditResult: Decodable {
    var ok: Bool
    var count: Int
    var headHash: String
    var brokenAt: Int?
    var reason: String?
}

struct RevisionEntry: Decodable, Identifiable {
    var seq: Int
    var entity: String
    var entityId: String
    var version: Int
    var action: String
    var data: [String: JSONValue]
    var actorName: String?
    var recordedAt: String
    var clientTs: String?
    var conflict: Bool
    var hash: String
    var id: Int { seq }

    var actionLabel: String {
        switch action {
        case "create": "Erfasst"
        case "update": "Geändert"
        case "delete": "Storniert"
        default: action
        }
    }
}

/// Minimaler JSON-Wert für die Anzeige von Revisionsdaten.
enum JSONValue: Decodable, CustomStringConvertible {
    case string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { self = .null }
    }

    var description: String {
        switch self {
        case .string(let s): s
        case .number(let n): n == n.rounded() && abs(n) < 1e12 ? String(Int(n)) : String(n)
        case .bool(let b): b ? "ja" : "nein"
        case .null: "–"
        }
    }
}

// MARK: Outbox

/// Ausstehende Änderung (wird bei nächster Verbindung an /sync gesendet).
struct PendingOp: Codable, Identifiable {
    var opId = UUID().uuidString.lowercased()
    var entity: String
    var entityId: String
    var action: String          // upsert | delete
    var baseVersion: Int?
    var data: Data?
    var clientTs: String
    var id: String { opId }
}
