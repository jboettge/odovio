<script setup lang="ts">
import { errorText } from '../store/toasts'
import { computed, onBeforeUnmount, ref, shallowRef, watch } from 'vue'
import PageHeader from '../components/PageHeader.vue'
import ActivityFeed from '../components/ActivityFeed.vue'
import AlertBox from '../components/AlertBox.vue'
import Loading from '../components/Loading.vue'
import Field from '../components/Field.vue'
import Icon from '../components/Icon.vue'
import Pager from '../components/Pager.vue'
import { useDebounced } from '../use/debounced'
import { usePager } from '../use/pager'
import { endpoints } from '../api/endpoints'
import type { ActivityItem } from '../api/types'
import { vehiclesByName } from '../store/data'
import { session } from '../store/session'
import { ACTION_LABELS, ENTITY_LABELS } from '../lib/labels'

const PAGE = 50
// shallowRef: geladene Einträge nicht tief reaktiv machen (nur ersetzt, nie verändert)
const items = shallowRef<ActivityItem[]>([])
const next = ref<number | null>(null)
const loading = ref(false)
const error = ref<string | null>(null)
const entity = ref('')
const action = ref('')
const vehicle = ref('')
const q = ref('')
const qDebounced = useDebounced(q)

/*
 * Nur die letzte Anfrage zählt: «Aktualisieren» oder ein Mandantenwechsel bricht ein laufendes «Ältere laden» ab
 * (sonst hängt eine alte Seite an die neue Liste oder überschreibt sie).
 */
let seq = 0
let ctrl: AbortController | null = null
onBeforeUnmount(() => ctrl?.abort())

async function fetchPage(reset: boolean) {
  const tenant = session.tenant
  if (!tenant) return
  if (!reset && loading.value) return
  ctrl?.abort()
  const my = ++seq
  const c = (ctrl = new AbortController())
  loading.value = true
  error.value = null
  try {
    const page = await endpoints.activity(tenant, PAGE, reset ? null : next.value, c.signal)
    if (my !== seq) return
    const before = reset ? 0 : items.value.length
    items.value = reset ? page.items : [...items.value, ...page.items]
    // nach «Ältere laden» zur Seite mit den ersten neuen Einträgen
    if (!reset && page.items.length && filtered.value.length > before) pager.page = Math.floor(before / pager.size) + 1
    next.value = page.next_before_seq ?? null
  } catch (e) {
    if (my === seq && !c.signal.aborted) error.value = errorText(e)
  } finally {
    if (my === seq) {
      loading.value = false
      ctrl = null
    }
  }
}

watch(
  () => session.tenant,
  () => {
    items.value = []
    next.value = null
    void fetchPage(true)
  },
  { immediate: true },
)

const vehicles = computed(() => vehiclesByName())
const filtered = computed(() => {
  const s = qDebounced.value.trim().toLowerCase()
  return items.value.filter(
    (i) =>
      (!entity.value || i.entity === entity.value) &&
      (!action.value || i.action === action.value) &&
      (!vehicle.value || i.vehicle_id === vehicle.value) &&
      (!s || `${i.summary} ${i.actor_name ?? ''}`.toLowerCase().includes(s)),
  )
})
const entities = computed(() => [...new Set(items.value.map((i) => i.entity))].sort())
// nachgeladene Einträge seitenweise anzeigen (DOM bleibt klein, auch nach vielen «Ältere laden»)
const pager = usePager(filtered, { size: 200, resetOn: [qDebounced, entity, action, vehicle] })
</script>

<template>
  <PageHeader title="Aktivität" subtitle="Alle Änderungen im Fahrzeugbuch, neueste zuerst. Ein Klick zeigt den Verlauf des Eintrags.">
    <button type="button" class="btn" :disabled="loading" @click="fetchPage(true)"><Icon name="refresh" size="sm" />Aktualisieren</button>
  </PageHeader>
  <div class="card">
    <div class="toolbar" role="search">
      <Field v-slot="f" label="Suche" class="grow"><input :id="f.id" v-model="q" class="input" type="search" placeholder="Text oder Person" /></Field>
      <Field v-slot="f" label="Objekt">
        <select :id="f.id" v-model="entity" class="select"><option value="">Alle</option><option v-for="e in entities" :key="e" :value="e">{{ ENTITY_LABELS[e] ?? e }}</option></select>
      </Field>
      <Field v-slot="f" label="Aktion">
        <select :id="f.id" v-model="action" class="select"><option value="">Alle</option><option v-for="(l, k) in ACTION_LABELS" :key="k" :value="k">{{ l }}</option></select>
      </Field>
      <Field v-slot="f" label="Fahrzeug">
        <select :id="f.id" v-model="vehicle" class="select"><option value="">Alle</option><option v-for="v in vehicles" :key="v.id" :value="v.id">{{ v.name }}</option></select>
      </Field>
    </div>
    <AlertBox v-if="error" kind="danger" live>{{ error }}</AlertBox>
    <p class="muted small" aria-live="polite">{{ filtered.length }} von {{ items.length }} geladenen Einträgen</p>
    <ActivityFeed :items="pager.items" :tenant="session.tenant ?? ''" group-by-day />
    <Pager v-model:page="pager.page" v-model:size="pager.size" :total="pager.total" label="Seiten der Aktivität" />
    <Loading v-if="loading" />
    <div v-else-if="next" class="row mt-2">
      <button type="button" class="btn" @click="fetchPage(false)">Ältere laden</button>
    </div>
    <p v-else-if="items.length" class="muted small mt-2">Ende des Protokolls erreicht.</p>
  </div>
</template>
