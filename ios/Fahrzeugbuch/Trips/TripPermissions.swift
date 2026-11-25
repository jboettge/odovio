import AVFoundation
import CoreLocation
import CoreMotion
import EventKit
import Foundation
import UserNotifications

/// Stand der Berechtigungen für die Einrichtung/Einstellungen (Texte für die Anzeige).
/// Standort: „nie“ (noch nicht gefragt) · „beim Verwenden“ · „immer“ · „abgelehnt“.
/// Übrige: „nie“ (noch nicht gefragt) · „erlaubt“ · „abgelehnt“ (inkl. eingeschränkt/nicht verfügbar).
struct PermissionStatus: Equatable {
    static let notAsked = "nie"
    static let whenInUse = "beim Verwenden"
    static let always = "immer"
    static let granted = "erlaubt"
    static let denied = "abgelehnt"

    var location: String
    var motion: String
    var calendar: String
    var notifications: String
    var camera: String

    /// Aktueller Stand (Standort vom `LocationAuthorizer` des Coordinators).
    static func current(location: CLAuthorizationStatus) async -> PermissionStatus {
        let notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return PermissionStatus(location: Self.location(location),
                                motion: Self.motion(CMMotionActivityManager.authorizationStatus()),
                                calendar: Self.calendar(EKEventStore.authorizationStatus(for: .event)),
                                notifications: Self.notifications(notifications),
                                camera: Self.camera(AVCaptureDevice.authorizationStatus(for: .video)))
    }

    var locationGranted: Bool { location == Self.whenInUse || location == Self.always }
    /// Voraussetzungen der automatischen Erkennung (Standort „Immer“ + Bewegung) erfüllt
    var automaticReady: Bool { location == Self.always && motion == Self.granted }

    static func location(_ s: CLAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: notAsked
        case .authorizedWhenInUse: whenInUse
        case .authorizedAlways: always
        default: denied
        }
    }

    static func motion(_ s: CMAuthorizationStatus) -> String {
        guard CMMotionActivityManager.isActivityAvailable() else { return denied }
        switch s {
        case .notDetermined: return notAsked
        case .authorized: return granted
        default: return denied
        }
    }

    static func calendar(_ s: EKAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: notAsked
        case .fullAccess: granted
        default: denied   // u. a. „nur hinzufügen“ reicht zum Lesen nicht
        }
    }

    static func notifications(_ s: UNAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: notAsked
        case .authorized, .provisional, .ephemeral: granted
        default: denied
        }
    }

    static func camera(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: notAsked
        case .authorized: granted
        default: denied
        }
    }
}

enum CameraPermission {
    static func request() async -> Bool {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else {
            return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        }
        return await AVCaptureDevice.requestAccess(for: .video)
    }
}

enum NotificationPermission {
    /// Fragt nur, wenn noch nicht entschieden; Rückgabe: Mitteilungen erlaubt.
    @discardableResult
    static func request() async -> Bool {
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional || status == .ephemeral
    }
}

/// Standortberechtigung anfragen und auf die Antwort warten.
@MainActor
final class LocationAuthorizer: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiters: [UUID: (before: CLAuthorizationStatus, continuation: CheckedContinuation<CLAuthorizationStatus, Never>)] = [:]

    override init() {
        super.init()
        manager.delegate = self
    }

    var status: CLAuthorizationStatus { manager.authorizationStatus }

    var isAuthorized: Bool { status == .authorizedAlways || status == .authorizedWhenInUse }

    /// Dialog „Beim Verwenden der App“ (nur wenn noch nicht entschieden).
    func requestWhenInUse(timeout: TimeInterval = 120) async -> CLAuthorizationStatus {
        guard status == .notDetermined else { return status }
        return await wait(timeout: timeout) { $0.requestWhenInUseAuthorization() }
    }

    /// Upgrade auf „Immer“ (iOS zeigt den Dialog höchstens einmal).
    func requestAlways(timeout: TimeInterval = 30) async -> CLAuthorizationStatus {
        guard status == .authorizedWhenInUse || status == .notDetermined else { return status }
        return await wait(timeout: timeout) { $0.requestAlwaysAuthorization() }
    }

    private func wait(timeout: TimeInterval, request: (CLLocationManager) -> Void) async -> CLAuthorizationStatus {
        let id = UUID()
        let before = manager.authorizationStatus
        return await withCheckedContinuation { (continuation: CheckedContinuation<CLAuthorizationStatus, Never>) in
            waiters[id] = (before, continuation)
            request(manager)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 1) * 1_000_000_000))
                self?.finish(id)
            }
        }
    }

    private func finish(_ id: UUID) {
        guard let w = waiters.removeValue(forKey: id) else { return }
        w.continuation.resume(returning: manager.authorizationStatus)
    }

    private func authorizationChanged() {
        let now = manager.authorizationStatus
        for (id, w) in waiters where w.before != now {
            finish(id)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.authorizationChanged() }
    }
}

enum MotionPermission {
    static var isAuthorized: Bool {
        CMMotionActivityManager.authorizationStatus() == .authorized
    }

    /// Eine kurze Abfrage der Aktivitäts-Historie löst den Dialog „Bewegung & Fitness“ aus.
    static func request() async {
        guard CMMotionActivityManager.isActivityAvailable(),
              CMMotionActivityManager.authorizationStatus() == .notDetermined else { return }
        let manager = CMMotionActivityManager()
        let now = Date()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            manager.queryActivityStarting(from: now.addingTimeInterval(-60), to: now,
                                          to: OperationQueue.main) { _, _ in
                _ = manager   // bis zur Antwort am Leben halten
                continuation.resume()
            }
        }
    }
}
