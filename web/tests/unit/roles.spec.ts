import { describe, expect, it } from 'vitest'
import { canWrite, gate, hasRole, isAdmin, visibleNav, type NavItem } from '../../src/lib/roles'
import { routes } from '../../src/router'

describe('Rollen-Gating', () => {
  it('Rangfolge admin ⊇ write ⊇ read', () => {
    expect(hasRole('admin', 'write')).toBe(true)
    expect(hasRole('write', 'read')).toBe(true)
    expect(hasRole('read', 'write')).toBe(false)
    expect(hasRole('write', 'admin')).toBe(false)
    expect(hasRole(null, 'read')).toBe(false)
    expect(hasRole('owner' as never, 'read')).toBe(false)
    expect(canWrite('admin')).toBe(true)
    expect(canWrite('read')).toBe(false)
    expect(isAdmin('write')).toBe(false)
  })

  it('Guard-Entscheidung', () => {
    const ctx = { authenticated: true, role: 'read' as const, tenant: 'privat' }
    expect(gate({ public: true }, { ...ctx, authenticated: false })).toBe('ok')
    expect(gate({ minRole: 'read' }, { ...ctx, authenticated: false })).toBe('login')
    expect(gate({ minRole: 'read' }, { ...ctx, tenant: null })).toBe('choose-tenant')
    expect(gate({ minRole: 'read' }, ctx)).toBe('ok')
    expect(gate({ minRole: 'write' }, ctx)).toBe('forbidden')
    expect(gate({ minRole: 'admin' }, { ...ctx, role: 'write' })).toBe('forbidden')
    expect(gate({ minRole: 'admin' }, { ...ctx, role: 'admin' })).toBe('ok')
    expect(gate({}, { ...ctx, tenant: null })).toBe('ok') // Konto ohne Fahrzeugbuch
  })

  it('Navigation blendet nicht erlaubte Seiten aus', () => {
    const items: NavItem[] = [
      { to: '/uebersicht', label: 'Übersicht', icon: 'grid', minRole: 'read' },
      { to: '/verwaltung/mitglieder', label: 'Mitglieder', icon: 'users', minRole: 'admin' },
    ]
    expect(visibleNav(items, 'read').map((i) => i.label)).toEqual(['Übersicht'])
    expect(visibleNav(items, 'admin').map((i) => i.label)).toEqual(['Übersicht', 'Mitglieder'])
    expect(visibleNav(items, null)).toEqual([])
  })

  it('Routen-Metadaten: Deep-Links und Mindestrollen', () => {
    const flat = routes.flatMap((r) => [r, ...(r.children ?? []).map((c) => ({ ...c, path: `${r.path}/${c.path}` }))])
    const find = (p: string) => flat.find((r) => r.path === p)
    expect(find('/verwaltung/mitglieder')?.meta?.minRole).toBe('admin')
    expect(find('/stammdaten/steuerparameter')?.meta?.minRole).toBe('read')
    expect(find('/fahrzeuge/:vid/monatsabschluss')?.meta?.minRole).toBe('write')
    expect(find('/auth/callback')?.meta?.public).toBe(true)
  })
})
