import { describe, expect, it } from 'vitest'
import { DEFAULT_SOURCE_URL, sourceHref } from '../../src/lib/source'

describe('sourceHref (AGPL-Quellcode-Link)', () => {
  it('übernimmt https-Links vom Server', () => {
    expect(sourceHref('https://git.example.ch/odovio')).toBe('https://git.example.ch/odovio')
  })
  it('fällt bei fehlendem, relativem oder unsicherem Wert auf das Repository zurück', () => {
    for (const v of [undefined, null, '', '/quellcode', 'http://git.example.ch', 'javascript:alert(1)', 42]) {
      expect(sourceHref(v)).toBe(DEFAULT_SOURCE_URL)
    }
  })
})
