import { describe, expect, it } from 'vitest'
import { chf, consumption, currentMonth, date, dateTime, km, month, monthOf, num, previousMonth, relative } from '../../src/lib/format'

const APOS = /[’']/

describe('Formatierung de-CH', () => {
  it('Kilometer mit Schweizer Tausendertrennzeichen', () => {
    expect(km(53410)).toMatch(new RegExp(`^53${APOS.source}410 km$`))
    expect(km(null)).toBe('–')
    expect(num(1234567)).toMatch(/^1[’']234[’']567$/)
  })
  it('CHF mit zwei Nachkommastellen und Punkt', () => {
    expect(chf(1234.5)).toMatch(/^CHF 1[’']234\.50$/)
    expect(chf(0.114, 3)).toBe('CHF 0.114')
    expect(chf(undefined)).toBe('–')
    expect(chf(Number.NaN)).toBe('–')
  })
  it('Verbrauch', () => {
    expect(consumption(6.43)).toBe('6.43 l/100 km')
  })
  it('Datum de-CH ohne Zeitzonenversatz', () => {
    expect(date('2026-11-25')).toBe('25.11.2026')
    expect(date('2026-01-01')).toBe('01.01.2026')
    expect(dateTime('2026-11-23T07:42:00+01:00')).toMatch(/^23\.11\.2026 \d{2}:42$/)
  })
  it('Monate', () => {
    expect(month('2026-11')).toBe('November 2026')
    expect(month('x')).toBe('–')
    expect(monthOf('2026-03-31')).toBe('2026-03')
    expect(previousMonth('2026-01')).toBe('2025-12')
    expect(currentMonth(new Date(2026, 10, 25))).toBe('2026-11')
  })
  it('Relative Zeit', () => {
    const now = new Date('2026-11-25T12:00:00Z')
    expect(relative('2026-11-25T11:59:30Z', now)).toBe('gerade eben')
    expect(relative('2026-11-25T11:00:00Z', now)).toBe('vor 1 Std.')
    expect(relative('2026-11-24T11:00:00Z', now)).toBe('gestern')
  })
})
