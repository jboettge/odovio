// Formatierung de-CH (Schweizer Schreibweise: 53’410 km, CHF 1’234.50, 25.11.2026).
// Intl de-CH verwendet als Tausendertrennzeichen den typografischen Apostroph (’) – wie die iOS-App.

const LOCALE = 'de-CH'
const DASH = '–'

const intCache = new Map<string, Intl.NumberFormat>()
function nf(min: number, max: number): Intl.NumberFormat {
  const key = `${min}:${max}`
  let f = intCache.get(key)
  if (!f) {
    f = new Intl.NumberFormat(LOCALE, { minimumFractionDigits: min, maximumFractionDigits: max })
    intCache.set(key, f)
  }
  return f
}

const collator = new Intl.Collator(LOCALE)
/** Alphabetisch (de-CH), mit einmal instanziiertem Collator (statt localeCompare je Vergleich). */
export function byText(a: string, b: string): number {
  return collator.compare(a, b)
}
/** Schneller Vergleich nach Codepunkten (ISO-Daten, IDs). */
export function byCode(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0
}

export function isNum(v: unknown): v is number {
  return typeof v === 'number' && Number.isFinite(v)
}

/** Zahl mit Tausendertrennzeichen; `digits` = feste Nachkommastellen. */
export function num(v: number | null | undefined, digits = 0, maxDigits = digits): string {
  return isNum(v) ? nf(digits, Math.max(digits, maxDigits)).format(v) : DASH
}

export function km(v: number | null | undefined, digits = 0): string {
  return isNum(v) ? `${num(v, digits)} km` : DASH
}

export function chf(v: number | null | undefined, digits = 2): string {
  return isNum(v) ? `CHF ${num(v, digits)}` : DASH
}

export function liters(v: number | null | undefined, digits = 2): string {
  return isNum(v) ? `${num(v, digits)} l` : DASH
}

export function consumption(v: number | null | undefined): string {
  return isNum(v) ? `${num(v, 2)} l/100 km` : DASH
}

export function pct(v: number | null | undefined, digits = 1): string {
  return isNum(v) ? `${num(v, digits)} %` : DASH
}

/** Byte-Grösse für Belege. */
export function bytes(v: number | null | undefined): string {
  if (!isNum(v)) return DASH
  if (v < 1024) return `${v} B`
  if (v < 1024 * 1024) return `${num(v / 1024, 0)} KB`
  return `${num(v / (1024 * 1024), 1)} MB`
}

function parseDate(v: string): Date | null {
  // reines Datum (YYYY-MM-DD) als lokales Datum, nicht UTC (sonst Tagesversatz)
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(v)
  const d = m ? new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3])) : new Date(v)
  return Number.isNaN(d.getTime()) ? null : d
}

const dateFmt = new Intl.DateTimeFormat(LOCALE, { day: '2-digit', month: '2-digit', year: 'numeric' })
const dateShortFmt = new Intl.DateTimeFormat(LOCALE, { weekday: 'short', day: '2-digit', month: '2-digit' })
const timeFmt = new Intl.DateTimeFormat(LOCALE, { hour: '2-digit', minute: '2-digit' })
const monthFmt = new Intl.DateTimeFormat(LOCALE, { month: 'long', year: 'numeric' })
const monthShortFmt = new Intl.DateTimeFormat(LOCALE, { month: 'short', year: '2-digit' })

export function date(v: string | null | undefined): string {
  const d = v ? parseDate(v) : null
  return d ? dateFmt.format(d) : DASH
}

export function dateTime(v: string | null | undefined): string {
  const d = v ? parseDate(v) : null
  return d ? `${dateFmt.format(d)} ${timeFmt.format(d)}` : DASH
}

export function time(v: string | null | undefined): string {
  const d = v ? parseDate(v) : null
  return d ? timeFmt.format(d) : DASH
}

/** „Mo., 23.11.“ */
export function weekdayDate(v: string | null | undefined): string {
  const d = v ? parseDate(v) : null
  return d ? dateShortFmt.format(d) : DASH
}

/** „2026-11“ → „November 2026“ */
export function month(v: string | null | undefined): string {
  if (!v || !/^\d{4}-\d{2}$/.test(v)) return DASH
  const [y, m] = v.split('-').map(Number) as [number, number]
  return monthFmt.format(new Date(y, m - 1, 1))
}

export function monthShort(v: string): string {
  const [y, m] = v.split('-').map(Number) as [number, number]
  return monthShortFmt.format(new Date(y, m - 1, 1))
}

/** Monat (YYYY-MM) eines ISO-Zeitpunkts bzw. Datums in lokaler Zeit. */
export function monthOf(v: string): string {
  const d = parseDate(v)
  if (!d) return v.slice(0, 7)
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`
}

export function currentMonth(now = new Date()): string {
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`
}

export function previousMonth(m: string): string {
  const [y, mm] = m.split('-').map(Number) as [number, number]
  const d = new Date(y, mm - 2, 1)
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`
}

/** ISO-Datum (YYYY-MM-DD) in lokaler Zeit. */
export function isoDate(d = new Date()): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

/** Relative Zeitangabe für den Aktivitätsfeed. */
export function relative(v: string | null | undefined, now = new Date()): string {
  const d = v ? parseDate(v) : null
  if (!d) return DASH
  const s = Math.round((now.getTime() - d.getTime()) / 1000)
  if (s < 60) return 'gerade eben'
  if (s < 3600) return `vor ${Math.floor(s / 60)} Min.`
  if (s < 86400) return `vor ${Math.floor(s / 3600)} Std.`
  if (s < 7 * 86400) {
    const days = Math.floor(s / 86400)
    return days === 1 ? 'gestern' : `vor ${days} Tagen`
  }
  return date(v)
}

/** Kurzer Hash für Anzeigezwecke. */
export function shortHash(h: string | null | undefined, n = 12): string {
  return h ? `${h.slice(0, n)}…` : DASH
}
