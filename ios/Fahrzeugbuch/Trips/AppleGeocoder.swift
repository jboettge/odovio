import CoreLocation
import Foundation

/// Lokalmodus (optional, `AppSettings.useAppleGeocoding`): Start/Ziel über Apples Geocoding statt über den
/// eigenen Server. Übermittelt wird nur die gerundete Koordinate; übernommen werden höchstens Strasse
/// (ohne Hausnummer) und Gemeinde. Wohnort-Regeln gelten unverändert (Aufrufer übergibt dort keinen Punkt).
@MainActor
enum AppleGeocoder {
    static func reverse(_ point: TrackPoint?, roundingMeters: Double) async -> GeoClient.ReverseResult? {
        guard let point else { return nil }
        let r = GeoMath.rounded(lat: point.lat, lon: point.lon, meters: roundingMeters)
        let geocoder = CLGeocoder()
        guard let mark = try? await geocoder.reverseGeocodeLocation(
            CLLocation(latitude: r.lat, longitude: r.lon), preferredLocale: Locale(identifier: "de_CH")).first
        else { return nil }
        let municipality = mark.locality?.nilIfEmpty ?? mark.subAdministrativeArea?.nilIfEmpty
        let street = mark.thoroughfare?.nilIfEmpty
        let label = [street, municipality].compactMap { $0 }.joined(separator: ", ").nilIfEmpty
        return GeoClient.ReverseResult(label: label, municipality: municipality, country: mark.isoCountryCode)
    }
}
