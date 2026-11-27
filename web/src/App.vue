<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import Icon from './components/Icon.vue'
import RoleBadge from './components/RoleBadge.vue'
import Toasts from './components/Toasts.vue'
import AlertBox from './components/AlertBox.vue'
import { authState, logout } from './auth/oidc'
import { watchIdle, type IdleWatch } from './auth/idle'
import { currentTenant, displayName, role, selectTenant, session, tenants } from './store/session'
import { dataState, load, reset, vehiclesByName } from './store/data'
import { visibleNav, type NavItem } from './lib/roles'
import { ROLE_LABELS } from './lib/roles'

const route = useRoute()
const router = useRouter()

const bare = computed(() => route.name === 'start' || route.name === 'callback' || !authState.user || !session.me)

const mainNav: NavItem[] = [
  { to: '/uebersicht', label: 'Übersicht', icon: 'grid', minRole: 'read' },
  { to: '/aktivitaet', label: 'Aktivität', icon: 'activity', minRole: 'read' },
  { to: '/integritaet', label: 'Integrität', icon: 'shield', minRole: 'read' },
  { to: '/stammdaten', label: 'Stammdaten', icon: 'database', minRole: 'read' },
]
const adminNav: NavItem[] = [{ to: '/verwaltung/mitglieder', label: 'Mitglieder', icon: 'users', minRole: 'admin' }]

const nav = computed(() => visibleNav(mainNav, role.value))
const admin = computed(() => visibleNav(adminNav, role.value))
const vehicles = computed(() => vehiclesByName())

watch(
  () => session.tenant,
  (t) => {
    if (t) load(t).catch(() => undefined)
    else reset(null)
  },
  { immediate: true },
)

/** Abmelden: laufende Ladevorgänge abbrechen und Fachdaten aus dem Speicher entfernen, dann Keycloak-Logout. */
function signOut(reason?: 'idle') {
  reset(null)
  void logout(reason)
}

// Abmeldung nach Inaktivität
let idle: IdleWatch | null = null
watch(
  () => authState.user !== null,
  (loggedIn) => {
    idle?.stop()
    idle = loggedIn ? watchIdle(() => signOut('idle')) : null
    if (!loggedIn) reset(null)
  },
  { immediate: true },
)
onBeforeUnmount(() => idle?.stop())

/*
 * Fahrzeugbuch-Wechsler: Auswahl mit Maus/Touch (oder im aufgeklappten Menü mit Enter) wechselt direkt.
 * Pfeiltasten im zugeklappten Select (Chromium/Firefox unter Windows/Linux lösen dabei «change» aus) wählen nur vor;
 * gewechselt wird erst mit Enter oder «Wechseln», Escape verwirft die Vorauswahl.
 */
const tenantDraft = ref(session.tenant ?? '')
watch(
  () => session.tenant,
  (t) => (tenantDraft.value = t ?? ''),
)
const tenantPending = computed(() => tenantDraft.value !== '' && tenantDraft.value !== (session.tenant ?? ''))
let keyChange = false
const STEP_KEYS = new Set(['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Home', 'End', 'PageUp', 'PageDown'])

function switchTenant() {
  const slug = tenantDraft.value
  if (!slug || slug === session.tenant) return
  if (selectTenant(slug)) void router.push('/uebersicht')
}
function onTenantKeydown(e: KeyboardEvent) {
  if (e.key === 'Enter') {
    e.preventDefault()
    switchTenant()
  } else if (e.key === 'Escape' && tenantPending.value) {
    e.preventDefault()
    tenantDraft.value = session.tenant ?? ''
  } else {
    // Buchstaben springen ebenfalls zu Einträgen; Alt+Pfeil öffnet nur das Menü
    keyChange = !e.altKey && !e.metaKey && (STEP_KEYS.has(e.key) || (e.key.length === 1 && e.key !== ' '))
  }
}
function onTenantChange(e: Event) {
  tenantDraft.value = (e.target as HTMLSelectElement).value
  const fromKeys = keyChange
  keyChange = false
  if (!fromKeys) switchTenant()
}

function retry() {
  if (session.tenant) load(session.tenant, { force: true }).catch(() => undefined)
}
</script>

<template>
  <a class="skip-link" href="#main">Zum Inhalt springen</a>
  <div v-if="bare" class="shell--bare">
    <RouterView />
  </div>
  <div v-else class="shell">
    <RouterLink to="/uebersicht" class="brand" aria-label="Fahrzeugbuch – Übersicht">
      <span class="brand-logo"><Icon name="car" /></span>Fahrzeugbuch
    </RouterLink>
    <header class="topbar">
      <div v-if="tenants.length > 1" class="row">
        <label for="tenant-select" class="muted small">Fahrzeugbuch</label>
        <select id="tenant-select" class="select" :value="tenantDraft" aria-describedby="tenant-hint" @change="onTenantChange" @keydown="onTenantKeydown" @pointerdown="keyChange = false">
          <option v-if="!session.tenant" value="" disabled>Bitte wählen</option>
          <option v-for="t in tenants" :key="t.slug" :value="t.slug">{{ t.name || t.slug }} ({{ ROLE_LABELS[t.role] }})</option>
        </select>
        <span id="tenant-hint" class="sr-only">Mit Enter wechseln</span>
        <button v-if="tenantPending" type="button" class="btn btn-primary btn-sm" @click="switchTenant">Wechseln</button>
      </div>
      <div v-else-if="currentTenant" class="row">
        <span class="muted small">Fahrzeugbuch</span><strong>{{ currentTenant.name || currentTenant.slug }}</strong>
      </div>
      <RoleBadge v-if="role" :role="role" />
      <span class="topbar-spacer"></span>
      <RouterLink to="/konto" class="topbar-user"><Icon name="user" />{{ displayName }}</RouterLink>
      <button type="button" class="btn btn-sm" @click="signOut()"><Icon name="logout" size="sm" />Abmelden</button>
    </header>
    <nav class="sidenav" aria-label="Hauptnavigation">
      <ul>
        <li v-for="n in nav.slice(0, 1)" :key="n.to">
          <RouterLink :to="n.to"><Icon :name="n.icon" />{{ n.label }}</RouterLink>
        </li>
      </ul>
      <template v-if="vehicles.length && session.tenant">
        <div class="sidenav-section" id="nav-vehicles">Fahrzeuge</div>
        <ul aria-labelledby="nav-vehicles">
          <li v-for="v in vehicles" :key="v.id">
            <RouterLink :to="`/fahrzeuge/${v.id}`" class="vehicle-link"><Icon name="car" />{{ v.name }}</RouterLink>
          </li>
        </ul>
      </template>
      <div class="sidenav-section" id="nav-book">Fahrzeugbuch</div>
      <ul aria-labelledby="nav-book">
        <li v-for="n in nav.slice(1)" :key="n.to">
          <RouterLink :to="n.to"><Icon :name="n.icon" />{{ n.label }}</RouterLink>
        </li>
      </ul>
      <template v-if="admin.length">
        <div class="sidenav-section" id="nav-admin">Verwaltung</div>
        <ul aria-labelledby="nav-admin">
          <li v-for="n in admin" :key="n.to">
            <RouterLink :to="n.to"><Icon :name="n.icon" />{{ n.label }}</RouterLink>
          </li>
        </ul>
      </template>
      <div class="sidenav-section" id="nav-account">Konto</div>
      <ul aria-labelledby="nav-account">
        <li><RouterLink to="/konto"><Icon name="user" />Konto</RouterLink></li>
      </ul>
    </nav>
    <main id="main" class="main" tabindex="-1">
      <div class="container">
        <AlertBox v-if="dataState.error && session.tenant" kind="danger" title="Daten konnten nicht geladen werden" live class="mt-0">
          <p>{{ dataState.error }}</p>
          <button type="button" class="btn btn-sm" @click="retry">Erneut versuchen</button>
        </AlertBox>
        <RouterView />
      </div>
    </main>
  </div>
  <Toasts />
</template>
