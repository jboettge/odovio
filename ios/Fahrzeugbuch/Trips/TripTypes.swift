import CryptoKit
import Foundation

/// Vorschlag für Kategorie/Zweck einer Fahrt. Wird nie stillschweigend übernommen –
/// Ausnahme: Regel mit `autoConfirm` (pro Regel aktivierbar, im Review trotzdem sichtbar).
struct TripSuggestion: Equatable {
    var category: String
    var purpose: String?
    var customerId: String?
    var confidence: Double
    var reason: String
    /// Stufe wie Server-Feld `suggestion_source`: rule | calendar | pattern | llm
    var source: String
    /// Nur Stufe „rule“: die Regel erlaubt automatische Bestätigung
    var autoConfirm: Bool = false
    /// Nur Stufe „rule“: auslösende Regel (nachvollziehbar, warum vorgeschlagen)
    var ruleId: String? = nil
}

/// Termin aus dem Gerätekalender (nur lokal ausgewertet).
struct CalendarAppointment {
    var title: String
    var location: String?
    var start: Date
    var end: Date
    var lat: Double?
    var lon: Double?
}

/// Häufig besuchter Punkt ohne passenden Ort → Nutzer benennt ihn einmal.
struct PlaceCandidate: Identifiable, Hashable {
    var id: String
    var lat: Double
    var lon: Double
    var visits: Int
    var suggestedLabel: String?
}

/// GPS-Punkt; kompakt als Array `[lat, lon, ts, accuracy]` gespeichert (ts = Unix-Sekunden).
struct TrackPoint: Codable, Hashable {
    var lat: Double
    var lon: Double
    var ts: Double
    var accuracy: Double

    init(lat: Double, lon: Double, ts: Double, accuracy: Double) {
        self.lat = lat
        self.lon = lon
        self.ts = ts
        self.accuracy = accuracy
    }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        lat = try c.decode(Double.self)
        lon = try c.decode(Double.self)
        ts = try c.decode(Double.self)
        accuracy = try c.decode(Double.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(lat)
        try c.encode(lon)
        try c.encode(ts)
        try c.encode(accuracy)
    }

    /// Kanonische Rundung (Basis für Speicherung und Hash): 6 Nachkommastellen, ganze Sekunden, 0.1 m.
    var canonical: TrackPoint {
        TrackPoint(lat: (lat * 1e6).rounded() / 1e6, lon: (lon * 1e6).rounded() / 1e6,
                   ts: ts.rounded(), accuracy: (accuracy * 10).rounded() / 10)
    }

    /// Auf ein Raster von `meters` gerundet (Datensparsamkeit).
    func coarse(_ meters: Double) -> TrackPoint {
        let r = GeoMath.rounded(lat: lat, lon: lon, meters: meters)
        return TrackPoint(lat: r.lat, lon: r.lon, ts: ts.rounded(), accuracy: max(accuracy, meters))
    }
}

/// Ergebnis einer Aufzeichnung.
struct RecordedTrack: Codable {
    /// Douglas-Peucker-reduziert und kanonisch gerundet; im Privatmodus leer
    var points: [TrackPoint]
    var distanceKm: Double
    var startAt: Date
    var endAt: Date
    /// Erster/letzter guter Fix (im Privatmodus auf ~1 km gerundet)
    var start: TrackPoint?
    var end: TrackPoint?
    /// SHA-256 (hex) über die kanonischen Punkte; `nil` ohne Track (Privatmodus, < 2 Punkte)
    var hash: String?
    var privateMode: Bool
}

enum GeoMath {
    static let earthRadius = 6_371_000.0

    /// Haversine-Distanz in Metern.
    static func distance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180
        let p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180
        let dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earthRadius * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }

    static func distance(_ a: TrackPoint, _ b: TrackPoint) -> Double {
        distance(lat1: a.lat, lon1: a.lon, lat2: b.lat, lon2: b.lon)
    }

    /// Rundet auf ein Raster von ca. `meters` (Breiten- und Längengrad getrennt).
    static func rounded(lat: Double, lon: Double, meters: Double) -> (lat: Double, lon: Double) {
        let latStep = meters / 111_320
        let lonStep = meters / (111_320 * max(cos(lat * .pi / 180), 0.01))
        let rLat = (lat / latStep).rounded() * latStep
        let rLon = (lon / lonStep).rounded() * lonStep
        return ((rLat * 1e5).rounded() / 1e5, (rLon * 1e5).rounded() / 1e5)
    }

    /// Abstand von `p` zur Strecke a–b in Metern (lokale equirektanguläre Projektion).
    static func segmentDistance(_ p: TrackPoint, _ a: TrackPoint, _ b: TrackPoint) -> Double {
        let k = earthRadius * .pi / 180
        let cosLat = cos(a.lat * .pi / 180)
        let bx = (b.lon - a.lon) * k * cosLat
        let by = (b.lat - a.lat) * k
        let px = (p.lon - a.lon) * k * cosLat
        let py = (p.lat - a.lat) * k
        let len2 = bx * bx + by * by
        if len2 == 0 { return sqrt(px * px + py * py) }
        let t = min(1, max(0, (px * bx + py * by) / len2))
        let dx = px - t * bx
        let dy = py - t * by
        return sqrt(dx * dx + dy * dy)
    }

    /// Douglas-Peucker (iterativ); Endpunkte bleiben immer erhalten.
    static func simplify(_ points: [TrackPoint], epsilon: Double) -> [TrackPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let range = stack.popLast() {
            let first = range.0
            let last = range.1
            guard last > first + 1 else { continue }
            var maxDist = 0.0
            var index = first
            for i in (first + 1)..<last {
                let d = segmentDistance(points[i], points[first], points[last])
                if d > maxDist {
                    maxDist = d
                    index = i
                }
            }
            if maxDist > epsilon {
                keep[index] = true
                stack.append((first, index))
                stack.append((index, last))
            }
        }
        var result: [TrackPoint] = []
        result.reserveCapacity(points.count / 4)
        for i in points.indices where keep[i] { result.append(points[i]) }
        return result
    }

    /// Kanonische Textform: eine Zeile je Punkt `lat,lon,ts,accuracy` (POSIX-Zahlenformat).
    static func canonicalData(_ points: [TrackPoint]) -> Data {
        var s = ""
        s.reserveCapacity(points.count * 40)
        for raw in points {
            let p = raw.canonical
            s += String(format: "%.6f,%.6f,", p.lat, p.lon)
            s += String(Int64(p.ts))
            s += String(format: ",%.1f\n", p.accuracy)
        }
        return Data(s.utf8)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Zeitpunkte der Fahrten (ISO-8601 mit Offset) lesen – zentral über `ISODate`.
enum TripTime {
    static func parse(_ s: String) -> Date? { ISODate.parse(s) }

    /// "yyyy-MM" eines Tagesdatums in Gerätezeit (Tanken, km-Stand, Wartung: Datum ohne Uhrzeit).
    /// Fahrten (Zeitpunkte) immer über `LogbookRules.month` bzw. `Trip.monthKey` zuordnen (Q12).
    static func month(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: d)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// ISO-Wochentag: 1 = Montag … 7 = Sonntag
    static func isoWeekday(_ d: Date, calendar: Calendar = .current) -> Int {
        let wd = calendar.component(.weekday, from: d)   // 1 = Sonntag
        return ((wd + 5) % 7) + 1
    }

    /// Minuten seit Mitternacht (lokal)
    static func minuteOfDay(_ d: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// "HH:MM" → Minuten
    static func minutes(_ hhmm: String?) -> Int? {
        guard let hhmm else { return nil }
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    static func hhmm(_ minutes: Int) -> String {
        let m = min(max(minutes, 0), 23 * 60 + 59)
        return String(format: "%02d:%02d", m / 60, m % 60)
    }
}

enum TripCategoryText {
    static let all = ["business", "private", "commute", "field"]

    static func label(_ c: String) -> String {
        switch c {
        case "business": "geschäftlich"
        case "private": "privat"
        case "commute": "Arbeitsweg"
        case "field": "Aussendienst"
        default: "unbekannt"
        }
    }
}

/// Datenschutz für Geodienste (S2): Wohnort und die ersten/letzten Meter einer Fahrt verlassen das Gerät nicht.
enum GeoPrivacy {
    /// Anfang und Ende des Tracks, die nie übertragen werden
    static let cutMeters = 200.0
    /// Mindestradius um den Wohnort
    static let minHomeRadius = 250.0
    /// Bezeichnung für Start/Ziel im Wohnort-Radius
    static let homeLabel = "Wohnort"

    struct Zone {
        var lat: Double
        var lon: Double
        var radius: Double
    }

    /// Schutzzonen aus Wohnort/privaten Orten mit (lokalen) Koordinaten.
    static func zones(_ places: [Place]) -> [Zone] {
        places.compactMap { p in
            guard !p.deleted, p.keepsCoordinatesLocal, let lat = p.lat, let lon = p.lon else { return nil }
            return Zone(lat: lat, lon: lon, radius: max(Double(p.radiusM), minHomeRadius))
        }
    }

    static func isProtected(_ point: TrackPoint, zones: [Zone]) -> Bool {
        zones.contains { GeoMath.distance(lat1: $0.lat, lon1: $0.lon, lat2: point.lat, lon2: point.lon) <= $0.radius }
    }

    /// Punkte für `/geo/match`: ohne Punkte in Schutzzonen und ohne die ersten/letzten `cut` Meter.
    static func trimmed(_ points: [TrackPoint], zones: [Zone], cut: Double = cutMeters) -> [TrackPoint] {
        guard points.count >= 2 else { return [] }
        var startIndex = 0
        var acc = 0.0
        while startIndex < points.count - 1 && acc < cut {
            acc += GeoMath.distance(points[startIndex], points[startIndex + 1])
            startIndex += 1
        }
        var endIndex = points.count - 1
        acc = 0
        while endIndex > startIndex && acc < cut {
            acc += GeoMath.distance(points[endIndex], points[endIndex - 1])
            endIndex -= 1
        }
        guard endIndex > startIndex else { return [] }
        let kept = points[startIndex...endIndex].filter { !isProtected($0, zones: zones) }
        return kept.count >= 2 ? Array(kept) : []
    }
}
