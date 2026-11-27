import CarPlay
import Observation
import UIKit

/// CarPlay („Driving Task“-App): ein Raster mit drei Kacheln – Fahrt starten, Fahrt beenden, Tanken.
///
/// - Start/Stopp nutzen dieselben Wege wie Siri/Kurzbefehle (`startFromIntent`/`stopFromIntent`, Standardfahrzeug).
/// - CarPlay erlaubt keine Texteingabe: «Tanken» merkt den Tankvorgang nur vor (Mitteilung + Formular beim
///   nächsten Öffnen auf dem iPhone); Liter/Betrag werden dort erfasst.
/// - Voraussetzung auf dem Gerät: CarPlay-Berechtigung `com.apple.developer.carplay-driving-task` (von Apple
///   freizuschalten, siehe docs/TESTFLIGHT.md). Im Simulator genügt die Debug-Entitlement-Datei.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var grid: CPGridTemplate?
    private var busy = false

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let grid = CPGridTemplate(title: "odovio", gridButtons: buttons())
        self.grid = grid
        interfaceController.setRootTemplate(grid, animated: false, completion: nil)
        observeRecording()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
        grid = nil
    }

    // MARK: Kacheln

    private func buttons() -> [CPGridButton] {
        let recording = TripCoordinator.shared.isRecording
        let start = CPGridButton(titleVariants: ["Fahrt starten", "Start"],
                                 image: Self.symbol("play.circle.fill")) { [weak self] _ in
            self?.startTrip()
        }
        start.isEnabled = !recording && !busy
        let stop = CPGridButton(titleVariants: ["Fahrt beenden", "Stopp"],
                                image: Self.symbol("stop.circle.fill")) { [weak self] _ in
            self?.stopTrip()
        }
        stop.isEnabled = recording && !busy
        let fuel = CPGridButton(titleVariants: ["Tanken"], image: Self.symbol("fuelpump.circle.fill")) { [weak self] _ in
            self?.noteFuel()
        }
        fuel.isEnabled = !busy
        return [start, stop, fuel]
    }

    private func refresh() {
        grid?.updateGridButtons(buttons())
    }

    /// Kacheln aktualisieren, wenn sich die Aufzeichnung ändert (auch über iPhone, Siri, Automatik).
    private func observeRecording() {
        withObservationTracking {
            _ = TripCoordinator.shared.isRecording
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.interfaceController != nil else { return }
                self.refresh()
                self.observeRecording()
            }
        }
    }

    // MARK: Aktionen

    private func startTrip() {
        run { await TripCoordinator.shared.startFromIntent(privateMode: false) }
    }

    private func stopTrip() {
        run { await TripCoordinator.shared.stopFromIntent() }
    }

    private func noteFuel() {
        run {
            let vehicle = await TripCoordinator.shared.defaultVehicleSummary()
            AppRouter.shared.pending = .addFuel(vehicleId: vehicle?.id)
            await TripNotifications.shared.notifyFuelReminder(vehicleId: vehicle?.id, vehicleName: vehicle?.name)
            return "Tankvorgang vorgemerkt. Liter und Betrag danach auf dem iPhone erfassen."
        }
    }

    private func run(_ action: @escaping @MainActor () async -> String) {
        guard !busy else { return }
        busy = true
        refresh()
        Task { @MainActor in
            let message = await action()
            busy = false
            refresh()
            showMessage(message)
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
}
