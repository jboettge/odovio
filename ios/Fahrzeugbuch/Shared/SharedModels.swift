import Foundation

// MARK: - Gemeinsames Bewirtschaften (Servermodus)
// Verwaltung der Mitglieder erfolgt ausschliesslich im Webfrontend; die App zeigt Mitglieder und
// Aktivitäten nur an (`TenantStore.fetchMembers()`, `TenantStore.fetchActivity(beforeSeq:)`).

/// Mitglied eines Mandanten (GET api/t/{t}/members).
struct Member: Decodable, Identifiable, Hashable {
    var id: String
    var username: String
    var name: String
    var email: String?
    /// "admin" | "write" | "read" (nil = unbekannt/keine direkte Rolle)
    var role: String?
    /// Herkunft der Mitgliedschaft (z. B. "local", "keycloak", "group")
    var source: String
    /// ISO-8601
    var lastActivityAt: String?

    enum CodingKeys: String, CodingKey { case id, username, name, email, role, source, lastActivityAt }

    init(id: String, username: String, name: String, email: String? = nil, role: String? = nil,
         source: String = "local", lastActivityAt: String? = nil) {
        self.id = id
        self.username = username
        self.name = name
        self.email = email
        self.role = role
        self.source = source
        self.lastActivityAt = lastActivityAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawId = c.lenientString(.id) ?? c.lenientInt(.id).map(String.init) ?? ""
        let user = c.lenientString(.username) ?? ""
        self.init(id: rawId.isEmpty ? user : rawId, username: user,
                  name: c.lenientString(.name)?.nilIfEmpty ?? user,
                  email: c.lenientString(.email)?.nilIfEmpty, role: c.lenientString(.role)?.nilIfEmpty,
                  source: c.lenientString(.source) ?? "local", lastActivityAt: c.lenientString(.lastActivityAt))
    }

    var isAdmin: Bool { role == "admin" }
    var lastActivityDate: Date? { lastActivityAt.flatMap(ISODate.parse) }

    var roleLabel: String { Member.roleLabel(role) }

    static func roleLabel(_ role: String?) -> String {
        switch role {
        case "admin": "Verwalten"
        case "write": "Bearbeiten"
        case "read": "Nur lesen"
        case nil: "–"
        default: role ?? "–"
        }
    }
}

/// Antwort von GET api/t/{t}/members. `manageable`: Server kann Mitglieder verwalten (im Webfrontend).
struct MembersResponse: Decodable {
    var members: [Member]
    var manageable: Bool

    enum CodingKeys: String, CodingKey { case members, manageable }

    init(members: [Member], manageable: Bool) {
        self.members = members
        self.manageable = manageable
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        members = (try? c.decodeIfPresent([Member].self, forKey: .members)) ?? []
        manageable = c.lenientBool(.manageable) ?? false
    }
}

/// Eintrag im Aktivitäten-Feed (GET api/t/{t}/activity).
struct ActivityItem: Decodable, Identifiable, Hashable {
    var seq: Int
    /// ISO-8601
    var at: String
    var actorName: String?
    /// create | update | delete | close …
    var action: String
    var entity: String
    var entityId: String
    var vehicleId: String?
    var summary: String
    var id: Int { seq }

    enum CodingKeys: String, CodingKey { case seq, at, actorName, action, entity, entityId, vehicleId, summary }

    init(seq: Int, at: String, actorName: String?, action: String, entity: String, entityId: String,
         vehicleId: String? = nil, summary: String) {
        self.seq = seq
        self.at = at
        self.actorName = actorName
        self.action = action
        self.entity = entity
        self.entityId = entityId
        self.vehicleId = vehicleId
        self.summary = summary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(seq: c.lenientInt(.seq) ?? 0, at: c.lenientString(.at) ?? "",
                  actorName: c.lenientString(.actorName), action: c.lenientString(.action) ?? "",
                  entity: c.lenientString(.entity) ?? "", entityId: c.lenientString(.entityId) ?? "",
                  vehicleId: c.lenientString(.vehicleId), summary: c.lenientString(.summary) ?? "")
    }

    var date: Date? { ISODate.parse(at) }

    var actionLabel: String {
        switch action {
        case "create": "Erfasst"
        case "update": "Geändert"
        case "delete": "Storniert"
        case "close": "Abgeschlossen"
        default: action
        }
    }
}

/// Seite des Aktivitäten-Feeds; `nextBeforeSeq` = Cursor für ältere Einträge (nil = Ende).
struct ActivityPage: Decodable {
    var items: [ActivityItem]
    var nextBeforeSeq: Int?

    enum CodingKeys: String, CodingKey { case items, nextBeforeSeq }

    init(items: [ActivityItem], nextBeforeSeq: Int? = nil) {
        self.items = items
        self.nextBeforeSeq = nextBeforeSeq
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? c.decodeIfPresent([ActivityItem].self, forKey: .items)) ?? []
        nextBeforeSeq = c.lenientInt(.nextBeforeSeq)
    }
}
