// Auswertungen (Web Worker / Hauptthread): gleiche Ergebnisse wie die bisherige Logik, Suche, Sortierung,
// Fallback, wenn der Worker nicht startet oder abstürzt.
import { describe, expect, it } from 'vitest'
import { AnalyticsEngine, handle, type EngineRequest } from '../../src/lib/analytics'
import { Analytics } from '../../src/lib/analyticsClient'
import { slimTrip } from '../../src/lib/slim'
import { tripHealth } from '../../src/lib/vehicle'
import type { Trip, TripPeriod } from '../../src/api/types'

function trip(id: string, start: string, kmStart: number | null, kmEnd: number | null, over: Partial<Trip> = {}): Trip {
  return {
    id, version: 1, deleted: false, vehicle_id: 'v', driver_sub: null, driver_name: 'Anna', start_at: start, end_at: null, km_start: kmStart, km_end: kmEnd,
    distance_gps: null, distance_route: null, start_place_id: null, end_place_id: null, start_label: 'Zürich', end_label: 'Bern', category: 'business',
    purpose: 'Kundentermin', customer_id: null, customer_name: null, status: 'confirmed', source: 'auto', suggestion_category: null, suggestion_purpose: null,
    suggestion_customer_id: null, suggestion_confidence: null, suggestion_reason: null, suggestion_source: null, track_hash: null, split_of: null,
    private_mode: false, note: null, km_estimated: false, ...over,
  }
}
const period = (month: string): TripPeriod =>
  ({ id: `p${month}`, version: 1, deleted: false, vehicle_id: 'v', month, status: 'closed', closed_by: null, closed_at: null, anchor_seq: null, km_start: null, km_end: null, trips_count: 0, business_km: 0, private_km: 0, commute_km: 0, field_km: 0, note: null, corrections: 0 }) as TripPeriod

const trips = [
  trip('a', '2026-10-01T08:00:00+02:00', 100, 124),
  trip('b', '2026-10-02T08:00:00+02:00', 124, 130, { status: 'suggested' }),
  trip('c', '2026-11-03T08:00:00+01:00', 142, 150, { km_estimated: true, category: 'private', start_label: null, end_label: null, purpose: null }), // Lücke 12 km im November
  trip('d', '2026-11-03T08:00:00+01:00', 150, 160, { customer_name: 'Meier AG' }), // gleiche Startzeit wie c → Sortierung nach ID
  trip('e', '2026-11-04T08:00:00+01:00', 160, 170, { deleted: true }),
]

function engine(extra: TripPeriod[] = []) {
  const e = new AnalyticsEngine()
  e.apply({ trips: trips.map(slimTrip), periods: extra.map((p) => ({ id: p.id, vehicle_id: p.vehicle_id, month: p.month, status: p.status, deleted: p.deleted })) })
  return e
}

describe('AnalyticsEngine', () => {
  it('health entspricht tripHealth (offene, Lücken ohne abgeschlossene Monate, geschätzte km)', () => {
    for (const periods of [[], [period('2026-11')]]) {
      const ref = tripHealth(trips, periods, 'v')
      const got = engine(periods).health(['v']).v!
      expect(got).toEqual({ open: ref.open, gaps: ref.gaps.length, gapKm: ref.gapKm, estimated: ref.estimated })
    }
    expect(engine().health(['v']).v).toMatchObject({ open: 1, gaps: 1, gapKm: 12, estimated: 1 })
  })

  it('query: neueste zuerst, stabil bei gleicher Startzeit, Filter, Summen ohne stornierte, Monate', () => {
    const e = engine()
    const all = e.query({ vid: 'v' })
    expect(all.ids).toEqual(['d', 'c', 'b', 'a'])
    expect(all.months).toEqual(['2026-11', '2026-10'])
    expect(all.sums.total).toBe(24 + 6 + 8 + 10)
    expect(all.sums.by).toEqual({ business: 40, private: 8 })
    expect(e.query({ vid: 'v', showDeleted: true }).ids).toEqual(['e', 'd', 'c', 'b', 'a'])
    expect(e.query({ vid: 'v', month: '2026-10' }).ids).toEqual(['b', 'a'])
    expect(e.query({ vid: 'v', status: 'offen' }).ids).toEqual(['b'])
    expect(e.query({ vid: 'v', category: 'private' }).ids).toEqual(['c'])
  })

  it('Suche über Strecke, Zweck, Kunde, Erfasser; Ortsnamen-Änderung wirkt sofort', () => {
    const e = engine()
    expect(e.query({ vid: 'v', q: 'meier' }).ids).toEqual(['d'])
    expect(e.query({ vid: 'v', q: '  ANNA ' }).ids).toHaveLength(4)
    expect(e.query({ vid: 'v', q: 'privatfahrt' }).ids).toEqual(['c'])
    e.apply({ trips: [slimTrip(trip('f', '2026-11-05T08:00:00+01:00', 170, 180, { start_label: null, start_place_id: 'p1' }))] })
    e.apply({ places: [{ id: 'p1', name: 'Werkhof', private: false }] })
    expect(e.query({ vid: 'v', q: 'werkhof' }).ids).toEqual(['f'])
    e.apply({ places: [{ id: 'p1', name: 'Lager Ost', private: false }] })
    expect(e.query({ vid: 'v', q: 'werkhof' }).ids).toEqual([])
    expect(e.query({ vid: 'v', q: 'lager ost' }).ids).toEqual(['f'])
  })

  it('monthSummary und Fahrzeugwechsel einer Fahrt', () => {
    const e = engine()
    expect(e.monthSummary('v', '2026-10')).toEqual({ trips: 2, open: ['b'] })
    e.apply({ trips: [slimTrip({ ...trips[1]!, vehicle_id: 'w' })] })
    expect(e.monthSummary('v', '2026-10')).toEqual({ trips: 1, open: [] })
    expect(e.query({ vid: 'w' }).ids).toEqual(['b'])
  })

  it('100k Fahrten: Abfrage und Suche bleiben schnell', () => {
    const e = new AnalyticsEngine()
    const many: Trip[] = []
    for (let i = 0; i < 100_000; i++) many.push(trip(`t${i}`, new Date(Date.UTC(2015, 0, 1) + i * 3_600_000).toISOString(), i * 10, i * 10 + 10, { vehicle_id: `v${i % 3}`, purpose: `Termin ${i}` }))
    e.apply({ trips: many.map(slimTrip) })
    let t = performance.now()
    expect(e.query({ vid: 'v1' }).ids).toHaveLength(33_333)
    const firstQuery = performance.now() - t
    t = performance.now()
    expect(e.query({ vid: 'v0', q: 'termin 99999' }).ids).toEqual(['t99999'])
    expect(e.query({ vid: 'v1', q: 'termin 4' }).ids.length).toBeGreaterThan(1000)
    const search = performance.now() - t
    expect(firstQuery).toBeLessThan(1500)
    expect(search).toBeLessThan(1500)
  })
})

describe('Analytics (Client)', () => {
  /** Worker-Attrappe: verarbeitet Nachrichten asynchron mit derselben Engine. */
  class FakeWorker {
    engine = new AnalyticsEngine()
    onmessage: ((ev: MessageEvent) => void) | null = null
    onerror: ((ev: ErrorEvent) => void) | null = null
    onmessageerror: (() => void) | null = null
    received: EngineRequest[] = []
    postMessage(m: EngineRequest) {
      this.received.push(m)
      const res = handle(this.engine, structuredClone(m))
      if (res) setTimeout(() => this.onmessage?.({ data: res } as MessageEvent), 0)
    }
    terminate() {}
  }

  it('Hauptthread (ohne Worker): gleiche Antworten, asynchron', async () => {
    const a = new Analytics({ useWorker: false })
    a.apply({ trips: trips.map(slimTrip) })
    await expect(a.query({ vid: 'v' })).resolves.toMatchObject({ ids: ['d', 'c', 'b', 'a'] })
    expect(a.mode).toBe('inline')
  })

  it('Worker: Nachrichten vor dem Start werden nachgereicht', async () => {
    const w = new FakeWorker()
    let ready!: (w: Worker) => void
    const a = new Analytics({ useWorker: true, createWorker: () => new Promise((r) => (ready = r)) })
    a.apply({ trips: trips.map(slimTrip) })
    const q = a.health(['v'])
    ready(w as unknown as Worker)
    await expect(q).resolves.toMatchObject({ v: { open: 1, gaps: 1 } })
    expect(a.mode).toBe('worker')
    expect(w.received.map((m) => m.op)).toEqual(['apply', 'health'])
  })

  it('Worker startet nicht (z. B. CSP) → Hauptthread mit aktuellem Datenstand', async () => {
    const a = new Analytics({ useWorker: true, createWorker: () => Promise.reject(new Error('blocked')) })
    a.setReplay(() => ({ trips: trips.map(slimTrip) }))
    a.apply({ trips: trips.map(slimTrip) })
    await expect(a.monthSummary('v', '2026-10')).resolves.toEqual({ trips: 2, open: ['b'] })
    expect(a.mode).toBe('inline')
  })

  it('Worker-Absturz → offene Anfragen werden im Hauptthread beantwortet', async () => {
    const w = new FakeWorker()
    w.postMessage = function (m: EngineRequest) {
      this.received.push(m)
    }
    const a = new Analytics({ useWorker: true, createWorker: async () => w as unknown as Worker })
    a.setReplay(() => ({ trips: trips.map(slimTrip) }))
    await new Promise((r) => setTimeout(r, 0))
    const q = a.query({ vid: 'v', status: 'offen' })
    w.onerror?.({ preventDefault() {} } as ErrorEvent)
    await expect(q).resolves.toMatchObject({ ids: ['b'] })
    expect(a.mode).toBe('inline')
  })
})
