import Foundation
import MetricKit

/// Absturzberichte über MetricKit: iOS liefert Diagnosen (Stacktrace, Ausnahme, Signal) beim nächsten Start
/// an die App. Gespeichert werden nur Absturz-/Hänger-Diagnosen als JSON im App-Container (nichts verlässt das
/// Gerät); der Nutzer kann sie in den Einstellungen teilen und löschen. Höchstens `maxReports` Dateien.
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
        for p in relevant {
            let stamp = Self.stampFormatter.string(from: p.timeStampEnd)
            let kind = (p.crashDiagnostics ?? []).isEmpty ? "haenger" : "absturz"
            let url = Self.directory.appendingPathComponent("odovio-\(kind)-\(stamp).json")
            guard !fm.fileExists(atPath: url.path) else { continue }
            try? p.jsonRepresentation().write(to: url, options: .atomic)
        }
        prune()
    }

    private func prune() {
        let files = Self.reports()
        guard files.count > Self.maxReports else { return }
        for url in files.dropFirst(Self.maxReports) { try? FileManager.default.removeItem(at: url) }
    }

    /// Gespeicherte Berichte, neueste zuerst.
    static func reports() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func deleteAll() {
        for url in reports() { try? FileManager.default.removeItem(at: url) }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
