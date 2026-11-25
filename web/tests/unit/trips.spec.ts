import { describe, expect, it } from 'vitest'
import type { Trip, TripPeriod } from '../../src/api/types'
import { kmGaps, needsReview, stornoNeedsReason, tripKm } from '../../src/lib/trips'
import { tripHealth } from '../../src/lib/vehicle'

const t = (id: string, start: string, a: number | null, b: number | null, over: Partial<Trip> = {}) =>
  ({ id, vehicle_id: 'v', start_at: start, km_start: a, km_end: b, deleted: false, status: 'confirmed', category: 'commute', distance_gps: null, distance_route: null, km_estimated: false, ...over }) as Trip
const period = (month: string): TripPeriod => ({ id: 'p', vehicle_id: 'v', month, status: 'closed', deleted: false } as TripPeriod)

describe('Fahrtenbuch-Logik', () => {
  it('km und Bestätigung', () => {
    expect(tripKm(t('a', '2026-11-01T08:00:00+01:00', 100, 112))).toBe(12)
    expect(tripKm(t('a', '2026-11-01T08:00:00+01:00', null, null, { distance_gps: 7.5 }))).toBe(7.5)
    expect(needsReview(t('a', '2026-11-01T08:00:00+01:00', 1, 2, { status: 'suggested' }))).toBe(true)
    expect(needsReview(t('a', '2026-11-01T08:00:00+01:00', 1, 2, { category: 'unknown' }))).toBe(true)
    expect(needsReview(t('a', '2026-11-01T08:00:00+01:00', 1, 2, { status: 'locked' }))).toBe(false)
  })
  it('Lücken in der Kilometerkette (unsortiert, Stornos ignoriert)', () => {
    const trips = [
      t('c', '2026-11-03T08:00:00+01:00', 136, 148),
      t('a', '2026-11-01T08:00:00+01:00', 100, 112),
      t('x', '2026-11-02T07:00:00+01:00', 112, 200, { deleted: true }),
      t('b', '2026-11-02T08:00:00+01:00', 112, 124),
    ]
    expect(kmGaps(trips)).toEqual([{ after_trip_id: 'b', before_trip_id: 'c', km_from: 124, km_to: 136, km: 12 }])
  })
  it('Lücken in abgeschlossenen Monaten zählen nicht mehr', () => {
    const trips = [t('a', '2026-10-01T08:00:00+02:00', 100, 112), t('b', '2026-10-02T08:00:00+02:00', 120, 130, { status: 'locked' })]
    expect(tripHealth(trips, [], 'v').gaps).toHaveLength(1)
    expect(tripHealth(trips, [period('2026-10')], 'v').gaps).toHaveLength(0)
  })
  it('Storno-Begründung nur im abgeschlossenen Monat', () => {
    const periods = [period('2026-10')]
    expect(stornoNeedsReason('trip', t('a', '2026-10-05T08:00:00+02:00', 1, 2), periods)).toBe(true)
    expect(stornoNeedsReason('trip', t('a', '2026-11-05T08:00:00+01:00', 1, 2), periods)).toBe(false)
    expect(stornoNeedsReason('trip', t('a', '2026-11-05T08:00:00+01:00', 1, 2, { status: 'locked' }), periods)).toBe(true)
    expect(stornoNeedsReason('fuel', { vehicle_id: 'v', date: '2026-10-09', km: 5 }, periods)).toBe(true)
    expect(stornoNeedsReason('maintenance', { vehicle_id: 'v', date: '2026-10-09', km: null }, periods)).toBe(false)
  })
})
