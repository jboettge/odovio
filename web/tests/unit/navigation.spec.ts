import { describe, expect, it } from 'vitest'
import { abortNavigation, navigationSignal } from '../../src/api/navigation'

describe('Abbruch beim Routenwechsel', () => {
  it('bricht das Signal der alten Seite ab und liefert ein frisches', () => {
    const old = navigationSignal()
    expect(old.aborted).toBe(false)
    abortNavigation()
    expect(old.aborted).toBe(true)
    expect(navigationSignal()).not.toBe(old)
    expect(navigationSignal().aborted).toBe(false)
  })
})
