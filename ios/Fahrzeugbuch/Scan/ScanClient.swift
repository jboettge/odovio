import Foundation

/// KI-Auswertung auf dem eigenen Server (`POST api/t/{t}/scan`) – nur auf Wunsch, wenn die
/// Erkennung auf dem Gerät nichts Eindeutiges liefert. Fehler führen nie zu einem Abbruch.
struct ScanClient {
    let api: APIClient
    let tenant: String

    struct ServerReading: Decodable {
        var liters: Double?
        var amount: Double?
        var pricePerLiter: Double?
        var km: Double?
        /// YYYY-MM-DD
        var date: String?
        var station: String?
        var confidence: Double?
        var reason: String?

        var hasValues: Bool { liters != nil || amount != nil || pricePerLiter != nil || km != nil }

        var parsedDate: Date? {
            guard let date else { return nil }
            return APIClient.dayFormatter.date(from: String(date.prefix(10)))
        }
    }

    enum Outcome {
        case reading(ServerReading)
        case noResult
        case notConfigured
        case failed(String)
    }

    private struct Body: Encodable {
        var imageB64: String
        var kind: String
    }

    static let maxImageBytes = 2 * 1024 * 1024

    /// KI-Auswertung verfügbar? Im Lokalmodus nie (kein Server).
    var isAvailable: Bool { !api.isLocalPlaceholder }

    func scan(jpeg: Data, kind: ScanKind) async -> Outcome {
        guard isAvailable else { return .notConfigured }   // Lokalmodus: keine KI-Auswertung
        guard jpeg.count <= Self.maxImageBytes else { return .failed("Das Bild ist zu gross (max. 2 MB).") }
        let body = Body(imageB64: jpeg.base64EncodedString(), kind: kind.rawValue)
        guard let data = try? APIClient.encoder.encode(body) else { return .failed("Bild konnte nicht gesendet werden.") }
        do {
            let response = try await api.rawResponse("POST", "api/t/\(tenant)/scan", body: data, timeout: 60)
            switch response.status {
            case 200:
                guard !response.data.isEmpty,
                      let r = try? APIClient.decoder.decode(ServerReading.self, from: response.data),
                      r.hasValues else { return .noResult }
                return .reading(r)
            case 204:
                return .noResult
            case 503:
                return .notConfigured
            case 429:
                return .failed("Zu viele Anfragen – bitte später erneut versuchen.")
            case 502:
                return .failed("Die KI-Auswertung auf dem Server ist fehlgeschlagen.")
            case 413:
                return .failed("Das Bild ist zu gross.")
            default:
                return .failed("Serverfehler \(response.status).")
            }
        } catch let error as URLError {
            return .failed(error.code == .timedOut ? "Zeitüberschreitung – bitte erneut versuchen."
                                                   : "Keine Verbindung zum Server.")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// Ob der Server Bilder auswerten kann (`GET api/intel/status` → `vision`), 10 Minuten zwischengespeichert.
@MainActor
enum VisionAvailability {
    private struct Entry {
        var value: Bool
        var checkedAt: Date
    }

    private struct Status: Decodable {
        var vision: Bool?
    }

    private static var cache: [String: Entry] = [:]

    static func check(api: APIClient) async -> Bool {
        #if DEBUG
        if Demo.isActive { return false }
        #endif
        if api.isLocalPlaceholder { return false }   // Lokalmodus: keine KI-Auswertung
        let key = api.baseURL.absoluteString
        if let entry = cache[key], Date().timeIntervalSince(entry.checkedAt) < 600 { return entry.value }
        guard let response = try? await api.rawResponse("GET", "api/intel/status", timeout: 8) else {
            return false   // offline → nicht zwischenspeichern
        }
        var available = false
        if response.status == 200, let status = try? APIClient.decoder.decode(Status.self, from: response.data) {
            available = status.vision ?? false
        }
        cache[key] = Entry(value: available, checkedAt: Date())
        return available
    }
}
