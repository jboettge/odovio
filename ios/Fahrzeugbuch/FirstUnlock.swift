import Foundation
import UIKit

/// Start vor der ersten Entsperrung nach einem Neustart (Q6).
///
/// iOS weckt die App z. B. für Standort-Ereignisse, bevor das Gerät nach einem Neustart je entsperrt wurde.
/// Dann liefern UserDefaults nur Standardwerte und die Keychain («AfterFirstUnlock») keine Einträge – das
/// heisst **nicht** «abgemeldet», «keine Betriebsart» oder «Automatik aus». Bis zur ersten Entsperrung
/// (`UIApplication.protectedDataDidBecomeAvailableNotification`) wird nichts davon interpretiert oder
/// überschrieben; danach laden `AppSettings`, `AuthManager`, `TripCoordinator` und `CarConnectionMonitor`
/// ihre Werte nach.
///
/// Erkennung: Geschützte Daten nicht verfügbar **und** der Installations-Marker in den UserDefaults fehlt.
/// Bei gesperrtem Gerät *nach* der ersten Entsperrung sind die UserDefaults lesbar (Marker vorhanden) – dann
/// läuft die App normal (Aufzeichnung im Hintergrund, Q1).
enum FirstUnlock {
    /// Entscheidung ohne Systemzugriff (testbar).
    /// - Parameters:
    ///   - protectedDataAvailable: `UIApplication.isProtectedDataAvailable` (auch bei gesperrtem Gerät
    ///     nach der ersten Entsperrung `false`)
    ///   - installMarker: Marker `Keychain.installMarkerKey` aus den UserDefaults gelesen
    static func isBeforeFirstUnlock(protectedDataAvailable: Bool, installMarker: Bool) -> Bool {
        !protectedDataAvailable && !installMarker
    }

    /// Läuft die App gerade vor der ersten Entsperrung?
    @MainActor
    static var isActive: Bool {
        isBeforeFirstUnlock(protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
                            installMarker: UserDefaults.standard.bool(forKey: Keychain.installMarkerKey))
    }
}
