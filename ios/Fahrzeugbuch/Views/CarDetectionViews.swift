import SwiftUI
import UIKit

/// Knopf «Einstellungen öffnen» (iOS-Einstellungen der App «odovio»).
struct OpenSystemSettingsButton: View {
    var title = "Einstellungen öffnen"

    var body: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        } label: {
            Label(title, systemImage: "gear")
        }
    }
}

/// Standardfahrzeug für Automatik, Siri/Kurzbefehle und CarPlay (Q3). Ohne Wahl gilt nur ein einziges
/// Fahrzeug automatisch – bei mehreren startet nichts, statt das falsche Fahrzeug zu buchen.
struct DefaultVehiclePicker: View {
    let store: TenantStore
    @State private var selection: String?
    @State private var loaded = false

    var body: some View {
        let vehicles = store.vehicleList
        Picker(selection: $selection) {
            Text("Nicht festgelegt").tag(String?.none)
            ForEach(vehicles) { v in
                Text(v.name).tag(Optional(v.id))
            }
        } label: {
            Label("Standardfahrzeug", systemImage: "car")
        }
        .onAppear {
            selection = store.explicitDefaultVehicleId
            loaded = true
        }
        .onChange(of: selection) { _, value in
            guard loaded else { return }
            store.defaultVehicleId = value
        }
        if selection == nil && vehicles.count > 1 {
            Label("Für Automatik, Siri und CarPlay ein Standardfahrzeug wählen – sonst startet keine Fahrt "
                  + "automatisch.", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(Color.warningText)
        }
    }
}

/// «Auto erkennen über»: CarPlay und/oder Bluetooth-Gerät(e), unabhängig wählbar. Mit Auto-Erkennung startet die Automatik nur,
/// wenn CoreMotion «im Auto» meldet UND CarPlay bzw. ein gelerntes Gerät verbunden ist (weniger Fehlalarme in
/// Zug/Tram/Bus); beim Verbinden startet sie direkt, beim Trennen endet die automatische Fahrt nach 2 min.
struct CarDetectionSettingsView: View {
    let store: TenantStore
    @Environment(TripCoordinator.self) private var coordinator
    @State private var car = CarConnectionMonitor.shared
    @State private var message: String?
    @State private var routeNames: [String] = []

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $car.mode.useCarPlay) {
                    Label("CarPlay", systemImage: "carplay")
                }
                Toggle(isOn: $car.mode.useBluetooth) {
                    Label("Bluetooth (Autoradio, Freisprecher)", systemImage: "dot.radiowaves.left.and.right")
                }
            } header: {
                Text("Auto erkennen über")
            } footer: {
                Text(modeFooter)
            }

            if car.mode.useCarPlay {
                carPlaySection
            }
            if car.mode.useBluetooth {
                bluetoothSections
            }

            Section {
                Text("iOS weckt Apps nicht, wenn sich ein Bluetooth-Gerät oder CarPlay verbindet. Zuverlässig "
                     + "ergänzend: App «Kurzbefehle» › Automation › «CarPlay» bzw. «Bluetooth» (dein Auto) › "
                     + "«Verbindet» → Aktion «Fahrt starten» (odovio), und «Trennt» → «Fahrt beenden».")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if !coordinator.autoDetectEnabled {
                    Label("Die automatische Erkennung ist ausgeschaltet – die Auto-Erkennung wirkt erst, wenn "
                          + "«Fahrten automatisch erkennen» an ist.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Kurzbefehle-Automation")
            }
        }
        .navigationTitle("Auto erkennen")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reloadRoute() }
    }

    private var modeFooter: String {
        switch (car.mode.useCarPlay, car.mode.useBluetooth) {
        case (false, false):
            "Beides aus: Fahrten starten, sobald «Bewegung & Fitness» eine Autofahrt erkennt – auch in Zug, Tram "
                + "oder Bus."
        case (true, false):
            "Automatik nur mit verbundenem CarPlay. Ist die odovio-Oberfläche in CarPlay geöffnet, startet die "
                + "Fahrt beim Verbinden und endet beim Trennen (nach 2 min Karenz, z. B. Tankstopp). Autos ohne "
                + "CarPlay: zusätzlich Bluetooth einschalten."
        case (false, true):
            "Automatik nur, wenn ein gelerntes Bluetooth-Gerät (Autoradio, Freisprecher) verbunden ist. Trennen "
                + "beendet die automatische Fahrt nach 2 min Karenz (z. B. Tankstopp)."
        case (true, true):
            "Automatik, wenn CarPlay oder ein gelerntes Bluetooth-Gerät verbunden ist – so funktioniert sie auch "
                + "in Autos ohne CarPlay. Trennen beendet die automatische Fahrt nach 2 min Karenz (z. B. Tankstopp)."
        }
    }

    private var vehicleChoices: [Vehicle] { store.vehicleList }

    @ViewBuilder
    private var carPlaySection: some View {
        Section {
            Picker(selection: $car.carPlayVehicleId) {
                Text("Standardfahrzeug").tag(String?.none)
                ForEach(vehicleChoices) { v in
                    Text(v.name).tag(Optional(v.id))
                }
            } label: {
                Label("Fahrzeug für CarPlay", systemImage: "car")
            }
            LabeledContent("Jetzt", value: car.current?.kind == .carPlayRoute || car.carPlaySceneConnected
                           ? "CarPlay verbunden" : "CarPlay nicht verbunden")
        } header: {
            Text("CarPlay")
        }
    }

    @ViewBuilder
    private var bluetoothSections: some View {
        Section {
            if car.devices.isEmpty {
                Text("Noch kein Gerät gelernt.")
                    .foregroundStyle(.secondary)
            }
            ForEach(car.devices) { device in
                Picker(selection: Binding(
                    get: { device.vehicleId },
                    set: { car.assign(vehicleId: $0, to: device.id) })) {
                    Text("Standardfahrzeug").tag(String?.none)
                    ForEach(vehicleChoices) { v in
                        Text(v.name).tag(Optional(v.id))
                    }
                } label: {
                    Label(device.name, systemImage: car.current?.deviceKey == device.id
                          ? "dot.radiowaves.left.and.right" : "car")
                }
            }
            .onDelete { offsets in car.removeDevices(at: offsets) }
        } header: {
            Text("Gelernte Geräte")
        } footer: {
            Text("Je Gerät optional ein Fahrzeug: Die Automatik bucht dann auf dieses Fahrzeug. Wischen zum Entfernen.")
        }
        Section {
            Button {
                message = car.learnCurrentDevice()
                reloadRoute()
            } label: {
                Label("Aktuell verbundenes Gerät als Auto übernehmen", systemImage: "plus.circle")
            }
            LabeledContent("Verbunden", value: routeNames.isEmpty ? "kein Bluetooth-Audiogerät" : routeNames.joined(separator: ", "))
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Text("Im Auto mit dem Autoradio bzw. Freisprecher verbunden sein (Musik oder Anruf nicht nötig). "
                 + "Gelesen werden nur Name und Kennung des Audiogeräts – keine Bluetooth-Berechtigung nötig.")
        }
    }

    private func reloadRoute() {
        routeNames = car.learnableNow().map { $0.name.isEmpty ? "Audiogerät" : $0.name }
        car.refresh(emit: false)
    }
}
