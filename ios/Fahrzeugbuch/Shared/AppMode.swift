import Foundation

/// Betriebsart der App: „Lokal“ (nur dieses Gerät, ohne Server und Login) oder „Server“ (eigener
/// Fahrzeugbuch-Server, gemeinsames Bewirtschaften). `AppSettings.mode == nil` → Auswahl anzeigen.
enum AppMode: String, Codable, CaseIterable, Identifiable {
    case local, server

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: "Lokal"
        case .server: "Server"
        }
    }

    /// Demo-Modus (nur Debug): Geräte-Funktionen (GPS, Bewegung) nicht starten.
    static var isDemo: Bool {
        #if DEBUG
        return Demo.isActive
        #else
        return false
        #endif
    }
}

/// Was in der aktuellen Betriebsart verfügbar ist (UI blendet Nicht-Verfügbares aus bzw. erklärt es).
struct ModeCapabilities: Equatable {
    /// PDF/CSV-Berichte vom Server
    var serverReports: Bool
    /// Änderungsverlauf je Eintrag (Server-Journal bzw. lokales Journal)
    var history: Bool
    /// Integritätsprüfung des Server-Journals (signierte Anker)
    var integrityServer: Bool
    /// KI-Vorschläge für den Fahrtzweck (LLM auf dem Server)
    var aiSuggestions: Bool
    /// KI-Auswertung von Fotos (Server)
    var aiScan: Bool
    /// Strassendistanz/Adressen über den Server (OSRM/Photon)
    var geocodingServer: Bool
    /// Mitgliederliste des Mandanten
    var members: Bool
    /// Aktivitäten-Feed (wer hat was geändert)
    var activity: Bool
    /// Belege werden auf den Server übertragen
    var attachmentsSync: Bool
    /// Berichte (PDF/CSV) auf dem Gerät erzeugen
    var localReports: Bool
    /// Steuerparameter in der App bearbeiten (Servermodus: nur im Webfrontend)
    var editTaxParams: Bool
    /// Datensicherung als Datei (Export/Import)
    var fileBackup: Bool

    static let server = ModeCapabilities(serverReports: true, history: true, integrityServer: true,
                                         aiSuggestions: true, aiScan: true, geocodingServer: true, members: true,
                                         activity: true, attachmentsSync: true, localReports: true,
                                         editTaxParams: false, fileBackup: false)

    static let local = ModeCapabilities(serverReports: false, history: true, integrityServer: false,
                                        aiSuggestions: false, aiScan: false, geocodingServer: false, members: false,
                                        activity: false, attachmentsSync: false, localReports: true,
                                        editTaxParams: true, fileBackup: true)

    static func of(_ mode: AppMode?) -> ModeCapabilities {
        mode == .local ? .local : .server
    }
}

/// Bezeichnung des Benutzers im Lokalmodus (Verlauf, Abschluss, Fahrer).
enum LocalIdentity {
    static let actorName = "Ich"
    /// Slug des lokalen Fahrzeugbuchs
    static let slug = "lokal"
}

extension TenantInfo {
    /// Lokales Fahrzeugbuch (ohne Server)
    static let local = TenantInfo(slug: LocalIdentity.slug, role: "write")
}
