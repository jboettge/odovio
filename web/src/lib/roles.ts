import type { Role } from '../api/types'

/** Rangfolge: admin ⊇ write ⊇ read. */
const RANK: Record<Role, number> = { read: 1, write: 2, admin: 3 }

export const ROLE_LABELS: Record<Role, string> = {
  admin: 'Verwalten',
  write: 'Bearbeiten',
  read: 'Lesen',
}

export const ROLE_DESCRIPTIONS: Record<Role, string> = {
  admin: 'Bearbeiten und Mitglieder verwalten',
  write: 'Einträge erfassen, Stammdaten bearbeiten, Monate abschliessen',
  read: 'Nur ansehen – Privatfahrten erscheinen ohne Details',
}

export function isRole(v: unknown): v is Role {
  return v === 'admin' || v === 'write' || v === 'read'
}

/** Hat `role` mindestens die Rechte von `min`? Unbekannte/fehlende Rolle → nein. */
export function hasRole(role: Role | null | undefined, min: Role): boolean {
  if (!role || !isRole(role)) return false
  return RANK[role] >= RANK[min]
}

export function canWrite(role: Role | null | undefined): boolean {
  return hasRole(role, 'write')
}

export function isAdmin(role: Role | null | undefined): boolean {
  return hasRole(role, 'admin')
}

export interface GateMeta {
  /** Seite ohne Anmeldung erreichbar (Start, Callback). */
  public?: boolean
  /** Mindestrolle im aktuellen Fahrzeugbuch; fehlt = keine Fahrzeugbuch-Rolle nötig (z. B. Konto). */
  minRole?: Role
}

export type GateResult = 'ok' | 'login' | 'choose-tenant' | 'forbidden'

/** Entscheidung des Router-Guards (rein, testbar). */
export function gate(meta: GateMeta, ctx: { authenticated: boolean; role: Role | null; tenant: string | null }): GateResult {
  if (meta.public) return 'ok'
  if (!ctx.authenticated) return 'login'
  if (!meta.minRole) return 'ok'
  if (!ctx.tenant) return 'choose-tenant'
  return hasRole(ctx.role, meta.minRole) ? 'ok' : 'forbidden'
}

export interface NavItem {
  to: string
  label: string
  minRole?: Role
  icon: string
}

/** Navigation: nicht erlaubte Seiten erscheinen nicht. */
export function visibleNav(items: NavItem[], role: Role | null): NavItem[] {
  return items.filter((i) => !i.minRole || hasRole(role, i.minRole))
}
