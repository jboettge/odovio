import Foundation

/// Verlauf, Integritätsprüfung und Server-Abfragen (gemeinsames Bewirtschaften) des Stores – je nach
/// Betriebsart aus dem lokalen Journal bzw. vom Server.
extension TenantStore {
    // MARK: Verlauf

    /// Lokaler Änderungsverlauf eines Objekts (älteste zuerst) – gleicher Typ wie der Server-Verlauf.
    /// `actorName` = „Ich“, `data` = Stand nach der Änderung (Schlüssel wie beim Server-Verlauf in camelCase).
    func localHistory(entity: String, id: String) -> [RevisionEntry] {
        guard let journal = localJournal else { return [] }
        return journal.entries(entity: entity, id: id).map(Self.revision)
    }

    static func revision(_ e: JournalEntry) -> RevisionEntry {
        var data: [String: JSONValue] = [:]
        for (k, v) in e.data.objectValue ?? [:] { data[k] = v.displayValue }
        return RevisionEntry(seq: e.seq, entity: e.entity, entityId: e.entityId, version: e.version, action: e.action,
                             data: data, actorName: e.actor ?? LocalIdentity.actorName, recordedAt: e.at,
                             clientTs: e.at, conflict: false, hash: e.hash)
    }

    /// Verlauf je nach Betriebsart: lokal aus dem Journal, sonst `GET api/t/{t}/history/{entity}/{id}`.
    func history(entity: String, id: String) async throws -> [RevisionEntry] {
        if isLocal { return localHistory(entity: entity, id: id) }
        return try await api.get("api/t/\(tenant.slug)/history/\(entity)/\(id)")
    }

    // MARK: Integrität (Lokalmodus)

    /// Journal-Datei prüfen (Kette, Prüfsummen, Nummerierung) und den letzten Journal-Stand jedes Objekts mit
    /// dem Datensatz vergleichen (fehlende, zusätzliche oder abweichende Datensätze).
    func verifyLocalJournal() -> LocalIntegrity {
        guard let journal = localJournal else {
            return LocalIntegrity(ok: false, count: 0, headHash: "", brokenAt: nil,
                                  problems: ["Kein lokales Journal (Servermodus)."])
        }
        flush()
        let (chain, entries) = journal.verifyFile()
        var result = chain
        result.problems += journal.loadProblems.filter { p in !result.problems.contains(where: { $0.contains(p) }) }
        if journal.hasDeferredEntries {
            result.problems.append("Änderungen seit dem Sperren des Geräts sind noch nicht im Journal.")
        }
        if let error = journal.lastError { result.problems.append(error) }
        result.problems += recordMismatches(entries)
        result.ok = result.problems.isEmpty
        return result
    }

    /// Abgleich letzter Journal-Stand ↔ Datensätze.
    func recordMismatches(_ entries: [JournalEntry]) -> [String] {
        Self.recordMismatches(contentSnapshot(), entries)
    }

    // MARK: Gemeinsames Bewirtschaften (Servermodus; Verwaltung nur im Webfrontend)

    /// Mitglieder des Mandanten (`GET api/t/{t}/members`). Im Lokalmodus nicht verfügbar (501).
    func fetchMembers() async throws -> MembersResponse {
        guard !isLocal else { throw APIError(status: 501, message: "Im Lokalmodus gibt es keine Mitglieder.") }
        return try await api.get("api/t/\(tenant.slug)/members")
    }

    /// Aktivitäten (neueste zuerst; `beforeSeq` = Cursor `nextBeforeSeq` der vorherigen Seite).
    func fetchActivity(beforeSeq: Int? = nil, limit: Int = 50) async throws -> ActivityPage {
        guard !isLocal else { throw APIError(status: 501, message: "Im Lokalmodus nicht verfügbar.") }
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let beforeSeq { query.append(URLQueryItem(name: "before_seq", value: String(beforeSeq))) }
        return try await api.get("api/t/\(tenant.slug)/activity", query: query)
    }

    // MARK: Prüfung/Bericht je Betriebsart

    /// Monatsprüfung: Servermodus `GET …/trips/check` (offline → lokale Prüfung), Lokalmodus lokal.
    func tripCheck(vehicleId: String, month: String) async -> (check: TripCheck, isLocal: Bool) {
        if !isLocal, let c: TripCheck = try? await api.get("api/t/\(tenant.slug)/vehicles/\(vehicleId)/trips/check",
                                                           query: [URLQueryItem(name: "month", value: month)]) {
            return (c, false)
        }
        return (monthCheck(vehicleId: vehicleId, month: month).tripCheck, true)
    }

    /// Jahresbericht: Servermodus vom Server (offline → lokale Berechnung), Lokalmodus lokal.
    func yearReport(vehicle: Vehicle, year: Int) async -> YearReport {
        if !isLocal, let r: YearReport = try? await api.get(
            "api/t/\(tenant.slug)/vehicles/\(vehicle.id)/year-report",
            query: [URLQueryItem(name: "year", value: String(year))]) {
            return r
        }
        return LocalReports.yearReport(store: self, vehicle: vehicle, year: year)
    }
}
