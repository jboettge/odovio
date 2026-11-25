// OIDC (Keycloak) mit oidc-client-ts: Authorization Code + PKCE (S256), Token nur im sessionStorage,
// automatische Erneuerung per Refresh-Token. Kein offline_access, kein Session-Monitor-iframe (CSP).
import { UserManager, WebStorageStateStore, type User } from 'oidc-client-ts'
import { reactive } from 'vue'
import type { AuthConfig } from '../api/types'
import type { TokenProvider } from '../api/client'
import { LOGOUT_REASON_KEY } from './idle'

export const WEB_SCOPES = 'openid profile'
export const CALLBACK_PATH = '/auth/callback'

export const authState = reactive({
  ready: false,
  user: null as User | null,
  config: null as AuthConfig | null,
  error: null as string | null,
})

let manager: UserManager | null = null

export async function fetchAuthConfig(fetchImpl: typeof fetch = fetch): Promise<AuthConfig> {
  const res = await fetchImpl('/auth/config', { headers: { Accept: 'application/json' }, cache: 'no-store' })
  if (!res.ok) throw new Error(`Anmeldekonfiguration nicht verfügbar (${res.status})`)
  const cfg = (await res.json()) as AuthConfig
  if (!cfg.issuer || !(cfg.web_client_id || cfg.client_id)) throw new Error('Anmeldekonfiguration unvollständig')
  return cfg
}

/** Nur relative Pfade derselben App zulassen (kein Open Redirect). */
export function safeReturnTo(v: unknown): string {
  if (typeof v !== 'string' || !v.startsWith('/') || v.startsWith('//') || v.startsWith('/\\')) return '/'
  if (v.startsWith(CALLBACK_PATH)) return '/'
  return v
}

export function createManager(cfg: AuthConfig, origin = window.location.origin): UserManager {
  const store = new WebStorageStateStore({ store: window.sessionStorage })
  return new UserManager({
    authority: cfg.issuer,
    client_id: cfg.web_client_id || cfg.client_id,
    redirect_uri: `${origin}${CALLBACK_PATH}`,
    post_logout_redirect_uri: `${origin}/`,
    response_type: 'code',
    scope: WEB_SCOPES,
    userStore: store,
    stateStore: store,
    automaticSilentRenew: true,
    accessTokenExpiringNotificationTimeInSeconds: 60,
    monitorSession: false,
    loadUserInfo: false,
    revokeTokenTypes: ['refresh_token'],
    filterProtocolClaims: true,
  })
}

export async function initAuth(cfg: AuthConfig): Promise<void> {
  authState.config = cfg
  manager = createManager(cfg)
  manager.events.addUserLoaded((u) => {
    authState.user = u
  })
  manager.events.addUserUnloaded(() => {
    authState.user = null
  })
  manager.events.addSilentRenewError(() => {
    // Refresh fehlgeschlagen (z. B. SSO-Session abgelaufen): beim nächsten 401 neu anmelden
  })
  const u = await manager.getUser()
  authState.user = u && !u.expired ? u : u?.refresh_token ? u : null
  if (!authState.user && window.location.pathname !== CALLBACK_PATH) purgeOidcState()
  authState.ready = true
}

function mgr(): UserManager {
  if (!manager) throw new Error('Anmeldung nicht initialisiert')
  return manager
}

export function isAuthenticated(): boolean {
  return authState.user !== null
}

export async function login(returnTo = '/'): Promise<void> {
  await mgr().signinRedirect({ state: { returnTo: safeReturnTo(returnTo) } })
}

/** Callback verarbeiten → Rücksprungziel. */
export async function completeLogin(): Promise<string> {
  const u = await mgr().signinRedirectCallback()
  authState.user = u
  const state = u.state as { returnTo?: unknown } | undefined
  return safeReturnTo(state?.returnTo)
}

/** Liegengebliebene Anmelde-/Abmelde-Zustände (z. B. nach end_session) entfernen. */
function purgeOidcState(): void {
  try {
    for (const k of Object.keys(window.sessionStorage)) if (k.startsWith('oidc.')) window.sessionStorage.removeItem(k)
  } catch {
    /* Speicher gesperrt */
  }
}

function clearSession(reason?: string): void {
  try {
    window.sessionStorage.clear()
    if (reason) window.sessionStorage.setItem(LOGOUT_REASON_KEY, reason)
  } catch {
    /* Speicher gesperrt */
  }
}

/** Abmelden: Refresh-Token widerrufen, sessionStorage leeren, Keycloak end_session (id_token_hint). */
export async function logout(reason?: 'idle'): Promise<void> {
  const m = mgr()
  const u = await m.getUser()
  try {
    if (u?.refresh_token) await m.revokeTokens(['refresh_token'])
  } catch {
    /* Widerruf optional */
  }
  await m.removeUser()
  clearSession(reason)
  authState.user = null
  await m.signoutRedirect({ id_token_hint: u?.id_token, post_logout_redirect_uri: `${window.location.origin}/` })
}

let redirecting = false

export const tokenProvider: TokenProvider = {
  async getToken() {
    if (!manager) return null
    const u = await manager.getUser()
    if (!u) return null
    if (u.expired && u.refresh_token) return this.refresh()
    return u.access_token
  },
  async refresh() {
    if (!manager) return null
    try {
      const u = await manager.signinSilent()
      return u?.access_token ?? null
    } catch {
      return null
    }
  },
  onUnauthorized() {
    if (redirecting || !manager) return
    redirecting = true
    const here = `${window.location.pathname}${window.location.search}`
    void manager.removeUser().finally(() => login(here))
  },
}
