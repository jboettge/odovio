// Befunde Review 11/2026: W3 (Idempotenz Editor), W1 (Rechteverlust-Text), W15 (ConfirmDialog), W17 (Fehler-Toasts).
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createApp, h, nextTick, reactive } from 'vue'
import type { SyncOp } from '../../src/api/types'
import { ApiClient, ApiError, type TokenProvider } from '../../src/api/client'

const syncMock = vi.fn<(tenant: string, ops: SyncOp[]) => Promise<{ results: unknown[]; conflicts: number }>>()
vi.mock('../../src/store/data', () => ({
  all: () => [],
  byId: () => undefined,
  ofVehicle: () => [],
  sync: (tenant: string, ops: SyncOp[]) => syncMock(tenant, ops),
  SyncRejected: class SyncRejected extends Error {},
}))

const lost = () => new ApiError(0, 'Keine Verbindung zum Server. Bitte Netzwerk prüfen und erneut versuchen.')
const ok = async () => ({ results: [{ status: 'applied' }], conflicts: 0 })

describe('useEditor: id/op_id beim Öffnen festlegen (W3)', () => {
  beforeEach(async () => {
    syncMock.mockReset()
    const { session } = await import('../../src/store/session')
    session.tenant = 'privat'
  })

  it('Neuanlage: erneutes Speichern nach verlorener Antwort sendet dieselbe id und op_id', async () => {
    const { useEditor } = await import('../../src/composables')
    const ed = useEditor('customer', () => ({ name: '', ref: '', note: '' }))
    ed.create()
    ed.state.form.name = 'Meier AG'
    syncMock.mockRejectedValueOnce(lost()).mockImplementationOnce(ok)
    expect(await ed.save()).toBe(false)
    expect(ed.state.error).toContain('Erneutes Speichern legt nichts doppelt an')
    expect(await ed.save()).toBe(true)
    const [a, b] = syncMock.mock.calls.map((c) => c[1][0]!)
    expect(b!.op_id).toBe(a!.op_id)
    expect(b!.id).toBe(a!.id)
    expect(ed.state.id).toBeNull() // Titel bleibt «erfassen»
  })

  it('Inhalt nach Fehler geändert → neue op_id, aber dieselbe id (Server soll die Änderung nicht als Duplikat verwerfen)', async () => {
    const { useEditor } = await import('../../src/composables')
    const ed = useEditor('customer', () => ({ name: '', ref: '', note: '' }))
    ed.create()
    ed.state.form.name = 'Meier AG'
    syncMock.mockRejectedValueOnce(lost()).mockImplementationOnce(ok)
    await ed.save()
    ed.state.form.name = 'Meier AG Zürich'
    await ed.save()
    const [a, b] = syncMock.mock.calls.map((c) => c[1][0]!)
    expect(b!.op_id).not.toBe(a!.op_id)
    expect(b!.id).toBe(a!.id)
  })

  it('jedes Öffnen und jeder Erfolg → neue op_id; Bearbeiten behält die Datensatz-id', async () => {
    const { useEditor } = await import('../../src/composables')
    const ed = useEditor('customer', () => ({ name: '', ref: '', note: '' }))
    syncMock.mockImplementation(ok)
    ed.create()
    ed.state.form.name = 'A'
    await ed.save()
    ed.create()
    ed.state.form.name = 'A'
    await ed.save()
    ed.edit({ id: 'c1', version: 3, deleted: false, name: 'B', ref: null, note: null } as never)
    await ed.save()
    await ed.save()
    const ops = syncMock.mock.calls.map((c) => c[1][0]!)
    expect(new Set(ops.map((o) => o.op_id)).size).toBe(4)
    expect(ops[0]!.id).not.toBe(ops[1]!.id)
    expect(ops[2]!.id).toBe('c1')
    expect(ops[2]!.base_version).toBe(3)
  })
})

describe('lostRights (W1)', () => {
  it('beschreibt verlorene Rechte bei Herabstufung/Entfernen', async () => {
    const { lostRights } = await import('../../src/lib/roles')
    expect(lostRights('admin', 'write')).toBe('die Mitgliederverwaltung')
    expect(lostRights('admin', 'read')).toBe('die Mitgliederverwaltung und das Erfassen von Einträgen')
    expect(lostRights('write', 'read')).toBe('das Erfassen von Einträgen')
    expect(lostRights('admin', null)).toBe('den Zugriff auf das Fahrzeugbuch')
    expect(lostRights('read', 'admin')).toBeNull()
    expect(lostRights('admin', 'admin')).toBeNull()
  })
})

describe('Toasts (W17)', () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => vi.useRealTimers())

  it('Erfolg schliesst sich automatisch, Fehler bleibt bis zum Schliessen', async () => {
    const { notify, toasts, dismiss } = await import('../../src/store/toasts')
    toasts.splice(0)
    notify('Gespeichert')
    notify('Fehlgeschlagen', 'error', 8000)
    vi.advanceTimersByTime(60_000)
    expect(toasts.map((t) => t.text)).toEqual(['Fehlgeschlagen'])
    dismiss(toasts[0]!.id)
    expect(toasts).toHaveLength(0)
  })
})

describe('ConfirmDialog (W15)', () => {
  it('setzt den Begründungsfehler beim erneuten Öffnen zurück; eindeutige Formular-IDs', async () => {
    // jsdom kennt showModal/close nicht
    HTMLDialogElement.prototype.showModal ??= function (this: HTMLDialogElement) {
      this.open = true
    }
    HTMLDialogElement.prototype.close ??= function (this: HTMLDialogElement) {
      this.open = false
    }
    const ConfirmDialog = (await import('../../src/components/ConfirmDialog.vue')).default
    const state = reactive({ open: true })
    const el = document.createElement('div')
    document.body.appendChild(el)
    const app = createApp({
      render: () => [
        h(ConfirmDialog, { open: state.open, title: 'Stornieren', reason: 'required' }),
        h(ConfirmDialog, { open: false, title: 'Zweiter' }),
      ],
    })
    app.mount(el)
    await nextTick()
    const forms = [...el.querySelectorAll('form')]
    expect(forms).toHaveLength(2)
    expect(forms[0]!.id).not.toBe(forms[1]!.id)
    forms[0]!.dispatchEvent(new Event('submit', { cancelable: true }))
    await nextTick()
    expect(el.textContent).toContain('mindestens 10 Zeichen erforderlich')
    state.open = false
    await nextTick()
    state.open = true
    await nextTick()
    expect(el.textContent).not.toContain('mindestens 10 Zeichen erforderlich')
    app.unmount()
  })
})

describe('ApiClient: Abbruch mitten in der Antwort (W3)', () => {
  it('→ ApiError 0 «Keine Verbindung» statt unerwartetem Fehler', async () => {
    const t: TokenProvider = { getToken: vi.fn(async () => 'tok'), refresh: vi.fn(async () => null), onUnauthorized: vi.fn() }
    const broken = new ReadableStream({
      start(c) {
        c.enqueue(new TextEncoder().encode('{"results":['))
        c.error(new TypeError('network error'))
      },
    })
    const fetchMock = vi.fn(async () => new Response(broken, { status: 200, headers: { 'Content-Type': 'application/json' } }))
    const c = new ApiClient(t, '', fetchMock as unknown as typeof fetch)
    await expect(c.post('/api/t/privat/sync', { ops: [] })).rejects.toMatchObject({ status: 0, message: expect.stringContaining('Keine Verbindung') })
  })
})
