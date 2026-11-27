// Gemeinsame Logik der Fahrzeug- und Stammdaten-Ansichten.
import { computed, reactive, ref } from 'vue'
import { useRoute } from 'vue-router'
import type { EntityMap, EntityName, FuelEntry, Maintenance, OdometerReading, Trip } from './api/types'
import { ApiError } from './api/client'
import { all, byId, ofVehicle, sync, SyncRejected } from './store/data'
import { role, session } from './store/session'
import { notify, errorText } from './store/toasts'
import { canWrite } from './lib/roles'
import { deleteOp, upsertOp, uuid, validate, type FieldErrors } from './lib/schema'
import { stornoNeedsReason } from './lib/trips'
import { ENTITY_LABELS } from './lib/labels'

export function useVehicle() {
  const route = useRoute()
  const vid = computed(() => String(route.params.vid ?? ''))
  const vehicle = computed(() => byId('vehicle', vid.value))
  // aus dem Fahrzeug-Index (kein Filtern über alle Datensätze des Mandanten)
  const of = <E extends 'trip' | 'fuel' | 'odometer' | 'maintenance'>(e: E) => computed(() => ofVehicle(e, vid.value))
  return {
    vid,
    vehicle,
    trips: of('trip'),
    fuel: of('fuel'),
    odometer: of('odometer'),
    maintenance: of('maintenance'),
    periods: computed(() => ofVehicle('trip_period', vid.value).filter((p) => !p.deleted)),
    tenant: computed(() => session.tenant ?? ''),
    writable: computed(() => canWrite(role.value)),
  }
}

/** Verlauf-Seitenpanel. */
export function useHistory() {
  const sel = ref<{ entity: string; id: string; title?: string } | null>(null)
  return {
    sel,
    show: (entity: string, id: string, title?: string) => (sel.value = { entity, id, title }),
    close: () => (sel.value = null),
  }
}

type StornoEntity = 'trip' | 'fuel' | 'odometer' | 'maintenance'

/** Stornieren mit Begründung (Pflicht im abgeschlossenen Monat). */
export function useStorno() {
  const state = reactive({
    open: false,
    entity: null as EntityName | null,
    rec: null as { id: string; version: number } | null,
    label: '',
    reason: 'optional' as 'none' | 'optional' | 'required',
    busy: false,
    error: null as string | null,
  })

  function ask(entity: EntityName, rec: { id: string; version: number }, label: string) {
    const periods = all('trip_period')
    const needs = ['trip', 'fuel', 'odometer', 'maintenance'].includes(entity)
      ? stornoNeedsReason(entity as StornoEntity, rec as Trip | FuelEntry | Maintenance | OdometerReading, periods)
      : false
    Object.assign(state, { open: true, entity, rec, label, reason: needs ? 'required' : 'optional', busy: false, error: null })
  }

  async function confirm(reason: string) {
    if (!state.entity || !state.rec || !session.tenant) return
    state.busy = true
    state.error = null
    try {
      await sync(session.tenant, [deleteOp(state.entity, state.rec.id, state.rec.version, reason || undefined)])
      notify(`${ENTITY_LABELS[state.entity] ?? 'Eintrag'} storniert`)
      state.open = false
    } catch (e) {
      state.error = e instanceof SyncRejected ? `Vom Server abgelehnt: ${e.message}` : errorText(e)
    } finally {
      state.busy = false
    }
  }

  return { state, ask, confirm, close: () => (state.open = false) }
}

/** Formular-Editor für Stammdaten (Neu/Bearbeiten → Sync-Op, danach neu laden). */
export function useEditor<E extends EntityName>(entity: E, defaults: () => Record<string, unknown>) {
  const state = reactive({
    open: false,
    id: null as string | null,
    version: null as number | null,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any -- Formularwerte aus v-model (string/number/bool)
    form: {} as Record<string, any>,
    errors: {} as FieldErrors,
    busy: false,
    error: null as string | null,
  })

  /*
   * Idempotenz: id (bei Neuanlage) und op_id werden beim Öffnen festgelegt. Ein erneutes «Speichern» nach einem
   * Fehler ohne Antwort (Verbindung weg, Antwort verloren) sendet dieselbe Op – hatte der Server sie schon
   * angewendet, meldet er «duplicate» statt einen zweiten Datensatz anzulegen. Wurde der Inhalt seither geändert,
   * gibt es eine neue op_id (sonst würde der Server die Änderung als Duplikat verwerfen), aber dieselbe id.
   */
  let attempt = { id: '', opId: '', sent: null as string | null }

  function create(extra: Record<string, unknown> = {}) {
    attempt = { id: uuid(), opId: uuid(), sent: null }
    Object.assign(state, { open: true, id: null, version: null, form: { ...defaults(), ...extra }, errors: {}, error: null })
  }

  function edit(rec: EntityMap[E]) {
    attempt = { id: rec.id, opId: uuid(), sent: null }
    Object.assign(state, { open: true, id: rec.id, version: rec.version, form: { ...rec }, errors: {}, error: null })
  }

  async function save(transform?: (f: Record<string, unknown>) => Record<string, unknown>): Promise<boolean> {
    if (!session.tenant) return false
    const data = transform ? transform({ ...state.form }) : { ...state.form }
    state.errors = validate(entity, data)
    if (Object.keys(state.errors).length) {
      state.error = 'Bitte die markierten Felder prüfen.'
      return false
    }
    if (state.busy) return false
    state.busy = true
    state.error = null
    if (!attempt.id) attempt = { id: state.id ?? uuid(), opId: uuid(), sent: null }
    const op = upsertOp(entity, attempt.id, data, state.version, undefined, attempt.opId)
    const fingerprint = JSON.stringify([op.base_version, op.data])
    if (attempt.sent !== null && attempt.sent !== fingerprint) op.op_id = attempt.opId = uuid()
    attempt.sent = fingerprint
    try {
      const res = await sync(session.tenant, [op])
      attempt = { id: attempt.id, opId: uuid(), sent: null }
      notify(res.conflicts ? 'Gespeichert – gleichzeitige Änderung überschrieben (im Verlauf sichtbar)' : 'Gespeichert', res.conflicts ? 'info' : 'ok')
      state.open = false
      return true
    } catch (e) {
      const unclear = e instanceof ApiError && (e.status === 0 || e.status >= 500)
      state.error =
        e instanceof SyncRejected
          ? `Vom Server abgelehnt: ${e.message}`
          : unclear
            ? `${errorText(e)} Erneutes Speichern legt nichts doppelt an.`
            : errorText(e)
      return false
    } finally {
      state.busy = false
    }
  }

  return { state, create, edit, save, close: () => (state.open = false) }
}

/** Zahl aus Eingabefeld (leer → null). */
export function numOrNull(v: unknown): number | null {
  if (v === '' || v === null || v === undefined) return null
  const n = typeof v === 'number' ? v : Number(String(v).replace(/[’'\s]/g, '').replace(',', '.'))
  return Number.isFinite(n) ? n : NaN
}

export function strOrNull(v: unknown): string | null {
  if (v === null || v === undefined) return null
  const s = String(v).trim()
  return s ? s : null
}
