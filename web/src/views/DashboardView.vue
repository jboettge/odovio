<script setup lang="ts">
import { errorText } from '../store/toasts'
import { computed, reactive, ref, watch } from 'vue'
import PageHeader from '../components/PageHeader.vue'
import Icon from '../components/Icon.vue'
import Loading from '../components/Loading.vue'
import EmptyState from '../components/EmptyState.vue'
import AlertBox from '../components/AlertBox.vue'
import ActivityFeed from '../components/ActivityFeed.vue'
import { dataState, stats, tick, vehiclesByName } from '../store/data'
import { role, session } from '../store/session'
import { endpoints } from '../api/endpoints'
import type { ActivityItem, Stats } from '../api/types'
import { ApiError } from '../api/client'
import { chf, date, km, num } from '../lib/format'
import { FUEL_TYPE_LABELS } from '../lib/labels'
import { analytics } from '../lib/analyticsClient'
import type { HealthResult } from '../lib/slim'
import { useAsync } from '../use/async'
import { canWrite } from '../lib/roles'

const vehicles = computed(() => vehiclesByName())
const statMap = reactive<Record<string, Stats | 'error'>>({})

watch(
  () => [session.tenant, dataState.loadedAt, vehicles.value.map((v) => v.id).join()] as const,
  async ([tenant]) => {
    if (!tenant) return
    await Promise.all(
      vehicles.value.map(async (v) => {
        try {
          statMap[v.id] = await stats(tenant, v.id)
        } catch {
          statMap[v.id] = 'error'
        }
      }),
    )
  },
  { immediate: true },
)

// Kilometerkette/offene Bestätigungen über alle Fahrten: im Web Worker (Hauptthread bleibt frei)
const healthRes = useAsync(
  () => ({ vids: vehicles.value.map((v) => v.id), data: tick('trip', 'trip_period'), loaded: dataState.loaded }),
  (a) => (a.loaded ? analytics().health(a.vids) : Promise.resolve({} as Record<string, HealthResult>)),
  {} as Record<string, HealthResult>,
)
const health = computed(() => healthRes.data.value)

function st(id: string): Stats | null {
  const s = statMap[id]
  return s && s !== 'error' ? s : null
}

const activity = ref<ActivityItem[]>([])
const activityError = ref<string | null>(null)
watch(
  () => [session.tenant, dataState.loadedAt] as const,
  async ([tenant]) => {
    if (!tenant) return
    try {
      activity.value = (await endpoints.activity(tenant, 8)).items
      activityError.value = null
    } catch (e) {
      activityError.value = e instanceof ApiError && e.status === 404 ? 'Aktivitätsfeed ist auf diesem Server nicht verfügbar.' : errorText(e)
    }
  },
  { immediate: true },
)

const totals = computed(() => {
  let open = 0
  let gaps = 0
  let overdue = 0
  for (const v of vehicles.value) {
    open += health.value[v.id]?.open ?? 0
    gaps += health.value[v.id]?.gaps ?? 0
    overdue += st(v.id)?.due.filter((d) => d.overdue).length ?? 0
  }
  return { open, gaps, overdue }
})
</script>

<template>
  <PageHeader title="Übersicht" :subtitle="`Fahrzeugbuch ${session.tenant ?? ''}`">
    <RouterLink v-if="canWrite(role)" to="/stammdaten/fahrzeuge" class="btn"><Icon name="plus" size="sm" />Fahrzeug erfassen</RouterLink>
  </PageHeader>

  <Loading v-if="!dataState.loaded && dataState.loading" text="Fahrzeugbuch wird geladen …" />
  <template v-else-if="dataState.loaded">
    <section v-if="totals.open || totals.gaps || totals.overdue" class="mt-0" aria-label="Handlungsbedarf">
      <div class="grid grid-3">
        <AlertBox v-if="totals.open" kind="warn" :title="`${totals.open} Fahrt${totals.open === 1 ? '' : 'en'} zu bestätigen`">
          <p class="small">In der App oder hier prüfen – erst bestätigte Fahrten zählen im Fahrtenbuch.</p>
        </AlertBox>
        <AlertBox v-if="totals.gaps" kind="danger" :title="`${totals.gaps} Lücke${totals.gaps === 1 ? '' : 'n'} in der Kilometerkette`">
          <p class="small">Fehlende Kilometer als Fahrt erfassen oder korrigieren.</p>
        </AlertBox>
        <AlertBox v-if="totals.overdue" kind="danger" :title="`${totals.overdue} Wartung${totals.overdue === 1 ? '' : 'en'} überfällig`">
          <p class="small">Details auf der Fahrzeugseite unter «Wartungen».</p>
        </AlertBox>
      </div>
    </section>

    <h2 class="section-title mt-3">Fahrzeuge</h2>
    <EmptyState v-if="!vehicles.length" title="Noch keine Fahrzeuge" icon="car">
      <p>Fahrzeuge werden in der App oder unter Stammdaten erfasst.</p>
    </EmptyState>
    <div v-else class="grid grid-tiles">
      <RouterLink v-for="v in vehicles" :key="v.id" :to="`/fahrzeuge/${v.id}`" class="card vehicle-tile" :aria-label="`${v.name} öffnen`">
        <div class="vehicle-tile-head">
          <span class="vehicle-icon"><Icon name="car" size="lg" /></span>
          <div>
            <div class="vehicle-tile-title">{{ v.name }}</div>
            <div class="row small muted">
              <span v-if="v.plate" class="plate">{{ v.plate }}</span>
              <span>{{ [v.make, v.model].filter(Boolean).join(' ') || FUEL_TYPE_LABELS[v.fuel_type] }}</span>
            </div>
          </div>
        </div>
        <dl class="facts">
          <div><dt>Kilometerstand</dt><dd>{{ st(v.id) ? km(st(v.id)!.current_km) : '…' }}</dd></div>
          <div><dt>Ø l/100 km</dt><dd>{{ st(v.id) ? num(st(v.id)!.avg_consumption, 2) : '…' }}</dd></div>
          <div><dt>Kosten total</dt><dd>{{ st(v.id) ? chf(st(v.id)!.total_fuel_cost + st(v.id)!.total_maintenance_cost, 0) : '…' }}</dd></div>
        </dl>
        <ul class="callout-list">
          <li v-if="health[v.id]?.open"><Icon name="check" class="warn" /><span class="warn">{{ health[v.id]!.open }} Fahrt{{ health[v.id]!.open === 1 ? '' : 'en' }} bestätigen</span></li>
          <li v-if="health[v.id]?.gaps"><Icon name="alert" class="danger" /><span class="danger">Lücke von {{ km(health[v.id]!.gapKm) }} in der Kilometerkette</span></li>
          <li v-for="d in st(v.id)?.due.slice(0, 2) ?? []" :key="d.maintenance_id">
            <Icon name="wrench" :class="d.overdue ? 'danger' : ''" />
            <span :class="d.overdue ? 'danger' : ''">{{ d.title }}: {{ d.overdue ? 'überfällig' : 'fällig' }}
              <span class="muted small">{{ [d.next_due_km !== null ? km(d.next_due_km) : '', d.next_due_date ? date(d.next_due_date) : ''].filter(Boolean).join(' / ') }}</span></span>
          </li>
          <li v-if="health[v.id] && !health[v.id]!.open && !health[v.id]!.gaps && !st(v.id)?.due.length"><Icon name="checkCircle" /><span class="muted">Alles erledigt</span></li>
        </ul>
      </RouterLink>
    </div>

    <section class="card mt-3" aria-labelledby="dash-activity">
      <div class="card-header">
        <h2 id="dash-activity">Letzte Aktivität</h2>
        <div class="actions"><RouterLink to="/aktivitaet" class="btn btn-sm btn-ghost">Alle anzeigen<Icon name="chevronRight" size="sm" /></RouterLink></div>
      </div>
      <p v-if="activityError" class="muted">{{ activityError }}</p>
      <ActivityFeed v-else :items="activity" :tenant="session.tenant ?? ''" compact />
    </section>
  </template>
</template>
