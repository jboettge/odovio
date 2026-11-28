// Datenbestand des gewählten Fahrzeugbuchs: vollständig über /changes geladen (Seiten mit has_more), danach
// inkrementell ab Cursor (Voll-Sync ist serverseitig rate-limitiert). Nach Schreibaktionen (Sync) neu laden.
//
// Skalierung (100k+ Fahrten je Mandant):
// - Normalisiert: je Objekttyp eine Map id → Datensatz. Der ganze Bestand ist markRaw und liegt ausserhalb
//   reaktiver Objekte (Vue macht 100k Datensätze nicht tief reaktiv; Ansichten halten Datensätze in shallowRef).
// - Indizes je Fahrzeug, je Fahrzeug+Monat (Fahrten; beim ersten Zugriff je Fahrzeug aufgebaut) und je
//   Elternobjekt (Wartungsposten, Belege), einmalig aufgebaut und bei Deltas nur für die geänderten Datensätze
//   nachgeführt – statt wiederholter Array-Filter.
// - Reaktivität grob je Objekttyp über Zähler (`ticks`): Ansichten rechnen nur neu, wenn sich ihr Typ ändert;
//   abgeleitete Listen werden je Zählerstand zwischengespeichert.
// - Laden abbrechbar (AbortController) bei Mandantenwechsel/Abmeldung; nur im Speicher (keine Persistenz).
import { markRaw, reactive } from 'vue'
import { endpoints, CHANGES_PAGE } from '../api/endpoints'
import { isAbort } from '../api/client'
import { userMessage } from '../lib/security'
import { monthOf, byText, byCode } from '../lib/format'
import { analytics, existingAnalytics } from '../lib/analyticsClient'
import { slimCustomer, slimPeriod, slimPlace, slimTrip, type Delta } from '../lib/slim'
import { CHANGE_KEYS, type Changes, type EntityMap, type EntityName, type Stats, type SyncOp, type OpResult, type Trip } from '../api/types'

const ENTITIES = Object.keys(CHANGE_KEYS) as EntityName[]

/** Objekttypen mit `vehicle_id`, die je Fahrzeug indiziert werden. */
const VEHICLE_INDEXED = ['trip', 'fuel', 'odometer', 'maintenance', 'trip_period', 'attachment'] as const
type VehicleEntity = (typeof VEHICLE_INDEXED)[number]
/** Elternbeziehungen: Objekttyp → Feld mit der Eltern-ID. */
const PARENT_FIELDS = {
  maintenance_item: ['maintenance_id'],
  maintenance_material: ['maintenance_id'],
  attachment: ['fuel_id', 'maintenance_id'],
} as const
type ParentEntity = keyof typeof PARENT_FIELDS

type Table<E extends EntityName> = Map<string, EntityMap[E]>
type Bucket<T> = Map<string, Map<string, T>>

export interface Store {
  tables: { [E in EntityName]: Table<E> }
  byVehicle: { [E in VehicleEntity]: Bucket<EntityMap[E]> }
  tripsByMonth: Map<string, Bucket<Trip>>
  byParent: Map<string, Bucket<unknown>>
}

function emptyStore(): Store {
  const tables = {} as Record<EntityName, Map<string, unknown>>
  for (const e of ENTITIES) tables[e] = new Map()
  const byVehicle = {} as Record<VehicleEntity, Bucket<unknown>>
  for (const e of VEHICLE_INDEXED) byVehicle[e] = new Map()
  return markRaw({ tables, byVehicle, tripsByMonth: new Map(), byParent: new Map() } as unknown as Store)
}

export const dataState = reactive({
  tenant: null as string | null,
  cursor: 0,
  loaded: false,
  loading: false,
  error: null as string | null,
  loadedAt: null as Date | null,
  /** geladene Datensätze im laufenden Ladevorgang (Fortschritt) */
  received: 0,
})

/** Änderungszähler je Objekttyp (fein genug für Ansichten, grob genug für wenig Overhead). */
const ticks = reactive(Object.fromEntries(ENTITIES.map((e) => [e, 0]))) as Record<EntityName, number>
let store = emptyStore()
const memo = new Map<string, { tick: string; value: unknown }>()

/** Abhängigkeit vom Objekttyp registrieren (für computed/watch) und aktuellen Zählerstand liefern. */
export function tick(...entities: EntityName[]): string {
  return entities.map((e) => ticks[e]).join(':')
}

/** Abgeleitete Liste je Zählerstand zwischenspeichern; eingefroren, damit niemand sie in place sortiert. */
function cached<T>(key: string, entities: EntityName[], fn: () => T): T {
  const t = tick(...entities)
  const hit = memo.get(key)
  if (hit && hit.tick === t) return hit.value as T
  const value = fn()
  if (Array.isArray(value)) Object.freeze(value)
  memo.set(key, { tick: t, value })
  return value
}

function put<T>(bucket: Bucket<T>, key: string, id: string, row: T): void {
  let m = bucket.get(key)
  if (!m) bucket.set(key, (m = new Map()))
  m.set(id, row)
}
function drop<T>(bucket: Bucket<T>, key: string, id: string): void {
  const m = bucket.get(key)
  if (!m) return
  m.delete(id)
  if (!m.size) bucket.delete(key)
}

function unindex(s: Store, entity: EntityName, row: Record<string, unknown>): void {
  const id = row.id as string
  if ((VEHICLE_INDEXED as readonly string[]).includes(entity) && row.vehicle_id) {
    drop(s.byVehicle[entity as VehicleEntity] as Bucket<unknown>, row.vehicle_id as string, id)
  }
  if (entity === 'trip') {
    // Monatsindex nur nachführen, wenn er für dieses Fahrzeug schon aufgebaut wurde
    const byMonth = s.tripsByMonth.get(row.vehicle_id as string)
    if (byMonth) drop(byMonth, monthOf(row.start_at as string), id)
  }
  for (const f of PARENT_FIELDS[entity as ParentEntity] ?? []) {
    if (row[f]) drop(parentBucket(s, entity, f), row[f] as string, id)
  }
}

function index(s: Store, entity: EntityName, row: Record<string, unknown>): void {
  const id = row.id as string
  if ((VEHICLE_INDEXED as readonly string[]).includes(entity) && row.vehicle_id) {
    put(s.byVehicle[entity as VehicleEntity] as Bucket<unknown>, row.vehicle_id as string, id, row)
  }
  if (entity === 'trip') {
    const byMonth = s.tripsByMonth.get(row.vehicle_id as string)
    if (byMonth) put(byMonth, monthOf(row.start_at as string), id, row as unknown as Trip)
  }
  for (const f of PARENT_FIELDS[entity as ParentEntity] ?? []) {
    if (row[f]) put(parentBucket(s, entity, f), row[f] as string, id, row)
  }
}

function parentBucket(s: Store, entity: EntityName, field: string): Bucket<unknown> {
  const key = `${entity}.${field}`
  let b = s.byParent.get(key)
  if (!b) s.byParent.set(key, (b = new Map()))
  return b
}

/** Seite aus /changes übernehmen; liefert die geänderten Objekttypen und das Delta für die Auswertungen. */
export function applyChanges(ch: Partial<Changes>, s: Store = store): { changed: Set<EntityName>; delta: Delta; count: number } {
  const changed = new Set<EntityName>()
  const delta: Delta = {}
  let count = 0
  for (const entity of ENTITIES) {
    const list = ch[CHANGE_KEYS[entity]] as unknown as Record<string, unknown>[] | undefined
    if (!list?.length) continue
    changed.add(entity)
    const table = s.tables[entity] as Map<string, unknown>
    for (const rec of list) {
      const prev = table.get(rec.id as string) as Record<string, unknown> | undefined
      if (prev) unindex(s, entity, prev)
      table.set(rec.id as string, rec)
      index(s, entity, rec)
      count++
    }
    if (entity === 'trip') delta.trips = (list as unknown as Trip[]).map(slimTrip)
    if (entity === 'trip_period') delta.periods = (list as unknown as EntityMap['trip_period'][]).map(slimPeriod)
    if (entity === 'place') delta.places = (list as unknown as EntityMap['place'][]).map(slimPlace)
    if (entity === 'customer') delta.customers = (list as unknown as EntityMap['customer'][]).map(slimCustomer)
  }
  return { changed, delta, count }
}

function bump(entities: Iterable<EntityName>): void {
  for (const e of entities) ticks[e]++
}

/** Vollständiger Stand für die Auswertungen (Neustart im Hauptthread nach Worker-Fehler). */
function fullDelta(s: Store = store): Delta {
  return {
    trips: [...s.tables.trip.values()].map(slimTrip),
    periods: [...s.tables.trip_period.values()].map(slimPeriod),
    places: [...s.tables.place.values()].map(slimPlace),
    customers: [...s.tables.customer.values()].map(slimCustomer),
  }
}

// ---------- Lesen ----------
export function all<E extends EntityName>(entity: E): EntityMap[E][] {
  return cached(`all:${entity}`, [entity], () => [...store.tables[entity].values()])
}

export function active<E extends EntityName>(entity: E): EntityMap[E][] {
  return cached(`active:${entity}`, [entity], () => all(entity).filter((r) => !r.deleted))
}

export function byId<E extends EntityName>(entity: E, id: string | null | undefined): EntityMap[E] | undefined {
  void ticks[entity]
  return id ? store.tables[entity].get(id) : undefined
}

/** Aktive Fahrzeuge nach Name (Navigation, Übersicht). */
export function vehiclesByName(): EntityMap['vehicle'][] {
  return cached('vehicles:byName', ['vehicle'], () => [...active('vehicle')].sort((a, b) => byText(a.name, b.name) || byCode(a.id, b.id)))
}

/** Datensätze eines Fahrzeugs (inkl. stornierte), aus dem Index. */
export function ofVehicle<E extends VehicleEntity>(entity: E, vid: string): EntityMap[E][] {
  return cached(`veh:${entity}:${vid}`, [entity], () => [...((store.byVehicle[entity] as Bucket<EntityMap[E]>).get(vid)?.values() ?? [])])
}

/** Fahrten eines Fahrzeugs in einem Monat (YYYY-MM, lokale Zeit; inkl. stornierte). */
export function tripsInMonth(vid: string, month: string): Trip[] {
  return cached(`tm:${vid}:${month}`, ['trip'], () => [...(monthIndex(vid).get(month)?.values() ?? [])])
}

function monthIndex(vid: string): Bucket<Trip> {
  let byMonth = store.tripsByMonth.get(vid)
  if (!byMonth) {
    byMonth = new Map()
    for (const t of store.byVehicle.trip.get(vid)?.values() ?? []) put(byMonth, monthOf(t.start_at), t.id, t)
    store.tripsByMonth.set(vid, byMonth)
  }
  return byMonth
}

/** Kinder eines Elternobjekts, z. B. Checkliste/Material einer Wartung, Belege eines Tankvorgangs. */
export function childrenOf<E extends ParentEntity>(entity: E, field: (typeof PARENT_FIELDS)[E][number], parentId: string): EntityMap[E][] {
  void ticks[entity]
  return [...((store.byParent.get(`${entity}.${field}`) as Bucket<EntityMap[E]> | undefined)?.get(parentId)?.values() ?? [])]
}

/** Anzahl aktiver Datensätze je Wert eines Feldes (z. B. Fahrten je Kunde). */
export function countBy<E extends EntityName>(entity: E, field: keyof EntityMap[E] & string): Record<string, number> {
  return cached(`count:${entity}:${field}`, [entity], () => {
    const by: Record<string, number> = {}
    for (const r of store.tables[entity].values()) {
      const k = (r as unknown as Record<string, unknown>)[field]
      if (!r.deleted && typeof k === 'string' && k) by[k] = (by[k] ?? 0) + 1
    }
    return by
  })
}

// ---------- Laden ----------
let ctrl: AbortController | null = null
/** Lebensdauer des gewählten Fahrzeugbuchs: bricht mandantenbezogene Anfragen (Kennzahlen) beim Wechsel ab. */
let tenantCtrl = new AbortController()
let inflight: Promise<void> | null = null
let again = false

const resetHooks: (() => void)[] = []
/** Rückruf beim Leeren des Datenbestands (Mandantenwechsel, Abmelden), z. B. für Beleg-Cache. */
export function onDataReset(fn: () => void): void {
  resetHooks.push(fn)
}

export function reset(tenant: string | null): void {
  ctrl?.abort()
  ctrl = null
  tenantCtrl.abort()
  tenantCtrl = new AbortController()
  inflight = null
  again = false
  dataState.tenant = tenant
  dataState.cursor = 0
  dataState.loaded = false
  dataState.loading = false
  dataState.error = null
  dataState.received = 0
  lastAuto = 0
  store = emptyStore()
  memo.clear()
  statsCache.clear()
  bump(ENTITIES)
  existingAnalytics()?.reset()
  for (const fn of resetHooks) fn()
}

/** Lädt (erstmals voll, danach inkrementell ab Cursor) alle Änderungen des Fahrzeugbuchs. */
export function load(tenant: string, opts: { force?: boolean } = {}): Promise<void> {
  if (dataState.tenant !== tenant) reset(tenant)
  if (dataState.loaded && !opts.force && !inflight) return Promise.resolve()
  if (inflight) {
    // läuft schon: bei force danach nochmals ab neuem Cursor (Änderungen seit Beginn nicht verlieren)
    if (opts.force) again = true
    return inflight
  }
  const my = (ctrl = new AbortController())
  const run = (async () => {
    dataState.loading = true
    dataState.error = null
    dataState.received = 0
    const changed = new Set<EntityName>()
    // Erstes Laden in einen neuen Bestand (Ansichten sehen bis zum Ende keinen halben Stand), Deltas direkt
    const initial = !dataState.loaded
    let target = initial ? emptyStore() : store
    let since = initial ? 0 : dataState.cursor
    try {
      do {
        again = false
        let next: Promise<Changes> | null = endpoints.changes(tenant, since, CHANGES_PAGE, my.signal)
        for (let page = 0; page < 10_000 && next; page++) {
          const ch: Changes = await next
          next = null
          if (my.signal.aborted || dataState.tenant !== tenant) return
          // nächste Seite schon anfordern, während diese verarbeitet wird (Cursor steht im Kopf der Antwort)
          if (ch.has_more) {
            next = endpoints.changes(tenant, ch.cursor, CHANGES_PAGE, my.signal)
            next.catch(() => undefined)
          }
          const res = applyChanges(ch, target)
          for (const e of res.changed) changed.add(e)
          const a = analytics()
          const replayFrom = target
          a.setReplay(() => fullDelta(replayFrom === store ? store : replayFrom))
          a.apply(res.delta)
          dataState.received += res.count
          since = ch.cursor
          // Delta: Cursor nach jeder Seite (Abbruch/Fehler setzt hier fort); erstes Laden: erst am Ende
          if (!initial) dataState.cursor = since
        }
        if (initial && target !== store) {
          store = target
          memo.clear()
          dataState.cursor = since
          target = store
        }
      } while (again && !my.signal.aborted)
      dataState.loaded = true
      dataState.loadedAt = new Date()
    } catch (e) {
      if (my.signal.aborted || isAbort(e)) return
      dataState.error = userMessage(e)
      throw e
    } finally {
      if (ctrl === my) {
        if (changed.size) {
          statsCache.clear()
          bump(changed)
        }
        dataState.loading = false
        inflight = null
        ctrl = null
      }
    }
  })()
  inflight = run
  return run
}

export async function refresh(): Promise<void> {
  if (dataState.tenant) await load(dataState.tenant, { force: true })
}

/** Mindestabstand für das automatische Nachladen (Tab wieder sichtbar / Fenster wieder im Fokus). */
export const STALE_MS = 60_000
let lastAuto = 0

/**
 * Nachladen, wenn der Stand älter als `minAgeMs` ist (z. B. nach Rückkehr in den Tab: Änderungen aus der App).
 * Gedrosselt: höchstens ein Versuch je `minAgeMs`, auch wenn das Laden fehlschlägt. Rückgabe null = nichts zu tun.
 */
export function refreshIfStale(minAgeMs = STALE_MS, now = Date.now()): Promise<void> | null {
  const tenant = dataState.tenant
  if (!tenant || !dataState.loaded || dataState.loading) return null
  if (now - (dataState.loadedAt?.getTime() ?? 0) < minAgeMs || now - lastAuto < minAgeMs) return null
  lastAuto = now
  return load(tenant, { force: true })
}

// ---------- Kennzahlen (Server) ----------
const statsCache = new Map<string, Promise<Stats>>()

/**
 * Kennzahlen je Fahrzeug, je Datenstand einmal geladen (gleichzeitige Aufrufe teilen sich die Anfrage). Gehört zum
 * Fahrzeugbuch, nicht zur Seite: wird beim Mandantenwechsel abgebrochen, nicht beim Routenwechsel.
 */
export function stats(tenant: string, vid: string): Promise<Stats> {
  const key = `${tenant}:${vid}`
  let p = statsCache.get(key)
  if (!p) {
    p = endpoints.stats(tenant, vid, tenantCtrl.signal)
    statsCache.set(key, p)
    p.catch(() => {
      if (statsCache.get(key) === p) statsCache.delete(key)
    })
  }
  return p
}

// ---------- Schreiben ----------
export class SyncRejected extends Error {
  constructor(readonly results: OpResult[]) {
    super(results.map((r) => r.error || 'abgelehnt').join('; '))
    this.name = 'SyncRejected'
  }
}

export interface SyncOutcome {
  results: OpResult[]
  conflicts: number
}

/** Ops senden, danach inkrementell neu laden. Abgelehnte Ops → SyncRejected (Meldung des Servers). */
export async function sync(tenant: string, ops: SyncOp[]): Promise<SyncOutcome> {
  const res = await endpoints.sync(tenant, ops)
  await load(tenant, { force: true }).catch(() => undefined)
  const rejected = res.results.filter((r) => r.status === 'rejected')
  if (rejected.length) throw new SyncRejected(rejected)
  return { results: res.results, conflicts: res.results.filter((r) => r.status === 'conflict').length }
}
