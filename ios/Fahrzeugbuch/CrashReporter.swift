import Foundation
import MetricKit

/// Absturzberichte über MetricKit: iOS liefert Diagnosen (Stacktrace, Ausnahme, Signal) beim nächsten Start
/// an die App. Gespeichert werden nur Absturz-/Hänger-Diagnosen als JSON im App-Container (nichts verlässt das
/// Gerät); der Nutzer kann sie in den Einstellungen teilen und löschen. Höchstens `maxReports` Dateien.
///
/// Datenschutz (I5): Dateischutz «completeUnlessOpen» (MetricKit liefert auch bei gesperrtem Gerät; danach
/// verschlüsselt), Ordner nicht im Geräte-Backup, beim Abmelden/Zurücksetzen gelöscht (`AppSettings.resetLocalData`).
final class CrashReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = CrashReporter()
    static let maxReports = 10

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    private var started = false

    /// Beim App-Start aufrufen (idempotent).
    func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
        // Bereits zugestellte, noch nicht gesicherte Diagnosen
        save(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        save(payloads)
    }

    private func save(_ payloads: [MXDiagnosticPayload]) {
        let relevant = payloads.filter { !($0.crashDiagnostics ?? []).isEmpty || !($0.hangDiagnostics ?? []).isEmpty }
        guard !relevant.isEmpty else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        var dir = Self.directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        for p in relevant {
            let stamp = Self.stampFormatter.string(from: p.timeStampEnd)
            let kind = (p.crashDiagnostics ?? []).isEmpty ? Kind.hang : Kind.crash
            let url = Self.directory.appendingPathComponent("odovio-\(kind.rawValue)-\(stamp).json")
            guard !fm.fileExists(atPath: url.path) else { continue }
            try? p.jsonRepresentation().write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
        prune()
    }

    /// Nur die neuesten `maxReports` behalten – nach Zeitpunkt, nicht nach Art (Q10).
    private func prune() {
        let files = Self.reports()
        guard files.count > Self.maxReports else { return }
        for url in files.dropFirst(Self.maxReports) { try? FileManager.default.removeItem(at: url) }
    }

    /// Gespeicherte Berichte, neueste zuerst.
    static func reports() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return newestFirst(files.filter { $0.pathExtension == "json" })
    }

    /// Nach dem Zeitpunkt im Dateinamen sortieren, neueste zuerst (Q10: der Name beginnt mit der Art –
    /// «haenger» > «absturz» – und taugt nicht als Sortierschlüssel). Ohne lesbaren Zeitpunkt zuletzt.
    static func newestFirst(_ files: [URL]) -> [URL] {
        files.map { (url: $0, date: Self.date(of: $0)) }
            .sorted { a, b in
                switch (a.date, b.date) {
                case let (x?, y?): return x != y ? x > y : a.url.lastPathComponent > b.url.lastPathComponent
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return a.url.lastPathComponent > b.url.lastPathComponent
                }
            }
            .map { $0.url }
    }

    /// Zeitpunkt aus dem Dateinamen `odovio-<art>-yyyyMMdd-HHmmss.json`.
    static func date(of url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.count >= 15 else { return nil }
        return stampFormatter.date(from: String(name.suffix(15)))
    }

    /// Anzeige statt des Dateinamens (U8), z. B. «Absturz vom 27.11.2026, 14:03».
    static func title(of url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let kind = name.contains("-\(Kind.hang.rawValue)-") ? "Hänger" : "Absturz"
        guard let when = Self.date(of: url) else { return kind }
        return "\(kind) vom \(titleFormatter.string(from: when))"
    }

    static func deleteAll() {
        for url in reports() { try? FileManager.default.removeItem(at: url) }
    }

    private enum Kind: String {
        case crash = "absturz"
        case hang = "haenger"
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_CH")
        f.dateFormat = "dd.MM.yyyy, HH:mm"
        return f
    }()
}
