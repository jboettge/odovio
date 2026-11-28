// Review 11/2026, Web: W6/W7 (useEditor: ungespeicherte Änderungen, Feldfehler), W8 (Field verknüpft Fehler),
// W10 (useAsync verwirft veraltete Antworten), W18 (gedrosseltes Nachladen), W19 (useStorno).
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createApp, defineComponent, effectScope, h, nextTick, ref } from 'vue'
import type { SyncOp } from '../../src/api/types'

const syncMock = vi.fn<(tenant: string, ops: SyncOp[]) => Promise<{ results: unknown[]; conflicts: number }>>()
const periods: unknown[] = []
class SyncRejected extends Error {
  constructor(msg: string) {
    super(msg)
    this.name = 'SyncRejected'
  }
}
vi.mock('../../src/store/data', () => ({
  all: (e: string) => (e === 'trip_period' ? periods : []),
  byId: () => undefined,
  ofVehicle: () => [],
  sync: (tenant: string, ops: SyncOp[]) => syncMock(tenant, ops),
  SyncRejected,
}))

const ok = async () => ({ results: [{ status: 'applied' }], conflicts: 0 })
const flush = () => new Promise((r) => setTimeout(r, 0))

beforeEach(async () => {
  syncMock.mockReset()
  periods.splice(0)
  const { session } = await import('../../src/store/session')
  session.tenant = 'privat'
})

describe('useEditor: ungespeicherte Änderungen (W6)', () => {
  it('frisch geöffnet unverändert; Eingabe → geändert; zurück auf den Anfangswert → unverändert', async () => {
    const { useEditor } = await import('../../src/composables')
    const ed = useEditor('customer', () => ({ name: '', ref: '', note: '' }))
    expect(ed.dirty).toBe(false) // geschlossen
    ed.create()
    expect(ed.dirty).toBe(false)
    ed.state.form.name = 'Meier'
    expect(ed.dirty).toBe(true)
    ed.state.form.name = ''
    expect(ed.dirty).toBe(false)
    ed.edit({ id: 'c1', version: 1, deleted: false, name: 'B', ref: null, note: null } as never)
    expect(ed.dirty).toBe(false)
    ed.close()
    expect(ed.dirty).toBe(false)
  })

  it('weitere Formularteile (track) zählen mit; nach erfolgreichem Speichern geschlossen', async () => {
    const { useEditor } = await import('../../src/composables')
    const rows = ref<string[]>([])
    const ed = useEditor('customer', () => ({ name: 'X', ref: '', note: '' }), { track: () => rows.value })
    ed.create()
    rows.value = ['Position']
    expect(ed.dirty).toBe(true)
    syncMock.mockImplementation(ok)
    expect(await ed.save()).toBe(true)
    expect(ed.state.open).toBe(false)
    expect(ed.dirty).toBe(false)
  })
})

describe('useEditor: Feldfehler (W7)', () => {
  it('Fehler verschwindet beim Ändern des Feldes, allgemeine Meldung mit dem letzten Fehler', async () => {
    const { useEditor, INVALID } = await import('../../src/composables')
    const scope = effectScope()
    const ed = scope.run(() => useEditor('customer', () => ({ name: '', ref: '', note: '' })))!
    ed.create()
    expect(await ed.save()).toBe(false)
    expect(ed.state.errors.name).toBe('Pflichtfeld')
    expect(ed.state.error).toBe(INVALID)
    ed.state.form.ref = 'R-1' // anderes Feld: Fehler bleibt
    await nextTick()
    expect(ed.state.errors.name).toBe('Pflichtfeld')
    ed.state.form.name = 'M'
    await nextTick()
    expect(ed.state.errors.name).toBeUndefined()
    expect(ed.state.error).toBeNull()
    expect(syncMock).not.toHaveBeenCalled()
    scope.stop()
  })

  it('Fehler ausserhalb von save() (z. B. beim Verlassen des Feldes) verschwinden ebenfalls bei Eingabe', async () => {
    const { useEditor } = await import('../../src/composables')
    const scope = effectScope()
    const ed = scope.run(() => useEditor('vehicle', () => ({ name: 'A', vin: 'XYZ' })))!
    ed.create()
    ed.state.errors = { vin: 'ungültig' }
    await nextTick()
    expect(ed.state.errors.vin).toBe('ungültig')
    ed.state.form.vin = 'XYZ1'
    await nextTick()
    expect(ed.state.errors.vin).toBeUndefined()
    scope.stop()
  })
})

describe('useStorno (W19)', () => {
  const rec: { id: string; version: number; vehicle_id: string; date: string; km: number | null } = { id: 'f1', version: 2, vehicle_id: 'v1', date: '2026-03-14', km: 1000 }

  it('Begründung Pflicht im abgeschlossenen Monat, sonst optional', async () => {
    const { useStorno } = await import('../../src/composables')
    const s = useStorno()
    s.ask('fuel', rec, 'Tanken')
    expect(s.state.reason).toBe('optional')
    periods.push({ id: 'p', vehicle_id: 'v1', month: '2026-03', status: 'closed', deleted: false })
    s.ask('fuel', rec, 'Tanken')
    expect(s.state).toMatchObject({ open: true, reason: 'required', label: 'Tanken', error: null })
    s.ask('fuel', { ...rec, km: null } as typeof rec, 'ohne km')
    expect(s.state.reason).toBe('optional') // ohne km-Stand verlangt auch der Server keine Begründung
  })

  it('bestätigt: Lösch-Op mit Version und Begründung; Ablehnung bleibt im Dialog sichtbar', async () => {
    const { useStorno } = await import('../../src/composables')
    const s = useStorno()
    s.ask('fuel', rec, 'Tanken')
    syncMock.mockImplementationOnce(ok)
    await s.confirm('Doppelt erfasst')
    const op = syncMock.mock.calls[0]![1][0]!
    expect(op).toMatchObject({ entity: 'fuel', id: 'f1', action: 'delete', base_version: 2, reason: 'Doppelt erfasst' })
    expect(s.state.open).toBe(false)

    s.ask('fuel', rec, 'Tanken')
    syncMock.mockRejectedValueOnce(new SyncRejected('Monat abgeschlossen'))
    await s.confirm('')
    expect(s.state.open).toBe(true)
    expect(s.state.busy).toBe(false)
    expect(s.state.error).toBe('Vom Server abgelehnt: Monat abgeschlossen')
    expect(syncMock.mock.calls[1]![1][0]!.reason).toBeUndefined()
  })
})

describe('useAsync (W10)', () => {
  it('nur die Antwort zur letzten Eingabe zählt; vorherige Anfrage wird abgebrochen; reload', async () => {
    const { useAsync } = await import('../../src/use/async')
    const arg = ref(1)
    const resolvers = new Map<number, (v: string) => void>()
    const signals: AbortSignal[] = []
    const scope = effectScope()
    const r = scope.run(() =>
      useAsync(
        () => arg.value,
        (a, signal) => {
          signals.push(signal)
          return new Promise<string>((res) => resolvers.set(a, res))
        },
        '',
      ),
    )!
    expect(r.pending.value).toBe(true)
    arg.value = 2
    await nextTick()
    expect(signals[0]!.aborted).toBe(true)
    resolvers.get(2)!('zwei')
    await flush()
    resolvers.get(1)!('eins (veraltet)')
    await flush()
    expect(r.data.value).toBe('zwei')
    expect(r.pending.value).toBe(false)
    const again = r.reload()
    resolvers.get(2)!('zwei neu')
    await again
    expect(r.data.value).toBe('zwei neu')
    // Seite verlassen während einer Anfrage → Abbruch, Antwort wird nicht mehr übernommen
    arg.value = 3
    await nextTick()
    scope.stop()
    expect(signals.at(-1)!.aborted).toBe(true)
    resolvers.get(3)!('drei')
    await flush()
    expect(r.data.value).toBe('zwei neu')
  })

  it('Fehler: Meldung und Ursache (z. B. Status), resetOnError setzt den Wert zurück', async () => {
    const { useAsync } = await import('../../src/use/async')
    const { ApiError } = await import('../../src/api/client')
    const scope = effectScope()
    const fail = ref(false)
    const r = scope.run(() =>
      useAsync(
        () => fail.value,
        async (f) => {
          if (f) throw new ApiError(404, 'Nicht gefunden')
          return 'ok'
        },
        'leer',
        { resetOnError: true },
      ),
    )!
    await flush()
    expect(r.data.value).toBe('ok')
    fail.value = true
    await flush()
    expect(r.data.value).toBe('leer')
    expect(r.error.value).toBe('Nicht gefunden')
    expect((r.failure.value as InstanceType<typeof ApiError>).status).toBe(404)
    scope.stop()
  })
})

describe('Field: Fehler mit dem Eingabefeld verknüpft (W8)', () => {
  it('setzt aria-describedby/aria-invalid, wenn das Eingabeelement sie nicht selbst bindet', async () => {
    const Field = (await import('../../src/components/Field.vue')).default
    const err = ref<string | undefined>()
    const el = document.createElement('div')
    document.body.appendChild(el)
    const app = createApp(
      defineComponent({
        setup: () => () =>
          h(Field, { label: 'Marke', error: err.value, hint: 'z. B. Skoda' }, { default: (f: { id: string }) => h('input', { id: f.id }) }),
      }),
    )
    app.mount(el)
    await nextTick()
    const input = el.querySelector('input')!
    const hint = el.querySelector('.hint')!
    expect(input.getAttribute('aria-describedby')).toBe(hint.id)
    expect(input.hasAttribute('aria-invalid')).toBe(false)
    err.value = 'zu lang'
    await nextTick()
    await nextTick()
    const error = el.querySelector('.error')!
    expect(input.getAttribute('aria-describedby')).toBe(`${hint.id} ${error.id}`)
    expect(input.getAttribute('aria-invalid')).toBe('true')
    err.value = undefined
    await nextTick()
    await nextTick()
    expect(input.hasAttribute('aria-invalid')).toBe(false)
    app.unmount()
  })

  it('erstes fehlerhaftes Feld (Fokus nach «Speichern»)', async () => {
    const { firstInvalid } = await import('../../src/lib/focus')
    const form = document.createElement('form')
    const el = (tag: string, attrs: Record<string, string> = {}, ...kids: Node[]) => {
      const e = document.createElement(tag)
      for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v)
      e.append(...kids)
      return e
    }
    const err = el('p', { class: 'error' })
    err.textContent = 'Wochentag wählen'
    form.append(
      el('div', { class: 'field' }, el('input', { id: 'a' })),
      el('fieldset', {}, el('input', { id: 'b', type: 'checkbox' }), err),
      el('div', { class: 'field' }, el('input', { id: 'c', 'aria-invalid': 'true' })),
    )
    expect(firstInvalid(form)?.id).toBe('c')
    form.querySelector('#c')!.removeAttribute('aria-invalid')
    expect(firstInvalid(form)?.id).toBe('b')
    form.querySelector('.error')!.remove()
    expect(firstInvalid(form)).toBeNull()
  })
})

describe('refreshIfStale (W18)', () => {
  afterEach(() => vi.doUnmock('../../src/store/data'))

  it('lädt nur bei altem Stand nach und höchstens einmal je Intervall', async () => {
    vi.resetModules()
    vi.doUnmock('../../src/store/data')
    const changes = vi.fn(async () => ({ cursor: 1, has_more: false }))
    vi.doMock('../../src/api/endpoints', () => ({ CHANGES_PAGE: 10, endpoints: { changes } }))
    vi.doMock('../../src/lib/analyticsClient', () => ({ analytics: () => ({ setReplay: () => undefined, apply: () => undefined }), existingAnalytics: () => null }))
    const data = await import('../../src/store/data')
    expect(data.refreshIfStale()).toBeNull() // nichts geladen
    await data.load('privat')
    expect(changes).toHaveBeenCalledTimes(1)
    const t0 = data.dataState.loadedAt!.getTime()
    expect(data.refreshIfStale(60_000, t0 + 10_000)).toBeNull() // frisch
    await data.refreshIfStale(60_000, t0 + 61_000)
    expect(changes).toHaveBeenCalledTimes(2)
    // auch wenn loadedAt alt wäre: zweiter Versuch innerhalb des Intervalls gedrosselt
    data.dataState.loadedAt = new Date(t0)
    expect(data.refreshIfStale(60_000, t0 + 90_000)).toBeNull()
    expect(data.refreshIfStale(60_000, t0 + 125_000)).not.toBeNull()
    vi.doUnmock('../../src/api/endpoints')
    vi.doUnmock('../../src/lib/analyticsClient')
  })
})
