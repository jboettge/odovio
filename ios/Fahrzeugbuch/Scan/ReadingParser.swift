import Foundation

// Texterkennung → Werte (Liter, Betrag, Preis pro Liter bzw. Kilometerstand).
// Rein (nur Foundation, keine UIKit/Vision-Typen), damit die Logik mit XCTest geprüft werden kann.

/// Was fotografiert wird.
enum ScanKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case pump, receipt, odometer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pump: "Zapfsäule"
        case .receipt: "Quittung"
        case .odometer: "Tacho"
        }
    }

    var systemImage: String {
        switch self {
        case .pump: "fuelpump"
        case .receipt: "doc.text.viewfinder"
        case .odometer: "gauge.with.dots.needle.67percent"
        }
    }

    var isFuel: Bool { self != .odometer }
}

/// Zielfeld eines erkannten Werts.
enum ReadingField: String, CaseIterable, Identifiable, Sendable {
    case amount, liters, pricePerLiter, km

    var id: String { rawValue }

    var label: String {
        switch self {
        case .amount: "Betrag"
        case .liters: "Liter"
        case .pricePerLiter: "Preis pro Liter"
        case .km: "Kilometerstand"
        }
    }

    var unit: String {
        switch self {
        case .amount: "CHF"
        case .liters: "l"
        case .pricePerLiter: "CHF/l"
        case .km: "km"
        }
    }

    /// Nachkommastellen für Anzeige/Eingabe
    var fractionDigits: Int {
        switch self {
        case .amount, .liters: 2
        case .pricePerLiter: 3
        case .km: 0
        }
    }

    static let fuelFields: [ReadingField] = [.liters, .amount, .pricePerLiter]
}

/// Normalisiertes Rechteck im Bild (0…1, Ursprung oben links).
struct TextBox: Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    static let zero = TextBox(x: 0, y: 0, width: 0, height: 0)

    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }

    func horizontalOverlap(_ other: TextBox) -> Double {
        max(0, min(maxX, other.maxX) - max(x, other.x))
    }
}

/// Eine erkannte Textzeile (Vision-Beobachtung bzw. Live-Erkennung).
struct RecognizedLine: Hashable, Sendable {
    /// Bester Kandidat
    var text: String
    /// Alle Kandidaten, bester zuerst (Vision: topCandidates(3))
    var candidates: [String]
    /// 0…1
    var confidence: Double
    var box: TextBox

    init(text: String, candidates: [String] = [], confidence: Double = 1,
         box: TextBox = TextBox(x: 0.1, y: 0.1, width: 0.8, height: 0.05)) {
        self.text = text
        var list = candidates.filter { $0 != text }
        list.insert(text, at: 0)
        self.candidates = list
        self.confidence = min(1, max(0, confidence))
        self.box = box
    }
}

/// Eine im Text gefundene Zahl inkl. Herkunft und Hinweisen (Schlüsselwörter, Position).
struct NumberToken: Identifiable, Hashable, Sendable {
    var id: Int
    var value: Double
    /// Erkannter Originaltext (vor Korrektur)
    var raw: String
    var decimals: Int
    var intDigits: Int
    /// Mehrere Trennzeichen als Tausendertrenner interpretiert (z. B. 1.234.567)
    var grouped: Bool
    var lineIndex: Int
    /// Physische Stelle im Bild – zwei Rollen dürfen nie dieselbe Stelle verwenden
    var group: String
    var box: TextBox
    var confidence: Double
    /// Hinweisgewicht je Feld (Schlüsselwort/Einheit/Beschriftung)
    var hints: [ReadingField: Double] = [:]
    /// Abzug (Alternativkandidat, MWST-/Rückgeld-Zeile …)
    var penalty: Double = 0
    var isVAT = false
    var isPercent = false
    /// Säulennummer, Beleg-Nr., Tageskilometer usw.
    var ignored = false
    /// Aus topCandidates 2/3
    var isAlternate = false
    /// Komma ergänzt (Sieben-Segment-Punkt nicht erkannt)
    var isImplied = false

    var isChip: Bool { !isAlternate && !isImplied && !isPercent }
}

/// Konsistente Kombination Betrag = Liter × Preis pro Liter.
struct FuelTriple: Hashable, Sendable {
    var amount: Double
    var liters: Double
    var pricePerLiter: Double
    var amountToken: Int?
    var litersToken: Int?
    var pplToken: Int?
    var score: Double
    /// Nur zwei Werte erkannt → dieser Wert ist berechnet
    var computed: ReadingField?

    func value(_ field: ReadingField) -> Double? {
        switch field {
        case .amount: amount
        case .liters: liters
        case .pricePerLiter: pricePerLiter
        case .km: nil
        }
    }

    func tokenId(_ field: ReadingField) -> Int? {
        switch field {
        case .amount: amountToken
        case .liters: litersToken
        case .pricePerLiter: pplToken
        case .km: nil
        }
    }

    var key: String { String(format: "%.2f|%.2f|%.3f", amount, liters, pricePerLiter) }
}

/// Ergebnis der Auswertung.
struct ScanReading: Sendable {
    static let unambiguousThreshold = 0.7

    var kind: ScanKind
    var tokens: [NumberToken] = []
    var fuel: FuelTriple?
    var alternatives: [FuelTriple] = []
    var km: Int?
    var kmToken: Int?
    var kmAlternatives: [Int] = []
    var date: Date?
    var station: String?
    /// 0…1
    var confidence: Double = 0
    var reason = ""

    init(kind: ScanKind) {
        self.kind = kind
    }

    var hasValues: Bool { fuel != nil || km != nil }
    var isUnambiguous: Bool { hasValues && confidence >= Self.unambiguousThreshold }

    func token(_ id: Int?) -> NumberToken? {
        guard let id else { return nil }
        return tokens.first { $0.id == id }
    }

    /// Erkannter Wert eines Felds
    func value(_ field: ReadingField) -> Double? {
        if field == .km { return km.map(Double.init) }
        return fuel?.value(field)
    }

    /// Token, aus dem ein Feld stammt (für Hervorhebung)
    func tokenId(for field: ReadingField) -> Int? {
        if field == .km { return kmToken }
        return fuel?.tokenId(field)
    }

    /// Zum Vergleich aufeinanderfolgender Live-Erkennungen
    var stabilityKey: String? {
        if let fuel { return fuel.key }
        if let km { return String(km) }
        return nil
    }

    /// Erkannte Zahlen als Auswahl (Chips) für ein Feld, in Lesereihenfolge, ohne Duplikate.
    func chips(for field: ReadingField) -> [NumberToken] {
        var seen = Set<String>()
        var result: [NumberToken] = []
        let ordered = tokens.filter(\.isChip).sorted { ($0.lineIndex, $0.box.x) < ($1.lineIndex, $1.box.x) }
        for t in ordered {
            if field == .km {
                guard let v = ReadingParser.kmValue(t) else { continue }
                var copy = t
                copy.value = Double(v)
                if seen.insert(String(v)).inserted { result.append(copy) }
            } else {
                guard t.decimals > 0, t.value > 0, t.value < 10_000 else { continue }
                if seen.insert(String(format: "%.3f", t.value)).inserted { result.append(t) }
            }
        }
        return result
    }
}

/// Auswertung erkannter Textzeilen.
struct ReadingParser {
    var kind: ScanKind
    /// Höchster bekannter km-Stand des Fahrzeugs (Plausibilität Tacho)
    var lastKnownKm: Int?
    var now: Date
    var calendar: Calendar

    init(kind: ScanKind, lastKnownKm: Int? = nil, now: Date = Date(), calendar: Calendar = .current) {
        self.kind = kind
        self.lastKnownKm = lastKnownKm
        self.now = now
        self.calendar = calendar
    }

    static func parse(_ lines: [RecognizedLine], kind: ScanKind, lastKnownKm: Int? = nil,
                      now: Date = Date()) -> ScanReading {
        ReadingParser(kind: kind, lastKnownKm: lastKnownKm, now: now).parse(lines)
    }

    // Plausibilitätsbereiche
    static let pplRange = 0.8...4.0
    static let litersRange = 0.5...300.0
    static let amountRange = 1.0...1000.0
    static let kmDigits = 4...7

    /// Toleranz für Betrag vs. Liter × Preis pro Liter
    static func tolerance(liters: Double) -> Double { max(0.015, liters * 0.0006) }

    func parse(_ input: [RecognizedLine]) -> ScanReading {
        let lines = input
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { a, b in
                if abs(a.box.midY - b.box.midY) > min(a.box.height, b.box.height) * 0.5 {
                    return a.box.midY < b.box.midY
                }
                return a.box.x < b.box.x
            }
        var reading = ScanReading(kind: kind)
        reading.tokens = extractTokens(lines)
        switch kind {
        case .pump, .receipt:
            evaluateFuel(&reading)
            if kind == .receipt {
                reading.date = findDate(lines)
                reading.station = findStation(lines)
            }
        case .odometer:
            evaluateOdometer(&reading)
        }
        return reading
    }

    // MARK: Zahlen erkennen

    /// Typische OCR-Verwechslungen (Sieben-Segment-Anzeigen)
    static let ocrDigitMap: [Character: Character] = [
        "O": "0", "o": "0", "D": "0",
        "I": "1", "l": "1", "|": "1",
        "S": "5", "B": "8", "Z": "2",
    ]
    static let separatorChars: Set<Character> = [".", ",", "'", "’", "`", "´"]
    private static let apostrophes: Set<Character> = ["'", "’", "`", "´"]

    private static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }

    private static func isRunChar(_ c: Character) -> Bool {
        isDigit(c) || ocrDigitMap[c] != nil || separatorChars.contains(c)
    }

    /// Ergebnis der Zahlen-Normalisierung.
    struct ParsedNumber: Equatable, Sendable {
        var value: Double
        var decimals: Int
        var intDigits: Int
        var grouped: Bool
        var normalized: String
    }

    /// Normalisiert eine Zahl: O/o/D→0, I/l/|→1, S→5, B→8, Z→2, Apostroph als Tausendertrenner, Komma→Punkt.
    static func parseNumber(_ raw: String) -> ParsedNumber? {
        var chars: [Character] = []
        for c in raw {
            if isDigit(c) || c == "." || c == "," {
                chars.append(c)
            } else if let mapped = ocrDigitMap[c] {
                chars.append(mapped)
            } else if apostrophes.contains(c) {
                continue   // Tausendertrenner 12'345
            } else if c == " " {
                continue
            } else {
                return nil
            }
        }
        while let first = chars.first, first == "." || first == "," { chars.removeFirst() }
        while let last = chars.last, last == "." || last == "," { chars.removeLast() }
        guard chars.contains(where: isDigit) else { return nil }

        let separatorIndices = chars.indices.filter { chars[$0] == "." || chars[$0] == "," }
        var integerPart: [Character]
        var fraction: [Character] = []
        var grouped = false
        if separatorIndices.isEmpty {
            integerPart = chars
        } else {
            let hasDot = chars.contains(".")
            let hasComma = chars.contains(",")
            var decimalIndex: Int?
            if hasDot && hasComma {
                decimalIndex = separatorIndices.last   // 1.234,50 bzw. 1,234.50
            } else if separatorIndices.count == 1 {
                decimalIndex = separatorIndices[0]
            } else {
                // Mehrere gleiche Trenner: alle Gruppen dreistellig → Tausender, sonst letzter = Komma
                let groups = split(chars, at: separatorIndices)
                if groups.dropFirst().allSatisfy({ $0.count == 3 }) {
                    decimalIndex = nil
                    grouped = true
                } else {
                    decimalIndex = separatorIndices.last
                }
            }
            if let d = decimalIndex {
                integerPart = chars[..<d].filter(isDigit)
                fraction = chars[(d + 1)...].filter(isDigit)
                if separatorIndices.count > 1 { grouped = true }
            } else {
                integerPart = chars.filter(isDigit)
            }
        }
        guard integerPart.count + fraction.count <= 10 else { return nil }
        if integerPart.isEmpty { integerPart = ["0"] }
        let text = fraction.isEmpty ? String(integerPart) : String(integerPart) + "." + String(fraction)
        guard let value = Double(text) else { return nil }
        let significant = integerPart.drop { $0 == "0" }.count
        return ParsedNumber(value: value, decimals: fraction.count, intDigits: max(significant, 1),
                            grouped: grouped, normalized: text)
    }

    private static func split(_ chars: [Character], at indices: [Int]) -> [[Character]] {
        var result: [[Character]] = []
        var start = 0
        for i in indices {
            result.append(Array(chars[start..<i]))
            start = i + 1
        }
        result.append(Array(chars[start...]))
        return result
    }

    /// Zahl in einer Zeile mit Position (Zeichen-Offsets) und Kontext.
    struct LineNumber: Sendable {
        var parsed: ParsedNumber
        var raw: String
        var start: Int
        var end: Int
        var before: String
        var after: String
    }

    /// Findet alle Zahlen eines Texts (Datum/Uhrzeit ausgeblendet).
    static func numbers(in text: String, kind: ScanKind) -> [LineNumber] {
        var prepared = mask(text, pattern: reDateTime)
        if kind == .odometer {
            prepared = mergeThousandsSpaces(prepared)
        }
        let chars = Array(prepared)
        var spans: [(start: Int, end: Int)] = []
        var i = 0
        while i < chars.count {
            guard isRunChar(chars[i]) else { i += 1; continue }
            var j = i
            while j < chars.count && isRunChar(chars[j]) { j += 1 }
            if let span = trimRun(chars, i, j) {
                spans.append(span)
            }
            i = j
        }
        var result: [LineNumber] = []
        for (n, span) in spans.enumerated() {
            let raw = String(chars[span.start..<span.end])
            guard let parsed = parseNumber(raw) else { continue }
            let beforeStart = n > 0 ? spans[n - 1].end : 0
            let afterEnd = n + 1 < spans.count ? spans[n + 1].start : chars.count
            result.append(LineNumber(parsed: parsed, raw: raw, start: span.start, end: span.end,
                                     before: String(chars[beforeStart..<span.start]),
                                     after: String(chars[span.end..<afterEnd])))
        }
        return result
    }

    /// Kürzt eine Zeichenfolge auf den Zahlteil; `nil`, wenn es keine Zahl ist.
    private static func trimRun(_ chars: [Character], _ from: Int, _ to: Int) -> (start: Int, end: Int)? {
        var start = from
        var end = to
        while start < end && separatorChars.contains(chars[start]) { start += 1 }
        while end > start && separatorChars.contains(chars[end - 1]) { end -= 1 }
        guard end > start else { return nil }
        // "43.60l" / "43.60ltr": l nach einer Zahl mit Komma ist die Einheit, nicht die Ziffer 1
        if end - start >= 3, chars[end - 1] == "l",
           chars[start..<(end - 1)].contains(where: { $0 == "." || $0 == "," }) {
            end -= 1
            while end > start && separatorChars.contains(chars[end - 1]) { end -= 1 }
        }
        // Verwechslungs-Buchstaben am Rand eines Worts (z. B. "PLZ8001") nicht als Ziffer werten
        if start > 0, chars[start - 1].isLetter {
            while start < end && ocrDigitMap[chars[start]] != nil { start += 1 }
        }
        if end < chars.count, chars[end].isLetter {
            while end > start && ocrDigitMap[chars[end - 1]] != nil { end -= 1 }
        }
        while start < end && separatorChars.contains(chars[start]) { start += 1 }
        while end > start && separatorChars.contains(chars[end - 1]) { end -= 1 }
        guard end > start else { return nil }
        let slice = chars[start..<end]
        let digits = slice.filter(isDigit).count
        let letters = slice.filter { ocrDigitMap[$0] != nil }.count
        guard digits >= 1, letters <= digits else { return nil }
        return (start: start, end: end)
    }

    /// "53 410" → "53410" (Tacho mit Leerzeichen als Tausendertrenner)
    static func mergeThousandsSpaces(_ text: String) -> String {
        var current = text
        for _ in 0..<3 {
            let ns = current as NSString
            let next = reSpaceThousands.stringByReplacingMatches(
                in: current, range: NSRange(location: 0, length: ns.length), withTemplate: "$1$2")
            if next == current { break }
            current = next
        }
        return current
    }

    /// Ersetzt Treffer durch Leerzeichen gleicher Länge (Offsets bleiben erhalten).
    private static func mask(_ text: String, pattern: NSRegularExpression) -> String {
        let ns = NSMutableString(string: text)
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            ns.replaceCharacters(in: m.range, with: String(repeating: " ", count: m.range.length))
        }
        return ns as String
    }

    // MARK: Hinweise (Schlüsselwörter, Einheiten, Beschriftungen)

    private static func re(_ pattern: String) -> NSRegularExpression {
        // Konstante Muster – ein Fehler wäre ein Programmierfehler
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func has(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static func strip(_ regex: NSRegularExpression, _ text: String) -> String {
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return text }
        return ns.replacingCharacters(in: m.range, with: " ")
    }

    static let reDateTime = re(
        #"(?<![0-9])(?:[0-9]{1,2}[./-][0-9]{1,2}[./-](?:[0-9]{4}|[0-9]{2})|[0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?)(?![0-9])"#)
    static let reDate = re(#"(?<![0-9])([0-9]{1,2})[./-]([0-9]{1,2})[./-]([0-9]{4}|[0-9]{2})(?![0-9])"#)
    /// Gruppen dürfen OCR-Verwechslungen enthalten ("53 4IO"), brauchen aber je eine echte Ziffer
    static let reSpaceThousands = re(
        #"(?<![0-9A-Za-z.,])((?=[OoDIl|SBZ]{0,2}[0-9])[0-9OoDIl|SBZ]{1,3})[ '’]((?=[OoDIl|SBZ]{0,2}[0-9])[0-9OoDIl|SBZ]{3})(?![0-9A-Za-z])"#)

    private static let currency = #"(?:chf|sfr\.?|fr\.?|eur|€)"#
    private static let literUnit = #"(?:l|lt|ltr|liter|litre)"#

    static let reAfterPercent = re(#"^\s*%"#)
    static let reAfterConsumption = re(#"^\s*l\s*/\s*100"#)
    static let reAfterPPL = re(#"^\s*\#(currency)?\s*/\s*\#(literUnit)\b"#)
    static let reAfterLiters = re(#"^\s*(?:l|lt|ltr|liter|litre|lit)\b"#)
    static let reAfterCurrency = re(#"^\s*\#(currency)"#)
    static let reAfterSpeed = re(#"^\s*km\s*/\s*h"#)
    static let reAfterKm = re(#"^\s*km\b"#)
    static let reAfterOther = re(#"^\s*(?:°|h\b|min\b|%)"#)
    static let reLeadUnit = re(#"^\s*(?:%|\#(currency)?\s*/\s*\#(literUnit)\b|(?:l|lt|ltr|liter|litre|km)\b)"#)

    static let reLabelPPL = re(
        #"(?:preis|\#(currency))\s*(?:/|pro)\s*\#(literUnit)\b|pro\s*liter|literpreis|einheitspreis|grundpreis|unit\s*price"#)
    static let reLabelLiters = re(#"liter|litre|ltr|menge|volumen|abgabe|quantity|^\s*l\s*$"#)
    static let reLabelAmount = re(
        #"total|betrag|summe|zu\s*zahlen|bezahlt|gesamt|endbetrag|amount|preis|\#(currency)"#)
    static let reLabelKm = re(#"\bkm\b|kilometer|\bodo\b|gesamt"#)
    static let reIgnoreFuel = re(
        #"s[aä]ule|saeule|zapf|pumpe|\bnr\b|nr\.|\bno\.|\btel\b|terminal|trx|transakt|beleg|karte|kasse|\bplz\b|kunde|auth|\bref\b|\bid\b|che-"#)
    static let reIgnoreOdometer = re(
        #"trip|tages|reichw|range|verbrauch|ø|durchschn|\bavg\b|temp|uhr|zeit|service|inspektion|öl"#)
    static let reVAT = re(#"mwst|m\.w\.st|mehrwert|\bust\b|\bvat\b|\btva\b|\biva\b|netto|steuer|exkl"#)
    static let reTotal = re(#"total|betrag|summe|zu\s*zahlen|endbetrag"#)
    static let reOther = re(
        #"r[uü]ckgeld|zur[uü]ck|retour|gegeben|\bbar\b|rabatt|bonus|punkte|cumulus|supercard|trinkgeld|saldo"#)

    /// Feld einer reinen Beschriftungszeile ("Betrag CHF", "Liter", "CHF/Liter", "km").
    func labelField(_ text: String) -> ReadingField? {
        let t = text.lowercased()
        if kind == .odometer {
            return Self.has(Self.reLabelKm, t) ? .km : nil
        }
        if Self.has(Self.reLabelPPL, t) { return .pricePerLiter }
        if Self.has(Self.reLabelLiters, t) { return .liters }
        if Self.has(Self.reLabelAmount, t) { return .amount }
        return nil
    }

    // MARK: Tokens

    private func extractTokens(_ lines: [RecognizedLine]) -> [NumberToken] {
        var tokens: [NumberToken] = []
        var nextId = 0
        var labelLines: [(index: Int, field: ReadingField)] = []

        for (li, line) in lines.enumerated() {
            let lower = line.text.lowercased()
            let vat = kind == .receipt && Self.has(Self.reVAT, lower) && !Self.has(Self.reTotal, lower)
            let other = kind.isFuel && Self.has(Self.reOther, lower)
            var primaryCount = 0
            for (ci, candidate) in line.candidates.prefix(3).enumerated() {
                let found = Self.numbers(in: candidate, kind: kind)
                if ci == 0 {
                    primaryCount = found.count
                    if found.isEmpty, let field = labelField(candidate) {
                        labelLines.append((index: li, field: field))
                    }
                }
                let length = max(Array(candidate).count, 1)
                for (n, number) in found.enumerated() {
                    if ci > 0 {
                        // Alternativkandidat nur, wenn er einen anderen Wert liefert
                        let sameValue = tokens.contains {
                            $0.lineIndex == li && abs($0.value - number.parsed.value) < 0.0005
                        }
                        if sameValue { continue }
                    }
                    let group = (ci == 0 || found.count == primaryCount) ? "\(li):\(n)" : "\(li):c\(ci):\(n)"
                    let fs = Double(number.start) / Double(length)
                    let fe = Double(number.end) / Double(length)
                    let box = TextBox(x: line.box.x + line.box.width * fs, y: line.box.y,
                                      width: max(line.box.width * (fe - fs), 0.001), height: line.box.height)
                    var t = NumberToken(id: nextId, value: number.parsed.value, raw: number.raw,
                                        decimals: number.parsed.decimals, intDigits: number.parsed.intDigits,
                                        grouped: number.parsed.grouped, lineIndex: li, group: group, box: box,
                                        confidence: line.confidence)
                    nextId += 1
                    t.isAlternate = ci > 0
                    if t.isAlternate { t.penalty += 0.15 }
                    t.isVAT = vat
                    if other { t.penalty += 0.4 }
                    applyInlineHints(&t, number: number, hasPrevious: n > 0, lineText: lower)
                    tokens.append(t)
                }
            }
        }

        applyLabelLineHints(&tokens, lines: lines, labels: labelLines)

        // Sieben-Segment-Anzeige ohne erkannten Dezimalpunkt: 7780 → 77.80 (nur als Ersatz)
        if kind == .pump {
            let decimalCount = tokens.filter { $0.decimals > 0 && !$0.ignored && !$0.isAlternate }.count
            if decimalCount < 2 {
                var implied: [NumberToken] = []
                for t in tokens where t.decimals == 0 && !t.ignored && !t.isAlternate && (3...5).contains(t.intDigits) {
                    for divisor in [100.0, 1000.0] where divisor == 100 || t.intDigits == 4 {
                        var copy = t
                        copy.id = nextId
                        nextId += 1
                        copy.value = t.value / divisor
                        copy.decimals = divisor == 100 ? 2 : 3
                        copy.intDigits = max(t.intDigits - copy.decimals, 1)
                        copy.isImplied = true
                        copy.penalty += 0.35
                        implied.append(copy)
                    }
                }
                tokens += implied
            }
        }
        return tokens
    }

    private func applyInlineHints(_ t: inout NumberToken, number: LineNumber, hasPrevious: Bool, lineText: String) {
        let after = number.after.lowercased()
        var before = number.before.lowercased()
        if hasPrevious {
            // Einheit direkt nach der vorherigen Zahl gehört zu dieser ("43.60 l x 1.784 CHF/l")
            before = Self.strip(Self.reLeadUnit, before)
        }

        if Self.has(Self.reAfterPercent, after) {
            t.isPercent = true
            t.ignored = true
        }

        switch kind {
        case .pump, .receipt:
            if Self.has(Self.reAfterConsumption, after) {
                t.ignored = true
            } else if Self.has(Self.reAfterPPL, after) {
                t.hints[.pricePerLiter] = 1.0
            } else if Self.has(Self.reAfterLiters, after) {
                t.hints[.liters] = 1.0
            } else if Self.has(Self.reAfterCurrency, after) {
                t.hints[.amount] = 0.6
            }
            if Self.has(Self.reIgnoreFuel, before) && t.decimals == 0 {
                t.ignored = true
            } else if Self.has(Self.reLabelPPL, before) {
                t.hints[.pricePerLiter] = max(t.hints[.pricePerLiter] ?? 0, 0.8)
            } else if Self.has(Self.reLabelLiters, before) {
                t.hints[.liters] = max(t.hints[.liters] ?? 0, 0.8)
            } else if Self.has(Self.reLabelAmount, before) {
                t.hints[.amount] = max(t.hints[.amount] ?? 0, 0.8)
            }
        case .odometer:
            if Self.has(Self.reAfterSpeed, after) || Self.has(Self.reAfterOther, after) {
                t.ignored = true
            } else if Self.has(Self.reAfterKm, after) {
                t.hints[.km] = 1.0
            }
            if Self.has(Self.reIgnoreOdometer, before) {
                t.ignored = true
            } else if Self.has(Self.reLabelKm, before) {
                t.hints[.km] = max(t.hints[.km] ?? 0, 0.8)
            } else if Self.has(Self.reLabelKm, lineText) {
                t.hints[.km] = max(t.hints[.km] ?? 0, 0.5)
            }
        }
    }

    /// Beschriftungen in eigenen Zeilen (Zapfsäule: "Betrag CHF" über der Anzeige) zuordnen.
    private func applyLabelLineHints(_ tokens: inout [NumberToken], lines: [RecognizedLine],
                                     labels: [(index: Int, field: ReadingField)]) {
        guard !labels.isEmpty else { return }
        for i in tokens.indices {
            let ownMax = tokens[i].hints.values.max() ?? 0
            if ownMax >= 0.8 { continue }
            let lineBox = lines[tokens[i].lineIndex].box
            var best: (field: ReadingField, weight: Double, distance: Double)?
            for label in labels {
                let lb = lines[label.index].box
                let h = max(lineBox.height, lb.height)
                var weight = 0.0
                var distance = Double.greatestFiniteMagnitude
                if abs(lb.midY - lineBox.midY) < h * 0.6 {
                    weight = 0.7                                  // gleiche Zeile (links/rechts)
                    distance = max(0, max(lb.x - lineBox.maxX, lineBox.x - lb.maxX))
                } else if lb.maxY <= lineBox.midY, lineBox.y - lb.maxY < lineBox.height * 2.0,
                          lb.maxX >= lineBox.x - max(lineBox.width, 0.2), lb.x <= lineBox.maxX {
                    // darüber (auch links darüber: Beschriftung links, Anzeige rechtsbündig)
                    weight = 0.6
                    distance = max(0, lineBox.y - lb.maxY) + 1
                } else if lb.y >= lineBox.midY, lb.y - lineBox.maxY < lineBox.height * 1.0,
                          lb.horizontalOverlap(lineBox) > 0 {
                    weight = 0.4                                  // darunter
                    distance = max(0, lb.y - lineBox.maxY) + 2
                }
                guard weight > 0 else { continue }
                if best == nil || distance < best!.distance {
                    best = (field: label.field, weight: weight, distance: distance)
                }
            }
            if let best, best.weight > ownMax {
                tokens[i].hints[best.field] = max(tokens[i].hints[best.field] ?? 0, best.weight)
            }
        }
    }

    // MARK: Tankung (Zapfsäule, Quittung)

    private static func role(_ t: NumberToken, _ field: ReadingField) -> Double {
        let own = t.hints[field] ?? 0
        var other = 0.0
        for f in ReadingField.fuelFields where f != field {
            other = max(other, t.hints[f] ?? 0)
        }
        return own * 0.7 - (other > own ? other * 0.5 : 0)
    }

    private static func contradicts(_ t: NumberToken, _ field: ReadingField) -> Bool {
        ReadingField.fuelFields.contains { f in f != field && (t.hints[f] ?? 0) >= 0.7 && (t.hints[field] ?? 0) < 0.5 }
    }

    private func evaluateFuel(_ reading: inout ScanReading) {
        var candidates = reading.tokens.filter { $0.decimals > 0 && !$0.ignored && $0.value > 0 }
        if candidates.count > 40 {
            candidates = Array(candidates.sorted { $0.confidence - $0.penalty > $1.confidence - $1.penalty }.prefix(40))
        }

        var triples = findTriples(candidates, all: reading.tokens)
        var twoValues = false
        if triples.isEmpty {
            triples = findPairs(candidates)
            twoValues = !triples.isEmpty
        }
        guard let best = triples.first else {
            reading.confidence = 0
            reading.reason = candidates.isEmpty
                ? "Keine Zahlen mit Nachkommastellen erkannt."
                : "Keine passende Kombination aus Betrag, Liter und Preis pro Liter gefunden."
            return
        }
        reading.fuel = best
        reading.alternatives = Array(triples.dropFirst().prefix(5))

        let a = reading.token(best.amountToken)
        let l = reading.token(best.litersToken)
        let p = reading.token(best.pplToken)
        let used = [a, l, p].compactMap { $0 }
        let hintCount = [(a, ReadingField.amount), (l, .liters), (p, .pricePerLiter)]
            .filter { pair in (pair.0?.hints[pair.1] ?? 0) >= 0.5 }.count
        let avgConf = used.isEmpty ? 0.5 : used.map(\.confidence).reduce(0, +) / Double(used.count)
        let penalties = used.map(\.penalty).reduce(0, +)
        let ambiguous = reading.alternatives.first.map { best.score - $0.score < 0.35 } ?? false

        var c: Double
        if twoValues {
            let distinct = Set(candidates.filter { !$0.isAlternate && !$0.isImplied }.map { String(format: "%.3f", $0.value) })
            c = 0.45 + 0.1 * Double(hintCount) + (distinct.count == 2 ? 0.1 : 0) - (ambiguous ? 0.2 : 0)
            reading.reason = switch best.computed ?? .pricePerLiter {
            case .amount: "Nur Liter und Preis pro Liter erkannt – Betrag berechnet."
            case .liters: "Nur Betrag und Preis pro Liter erkannt – Liter berechnet."
            default: "Nur Betrag und Liter erkannt – Preis pro Liter berechnet."
            }
        } else {
            c = 0.68 + 0.08 * Double(hintCount)
            if (p?.decimals ?? 0) == 3 { c += 0.08 }
            if kind == .pump, let a, let l, let p, a.box.midY < l.box.midY, l.box.midY < p.box.midY { c += 0.06 }
            if ambiguous { c -= 0.3 }
            reading.reason = ambiguous
                ? "Mehrere Kombinationen passen – bitte Werte prüfen."
                : "Betrag = Liter × Preis pro Liter stimmt überein."
        }
        c *= 0.85 + 0.15 * avgConf
        c -= penalties * 0.5
        reading.confidence = min(0.98, max(0.05, c))
    }

    private func findTriples(_ candidates: [NumberToken], all: [NumberToken]) -> [FuelTriple] {
        let amounts = candidates.filter { Self.amountRange.contains($0.value) }
        let liters = candidates.filter { Self.litersRange.contains($0.value) }
        let ppls = candidates.filter { Self.pplRange.contains($0.value) }
        var found: [String: FuelTriple] = [:]
        for a in amounts {
            for l in liters where l.group != a.group && l.id != a.id {
                for p in ppls where p.group != a.group && p.group != l.group {
                    let product = l.value * p.value
                    let error = abs(a.value - product)
                    let tol = Self.tolerance(liters: l.value)
                    var s = 1.0
                    if error <= tol {
                        s += 0.2 * (1 - error / tol)
                    } else if kind == .receipt && error <= 0.051 {
                        s -= 0.3   // Rundung auf 5 Rappen (Barzahlung)
                    } else {
                        continue
                    }
                    s += score(a: a, l: l, p: p)
                    if kind == .receipt {
                        let repeats = all.filter {
                            $0.id != a.id && !$0.isAlternate && !$0.isImplied && $0.group != a.group
                                && abs($0.value - a.value) < 0.005 && !$0.isVAT
                        }.count
                        s += min(Double(repeats), 2) * 0.08
                    }
                    let triple = FuelTriple(amount: a.value, liters: l.value, pricePerLiter: p.value,
                                            amountToken: a.id, litersToken: l.id, pplToken: p.id, score: s)
                    if let existing = found[triple.key], existing.score >= s { continue }
                    found[triple.key] = triple
                }
            }
        }
        return found.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.key < $1.key }
    }

    private func score(a: NumberToken, l: NumberToken, p: NumberToken) -> Double {
        var s = Self.role(a, .amount) + Self.role(l, .liters) + Self.role(p, .pricePerLiter)
        s -= a.penalty + l.penalty + p.penalty
        if a.isVAT { s -= 1.0 }
        if l.isVAT { s -= 0.5 }
        if p.isVAT { s -= 0.5 }
        switch p.decimals {
        case 3: s += 0.3
        case 2: s += 0.1
        default: break
        }
        if a.decimals == 2 { s += 0.2 } else if a.decimals >= 3 { s -= 0.3 }
        if l.decimals == 2 { s += 0.1 }
        if kind == .pump {
            if a.box.midY < l.box.midY && l.box.midY < p.box.midY { s += 0.3 }
            if p.box.height < min(a.box.height, l.box.height) { s += 0.1 }
        }
        s += 0.3 * (a.confidence + l.confidence + p.confidence) / 3
        return s
    }

    /// Nur zwei Werte: fehlenden dritten berechnen, falls plausibel.
    private func findPairs(_ candidates: [NumberToken]) -> [FuelTriple] {
        var found: [String: FuelTriple] = [:]
        func add(_ t: FuelTriple) {
            guard Self.amountRange.contains(t.amount), Self.litersRange.contains(t.liters),
                  Self.pplRange.contains(t.pricePerLiter) else { return }
            if let existing = found[t.key], existing.score >= t.score { return }
            found[t.key] = t
        }
        for x in candidates {
            for y in candidates where y.group != x.group {
                // Betrag + Liter → Preis pro Liter
                if Self.amountRange.contains(x.value), Self.litersRange.contains(y.value),
                   !Self.contradicts(x, .amount), !Self.contradicts(y, .liters) {
                    let ppl = x.value / y.value
                    var s = 0.5 + Self.role(x, .amount) + Self.role(y, .liters) - x.penalty - y.penalty
                    if x.decimals == 2 { s += 0.1 }
                    if (1.3...2.5).contains(ppl) { s += 0.2 }
                    if kind == .pump && x.box.midY < y.box.midY { s += 0.1 }
                    s += 0.2 * (x.confidence + y.confidence) / 2
                    add(FuelTriple(amount: x.value, liters: y.value, pricePerLiter: (ppl * 1000).rounded() / 1000,
                                   amountToken: x.id, litersToken: y.id, pplToken: nil, score: s,
                                   computed: .pricePerLiter))
                }
                // Liter + Preis pro Liter → Betrag (Preis nur mit Hinweis oder 3 Nachkommastellen)
                let pplLike = (y.hints[.pricePerLiter] ?? 0) >= 0.5 || y.decimals == 3
                if pplLike, Self.litersRange.contains(x.value), Self.pplRange.contains(y.value),
                   !Self.contradicts(x, .liters), !Self.contradicts(y, .pricePerLiter) {
                    let amount = (x.value * y.value * 100).rounded() / 100
                    let s = 0.4 + Self.role(x, .liters) + Self.role(y, .pricePerLiter) - x.penalty - y.penalty
                        + 0.2 * (x.confidence + y.confidence) / 2
                    add(FuelTriple(amount: amount, liters: x.value, pricePerLiter: y.value,
                                   amountToken: nil, litersToken: x.id, pplToken: y.id, score: s, computed: .amount))
                }
                // Betrag + Preis pro Liter → Liter
                if pplLike, Self.amountRange.contains(x.value), Self.pplRange.contains(y.value),
                   !Self.contradicts(x, .amount), !Self.contradicts(y, .pricePerLiter) {
                    let liters = (x.value / y.value * 100).rounded() / 100
                    let s = 0.4 + Self.role(x, .amount) + Self.role(y, .pricePerLiter) - x.penalty - y.penalty
                        + 0.2 * (x.confidence + y.confidence) / 2
                    add(FuelTriple(amount: x.value, liters: liters, pricePerLiter: y.value,
                                   amountToken: x.id, litersToken: nil, pplToken: y.id, score: s, computed: .liters))
                }
            }
        }
        return found.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.key < $1.key }
    }

    // MARK: Quittung: Datum, Tankstelle

    func findDate(_ lines: [RecognizedLine]) -> Date? {
        let latest = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        for line in lines {
            let text = line.text
            let ns = text as NSString
            for m in Self.reDate.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let d = Int(ns.substring(with: m.range(at: 1))),
                      let mo = Int(ns.substring(with: m.range(at: 2))),
                      var y = Int(ns.substring(with: m.range(at: 3))) else { continue }
                if y < 100 { y += 2000 }
                guard (1...31).contains(d), (1...12).contains(mo), (2000...2100).contains(y) else { continue }
                var comps = DateComponents()
                comps.year = y
                comps.month = mo
                comps.day = d
                guard let date = calendar.date(from: comps),
                      calendar.component(.day, from: date) == d,   // kein 31.02.
                      date <= latest else { continue }
                return date
            }
        }
        return nil
    }

    private static let genericHeaders = [
        "quittung", "beleg", "kassenbeleg", "kundenbeleg", "kundenquittung", "willkommen", "herzlich",
        "danke", "kopie", "original", "tankquittung", "rechnung", "bon", "datum", "zeit", "duplikat",
    ]

    /// Erste Zeile ohne Zahlen (Tankstellenname), Grossbuchstaben hübsch gemacht.
    func findStation(_ lines: [RecognizedLine]) -> String? {
        for line in lines.prefix(8) {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.contains(where: Self.isDigit) else { continue }
            let letters = text.filter(\.isLetter).count
            guard letters >= 3 else { continue }
            let lower = text.lowercased()
            if Self.genericHeaders.contains(where: { lower.hasPrefix($0) }) { continue }
            if Self.has(Self.reVAT, lower) || labelField(text) != nil && letters < 12 { continue }
            let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let pretty = collapsed == collapsed.uppercased() && letters > 3 ? collapsed.capitalized : collapsed
            return String(pretty.prefix(60))
        }
        return nil
    }

    // MARK: Tacho

    /// Kilometerstand eines Tokens: Ganzzahl mit 4–7 Stellen bzw. "53.410" als Tausender; sonst `nil`.
    static func kmValue(_ t: NumberToken) -> Int? {
        if t.isPercent || t.isImplied { return nil }
        if t.decimals == 0 {
            guard kmDigits.contains(t.intDigits), t.value < 10_000_000 else { return nil }
            return Int(t.value)
        }
        // Ein Trenner + genau drei Stellen → Tausendertrenner (nicht Tageskilometer)
        if t.decimals == 3, !t.grouped, (1...4).contains(t.intDigits) {
            let v = Int((t.value * 1000).rounded())
            return kmDigits.contains(String(v).count) ? v : nil
        }
        return nil   // Tageskilometer (123.4) usw.
    }

    private func evaluateOdometer(_ reading: inout ScanReading) {
        let last = lastKnownKm ?? 0
        let maxHeight = reading.tokens.map(\.box.height).max() ?? 1
        var scored: [(value: Int, token: Int, score: Double, plausible: Bool)] = []
        let candidates = reading.tokens.filter { !$0.ignored }
        let largest = candidates.compactMap(Self.kmValue).max()
        for t in candidates {
            guard let v = Self.kmValue(t) else { continue }
            var s = 0.2 * Double(String(v).count)
            s += (t.hints[.km] ?? 0) * 0.8
            s += maxHeight > 0 ? t.box.height / maxHeight * 0.4 : 0
            s += t.confidence * 0.3
            s -= t.penalty
            if t.decimals == 3 { s -= 0.1 }
            if v == largest { s += 0.1 }
            var plausible = true
            if last > 0 {
                plausible = v >= last - 50 && v <= last + 20_000
                if plausible {
                    s += 1.0 + 0.3 * (1 - min(1, max(0, Double(v - last) / 20_000)))
                } else {
                    s -= 1.0
                }
            }
            scored.append((value: v, token: t.id, score: s, plausible: plausible))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.value > $1.value }
        var seen = Set<Int>()
        let distinct = scored.filter { seen.insert($0.value).inserted }
        reading.kmAlternatives = distinct.map(\.value)

        guard let best = distinct.first(where: \.plausible) else {
            reading.confidence = 0
            reading.reason = distinct.isEmpty
                ? "Kein Kilometerstand (4–7 Stellen) erkannt."
                : "Kein plausibler Kilometerstand (zuletzt \(last) km) – bitte Zahl wählen."
            return
        }
        reading.km = best.value
        reading.kmToken = best.token
        let token = reading.token(best.token)
        var c = 0.5
        if (token?.hints[.km] ?? 0) >= 0.5 { c += 0.15 }
        if last > 0 { c += 0.25 }
        let others = distinct.filter { $0.value != best.value }
        if others.isEmpty { c += 0.1 }
        if let second = others.first, best.score - second.score < 0.3 { c -= 0.25 }
        c *= 0.85 + 0.15 * (token?.confidence ?? 0.5)
        reading.confidence = min(0.98, max(0.05, c))
        reading.reason = (token?.hints[.km] ?? 0) >= 0.5
            ? "Kilometerstand neben «km» erkannt."
            : "Grösste passende Zahl als Kilometerstand gewählt."
    }
}
