import EventKit
import Foundation

/// Termin aus dem Gerätekalender (nur lokal ausgewertet).
struct CalendarAppointment {
    var title: String
    var location: String?
    var start: Date
    var end: Date
    var lat: Double?
    var lon: Double?
}

/// Liest Termine aus EventKit – nur lesend und nur mit Vollzugriff (iOS 17).
/// Kalenderinhalte verlassen das Gerät nicht; höchstens der Termintitel als Zweckvorschlag.
@MainActor
final class CalendarMatcher {
    private var eventStore = EKEventStore()

    static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Fragt einmalig nach Vollzugriff (nur wenn noch nicht entschieden).
    @discardableResult
    func requestAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return true
        case .notDetermined:
            let granted = (try? await eventStore.requestFullAccessToEvents()) ?? false
            if granted { eventStore = EKEventStore() }   // frische Instanz sieht die Kalender sicher
            return granted
        default:
            return false
        }
    }

    /// Termine mit Ort, die das Intervall überlappen (ohne Ganztagestermine).
    func appointments(from: Date, to: Date) -> [CalendarAppointment] {
        guard Self.isAuthorized, to > from else { return [] }
        let predicate = eventStore.predicateForEvents(withStart: from, end: to, calendars: nil)
        return eventStore.events(matching: predicate).compactMap { event -> CalendarAppointment? in
            guard !event.isAllDay, let start = event.startDate, let end = event.endDate else { return nil }
            let location = event.location?.nilIfEmpty
            let geo = event.structuredLocation?.geoLocation
            guard location != nil || geo != nil else { return nil }
            let title = (event.title ?? "").trimmed
            return CalendarAppointment(title: title, location: location, start: start, end: end,
                                       lat: geo?.coordinate.latitude, lon: geo?.coordinate.longitude)
        }
    }
}
