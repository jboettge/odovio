// Kennzahlen je Fahrzeug aus dem geladenen Datenbestand.
import type { Trip, TripGap, TripPeriod } from '../api/types'
import { monthOf } from './format'
import { closedPeriod, kmGaps, needsReview } from './trips'

export interface TripHealth {
  open: number
  gaps: TripGap[]
  gapKm: number
  estimated: number
}

/** Offene Bestätigungen und km-Lücken (Lücken in abgeschlossenen Monaten zählen nicht mehr). */
export function tripHealth(trips: Trip[], periods: TripPeriod[], vehicleId: string): TripHealth {
  const mine = trips.filter((t) => t.vehicle_id === vehicleId && !t.deleted)
  const byId = new Map(mine.map((t) => [t.id, t]))
  const gaps = kmGaps(mine).filter((g) => {
    const t = byId.get(g.before_trip_id)
    return t ? !closedPeriod(periods, vehicleId, monthOf(t.start_at)) : true
  })
  return {
    open: mine.filter(needsReview).length,
    gaps,
    gapKm: gaps.reduce((a, g) => a + Math.abs(g.km), 0),
    estimated: mine.filter((t) => t.km_estimated && t.status !== 'locked').length,
  }
}
