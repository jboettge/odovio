// Kilometerstände eines Fahrzeugs (abgelesen, Tanken, Wartung, Fahrten) für Vorschläge und Plausibilität beim
// Erfassen im Web. Nur Hinweise – gespeichert wird trotzdem (Korrekturen alter Einträge bleiben möglich).
import type { FuelEntry, Maintenance, OdometerReading, Trip } from '../api/types'
import { date as fmtDate, km as fmtKm } from './format'

export interface KmPoint {
  /** ID des Datensatzes (beim Bearbeiten ausgenommen) */
  id: string
  date: string
  km: number
}

export function kmPoints(src: { odometer: OdometerReading[]; fuel: FuelEntry[]; maintenance: Maintenance[]; trips: Trip[] }): KmPoint[] {
  const out: KmPoint[] = []
  for (const o of src.odometer) if (!o.deleted) out.push({ id: o.id, date: o.date, km: o.km })
  for (const f of src.fuel) if (!f.deleted) out.push({ id: f.id, date: f.date, km: f.km })
  for (const m of src.maintenance) if (!m.deleted && m.km !== null) out.push({ id: m.id, date: m.date, km: m.km })
  for (const t of src.trips) {
    if (t.deleted) continue
    const day = t.start_at.slice(0, 10)
    if (t.km_start !== null) out.push({ id: t.id, date: day, km: t.km_start })
    if (t.km_end !== null) out.push({ id: t.id, date: (t.end_at ?? t.start_at).slice(0, 10), km: t.km_end })
  }
  return out
}

/** Aktueller Stand = Maximum aller Werte (mindestens Start-km). */
export function currentKm(points: KmPoint[], initialKm: number): number {
  return points.reduce((a, p) => Math.max(a, p.km), initialKm)
}

/**
 * Passt `km` am Tag `day` zu den übrigen Ständen? Hinweis, wenn er unter einem früheren oder über einem späteren
 * Stand liegt oder unter dem Start-km. `null` = plausibel bzw. nicht prüfbar.
 */
export function kmWarning(points: KmPoint[], day: string, km: number | null, initialKm: number, excludeId?: string | null): string | null {
  if (km === null || !Number.isFinite(km) || !/^\d{4}-\d{2}-\d{2}$/.test(day)) return null
  if (km < initialKm) return `Unter dem Start-km des Fahrzeugs (${fmtKm(initialKm)}).`
  let before: KmPoint | null = null
  let after: KmPoint | null = null
  for (const p of points) {
    if (p.id === excludeId) continue
    if (p.date < day && p.km > km && (!before || p.km > before.km)) before = p
    if (p.date > day && p.km < km && (!after || p.km < after.km)) after = p
  }
  if (before) return `Kleiner als ${fmtKm(before.km)} am ${fmtDate(before.date)} – bitte prüfen.`
  if (after) return `Grösser als ${fmtKm(after.km)} am ${fmtDate(after.date)} – bitte prüfen.`
  return null
}

/** Literpreis ausserhalb des Üblichen (Tippfehler bei Betrag oder Litern)? */
export function pricePerLiterWarning(liters: number | null, total: number | null): string | null {
  if (!liters || total === null || !Number.isFinite(liters) || !Number.isFinite(total) || liters <= 0) return null
  const p = total / liters
  if (p < 0.5 || p > 5) return `${p.toFixed(2)} CHF/l wirkt ungewöhnlich – Liter und Betrag prüfen.`
  return null
}
