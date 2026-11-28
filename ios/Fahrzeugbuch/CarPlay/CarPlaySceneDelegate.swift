import CarPlay
import Observation
import UIKit

/// CarPlay („Driving Task“-App): nur Fahrt-Funktionen – Raster mit «Fahrt starten» / «Fahrt beenden»,
/// der Titel zeigt den Status («Aufzeichnung seit 14:05 · 12.4 km»).
///
/// - Start/Stopp nutzen dieselben Wege wie Siri/Kurzbefehle (`startAction`/`stopAction`); Fahrzeug = «Fahrzeug für
///   CarPlay» (Einstellungen › Fahrtenbuch › Auto erkennen über), sonst das ausdrücklich gewählte
///   Standardfahrzeug bzw. das einzige Fahrzeug.
/// - Meldungen kurz (HIG, U4: «Fahrt gestartet», «Fahrt beendet · 12.4 km», «Kein Standardfahrzeug»);
///   was eine Handlung am iPhone braucht, kommt zusätzlich als Mitteilung aufs iPhone.
/// - Verbinden/Trennen der Szene meldet `CarConnectionMonitor`: Die Szene gilt als «im Auto»; die Fahrt startet
///   die Automatik, sobald iOS «im Auto unterwegs» erkennt. Beim Trennen endet die automatisch gestartete Fahrt
///   (nach kurzer Karenz).
///   Die Szene verbindet erst, wenn die App auf dem CarPlay-Bildschirm geöffnet ist bzw. war; verlässlich ist
///   ergänzend die Kurzbefehle-Automation «CarPlay verbunden → Fahrt starten» (docs/TESTFLIGHT.md).
/// - Voraussetzung auf dem Gerät: CarPlay-Berechtigung `com.apple.developer.carplay-driving-task` (von Apple
///   freizuschalten, siehe docs/TESTFLIGHT.md). Im Simulator genügt die Debug-Entitlement-Datei.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var grid: CPGridTemplate?
    private var busy = false
    private var statusTask: Task<Void, Never>?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let grid = CPGridTemplate(title: statusTitle(), gridButtons: buttons())
        self.grid = grid
        interfaceController.setRootTemplate(grid, animated: false, completion: nil)
        observeRecording()
        startStatusUpdates()
        CarConnectionMonitor.shared.setCarPlayScene(connected: true)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
        grid = nil
        statusTask?.cancel()
        statusTask = nil
        CarConnectionMonitor.shared.setCarPlayScene(connected: false)
    }

    // MARK: Kacheln und Status

    private func buttons() -> [CPGridButton] {
        let coordinator = TripCoordinator.shared
        let recording = coordinator.isRecording
        let start = CPGridButton(titleVariants: ["Fahrt starten", "Start"],
                                 image: Self.symbol("play.circle.fill")) { [weak self] _ in
            self?.startTrip()
        }
        start.isEnabled = !recording && !busy && !coordinator.isFinishing
        let stop = CPGridButton(titleVariants: ["Fahrt beenden", "Stopp"],
                                image: Self.symbol("stop.circle.fill")) { [weak self] _ in
            self?.stopTrip()
        }
        stop.isEnabled = recording && !busy
        return [start, stop]
    }

    /// Titel als Statuszeile (nur Information, keine Bedienung).
    private func statusTitle() -> String {
        let coordinator = TripCoordinator.shared
        if coordinator.isFinishing { return "Fahrt wird gespeichert …" }
        guard coordinator.isRecording else { return "odovio" }
        let km = TripNotifications.kmText(coordinator.liveDistanceKm)
        if let start = coordinator.recordingStartedAt {
            return "Aufzeichnung seit \(Self.timeFormatter.string(from: start)) · \(km)"
        }
        return "Aufzeichnung läuft · \(km)"
    }

    private func refresh() {
        grid?.updateGridButtons(buttons())
        grid?.updateTitle(statusTitle())
    }

    /// Kacheln aktualisieren, wenn sich die Aufzeichnung ändert (auch über iPhone, Siri, Automatik).
    private func observeRecording() {
        withObservationTracking {
            _ = TripCoordinator.shared.isRecording
            _ = TripCoordinator.shared.isFinishing
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.interfaceController != nil else { return }
                self.refresh()
                self.observeRecording()
            }
        }
    }

    /// Distanz im Titel alle 30 s nachführen (nicht bei jedem GPS-Fix).
    private func startStatusUpdates() {
        statusTask?.cancel()
        statusTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, self.interfaceController != nil else { return }
                if TripCoordinator.shared.isRecording { self.grid?.updateTitle(self.statusTitle()) }
            }
        }
    }

    // MARK: Aktionen

    private func startTrip() {
        run {
            await TripCoordinator.shared.startAction(privateMode: false,
                                                     preferredVehicleId: CarConnectionMonitor.shared.carPlayVehicleId)
        }
    }

    private func stopTrip() {
        run { await TripCoordinator.shared.stopAction() }
    }

    private func run(_ action: @escaping @MainActor () async -> TripCoordinator.ActionOutcome) {
        guard !busy else { return }
        busy = true
        refresh()
        Task { @MainActor in
            let outcome = await action()
            busy = false
            refresh()
            showMessage(outcome.short)
            if outcome.notify {
                await TripNotifications.shared.notifyInfo(title: outcome.short, body: outcome.detail)
            }
        }
    }

    /// Kurze Rückmeldung; schliesst sich nach 4 s selbst.
    private func showMessage(_ text: String) {
        guard let controller = interfaceController else { return }
        let ok = CPAlertAction(title: "OK", style: .default) { [weak controller] _ in
            controller?.dismissTemplate(animated: true, completion: nil)
        }
        let alert = CPAlertTemplate(titleVariants: [text], actions: [ok])
        controller.presentTemplate(alert, animated: true, completion: nil)
        Task { @MainActor [weak controller] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if controller?.presentedTemplate === alert {
                controller?.dismissTemplate(animated: true, completion: nil)
            }
        }
    }

    private static func symbol(_ name: String) -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: 40, weight: .semibold)
        return UIImage(systemName: name, withConfiguration: config) ?? UIImage()
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_CH")
        f.dateFormat = "HH:mm"
        return f
    }()
}
