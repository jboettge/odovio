<script setup lang="ts">
import { errorText } from '../store/toasts'
import { computed, onMounted, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import Icon from '../components/Icon.vue'
import RoleBadge from '../components/RoleBadge.vue'
import AlertBox from '../components/AlertBox.vue'
import Loading from '../components/Loading.vue'
import { authState, login, logout, safeReturnTo } from '../auth/oidc'
import { IDLE_TIMEOUT_MIN, LOGOUT_REASON_KEY } from '../auth/idle'
import { displayName, loadMe, selectTenant, session, tenants } from '../store/session'
import { ROLE_DESCRIPTIONS } from '../lib/roles'

const route = useRoute()
const router = useRouter()
const busy = ref(false)
const idleLogout = ref(false)
try {
  idleLogout.value = window.sessionStorage.getItem(LOGOUT_REASON_KEY) === 'idle'
  window.sessionStorage.removeItem(LOGOUT_REASON_KEY)
} catch {
  /* Speicher gesperrt */
}
const returnTo = computed(() => {
  const r = safeReturnTo(route.query.returnTo)
  return r === '/' ? '/uebersicht' : r
})

async function start() {
  busy.value = true
  try {
    await login(returnTo.value)
  } catch (e) {
    authState.error = errorText(e)
    busy.value = false
  }
}

function choose(slug: string) {
  if (selectTenant(slug)) void router.replace(returnTo.value)
}

onMounted(async () => {
  if (!authState.user) return
  try {
    await loadMe()
  } catch {
    return
  }
  // Nur ein Fahrzeugbuch oder bereits gewählt und kein Wechselwunsch → direkt weiter
  if (route.query.wechseln === undefined && tenants.value.length === 1) choose(tenants.value[0]!.slug)
  else if (route.query.wechseln === undefined && route.query.returnTo && session.tenant) void router.replace(returnTo.value)
})
</script>

<template>
  <main id="main" class="start" tabindex="-1">
    <div class="card start-card">
      <div class="start-logo"><Icon name="car" size="lg" /></div>
      <h1>Fahrzeugbuch</h1>
      <p class="muted">Fahrten, Tankvorgänge, Wartungen und Berichte – im Browser.</p>

      <AlertBox v-if="idleLogout && !authState.user" kind="info" title="Automatisch abgemeldet" class="mt-2">
        <p>Nach {{ IDLE_TIMEOUT_MIN }} Minuten ohne Aktivität wurdest du zum Schutz deiner Daten abgemeldet.</p>
      </AlertBox>
      <AlertBox v-if="authState.error" kind="danger" title="Anmeldung nicht möglich" live>
        <p>{{ authState.error }}</p>
      </AlertBox>

      <template v-else-if="!authState.user">
        <button type="button" class="btn btn-primary btn-lg mt-2" :disabled="busy" @click="start">
          {{ busy ? 'Weiterleitung …' : 'Mit Keycloak anmelden' }}
        </button>
        <p class="muted small mt-2">Die Anmeldung erfolgt über Keycloak (Single Sign-on). Es werden keine Passwörter im Browser gespeichert.</p>
      </template>

      <template v-else>
        <Loading v-if="session.loading" text="Konto wird geladen …" />
        <AlertBox v-else-if="session.error" kind="danger" title="Konto konnte nicht geladen werden" live>
          <p>{{ session.error }}</p>
          <button type="button" class="btn btn-sm" @click="loadMe(true)">Erneut versuchen</button>
        </AlertBox>
        <template v-else-if="session.me">
          <p class="mt-2">Angemeldet als <strong>{{ displayName }}</strong>.</p>
          <AlertBox v-if="!tenants.length" kind="warn" title="Kein Fahrzeugbuch zugewiesen">
            <p>Bitte wende dich an die Verwaltung deines Fahrzeugbuchs.</p>
          </AlertBox>
          <template v-else>
            <h2 class="mt-2">Fahrzeugbuch wählen</h2>
            <ul class="tenant-list">
              <li v-for="t in tenants" :key="t.slug">
                <button type="button" class="tenant-btn" :aria-current="t.slug === session.tenant ? 'true' : undefined" @click="choose(t.slug)">
                  <Icon name="database" />
                  <strong>{{ t.name || t.slug }}<span class="cell-sub">{{ ROLE_DESCRIPTIONS[t.role] }}</span></strong>
                  <RoleBadge :role="t.role" />
                  <Icon name="chevronRight" />
                </button>
              </li>
            </ul>
          </template>
        </template>
        <button type="button" class="btn btn-ghost mt-2" @click="logout()"><Icon name="logout" size="sm" />Abmelden</button>
      </template>
    </div>
  </main>
</template>
