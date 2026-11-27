// Realistische Demo-Daten für den Mock-Server (deterministisch, relativ zum heutigen Datum).
import { createHash, randomUUID } from 'node:crypto'

// ---------- Hilfen ----------
function rng(seed) {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

let idCounter = 0
/** Deterministische UUID (v4-Format) aus Zähler – stabile IDs für Tests. */
export function did(prefix = 0) {
  idCounter++
  const h = createHash('sha256').update(`fzb-demo-${prefix}-${idCounter}`).digest('hex')
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`
}

const pad = (n) => String(n).padStart(2, '0')
export const isoDate = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
export function isoTs(d) {
  const off = -d.getTimezoneOffset()
  const sign = off >= 0 ? '+' : '-'
  const a = Math.abs(off)
  return `${isoDate(d)}T${pad(d.getHours())}:${pad(d.getMinutes())}:00${sign}${pad(Math.floor(a / 60))}:${pad(a % 60)}`
}
export const monthOf = (s) => {
  const d = new Date(s)
  return Number.isNaN(d.getTime()) ? s.slice(0, 7) : `${d.getFullYear()}-${pad(d.getMonth() + 1)}`
}
const addDays = (d, n) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n)
const at = (d, h, m) => new Date(d.getFullYear(), d.getMonth(), d.getDate(), h, m)

// ---------- Benutzer ----------
export const USERS = {
  jakob: { sub: 'u-jakob', username: 'jakob', name: 'Jakob Muster', email: 'jakob@example.ch', tenants: { privat: 'admin', 'muster-ag': 'admin' } },
  anna: { sub: 'u-anna', username: 'anna', name: 'Anna Beispiel', email: 'anna@example.ch', tenants: { privat: 'write' } },
  treuhand: { sub: 'u-treuhand', username: 'treuhand', name: 'Treuhand Keller', email: 'keller@treuhand.example', tenants: { privat: 'read', 'muster-ag': 'read' } },
  lea: { sub: 'u-lea', username: 'lea', name: 'Lea Fischer', email: 'lea@muster-ag.example', tenants: { 'muster-ag': 'write' } },
  neu: { sub: 'u-neu', username: 'neu', name: 'Nora Neu', email: 'nora@example.ch', tenants: {} },
}

export const ENTITY_KEYS = {
  vehicle: 'vehicles', odometer: 'odometer', fuel: 'fuel', maintenance: 'maintenance', maintenance_item: 'maintenance_items',
  maintenance_material: 'maintenance_materials', material_article: 'material_articles', trip: 'trips', place: 'places',
  customer: 'customers', purpose_rule: 'purpose_rules', tax_param: 'tax_params', trip_period: 'trip_periods', attachment: 'attachments',
}

// ---------- Mandant mit Journal ----------
export class Tenant {
  constructor(slug) {
    this.slug = slug
    this.seq = 0
    this.head = '0'.repeat(64)
    this.rows = Object.fromEntries(Object.keys(ENTITY_KEYS).map((e) => [e, new Map()]))
    this.revisions = []
    this.anchors = []
    this.members = []
    this.blobs = new Map()
    /** Änderungsprotokoll [seq, entity, id] in Seq-Reihenfolge (für effizientes /changes bei grossen Daten) */
    this.log = []
  }

  /** Revision schreiben (Hash-Kette) und Objekt aktualisieren. */
  record(entity, obj, action, actor, when = new Date(), meta = {}) {
    const map = this.rows[entity]
    const prev = map.get(obj.id)
    const version = (prev?.version ?? 0) + 1
    const nowIso = when.toISOString()
    const row = {
      ...obj,
      version,
      deleted: action === 'delete' ? true : (obj.deleted ?? false),
      created_by: prev?.created_by ?? actor,
      updated_by: actor,
      created_at: prev?.created_at ?? nowIso,
      updated_at: nowIso,
    }
    this.seq++
    row.last_seq = this.seq
    map.set(obj.id, row)
    this.log.push([this.seq, entity, obj.id])
    const data = { ...strip(row), ...meta }
    const body = JSON.stringify({ seq: this.seq, entity, id: obj.id, version, action, data })
    this.head = createHash('sha256').update(this.head + body).digest('hex')
    this.revisions.push({
      seq: this.seq, entity, entity_id: obj.id, version, action, data, actor_name: actor,
      recorded_at: nowIso, client_ts: isoTs(when), conflict: false, hash: this.head,
    })
    if (this.seq % 25 === 0) this.anchor(when)
    return row
  }

  anchor(when = new Date()) {
    const sig = createHash('sha512').update(`anchor|${this.slug}|${this.seq}|${this.head}`).digest('hex')
    this.anchors.push({ seq: this.seq, head_hash: this.head, created_at: when.toISOString(), key_id: 'demo-ed25519-01', signature: sig.slice(0, 128) })
  }

  /** Journal chronologisch nach Zeitpunkt ordnen (Aufbau erfolgt nicht in Zeitfolge), Kette neu rechnen. */
  resequence() {
    const revs = [...this.revisions].sort((a, b) => a.recorded_at.localeCompare(b.recorded_at) || a.seq - b.seq)
    let head = '0'.repeat(64)
    const last = new Map()
    const anchorTimes = this.anchors.map((a) => a.created_at)
    this.anchors = []
    revs.forEach((r, i) => {
      r.seq = i + 1
      const body = JSON.stringify({ seq: r.seq, entity: r.entity, id: r.entity_id, version: r.version, action: r.action, data: r.data })
      head = createHash('sha256').update(head + body).digest('hex')
      r.hash = head
      last.set(`${r.entity}:${r.entity_id}`, r.seq)
    })
    this.revisions = revs
    this.seq = revs.length
    this.head = head
    for (const [entity, map] of Object.entries(this.rows)) for (const row of map.values()) row.last_seq = last.get(`${entity}:${row.id}`) ?? row.last_seq
    this.log = revs.map((r) => [r.seq, r.entity, r.entity_id])
    // Anker zu den ursprünglichen Zeitpunkten neu setzen
    for (const at of [...new Set(anchorTimes)].sort()) {
      const upTo = revs.filter((r) => r.recorded_at <= at).at(-1)
      if (!upTo) continue
      const sig = createHash('sha512').update(`anchor|${this.slug}|${upTo.seq}|${upTo.hash}`).digest('hex')
      this.anchors.push({ seq: upTo.seq, head_hash: upTo.hash, created_at: at, key_id: 'demo-ed25519-01', signature: sig.slice(0, 128) })
    }
  }

  get(entity, id) {
    return this.rows[entity].get(id)
  }

  /** Aktuelle Datensätze mit last_seq > since in Seq-Reihenfolge, höchstens `limit` (Binärsuche im Protokoll). */
  changesSince(since, limit) {
    let lo = 0
    let hi = this.log.length
    while (lo < hi) {
      const mid = (lo + hi) >> 1
      if (this.log[mid][0] <= since) lo = mid + 1
      else hi = mid
    }
    const out = []
    for (let i = lo; i < this.log.length && out.length <= limit; i++) {
      const [seq, entity, id] = this.log[i]
      const row = this.rows[entity].get(id)
      if (row && row.last_seq === seq) out.push([seq, entity, row])
    }
    return out
  }

  /** Revisionen mit seq < before (neueste zuerst), höchstens `limit`. Revisionen liegen nach Seq sortiert vor. */
  revisionsBefore(before, limit) {
    let lo = 0
    let hi = this.revisions.length
    while (lo < hi) {
      const mid = (lo + hi) >> 1
      if (this.revisions[mid].seq < before) lo = mid + 1
      else hi = mid
    }
    return this.revisions.slice(Math.max(0, lo - limit), lo).reverse()
  }

  list(entity) {
    return [...this.rows[entity].values()]
  }
}

function strip(row) {
  const { version: _v, deleted: _d, last_seq: _l, created_by: _c, updated_by: _u, created_at: _ca, updated_at: _ua, id: _i, ...rest } = row
  return rest
}

// ---------- Aufbau ----------
const PLACE_NAMES = {}

function place(t, actor, when, p) {
  const row = t.record('place', { id: did(1), lat: null, lon: null, radius_m: 150, customer_id: null, default_category: null, private: false, ...p }, 'create', actor, when)
  PLACE_NAMES[row.id] = row.name
  return row
}

function vehicleBase(v) {
  return { make: null, model: null, plate: null, fuel_type: 'benzin', initial_km: 0, purchase_price: null, ownership: null, private_use_method: null, annual_fixed_costs: null, vin: null, ...v }
}

function tripRow(vehicleId, driver, start, end, kmStart, kmEnd, extra = {}) {
  return {
    id: did(2), vehicle_id: vehicleId, driver_sub: driver.sub, driver_name: driver.name,
    start_at: isoTs(start), end_at: end ? isoTs(end) : null, km_start: kmStart, km_end: kmEnd,
    distance_gps: kmStart !== null && kmEnd !== null ? Math.round((kmEnd - kmStart) * 10.2) / 10 : null, distance_route: null,
    start_place_id: null, end_place_id: null, start_label: null, end_label: null, category: 'unknown', purpose: null,
    customer_id: null, customer_name: null, status: 'confirmed', source: 'auto', suggestion_category: null, suggestion_purpose: null,
    suggestion_customer_id: null, suggestion_confidence: null, suggestion_reason: null, suggestion_source: null, track_hash: null,
    split_of: null, private_mode: false, note: null, km_estimated: false, ...extra,
  }
}

/**
 * Simuliert die Nutzung eines Fahrzeugs Tag für Tag: Fahrten (ab `tripsFrom`), Tankvorgänge, km-Stände.
 * Liefert Einträge in chronologischer Reihenfolge, damit das Journal plausibel ist.
 */
function simulate({ vehicle, driver, from, today, tripsFrom, rand, places, customers, targetKm, consumption, business }) {
  const events = []
  let kmNow = 0
  let tankUsed = 0
  const cur = monthOf(isoTs(today))
  const prevMonth = (() => {
    const d = new Date(today.getFullYear(), today.getMonth() - 1, 1)
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}`
  })()
  let gapDone = false
  let estimatedLeft = 2
  const recent = []

  for (let d = new Date(from); d <= today; d = addDays(d, 1)) {
    const dow = d.getDay() // 0 = So
    const work = dow >= 1 && dow <= 5
    const day = []
    if (work && rand() > 0.12) {
      const commute = business ? 0 : 12
      if (business) {
        const c = customers[Math.floor(rand() * customers.length)]
        const dist = 14 + Math.round(rand() * 30)
        day.push({ h: 8, m: 5, km: dist, from: places.work, to: c.place, cat: 'business', purpose: rand() > 0.5 ? 'Montage vor Ort' : 'Service-Einsatz', customer: c })
        day.push({ h: 15, m: 40, km: dist + Math.round(rand() * 3), from: c.place, to: places.work, cat: 'business', purpose: 'Rückfahrt Werkstatt', customer: c })
      } else {
        day.push({ h: 7, m: 40, km: commute, from: places.home, to: places.work, cat: 'commute', purpose: null })
        if (rand() > 0.72) {
          const c = customers[Math.floor(rand() * customers.length)]
          day.push({ h: 12, m: 10, km: 18, from: places.work, to: c.place, cat: 'business', purpose: 'Kundentermin', customer: c })
          day.push({ h: 15, m: 20, km: 18, from: c.place, to: places.work, cat: 'business', purpose: 'Rückfahrt', customer: c })
        }
        day.push({ h: 17, m: 25, km: commute, from: places.work, to: places.home, cat: 'commute', purpose: null })
      }
    } else if (!business && !work && rand() > 0.45) {
      const long = rand() > 0.8
      day.push({ h: 10, m: 15, km: long ? 85 : 7, from: places.home, to: null, toLabel: long ? 'Luzern' : 'Einkaufszentrum', cat: 'private', purpose: null })
      day.push({ h: 16, m: 30, km: long ? 85 : 7, from: null, fromLabel: long ? 'Luzern' : 'Einkaufszentrum', to: places.home, cat: 'private', purpose: null })
    }

    for (const tr of day) {
      const start = at(d, tr.h, tr.m)
      const end = new Date(start.getTime() + (tr.km * 1.4 + 6) * 60_000)
      let kmStart = kmNow
      const isCurMonth = monthOf(isoTs(start)) === cur
      // Lücke von 12 km im laufenden Monat (Fahrt nicht erfasst)
      if (isCurMonth && !business && !gapDone && d.getDate() >= 12 && tr.cat === 'commute' && tr.h < 12) {
        kmStart += 12
        gapDone = true
      }
      kmNow = kmStart + tr.km
      tankUsed += (tr.km * consumption * (0.92 + rand() * 0.16)) / 100
      if (start < tripsFrom) continue
      const row = tripRow(vehicle.id, driver, start, end, kmStart, kmNow, {
        category: tr.cat,
        purpose: tr.purpose,
        customer_id: tr.customer?.id ?? null,
        start_place_id: tr.from?.id ?? null,
        end_place_id: tr.to?.id ?? null,
        start_label: tr.from ? null : (tr.fromLabel ?? null),
        end_label: tr.to ? null : (tr.toLabel ?? null),
        status: monthOf(isoTs(start)) < prevMonth ? 'locked' : 'confirmed',
        suggestion_category: tr.cat,
        suggestion_source: tr.cat === 'commute' ? 'rule' : tr.cat === 'business' ? 'calendar' : 'pattern',
        suggestion_confidence: 0.9,
      })
      recent.push(row)
      events.push({ when: end, kind: 'trip', row })
    }
    // Tanken bei ~42 l Verbrauch
    if (tankUsed > 40 + rand() * 6) {
      const liters = Math.round(tankUsed * 100) / 100
      const price = Math.round(liters * (1.78 + rand() * 0.14) * 20) / 20
      const fuelRow = {
        id: did(3), vehicle_id: vehicle.id, date: isoDate(d), km: kmNow, liters, price_total: price, full_tank: rand() > 0.12,
        station: ['Migrol Zürich-West', 'Shell Altstetten', 'AVIA Schlieren', 'Coop Pronto Dietikon'][Math.floor(rand() * 4)], note: null,
      }
      events.push({ when: at(d, 18, 30), kind: 'fuel', row: fuelRow })
      tankUsed = fuelRow.full_tank ? 0 : tankUsed - liters
    }
    // km-Stand am Monatsende abgelesen
    if (addDays(d, 1).getDate() === 1) {
      events.push({ when: at(d, 20, 0), kind: 'odometer', row: { id: did(4), vehicle_id: vehicle.id, date: isoDate(d), km: kmNow, note: 'Monatsende abgelesen' } })
    }
  }

  // Auf Ziel-Kilometerstand verschieben (aktueller Stand = targetKm)
  const offset = targetKm - kmNow
  for (const e of events) {
    if (e.kind === 'trip') {
      e.row.km_start += offset
      e.row.km_end += offset
    } else e.row.km += offset
  }
  const initialKm = offset

  // Laufender Monat: die letzten 4 Fahrten unbestätigt, 2 davon mit geschätztem km-Stand
  const curTrips = events.filter((e) => e.kind === 'trip' && monthOf(e.row.start_at) === cur)
  const open = curTrips.slice(-4)
  for (const [i, e] of open.entries()) {
    e.row.status = e.row.category === 'commute' && i > 0 ? 'suggested' : 'draft'
    if (e.row.category === 'business') e.row.purpose = null
    if (estimatedLeft > 0 && !business) {
      e.row.km_estimated = true
      estimatedLeft--
    }
    if (e.row.status === 'draft') e.row.category = 'unknown'
  }
  return { events, initialKm }
}

export function buildDemo(now = new Date()) {
  idCounter = 0
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  const tenants = {}

  // ================= privat =================
  {
    const t = new Tenant('privat')
    tenants.privat = t
    const jakob = USERS.jakob
    const anna = USERS.anna
    const start = new Date(today.getFullYear() - 1, today.getMonth() - 1, 1)
    const actor = jakob.name

    const cust = [
      t.record('customer', { id: did(5), name: 'Meier AG', ref: 'K-1001', note: 'Hauptkunde Zürich' }, 'create', actor, start),
      t.record('customer', { id: did(5), name: 'Garage Muster AG', ref: 'K-1002', note: null }, 'create', actor, start),
      t.record('customer', { id: did(5), name: 'Huber Immobilien', ref: null, note: 'Verwaltung Liegenschaften' }, 'create', actor, start),
    ]
    const places = {
      home: place(t, actor, start, { name: 'Wohnort', kind: 'home', default_category: null }),
      work: place(t, actor, start, { name: 'Büro b-re.ch', kind: 'work', lat: 47.389, lon: 8.517, default_category: 'commute' }),
    }
    const custPlaces = [
      place(t, actor, start, { name: 'Meier AG', kind: 'customer', lat: 47.412, lon: 8.545, customer_id: cust[0].id, default_category: 'business' }),
      place(t, actor, start, { name: 'Garage Muster AG', kind: 'customer', lat: 47.367, lon: 8.432, customer_id: cust[1].id, default_category: 'business' }),
    ]
    place(t, actor, start, { name: 'Arztpraxis', kind: 'other', private: true })
    const customers = [
      { ...cust[0], place: custPlaces[0] },
      { ...cust[1], place: custPlaces[1] },
    ]

    t.record('purpose_rule', { id: did(6), priority: 10, from_place_id: places.home.id, to_place_id: places.work.id, weekdays: '1,2,3,4,5', time_from: '06:00', time_to: '10:00', vehicle_id: null, result_category: 'commute', result_purpose: null, result_customer_id: null, auto_confirm: true, origin: 'user', active: true }, 'create', actor, start)
    t.record('purpose_rule', { id: did(6), priority: 20, from_place_id: places.work.id, to_place_id: custPlaces[0].id, weekdays: '1,2,3,4,5', time_from: null, time_to: null, vehicle_id: null, result_category: 'business', result_purpose: 'Kundentermin', result_customer_id: cust[0].id, auto_confirm: false, origin: 'learned', active: true }, 'create', actor, start)
    t.record('purpose_rule', { id: did(6), priority: 90, from_place_id: null, to_place_id: places.home.id, weekdays: '6,7', time_from: null, time_to: null, vehicle_id: null, result_category: 'private', result_purpose: null, result_customer_id: null, auto_confirm: false, origin: 'user', active: false }, 'create', actor, start)

    t.record('tax_param', { id: did(7), year: today.getFullYear(), scope: 'tenant', key: 'km_rate', value: 0.7, source_url: 'https://www.estv.admin.ch/', note: 'Spesenreglement 2026 – mit Treuhand bestätigt?' }, 'create', actor, start)
    t.record('tax_param', { id: did(7), year: today.getFullYear(), scope: 'canton:ZH', key: 'cap_canton', value: 5000, source_url: null, note: 'Annahme Kanton Zürich' }, 'create', actor, start)

    const arts = [
      t.record('material_article', { id: did(8), name: 'Motoröl 5W-30', part_number: 'VW 504 00', unit: 'l', unit_price: 18, category: 'Öl', vehicle_id: null, note: null }, 'create', actor, start),
      t.record('material_article', { id: did(8), name: 'Ölfilter', part_number: '04E115561H', unit: 'Stk', unit_price: 18.5, category: 'Filter', vehicle_id: null, note: null }, 'create', actor, start),
      t.record('material_article', { id: did(8), name: 'Luftfilter', part_number: '5Q0129620D', unit: 'Stk', unit_price: 32, category: 'Filter', vehicle_id: null, note: null }, 'create', actor, start),
      t.record('material_article', { id: did(8), name: 'Scheibenwischer-Set', part_number: null, unit: 'Set', unit_price: 39.9, category: 'Verschleiss', vehicle_id: null, note: 'Bosch Aerotwin' }, 'create', actor, start),
    ]

    const skoda = t.record('vehicle', vehicleBase({ id: did(9), name: 'Skoda Octavia', make: 'Skoda', model: 'Octavia Combi', plate: 'ZH 123 456', vin: 'TMBJJ7NE5L0123456', fuel_type: 'benzin', initial_km: 0, purchase_price: 38900, ownership: 'private', annual_fixed_costs: 2350 }), 'create', actor, start)
    const corolla = t.record('vehicle', vehicleBase({ id: did(9), name: 'Toyota Corolla', make: 'Toyota', model: 'Corolla Hybrid', plate: 'ZH 987 654', fuel_type: 'hybrid', initial_km: 0, ownership: 'private', annual_fixed_costs: 1900 }), 'create', anna.name, start)

    const tripsFrom = new Date(today.getFullYear(), today.getMonth() - 5, 1)
    const sim = simulate({ t, vehicle: skoda, driver: jakob, actor, from: start, today, tripsFrom, rand: rng(42), places, customers, targetKm: 53410, consumption: 6.4, business: false })
    const sim2 = simulate({ t, vehicle: corolla, driver: anna, actor: anna.name, from: start, today, tripsFrom: addDays(today, 1), rand: rng(7), places, customers, targetKm: 28745, consumption: 4.6, business: false })
    skoda.initial_km = sim.initialKm
    corolla.initial_km = sim2.initialKm
    t.record('vehicle', skoda, 'update', actor, addDays(start, 1))
    t.record('vehicle', corolla, 'update', anna.name, addDays(start, 1))

    const all = [...sim.events.map((e) => ({ ...e, actor })), ...sim2.events.map((e) => ({ ...e, actor: anna.name }))].sort((a, b) => a.when - b.when)
    let n = 0
    const fuelRows = []
    for (const e of all) {
      const row = t.record(e.kind, e.row, 'create', e.actor, e.when)
      if (e.kind === 'fuel') fuelRows.push(row)
      // einige Fahrten nachträglich bestätigt (Verlauf)
      if (e.kind === 'trip' && row.category === 'business' && n++ % 3 === 0 && row.status !== 'draft') {
        t.record('trip', { ...row, purpose: row.purpose ?? 'Kundentermin' }, 'update', e.actor, new Date(e.when.getTime() + 3_600_000))
      }
    }
    // Belege zu den letzten Tankvorgängen
    for (const f of fuelRows.filter((f) => f.vehicle_id === skoda.id).slice(-6)) {
      const a = t.record('attachment', { id: did(10), fuel_id: f.id, maintenance_id: null, vehicle_id: f.vehicle_id, kind: 'receipt', sha256: 'a'.repeat(64), mime: 'image/jpeg', size: 15558, taken_at: null, note: null }, 'create', actor, new Date(f.date))
      t.blobs.set(a.id, 'receipt.jpg')
    }
    const lastFuel = fuelRows.filter((f) => f.vehicle_id === skoda.id).at(-1)
    if (lastFuel) {
      const a = t.record('attachment', { id: did(10), fuel_id: lastFuel.id, maintenance_id: null, vehicle_id: skoda.id, kind: 'pump', sha256: 'b'.repeat(64), mime: 'image/heic', size: 120000, taken_at: null, note: null }, 'create', actor, new Date(lastFuel.date))
      void a
    }
    // Ein stornierter Tankvorgang (doppelt erfasst)
    const dup = fuelRows.filter((f) => f.vehicle_id === skoda.id).at(-3)
    if (dup) {
      const copy = t.record('fuel', { ...dup, id: did(3), note: 'doppelt erfasst' }, 'create', anna.name, new Date(dup.date))
      t.record('fuel', copy, 'delete', anna.name, addDays(new Date(dup.date), 1), { storno_reason: 'Doppelt erfasst (Sync)' })
    }

    // Wartungen
    const svcDate = addDays(today, -150)
    const svc = t.record('maintenance', { id: did(11), vehicle_id: skoda.id, date: isoDate(svcDate), km: 53410 - 4200, title: 'Service 60’000 km', cost: 386.2, note: 'Garage Muster AG, Ölwechsel inkl. Filter', next_due_km: 53410 + 10800, next_due_date: isoDate(addDays(svcDate, 365)) }, 'create', actor, svcDate)
    for (const [i, l] of ['Motoröl gewechselt', 'Ölfilter ersetzt', 'Bremsen geprüft', 'Lichter geprüft', 'Reifendruck kontrolliert'].entries())
      t.record('maintenance_item', { id: did(12), maintenance_id: svc.id, label: l, done: i !== 3, position: i }, 'create', actor, svcDate)
    t.record('maintenance_material', { id: did(13), maintenance_id: svc.id, article_id: arts[0].id, name: arts[0].name, part_number: arts[0].part_number, quantity: 4.5, unit: 'l', unit_price: 18, position: 0 }, 'create', actor, svcDate)
    t.record('maintenance_material', { id: did(13), maintenance_id: svc.id, article_id: arts[1].id, name: arts[1].name, part_number: arts[1].part_number, quantity: 1, unit: 'Stk', unit_price: 18.5, position: 1 }, 'create', actor, svcDate)
    const inv = t.record('attachment', { id: did(10), fuel_id: null, maintenance_id: svc.id, vehicle_id: skoda.id, kind: 'receipt', sha256: 'c'.repeat(64), mime: 'application/pdf', size: 20211, taken_at: null, note: 'Rechnung' }, 'create', actor, svcDate)
    t.blobs.set(inv.id, 'invoice.pdf')
    const tyreDate = addDays(today, -40)
    t.record('maintenance', { id: did(11), vehicle_id: skoda.id, date: isoDate(tyreDate), km: null, title: 'Reifenwechsel Winter', cost: null, note: 'Selbst gewechselt', next_due_km: null, next_due_date: isoDate(addDays(tyreDate, 160)) }, 'create', actor, tyreDate)
    const mfkDate = addDays(today, -730)
    t.record('maintenance', { id: did(11), vehicle_id: skoda.id, date: isoDate(mfkDate), km: null, title: 'Motorfahrzeugkontrolle (MFK)', cost: 65, note: null, next_due_km: null, next_due_date: isoDate(addDays(today, -10)) }, 'create', actor, mfkDate)
    const wiper = t.record('maintenance', { id: did(11), vehicle_id: corolla.id, date: isoDate(addDays(today, -90)), km: 28745 - 1500, title: 'Scheibenwischer ersetzt', cost: null, note: null, next_due_km: null, next_due_date: null }, 'create', anna.name, addDays(today, -90))
    t.record('maintenance_material', { id: did(13), maintenance_id: wiper.id, article_id: arts[3].id, name: arts[3].name, part_number: null, quantity: 1, unit: 'Set', unit_price: 39.9, position: 0 }, 'create', anna.name, addDays(today, -90))
    t.record('maintenance', { id: did(11), vehicle_id: corolla.id, date: isoDate(addDays(today, -200)), km: 28745 - 4100, title: 'Service', cost: 295, note: null, next_due_km: 28745 + 300, next_due_date: null }, 'create', anna.name, addDays(today, -200))

    // Abgeschlossene Monate: alle vor dem Vormonat (ab Beginn der Fahrten)
    const closeUntil = new Date(today.getFullYear(), today.getMonth() - 1, 1)
    for (let m = new Date(tripsFrom); m < closeUntil; m = new Date(m.getFullYear(), m.getMonth() + 1, 1)) {
      const month = `${m.getFullYear()}-${pad(m.getMonth() + 1)}`
      const mt = t.list('trip').filter((x) => x.vehicle_id === skoda.id && monthOf(x.start_at) === month)
      const sum = (c) => mt.filter((x) => x.category === c).reduce((a, x) => a + (x.km_end - x.km_start), 0)
      const closedAt = new Date(m.getFullYear(), m.getMonth() + 1, 3, 9, 12)
      t.record('trip_period', {
        id: did(14), vehicle_id: skoda.id, month, status: 'closed', closed_by: actor, closed_at: closedAt.toISOString(), anchor_seq: t.seq,
        km_start: mt[0]?.km_start ?? null, km_end: mt.at(-1)?.km_end ?? null, trips_count: mt.length,
        business_km: sum('business'), private_km: sum('private'), commute_km: sum('commute'), field_km: sum('field'), note: null, corrections: 0,
      }, 'create', actor, closedAt)
      t.anchor(closedAt)
    }

    t.members = [
      { id: 'm-jakob', username: 'jakob', name: jakob.name, email: jakob.email, role: 'admin', source: 'keycloak', last_activity_at: new Date(now.getTime() - 3_600_000).toISOString() },
      { id: 'm-anna', username: 'anna', name: anna.name, email: anna.email, role: 'write', source: 'keycloak', last_activity_at: addDays(today, -2).toISOString() },
      { id: 'm-treuhand', username: 'treuhand', name: USERS.treuhand.name, email: USERS.treuhand.email, role: 'read', source: 'keycloak', last_activity_at: addDays(today, -21).toISOString() },
    ]
  }

  // ================= muster-ag =================
  {
    const t = new Tenant('muster-ag')
    tenants['muster-ag'] = t
    const jakob = USERS.jakob
    const lea = USERS.lea
    const start = new Date(today.getFullYear(), today.getMonth() - 8, 1)
    const actor = jakob.name
    const work = place(t, actor, start, { name: 'Werkstatt Muster AG', kind: 'work', lat: 47.5, lon: 8.72, default_category: 'business' })
    const custRows = [
      t.record('customer', { id: did(5), name: 'Bäckerei Frei', ref: 'B-77', note: null }, 'create', actor, start),
      t.record('customer', { id: did(5), name: 'Schulhaus Talwies', ref: 'S-12', note: 'Hauswart Hr. Graf' }, 'create', actor, start),
    ]
    const customers = custRows.map((c, i) => ({ ...c, place: place(t, actor, start, { name: c.name, kind: 'customer', lat: 47.49 + i * 0.01, lon: 8.7, customer_id: c.id, default_category: 'business' }) }))
    const caddy = t.record('vehicle', vehicleBase({ id: did(9), name: 'VW Caddy', make: 'VW', model: 'Caddy Cargo', plate: 'ZH 55 101', fuel_type: 'diesel', purchase_price: 41500, ownership: 'business', private_use_method: 'flat', annual_fixed_costs: 3100 }), 'create', actor, start)
    const sim = simulate({ t, vehicle: caddy, driver: lea, actor: lea.name, from: start, today, tripsFrom: new Date(today.getFullYear(), today.getMonth() - 2, 1), rand: rng(99), places: { work, home: work }, customers, targetKm: 18230, consumption: 6.9, business: true })
    caddy.initial_km = sim.initialKm
    t.record('vehicle', caddy, 'update', actor, addDays(start, 1))
    for (const e of sim.events.sort((a, b) => a.when - b.when)) t.record(e.kind, e.row, 'create', lea.name, e.when)
    t.record('maintenance', { id: did(11), vehicle_id: caddy.id, date: isoDate(addDays(today, -60)), km: 18230 - 2300, title: 'Service', cost: 512.4, note: null, next_due_km: 18230 + 12000, next_due_date: null }, 'create', actor, addDays(today, -60))
    t.members = [
      { id: 'm-jakob', username: 'jakob', name: jakob.name, email: jakob.email, role: 'admin', source: 'keycloak', last_activity_at: new Date(now.getTime() - 7_200_000).toISOString() },
      { id: 'm-lea', username: 'lea', name: lea.name, email: lea.email, role: 'write', source: 'keycloak', last_activity_at: addDays(today, -1).toISOString() },
      { id: 'm-treuhand', username: 'treuhand', name: USERS.treuhand.name, email: USERS.treuhand.email, role: 'read', source: 'keycloak', last_activity_at: null },
    ]
  }

  for (const t of Object.values(tenants)) t.resequence()
  return tenants
}

// ================= Lasttest: --seed large =================
/**
 * Grosser Datenbestand für Performance-Tests: Mandant «privat» mit 3 Fahrzeugen × `tripsPerVehicle` Fahrten über
 * viele Jahre, `fuelTotal` Tankvorgänge, monatliche km-Stände, Wartungen, 200 Kunden, abgeschlossene Monate.
 * Das Journal (Aktivität) enthält jede Erfassung (> 100k Einträge). Chronologisch erzeugt (kein Umsortieren nötig).
 * Der Mandant «muster-ag» bleibt der kleine Demo-Bestand.
 */
export function buildLarge(now = new Date(), { tripsPerVehicle = 30_000, fuelTotal = 5_000 } = {}) {
  const tenants = buildDemo(now)
  idCounter = 1_000_000
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  const t = new Tenant('privat')
  const jakob = USERS.jakob
  const anna = USERS.anna
  const actor = jakob.name
  const perDay = 6
  const days = Math.ceil(tripsPerVehicle / perDay)
  const start = addDays(today, -days - 2)
  const rand = rng(2026)
  const events = []
  const ev = (when, entity, row, who = actor) => events.push({ when, entity, row, who })

  const customers = []
  for (let i = 0; i < 200; i++) customers.push({ id: did(5), name: `Kunde ${String(i + 1).padStart(3, '0')} AG`, ref: `K-${3000 + i}`, note: i % 7 === 0 ? 'Rahmenvertrag' : null })
  for (const c of customers) ev(start, 'customer', c)
  const placeRow = (p) => ({ id: did(1), lat: null, lon: null, radius_m: 150, customer_id: null, default_category: null, private: false, ...p })
  const home = placeRow({ name: 'Wohnort', kind: 'home' })
  const work = placeRow({ name: 'Büro b-re.ch', kind: 'work', lat: 47.389, lon: 8.517, default_category: 'commute' })
  const custPlaces = customers.slice(0, 40).map((c, i) => placeRow({ name: c.name, kind: 'customer', lat: 47.3 + i * 0.004, lon: 8.4 + i * 0.003, customer_id: c.id, default_category: 'business' }))
  const others = ['Einkaufszentrum', 'Luzern', 'Bern', 'Basel', 'Winterthur'].map((name) => placeRow({ name, kind: 'other' }))
  for (const p of [home, work, ...custPlaces, ...others]) ev(start, 'place', p)
  ev(start, 'material_article', { id: did(8), name: 'Motoröl 5W-30', part_number: 'VW 504 00', unit: 'l', unit_price: 18, category: 'Öl', vehicle_id: null, note: null })

  const specs = [
    { name: 'Skoda Octavia', make: 'Skoda', model: 'Octavia Combi', plate: 'ZH 123 456', fuel_type: 'benzin', cons: 6.4, driver: jakob },
    { name: 'Toyota Corolla', make: 'Toyota', model: 'Corolla Hybrid', plate: 'ZH 987 654', fuel_type: 'hybrid', cons: 4.6, driver: anna },
    { name: 'VW Touran', make: 'VW', model: 'Touran', plate: 'ZH 555 777', fuel_type: 'diesel', cons: 5.8, driver: jakob },
  ]
  const cur = monthOf(isoTs(today))
  const prevMonth = (() => {
    const d = new Date(today.getFullYear(), today.getMonth() - 1, 1)
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}`
  })()
  const fuelEvery = Math.max(1, Math.floor((days * specs.length) / fuelTotal))
  const SLOTS = [[7, 30], [9, 10], [11, 45], [14, 5], [16, 40], [18, 50]]
  const closedMonths = new Map()

  specs.forEach((spec, vi) => {
    const vehicle = vehicleBase({ id: did(9), name: spec.name, make: spec.make, model: spec.model, plate: spec.plate, fuel_type: spec.fuel_type, initial_km: 1000 * (vi + 1), purchase_price: 30000 + vi * 5000, ownership: 'private', annual_fixed_costs: 2000 })
    ev(start, 'vehicle', vehicle, spec.driver.name)
    let km = vehicle.initial_km
    let tank = 0
    let made = 0
    let fuelCount = 0
    const monthTrips = new Map()
    for (let d = 0; d <= days && made < tripsPerVehicle; d++) {
      const day = addDays(start, d + 1)
      for (const [h, m] of SLOTS) {
        if (made >= tripsPerVehicle) break
        const begin = at(day, h, m)
        const dist = 3 + Math.floor(rand() * 40)
        const end = new Date(begin.getTime() + (dist * 1.3 + 5) * 60_000)
        const r = rand()
        const cat = r < 0.45 ? 'business' : r < 0.7 ? 'commute' : r < 0.95 ? 'private' : 'field'
        const c = customers[Math.floor(rand() * customers.length)]
        const mo = monthOf(isoTs(begin))
        const row = tripRow(vehicle.id, spec.driver, begin, end, km, km + dist, {
          category: cat,
          purpose: cat === 'business' ? `Kundentermin ${c.name}` : cat === 'field' ? 'Service-Einsatz' : null,
          customer_id: cat === 'business' ? c.id : null,
          start_place_id: cat === 'commute' ? home.id : work.id,
          end_place_id: cat === 'commute' ? work.id : cat === 'business' && custPlaces.length ? custPlaces[Math.floor(rand() * custPlaces.length)].id : null,
          end_label: cat === 'private' || cat === 'field' ? others[Math.floor(rand() * others.length)].name : null,
          status: mo < prevMonth ? 'locked' : 'confirmed',
          source: rand() > 0.1 ? 'auto' : 'manual',
        })
        km += dist
        tank += (dist * spec.cons) / 100
        made++
        ev(end, 'trip', row, spec.driver.name)
        if (!monthTrips.has(mo)) monthTrips.set(mo, [])
        monthTrips.get(mo).push(row)
      }
      if (d % fuelEvery === 0 && fuelCount * specs.length < fuelTotal) {
        const liters = Math.round(Math.max(tank, 20) * 100) / 100
        ev(at(day, 19, 30), 'fuel', { id: did(3), vehicle_id: vehicle.id, date: isoDate(day), km, liters, price_total: Math.round(liters * (1.7 + rand() * 0.2) * 20) / 20, full_tank: rand() > 0.1, station: ['Migrol', 'Shell', 'AVIA', 'Coop Pronto'][Math.floor(rand() * 4)], note: null }, spec.driver.name)
        tank = 0
        fuelCount++
      }
      if (addDays(day, 1).getDate() === 1) ev(at(day, 21, 0), 'odometer', { id: did(4), vehicle_id: vehicle.id, date: isoDate(day), km, note: 'Monatsende abgelesen' }, spec.driver.name)
      if (d % 365 === 180) {
        const mid = did(11)
        ev(at(day, 12, 0), 'maintenance', { id: mid, vehicle_id: vehicle.id, date: isoDate(day), km, title: 'Jahresservice', cost: 300 + Math.round(rand() * 200), note: null, next_due_km: km + 15000, next_due_date: isoDate(addDays(day, 365)) })
        ev(at(day, 12, 0), 'maintenance_item', { id: did(12), maintenance_id: mid, label: 'Motoröl gewechselt', done: true, position: 0 })
      }
    }
    // laufender Monat: die letzten 4 Fahrten offen
    const open = monthTrips.get(cur) ?? []
    for (const row of open.slice(-4)) {
      row.status = 'suggested'
    }
    // abgeschlossene Monate: alle vor dem Vormonat
    for (const [mo, trips] of monthTrips) {
      if (mo >= prevMonth) continue
      const [y, mm] = mo.split('-').map(Number)
      const closedAt = new Date(y, mm, 3, 9, 12)
      const sum = (cat) => trips.filter((x) => x.category === cat).reduce((a, x) => a + (x.km_end - x.km_start), 0)
      ev(closedAt, 'trip_period', { id: did(14), vehicle_id: vehicle.id, month: mo, status: 'closed', closed_by: actor, closed_at: closedAt.toISOString(), anchor_seq: null, km_start: trips[0].km_start, km_end: trips.at(-1).km_end, trips_count: trips.length, business_km: sum('business'), private_km: sum('private'), commute_km: sum('commute'), field_km: sum('field'), note: null, corrections: 0 })
      closedMonths.set(`${vehicle.id}:${mo}`, true)
    }
  })
  events.sort((a, b) => a.when - b.when)
  for (const e of events) t.record(e.entity, e.row, 'create', e.who, e.when)
  t.members = tenants.privat.members
  tenants.privat = t
  return tenants
}

export { randomUUID }
