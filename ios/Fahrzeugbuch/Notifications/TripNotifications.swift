import Foundation
import UserNotifications

/// Mitteilungen des Fahrtenbuchs (U2) und zentraler `UNUserNotificationCenterDelegate`.
///
/// - (a) Manuell gestartete Fahrt steht 10 min still → „Fahrt beenden?“ (Aktion „Beenden“).
/// - (b) Automatisch erkannte Fahrt gespeichert → „18 km erkannt“ mit Aktionen „Geschäftlich“/„Privat“
///   (bestätigt mit der Kategorie; Tippen öffnet das Review).
/// - (c) Wöchentliche Erinnerung (So 18:00) an offene Bestätigungen.
/// - (d) Hinweis aus CarPlay (CarPlay zeigt nur Kurzmeldungen; Details/Handlung hier auf dem iPhone).
/// - Aktionen «Fahrt beenden», «Geschäftlich», «Privat» verlangen Entsperren (`.authenticationRequired`, I2):
///   steuerrelevante Daten nicht am gesperrten iPhone setzbar.
///
/// Registrierung: `TripNotifications.shared.register()` früh beim Start (in `TripCoordinator.configure`
/// und im `AppDelegate`), damit auch Aktionen nach einem Kaltstart ankommen.
/// Datenschutz: Inhalte nur mit km, Uhrzeit und ggf. Ortsnamen (nie im Privatmodus).
@MainActor
final class TripNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TripNotifications()

    enum Category {
        static let idle = "fzb.trip.idle"
        static let detected = "fzb.trip.detected"
        static let review = "fzb.trip.review"
        static let info = "fzb.trip.info"
    }

    enum Action {
        static let stop = "fzb.action.stop"
        static let business = "fzb.action.business"
        static let personal = "fzb.action.private"
    }

    enum Identifier {
        static let prefix = "fzb-trip-"
        static let idle = "fzb-trip-idle"
        static let weekly = "fzb-trip-weekly"
        static let info = "fzb-trip-info"
        static func detected(_ tripId: String) -> String { "fzb-trip-detected-\(tripId)" }
    }

    private enum Key {
        static let tripId = "tripId"
        static let tenant = "tenant"
        static let vehicleId = "vehicleId"
    }

    private var registered = false

    /// Delegate und Kategorien setzen (idempotent).
    func register() {
        guard !registered else { return }
        registered = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Nur entsperrt ausführbar (I2): Fahrtende und Kategorie sind steuerrelevant
        let stop = UNNotificationAction(identifier: Action.stop, title: "Fahrt beenden",
                                        options: [.authenticationRequired])
        let business = UNNotificationAction(identifier: Action.business, title: "Geschäftlich",
                                            options: [.authenticationRequired])
        let personal = UNNotificationAction(identifier: Action.personal, title: "Privat",
                                            options: [.authenticationRequired])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.idle, actions: [stop], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.detected, actions: [business, personal], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.review, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.info, actions: [], intentIdentifiers: []),
        ])
    }

    // MARK: Planen

    /// (a) Manuelle Fahrt steht still.
    func notifyIdle(vehicleName: String?) async {
        guard await isAllowed() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Fahrt beenden?"
        content.body = "Seit 10 Minuten keine Bewegung" + (vehicleName.map { " (\($0))" } ?? "")
            + ". Läuft die Aufzeichnung noch?"
        content.sound = .default
        content.categoryIdentifier = Category.idle
        content.threadIdentifier = "fzb-trip"
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Identifier.idle, content: content, trigger: nil))
    }

    /// (d) Details zu einer CarPlay-Aktion aufs iPhone (CarPlay zeigt nur die Kurzmeldung, U4).
    /// Tippen öffnet das Review offener Fahrten.
    func notifyInfo(title: String, body: String) async {
        guard await isAllowed() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        content.categoryIdentifier = Category.info
        content.threadIdentifier = "fzb-trip"
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Identifier.info, content: content, trigger: nil))
    }

    /// Stillstands-Mitteilung zurückziehen (Fahrt beendet oder wieder in Bewegung).
    func clearIdle() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Identifier.idle])
        center.removeDeliveredNotifications(withIdentifiers: [Identifier.idle])
    }

    /// (b) Automatisch erkannte Fahrt: „18 km erkannt“ mit Geschäftlich/Privat.
    func notifyDetected(_ trip: Trip, tenant: String, route: String?) async {
        guard trip.status != "confirmed", trip.status != "locked", await isAllowed() else { return }
        let km = trip.distanceKm ?? trip.distanceGps ?? 0
        let content = UNMutableNotificationContent()
        content.title = "\(Self.kmText(km)) erkannt"
        var parts: [String] = []
        if let start = trip.startDate {
            parts.append(Self.timeFormatter.string(from: start)
                         + (trip.endDate.map { "–" + Self.timeFormatter.string(from: $0) } ?? ""))
        }
        if !trip.privateMode, let route { parts.append(route) }
        if let s = trip.suggestionCategory, s != TripCategory.unknown.rawValue {
            parts.append("Vorschlag: \(TripCategory.of(s).label)")
        }
        content.body = (parts.isEmpty ? "" : parts.joined(separator: " · ") + ". ") + "Geschäftlich oder privat?"
        content.sound = .default
        content.categoryIdentifier = trip.privateMode ? Category.review : Category.detected
        content.threadIdentifier = "fzb-trip"
        content.userInfo = [Key.tripId: trip.id, Key.tenant: tenant, Key.vehicleId: trip.vehicleId]
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Identifier.detected(trip.id), content: content, trigger: nil))
    }

    /// (c) Wöchentliche Erinnerung (Sonntag 18:00) – nur solange Fahrten offen sind.
    func refreshWeeklyReminder(openCount: Int, tenant: String?) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Identifier.weekly])
        guard openCount > 0, await isAllowed() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Fahrten bestätigen"
        content.body = openCount == 1 ? "1 Fahrt wartet auf deine Bestätigung."
            : "\(openCount) Fahrten warten auf deine Bestätigung."
        content.sound = .default
        content.categoryIdentifier = Category.review
        content.threadIdentifier = "fzb-trip"
        if let tenant { content.userInfo = [Key.tenant: tenant] }
        var when = DateComponents()
        when.weekday = 1   // Sonntag (gregorianisch)
        when.hour = 18
        when.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: true)
        try? await center.add(UNNotificationRequest(identifier: Identifier.weekly, content: content, trigger: trigger))
    }

    /// Alle Fahrt-Mitteilungen entfernen (Abmelden).
    func removeAll() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Identifier.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
            .filter { $0.hasPrefix(Identifier.prefix) }
        center.removeDeliveredNotifications(withIdentifiers: delivered)
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Auch im Vordergrund anzeigen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                            @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        let info = response.notification.request.content.userInfo
        let tripId = info[Key.tripId] as? String
        let tenant = info[Key.tenant] as? String
        let vehicleId = info[Key.vehicleId] as? String
        let done = UncheckedBox(completionHandler)
        Task { @MainActor in
            await TripNotifications.shared.handle(action: action, category: category, tripId: tripId,
                                                  tenant: tenant, vehicleId: vehicleId)
            done.value()
        }
    }

    /// Aktion verarbeiten (auch für Tests/Kurzbefehle aufrufbar).
    func handle(action: String, category: String, tripId: String?, tenant: String?, vehicleId: String?) async {
        let coordinator = TripCoordinator.shared
        switch action {
        case Action.stop:
            clearIdle()
            _ = await coordinator.stop()
        case Action.business:
            if let tripId { await coordinator.classifyFromNotification(tripId: tripId, tenant: tenant, as: .business) }
        case Action.personal:
            if let tripId { await coordinator.classifyFromNotification(tripId: tripId, tenant: tenant, as: .personal) }
        case UNNotificationDefaultActionIdentifier:
            if category == Category.detected || category == Category.review || category == Category.info {
                AppRouter.shared.pending = .review(vehicleId: vehicleId)
            }
        default:
            break
        }
    }

    // MARK: Hilfen

    private func isAllowed() async -> Bool {
        let s = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return s == .authorized || s == .provisional || s == .ephemeral
    }

    static func kmText(_ km: Double) -> String {
        let rounded = km >= 10 ? km.rounded() : (km * 10).rounded() / 10
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return "\(text) km"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_CH")
        f.dateFormat = "HH:mm"
        return f
    }()
}

/// Übergibt einen nicht-Sendable Completion-Handler an den Main-Actor.
private final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
