import Foundation

/// VIN (Fahrzeug-Identifizierungsnummer, Fahrgestellnummer) – gleiche Regeln wie der Server
/// (`schemas.normalize_vin`) und das Web (`web/src/lib/vin.ts`): Leerzeichen/Bindestriche entfernen,
/// Grossbuchstaben; gültig sind genau 17 Zeichen aus Ziffern und Buchstaben ohne I, O, Q (ISO 3779).
/// Die Prüfziffer (Stelle 9) wird nicht erzwungen (in Europa unüblich) – nur bei nordamerikanischen VINs
/// (Stelle 1: 1–5, 7) gibt es einen Hinweis.
enum VIN {
    static let length = 17
    static let errorText = "VIN ungültig: genau 17 Zeichen (Ziffern und Buchstaben ohne I, O, Q)"
    static let hintText = "17 Zeichen – im Fahrzeugausweis (Fahrgestell-Nr.) oder unten an der Windschutzscheibe."

    /// Zulässige Zeichen (ohne I, O, Q)
    static let allowed: Set<Character> = Set("ABCDEFGHJKLMNPRSTUVWXYZ0123456789")

    // MARK: Normalisieren / Prüfen

    /// Leerraum und Bindestriche entfernen, Grossbuchstaben (leer → "").
    static func normalize(_ raw: String) -> String {
        var kept = String.UnicodeScalarView()
        for u in raw.unicodeScalars where u != "-" && !CharacterSet.whitespacesAndNewlines.contains(u) {
            kept.append(u)
        }
        return String(kept).uppercased()
    }

    /// Normalisiert; leer → `nil` (keine VIN). Ungültige Werte bleiben stehen (Prüfung mit `isValid`).
    static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let v = normalize(raw)
        return v.isEmpty ? nil : v
    }

    /// Genau 17 zulässige Zeichen (bereits normalisiert).
    static func isValid(_ vin: String) -> Bool {
        vin.count == length && vin.allSatisfy { allowed.contains($0) }
    }

    /// Eingabe zulässig: leer oder (normalisiert) gültig.
    static func isAcceptable(_ raw: String) -> Bool {
        let v = normalize(raw)
        return v.isEmpty || isValid(v)
    }

    // MARK: Prüfziffer (nur Hinweis)

    private static let transliteration: [Character: Int] = [
        "A": 1, "B": 2, "C": 3, "D": 4, "E": 5, "F": 6, "G": 7, "H": 8, "J": 1, "K": 2, "L": 3, "M": 4,
        "N": 5, "P": 7, "R": 9, "S": 2, "T": 3, "U": 4, "V": 5, "W": 6, "X": 7, "Y": 8, "Z": 9,
    ]
    private static let weights = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2]

    /// Erwartete Prüfziffer (Stelle 9, "0"–"9" oder "X") nach 49 CFR 565; `nil` bei ungültiger VIN.
    static func checkDigit(_ vin: String) -> Character? {
        guard isValid(vin) else { return nil }
        var sum = 0
        for (i, c) in vin.enumerated() {
            guard let value = c.wholeNumberValue ?? transliteration[c] else { return nil }
            sum += value * weights[i]
        }
        let r = sum % 11
        return r == 10 ? "X" : Character(String(r))
    }

    /// Nordamerikanische VIN (Stelle 1: 1–5 oder 7) – dort ist die Prüfziffer Pflicht.
    static func isNorthAmerican(_ vin: String) -> Bool {
        guard let first = vin.first else { return false }
        return "123457".contains(first)
    }

    /// Prüfziffer stimmt (oder ist ausserhalb Nordamerikas nicht massgebend).
    static func checkDigitPlausible(_ vin: String) -> Bool {
        guard isValid(vin), isNorthAmerican(vin) else { return true }
        return checkDigit(vin) == Array(vin)[8]
    }

    /// Hinweis (kein Fehler) bei nordamerikanischer VIN mit nicht passender Prüfziffer, sonst `nil`.
    static func warning(_ vin: String) -> String? {
        guard isValid(vin), !checkDigitPlausible(vin), let expected = checkDigit(vin) else { return nil }
        return "Prüfziffer (Stelle 9) passt nicht – erwartet «\(expected)». Bitte VIN kontrollieren."
    }

    // MARK: Scan (Barcode/Texterkennung)

    /// Häufige OCR-Verwechslungen: I, O, Q kommen in einer VIN nie vor → 1, 0, 0.
    static func correctOCR(_ s: String) -> String {
        String(s.map { c -> Character in
            switch c {
            case "I": return "1"
            case "O", "Q": return "0"
            default: return c
            }
        })
    }

    struct Token: Equatable {
        var text: String
        /// Vom vorherigen Token nur durch Leerzeichen/Bindestriche getrennt (darf angehängt werden)
        var joinsPrevious: Bool
    }

    /// Folgen von A–Z/0–9 (Grossbuchstaben); andere Zeichen trennen.
    static func tokens(_ text: String) -> [Token] {
        var out: [Token] = []
        var current = ""
        var joinable = false
        for ch in text.uppercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                current.append(ch)
                continue
            }
            if !current.isEmpty {
                out.append(Token(text: current, joinsPrevious: joinable))
                current = ""
                joinable = true
            }
            if ch != " " && ch != "-" && ch != "\u{00A0}" { joinable = false }
        }
        if !current.isEmpty { out.append(Token(text: current, joinsPrevious: joinable)) }
        return out
    }

    /// Mindestens ein Buchstabe und eine Ziffer (reine Zahlen auf Quittungen/Strichcodes sind keine VIN).
    private static func plausible(_ vin: String) -> Bool {
        vin.contains(where: { $0.isLetter }) && vin.contains(where: { $0.isNumber })
    }

    /// Gültige VINs in einem erkannten Text oder Barcode-Inhalt (normalisiert, OCR-korrigiert, ohne Doppel).
    /// Ganze 17er-Folgen zuerst (auch mit führendem „I“ = Import-Kennzeichen nordamerikanischer Code-39-Etiketten),
    /// danach in Gruppen gedruckte VINs („WVW ZZZ 1KZ 6W 000001“) – dort ohne OCR-Korrektur und mit numerischen
    /// letzten vier Stellen (ISO 3779), damit zusammengesetzte Textzeilen („TOTAL 1234 …“) nicht als VIN gelten.
    static func candidates(in text: String) -> [String] {
        let toks = tokens(text)
        var found: [String] = []
        func add(_ raw: String, grouped: Bool) {
            let vin = grouped ? raw : correctOCR(raw)
            guard isValid(vin), plausible(vin), !found.contains(vin) else { return }
            if grouped && !vin.suffix(4).allSatisfy({ $0.isNumber }) { return }
            found.append(vin)
        }
        for t in toks {
            if t.text.count == length + 1, t.text.first == "I" { add(String(t.text.dropFirst()), grouped: false) }
            if t.text.count == length { add(t.text, grouped: false) }
        }
        for i in toks.indices {
            var joined = toks[i].text
            var j = i + 1
            while joined.count < length, j < toks.count, toks[j].joinsPrevious {
                joined += toks[j].text
                j += 1
            }
            if j > i + 1, joined.count == length { add(joined, grouped: true) }
        }
        return found
    }

    /// Bester Kandidat aus mehreren Texten: zuerst einer mit plausibler Prüfziffer.
    static func bestCandidate(in texts: [String]) -> String? {
        let all = texts.flatMap { candidates(in: $0) }
        return all.first(where: checkDigitPlausible) ?? all.first
    }

    /// Für VoiceOver: Zeichen einzeln vorlesen.
    static func spoken(_ vin: String) -> String {
        vin.map { String($0) }.joined(separator: " ")
    }
}
