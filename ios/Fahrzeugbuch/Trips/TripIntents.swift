import AppIntents
import Foundation

// App-Intents „Fahrt starten/beenden“ (Siri, Kurzbefehle, Action-Button).
//
// CarPlay-Trigger (vom Nutzer einzurichten, App → Kurzbefehle → Automation):
//   • „CarPlay – Verbindet“  → Aktion „Fahrt starten“ (läuft ohne Rückfrage)
//   • „CarPlay – Trennt“     → Aktion „Fahrt beenden“
//   Alternativ „Bluetooth – Auto-Freisprecher verbunden/getrennt“ (fragt je nach iOS-Version nach).
// Die Intents laufen ohne Öffnen der App im Hintergrund; damit die Aufzeichnung dort weiterläuft,
// braucht es die Standortberechtigung „Immer“ (sonst die App einmal öffnen).
// Fahrzeug = Standardfahrzeug des geöffneten Mandanten (bzw. das einzige Fahrzeug).

struct StartTripIntent: AppIntent {
    static let title: LocalizedStringResource = "Fahrt starten"
    static let description: IntentDescription? = IntentDescription(
        "Startet die Aufzeichnung einer Fahrt mit dem Standardfahrzeug im Fahrtenbuch.")
    static let openAppWhenRun: Bool = false

    /// Privatmodus: nur km und Zeit speichern – kein Track, keine Adressen
    @Parameter(title: "Privatfahrt", default: false)
    var privateMode: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await TripCoordinator.shared.startFromIntent(privateMode: privateMode)
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct StartPrivateTripIntent: AppIntent {
    static let title: LocalizedStringResource = "Privatfahrt starten"
    static let description: IntentDescription? = IntentDescription(
        "Startet eine Fahrt im Privatmodus: nur km und Zeit, kein Track, keine Adressen.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await TripCoordinator.shared.startFromIntent(privateMode: true)
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct StopTripIntent: AppIntent {
    static let title: LocalizedStringResource = "Fahrt beenden"
    static let description: IntentDescription? = IntentDescription(
        "Beendet die laufende Fahrt und legt einen Entwurf im Fahrtenbuch an.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await TripCoordinator.shared.stopFromIntent()
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

/// „Tanken erfassen“: öffnet die App direkt im Tank-Formular (Standardfahrzeug).
struct AddFuelIntent: AppIntent {
    static let title: LocalizedStringResource = "Tanken erfassen"
    static let description: IntentDescription? = IntentDescription(
        "Öffnet das Fahrzeugbuch direkt beim Erfassen eines Tankvorgangs.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.pending = .addFuel(vehicleId: nil)
        return .result()
    }
}

/// „Fahrten bestätigen“: öffnet das Review offener Fahrten.
struct ReviewTripsIntent: AppIntent {
    static let title: LocalizedStringResource = "Fahrten bestätigen"
    static let description: IntentDescription? = IntentDescription(
        "Öffnet die Liste der Fahrten, die noch bestätigt werden müssen.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.pending = .review(vehicleId: nil)
        return .result()
    }
}

struct FahrtenbuchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartTripIntent(),
            phrases: [
                "Fahrt starten mit \(.applicationName)",
                "Starte eine Fahrt in \(.applicationName)",
                "\(.applicationName) Fahrt starten",
            ],
            shortTitle: "Fahrt starten",
            systemImageName: "car.fill"
        )
        AppShortcut(
            intent: StartPrivateTripIntent(),
            phrases: [
                "Privatfahrt starten mit \(.applicationName)",
                "Starte eine Privatfahrt in \(.applicationName)",
            ],
            shortTitle: "Privatfahrt starten",
            systemImageName: "car.side"
        )
        AppShortcut(
            intent: StopTripIntent(),
            phrases: [
                "Fahrt beenden mit \(.applicationName)",
                "Beende die Fahrt in \(.applicationName)",
                "\(.applicationName) Fahrt beenden",
            ],
            shortTitle: "Fahrt beenden",
            systemImageName: "flag.checkered"
        )
        AppShortcut(
            intent: AddFuelIntent(),
            phrases: [
                "Tanken erfassen mit \(.applicationName)",
                "Tankvorgang in \(.applicationName) erfassen",
                "\(.applicationName) Tanken",
            ],
            shortTitle: "Tanken erfassen",
            systemImageName: "fuelpump.fill"
        )
        AppShortcut(
            intent: ReviewTripsIntent(),
            phrases: [
                "Fahrten bestätigen in \(.applicationName)",
                "\(.applicationName) Fahrten bestätigen",
            ],
            shortTitle: "Fahrten bestätigen",
            systemImageName: "checkmark.circle"
        )
    }
}
