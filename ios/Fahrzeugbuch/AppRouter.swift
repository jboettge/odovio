import Foundation
import Observation
import UIKit

/// Ziel, das die App beim nächsten Erscheinen öffnen soll (Quick Action, App-Intent, Mitteilung).
/// Die UI beobachtet `pending`, navigiert und setzt es danach auf `nil`.
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    enum AppRoute: Equatable {
        /// Tankvorgang erfassen (`nil` = Standardfahrzeug)
        case addFuel(vehicleId: String?)
        /// Fahrt erfassen (Formular), z. B. wenn „Fahrt starten“ nicht direkt möglich war
        case addTrip(vehicleId: String?)
        /// Fahrten bestätigen
        case review(vehicleId: String?)
    }

    var pending: AppRoute?

    private init() {}
}

/// Home-Screen-Quick-Actions (`UIApplicationShortcutItems` in project.yml).
enum QuickAction {
    static let addFuel = "net.jmb.fahrzeugbuch.addFuel"
    static let startTrip = "net.jmb.fahrzeugbuch.startTrip"

    /// Verarbeitet eine Quick Action; Rückgabe: erkannt.
    @MainActor
    @discardableResult
    static func handle(_ type: String) -> Bool {
        switch type {
        case addFuel:
            AppRouter.shared.pending = .addFuel(vehicleId: nil)
            return true
        case startTrip:
            Task { @MainActor in
                let coordinator = TripCoordinator.shared
                guard !coordinator.isRecording else { return }
                _ = await coordinator.startFromIntent(privateMode: false)
                if !coordinator.isRecording {
                    // Kein Standardfahrzeug, keine Berechtigung … → Formular öffnen (Hinweis in `lastError`)
                    AppRouter.shared.pending = .addTrip(vehicleId: nil)
                }
            }
            return true
        default:
            return false
        }
    }
}

/// Adapter für SwiftUI (`@UIApplicationDelegateAdaptor(AppDelegate.self)`): Quick Actions (Kalt- und
/// Warmstart) und frühe Registrierung des Mitteilungs-Delegates.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated {
            TripNotifications.shared.register()
        }
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem {
            // Kaltstart über Quick Action
            let type = item.type
            MainActor.assumeIsolated { _ = QuickAction.handle(type) }
        }
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = QuickActionSceneDelegate.self
        return config
    }
}

/// Warmstart über Quick Action.
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        let type = shortcutItem.type
        let handled = MainActor.assumeIsolated { QuickAction.handle(type) }
        completionHandler(handled)
    }
}
