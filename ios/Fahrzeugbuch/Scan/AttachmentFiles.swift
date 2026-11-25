import CryptoKit
import Foundation

/// Lokale Beleg-Dateien.
/// - Servermodus: `Application Support/Attachments/<id>.jpg` (Dateischutz „completeUnlessOpen“, nicht im Backup;
///   zugleich Cache heruntergeladener Belege).
/// - Lokalmodus: `Application Support/Lokal/Belege/<id>.jpg` (bzw. Verzeichnis des lokalen Stores) – **im**
///   Geräte-Backup, da einzige Kopie.
/// Lesen ohne Verzeichnis sucht in beiden Ablagen (z. B. Upload nach dem Wechsel Lokal → Server).
enum AttachmentFiles {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Attachments", directoryHint: .isDirectory)
    }

    /// Standardablage des Lokalmodus
    static var localDirectory: URL {
        StoreFiles.localDirectory.appending(path: "Belege", directoryHint: .isDirectory)
    }

    static func isValidId(_ id: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return !id.isEmpty && id.count <= 64 && id.allSatisfy { allowed.contains($0) }
    }

    /// Nur UUID-artige Namen (kein Pfad-Trick über die ID).
    static func url(for id: String, directory dir: URL? = nil) -> URL? {
        guard isValidId(id) else { return nil }
        return (dir ?? directory).appending(path: "\(id.lowercased()).jpg")
    }

    /// Schreiben. `directory == nil` → Servermodus-Ablage (nicht im Backup); sonst lokale Ablage (im Backup).
    static func write(_ data: Data, id: String, directory dir: URL? = nil) throws {
        guard let url = url(for: id, directory: dir) else { throw CocoaError(.fileWriteInvalidFileName) }
        let exclude = dir == nil
        ensureDirectory(dir ?? directory, excludeFromBackup: exclude)
        try data.write(to: url, options: StoreFiles.writeOptions)
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = exclude
        try? target.setResourceValues(values)
    }

    /// Lesen: im angegebenen Verzeichnis, sonst Servermodus-Ablage, dann lokale Standardablage.
    static func read(_ id: String, directory dir: URL? = nil) -> Data? {
        for candidate in candidates(dir) {
            if let url = url(for: id, directory: candidate), let data = try? Data(contentsOf: url) { return data }
        }
        return nil
    }

    static func exists(_ id: String, directory dir: URL? = nil) -> Bool {
        candidates(dir).contains { candidate in
            url(for: id, directory: candidate).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
    }

    static func remove(_ id: String, directory dir: URL? = nil) {
        guard let url = url(for: id, directory: dir) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Abmelden / Benutzerwechsel (nur Servermodus-Ablage; lokale Daten bleiben)
    static func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// SHA-256 als 64 Hex-Zeichen (klein)
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func candidates(_ dir: URL?) -> [URL] {
        if let dir { return [dir] }
        return [directory, localDirectory]
    }

    private static func ensureDirectory(_ dir: URL, excludeFromBackup: Bool) {
        try? StoreFiles.ensureDirectory(dir, excludeFromBackup: excludeFromBackup)
    }
}
