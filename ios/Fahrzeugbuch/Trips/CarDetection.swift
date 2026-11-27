import AVFoundation
import Foundation
import Observation

/// Wie die Automatik erkennt, dass man im (eigenen) Auto sitzt.
enum CarDetectionMode: String, Codable, CaseIterable, Identifiable {
    /// Nur CoreMotion «automotive» (auch Zug/Tram/Bus lösen aus)
    case off
    /// Zusätzlich CarPlay verbunden (CarPlay-Szene oder Audio-Route `.carAudio`)
    case carPlay
    /// Zusätzlich ein gelerntes Bluetooth-Audiogerät (Freisprecher/Autoradio) in der Audio-Route
    case bluetooth

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "Aus"
        case .carPlay: "CarPlay"
        case .bluetooth: "Bluetooth-Gerät(e)"
        }
    }
}

/// Gelerntes Auto-Audiogerät (Bluetooth/CarPlay-Audio), optional einem Fahrzeug zugeordnet.
struct CarDevice: Codable, Hashable, Identifiable {
    /// `AVAudioSessionPortDescription.uid` beim Lernen
    var uid: String
    var name: String
    /// Fahrzeug für die Automatik; `nil` = Standardfahrzeug
    var vehicleId: String?

    var id: String { CarRouteMatcher.deviceKey(uid: uid, name: name) }
}

/// Ausgang der aktuellen Audio-Route (wertbasiert, testbar ohne `AVAudioSession`).
struct AudioPortInfo: Equatable {
    /// `AVAudioSession.Port.rawValue`
    var type: String
    var uid: String
    var name: String
}

/// Erkannte Verbindung zum Auto.
struct CarConnection: Equatable {
    enum Kind: String {
        /// CarPlay-Oberfläche der App verbunden (`CPTemplateApplicationScene`)
        case carPlayScene
        /// CarPlay-Audio in der Route (`.carAudio`)
        case carPlayRoute
        /// Gelerntes Bluetooth-Gerät in der Route
        case bluetooth
    }

    var kind: Kind
    var name: String
    /// Schlüssel des gelernten Geräts (nur `.bluetooth`)
    var deviceKey: String?
    /// Zugeordnetes Fahrzeug (Gerät bzw. «Fahrzeug für CarPlay»); `nil` = Standardfahrzeug
    var vehicleId: String?
}

/// Reine Abgleichslogik Audio-Route ↔ gelernte Geräte (Unit-Tests ohne Hardware).
enum CarRouteMatcher {
    /// Ports, die als «Auto» gelernt werden können
    static let carPortTypes: Set<String> = [
        AVAudioSession.Port.bluetoothA2DP.rawValue,
        AVAudioSession.Port.bluetoothHFP.rawValue,
        AVAudioSession.Port.bluetoothLE.rawValue,
        AVAudioSession.Port.carAudio.rawValue,
    ]
    static let carPlayPortType = AVAudioSession.Port.carAudio.rawValue

    /// Vergleichsschlüssel eines Geräts. Bluetooth-UIDs tragen je Profil eine Endung
    /// (z. B. `00:11:22:33:44:55-tacl` für A2DP, `…-tsco` für HFP) → nur die Adresse vergleichen.
    /// Ohne UID: Name (klein geschrieben).
    static func deviceKey(uid: String, name: String) -> String {
        let trimmed = uid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "name:" + name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if let dash = trimmed.firstIndex(of: "-") {
            let head = String(trimmed[..<dash])
            if head.contains(":") { return head }
        }
        return trimmed
    }

    /// Ausgänge, die als Auto übernommen werden können (Bluetooth, CarPlay-Audio).
    static func learnable(_ outputs: [AudioPortInfo]) -> [AudioPortInfo] {
        outputs.filter { carPortTypes.contains($0.type) }
    }

    static func isCarPlayRoute(_ outputs: [AudioPortInfo]) -> Bool {
        outputs.contains { $0.type == carPlayPortType }
    }

    /// Gelerntes Gerät in der Route?
    static func matchingDevice(_ outputs: [AudioPortInfo], devices: [CarDevice]) -> (CarDevice, AudioPortInfo)? {
        for output in learnable(outputs) {
            let key = deviceKey(uid: output.uid, name: output.name)
            if let device = devices.first(where: { $0.id == key }) { return (device, output) }
        }
        return nil
    }

    /// Aktuelle Verbindung zum Auto gemäss Einstellung. Eine verbundene CarPlay-Szene zählt immer.
    static func connection(mode: CarDetectionMode, outputs: [AudioPortInfo], devices: [CarDevice],
                           carPlaySceneConnected: Bool, carPlayVehicleId: String?) -> CarConnection? {
        if carPlaySceneConnected {
            return CarConnection(kind: .carPlayScene, name: "CarPlay", deviceKey: nil, vehicleId: carPlayVehicleId)
        }
        switch mode {
        case .off:
            return nil
        case .carPlay:
            guard let port = outputs.first(where: { $0.type == carPlayPortType }) else { return nil }
            return CarConnection(kind: .carPlayRoute, name: port.name.isEmpty ? "CarPlay" : port.name,
                                 deviceKey: nil, vehicleId: carPlayVehicleId)
        case .bluetooth:
            guard let match = matchingDevice(outputs, devices: devices) else { return nil }
            let (device, port) = match
            return CarConnection(kind: .bluetooth, name: port.name.isEmpty ? device.name : port.name,
                                 deviceKey: device.id, vehicleId: device.vehicleId)
        }
    }

    /// Start der Automatik auf «automotive» (CoreMotion): ohne Auto-Erkennung immer, sonst nur verbunden.
    static func motionStartAllowed(mode: CarDetectionMode, connection: CarConnection?) -> Bool {
        mode == .off || connection != nil
    }

    /// Start direkt beim Verbinden (Routenwechsel, CarPlay-Szene), wenn CoreMotion nicht widerspricht
    /// (zu Fuss unterwegs = z. B. Garage neben dem Haus, Auto nur in Funkreichweite).
    static func connectStartAllowed(mode: CarDetectionMode, connection: CarConnection?,
                                    latestMotion: MotionSample?) -> Bool {
        guard let connection else { return false }
        if connection.kind == .carPlayScene { return true }
        guard mode != .off else { return false }
        return !(latestMotion?.isOnFoot ?? false)
    }
}

/// Ereignis des `CarConnectionMonitor`.
enum CarConnectionEvent {
    case connected(CarConnection)
    case disconnected(CarConnection)
}

/// Einstellung «Auto erkennen über» und Beobachtung der Audio-Route / CarPlay-Szene.
///
/// - Die Route (`AVAudioSession.sharedInstance().currentRoute`) wird bei jedem Weck-Ereignis der Automatik
///   geprüft (`connectionNow()`); `routeChangeNotification` kommt nur, solange die App läuft – iOS weckt
///   keine App, wenn sich ein Bluetooth-Gerät verbindet. Zuverlässig ergänzend: Kurzbefehle-Automation
///   «CarPlay/Bluetooth verbunden → Fahrt starten» (siehe docs/TESTFLIGHT.md).
/// - Datenschutz: Gelesen werden nur Typ, Name und UID der Audio-Ausgänge; kein CoreBluetooth, keine
///   Berechtigung und kein Usage-String nötig. Gespeichert werden nur die gelernten Geräte (UserDefaults).
@MainActor
@Observable
final class CarConnectionMonitor {
    static let shared = CarConnectionMonitor()

    var mode: CarDetectionMode {
        didSet {
            guard oldValue != mode else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode)
            refresh(emit: false)
        }
    }

    private(set) var devices: [CarDevice]

    /// Fahrzeug für CarPlay (Szene oder Route); `nil` = Standardfahrzeug
    var carPlayVehicleId: String? {
        didSet { UserDefaults.standard.set(carPlayVehicleId, forKey: Keys.carPlayVehicle) }
    }

    private(set) var carPlaySceneConnected = false
    /// Zuletzt erkannte Verbindung (für Ereignisse und Anzeige)
    private(set) var current: CarConnection?

    @ObservationIgnored var onEvent: ((CarConnectionEvent) -> Void)?
    @ObservationIgnored private var routeObserver: NSObjectProtocol?

    private enum Keys {
        static let mode = "carDetectionMode"
        static let devices = "carDetectionDevices"
        static let carPlayVehicle = "carDetectionCarPlayVehicle"
    }

    private init() {
        let defaults = UserDefaults.standard
        mode = defaults.string(forKey: Keys.mode).flatMap(CarDetectionMode.init(rawValue:)) ?? .off
        if let data = defaults.data(forKey: Keys.devices),
           let list = try? JSONDecoder().decode([CarDevice].self, from: data) {
            devices = list
        } else {
            devices = []
        }
        carPlayVehicleId = defaults.string(forKey: Keys.carPlayVehicle)
        current = nil
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in CarConnectionMonitor.shared.refresh() }
        }
        current = connectionNow()
    }

    /// Start vor der ersten Entsperrung (Q6): Modus und gelernte Geräte waren nicht lesbar → jetzt laden
    /// (ohne Ereignis; die Automatik prüft die Route beim nächsten Weck-Ereignis).
    func reloadAfterFirstUnlock() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Keys.devices),
           let list = try? JSONDecoder().decode([CarDevice].self, from: data) {
            devices = list
        }
        let storedVehicle = defaults.string(forKey: Keys.carPlayVehicle)
        if storedVehicle != carPlayVehicleId { carPlayVehicleId = storedVehicle }
        mode = defaults.string(forKey: Keys.mode).flatMap(CarDetectionMode.init(rawValue:)) ?? .off
        refresh(emit: false)
    }

    // MARK: Abfrage

    /// Ausgänge der aktuellen Audio-Route.
    func currentOutputs() -> [AudioPortInfo] {
        AVAudioSession.sharedInstance().currentRoute.outputs.map {
            AudioPortInfo(type: $0.portType.rawValue, uid: $0.uid, name: $0.portName)
        }
    }

    /// Verbindung jetzt (liest die Route neu, ohne Ereignis).
    func connectionNow() -> CarConnection? {
        CarRouteMatcher.connection(mode: mode, outputs: currentOutputs(), devices: devices,
                                   carPlaySceneConnected: carPlaySceneConnected, carPlayVehicleId: carPlayVehicleId)
    }

    /// Lernbare Geräte der aktuellen Route (Anzeige in den Einstellungen).
    func learnableNow() -> [AudioPortInfo] { CarRouteMatcher.learnable(currentOutputs()) }

    // MARK: Ereignisse

    /// Route bzw. Szene neu auswerten und bei Änderung `onEvent` melden. `emit == false`: nur den Stand
    /// nachführen (Änderungen in den Einstellungen sollen keine Fahrt starten/beenden).
    func refresh(emit: Bool = true) {
        let now = connectionNow()
        let before = current
        current = now
        guard emit else { return }
        switch (before, now) {
        case (nil, let c?):
            onEvent?(.connected(c))
        case (let b?, nil):
            onEvent?(.disconnected(b))
        case (let b?, let c?) where b.kind != c.kind || b.deviceKey != c.deviceKey:
            onEvent?(.disconnected(b))
            onEvent?(.connected(c))
        default:
            break
        }
    }

    /// CarPlay-Szene verbunden/getrennt (`CarPlaySceneDelegate`).
    func setCarPlayScene(connected: Bool) {
        guard carPlaySceneConnected != connected else { return }
        carPlaySceneConnected = connected
        refresh()
    }

    // MARK: Geräte

    /// Aktuell verbundenes Bluetooth-/CarPlay-Audiogerät als Auto übernehmen; Rückgabe = Meldung.
    @discardableResult
    func learnCurrentDevice(vehicleId: String? = nil) -> String {
        guard let port = learnableNow().first else {
            return "Kein Bluetooth- oder CarPlay-Audiogerät verbunden. Im Auto verbinden (Radio/Freisprecher an) "
                + "und erneut versuchen."
        }
        let device = CarDevice(uid: port.uid, name: port.name.isEmpty ? "Auto" : port.name, vehicleId: vehicleId)
        if devices.contains(where: { $0.id == device.id }) {
            return "«\(device.name)» ist bereits als Auto gespeichert."
        }
        devices.append(device)
        saveDevices()
        refresh(emit: false)
        return "«\(device.name)» als Auto übernommen."
    }

    func assign(vehicleId: String?, to deviceId: String) {
        guard let i = devices.firstIndex(where: { $0.id == deviceId }) else { return }
        devices[i].vehicleId = vehicleId
        saveDevices()
        refresh(emit: false)
    }

    func removeDevices(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where devices.indices.contains(index) {
            devices.remove(at: index)
        }
        saveDevices()
        refresh(emit: false)
    }

    private func saveDevices() {
        UserDefaults.standard.set(try? JSONEncoder().encode(devices), forKey: Keys.devices)
    }
}
