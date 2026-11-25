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
    /// Erfasst/zuletzt geändert von (Anzeigename, nur vom Server; nie gesendet)
    var createdBy: String? { get }
    var updatedBy: String? { get }
    /// Nutzdaten für `/sync` (Standard: alle Felder ausser id/version/deleted; `Place` überschreibt)
    func payload() throws -> Data
}

extension SyncEntity {
    /// Felder, die nur der Server setzt (nie in `/sync` senden)
    static var serverOnlyKeys: [String] { ["created_by", "updated_by"] }

    /// Nutzdaten für den Server (snake_case, ohne id/version/deleted).
    func payload() throws -> Data {
        try payload(omitting: [])
    }

    /// Wie `payload()`, lässt zusätzlich die genannten (snake_case-)Felder weg.
    func payload(omitting extra: [String]) throws -> Data {
        let data = try APIClient.encoder.encode(self)
        var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        for key in ["id", "version", "deleted"] + Self.serverOnlyKeys + extra { dict.removeValue(forKey: key) }
        return try JSONSerialization.data(withJSONObject: dict)
    }
}

struct Vehicle: SyncEntity {
    static let entityName = "vehicle"
    var id = UUID().uuidString.lowercased()
    var version = 0
    var deleted = false
    /// Anzeigename (setzt nur der Server; wird nie gesendet)
    var createdBy: String?
    var updatedBy: String?
    var name: String
    var make: String?
    var model: String?
    var plate: String?
    var fuelType: String = FuelType.benzin.rawValue
    var initialKm: Int = 0
    /// Kaufpreis exkl. MWST (Basis Privatanteil pauschal)
    var purchasePrice: Double?
    /// "private" | "business"; `nil` = privat
    var ownership: String?
    /// "flat" | "effective"; `nil` = pauschal
    var privateUseMethod: String?
    /// Fixkosten pro Jahr (Versicherung, Steuer, Abschreibung, Leasing …)
    var annualFixedCosts: Double?

    var isBusiness: Bool { ownership == "business" }

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
    /// Anzeigename (setzt nur der Server; wird nie gesendet)
    var createdBy: String?
    var updatedBy: String?
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
    /// Anzeigename (setzt nur der Server; wird nie gesendet)
    var createdBy: String?
    var updatedBy: String?
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

/// Beleg/Foto (Tankquittung, Zapfsäule, Tacho). Metadaten werden synchronisiert, das JPEG danach
/// separat hochgeladen (`PUT …/attachments/{id}/blob`). sha256/mime/size sind danach unveränderlich.
struct Attachment: SyncEntity {
    static let entityName = "attachment"
    /// Grenze wie Server (8 MiB)
    static let maxSize = 8 * 1024 * 1024
    static let kinds = ["receipt", "pump", "odometer", "other"]

    var id = UUID().uuidString.lowercased()
    var version = 0
    var deleted = false
    /// Anzeigename (setzt nur der Server; wird nie gesendet)
    var createdBy: String?
    var updatedBy: String?
    var fuelId: String?
    var maintenanceId: String?
    /// Pflicht für Tacho-Fotos ohne Tankung/Wartung; sonst passend zum verknüpften Eintrag
    var vehicleId: String?
    /// "receipt" | "pump" | "odometer" | "other"
    var kind: String
    /// SHA-256 des JPEG (64 Hex-Zeichen, klein)
    var sha256: String
    var mime: String = "image/jpeg"
    var size: Int
    /// ISO-8601 mit Offset
    var takenAt: String?
    var note: String?

    var kindLabel: String {
        switch kind {
        case "receipt": "Quittung"
        case "pump": "Zapfsäule"
        case "odometer": "Tacho"
        default: "Beleg"
        }
    }

    var takenDate: Date? { takenAt.flatMap { Trip.parseISO($0) } }
}

struct Maintenance: SyncEntity {
    static let entityName = "maintenance"
    var id = UUID().uuidString.lowercased()
    var version = 0
    var deleted = false
    /// Anzeigename (setzt nur der Server; wird nie gesendet)
    var createdBy: String?
    var updatedBy: String?
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
    /// Anzeigename (setzt nur der Server; wird nie gesendet)
    var createdBy: String?
    var updatedBy: String?
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
    /// Anzeigename (setzt nur der Server; wird nie gesendet)
    var createdBy: String?
    var updatedBy: String?
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
    /// Anzeigename (setzt nur der Server; wird nie gesendet)
    var createdBy: String?
    var updatedBy: String?
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
    /// Verwalten (Rolle "admin") – impliziert Schreibrecht. Verwaltung selbst nur im Webfrontend.
    var isAdmin: Bool { role == "admin" }
    var canWrite: Bool { role == "write" || role == "admin" }
    var isLocal: Bool { slug == LocalIdentity.slug && role == "write" }
    var roleLabel: String { Member.roleLabel(role) }
}

struct MeResponse: Decodable {
    var sub: String
    var name: String?
    /// Anzeigename (z. B. „Anna Muster“), neuere Server
    var displayName: String?
    var tenants: [TenantInfo]
}

struct ChangesResponse: Decodable {
    var cursor: Int
    /// Paging: weitere Seiten ab `cursor` vorhanden (ältere Server: fehlt → false)
    var hasMore: Bool = false
    var vehicles: [Vehicle] = []
    var odometer: [OdometerReading] = []
    var fuel: [FuelEntry] = []
    var maintenance: [Maintenance] = []
    var maintenanceItems: [MaintenanceItem] = []
    var maintenanceMaterials: [MaintenanceMaterial] = []
    /// Optional, damit ältere Server ohne Materialstamm weiter funktionieren
    var materialArticles: [MaterialArticle]?
    /// Fahrtenbuch – optional, damit ältere Server ohne Fahrtenbuch weiter funktionieren
    var trips: [Trip]?
    var places: [Place]?
    var customers: [Customer]?
    var purposeRules: [PurposeRule]?
    var taxParams: [TaxParam]?
    var tripPeriods: [TripPeriod]?
    /// Belege – optional, damit ältere Server ohne Belegablage weiter funktionieren
    var attachments: [Attachment]?

    enum CodingKeys: String, CodingKey {
        case cursor, hasMore, vehicles, odometer, fuel, maintenance, maintenanceItems, maintenanceMaterials
        case materialArticles, trips, places, customers, purposeRules, taxParams, tripPeriods, attachments
    }

    init(cursor: Int) { self.cursor = cursor }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try c.decode(Int.self, forKey: .cursor)
        hasMore = c.lenientBool(.hasMore) ?? false
        vehicles = try c.decodeIfPresent([Vehicle].self, forKey: .vehicles) ?? []
        odometer = try c.decodeIfPresent([OdometerReading].self, forKey: .odometer) ?? []
        fuel = try c.decodeIfPresent([FuelEntry].self, forKey: .fuel) ?? []
        maintenance = try c.decodeIfPresent([Maintenance].self, forKey: .maintenance) ?? []
        maintenanceItems = try c.decodeIfPresent([MaintenanceItem].self, forKey: .maintenanceItems) ?? []
        maintenanceMaterials = try c.decodeIfPresent([MaintenanceMaterial].self, forKey: .maintenanceMaterials) ?? []
        materialArticles = try c.decodeIfPresent([MaterialArticle].self, forKey: .materialArticles)
        trips = try c.decodeIfPresent([Trip].self, forKey: .trips)
        places = try c.decodeIfPresent([Place].self, forKey: .places)
        customers = try c.decodeIfPresent([Customer].self, forKey: .customers)
        purposeRules = try c.decodeIfPresent([PurposeRule].self, forKey: .purposeRules)
        taxParams = try c.decodeIfPresent([TaxParam].self, forKey: .taxParams)
        tripPeriods = try c.decodeIfPresent([TripPeriod].self, forKey: .tripPeriods)
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments)
    }
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
    /// Begründung (Storno gesperrter Fahrten, Änderungen in abgeschlossenen Monaten; ≤ 300 Zeichen)
    var reason: String? = nil
    var id: String { opId }
}

/// Vom Server abgelehnte Änderung. Bleibt sichtbar (Liste „Abgelehnt“), bis sie verworfen oder erneut
/// gesendet wird; `snapshot` = lokaler Stand des Objekts zum Zeitpunkt der Ablehnung (zum Bearbeiten).
struct RejectedOp: Codable, Identifiable, Hashable {
    /// op_id der abgelehnten Änderung
    var id: String
    var entity: String
    var entityId: String
    /// upsert | delete
    var action: String
    /// z. B. „Tankvorgang 24.11.“
    var label: String
    /// Grund laut Server
    var error: String
    var date: Date
    /// Lokale Kopie des Objekts (JSON wie in der Mandantendatei); `nil` bei Storno ohne lokale Kopie
    var snapshot: Data?
    var reason: String?

    /// Server verlangt eine Begründung (abgeschlossener Monat / gesperrte Fahrt)
    var needsReason: Bool { error.localizedCaseInsensitiveContains("Begründung") }
}

// MARK: - Fahrtenbuch

/// Kategorie einer Fahrt. Rohwerte wie Server (`private` ist in Swift ein Schlüsselwort → `personal`).
enum TripCategory: String, CaseIterable, Identifiable {
    case business, personal = "private", commute, field, unknown

    var id: String { rawValue }

    var label: String {
        switch self {
        case .business: "Geschäftlich"
        case .personal: "Privatfahrt"
        case .commute: "Arbeitsweg"
        case .field: "Aussendienst"
        case .unknown: "Unbekannt"
        }
    }

    var systemImage: String {
        switch self {
        case .business: "briefcase.fill"
        case .personal: "person.fill"
        case .commute: "building.2.fill"
        case .field: "map.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    /// Wählbare Kategorien (ohne „Unbekannt“)
    static let selectable: [TripCategory] = [.business, .personal, .commute, .field]

    static func of(_ raw: String?) -> TripCategory {
        guard let raw, let c = TripCategory(rawValue: raw) else { return .unknown }
        return c
    }
}

/// Fahrt (Fahrtenbuch). Zeitpunkte als ISO-8601 mit Offset (wie Server), km-Stand massgebend.
///
/// `startDate`/`endDate` werden beim Dekodieren bzw. Setzen von `startAt`/`endAt` einmal geparst
/// (Sortierungen und Listen parsen nicht je Zugriff).
struct Trip: SyncEntity {
    static let entityName = "trip"
    /// Grenzen wie Server (schemas.TripData)
    static let maxPurpose = 300
    static let maxLabel = 200
    static let maxNote = 2000
    /// Privatmodus: Server akzeptiert nur kurze Bezeichnungen (Gemeinde)
    static let maxPrivateLabel = 60

    var id: String
    var version: Int
    var deleted: Bool
    /// Anzeigename (setzt nur der Server; wird nie gesendet)
    var createdBy: String?
    var updatedBy: String?
    var vehicleId: String
    var driverSub: String?
    var driverName: String?
    var startAt: String {
        didSet { if startAt != oldValue { startDate = ISODate.parse(startAt) } }
    }
    var endAt: String? {
        didSet { if endAt != oldValue { endDate = endAt.flatMap(ISODate.parse) } }
    }
    var kmStart: Int?
    var kmEnd: Int?
    /// km-Stände aus GPS geschätzt (nicht vom Tacho abgelesen); Auto-Bestätigung und Abschluss sperren
    var kmEstimated: Bool
    var distanceGps: Double?
    var distanceRoute: Double?
    var startPlaceId: String?
    var endPlaceId: String?
    var startLabel: String?
    var endLabel: String?
    /// business | private | commute | field | unknown
    var category: String
    var purpose: String?
    var customerId: String?
    /// Kundenname zum Abschlusszeitpunkt (setzt nur der Server; wird nie gesendet)
    var customerName: String?
    /// draft | suggested | confirmed | locked (locked setzt nur der Server)
    var status: String
    /// auto | manual | gap | import
    var source: String
    var suggestionCategory: String?
    var suggestionPurpose: String?
    var suggestionCustomerId: String?
    var suggestionConfidence: Double?
    var suggestionReason: String?
    /// rule | calendar | pattern | llm
    var suggestionSource: String?
    var trackHash: String?
    var splitOf: String?
    var privateMode: Bool
    var note: String?

    /// Geparster Start (Cache von `startAt`)
    private(set) var startDate: Date?
    /// Geparstes Ende (Cache von `endAt`)
    private(set) var endDate: Date?

    enum CodingKeys: String, CodingKey {
        case id, version, deleted, vehicleId, driverSub, driverName, startAt, endAt, kmStart, kmEnd, kmEstimated
        case distanceGps, distanceRoute, startPlaceId, endPlaceId, startLabel, endLabel, category, purpose
        case customerId, customerName, status, source, suggestionCategory, suggestionPurpose, suggestionCustomerId
        case suggestionConfidence, suggestionReason, suggestionSource, trackHash, splitOf, privateMode, note
        case createdBy, updatedBy
    }

    init(id: String = UUID().uuidString.lowercased(), version: Int = 0, deleted: Bool = false,
         vehicleId: String, driverSub: String? = nil, driverName: String? = nil,
         startAt: String, endAt: String? = nil, kmStart: Int? = nil, kmEnd: Int? = nil, kmEstimated: Bool = false,
         distanceGps: Double? = nil, distanceRoute: Double? = nil,
         startPlaceId: String? = nil, endPlaceId: String? = nil, startLabel: String? = nil, endLabel: String? = nil,
         category: String = "unknown", purpose: String? = nil, customerId: String? = nil,
         customerName: String? = nil, status: String = "draft", source: String = "manual",
         suggestionCategory: String? = nil, suggestionPurpose: String? = nil, suggestionCustomerId: String? = nil,
         suggestionConfidence: Double? = nil, suggestionReason: String? = nil, suggestionSource: String? = nil,
         trackHash: String? = nil, splitOf: String? = nil, privateMode: Bool = false, note: String? = nil) {
        self.id = id
        self.version = version
        self.deleted = deleted
        self.vehicleId = vehicleId
        self.driverSub = driverSub
        self.driverName = driverName
        self.startAt = startAt
        self.endAt = endAt
        self.kmStart = kmStart
        self.kmEnd = kmEnd
        self.kmEstimated = kmEstimated
        self.distanceGps = distanceGps
        self.distanceRoute = distanceRoute
        self.startPlaceId = startPlaceId
        self.endPlaceId = endPlaceId
        self.startLabel = startLabel
        self.endLabel = endLabel
        self.category = category
        self.purpose = purpose
        self.customerId = customerId
        self.customerName = customerName
        self.status = status
        self.source = source
        self.suggestionCategory = suggestionCategory
        self.suggestionPurpose = suggestionPurpose
        self.suggestionCustomerId = suggestionCustomerId
        self.suggestionConfidence = suggestionConfidence
        self.suggestionReason = suggestionReason
        self.suggestionSource = suggestionSource
        self.trackHash = trackHash
        self.splitOf = splitOf
        self.privateMode = privateMode
        self.note = note
        self.startDate = ISODate.parse(startAt)
        self.endDate = endAt.flatMap(ISODate.parse)
    }

    /// Tolerant: fehlende Felder bzw. `null` (maskierte Privatfahrten für die Leserolle) erhalten Standardwerte.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let start = try c.decode(String.self, forKey: .startAt)
        let end = c.lenientString(.endAt)
        self.init(id: try c.decode(String.self, forKey: .id),
                  version: c.lenientInt(.version) ?? 0,
                  deleted: c.lenientBool(.deleted) ?? false,
                  vehicleId: try c.decode(String.self, forKey: .vehicleId),
                  driverSub: c.lenientString(.driverSub),
                  driverName: c.lenientString(.driverName),
                  startAt: start,
                  endAt: end,
                  kmStart: c.lenientInt(.kmStart),
                  kmEnd: c.lenientInt(.kmEnd),
                  kmEstimated: c.lenientBool(.kmEstimated) ?? false,
                  distanceGps: c.lenientDouble(.distanceGps),
                  distanceRoute: c.lenientDouble(.distanceRoute),
                  startPlaceId: c.lenientString(.startPlaceId),
                  endPlaceId: c.lenientString(.endPlaceId),
                  startLabel: c.lenientString(.startLabel),
                  endLabel: c.lenientString(.endLabel),
                  category: c.lenientString(.category) ?? TripCategory.unknown.rawValue,
                  purpose: c.lenientString(.purpose),
                  customerId: c.lenientString(.customerId),
                  customerName: c.lenientString(.customerName),
                  status: c.lenientString(.status) ?? "draft",
                  source: c.lenientString(.source) ?? "manual",
                  suggestionCategory: c.lenientString(.suggestionCategory),
                  suggestionPurpose: c.lenientString(.suggestionPurpose),
                  suggestionCustomerId: c.lenientString(.suggestionCustomerId),
                  suggestionConfidence: c.lenientDouble(.suggestionConfidence),
                  suggestionReason: c.lenientString(.suggestionReason),
                  suggestionSource: c.lenientString(.suggestionSource),
                  trackHash: c.lenientString(.trackHash),
                  splitOf: c.lenientString(.splitOf),
                  privateMode: c.lenientBool(.privateMode) ?? false,
                  note: c.lenientString(.note))
        createdBy = c.lenientString(.createdBy)
        updatedBy = c.lenientString(.updatedBy)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(version, forKey: .version)
        try c.encode(deleted, forKey: .deleted)
        try c.encode(vehicleId, forKey: .vehicleId)
        try c.encodeIfPresent(driverSub, forKey: .driverSub)
        try c.encodeIfPresent(driverName, forKey: .driverName)
        try c.encode(startAt, forKey: .startAt)
        try c.encodeIfPresent(endAt, forKey: .endAt)
        try c.encodeIfPresent(kmStart, forKey: .kmStart)
        try c.encodeIfPresent(kmEnd, forKey: .kmEnd)
        try c.encode(kmEstimated, forKey: .kmEstimated)
        try c.encodeIfPresent(distanceGps, forKey: .distanceGps)
        try c.encodeIfPresent(distanceRoute, forKey: .distanceRoute)
        try c.encodeIfPresent(startPlaceId, forKey: .startPlaceId)
        try c.encodeIfPresent(endPlaceId, forKey: .endPlaceId)
        try c.encodeIfPresent(startLabel, forKey: .startLabel)
        try c.encodeIfPresent(endLabel, forKey: .endLabel)
        try c.encode(category, forKey: .category)
        try c.encodeIfPresent(purpose, forKey: .purpose)
        try c.encodeIfPresent(customerId, forKey: .customerId)
        try c.encodeIfPresent(customerName, forKey: .customerName)
        try c.encode(status, forKey: .status)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(suggestionCategory, forKey: .suggestionCategory)
        try c.encodeIfPresent(suggestionPurpose, forKey: .suggestionPurpose)
        try c.encodeIfPresent(suggestionCustomerId, forKey: .suggestionCustomerId)
        try c.encodeIfPresent(suggestionConfidence, forKey: .suggestionConfidence)
        try c.encodeIfPresent(suggestionReason, forKey: .suggestionReason)
        try c.encodeIfPresent(suggestionSource, forKey: .suggestionSource)
        try c.encodeIfPresent(trackHash, forKey: .trackHash)
        try c.encodeIfPresent(splitOf, forKey: .splitOf)
        try c.encode(privateMode, forKey: .privateMode)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(createdBy, forKey: .createdBy)
        try c.encodeIfPresent(updatedBy, forKey: .updatedBy)
    }

    // MARK: Datenschutz

    /// Privatmodus: keine Orts-IDs, kein Zweck/Kunde, kein Track-Hash, keine Zweck-/Kundenvorschläge,
    /// Bezeichnungen höchstens kurz (Gemeinde). Der Server lehnt anderes ab.
    var privacySanitized: Trip {
        guard privateMode else { return self }
        var t = self
        t.startPlaceId = nil
        t.endPlaceId = nil
        t.purpose = nil
        t.customerId = nil
        t.customerName = nil
        t.trackHash = nil
        t.suggestionPurpose = nil
        t.suggestionCustomerId = nil
        t.startLabel = t.startLabel?.nilIfEmpty.map { String($0.prefix(Self.maxPrivateLabel)) }
        t.endLabel = t.endLabel?.nilIfEmpty.map { String($0.prefix(Self.maxPrivateLabel)) }
        return t
    }

    /// Nutzdaten für `/sync`: ohne `customer_name` (nur Server); im Privatmodus bereinigt.
    func payload() throws -> Data {
        var omit = ["customer_name"]
        if privateMode {
            omit += ["start_place_id", "end_place_id", "purpose", "customer_id", "track_hash",
                     "suggestion_purpose", "suggestion_customer_id"]
        }
        return try privacySanitized.payload(omitting: omit)
    }

    // MARK: Zeit

    /// ISO-8601 mit lokalem Offset, z. B. 2026-11-24T07:42:00+01:00
    static func isoString(_ date: Date) -> String { ISODate.string(date) }

    static func parseISO(_ value: String) -> Date? { ISODate.parse(value) }

    // MARK: Ableitungen

    var categoryValue: TripCategory { TripCategory.of(category) }
    var isLocked: Bool { status == "locked" }
    var isConfirmed: Bool { status == "confirmed" || status == "locked" }
    /// Muss noch bestätigt/klassifiziert werden (gesperrte Fahrten nie)
    var needsReview: Bool { !isLocked && (!isConfirmed || category == TripCategory.unknown.rawValue) }
    /// "YYYY-MM" des (lokalen) Startdatums wie Server (`start_at[:7]`)
    var monthKey: String { String(startAt.prefix(7)) }
    var hasSuggestion: Bool { suggestionCategory != nil }

    /// Distanz wie Server: km-Stand, sonst Route, sonst GPS
    var distanceKm: Double? {
        if let a = kmStart, let b = kmEnd { return Double(b - a) }
        return distanceRoute ?? distanceGps
    }

    static func statusLabel(_ status: String) -> String {
        switch status {
        case "draft": "Entwurf"
        case "suggested": "Vorgeschlagen"
        case "confirmed": "Bestätigt"
        case "locked": "Abgeschlossen"
        default: status
        }
    }

    static func sourceLabel(_ source: String) -> String {
        switch source {
        case "auto": "Automatisch"
        case "manual": "Manuell"
        case "gap": "Lücke"
        case "import": "Import"
        default: source
        }
    }

    static func suggestionSourceLabel(_ source: String?) -> String {
        switch source {
        case "rule": "Regel"
        case "calendar": "Kalender"
        case "pattern": "Wiederholung"
        case "llm": "KI-Vorschlag"
        default: "Vorschlag"
        }
    }
}

enum PlaceKind: String, CaseIterable, Identifiable {
    case home, work, customer, other
    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: "Wohnort"
        case .work: "Arbeitsort"
        case .customer: "Kunde"
        case .other: "Anderer Ort"
        }
    }

    var groupTitle: String {
        switch self {
        case .home: "Wohnort"
        case .work: "Arbeitsorte"
        case .customer: "Kunden"
        case .other: "Weitere Orte"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .work: "building.2.fill"
        case .customer: "person.crop.square.fill"
        case .other: "mappin.circle.fill"
        }
    }

    static func of(_ raw: String?) -> PlaceKind {
        guard let raw, let k = PlaceKind(rawValue: raw) else { return .other }
        return k
    }
}

/// Bekannter Ort (Wohnort, Büro, Kunde …). Koordinaten des Wohnorts verlassen das Gerät nie.
struct Place: SyncEntity {
    static let entityName = "place"
    static let maxName = 100
    static let radiusRange = 50...5000

    var id = UUID().uuidString.lowercased()
    var version = 0
    var deleted = false
    /// Anzeigename (setzt nur der Server; wird nie gesendet)
    var createdBy: String?
    var updatedBy: String?
    var name: String
    /// home | work | customer | other
    var kind: String = PlaceKind.other.rawValue
    var lat: Double?
    var lon: Double?
    var radiusM: Int = 150
    var customerId: String?
    var defaultCategory: String?
    /// Server-Feld `private` (Schlüsselwort in Swift)
    var isPrivate: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, version, deleted, createdBy, updatedBy, name, kind, lat, lon, radiusM, customerId, defaultCategory
        case isPrivate = "private"
    }

    var kindValue: PlaceKind { PlaceKind.of(kind) }
    var isHome: Bool { kind == PlaceKind.home.rawValue }
    var hasCoordinate: Bool { lat != nil && lon != nil }

    /// Wohnort bzw. privater Ort: Koordinaten bleiben auf dem Gerät.
    var keepsCoordinatesLocal: Bool { isHome || isPrivate }

    /// Wohnort/privater Ort: Koordinaten nie senden (Server lehnt ab, Datensparsamkeit).
    func payload() throws -> Data {
        try payload(omitting: keepsCoordinatesLocal ? ["lat", "lon"] : [])
    }
}

extension Place {
    /// Tolerant: maskierte private Orte (Leserolle) kommen ohne Koordinaten bzw. mit `null`-Feldern.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id),
                  version: c.lenientInt(.version) ?? 0,
                  deleted: c.lenientBool(.deleted) ?? false,
                  name: c.lenientString(.name) ?? "Privater Ort",
                  kind: c.lenientString(.kind) ?? PlaceKind.other.rawValue,
                  lat: c.lenientDouble(.lat),
                  lon: c.lenientDouble(.lon),
                  radiusM: c.lenientInt(.radiusM) ?? 150,
                  customerId: c.lenientString(.customerId),
                  defaultCategory: c.lenientString(.defaultCategory),
                  isPrivate: c.lenientBool(.isPrivate) ?? false)
        createdBy = c.lenientString(.createdBy)
        updatedBy = c.lenientString(.updatedBy)
    }
}

/// Kunde/Projekt (Zweck geschäftlicher Fahrten).
struct Customer: SyncEntity {
    static let entityName = "customer"
    static let maxName = 150
    static let maxRef = 50
    static let maxNote = 500

    var id = UUID().uuidString.lowercased()
    var version = 0
    var deleted = false
    /// Anzeigename (setzt nur der Server; wird nie gesendet)
    var createdBy: String?
    var updatedBy: String?
    var name: String
    var ref: String?
    var note: String?
}

/// Regel für Zweck-Vorschläge (Ort/Zeit/Wochentag → Kategorie/Zweck/Kunde).
struct PurposeRule: SyncEntity {
    static let entityName = "purpose_rule"
    static let weekdayLabels = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]

    var id = UUID().uuidString.lowercased()
    var version = 0
    var deleted = false
    /// Anzeigename (setzt nur der Server; wird nie gesendet)
    var createdBy: String?
    var updatedBy: String?
    var priority: Int = 100
    var fromPlaceId: String?
    var toPlaceId: String?
    /// ISO-Wochentage "1,2,3,4,5" (1 = Montag); `nil` = jeden Tag
    var weekdays: String?
    /// "HH:MM"
    var timeFrom: String?
    var timeTo: String?
    var vehicleId: String?
    var resultCategory: String = TripCategory.business.rawValue
    var resultPurpose: String?
    var resultCustomerId: String?
    var autoConfirm: Bool = false
    /// user | learned
    var origin: String = "user"
    var active: Bool = true

    var isLearned: Bool { origin == "learned" }

    var weekdaySet: [Int] {
        guard let weekdays else { return [] }
        return weekdays.split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { (1...7).contains($0) }
            .sorted()
    }

    static func weekdayString(_ days: [Int]) -> String? {
        let set = Array(Set(days.filter { (1...7).contains($0) })).sorted()
        if set.isEmpty { return nil }
        return set.map { String($0) }.joined(separator: ",")
    }

    /// "Mo–Fr", "Sa–So", "Mo, Mi, Fr", "täglich"
    static func weekdayText(_ days: [Int]) -> String {
        let set = Array(Set(days)).filter { (1...7).contains($0) }.sorted()
        if set.isEmpty || set.count == 7 { return "täglich" }
        var parts: [String] = []
        var i = 0
        while i < set.count {
            var j = i
            while j + 1 < set.count && set[j + 1] == set[j] + 1 { j += 1 }
            let first = weekdayLabels[set[i] - 1]
            let last = weekdayLabels[set[j] - 1]
            if j - i >= 2 {
                parts.append("\(first)–\(last)")
            } else if j > i {
                parts.append(first)
                parts.append(last)
            } else {
                parts.append(first)
            }
            i = j + 1
        }
        return parts.joined(separator: ", ")
    }
}

/// Steuer-/Spesenparameter je Jahr und Geltungsbereich (Bund, Kanton, Mandant).
struct TaxParam: SyncEntity {
    static let entityName = "tax_param"
    static let keys = ["km_rate", "commute_rate", "cap_federal", "cap_canton", "private_share_pct",
                       "min_private_month", "vat_rate"]
    static let maxValue = 1_000_000.0
    static let maxText = 300

    var id = UUID().uuidString.lowercased()
    var version = 0
    var deleted = false
    /// Anzeigename (setzt nur der Server; wird nie gesendet)
    var createdBy: String?
    var updatedBy: String?
    var year: Int
    /// federal | canton:ZH | tenant
    var scope: String = "tenant"
    var key: String
    var value: Double
    var sourceUrl: String?
    var note: String?

    static func label(_ key: String) -> String {
        switch key {
        case "km_rate": "Kilometeransatz Geschäftsfahrten"
        case "commute_rate": "Arbeitsweg Privatauto"
        case "cap_federal": "Fahrkostenabzug Obergrenze Bund"
        case "cap_canton": "Fahrkostenabzug Obergrenze Kanton"
        case "private_share_pct": "Privatanteil pauschal"
        case "min_private_month": "Privatanteil Minimum"
        case "vat_rate": "MWST-Normalsatz"
        default: key
        }
    }

    static func unit(_ key: String) -> String {
        switch key {
        case "km_rate", "commute_rate": "CHF/km"
        case "cap_federal", "cap_canton": "CHF"
        case "private_share_pct": "%/Monat"
        case "min_private_month": "CHF/Monat"
        case "vat_rate": "%"
        default: ""
        }
    }

    static func scopeLabel(_ scope: String) -> String {
        if scope == "federal" { return "Bund" }
        if scope == "tenant" { return "Mandant" }
        if scope == "default" { return "Standard (Annahme)" }
        if scope.hasPrefix("canton:") { return "Kanton \(scope.dropFirst("canton:".count))" }
        return scope
    }

    static func valueText(_ key: String, _ value: Double) -> String {
        let digits = (key == "km_rate" || key == "commute_rate") ? 2 : (value == value.rounded() ? 0 : 2)
        return "\(Fmt.num(value, digits)) \(unit(key))"
    }
}

/// Monatsabschluss (nur Server schreibt; App speichert und zeigt an).
struct TripPeriod: Codable, Identifiable, Hashable {
    var id: String
    var version: Int = 0
    var deleted: Bool = false
    var vehicleId: String
    /// "YYYY-MM"
    var month: String
    var status: String = "closed"
    var closedBy: String?
    var closedAt: String?
    var anchorSeq: Int?
    var kmStart: Int?
    var kmEnd: Int?
    var tripsCount: Int = 0
    var businessKm: Double = 0
    var privateKm: Double = 0
    var commuteKm: Double = 0
    var fieldKm: Double = 0
    var note: String?
    /// Anzahl Korrekturen (Storni/Änderungen mit Begründung) nach dem Abschluss
    var corrections: Int?

    enum CodingKeys: String, CodingKey {
        case id, version, deleted, vehicleId, month, status, closedBy, closedAt, anchorSeq, kmStart, kmEnd
        case tripsCount, businessKm, privateKm, commuteKm, fieldKm, note, corrections
    }

    var isClosed: Bool { status == "closed" && !deleted }
    var closedDate: Date? {
        guard let closedAt else { return nil }
        return Trip.parseISO(closedAt)
    }
}

extension TripPeriod {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVehicle = try c.decode(String.self, forKey: .vehicleId)
        let decodedMonth = try c.decode(String.self, forKey: .month)
        vehicleId = decodedVehicle
        month = decodedMonth
        id = c.lenientString(.id) ?? "\(decodedVehicle)|\(decodedMonth)"
        version = c.lenientInt(.version) ?? 0
        deleted = c.lenientBool(.deleted) ?? false
        status = c.lenientString(.status) ?? "closed"
        closedBy = c.lenientString(.closedBy)
        closedAt = c.lenientString(.closedAt)
        anchorSeq = c.lenientInt(.anchorSeq)
        kmStart = c.lenientInt(.kmStart)
        kmEnd = c.lenientInt(.kmEnd)
        tripsCount = c.lenientInt(.tripsCount) ?? 0
        businessKm = c.lenientDouble(.businessKm) ?? 0
        privateKm = c.lenientDouble(.privateKm) ?? 0
        commuteKm = c.lenientDouble(.commuteKm) ?? 0
        fieldKm = c.lenientDouble(.fieldKm) ?? 0
        note = c.lenientString(.note)
        corrections = c.lenientInt(.corrections)
    }
}

/// Antwort von `POST …/periods/{month}/close`: `{period, locked_trips, gaps, forced, cursor, anchor}`.
/// `gaps` ist je nach Server-Version eine Zahl oder die Liste der Lücken (→ Anzahl).
struct PeriodCloseResponse: Decodable {
    var period: TripPeriod
    var lockedTrips: Int?
    var gaps: Int?
    var forced: Bool?
    var cursor: Int?

    enum CodingKeys: String, CodingKey { case period, lockedTrips, gaps, forced, cursor }

    init(period: TripPeriod, lockedTrips: Int? = nil, gaps: Int? = nil, forced: Bool? = nil, cursor: Int? = nil) {
        self.period = period
        self.lockedTrips = lockedTrips
        self.gaps = gaps
        self.forced = forced
        self.cursor = cursor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        period = try c.decode(TripPeriod.self, forKey: .period)
        lockedTrips = c.lenientInt(.lockedTrips)
        if let n = c.lenientInt(.gaps) {
            gaps = n
        } else if let list = try? c.decodeIfPresent([TripGap].self, forKey: .gaps) {
            gaps = list.count
        } else {
            gaps = nil
        }
        forced = c.lenientBool(.forced)
        cursor = c.lenientInt(.cursor)
    }
}

/// Lücke in der km-Kette (km-Ende Fahrt n ≠ km-Beginn Fahrt n+1; negativ = Überschneidung).
struct TripGap: Identifiable, Hashable, Decodable {
    var afterTripId: String?
    var beforeTripId: String?
    var kmFrom: Int
    var kmTo: Int
    var km: Int

    init(afterTripId: String?, beforeTripId: String?, kmFrom: Int, kmTo: Int, km: Int? = nil) {
        self.afterTripId = afterTripId
        self.beforeTripId = beforeTripId
        self.kmFrom = kmFrom
        self.kmTo = kmTo
        self.km = km ?? (kmTo - kmFrom)
    }

    var id: String { "\(afterTripId ?? "-")|\(beforeTripId ?? "-")|\(kmFrom)|\(kmTo)" }
}

extension KeyedDecodingContainer {
    /// Int, auch aus 12.0 o. ä.; fehlend/ungültig → nil
    func lenientInt(_ key: Key) -> Int? {
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return v }
        if let d = try? decodeIfPresent(Double.self, forKey: key), d.isFinite { return Int(d.rounded()) }
        return nil
    }

    func lenientDouble(_ key: Key) -> Double? {
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Double(s) }
        return nil
    }

    func lenientString(_ key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        return nil
    }

    func lenientBool(_ key: Key) -> Bool? {
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i != 0 }
        return nil
    }
}

// MARK: Fahrtenbuch – Server-Antworten (tolerant)

struct TripMismatch: Decodable, Identifiable, Hashable {
    var tripId: String?
    var reason: String?
    /// Verhindert den Abschluss (ausser force + Begründung); `nil` bei älteren Servern = blockierend
    var blocking: Bool?
    var id: String { "\(tripId ?? "-")|\(reason ?? "")" }
}

struct OdometerCheck: Decodable, Hashable {
    var tripKm: Double?
    var odometerKm: Double?
    var diffKm: Double?
    var ok: Bool?
    var readings: Int?
    var note: String?

    enum CodingKeys: String, CodingKey { case tripKm, odometerKm, diffKm, ok, readings, note }

    init(tripKm: Double?, odometerKm: Double?, diffKm: Double?, ok: Bool?, readings: Int?, note: String?) {
        self.tripKm = tripKm
        self.odometerKm = odometerKm
        self.diffKm = diffKm
        self.ok = ok
        self.readings = readings
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tripKm = c.lenientDouble(.tripKm)
        odometerKm = c.lenientDouble(.odometerKm)
        diffKm = c.lenientDouble(.diffKm)
        ok = c.lenientBool(.ok)
        readings = c.lenientInt(.readings)
        note = c.lenientString(.note)
    }
}

/// Antwort von GET …/trips/check?month=
struct TripCheck: Decodable {
    var month: String?
    var trips: Int?
    var gaps: [TripGap] = []
    var mismatches: [TripMismatch] = []
    var odometerCheck: OdometerCheck?
    var unconfirmed: Int?
    var closed: Bool?

    enum CodingKeys: String, CodingKey { case month, trips, gaps, mismatches, odometerCheck, unconfirmed, closed }

    init(month: String?, trips: Int?, gaps: [TripGap], mismatches: [TripMismatch], odometerCheck: OdometerCheck?,
         unconfirmed: Int?, closed: Bool?) {
        self.month = month
        self.trips = trips
        self.gaps = gaps
        self.mismatches = mismatches
        self.odometerCheck = odometerCheck
        self.unconfirmed = unconfirmed
        self.closed = closed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        month = c.lenientString(.month)
        trips = c.lenientInt(.trips)
        gaps = (try? c.decodeIfPresent([TripGap].self, forKey: .gaps)) ?? []
        mismatches = (try? c.decodeIfPresent([TripMismatch].self, forKey: .mismatches)) ?? []
        odometerCheck = try? c.decodeIfPresent(OdometerCheck.self, forKey: .odometerCheck)
        unconfirmed = c.lenientInt(.unconfirmed)
        closed = c.lenientBool(.closed)
    }
}

struct YearReportParam: Decodable, Identifiable, Hashable {
    var key: String?
    var label: String?
    var value: Double?
    var year: Int?
    var scope: String?
    var sourceUrl: String?
    var note: String?
    var id: String { "\(key ?? "-")|\(scope ?? "-")|\(year ?? 0)" }

    enum CodingKeys: String, CodingKey { case key, label, value, year, scope, sourceUrl, note }

    init(key: String?, label: String?, value: Double?, year: Int?, scope: String?, sourceUrl: String?, note: String?) {
        self.key = key
        self.label = label
        self.value = value
        self.year = year
        self.scope = scope
        self.sourceUrl = sourceUrl
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.lenientString(.key)
        label = c.lenientString(.label)
        value = c.lenientDouble(.value)
        year = c.lenientInt(.year)
        scope = c.lenientString(.scope)
        sourceUrl = c.lenientString(.sourceUrl)
        note = c.lenientString(.note)
    }
}

struct YearReportItem: Decodable, Hashable {
    var label: String?
    var value: Double?
    var applicable: Bool?
    var formula: String?
    var reason: String?
    var params: [YearReportParam] = []

    enum CodingKeys: String, CodingKey { case label, value, applicable, formula, reason, params }

    init(label: String?, value: Double?, applicable: Bool?, formula: String?, reason: String?,
         params: [YearReportParam] = []) {
        self.label = label
        self.value = value
        self.applicable = applicable
        self.formula = formula
        self.reason = reason
        self.params = params
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = c.lenientString(.label)
        value = c.lenientDouble(.value)
        applicable = c.lenientBool(.applicable)
        formula = c.lenientString(.formula)
        reason = c.lenientString(.reason)
        params = (try? c.decodeIfPresent([YearReportParam].self, forKey: .params)) ?? []
    }
}

/// Jahresbericht (GET …/year-report?year=). Alle Felder optional, unbekannte werden ignoriert.
/// Achtung: `convertFromSnakeCase` wandelt auch Dictionary-Schlüssel (z. B. `km_rate` → `kmRate`);
/// Zugriff deshalb über `value(_:_:)` mit normalisiertem Schlüssel.
struct YearReport: Decodable {
    var year: Int?
    var canton: String?
    var tripsCount: Int?
    var unconfirmed: Int?
    var monthsUsed: Int?
    var km: [String: Double] = [:]
    var sharesPct: [String: Double] = [:]
    var costs: [String: Double] = [:]
    var items: [String: YearReportItem] = [:]
    var params: [String: YearReportParam] = [:]
    var warnings: [String] = []
    var disclaimer: String?
    /// Lokal aus den Fahrten berechnet (offline, ohne Steuerposten)
    var isLocal = false

    enum CodingKeys: String, CodingKey {
        case year, canton, tripsCount, unconfirmed, monthsUsed, km, sharesPct, costs, items, params, warnings
        case disclaimer
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        year = c.lenientInt(.year)
        canton = c.lenientString(.canton)
        tripsCount = c.lenientInt(.tripsCount)
        unconfirmed = c.lenientInt(.unconfirmed)
        monthsUsed = c.lenientInt(.monthsUsed)
        km = Self.numbers(c, .km)
        sharesPct = Self.numbers(c, .sharesPct)
        costs = Self.numbers(c, .costs)
        items = (try? c.decodeIfPresent([String: YearReportItem].self, forKey: .items)) ?? [:]
        params = (try? c.decodeIfPresent([String: YearReportParam].self, forKey: .params)) ?? [:]
        warnings = (try? c.decodeIfPresent([String].self, forKey: .warnings)) ?? []
        disclaimer = c.lenientString(.disclaimer)
    }

    private static func numbers(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [String: Double] {
        guard let raw = try? c.decodeIfPresent([String: Double?].self, forKey: key) else { return [:] }
        return raw.compactMapValues { $0 }
    }

    static func normalized(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: "").lowercased()
    }

    /// Wert per Schlüssel unabhängig von snake_case/camelCase.
    static func value<T>(_ dict: [String: T], _ key: String) -> T? {
        if let v = dict[key] { return v }
        let wanted = normalized(key)
        return dict.first { normalized($0.key) == wanted }?.value
    }

    func km(_ category: TripCategory) -> Double? { Self.value(self.km, category.rawValue) }
    func share(_ category: TripCategory) -> Double? { Self.value(self.sharesPct, category.rawValue) }
    func item(_ key: String) -> YearReportItem? { Self.value(self.items, key) }
    var totalKm: Double? { Self.value(self.km, "total") }

    /// Offline-Ersatz: km und Anteile je Kategorie aus lokalen Fahrten.
    static func local(trips: [Trip], year: Int) -> YearReport {
        var r = YearReport()
        r.year = year
        r.isLocal = true
        let list = trips.filter { !$0.deleted && $0.startAt.hasPrefix("\(year)-") }
        r.tripsCount = list.count
        r.unconfirmed = list.filter(\.needsReview).count
        var totals: [String: Double] = [:]
        for c in TripCategory.allCases { totals[c.rawValue] = 0 }
        for t in list {
            totals[t.category, default: 0] += max(0, t.distanceKm ?? 0)
        }
        let total = totals.values.reduce(0, +)
        totals["total"] = total
        r.km = totals
        if total > 0 {
            for c in TripCategory.allCases {
                r.sharesPct[c.rawValue] = (totals[c.rawValue] ?? 0) / total * 100
            }
        }
        if let n = r.unconfirmed, n > 0 {
            r.warnings.append("\(n) Fahrt(en) nicht bestätigt bzw. ohne Kategorie – Zahlen vorläufig.")
        }
        return r
    }
}
