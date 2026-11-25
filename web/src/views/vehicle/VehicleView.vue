<script setup lang="ts">
import { computed } from 'vue'
import PageHeader from '../../components/PageHeader.vue'
import Loading from '../../components/Loading.vue'
import EmptyState from '../../components/EmptyState.vue'
import { useVehicle } from '../../composables'
import { dataState } from '../../store/data'
import { OWNERSHIP_LABELS, FUEL_TYPE_LABELS } from '../../lib/labels'

const { vid, vehicle, writable } = useVehicle()

const tabs = computed(() => [
  { to: `/fahrzeuge/${vid.value}`, label: 'Übersicht' },
  { to: `/fahrzeuge/${vid.value}/fahrten`, label: 'Fahrten' },
  { to: `/fahrzeuge/${vid.value}/tanken`, label: 'Tankvorgänge' },
  { to: `/fahrzeuge/${vid.value}/wartungen`, label: 'Wartungen' },
  { to: `/fahrzeuge/${vid.value}/kilometerstaende`, label: 'Kilometerstände' },
  { to: `/fahrzeuge/${vid.value}/berichte`, label: 'Berichte' },
  ...(writable.value ? [{ to: `/fahrzeuge/${vid.value}/monatsabschluss`, label: 'Monatsabschluss' }] : []),
])
const subtitle = computed(() => {
  const v = vehicle.value
  if (!v) return ''
  return [[v.make, v.model].filter(Boolean).join(' '), FUEL_TYPE_LABELS[v.fuel_type] ?? v.fuel_type, OWNERSHIP_LABELS[v.ownership ?? 'private']]
    .filter(Boolean)
    .join(' · ')
})
</script>

<template>
  <Loading v-if="!dataState.loaded" text="Fahrzeug wird geladen …" />
  <EmptyState v-else-if="!vehicle" title="Fahrzeug nicht gefunden" icon="car">
    <RouterLink to="/uebersicht">Zur Übersicht</RouterLink>
  </EmptyState>
  <template v-else>
    <PageHeader :title="vehicle.name" :subtitle="subtitle" eyebrow="Fahrzeug">
      <template #meta>
        <div class="row mt-1">
          <span v-if="vehicle.plate" class="plate">{{ vehicle.plate }}</span>
          <span v-if="vehicle.deleted" class="badge badge-danger">storniert</span>
        </div>
      </template>
    </PageHeader>
    <nav class="tabs" aria-label="Bereiche des Fahrzeugs">
      <RouterLink v-for="t in tabs" :key="t.to" :to="t.to" exact-active-class="router-link-exact-active">{{ t.label }}</RouterLink>
    </nav>
    <RouterView :key="vid" />
  </template>
</template>
