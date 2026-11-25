import Foundation
import UserNotifications

/// Lokale Erinnerungen für datumsbasierte Fälligkeiten (14 Tage vorher und am Stichtag, 09:00).
/// Plant nur, wenn Mitteilungen bereits erlaubt sind (fragt selbst nicht nach).
/// Kilometer-Fälligkeiten werden in der App angezeigt (ohne Hintergrundbetrieb nicht planbar).
enum DueNotifications {
    private static let prefix = "fzb-due-"

    @MainActor
    static func reschedule(_ store: TenantStore) async {
        #if DEBUG
        if Demo.isActive { return }
        #endif
        let center = UNUserNotificationCenter.current()
        let items = store.dueItems.filter { $0.item.nextDueDate != nil }
        let pending = await center.pendingNotificationRequests()
        let mine = "\(prefix)\(store.tenant.slug)-"
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(mine) })
        guard !items.isEmpty else { return }
        // Keine unvermittelte Abfrage beim Öffnen der Liste (U8): Berechtigung wird über
        // `TripCoordinator.requestNotifications()` (Einrichtung/Einstellungen) erteilt.
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }

        let cal = Calendar.current
        for (vehicle, item) in items {
            guard let due = item.nextDueDate else { continue }
            for (offset, label) in [(-14, "in 14 Tagen fällig"), (0, "heute fällig")] {
                // Vergangene Termine nicht planen – Überfälliges zeigt die App selbst an
                guard let day = cal.date(byAdding: .day, value: offset, to: due),
                      let fire = cal.date(bySettingHour: 9, minute: 0, second: 0, of: day),
                      fire > Date() else { continue }
                let content = UNMutableNotificationContent()
                content.title = "\(item.title) – \(vehicle.name)"
                content.body = "\(label) (\(Fmt.day(due)))"
                content.sound = .default
                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire), repeats: false)
                let id = "\(mine)\(item.id)-\(offset)"
                try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            }
        }
    }
}
