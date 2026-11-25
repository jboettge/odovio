<script setup lang="ts">
import { computed } from 'vue'
import PageHeader from '../../components/PageHeader.vue'
import Loading from '../../components/Loading.vue'
import AlertBox from '../../components/AlertBox.vue'
import { dataState } from '../../store/data'
import { role } from '../../store/session'
import { canWrite } from '../../lib/roles'

const tabs = [
  { to: '/stammdaten/fahrzeuge', label: 'Fahrzeuge' },
  { to: '/stammdaten/orte', label: 'Orte' },
  { to: '/stammdaten/kunden', label: 'Kunden' },
  { to: '/stammdaten/regeln', label: 'Regeln' },
  { to: '/stammdaten/steuerparameter', label: 'Steuerparameter' },
  { to: '/stammdaten/material', label: 'Materialstamm' },
]
const readonly = computed(() => !canWrite(role.value))
</script>

<template>
  <PageHeader title="Stammdaten" subtitle="Grundlagen für Fahrtenbuch, Vorschläge und Auswertungen." />
  <AlertBox v-if="readonly" kind="info" class="mt-0">Nur Lesezugriff – Stammdaten können mit der Rolle «Bearbeiten» geändert werden.</AlertBox>
  <nav class="tabs mt-2" aria-label="Stammdaten">
    <RouterLink v-for="t in tabs" :key="t.to" :to="t.to">{{ t.label }}</RouterLink>
  </nav>
  <Loading v-if="!dataState.loaded" />
  <RouterView v-else />
</template>
