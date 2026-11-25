import CoreLocation
import CoreMotion
import Foundation

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
