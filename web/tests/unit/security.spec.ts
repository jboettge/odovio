import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { safeHref, userMessage } from '../../src/lib/security'
import { safeReturnTo } from '../../src/auth/oidc'
import { watchIdle } from '../../src/auth/idle'
import { ApiError } from '../../src/api/client'

describe('Sicherheit', () => {
  it('Links aus Daten nur https: oder relativ', () => {
    expect(safeHref('https://www.estv.admin.ch/x')).toBe('https://www.estv.admin.ch/x')
    expect(safeHref('/stammdaten/orte')).toBe('/stammdaten/orte')
    expect(safeHref('javascript:alert(1)')).toBeNull()
    expect(safeHref('JaVaScRiPt:alert(1)')).toBeNull()
    expect(safeHref('data:text/html,<b>x</b>')).toBeNull()
    expect(safeHref('http://example.ch')).toBeNull()
    expect(safeHref('//evil.example')).toBeNull()
    expect(safeHref(42)).toBeNull()
  })
  it('Rücksprung nach Login nur auf eigene Pfade', () => {
    expect(safeReturnTo('/verwaltung/mitglieder?buch=privat')).toBe('/verwaltung/mitglieder?buch=privat')
    expect(safeReturnTo('https://evil.example')).toBe('/')
    expect(safeReturnTo('//evil.example')).toBe('/')
    expect(safeReturnTo('/\\evil.example')).toBe('/')
    expect(safeReturnTo('/auth/callback?code=x')).toBe('/')
    expect(safeReturnTo(undefined)).toBe('/')
  })
  it('Fehlermeldungen ohne technische Details', () => {
    expect(userMessage(new ApiError(403, 'Verwaltung nur im Webfrontend'))).toBe('Verwaltung nur im Webfrontend')
    expect(userMessage(new TypeError("Cannot read properties of undefined (reading 'x')"))).toMatch(/^Unerwarteter Fehler/)
  })
})

describe('Abmeldung nach Inaktivität', () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => vi.useRealTimers())

  it('meldet nach Ablauf ab, Aktivität setzt die Frist zurück', () => {
    const onIdle = vi.fn()
    const w = watchIdle(onIdle, 60_000)
    vi.advanceTimersByTime(45_000)
    window.dispatchEvent(new KeyboardEvent('keydown'))
    vi.advanceTimersByTime(45_000)
    expect(onIdle).not.toHaveBeenCalled()
    vi.advanceTimersByTime(30_000)
    expect(onIdle).toHaveBeenCalledTimes(1)
    vi.advanceTimersByTime(120_000)
    expect(onIdle).toHaveBeenCalledTimes(1)
    w.stop()
  })
})
