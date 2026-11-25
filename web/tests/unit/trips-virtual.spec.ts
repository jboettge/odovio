// Fahrtentabelle mit vielen Fahrten: nur sichtbare Zeilen im DOM, ARIA-Zeilenangaben, Platzhalter ohne Inline-Style,
// Nachrendern beim Scrollen.
import { describe, expect, it, vi } from 'vitest'
import { createApp, h, nextTick } from 'vue'
import { createMemoryHistory, createRouter, RouterView } from 'vue-router'

const N = 2000
const trips = Array.from({ length: N }, (_, i) => ({
  id: `t${String(i).padStart(5, '0')}`, version: 1, deleted: false, vehicle_id: 'v1', driver_name: 'Anna', created_by: 'Anna',
  start_at: new Date(Date.UTC(2024, 0, 1, 6) + i * 4 * 3_600_000).toISOString(), end_at: null, km_start: i * 10, km_end: i * 10 + 10,
  distance_gps: null, distance_route: null, start_place_id: null, end_place_id: null, start_label: `Start ${i}`, end_label: 'Ziel',
  category: 'business', purpose: `Termin ${i}`, customer_id: null, customer_name: null, status: 'confirmed', source: 'auto', private_mode: false, note: null, km_estimated: false,
}))
const KEYS = ['vehicles', 'odometer', 'fuel', 'maintenance', 'maintenance_items', 'maintenance_materials', 'material_articles', 'trips', 'places', 'customers', 'purpose_rules', 'tax_params', 'trip_periods', 'attachments']

vi.mock('../../src/api/endpoints', () => ({
  CHANGES_PAGE: 5000,
  endpoints: {
    changes: vi.fn(async () => ({
      ...Object.fromEntries(KEYS.map((k) => [k, []])),
      cursor: N,
      has_more: false,
      vehicles: [{ id: 'v1', version: 1, deleted: false, name: 'Skoda', fuel_type: 'benzin', initial_km: 0 }],
      trips,
    })),
    me: vi.fn(),
  },
}))

const flush = async () => {
  for (let i = 0; i < 6; i++) {
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
  }
}

describe('Fahrtentabelle mit 2000 Fahrten (virtuelles Scrollen)', () => {
  it('rendert nur sichtbare Zeilen mit aria-rowcount/aria-rowindex und scrollt nach', async () => {
    vi.stubGlobal('requestAnimationFrame', (cb: FrameRequestCallback) => setTimeout(() => cb(0), 0) as unknown as number)
    vi.stubGlobal('cancelAnimationFrame', (id: number) => clearTimeout(id))
    const { session } = await import('../../src/store/session')
    const { load } = await import('../../src/store/data')
    session.me = { sub: 's', name: 'Anna', tenants: [{ slug: 'privat', role: 'write' }] }
    session.tenant = 'privat'
    await load('privat')
    const VehicleTrips = (await import('../../src/views/vehicle/VehicleTrips.vue')).default
    const router = createRouter({ history: createMemoryHistory(), routes: [{ path: '/fahrzeuge/:vid/fahrten', component: VehicleTrips }] })
    await router.push('/fahrzeuge/v1/fahrten')
    const el = document.createElement('div')
    document.body.appendChild(el)
    const app = createApp({ render: () => h(RouterView) }).use(router)
    app.mount(el)
    await router.isReady()
    await flush()

    const table = el.querySelector('table')!
    expect(table.getAttribute('aria-rowcount')).toBe(String(N + 1))
    let rows = [...el.querySelectorAll('tbody tr[aria-rowindex]')]
    expect(rows.length).toBeGreaterThan(10)
    expect(rows.length).toBeLessThan(80)
    expect(rows[0]!.getAttribute('aria-rowindex')).toBe('2')
    // neueste zuerst
    expect(rows[0]!.textContent).toContain(`Termin ${N - 1}`)
    const pad = el.querySelector('tr.vpad svg')!
    expect(Number(pad.getAttribute('height'))).toBeGreaterThan(10_000)
    expect(el.querySelector('tr.vpad')!.getAttribute('aria-hidden')).toBe('true')
    expect(el.querySelectorAll('[style]')).toHaveLength(0)

    // Seite weit nach unten gescrollt: Tabelle beginnt 48'000 px über dem Fenster
    const wrap = el.querySelector('.vtable') as HTMLElement
    wrap.getBoundingClientRect = () => ({ top: -48_000, bottom: 50_000, left: 0, right: 1000, width: 1000, height: 98_000, x: 0, y: -48_000, toJSON() {} })
    window.dispatchEvent(new Event('scroll'))
    await flush()
    rows = [...el.querySelectorAll('tbody tr[aria-rowindex]')]
    const first = Number(rows[0]!.getAttribute('aria-rowindex'))
    expect(first).toBeGreaterThan(900)
    expect(rows.length).toBeLessThan(80)
    // fortlaufende Indizes
    rows.forEach((r, i) => expect(Number(r.getAttribute('aria-rowindex'))).toBe(first + i))
    expect(el.querySelectorAll('tr.vpad')).toHaveLength(2)

    app.unmount()
    el.remove()
    vi.unstubAllGlobals()
  })
})
