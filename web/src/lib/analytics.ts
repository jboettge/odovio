// Rechenintensive Auswertungen über alle Fahrten (100k+ je Mandant): Kilometerkette/Lücken, offene Bestätigungen,
// Filter + Volltextsuche + Summen der Fahrtentabelle, Monatsübersicht. Läuft im Web Worker
// (src/workers/analytics.worker.ts); ohne Worker (Tests, Fehler) dieselbe Klasse im Hauptthread.
// Datenhaltung inkrementell: `apply` übernimmt nur geänderte Datensätze, Sortierungen werden je Fahrzeug
// zwischengespeichert und nur bei Änderungen dieses Fahrzeugs neu aufgebaut.
import type { Place } from '../api/types'
import type { Delta, HealthResult, MonthSummary, PeriodLite, PlaceLite, CustomerLite, TripLite, TripQuery, TripQueryResult } from './slim'
import { monthOf } from './format'
import { routeText } from './privacy'
import { needsReview, tripKm } from './trips'

export type { TripLite, PeriodLite, PlaceLite, CustomerLite, Delta, HealthResult, TripQuery, TripQueryResult, MonthSummary } from './slim'

interface Rec extends TripLite {
  ts: number
  month: string
  km: number
  hay?: string
}

interface VehicleCache {
  /** alle Fahrten (inkl. stornierte), chronologisch */
  sorted: Rec[]
  months: string[]
}

/** Monat (YYYY-MM, lokale Zeit) aus bereits geparstem Zeitpunkt (ein Date je Fahrt statt zwei). */
function localMonth(ts: number, raw: string): string {
  if (Number.isNaN(ts)) return monthOf(raw)
  const d = new Date(ts)
  const m = d.getMonth() + 1
  return `${d.getFullYear()}-${m < 10 ? '0' : ''}${m}`
}

const cmp = (a: Rec, b: Rec) => a.ts - b.ts || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)

export class AnalyticsEngine {
  private trips = new Map<string, Rec>()
  private byVehicle = new Map<string, Map<string, Rec>>()
  private cache = new Map<string, VehicleCache>()
  private periods = new Map<string, PeriodLite>()
  private closed = new Map<string, Set<string>>()
  private places = new Map<string, PlaceLite>()
  private customers = new Map<string, CustomerLite>()

  get size(): number {
    return this.trips.size
  }

  reset(): void {
    this.trips.clear()
    this.byVehicle.clear()
    this.cache.clear()
    this.periods.clear()
    this.closed.clear()
    this.places.clear()
    this.customers.clear()
  }

  apply(d: Delta): void {
    for (const t of d.trips ?? []) {
      const prev = this.trips.get(t.id)
      if (prev && prev.vehicle_id !== t.vehicle_id) {
        this.byVehicle.get(prev.vehicle_id)?.delete(t.id)
        this.cache.delete(prev.vehicle_id)
      }
      const ts = Date.parse(t.start_at)
      const rec: Rec = { ...t, ts, month: localMonth(ts, t.start_at), km: tripKm(t) }
      this.trips.set(t.id, rec)
      let m = this.byVehicle.get(t.vehicle_id)
      if (!m) this.byVehicle.set(t.vehicle_id, (m = new Map()))
      m.set(t.id, rec)
      this.cache.delete(t.vehicle_id)
    }
    if (d.periods?.length) {
      for (const p of d.periods) this.periods.set(p.id, p)
      this.closed.clear()
      for (const p of this.periods.values()) {
        if (p.deleted || p.status !== 'closed') continue
        let s = this.closed.get(p.vehicle_id)
        if (!s) this.closed.set(p.vehicle_id, (s = new Set()))
        s.add(p.month)
      }
    }
    if (d.places?.length || d.customers?.length) {
      for (const p of d.places ?? []) this.places.set(p.id, p)
      for (const c of d.customers ?? []) this.customers.set(c.id, c)
      // Suchtexte hängen von Orts-/Kundennamen ab
      for (const r of this.trips.values()) r.hay = undefined
    }
  }

  private vehicle(vid: string): VehicleCache {
    let c = this.cache.get(vid)
    if (!c) {
      const sorted = [...(this.byVehicle.get(vid)?.values() ?? [])].sort(cmp)
      const months = [...new Set(sorted.map((r) => r.month))].sort().reverse()
      c = { sorted, months }
      this.cache.set(vid, c)
    }
    return c
  }

  /** Offene Bestätigungen, km-Lücken (nicht in abgeschlossenen Monaten) und geschätzte km-Stände je Fahrzeug. */
  health(vids: string[]): Record<string, HealthResult> {
    const out: Record<string, HealthResult> = {}
    for (const vid of vids) {
      const closed = this.closed.get(vid)
      let open = 0
      let gaps = 0
      let gapKm = 0
      let estimated = 0
      let prev: Rec | null = null
      for (const t of this.vehicle(vid).sorted) {
        if (t.deleted) continue
        if (needsReview(t)) open++
        if (t.km_estimated && t.status !== 'locked') estimated++
        if (prev && prev.km_end !== null && t.km_start !== null && prev.km_end !== t.km_start && !closed?.has(t.month)) {
          gaps++
          gapKm += Math.abs(t.km_start - prev.km_end)
        }
        prev = t
      }
      out[vid] = { open, gaps, gapKm, estimated }
    }
    return out
  }

  private hay(t: Rec): string {
    if (t.hay === undefined) {
      const lookup = (id: string) => this.places.get(id) as Place | undefined
      const c = t.customer_id ? this.customers.get(t.customer_id) : undefined
      const customer = t.customer_name || (c ? (c.ref ? `${c.name} (${c.ref})` : c.name) : null)
      const by = t.driver_name || t.created_by || '–'
      t.hay = [routeText(t, lookup).text, t.purpose, customer, t.note, by].filter(Boolean).join(' ').toLowerCase()
    }
    return t.hay
  }

  /** Fahrtentabelle: Filter, Suche (Teilstring, ohne Gross-/Kleinschreibung), neueste zuerst, Summen je Kategorie. */
  query(q: TripQuery): TripQueryResult {
    const { sorted, months } = this.vehicle(q.vid)
    const s = (q.q ?? '').trim().toLowerCase()
    const ids: string[] = []
    const by: Record<string, number> = {}
    let total = 0
    for (let i = sorted.length - 1; i >= 0; i--) {
      const t = sorted[i]!
      if (t.deleted && !q.showDeleted) continue
      if (q.month && t.month !== q.month) continue
      if (q.category && t.category !== q.category) continue
      if (q.status && (q.status === 'offen' ? !needsReview(t) : t.status !== q.status)) continue
      if (s && !this.hay(t).includes(s)) continue
      ids.push(t.id)
      if (!t.deleted) {
        by[t.category] = (by[t.category] ?? 0) + t.km
        total += t.km
      }
    }
    return { ids, sums: { by, total }, months }
  }

  /** Fahrten eines Monats (ohne stornierte) und davon offene, chronologisch. */
  monthSummary(vid: string, month: string): MonthSummary {
    let trips = 0
    const open: string[] = []
    for (const t of this.vehicle(vid).sorted) {
      if (t.deleted || t.month !== month) continue
      trips++
      if (needsReview(t)) open.push(t.id)
    }
    return { trips, open }
  }
}

export type EngineOp = 'health' | 'query' | 'monthSummary'
export type EngineRequest =
  | { op: 'reset' }
  | { op: 'apply'; delta: Delta }
  | { id: number; op: 'health'; args: [string[]] }
  | { id: number; op: 'query'; args: [TripQuery] }
  | { id: number; op: 'monthSummary'; args: [string, string] }
export type EngineResponse = { id: number; result: unknown } | { id: number; error: string }

/** Nachricht im Worker (oder Hauptthread) verarbeiten; liefert die Antwort für Anfragen mit `id`. */
export function handle(engine: AnalyticsEngine, m: EngineRequest): EngineResponse | null {
  switch (m.op) {
    case 'reset':
      engine.reset()
      return null
    case 'apply':
      engine.apply(m.delta)
      return null
    default:
      try {
        const result =
          m.op === 'health' ? engine.health(...m.args) : m.op === 'query' ? engine.query(...m.args) : engine.monthSummary(...m.args)
        return { id: m.id, result }
      } catch (e) {
        return { id: m.id, error: e instanceof Error ? e.message : 'Auswertung fehlgeschlagen' }
      }
  }
}
