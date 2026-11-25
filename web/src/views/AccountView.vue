<script setup lang="ts">
import { useRouter } from 'vue-router'
import PageHeader from '../components/PageHeader.vue'
import RoleBadge from '../components/RoleBadge.vue'
import Icon from '../components/Icon.vue'
import { logout } from '../auth/oidc'
import { displayName, selectTenant, session, tenants } from '../store/session'
import { ROLE_DESCRIPTIONS } from '../lib/roles'
import { GLOSSARY } from '../lib/labels'

const router = useRouter()
function use(slug: string) {
  if (selectTenant(slug)) void router.push('/uebersicht')
}
</script>

<template>
  <PageHeader title="Konto" :subtitle="`Angemeldet als ${displayName}`">
    <button type="button" class="btn btn-primary" @click="logout()"><Icon name="logout" size="sm" />Abmelden</button>
  </PageHeader>
  <div class="grid grid-2">
    <section class="card" aria-labelledby="acc-books">
      <h2 id="acc-books" class="section-title">Fahrzeugbücher und Rollen</h2>
      <div class="table-wrap">
        <table class="table">
          <thead><tr><th scope="col">Fahrzeugbuch</th><th scope="col">Rolle</th><th scope="col"><span class="sr-only">Aktion</span></th></tr></thead>
          <tbody>
            <tr v-for="t in tenants" :key="t.slug">
              <td><strong>{{ t.name || t.slug }}</strong><span class="cell-sub">{{ ROLE_DESCRIPTIONS[t.role] }}</span></td>
              <td><RoleBadge :role="t.role" /></td>
              <td class="actions">
                <span v-if="t.slug === session.tenant" class="badge badge-ok">aktiv</span>
                <button v-else type="button" class="btn btn-sm" @click="use(t.slug)">Verwenden</button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <h2 class="section-title mt-3">Angaben</h2>
      <dl class="dl">
        <dt>Name</dt><dd>{{ displayName }}</dd>
        <dt>Benutzer-ID</dt><dd class="mono">{{ session.me?.sub }}</dd>
      </dl>
      <p class="muted small mt-2">Beim Abmelden wird auch die Keycloak-Sitzung beendet. Anmeldedaten liegen nur in dieser Browser-Sitzung (sessionStorage).</p>
    </section>
    <section class="card" aria-labelledby="acc-glossary">
      <h2 id="acc-glossary" class="section-title">Begriffe</h2>
      <dl class="stack">
        <div v-for="g in GLOSSARY" :key="g.term">
          <dt><strong>{{ g.term }}</strong></dt>
          <dd class="muted small">{{ g.text }}</dd>
        </div>
      </dl>
    </section>
  </div>
</template>
