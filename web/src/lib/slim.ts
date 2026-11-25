// Schlanke Datenformen für die Auswertungen (Worker): nur die nötigen Felder → günstiger zu übertragen.
// Eigenes kleines Modul, damit der Startpfad nicht die ganze Auswertungs-Engine enthält.
import type { Customer, Place, Trip, TripPeriod } from '../api/types'

/** Felder einer Fahrt, die für Auswertungen und Suche nötig sind (schlanker als Trip → günstiger zu übertragen). */
export const TRIP_FIELDS = [
  'id', 'vehicle_id', 'start_at', 'end_at', 'km_start', 'km_end', 'distance_gps', 'distance_route', 'category', 'status',
  'deleted', 'km_estimated', 'private_mode', 'start_place_id', 'end_place_id', 'start_label', 'end_label', 'purpose',
  'customer_id', 'customer_name', 'note', 'driver_name', 'created_by',
] as const satisfies readonly (keyof Trip)[]

export type TripLite = Pick<Trip, (typeof TRIP_FIELDS)[number]>
export type PeriodLite = Pick<TripPeriod, 'id' | 'vehicle_id' | 'month' | 'status' | 'deleted'>
export type PlaceLite = Pick<Place, 'id' | 'name' | 'private'>
export type CustomerLite = Pick<Customer, 'id' | 'name' | 'ref'>

export interface Delta {
  trips?: TripLite[]
  periods?: PeriodLite[]
  places?: PlaceLite[]
  customers?: CustomerLite[]
}

export interface HealthResult {
  open: number
  gaps: number
  gapKm: number
  estimated: number
}

export interface TripQuery {
  vid: string
  month?: string
  category?: string
  /** '' | 'offen' (zu bestätigen) | TripStatus */
  status?: string
  q?: string
  showDeleted?: boolean
}

export interface TripQueryResult {
  /** passende Fahrt-IDs, neueste zuerst (stabil: bei gleicher Startzeit nach ID) */
  ids: string[]
  sums: { by: Record<string, number>; total: number }
  /** Monate (YYYY-MM) mit Fahrten dieses Fahrzeugs, neueste zuerst */
  months: string[]
}

export interface MonthSummary {
  trips: number
  /** offene (zu bestätigende) Fahrten, chronologisch */
  open: string[]
}

/** Als Objekt-Literal (gleiche Form für alle Fahrten → schnell zu erzeugen und zu übertragen). */
export function slimTrip(t: Trip): TripLite {
  return {
    id: t.id,
    vehicle_id: t.vehicle_id,
    start_at: t.start_at,
    end_at: t.end_at ?? null,
    km_start: t.km_start ?? null,
    km_end: t.km_end ?? null,
    distance_gps: t.distance_gps ?? null,
    distance_route: t.distance_route ?? null,
    category: t.category,
    status: t.status,
    deleted: t.deleted,
    km_estimated: t.km_estimated ?? false,
    private_mode: t.private_mode ?? false,
    start_place_id: t.start_place_id ?? null,
    end_place_id: t.end_place_id ?? null,
    start_label: t.start_label ?? null,
    end_label: t.end_label ?? null,
    purpose: t.purpose ?? null,
    customer_id: t.customer_id ?? null,
    customer_name: t.customer_name ?? null,
    note: t.note ?? null,
    driver_name: t.driver_name ?? null,
    created_by: t.created_by ?? null,
  }
}
export const slimPeriod = (p: TripPeriod): PeriodLite => ({ id: p.id, vehicle_id: p.vehicle_id, month: p.month, status: p.status, deleted: p.deleted })
export const slimPlace = (p: Place): PlaceLite => ({ id: p.id, name: p.name, private: p.private })
export const slimCustomer = (c: Customer): CustomerLite => ({ id: c.id, name: c.name, ref: c.ref })

