import { describe, expect, it } from 'vitest'
import { deleteOp, localIsoTs, toData, upsertOp, validate } from '../../src/lib/schema'

describe('Feldgrenzen wie Server-Schemas', () => {
  it('Fahrzeug', () => {
    expect(validate('vehicle', { name: '', fuel_type: 'benzin', initial_km: 0 })).toHaveProperty('name')
    expect(validate('vehicle', { name: 'x'.repeat(101), fuel_type: 'benzin', initial_km: 0 }).name).toMatch(/höchstens 100/)
    expect(validate('vehicle', { name: 'Skoda', fuel_type: 'benzin', initial_km: 5_000_001 }).initial_km).toMatch(/höchstens/)
    expect(validate('vehicle', { name: 'Skoda', fuel_type: 'benzin', initial_km: 1.5 }).initial_km).toMatch(/ganze Zahl/)
    expect(validate('vehicle', { name: 'Skoda', fuel_type: 'benzin', initial_km: 0, ownership: 'firma' }).ownership).toBe('ungültiger Wert')
    expect(validate('vehicle', { name: 'Skoda', fuel_type: 'benzin', initial_km: 0, purchase_price: Number.NaN }).purchase_price).toBe('Zahl erwartet')
    expect(validate('vehicle', { name: 'Skoda', fuel_type: 'benzin', initial_km: 48000 })).toEqual({})
  })
  it('Ort: keine Koordinaten für Wohnort/vertrauliche Orte, Radius 50–5000', () => {
    expect(validate('place', { name: 'Wohnort', kind: 'home', radius_m: 150, lat: 47.1, lon: 8.5 })).toHaveProperty('lat')
    expect(validate('place', { name: 'Arzt', kind: 'other', radius_m: 150, lat: 47.1, lon: 8.5, private: true })).toHaveProperty('lat')
    expect(validate('place', { name: 'Büro', kind: 'work', radius_m: 20 }).radius_m).toMatch(/mindestens 50/)
  })
  it('Regel: Wochentage und Zeiten', () => {
    const base = { priority: 10, result_category: 'business', origin: 'user' }
    expect(validate('purpose_rule', { ...base, weekdays: '1,2,8' }).weekdays).toMatch(/Format/)
    expect(validate('purpose_rule', { ...base, weekdays: '1,1' }).weekdays).toMatch(/Doppel/)
    expect(validate('purpose_rule', { ...base, time_from: '25:00' }).time_from).toBe('Format HH:MM')
    expect(validate('purpose_rule', { ...base, weekdays: '1,2,3', time_from: '06:00' })).toEqual({})
  })
  it('Steuerparameter: Geltungsbereich', () => {
    const base = { year: 2026, key: 'km_rate', value: 0.7 }
    expect(validate('tax_param', { ...base, scope: 'canton:zh' })).toHaveProperty('scope')
    expect(validate('tax_param', { ...base, scope: 'canton:ZH' })).toEqual({})
    expect(validate('tax_param', { ...base, scope: 'tenant', year: 1999 }).year).toMatch(/mindestens 2000/)
  })
  it('toData sendet alle Felder (ohne Metadaten) und Upsert-Op hat UUIDs', () => {
    const d = toData('customer', { id: 'x', version: 3, deleted: false, name: 'Meier AG', ref: '', note: undefined, created_by: 'Jakob' } as never)
    expect(d).toEqual({ name: 'Meier AG', ref: null, note: null })
    const op = upsertOp('customer', null, { name: 'Meier AG' }, null)
    expect(op.id).toMatch(/^[0-9a-f-]{36}$/)
    expect(op.op_id).not.toBe(op.id)
    expect(op.action).toBe('upsert')
    expect(op.base_version).toBeNull()
    expect(op.client_ts).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$/)
    const del = deleteOp('trip', op.id, 4, '  Doppelt erfasst gemäss Tacho  ')
    expect(del).toMatchObject({ action: 'delete', base_version: 4, data: {}, reason: 'Doppelt erfasst gemäss Tacho' })
    expect(localIsoTs(new Date(2026, 0, 2, 3, 4, 5))).toMatch(/^2026-01-02T03:04:05/)
  })
})
