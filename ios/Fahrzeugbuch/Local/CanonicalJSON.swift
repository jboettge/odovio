import Foundation

/// JSON-Wert mit kanonischer Darstellung (sortierte Schlüssel, ohne Leerraum, Zahlen deterministisch)
/// – Grundlage der Hash-Kette des lokalen Journals und der Datensicherung.
///
/// Kanonisch: ganzzahlige Werte (|x| < 2^53) ohne Nachkommastellen, übrige Zahlen in der kürzesten
/// rundungssicheren Darstellung von Swift, Strings mit JSON-Escapes (Steuerzeichen als \u00XX), Nicht-ASCII
/// als UTF-8. `canonical(parse(canonical(x))) == canonical(x)` (idempotent), unabhängig von der Plattform.
indirect enum JSONNode: Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONNode])
    case object([String: JSONNode])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONNode].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONNode].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Kein JSON-Wert")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // MARK: Erzeugen

    /// JSON-Daten → Wert (Decoder ohne Schlüsselumwandlung).
    static func parse(_ data: Data) throws -> JSONNode {
        try JSONDecoder().decode(JSONNode.self, from: data)
    }

    /// Kodierbaren Wert (z. B. Entity) mit dem angegebenen Encoder in einen JSON-Wert wandeln.
    static func from<T: Encodable>(_ value: T, encoder: JSONEncoder) throws -> JSONNode {
        try parse(try encoder.encode(value))
    }

    /// Wert in einen Typ dekodieren (über die kanonische Darstellung).
    func decode<T: Decodable>(_ type: T.Type, decoder: JSONDecoder) throws -> T {
        try decoder.decode(T.self, from: canonicalData)
    }

    // MARK: Zugriff

    subscript(key: String) -> JSONNode? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let i): return Int(exactly: i)
        case .double(let d): return d.isFinite && d.rounded() == d && abs(d) < 9.0e15 ? Int(d) : nil
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var objectValue: [String: JSONNode]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var arrayValue: [JSONNode]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// Für die Anzeige im Verlauf (`RevisionEntry.data`): Skalare direkt, verschachtelte Werte als Text.
    var displayValue: JSONValue {
        switch self {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .number(Double(i))
        case .double(let d): return .number(d)
        case .string(let s): return .string(s)
        case .array, .object: return .string(canonical)
        }
    }

    // MARK: Kanonische Darstellung

    var canonical: String {
        var out = ""
        write(into: &out)
        return out
    }

    var canonicalData: Data { Data(canonical.utf8) }

    private func write(into out: inout String) {
        switch self {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .int(let i):
            out += String(i)
        case .double(let d):
            out += Self.number(d)
        case .string(let s):
            Self.writeString(s, into: &out)
        case .array(let a):
            out += "["
            for (n, v) in a.enumerated() {
                if n > 0 { out += "," }
                v.write(into: &out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            for (n, key) in o.keys.sorted(by: Self.keyOrder).enumerated() {
                if n > 0 { out += "," }
                Self.writeString(key, into: &out)
                out += ":"
                o[key]!.write(into: &out)
            }
            out += "}"
        }
    }

    /// Schlüsselreihenfolge nach Unicode-Skalarwerten (wie Python `sort_keys`), unabhängig von der Locale.
    static func keyOrder(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars)
    }

    static func number(_ d: Double) -> String {
        guard d.isFinite else { return "null" }
        if d.rounded() == d && abs(d) < 9_007_199_254_740_992 {
            return String(Int64(d))
        }
        return "\(d)"
    }

    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
    }
}

/// SHA-256 als 64 Hex-Zeichen (klein).
enum Hashing {
    static func sha256Hex(_ data: Data) -> String { AttachmentFiles.sha256(data) }
    static func sha256Hex(_ text: String) -> String { sha256Hex(Data(text.utf8)) }
}
