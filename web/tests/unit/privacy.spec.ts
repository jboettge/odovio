import { describe, expect, it } from 'vitest'
import type { Place, Trip } from '../../src/api/types'
import { isMaskedTrip, placeCoordinateText, placeShowsCoordinates, purposeText, routeText } from '../../src/lib/privacy'

const trip = (over: Partial<Trip>): Trip =>
  ({
    id: 't1', version: 1, deleted: false, vehicle_id: 'v', driver_sub: null, driver_name: 'Anna', start_at: '2026-11-21T10:15:00+01:00', end_at: null,
    km_start: 100, km_end: 107, distance_gps: null, distance_route: null, start_place_id: null, end_place_id: null, start_label: null, end_label: null,
    category: 'business', purpose: null, customer_id: null, customer_name: null, status: 'confirmed', source: 'auto', suggestion_category: null,
    suggestion_purpose: null, suggestion_customer_id: null, suggestion_confidence: null, suggestion_reason: null, suggestion_source: null,
    track_hash: null, split_of: null, private_mode: false, note: null, km_estimated: false, ...over,
  }) as Trip

const place = (over: Partial<Place>): Place =>
  ({ id: 'p1', version: 1, deleted: false, name: 'Büro', kind: 'work', lat: 47.389, lon: 8.517, radius_m: 150, customer_id: null, default_category: null, private: false, ...over }) as Place

describe('Maskierung (Leserolle)', () => {
  it('maskierte Privatfahrt erscheint als «Privatfahrt»', () => {
    const t = trip({ category: 'private' })
    expect(isMaskedTrip(t)).toBe(true)
    expect(routeText(t, () => undefined)).toEqual({ text: 'Privatfahrt', masked: true })
    expect(purposeText(t)).toBe('Privatfahrt')
  })
  it('Privatmodus zählt als privat', () => {
    expect(isMaskedTrip(trip({ category: 'commute', private_mode: true }))).toBe(true)
  })
  it('nicht maskierte Fahrt zeigt Orte; private Orte nur als «Privater Ort»', () => {
    const places: Record<string, Place> = { a: place({ id: 'a', name: 'Wohnort', kind: 'home', lat: null, lon: null }), b: place({ id: 'b', name: 'Arzt', private: true }) }
    const t = trip({ start_place_id: 'a', end_place_id: 'b' })
    expect(isMaskedTrip(t)).toBe(false)
    expect(routeText(t, (id) => places[id]).text).toBe('Wohnort → Privater Ort')
    expect(routeText(trip({ start_label: 'Zürich', end_label: 'Luzern', category: 'private' }), () => undefined).text).toBe('Zürich → Luzern')
  })
  it('Koordinaten von Wohnort/vertraulichen Orten werden nie angezeigt', () => {
    expect(placeShowsCoordinates(place({}))).toBe(true)
    expect(placeShowsCoordinates(place({ kind: 'home' }))).toBe(false)
    expect(placeShowsCoordinates(place({ private: true }))).toBe(false)
    expect(placeCoordinateText(place({ kind: 'home' }))).toMatch(/nur auf dem Gerät/)
    expect(placeCoordinateText(place({ private: true }))).toMatch(/vertraulich/)
  })
})
