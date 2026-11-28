import { describe, expect, it } from 'vitest'
import { hex, sniff } from '../../src/lib/receipts'
import { currentKm, kmPoints, kmWarning, pricePerLiterWarning, type KmPoint } from '../../src/lib/readings'

const bytes = (...xs: (number | string)[]) => new Uint8Array(xs.flatMap((x) => (typeof x === 'string' ? [...x].map((c) => c.charCodeAt(0)) : [x])))

describe('sniff (Magic Bytes wie der Server)', () => {
  it('erkennt JPEG, PDF und HEIC', () => {
    expect(sniff(bytes(0xff, 0xd8, 0xff, 0xe0))).toBe('image/jpeg')
    expect(sniff(bytes('%PDF-1.7'))).toBe('application/pdf')
    expect(sniff(bytes(0, 0, 0, 0x18, 'ftypheic', 0, 0))).toBe('image/heic')
    expect(sniff(bytes(0, 0, 0, 0x18, 'ftypmif1', 0, 0))).toBe('image/heic')
  })
  it('andere Bilder → Umwandlung, MP4/Unbekanntes → abgelehnt', () => {
    expect(sniff(bytes(0x89, 'PNG', 0x0d, 0x0a))).toBe('image')
    expect(sniff(bytes('RIFF', 0, 0, 0, 0, 'WEBP'))).toBe('image')
    expect(sniff(bytes('GIF89a'))).toBe('image')
    expect(sniff(bytes(0, 0, 0, 0x18, 'ftypisom', 0, 0))).toBeNull()
    expect(sniff(bytes('PK', 3, 4))).toBeNull()
    expect(sniff(bytes('<svg'))).toBeNull()
  })
  it('hex', () => expect(hex(new Uint8Array([0, 15, 255]).buffer)).toBe('000fff'))
})

describe('Kilometer-Plausibilität', () => {
  const pts: KmPoint[] = [
    { id: 'a', date: '2026-03-01', km: 10_000 },
    { id: 'b', date: '2026-04-01', km: 11_000 },
    { id: 'c', date: '2026-05-01', km: 12_000 },
  ]
  it('passt zwischen früheren und späteren Ständen', () => {
    expect(kmWarning(pts, '2026-04-15', 11_500, 0)).toBeNull()
    expect(kmWarning(pts, '2026-06-01', 12_500, 0)).toBeNull()
  })
  it('kleiner als früher / grösser als später / unter Start-km', () => {
    expect(kmWarning(pts, '2026-04-15', 10_500, 0)).toMatch(/^Kleiner als 11.000 km am 01\.04\.2026/)
    expect(kmWarning(pts, '2026-04-15', 12_500, 0)).toMatch(/^Grösser als 12.000 km am 01\.05\.2026/)
    expect(kmWarning(pts, '2026-04-15', 500, 1000)).toMatch(/Start-km/)
  })
  it('eigener Datensatz beim Bearbeiten ausgenommen; leere Eingaben ohne Hinweis', () => {
    expect(kmWarning(pts, '2026-04-02', 10_800, 0, 'b')).toBeNull()
    expect(kmWarning(pts, '2026-04-15', null, 0)).toBeNull()
    expect(kmWarning(pts, '', 1, 0)).toBeNull()
  })
  it('kmPoints/currentKm aus allen Quellen, ohne stornierte', () => {
    const base = { version: 1, deleted: false, created_by: null, updated_by: null, created_at: '', updated_at: '' }
    const points = kmPoints({
      odometer: [{ ...base, id: 'o', vehicle_id: 'v', date: '2026-01-01', km: 100, note: null }],
      fuel: [{ ...base, id: 'f', vehicle_id: 'v', date: '2026-01-02', km: 200, liters: 1, price_total: 2, full_tank: true, station: null, note: null, deleted: true }],
      maintenance: [{ ...base, id: 'm', vehicle_id: 'v', date: '2026-01-03', km: null, title: 'x', cost: null, note: null, next_due_km: null, next_due_date: null }],
      trips: [],
    } as never)
    expect(points.map((p) => p.id)).toEqual(['o'])
    expect(currentKm(points, 50)).toBe(100)
    expect(currentKm([], 50)).toBe(50)
  })
  it('Literpreis', () => {
    expect(pricePerLiterWarning(40, 76)).toBeNull()
    expect(pricePerLiterWarning(40, 9)).toMatch(/ungewöhnlich/)
    expect(pricePerLiterWarning(null, 9)).toBeNull()
  })
})
