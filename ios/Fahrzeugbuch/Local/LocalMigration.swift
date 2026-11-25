import Foundation

/// Ergebnis des Wechsels Lokal → Server.
struct MigrationReport: Equatable {
    /// Übertragene Objekte je Entity (z. B. "trip": 120)
    var counts: [String: Int] = [:]
    /// Vom Server abgelehnte Änderungen (Beschreibung + Grund)
    var rejected: [String] = []
    /// Hinweise (gesperrte Fahrten, nicht übertragbare Monatsabschlüsse/Steuerparameter, Übersprungenes …)
    var notes: [String] = []
    /// Noch nicht übertragen (offline) – werden beim nächsten Sync gesendet
    var pending: Int = 0

    var total: Int { counts.values.reduce(0, +) }
}

/// Moduswechsel zwischen Lokal und Server (testbarer Teil; Ablauf mit Login/Sync in `AppSettings`).
@MainActor
enum LocalMigration {
    /// Lokalen Bestand in einen (Server-)Store einreihen – gleiche IDs, Abhängigkeitsreihenfolge, Belege in
    /// `pendingBlobs`. Noch kein Sync. Rückgabe: Bericht ohne Ablehnungen.
    static func enqueue(from local: TenantStore, into server: TenantStore) -> MigrationReport {
        var report = MigrationReport()
        guard !server.isLocal else {
            report.notes.append("Ziel ist kein Server-Mandant.")
            return report
        }
        guard server.canWrite else {
            report.notes.append("Keine Schreibberechtigung für Mandant „\(server.tenant.slug)“ – nichts übertragen.")
            return report
        }
        local.flush()
        let snap = local.contentSnapshot()
        let counts = server.enqueueMigration(snap, attachmentSource: local.attachmentDirectory)
        report.counts = counts.filter { !$0.key.hasPrefix("skipped:") }
        let skipped = counts.filter { $0.key.hasPrefix("skipped:") }
        for (key, n) in skipped.sorted(by: { $0.key < $1.key }) {
            let entity = String(key.dropFirst("skipped:".count))
            report.notes.append("\(n) \(TenantStore.entityLabel(entity))-Einträge übersprungen (Fahrzeug bzw. "
                                + "übergeordneter Eintrag storniert).")
        }
        let locked = (snap.trips ?? [:]).values.filter { !$0.deleted && $0.isLocked }.count
        if locked > 0 {
            report.notes.append("\(locked) Fahrt(en) aus lokal abgeschlossenen Monaten als „bestätigt“ übertragen – "
                                + "die Monate bitte auf dem Server erneut abschliessen.")
        }
        let closed = (snap.periods ?? [:]).values.filter(\.isClosed).count
        if closed > 0 {
            report.notes.append("\(closed) lokale(r) Monatsabschluss/-abschlüsse nicht übertragbar (Abschluss nur auf "
                                + "dem Server mit signiertem Anker).")
        }
        let taxParams = (snap.taxParams ?? [:]).values.filter { !$0.deleted }.count
        if taxParams > 0 {
            report.notes.append("\(taxParams) Steuerparameter nicht übertragen – im Webfrontend erfassen.")
        }
        report.notes.append("Lokale Daten bleiben als Sicherung auf dem Gerät, bis du sie löschst.")
        return report
    }

    /// Nach dem Sync: Ablehnungen der übertragenen Objekte und ausstehende Änderungen ergänzen.
    static func finish(_ report: inout MigrationReport, server: TenantStore, ids: Set<String>) {
        report.rejected = server.rejectedOps.filter { ids.contains($0.entityId) }.map { "\($0.label): \($0.error)" }
        report.pending = server.outbox.count + server.pendingBlobs.count
        if report.pending > 0 {
            report.notes.append("\(report.pending) Änderung(en) noch nicht übertragen – werden beim nächsten Sync gesendet.")
        }
    }

    /// IDs aller Objekte eines Stands (für den Abgleich der Ablehnungen).
    static func ids(_ s: TenantStore.Snapshot) -> Set<String> {
        var out = Set<String>()
        out.formUnion(s.vehicles.keys); out.formUnion(s.odometer.keys); out.formUnion(s.fuel.keys)
        out.formUnion(s.maintenance.keys); out.formUnion(s.items.keys)
        out.formUnion((s.materials ?? [:]).keys); out.formUnion((s.articles ?? [:]).keys)
        out.formUnion((s.trips ?? [:]).keys); out.formUnion((s.places ?? [:]).keys)
        out.formUnion((s.customers ?? [:]).keys); out.formUnion((s.rules ?? [:]).keys)
        out.formUnion((s.attachments ?? [:]).keys)
        return out
    }

    /// Server → Lokal: aktuellen Stand eines Server-Stores als lokale Daten übernehmen (ohne Outbox, ohne
    /// Ablehnungen; Belege, soweit auf dem Gerät vorhanden, werden in die lokale Ablage kopiert).
    /// Rückgabe: Hinweise (z. B. verworfene ausstehende Änderungen).
    @discardableResult
    static func copyServerState(_ server: TenantStore, into local: TenantStore) throws -> [String] {
        guard local.isLocal else { throw BackupError.notLocal }
        server.flush()
        var notes: [String] = []
        let pending = server.outbox.count + server.pendingBlobs.count
        if pending > 0 {
            notes.append("\(pending) noch nicht synchronisierte Änderung(en) wurden lokal übernommen, aber nicht mehr an "
                         + "den Server gesendet.")
        }
        if !server.rejectedOps.isEmpty {
            notes.append("\(server.rejectedOps.count) abgelehnte Änderung(en) wurden verworfen.")
        }
        var snap = server.contentSnapshot()
        snap.outbox = []
        snap.rejectedOps = []
        snap.pendingBlobs = []
        snap.cursor = 0
        snap.lastSync = nil
        var missing = 0
        for a in (snap.attachments ?? [:]).values where !a.deleted {
            if let d = AttachmentFiles.read(a.id) {
                try? AttachmentFiles.write(d, id: a.id, directory: local.attachmentDirectory)
            } else {
                missing += 1
            }
        }
        if missing > 0 {
            notes.append("\(missing) Beleg-Foto(s) waren nicht auf dem Gerät und fehlen im lokalen Fahrzeugbuch.")
        }
        LocalBackup.archiveCurrent(local)
        try local.replaceLocalContent(snap, journal: nil, reason: "Übernommen vom Server (\(server.tenant.slug))")
        return notes
    }
}
