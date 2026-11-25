import CryptoKit
import Foundation

/// Lokale Beleg-Dateien: Application Support/Attachments/<id>.jpg
/// (Dateischutz „completeUnlessOpen“, nicht im Backup). Dient zugleich als Cache heruntergeladener Belege.
enum AttachmentFiles {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Attachments", directoryHint: .isDirectory)
    }

    /// Nur UUID-artige Namen (kein Pfad-Trick über die ID).
    static func url(for id: String) -> URL? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard !id.isEmpty, id.count <= 64, id.allSatisfy({ allowed.contains($0) }) else { return nil }
        return directory.appending(path: "\(id.lowercased()).jpg")
    }

    static func write(_ data: Data, id: String) throws {
        guard let url = url(for: id) else { throw CocoaError(.fileWriteInvalidFileName) }
        ensureDirectory()
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    static func read(_ id: String) -> Data? {
        guard let url = url(for: id) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func exists(_ id: String) -> Bool {
        guard let url = url(for: id) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func remove(_ id: String) {
        guard let url = url(for: id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Abmelden / Benutzerwechsel
    static func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// SHA-256 als 64 Hex-Zeichen (klein)
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func ensureDirectory() {
        let dir = directory
        guard !FileManager.default.fileExists(atPath: dir.path) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var target = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }
}
