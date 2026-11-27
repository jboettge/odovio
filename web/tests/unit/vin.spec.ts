import { describe, expect, it } from 'vitest'
import { validate } from '../../src/lib/schema'
import { VIN_ERROR, isValidVin, normalizeVin, vinCheckDigit, vinOrNull, vinWarning } from '../../src/lib/vin'

describe('VIN (wie server/app/schemas.normalize_vin und iOS VIN.swift)', () => {
  it('normalisiert Leerzeichen, Bindestriche und Kleinbuchstaben', () => {
    expect(normalizeVin(' wvw-zzz 1kz6w0\t00001 ')).toBe('WVWZZZ1KZ6W000001')
    expect(normalizeVin(null)).toBe('')
    expect(vinOrNull('  - ')).toBeNull()
    expect(vinOrNull('wvwzzz1kz6w000001')).toBe('WVWZZZ1KZ6W000001')
  })
  it('gültig: genau 17 Zeichen ohne I, O, Q', () => {
    expect(isValidVin('WVWZZZ1KZ6W000001')).toBe(true)
    for (const bad of ['WVWZZZ1KZ6W00000', 'WVWZZZ1KZ6W0000012', 'WVWZZZ1KZ6W00000I', 'WVWZZZ1KZ6W00000O', 'WVWZZZ1KZ6W00000Q', 'WVWZZZ1KZ6W00000Ä']) {
      expect(isValidVin(bad), bad).toBe(false)
    }
  })
  it('Prüfziffer nur als Hinweis bei nordamerikanischen VINs', () => {
    expect(vinCheckDigit('1M8GDM9AXKP042788')).toBe('X')
    expect(vinWarning('1M8GDM9AXKP042788')).toBeNull()
    expect(vinWarning('1M8GDM9A1KP042788')).toMatch(/erwartet «X»/)
    expect(vinWarning('WVWZZZ1KZ6W000001')).toBeNull()          // Europa: keine Prüfziffer-Pflicht
    expect(vinWarning('WVWZZZ1KZ6W00000O')).toBeNull()          // ungültig → Fehler statt Hinweis
  })
  it('Feldvalidierung vor dem Senden', () => {
    const base = { name: 'Golf', fuel_type: 'benzin', initial_km: 0 }
    expect(validate('vehicle', { ...base, vin: 'WVWZZZ1KZ6W000001' })).toEqual({})
    expect(validate('vehicle', { ...base, vin: null })).toEqual({})
    expect(validate('vehicle', { ...base, vin: 'WVWZZZ1KZ6W00000O' }).vin).toBe(VIN_ERROR)
    expect(validate('vehicle', { ...base, vin: 'WVWZZZ1KZ6W0000012' }).vin).toBe(VIN_ERROR)
  })
})
