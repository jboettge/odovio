// Datenbestand des gewählten Fahrzeugbuchs: vollständig über /changes geladen, danach inkrementell
// ab Cursor (Voll-Sync ist serverseitig rate-limitiert). Nach Schreibaktionen (Sync) neu laden.
import { shallowRef, reactive } from 'vue'
import { endpoints } from '../api/endpoints'
import { userMessage } from '../lib/security'
import { CHANGE_KEYS, type EntityMap, type EntityName, type Stats, type SyncOp, type OpResult } from '../api/types'

type Rows = { [E in EntityName]: Record<string, EntityMap[E]> }

function emptyRows(): Rows {
  const r = {} as Record<EntityName, Record<string, unknown>>
  for (const e of Object.keys(CHANGE_KEYS) as EntityName[]) r[e] = {}
  return r as Rows
}

export const dataState = reactive({
  tenant: null as string | null,
  cursor: 0,
  loaded: false,
  loading: false,
  error: null as string | null,
  loadedAt: null as Date | null,
})

const rows = shallowRef<Rows>(emptyRows())
const statsCache = shallowRef<Record<string, Stats>>({})

export function all<E extends EntityName>(entity: E): EntityMap[E][] {
  return Object.values(rows.value[entity])
}

export function active<E extends EntityName>(entity: E): EntityMap[E][] {
  return all(entity).filter((r) => !r.deleted)
}

export function byId<E extends EntityName>(entity: E, id: string | null | undefined): EntityMap[E] | undefined {
  return id ? rows.value[entity][id] : undefined
}

export function reset(tenant: string | null): void {
  dataState.tenant = tenant
  dataState.cursor = 0
  dataState.loaded = false
  dataState.error = null
  rows.value = emptyRows()
  statsCache.value = {}
}

let inflight: Promise<void> | null = null

/** Lädt (erstmals voll, danach inkrementell) alle Änderungen des Fahrzeugbuchs. */
export function load(tenant: string, opts: { force?: boolean } = {}): Promise<void> {
  if (dataState.tenant !== tenant) reset(tenant)
  if (dataState.loaded && !opts.force) return Promise.resolve()
  inflight ??= (async () => {
    dataState.loading = true
    dataState.error = null
    try {
      const next: Rows = { ...rows.value }
      for (const e of Object.keys(next) as EntityName[]) next[e] = { ...next[e] } as never
      let since = dataState.cursor
      for (let page = 0; page < 1000; page++) {
        const ch = await endpoints.changes(tenant, since)
        if (dataState.tenant !== tenant) return
        for (const [entity, key] of Object.entries(CHANGE_KEYS) as [EntityName, keyof typeof ch][]) {
          const list = ch[key] as unknown as EntityMap[EntityName][] | undefined
          for (const rec of list ?? []) (next[entity] as Record<string, unknown>)[rec.id] = rec
        }
        since = ch.cursor
        if (!ch.has_more) break
      }
      rows.value = next
      statsCache.value = {}
      dataState.cursor = since
      dataState.loaded = true
      dataState.loadedAt = new Date()
    } catch (e) {
      dataState.error = userMessage(e)
      throw e
    } finally {
      dataState.loading = false
      inflight = null
    }
  })()
  return inflight
}

export async function refresh(): Promise<void> {
  if (dataState.tenant) await load(dataState.tenant, { force: true })
}

export async function stats(tenant: string, vid: string): Promise<Stats> {
  const hit = statsCache.value[vid]
  if (hit && dataState.tenant === tenant) return hit
  const s = await endpoints.stats(tenant, vid)
  statsCache.value = { ...statsCache.value, [vid]: s }
  return s
}

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

/** Ops senden, danach neu laden. Abgelehnte Ops → SyncRejected (Meldung des Servers). */
export async function sync(tenant: string, ops: SyncOp[]): Promise<SyncOutcome> {
  const res = await endpoints.sync(tenant, ops)
  await load(tenant, { force: true }).catch(() => undefined)
  const rejected = res.results.filter((r) => r.status === 'rejected')
  if (rejected.length) throw new SyncRejected(rejected)
  return { results: res.results, conflicts: res.results.filter((r) => r.status === 'conflict').length }
}
