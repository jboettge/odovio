<script setup lang="ts">
import { errorText } from '../../store/toasts'
import { computed, ref, watch } from 'vue'
import Kpi from '../../components/Kpi.vue'
import Icon from '../../components/Icon.vue'
import Loading from '../../components/Loading.vue'
import AlertBox from '../../components/AlertBox.vue'
import LineChart from '../../components/LineChart.vue'
import BarChart from '../../components/BarChart.vue'
import { useVehicle } from '../../composables'
import { childrenOf, dataState, stats, tick } from '../../store/data'
import type { Stats } from '../../api/types'
import { chf, consumption, currentMonth, date, km, liters, monthShort, num, previousMonth } from '../../lib/format'
import { FUEL_TYPE_LABELS, METHOD_LABELS, OWNERSHIP_LABELS } from '../../lib/labels'
import { analytics } from '../../lib/analyticsClient'
import type { HealthResult } from '../../lib/slim'
import { useAsync } from '../../use/async'

const { vid, vehicle, fuel, maintenance, tenant } = useVehicle()
const s = ref<Stats | null>(null)
const error = ref<string | null>(null)

watch(
  () => [vid.value, dataState.loadedAt] as const,
  async () => {
    error.value = null
    try {
      s.value = await stats(tenant.value, vid.value)
    } catch (e) {
      error.value = errorText(e)
    }
  },
  { immediate: true },
)

const NO_HEALTH: HealthResult = { open: 0, gaps: 0, gapKm: 0, estimated: 0 }
// Kilometerkette/offene Fahrten über alle Fahrten des Fahrzeugs im Web Worker
const healthRes = useAsync(
  () => ({ vid: vid.value, data: tick('trip', 'trip_period') }),
  async (a) => (await analytics().health([a.vid]))[a.vid] ?? NO_HEALTH,
  NO_HEALTH,
)
const health = computed(() => healthRes.data.value)
const healthPending = healthRes.pending

const points = computed(() =>
  (s.value?.points ?? []).map((p) => ({
    label: date(p.date),
    value: p.consumption,
    detail: `${km(p.distance)} · ${liters(p.liters)} · ${chf(p.cost)}`,
  })),
)

/** Kosten je Monat (12 Monate): Treibstoff + Wartung (Rechnungsbetrag, sonst Materialsumme). */
const monthly = computed(() => {
  const months: string[] = []
  let m = currentMonth()
  for (let i = 0; i < 12; i++) {
    months.unshift(m)
    m = previousMonth(m)
  }
  const first = months[0]!
  const fuelBy: Record<string, number> = {}
  const maintBy: Record<string, number> = {}
  for (const f of fuel.value) if (!f.deleted && f.date.slice(0, 7) >= first) fuelBy[f.date.slice(0, 7)] = (fuelBy[f.date.slice(0, 7)] ?? 0) + f.price_total
  for (const w of maintenance.value) {
    if (w.deleted || w.date.slice(0, 7) < first) continue
    // Materialsumme aus dem Index je Wartung (statt Filter über alle Materialposten)
    const cost = w.cost ?? childrenOf('maintenance_material', 'maintenance_id', w.id).reduce((a, x) => a + (x.deleted ? 0 : x.quantity * (x.unit_price ?? 0)), 0)
    maintBy[w.date.slice(0, 7)] = (maintBy[w.date.slice(0, 7)] ?? 0) + cost
  }
  return months.map((mm) => ({ label: monthShort(mm), values: [fuelBy[mm] ?? 0, maintBy[mm] ?? 0] }))
})
const activeMaintenance = computed(() => maintenance.value.filter((m) => !m.deleted).length)
const monthlyTotal = computed(() => monthly.value.reduce((a, d) => a + d.values[0]! + d.values[1]!, 0))
</script>

<template>
  <AlertBox v-if="error" kind="danger" live>{{ error }}</AlertBox>
  <Loading v-else-if="!s" text="Kennzahlen werden geladen …" />
  <div v-else class="stack">
    <div class="grid grid-kpi">
      <Kpi label="Aktueller Kilometerstand" :value="km(s.current_km)" :sub="`${km(s.driven_km)} seit Erfassung`" />
      <Kpi label="Ø Verbrauch" :value="consumption(s.avg_consumption)" :sub="s.avg_liters_per_km !== null ? `${num(s.avg_liters_per_km, 3)} l pro km` : 'mind. zwei Volltankungen nötig'" />
      <Kpi label="Kosten pro km" :value="s.avg_cost_per_km !== null ? chf(s.avg_cost_per_km, 3) : '–'" sub="Treibstoff" />
      <Kpi label="Treibstoff total" :value="chf(s.total_fuel_cost)" :sub="liters(s.total_liters, 1)" />
      <Kpi label="Wartung total" :value="chf(s.total_maintenance_cost)" :sub="`${activeMaintenance} Wartungen`" />
    </div>

    <div class="grid grid-2">
      <section class="card" aria-labelledby="ov-book">
        <h2 id="ov-book" class="section-title">Fahrtenbuch</h2>
        <ul class="callout-list">
          <li v-if="health.open">
            <Icon name="check" class="warn" /><RouterLink :to="{ path: `/fahrzeuge/${vid}/fahrten`, query: { status: 'offen' } }" class="warn">{{ health.open }} Fahrt{{ health.open === 1 ? '' : 'en' }} bestätigen</RouterLink>
          </li>
          <li v-if="health.gaps">
            <Icon name="alert" class="danger" /><span class="danger">Lücke{{ health.gaps > 1 ? 'n' : '' }} von {{ km(health.gapKm) }} in der Kilometerkette</span>
          </li>
          <li v-if="health.estimated"><Icon name="gauge" class="warn" /><span class="warn">{{ health.estimated }} {{ health.estimated === 1 ? 'Kilometerstand' : 'Kilometerstände' }} geschätzt (ca.)</span></li>
          <li v-if="!healthPending && !health.open && !health.gaps && !health.estimated"><Icon name="checkCircle" /><span class="muted">Alle Fahrten bestätigt, Kilometerkette lückenlos</span></li>
        </ul>
        <h2 class="section-title mt-3">Fälligkeiten</h2>
        <p v-if="!s.due.length" class="muted">Keine Wartung fällig.</p>
        <ul v-else class="callout-list">
          <li v-for="d in s.due" :key="d.maintenance_id">
            <Icon name="wrench" :class="d.overdue ? 'danger' : ''" />
            <span :class="d.overdue ? 'danger' : ''">{{ d.title }}</span>
            <span class="muted small">{{ [d.next_due_km !== null ? `bei ${km(d.next_due_km)}` : '', d.next_due_date ? `am ${date(d.next_due_date)}` : ''].filter(Boolean).join(' / ') }}</span>
            <span :class="['badge', d.overdue ? 'badge-danger' : 'badge-warn']">{{ d.overdue ? 'überfällig' : 'fällig' }}</span>
          </li>
        </ul>
      </section>

      <section class="card" aria-labelledby="ov-data">
        <h2 id="ov-data" class="section-title">Fahrzeug</h2>
        <dl v-if="vehicle" class="dl">
          <dt>Kennzeichen</dt><dd>{{ vehicle.plate || '–' }}</dd>
          <dt>Marke / Modell</dt><dd>{{ [vehicle.make, vehicle.model].filter(Boolean).join(' ') || '–' }}</dd>
          <dt>VIN</dt><dd><span v-if="vehicle.vin" class="mono" data-testid="vehicle-vin">{{ vehicle.vin }}</span><template v-else>–</template></dd>
          <dt>Treibstoff</dt><dd>{{ FUEL_TYPE_LABELS[vehicle.fuel_type] ?? vehicle.fuel_type }}</dd>
          <dt>Start-km</dt><dd>{{ km(vehicle.initial_km) }}</dd>
          <dt>Halter</dt><dd>{{ vehicle.ownership ? OWNERSHIP_LABELS[vehicle.ownership] : 'nicht erfasst (Privatfahrzeug angenommen)' }}</dd>
          <dt v-if="vehicle.ownership === 'business'">Privatanteil</dt><dd v-if="vehicle.ownership === 'business'">{{ vehicle.private_use_method ? METHOD_LABELS[vehicle.private_use_method] : 'nicht erfasst' }}</dd>
          <dt>Kaufpreis</dt><dd>{{ chf(vehicle.purchase_price, 0) }}</dd>
          <dt>Fixkosten/Jahr</dt><dd>{{ chf(vehicle.annual_fixed_costs, 0) }}</dd>
        </dl>
      </section>
    </div>

    <section class="card" aria-labelledby="ov-cons">
      <div class="card-header">
        <h2 id="ov-cons">Verbrauch</h2>
        <span class="muted small">l/100 km je Volltankung</span>
      </div>
      <p v-if="points.length < 1" class="muted">Für den Verbrauch braucht es mindestens zwei Volltankungen.</p>
      <LineChart
        v-else
        title="Verbrauch in Litern pro 100 km je Volltankung mit Durchschnittslinie"
        series-label="Verbrauch"
        :points="points"
        :ref-value="s.avg_consumption"
        ref-label="Ø"
        unit="l"
        :format="(v: number) => `${num(v, 2)} l/100 km`"
      />
    </section>

    <section class="card" aria-labelledby="ov-cost">
      <div class="card-header">
        <h2 id="ov-cost">Kosten je Monat</h2>
        <span class="muted small">letzte 12 Monate · {{ chf(monthlyTotal, 0) }}</span>
      </div>
      <BarChart title="Kosten je Monat, gestapelt nach Treibstoff und Wartung" :series="['Treibstoff', 'Wartung']" :data="monthly" :format="(v: number) => chf(v, 0)" />
    </section>
  </div>
</template>
