import Foundation

// Reine Entscheidungslogik der Fahrterkennung (ohne CoreLocation/CoreMotion-Objekte, ohne Actor),
// damit sie in den Unit-Tests direkt geprüft werden kann. Aufrufer: `TripDetector`, `TripRecorder`,
// `TripCoordinator`.

/// Zeitpunkte einer Fahrt.
enum TripTiming {
    /// Ende einer Fahrt = Zeitstempel des letzten Bewegungspunkts (nicht der Moment der Auswertung):
    /// Wird die App beim Parkieren suspendiert, wertet iOS den Stopp oft erst Stunden später aus (Q2).
    /// Ohne Punkt (kein GPS) gilt `now`. Ergebnis liegt immer in `startedAt…now`.
    static func endDate(lastMovingTs: Double?, startedAt: Date, now: Date) -> Date {
        guard let lastMovingTs else { return max(now, startedAt) }
        let last = Date(timeIntervalSince1970: lastMovingTs)
        return min(max(last, startedAt), max(now, startedAt))
    }
}

/// Lücken in der Aufzeichnung (Q2): Nach mehr als 10 Minuten ohne Bewegungspunkt gehört die nächste
/// Bewegung zu einer neuen Fahrt – ausser CoreMotion meldete in der Lücke überwiegend «im Auto» (Stau, Q4).
enum RecordingGap {
    static let splitAfter: TimeInterval = 600
    /// So viel «gehend/laufend/Velo» in der Lücke genügt für eine neue Fahrt (ausgestiegen)
    static let onFootThreshold: TimeInterval = 60
    /// Mindestanteil «automotive» in der Lücke, damit sie als Stau (gleiche Fahrt) gilt
    static let automotiveShare = 0.5

    /// Liegt zwischen zwei Bewegungspunkten eine Lücke?
    static func isGap(previousTs: Double, nextTs: Double) -> Bool {
        nextTs - previousTs > splitAfter
    }

    /// Neue Fahrt nach der Lücke `gapStart…gapEnd`? `samples` = CoreMotion-Historie (auch Einträge, die vor
    /// der Lücke begonnen haben; der letzte davor gilt ab `gapStart`). `nil`/leer = unbekannt → aufteilen.
    static func shouldSplit(gapStart: Date, gapEnd: Date, samples: [MotionSample]?) -> Bool {
        let total = gapEnd.timeIntervalSince(gapStart)
        guard total > splitAfter else { return false }
        guard let samples, !samples.isEmpty else { return true }
        let sorted = samples.sorted { $0.date < $1.date }
        var automotive: TimeInterval = 0
        var onFoot: TimeInterval = 0
        for (i, s) in sorted.enumerated() {
            let next = i + 1 < sorted.count ? sorted[i + 1].date : gapEnd
            let from = max(s.date, gapStart)
            let to = min(next, gapEnd)
            guard to > from else { continue }
            let d = to.timeIntervalSince(from)
            if s.isOnFoot {
                onFoot += d
            } else if s.automotive {
                automotive += d
            }
        }
        if onFoot >= onFootThreshold { return true }
        return automotive < total * automotiveShare
    }

    /// Nach einem Neustart der App: automatisch gestartete Fahrt nicht fortsetzen, sondern am letzten
    /// Bewegungspunkt beenden, wenn dieser länger als `splitAfter` zurückliegt (sonst verschmelzen Fahrten).
    /// Manuelle Fahrten setzt die App fort (der Nutzer beendet sie selbst; Ende = letzter Bewegungspunkt).
    static func endsOnResume(source: String, lastMovingAt: Date, now: Date) -> Bool {
        source == "auto" && now.timeIntervalSince(lastMovingAt) > splitAfter
    }
}

/// Automatischer Stopp einer automatisch gestarteten Fahrt.
enum TripStopRule {
    /// Kein «automotive» und keine Bewegung seit … → Ende
    static let stopAfter: TimeInterval = 180
    /// iOS meldet Stillstand (`CLLocationUpdate.isStationary`) seit … und CoreMotion nicht mehr «automotive»
    static let stationaryStopAfter: TimeInterval = 60
    /// Manuelle Fahrt ohne GPS-Bewegung → Vorschlag «Fahrt beenden?»
    static let stopWithoutMovement: TimeInterval = 600
    /// Ab dieser Geschwindigkeit (m/s) zählt ein Fix als Bewegung (Kolonnenverkehr, Q4)
    static let movingSpeed = 1.0

    static func shouldStop(now: Date, lastAutomotiveAt: Date?, lastMovingAt: Date?, watchStartedAt: Date?,
                           stillInCar: Bool, stationarySince: Date?) -> Bool {
        let lastActive = [lastAutomotiveAt, lastMovingAt, watchStartedAt].compactMap { $0 }.max() ?? now
        let idle = now.timeIntervalSince(lastActive)
        func carWithin(_ window: TimeInterval) -> Bool {
            lastAutomotiveAt.map { now.timeIntervalSince($0) < window } ?? false
        }
        // (1) CoreMotion nicht mehr «im Auto» und weder Auto noch GPS-Bewegung seit 3 min
        if !stillInCar && idle > stopAfter { return true }
        // (2) iOS meldet Stillstand und CoreMotion widerspricht nicht → früh beenden (vor dem Suspendieren)
        if let s = stationarySince, now.timeIntervalSince(s) >= stationaryStopAfter,
           !stillInCar, !carWithin(stationaryStopAfter) {
            return true
        }
        // Früher zusätzlich: «10 min ohne GPS-Bewegung → Ende» auch bei «automotive». Das teilte Fahrten im
        // Stau (Q4). Jetzt endet eine Fahrt ohne GPS-Bewegung nur, wenn CoreMotion nicht mehr «automotive»
        // meldet – das deckt (1) ab. CoreMotion meldet nur Wechsel; die letzte Aktivität gilt bis zur nächsten.
        return false
    }
}

/// Fahrzeugwahl für Automatik, Siri/Kurzbefehle und CarPlay (Q3): nie stillschweigend «das erste».
enum DefaultVehicleChoice {
    /// - Parameters:
    ///   - preferredId: Zuordnung der Auto-Erkennung (Bluetooth-Gerät / CarPlay), falls vorhanden
    ///   - storedId: ausdrücklich gewähltes Standardfahrzeug (Einstellungen bzw. zuletzt gestartete Fahrt)
    ///   - activeIds: nicht stornierte Fahrzeuge des Mandanten
    /// - Returns: Fahrzeug-ID oder `nil` (dann klare Meldung statt Raten)
    static func automation(preferredId: String?, storedId: String?, activeIds: [String]) -> String? {
        if let preferredId, activeIds.contains(preferredId) { return preferredId }
        if let storedId, activeIds.contains(storedId) { return storedId }
        return activeIds.count == 1 ? activeIds.first : nil
    }

    static let missingText = "Kein Standardfahrzeug festgelegt – in odovio unter Einstellungen › Fahrtenbuch "
        + "› Standardfahrzeug wählen."
}
