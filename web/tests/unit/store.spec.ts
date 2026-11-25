// Datenhaltung: normalisierte Maps + Indizes (inkrementell), Paging mit has_more/Cursor, Abbruch bei
// Mandantenwechsel, keine Persistenz von Fachdaten im Browser.
import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { Changes, Trip } from '../../src/api/types'

const changesMock = vi.fn()
vi.mock('../../src/api/endpoints', () => ({
  CHANGES_PAGE: 5000,
  endpoints: { changes: (...a: unknown[]) => changesMock(...a), stats: vi.fn(), me: vi.fn() },
}))

const KEYS = ['vehicles', 'odometer', 'fuel', 'maintenance', 'maintenance_items', 'maintenance_materials', 'material_articles', 'trips', 'places', 'customers', 'purpose_rules', 'tax_params', 'trip_periods', 'attachments'] as const
function page(over: Partial<Changes>, cursor: number, hasMore = false): Changes {
  return { ...(Object.fromEntries(KEYS.map((k) => [k, []])) as unknown as Changes), cursor, has_more: hasMore, ...over }
}
let n = 0
function trip(over: Partial<Trip> = {}): Trip {
  n++
  return {
    id: `t${n}`, version: 1, deleted: false, vehicle_id: 'v1', driver_sub: null, driver_name: 'A', start_at: `2026-10-${String((n % 28) + 1).padStart(2, '0')}T08:00:00+02:00`,
    end_at: null, km_start: n * 10, km_end: n * 10 + 10, distance_gps: null, distance_route: null, start_place_id: null, end_place_id: null, start_label: 'A', end_label: 'B',
    category: 'business', purpose: 'x', customer_id: 'c1', customer_name: null, status: 'confirmed', source: 'auto', suggestion_category: null, suggestion_purpose: null,
    suggestion_customer_id: null, suggestion_confidence: null, suggestion_reason: null, suggestion_source: null, track_hash: null, split_of: null, private_mode: false, note: null, km_estimated: false,
    ...over,
  }
}

beforeEach(async () => {
  vi.resetModules()
  changesMock.mockReset()
  window.sessionStorage.clear()
  window.localStorage.clear()
})

describe('Store: Indizes', () => {
  it('Fahrzeug-, Monats- und Eltern-Index werden bei Deltas inkrementell nachgeführt', async () => {
    const s = await import('../../src/store/data')
    s.reset('privat')
    const a = trip({ id: 'a', start_at: '2026-10-05T08:00:00+02:00' })
    const b = trip({ id: 'b', start_at: '2026-11-05T08:00:00+01:00' })
    s.applyChanges(page({ trips: [a, b], maintenance_items: [{ id: 'i1', version: 1, deleted: false, maintenance_id: 'm1', label: 'Öl', done: true, position: 0 }] }, 3))
    expect(s.ofVehicle('trip', 'v1').map((t) => t.id).sort()).toEqual(['a', 'b'])
    expect(s.tripsInMonth('v1', '2026-10').map((t) => t.id)).toEqual(['a'])
    expect(s.childrenOf('maintenance_item', 'maintenance_id', 'm1')).toHaveLength(1)
    expect(s.countBy('trip', 'customer_id')).toEqual({ c1: 2 })

    // Delta: Posten wechselt die Wartung → Eltern-Index nachgeführt (alter Eintrag entfernt)
    s.applyChanges(page({ maintenance_items: [{ id: 'i1', version: 2, deleted: false, maintenance_id: 'm2', label: 'Öl', done: true, position: 0 }] }, 4))
    expect(s.childrenOf('maintenance_item', 'maintenance_id', 'm1')).toHaveLength(0)
    expect(s.childrenOf('maintenance_item', 'maintenance_id', 'm2').map((i) => i.version)).toEqual([2])
  })

  it('gecachte Listen sind eingefroren (kein versehentliches Sortieren in place)', async () => {
    const s = await import('../../src/store/data')
    s.reset('privat')
    const v = { version: 1, deleted: false, make: null, model: null, plate: null, fuel_type: 'benzin', initial_km: 0, purchase_price: null, ownership: null, private_use_method: null, annual_fixed_costs: null } as const
    s.applyChanges(page({ vehicles: [{ ...v, id: 'v1', name: 'B' }, { ...v, id: 'v2', name: 'A' }] }, 1))
    const list = s.all('vehicle')
    expect(Object.isFrozen(list)).toBe(true)
    expect(() => (list as unknown as unknown[]).sort()).toThrow()
  })
})

describe('Store: Laden', () => {
  it('lädt alle Seiten (has_more) ab Cursor, Indizes nach dem Laden konsistent, danach nur Deltas', async () => {
    const s = await import('../../src/store/data')
    changesMock
      .mockResolvedValueOnce(page({ trips: [trip({ id: 'p1' })] }, 10, true))
      .mockResolvedValueOnce(page({ trips: [trip({ id: 'p2' })] }, 20, true))
      .mockResolvedValueOnce(page({ trips: [trip({ id: 'p3' })] }, 30, false))
    await s.load('privat')
    expect(changesMock.mock.calls.map((c) => c[1])).toEqual([0, 10, 20])
    expect(s.dataState.cursor).toBe(30)
    expect(s.dataState.loaded).toBe(true)
    expect(s.dataState.received).toBe(3)
    expect(s.ofVehicle('trip', 'v1')).toHaveLength(3)

    changesMock.mockResolvedValueOnce(page({ trips: [{ ...trip({ id: 'p2' }), vehicle_id: 'v9' }] }, 31))
    const t = s.tick('trip')
    await s.load('privat', { force: true })
    expect(changesMock.mock.calls.at(-1)![1]).toBe(30)
    expect(s.tick('trip')).not.toBe(t)
    expect(s.ofVehicle('trip', 'v1').map((x) => x.id).sort()).toEqual(['p1', 'p3'])
    expect(s.ofVehicle('trip', 'v9').map((x) => x.id)).toEqual(['p2'])
    expect(s.tripsInMonth('v1', s.ofVehicle('trip', 'v1')[0]!.start_at.slice(0, 7)).length).toBeGreaterThan(0)
  })

  it('Ansichten sehen beim ersten Laden keinen halben Stand; Abbruch bei Mandantenwechsel verwirft Seiten', async () => {
    const s = await import('../../src/store/data')
    let release!: (c: Changes) => void
    changesMock.mockResolvedValueOnce(page({ trips: [trip({ id: 'x1' })] }, 10, true)).mockImplementationOnce(
      (_t: string, _s: number, _l: number, signal: AbortSignal) =>
        new Promise<Changes>((res, rej) => {
          release = res
          signal.addEventListener('abort', () => rej(new DOMException('aborted', 'AbortError')))
        }),
    )
    const p = s.load('privat')
    await new Promise((r) => setTimeout(r, 0))
    expect(s.all('trip')).toHaveLength(0) // erste Seite liegt im neuen Bestand, noch nicht sichtbar
    const signal = changesMock.mock.calls[1]![3] as AbortSignal
    s.reset('muster-ag') // Mandantenwechsel
    expect(signal.aborted).toBe(true)
    release(page({ trips: [trip({ id: 'x2' })] }, 20))
    await p
    expect(s.dataState.tenant).toBe('muster-ag')
    expect(s.dataState.cursor).toBe(0)
    expect(s.all('trip')).toHaveLength(0)
  })

  it('Fachdaten bleiben im Speicher (weder localStorage noch sessionStorage)', async () => {
    const s = await import('../../src/store/data')
    changesMock.mockResolvedValueOnce(page({ trips: [trip({ id: 'geheim', purpose: 'Arzttermin' })] }, 1))
    await s.load('privat')
    const dump = JSON.stringify({ ...window.localStorage }) + JSON.stringify({ ...window.sessionStorage })
    expect(dump).not.toContain('geheim')
    expect(dump).not.toContain('Arzttermin')
  })
})
