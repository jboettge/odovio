import { describe, expect, it, vi } from 'vitest'
import { createApp, h, nextTick } from 'vue'
import { createMemoryHistory, createRouter, RouterView } from 'vue-router'

const changes = {
  cursor: 9,
  has_more: false,
  vehicles: [{ id: 'v1', version: 1, deleted: false, name: 'Skoda Octavia', fuel_type: 'benzin', initial_km: 0 }],
  places: [{ id: 'p1', version: 1, deleted: false, name: 'Privater Ort', kind: 'other', private: true, lat: null, lon: null, radius_m: 150 }],
  trips: [
    // maskiert geliefert (Leserolle): Orte/Zweck = null
    { id: 't1', version: 1, deleted: false, vehicle_id: 'v1', start_at: '2026-11-21T10:15:00+01:00', end_at: '2026-11-21T11:00:00+01:00', km_start: 100, km_end: 185, category: 'private', status: 'confirmed', source: 'auto', private_mode: false, start_label: null, end_label: null, start_place_id: null, end_place_id: null, purpose: null, customer_id: null, customer_name: null, note: null, driver_name: 'Jakob Muster', km_estimated: false, distance_gps: null, distance_route: null },
    { id: 't2', version: 2, deleted: false, vehicle_id: 'v1', start_at: '2026-11-23T07:42:00+01:00', end_at: '2026-11-23T08:00:00+01:00', km_start: 185, km_end: 197, category: 'commute', status: 'suggested', source: 'auto', private_mode: false, start_label: 'Wohnort', end_label: 'Büro b-re.ch', start_place_id: null, end_place_id: null, purpose: null, customer_id: null, customer_name: null, note: null, driver_name: 'Jakob Muster', km_estimated: true, distance_gps: null, distance_route: null },
  ],
}

vi.mock('../../src/api/endpoints', () => ({
  endpoints: { changes: vi.fn(async () => ({ ...emptyChanges(), ...changes })), me: vi.fn() },
}))
function emptyChanges() {
  return Object.fromEntries(['vehicles', 'odometer', 'fuel', 'maintenance', 'maintenance_items', 'maintenance_materials', 'material_articles', 'trips', 'places', 'customers', 'purpose_rules', 'tax_params', 'trip_periods', 'attachments'].map((k) => [k, []]))
}

describe('Fahrtentabelle (Leserolle)', () => {
  it('zeigt maskierte Privatfahrten als «Privatfahrt», geschätzte km mit «ca.», keine Storno-Knöpfe', async () => {
    const { session } = await import('../../src/store/session')
    const { load } = await import('../../src/store/data')
    session.me = { sub: 's', name: 'Treuhand', tenants: [{ slug: 'privat', role: 'read' }] }
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
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    const rows = [...el.querySelectorAll('tbody tr')]
    expect(rows).toHaveLength(2)
    const priv = rows.find((r) => r.textContent!.includes('85 km'))!
    expect(priv.textContent).toContain('Privatfahrt')
    expect(priv.textContent).not.toContain('null')
    const est = rows.find((r) => r.textContent!.includes('Büro b-re.ch'))!
    expect(est.querySelector('.badge-warn')!.textContent).toBe('ca.')
    expect(el.querySelectorAll('button[aria-label*="stornieren"]')).toHaveLength(0)
    expect(el.querySelectorAll('[style]')).toHaveLength(0)
    app.unmount()
    el.remove()
  })
})
