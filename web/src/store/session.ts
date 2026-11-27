// Angemeldeter Benutzer (/api/me) und gewähltes Fahrzeugbuch.
import { computed, reactive } from 'vue'
import { endpoints } from '../api/endpoints'
import type { Me, Role, TenantInfo } from '../api/types'
import { isRole } from '../lib/roles'
import { userMessage } from '../lib/security'

const TENANT_KEY = 'fzb.tenant'

function readPref(): string | null {
  try {
    return window.sessionStorage.getItem(TENANT_KEY)
  } catch {
    return null
  }
}

function writePref(slug: string | null): void {
  try {
    if (slug) {
      window.sessionStorage.setItem(TENANT_KEY, slug)
    } else {
      window.sessionStorage.removeItem(TENANT_KEY)
    }
  } catch {
    /* Speicher gesperrt: ohne Vorauswahl weiter */
  }
}

export const session = reactive({
  me: null as Me | null,
  tenant: null as string | null,
  loading: false,
  error: null as string | null,
})

export const tenants = computed<TenantInfo[]>(() =>
  (session.me?.tenants ?? []).filter((t) => isRole(t.role)),
)

export const currentTenant = computed<TenantInfo | null>(() => tenants.value.find((t) => t.slug === session.tenant) ?? null)

/** Anzeigename des gewählten Fahrzeugbuchs (statt Kürzel/Slug). */
export const tenantName = computed(() => currentTenant.value?.name || session.tenant || '')
export const role = computed<Role | null>(() => currentTenant.value?.role ?? null)

export const displayName = computed(() => session.me?.display_name || session.me?.name || 'Unbekannt')

let pending: Promise<Me> | null = null

export async function loadMe(force = false): Promise<Me> {
  if (session.me && !force) return session.me
  pending ??= (async () => {
    session.loading = true
    session.error = null
    try {
      // eigenes Signal: /api/me gehört nicht zur aktuellen Seite und wird beim Routenwechsel nicht abgebrochen
      const me = await endpoints.me(new AbortController().signal)
      session.me = me
      pickDefaultTenant()
      return me
    } catch (e) {
      session.error = userMessage(e)
      throw e
    } finally {
      session.loading = false
      pending = null
    }
  })()
  return pending
}

/** Vorauswahl: gespeichertes Fahrzeugbuch, sonst das einzige. */
export function pickDefaultTenant(): void {
  const list = tenants.value
  if (session.tenant && list.some((t) => t.slug === session.tenant)) return
  const pref = readPref()
  if (pref && list.some((t) => t.slug === pref)) session.tenant = pref
  else if (list.length === 1) session.tenant = list[0]!.slug
  else session.tenant = null
}

export function selectTenant(slug: string | null): boolean {
  if (slug !== null && !tenants.value.some((t) => t.slug === slug)) return false
  session.tenant = slug
  writePref(slug)
  return true
}
