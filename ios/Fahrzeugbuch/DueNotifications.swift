import Foundation
import UserNotifications

/// Lokale Erinnerungen für datumsbasierte Fälligkeiten (14 Tage vorher und am Stichtag, 09:00).
/// Plant nur, wenn Mitteilungen bereits erlaubt sind (fragt selbst nicht nach).
/// Kilometer-Fälligkeiten werden in der App angezeigt (ohne Hintergrundbetrieb nicht planbar).
///
/// iOS behält höchstens 64 geplante Mitteilungen je App und verwirft weitere still (Q14). Geplant werden
/// deshalb nur die frühesten innerhalb des freien Budgets (Reserve für Fahrt-Mitteilungen); die übrigen beim
/// nächsten Neuplanen (spätestens am Folgetag beim Öffnen der Fahrzeugliste).
enum DueNotifications {
    private static let prefix = "fzb-due-"
    /// Obergrenze von iOS für geplante lokale Mitteilungen je App
    static let systemLimit = 64
    /// Reserve für Fahrt-Mitteilungen (Wochenerinnerung, Stillstand, erkannte Fahrten, Hinweise)
    static let reserved = 8

    /// Eine geplante Erinnerung.
    struct Planned: Equatable {
        var id: String
        var fire: Date
        var title: String
        var body: String
    }

    /// Freies Budget für diesen Mandanten: Grenze minus Reserve minus fremde geplante Mitteilungen.
    static func budget(otherPending: Int) -> Int {
        max(0, systemLimit - reserved - otherPending)
    }

    /// Zu planende Erinnerungen: nur künftige, die frühesten zuerst, höchstens `budget`.
    static func plan(_ candidates: [Planned], now: Date, budget: Int) -> [Planned] {
        Array(candidates.filter { $0.fire > now }.sorted { $0.fire < $1.fire }.prefix(max(0, budget)))
    }

    @MainActor
    static func reschedule(_ store: TenantStore) async {
        #if DEBUG
        if Demo.isActive { return }
        #endif
        let center = UNUserNotificationCenter.current()
        let items = store.dueItems.filter { $0.item.nextDueDate != nil }
        let pending = await center.pendingNotificationRequests()
        let mine = "\(prefix)\(store.tenant.slug)-"
        let mineIds = pending.map(\.identifier).filter { $0.hasPrefix(mine) }
        center.removePendingNotificationRequests(withIdentifiers: mineIds)
        guard !items.isEmpty else { return }
        // Keine unvermittelte Abfrage beim Öffnen der Liste (U8): Berechtigung wird über
        // `TripCoordinator.requestNotifications()` (Einrichtung/Einstellungen) erteilt.
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }

        let cal = Calendar.current
        var candidates: [Planned] = []
        for (vehicle, item) in items {
            guard let due = item.nextDueDate else { continue }
            for (offset, label) in [(-14, "in 14 Tagen fällig"), (0, "heute fällig")] {
                // Vergangene Termine nicht planen – Überfälliges zeigt die App selbst an
                guard let day = cal.date(byAdding: .day, value: offset, to: due),
                      let fire = cal.date(bySettingHour: 9, minute: 0, second: 0, of: day) else { continue }
                candidates.append(Planned(id: "\(mine)\(item.id)-\(offset)", fire: fire,
                                          title: "\(item.title) – \(vehicle.name)", body: "\(label) (\(Fmt.day(due)))"))
            }
        }
        let free = Self.budget(otherPending: pending.count - mineIds.count)
        for p in Self.plan(candidates, now: Date(), budget: free) {
            let content = UNMutableNotificationContent()
            content.title = p.title
            content.body = p.body
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: cal.dateComponents([.year, .month, .day, .hour, .minute], from: p.fire), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: p.id, content: content, trigger: trigger))
        }
    }
}
