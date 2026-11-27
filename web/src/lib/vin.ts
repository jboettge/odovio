// VIN (Fahrzeug-Identifizierungsnummer, Fahrgestellnummer) – gleiche Regeln wie server/app/schemas.py und die
// iOS-App (VIN.swift): Leerzeichen/Bindestriche entfernen, Grossbuchstaben; gültig sind genau 17 Zeichen aus
// Ziffern und Buchstaben ohne I, O, Q (ISO 3779). Die Prüfziffer (Stelle 9) wird nicht erzwungen (in Europa
// unüblich) – nur bei nordamerikanischen VINs (Stelle 1: 1–5, 7) gibt es einen Hinweis.

export const VIN_PATTERN = /^[A-HJ-NPR-Z0-9]{17}$/
export const VIN_ERROR = 'VIN ungültig: genau 17 Zeichen (Ziffern und Buchstaben ohne I, O, Q)'

/** Eingabe normalisieren; leer → ''. */
export function normalizeVin(raw: unknown): string {
  if (raw === null || raw === undefined) return ''
  return String(raw).replace(/[\s-]+/g, '').toUpperCase()
}

export function isValidVin(vin: string): boolean {
  return VIN_PATTERN.test(vin)
}

const TRANSLIT: Record<string, number> = {
  A: 1, B: 2, C: 3, D: 4, E: 5, F: 6, G: 7, H: 8, J: 1, K: 2, L: 3, M: 4, N: 5, P: 7, R: 9,
  S: 2, T: 3, U: 4, V: 5, W: 6, X: 7, Y: 8, Z: 9,
}
const WEIGHTS = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2]

/** Erwartete Prüfziffer (Stelle 9) nach 49 CFR 565; nur für gültige VINs. */
export function vinCheckDigit(vin: string): string | null {
  if (!isValidVin(vin)) return null
  let sum = 0
  for (let i = 0; i < 17; i++) {
    const c = vin[i]!
    const value = c >= '0' && c <= '9' ? Number(c) : TRANSLIT[c]!
    sum += value * WEIGHTS[i]!
  }
  const r = sum % 11
  return r === 10 ? 'X' : String(r)
}

/** Nordamerikanische VIN (Stelle 1: 1–5 oder 7) – dort ist die Prüfziffer Pflicht. */
export function isNorthAmerican(vin: string): boolean {
  return /^[1-57]/.test(vin)
}

/** Hinweis (kein Fehler) bei nordamerikanischer VIN mit nicht passender Prüfziffer, sonst null. */
export function vinWarning(vin: string): string | null {
  if (!isValidVin(vin) || !isNorthAmerican(vin)) return null
  const expected = vinCheckDigit(vin)
  return expected === vin[8] ? null : `Prüfziffer (Stelle 9) passt nicht – erwartet «${expected}». Bitte VIN kontrollieren.`
}

/** Normalisierte VIN für die Sync-Nutzdaten: leer → null (ungültige Werte bleiben stehen, damit die
 *  Validierung sie meldet). */
export function vinOrNull(raw: unknown): string | null {
  const v = normalizeVin(raw)
  return v ? v : null
}
