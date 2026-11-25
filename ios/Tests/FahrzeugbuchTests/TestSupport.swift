import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import Fahrzeugbuch

/// Server-Attrappe für `APIClient.with(transport:)`: beantwortet Requests per Handler und protokolliert sie.
final class MockServer: @unchecked Sendable {
    struct Request {
        var method: String
        var path: String
        var query: [String: String]
        var body: Data?

        var json: [String: Any]? {
            body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    typealias Handler = (Request) -> (status: Int, body: Data, headers: [String: String])

    private let lock = NSLock()
    private var handlers: [(String, Handler)] = []
    private var log: [Request] = []

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    func requests(path suffix: String) -> [Request] {
        requests.filter { $0.path.hasSuffix(suffix) }
    }

    /// Handler für Pfade mit diesem Suffix (der zuletzt registrierte gewinnt).
    func on(_ pathSuffix: String, _ handler: @escaping Handler) {
        lock.lock()
        handlers.insert((pathSuffix, handler), at: 0)
        lock.unlock()
    }

    func onJSON(_ pathSuffix: String, status: Int = 200, _ json: String) {
        on(pathSuffix) { _ in (status, Data(json.utf8), [:]) }
    }

    func api() -> APIClient {
        APIClient(baseURL: URL(string: "https://fzb.example")!) { _ in "token" }
            .with(transport: { [self] request in try self.respond(request) })
    }

    private func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
        let url = request.url!
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            query[item.name] = item.value
        }
        let r = Request(method: request.httpMethod ?? "GET", path: url.path, query: query, body: request.httpBody)
        lock.lock()
        log.append(r)
        let handler = handlers.first { r.path.hasSuffix($0.0) }?.1
        lock.unlock()
        guard let handler else { throw URLError(.cannotConnectToHost) }
        let result = handler(r)
        let response = HTTPURLResponse(url: url, statusCode: result.status, httpVersion: "HTTP/1.1",
                                       headerFields: result.headers)!
        return (result.body, response)
    }
}

enum Fixture {
    static func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fzb-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func day(_ s: String) -> Date { APIClient.dayFormatter.date(from: s)! }

    static let vehicleId = "11111111-1111-4111-8111-111111111111"

    static func trip(_ id: String, start: String, end: String? = nil, kmStart: Int? = nil, kmEnd: Int? = nil,
                     category: String = "business", status: String = "confirmed") -> Trip {
        Trip(id: id, version: 1, vehicleId: vehicleId, startAt: start, endAt: end, kmStart: kmStart, kmEnd: kmEnd,
             category: category, status: status)
    }

    /// Leere `/changes`-Antwort mit Cursor.
    static func changes(cursor: Int, hasMore: Bool = false, extra: String = "") -> String {
        """
        {"cursor": \(cursor), "has_more": \(hasMore), "vehicles": [], "odometer": [], "fuel": [], "maintenance": [],
         "maintenance_items": [], "maintenance_materials": [], "material_articles": [], "trips": [], "places": [],
         "customers": [], "purpose_rules": [], "tax_params": [], "trip_periods": [], "attachments": []\(extra)}
        """
    }

    /// `/sync`-Antwort: alle Ops angenommen (Version = base + 1).
    static func acceptAll(_ request: MockServer.Request) -> (status: Int, body: Data, headers: [String: String]) {
        let ops = request.json?["ops"] as? [[String: Any]] ?? []
        let results: [[String: Any]] = ops.map { op in
            ["op_id": op["op_id"] ?? "", "status": "applied", "entity": op["entity"] ?? "", "id": op["id"] ?? "",
             "version": ((op["base_version"] as? Int) ?? 0) + 1]
        }
        let body = try! JSONSerialization.data(withJSONObject: ["results": results, "cursor": 10])
        return (200, body, [:])
    }
}
