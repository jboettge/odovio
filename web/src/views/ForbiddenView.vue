<script setup lang="ts">
import { computed } from 'vue'
import { useRoute } from 'vue-router'
import PageHeader from '../components/PageHeader.vue'
import AlertBox from '../components/AlertBox.vue'
import { role } from '../store/session'
import { ROLE_LABELS } from '../lib/roles'

const route = useRoute()
const buch = computed(() => (typeof route.query.buch === 'string' ? route.query.buch : null))
</script>

<template>
  <PageHeader title="Kein Zugriff" />
  <AlertBox kind="warn" title="Diese Seite ist für deine Rolle nicht freigegeben">
    <p v-if="buch">Du hast keinen Zugriff auf das Fahrzeugbuch «{{ buch }}».</p>
    <p v-else>Deine Rolle in diesem Fahrzeugbuch: <strong>{{ role ? ROLE_LABELS[role] : 'keine' }}</strong>.</p>
    <p>Verwaltungsaufgaben (Mitglieder) erfordern die Rolle «Verwalten», Bearbeiten und Monatsabschluss die Rolle «Bearbeiten».</p>
  </AlertBox>
  <p class="mt-2"><RouterLink to="/uebersicht">Zur Übersicht</RouterLink> · <RouterLink :to="{ path: '/', query: { wechseln: '1' } }">Fahrzeugbuch wechseln</RouterLink></p>
</template>
