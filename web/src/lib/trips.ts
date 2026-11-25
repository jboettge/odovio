// Fahrtenbuch-Logik clientseitig (gleich wie server/app/trips.py) für Übersichten.
import type { FuelEntry, Maintenance, Trip, TripGap, TripPeriod } from '../api/types'
import { monthOf } from './format'

export function tripKm(t: Trip): number {
  if (t.km_start !== null && t.km_end !== null) return t.km_end - t.km_start
  if (t.distance_route !== null) return t.distance_route
  return t.distance_gps ?? 0
}

export function needsReview(t: Trip): boolean {
  return !(t.status === 'confirmed' || t.status === 'locked') || t.category === 'unknown'
}

export function sortTrips(trips: Trip[]): Trip[] {
  return [...trips].sort((a, b) => {
    const d = new Date(a.start_at).getTime() - new Date(b.start_at).getTime()
    return d !== 0 ? d : a.id.localeCompare(b.id)
  })
}

/** km-Lücken der Kette (aktive Fahrten eines Fahrzeugs, chronologisch). */
export function kmGaps(trips: Trip[]): TripGap[] {
  const chain = sortTrips(trips.filter((t) => !t.deleted))
  const gaps: TripGap[] = []
  for (let i = 1; i < chain.length; i++) {
    const a = chain[i - 1]!
    const b = chain[i]!
    if (a.km_end !== null && b.km_start !== null && a.km_end !== b.km_start) {
      gaps.push({ after_trip_id: a.id, before_trip_id: b.id, km_from: a.km_end, km_to: b.km_start, km: b.km_start - a.km_end })
    }
  }
  return gaps
}

export function closedPeriod(periods: TripPeriod[], vehicleId: string, month: string): TripPeriod | undefined {
  return periods.find((p) => p.vehicle_id === vehicleId && p.month === month && p.status === 'closed' && !p.deleted)
}

/** Braucht ein Storno/eine Korrektur eine Begründung (abgeschlossener Monat)? */
export function stornoNeedsReason(
  entity: 'trip' | 'fuel' | 'odometer' | 'maintenance',
  rec: Trip | FuelEntry | Maintenance | { vehicle_id: string; date: string; km: number | null },
  periods: TripPeriod[],
): boolean {
  if (entity === 'trip') {
    const t = rec as Trip
    return t.status === 'locked' || Boolean(closedPeriod(periods, t.vehicle_id, monthOf(t.start_at)))
  }
  const r = rec as { vehicle_id: string; date: string; km: number | null }
  if (r.km === null || r.km === undefined) return false
  return Boolean(closedPeriod(periods, r.vehicle_id, r.date.slice(0, 7)))
}

export const MIN_REASON = 10
