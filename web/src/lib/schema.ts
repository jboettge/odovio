// Feldgrenzen wie server/app/schemas.py – Validierung vor dem Senden (der Server prüft erneut).
import type { EntityMap, EntityName, SyncOp } from '../api/types'
import { VIN_ERROR, VIN_PATTERN } from './vin'

type Spec =
  | { type: 'string'; min?: number; max: number; required?: boolean; pattern?: RegExp; patternMsg?: string }
  | { type: 'number'; min?: number; max: number; gt?: number; int?: boolean; required?: boolean }
  | { type: 'enum'; values: readonly (string | null)[]; required?: boolean }
  | { type: 'bool' }
  | { type: 'date'; required?: boolean }
  | { type: 'ref'; required?: boolean }
  | { type: 'ts'; required?: boolean }

const MAX_KM = 5_000_000
const NOTE = 2000
const HHMM = /^([01]\d|2[0-3]):[0-5]\d$/
const CATS = ['business', 'private', 'commute', 'field', 'unknown'] as const

export const SCHEMAS: Record<EntityName, Record<string, Spec>> = {
  vehicle: {
    name: { type: 'string', min: 1, max: 100, required: true },
    make: { type: 'string', max: 100 },
    model: { type: 'string', max: 100 },
    plate: { type: 'string', max: 30 },
    fuel_type: { type: 'string', min: 1, max: 20, required: true },
    initial_km: { type: 'number', min: 0, max: MAX_KM, int: true, required: true },
    purchase_price: { type: 'number', min: 0, max: 10_000_000 },
    ownership: { type: 'enum', values: ['private', 'business', null] },
    private_use_method: { type: 'enum', values: ['flat', 'effective', null] },
    annual_fixed_costs: { type: 'number', min: 0, max: 1_000_000 },
    // Rohlänge wie der Server (40); normalisiert (vinOrNull) muss sie dem Muster entsprechen
    vin: { type: 'string', max: 40, pattern: VIN_PATTERN, patternMsg: VIN_ERROR },
  },
  odometer: {
    vehicle_id: { type: 'ref', required: true },
    date: { type: 'date', required: true },
    km: { type: 'number', min: 0, max: MAX_KM, int: true, required: true },
    note: { type: 'string', max: NOTE },
  },
  fuel: {
    vehicle_id: { type: 'ref', required: true },
    date: { type: 'date', required: true },
    km: { type: 'number', min: 0, max: MAX_KM, int: true, required: true },
    liters: { type: 'number', gt: 0, max: 5000, required: true },
    price_total: { type: 'number', min: 0, max: 100_000, required: true },
    full_tank: { type: 'bool' },
    station: { type: 'string', max: 100 },
    note: { type: 'string', max: NOTE },
  },
  maintenance: {
    vehicle_id: { type: 'ref', required: true },
    date: { type: 'date', required: true },
    km: { type: 'number', min: 0, max: MAX_KM, int: true },
    title: { type: 'string', min: 1, max: 150, required: true },
    cost: { type: 'number', min: 0, max: 1_000_000 },
    note: { type: 'string', max: NOTE },
    next_due_km: { type: 'number', min: 0, max: MAX_KM, int: true },
    next_due_date: { type: 'date' },
  },
  maintenance_item: {
    maintenance_id: { type: 'ref', required: true },
    label: { type: 'string', min: 1, max: 200, required: true },
    done: { type: 'bool' },
    position: { type: 'number', min: 0, max: 10_000, int: true },
  },
  maintenance_material: {
    maintenance_id: { type: 'ref', required: true },
    article_id: { type: 'ref' },
    name: { type: 'string', min: 1, max: 150, required: true },
    part_number: { type: 'string', max: 60 },
    quantity: { type: 'number', gt: 0, max: 100_000, required: true },
    unit: { type: 'string', min: 1, max: 20, required: true },
    unit_price: { type: 'number', min: 0, max: 100_000 },
    position: { type: 'number', min: 0, max: 10_000, int: true },
  },
  material_article: {
    name: { type: 'string', min: 1, max: 150, required: true },
    part_number: { type: 'string', max: 60 },
    unit: { type: 'string', min: 1, max: 20, required: true },
    unit_price: { type: 'number', min: 0, max: 100_000 },
    category: { type: 'string', max: 50 },
    vehicle_id: { type: 'ref' },
    note: { type: 'string', max: 500 },
  },
  customer: {
    name: { type: 'string', min: 1, max: 150, required: true },
    ref: { type: 'string', max: 50 },
    note: { type: 'string', max: 500 },
  },
  place: {
    name: { type: 'string', min: 1, max: 100, required: true },
    kind: { type: 'enum', values: ['home', 'work', 'customer', 'other'], required: true },
    lat: { type: 'number', min: -90, max: 90 },
    lon: { type: 'number', min: -180, max: 180 },
    radius_m: { type: 'number', min: 50, max: 5000, int: true, required: true },
    customer_id: { type: 'ref' },
    default_category: { type: 'enum', values: [...CATS, null] },
    private: { type: 'bool' },
  },
  trip: {
    vehicle_id: { type: 'ref', required: true },
    driver_sub: { type: 'string', max: 255 },
    driver_name: { type: 'string', max: 100 },
    start_at: { type: 'ts', required: true },
    end_at: { type: 'ts' },
    km_start: { type: 'number', min: 0, max: MAX_KM, int: true },
    km_end: { type: 'number', min: 0, max: MAX_KM, int: true },
    distance_gps: { type: 'number', min: 0, max: 10_000 },
    distance_route: { type: 'number', min: 0, max: 10_000 },
    start_place_id: { type: 'ref' },
    end_place_id: { type: 'ref' },
    start_label: { type: 'string', max: 200 },
    end_label: { type: 'string', max: 200 },
    category: { type: 'enum', values: CATS, required: true },
    purpose: { type: 'string', max: 300 },
    customer_id: { type: 'ref' },
    customer_name: { type: 'string', max: 150 },
    status: { type: 'enum', values: ['draft', 'suggested', 'confirmed', 'locked'], required: true },
    source: { type: 'enum', values: ['auto', 'manual', 'gap', 'import'], required: true },
    suggestion_category: { type: 'enum', values: [...CATS, null] },
    suggestion_purpose: { type: 'string', max: 300 },
    suggestion_customer_id: { type: 'ref' },
    suggestion_confidence: { type: 'number', min: 0, max: 1 },
    suggestion_reason: { type: 'string', max: 300 },
    suggestion_source: { type: 'enum', values: ['rule', 'calendar', 'pattern', 'llm', null] },
    track_hash: { type: 'string', max: 64 },
    split_of: { type: 'ref' },
    private_mode: { type: 'bool' },
    note: { type: 'string', max: NOTE },
    km_estimated: { type: 'bool' },
  },
  purpose_rule: {
    priority: { type: 'number', min: 0, max: 1000, int: true, required: true },
    from_place_id: { type: 'ref' },
    to_place_id: { type: 'ref' },
    weekdays: { type: 'string', max: 20, pattern: /^([1-7])(,[1-7])*$/, patternMsg: 'Format 1,2,3 (ISO-Wochentage 1–7)' },
    time_from: { type: 'string', max: 5, pattern: HHMM, patternMsg: 'Format HH:MM' },
    time_to: { type: 'string', max: 5, pattern: HHMM, patternMsg: 'Format HH:MM' },
    vehicle_id: { type: 'ref' },
    result_category: { type: 'enum', values: ['business', 'private', 'commute', 'field'], required: true },
    result_purpose: { type: 'string', max: 300 },
    result_customer_id: { type: 'ref' },
    auto_confirm: { type: 'bool' },
    origin: { type: 'enum', values: ['user', 'learned'], required: true },
    active: { type: 'bool' },
  },
  tax_param: {
    year: { type: 'number', min: 2000, max: 2100, int: true, required: true },
    scope: { type: 'string', max: 30, required: true, pattern: /^(federal|canton:[A-Z]{2}|tenant)$/, patternMsg: 'Bund, Kanton (2 Buchstaben) oder Fahrzeugbuch' },
    key: { type: 'enum', values: ['km_rate', 'commute_rate', 'cap_federal', 'cap_canton', 'private_share_pct', 'min_private_month', 'vat_rate'], required: true },
    value: { type: 'number', min: 0, max: 1_000_000, required: true },
    source_url: { type: 'string', max: 300 },
    note: { type: 'string', max: 300 },
  },
  trip_period: {},
  attachment: {
    fuel_id: { type: 'ref' },
    maintenance_id: { type: 'ref' },
    vehicle_id: { type: 'ref' },
    kind: { type: 'enum', values: ['receipt', 'pump', 'odometer', 'other'], required: true },
    sha256: { type: 'string', min: 64, max: 64, required: true },
    mime: { type: 'enum', values: ['image/jpeg', 'image/heic', 'application/pdf'], required: true },
    size: { type: 'number', min: 1, max: 8 * 1024 * 1024, int: true, required: true },
    taken_at: { type: 'ts' },
    note: { type: 'string', max: 300 },
  },
}

export type FieldErrors = Record<string, string>

function empty(v: unknown): boolean {
  return v === null || v === undefined || v === ''
}

/** Prüft Daten gegen die Feldgrenzen. Rückgabe: Feld → deutsche Fehlermeldung. */
export function validate(entity: EntityName, data: Record<string, unknown>): FieldErrors {
  const errors: FieldErrors = {}
  const specs = SCHEMAS[entity]
  for (const [field, spec] of Object.entries(specs)) {
    const v = data[field]
    if (spec.type === 'bool') continue
    if (empty(v)) {
      if ('required' in spec && spec.required) errors[field] = 'Pflichtfeld'
      continue
    }
    switch (spec.type) {
      case 'string': {
        const s = String(v)
        if (spec.min !== undefined && s.trim().length < spec.min) errors[field] = spec.min <= 1 ? 'Pflichtfeld' : `mind. ${spec.min} Zeichen`
        else if (s.length > spec.max) errors[field] = `höchstens ${spec.max} Zeichen`
        else if (spec.pattern && !spec.pattern.test(s)) errors[field] = spec.patternMsg ?? 'ungültiges Format'
        break
      }
      case 'number': {
        const n = typeof v === 'number' ? v : Number(v)
        if (!Number.isFinite(n)) errors[field] = 'Zahl erwartet'
        else if (spec.int && !Number.isInteger(n)) errors[field] = 'ganze Zahl erwartet'
        else if (spec.gt !== undefined && n <= spec.gt) errors[field] = `muss grösser als ${spec.gt} sein`
        else if (spec.min !== undefined && n < spec.min) errors[field] = `mindestens ${spec.min}`
        else if (n > spec.max) errors[field] = `höchstens ${spec.max.toLocaleString('de-CH')}`
        break
      }
      case 'enum':
        if (!spec.values.includes(v as string)) errors[field] = 'ungültiger Wert'
        break
      case 'date':
        if (!/^\d{4}-\d{2}-\d{2}$/.test(String(v))) errors[field] = 'Datum erwartet'
        break
      case 'ts':
        if (Number.isNaN(new Date(String(v)).getTime())) errors[field] = 'Zeitpunkt erwartet'
        break
      case 'ref':
        if (String(v).length > 36) errors[field] = 'ungültiger Verweis'
        break
    }
  }
  if (entity === 'place' && (data.kind === 'home' || data.private) && (!empty(data.lat) || !empty(data.lon))) {
    errors.lat = 'Koordinaten von Wohnort und vertraulichen Orten bleiben auf dem Gerät'
  }
  if (entity === 'purpose_rule' && typeof data.weekdays === 'string' && data.weekdays) {
    const days = data.weekdays.split(',')
    if (new Set(days).size !== days.length) errors.weekdays = 'Wochentage ohne Doppel'
  }
  return errors
}

/** Felder eines Objekts für eine Upsert-Op (ohne id/version/deleted/Metadaten). Der Server ersetzt
 *  alle Felder – fehlende würden auf den Default zurückgesetzt, daher immer das ganze Objekt senden. */
export function toData<E extends EntityName>(entity: E, rec: Partial<EntityMap[E]> | Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  const r = rec as Record<string, unknown>
  for (const field of Object.keys(SCHEMAS[entity])) {
    const v = r[field]
    out[field] = v === '' || v === undefined ? null : v
  }
  // Defaults des Servers für Bool-Felder statt null
  for (const [field, spec] of Object.entries(SCHEMAS[entity])) {
    if (spec.type === 'bool' && out[field] === null) out[field] = field === 'active' || field === 'full_tank'
  }
  return out
}

export function uuid(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') return crypto.randomUUID()
  const b = new Uint8Array(16)
  crypto.getRandomValues(b)
  b[6] = (b[6]! & 0x0f) | 0x40
  b[8] = (b[8]! & 0x3f) | 0x80
  const h = [...b].map((x) => x.toString(16).padStart(2, '0')).join('')
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`
}

/** ISO-8601 mit lokalem Offset (z. B. 2026-11-25T14:03:00+01:00). */
export function localIsoTs(d = new Date()): string {
  const off = -d.getTimezoneOffset()
  const sign = off >= 0 ? '+' : '-'
  const abs = Math.abs(off)
  const p = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}${sign}${p(Math.floor(abs / 60))}:${p(abs % 60)}`
}

export function upsertOp<E extends EntityName>(
  entity: E,
  id: string | null,
  data: Record<string, unknown>,
  baseVersion: number | null,
  reason?: string,
  /** feste op_id (Wiederholung desselben Speicherns nach verlorener Antwort → Server dedupliziert) */
  opId?: string,
): SyncOp {
  const op: SyncOp = {
    op_id: opId ?? uuid(),
    entity,
    id: id ?? uuid(),
    action: 'upsert',
    base_version: baseVersion,
    data: toData(entity, data),
    client_ts: localIsoTs(),
  }
  if (reason?.trim()) op.reason = reason.trim()
  return op
}

export function deleteOp(entity: EntityName, id: string, baseVersion: number | null, reason?: string): SyncOp {
  const op: SyncOp = { op_id: uuid(), entity, id, action: 'delete', base_version: baseVersion, data: {}, client_ts: localIsoTs() }
  if (reason?.trim()) op.reason = reason.trim()
  return op
}
