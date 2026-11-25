<script setup lang="ts">
import { computed, ref } from 'vue'
import { useRoute } from 'vue-router'
import Field from '../../components/Field.vue'
import Icon from '../../components/Icon.vue'
import CategoryBadge from '../../components/CategoryBadge.vue'
import StatusBadge from '../../components/StatusBadge.vue'
import HistoryPanel from '../../components/HistoryPanel.vue'
import ConfirmDialog from '../../components/ConfirmDialog.vue'
import EmptyState from '../../components/EmptyState.vue'
import { useHistory, useStorno, useVehicle } from '../../composables'
import { byId } from '../../store/data'
import type { Trip, TripCategory } from '../../api/types'
import { km, month as monthLabel, monthOf, num, time, weekdayDate } from '../../lib/format'
import { CATEGORIES, CATEGORY_LABELS, SOURCE_LABELS, STATUS_LABELS, STATUSES } from '../../lib/labels'
import { isMaskedTrip, purposeText, routeText } from '../../lib/privacy'
import { needsReview, sortTrips, tripKm } from '../../lib/trips'

const route = useRoute()
const { trips, tenant, writable } = useVehicle()
const history = useHistory()
const storno = useStorno()

const q = ref('')
const month = ref(typeof route.query.monat === 'string' ? route.query.monat : '')
const category = ref<'' | TripCategory>('')
const status = ref(typeof route.query.status === 'string' ? route.query.status : '')
const showDeleted = ref(false)

const months = computed(() => [...new Set(trips.value.map((t) => monthOf(t.start_at)))].sort().reverse())
const lookup = (id: string) => byId('place', id)

function customerText(t: Trip): string | null {
  if (t.customer_name) return t.customer_name
  const c = byId('customer', t.customer_id)
  return c ? (c.ref ? `${c.name} (${c.ref})` : c.name) : null
}
function recordedBy(t: Trip): string {
  return t.driver_name || t.created_by || '–'
}

const rows = computed(() => {
  const s = q.value.trim().toLowerCase()
  return sortTrips(trips.value)
    .reverse()
    .filter((t) => showDeleted.value || !t.deleted)
    .filter((t) => !month.value || monthOf(t.start_at) === month.value)
    .filter((t) => !category.value || t.category === category.value)
    .filter((t) => !status.value || (status.value === 'offen' ? needsReview(t) : t.status === status.value))
    .filter((t) => {
      if (!s) return true
      const hay = [routeText(t, lookup).text, t.purpose, customerText(t), t.note, recordedBy(t)].filter(Boolean).join(' ').toLowerCase()
      return hay.includes(s)
    })
})

const sums = computed(() => {
  const by: Record<string, number> = {}
  let total = 0
  for (const t of rows.value) {
    if (t.deleted) continue
    const k = tripKm(t)
    by[t.category] = (by[t.category] ?? 0) + k
    total += k
  }
  return { by, total }
})

function stornoTrip(t: Trip) {
  storno.ask('trip', t, `${weekdayDate(t.start_at)} ${time(t.start_at)} · ${routeText(t, lookup).text}`)
}
</script>

<template>
  <section class="card card-flush" aria-labelledby="trips-h">
    <div class="card-header">
      <h2 id="trips-h">Fahrten</h2>
      <span class="muted small" aria-live="polite">{{ rows.length }} Fahrten · {{ km(sums.total, 0) }}</span>
    </div>
    <div class="toolbar mt-1 card-header" role="search">
      <Field v-slot="f" label="Suche" class="grow">
        <input :id="f.id" v-model="q" class="input" type="search" placeholder="Ort, Zweck oder Kunde suchen" />
      </Field>
      <Field v-slot="f" label="Monat">
        <select :id="f.id" v-model="month" class="select">
          <option value="">Alle Monate</option>
          <option v-for="m in months" :key="m" :value="m">{{ monthLabel(m) }}</option>
        </select>
      </Field>
      <Field v-slot="f" label="Kategorie">
        <select :id="f.id" v-model="category" class="select">
          <option value="">Alle</option>
          <option v-for="c in CATEGORIES" :key="c" :value="c">{{ CATEGORY_LABELS[c] }}</option>
        </select>
      </Field>
      <Field v-slot="f" label="Status">
        <select :id="f.id" v-model="status" class="select">
          <option value="">Alle</option>
          <option value="offen">Zu bestätigen</option>
          <option v-for="s in STATUSES" :key="s" :value="s">{{ STATUS_LABELS[s] }}</option>
        </select>
      </Field>
      <label class="check"><input v-model="showDeleted" type="checkbox" />Stornierte anzeigen</label>
    </div>
    <div v-if="sums.total" class="row card-header small">
      <span v-for="c in CATEGORIES.filter((c) => sums.by[c])" :key="c" class="row"><CategoryBadge :category="c" />{{ km(sums.by[c], 0) }}</span>
    </div>
    <EmptyState v-if="!rows.length" title="Keine Fahrten" icon="route"><p>Für diese Auswahl sind keine Fahrten erfasst.</p></EmptyState>
    <div v-else class="table-wrap">
      <table class="table">
        <caption class="sr-only">Fahrten, neueste zuerst</caption>
        <thead>
          <tr>
            <th scope="col">Datum</th>
            <th scope="col">Strecke</th>
            <th scope="col">Kategorie</th>
            <th scope="col">Zweck / Kunde</th>
            <th scope="col" class="num">km-Stand</th>
            <th scope="col" class="num">Distanz</th>
            <th scope="col">Status</th>
            <th scope="col">Erfasst von</th>
            <th scope="col"><span class="sr-only">Aktionen</span></th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="t in rows" :key="t.id" :class="{ 'is-deleted': t.deleted }">
            <td class="nowrap">
              {{ weekdayDate(t.start_at) }}
              <span class="cell-sub">{{ time(t.start_at) }}–{{ t.end_at ? time(t.end_at) : '?' }}</span>
            </td>
            <td class="strike-cell">
              <span v-if="routeText(t, lookup).masked" class="row"><Icon name="eyeOff" size="sm" />Privatfahrt</span>
              <span v-else>{{ routeText(t, lookup).text }}</span>
              <span v-if="t.private_mode" class="cell-sub">Privatmodus</span>
              <span v-else-if="t.source !== 'manual'" class="cell-sub">{{ SOURCE_LABELS[t.source] }}</span>
            </td>
            <td><CategoryBadge :category="t.category" /></td>
            <td>
              <span v-if="isMaskedTrip(t)" class="muted">Privatfahrt</span>
              <template v-else>
                {{ purposeText(t) }}
                <span v-if="customerText(t)" class="cell-sub">{{ customerText(t) }}</span>
              </template>
            </td>
            <td class="num">
              <span v-if="t.km_estimated" class="badge badge-warn" title="Kilometerstand aus GPS geschätzt, nicht abgelesen">ca.</span>
              {{ t.km_start !== null ? num(t.km_start) : '?' }}–{{ t.km_end !== null ? num(t.km_end) : '?' }}
            </td>
            <td class="num">{{ km(tripKm(t), 0) }}</td>
            <td>
              <StatusBadge :status="t.status" />
              <span v-if="t.deleted" class="badge badge-danger">storniert</span>
            </td>
            <td>{{ recordedBy(t) }}</td>
            <td class="actions">
              <button type="button" class="btn btn-ghost btn-icon btn-sm" :aria-label="`Verlauf der Fahrt vom ${weekdayDate(t.start_at)}`" @click="history.show('trip', t.id, 'Verlauf der Fahrt')"><Icon name="history" size="sm" /></button>
              <button v-if="writable && !t.deleted" type="button" class="btn btn-ghost btn-icon btn-sm" :aria-label="`Fahrt vom ${weekdayDate(t.start_at)} stornieren`" @click="stornoTrip(t)"><Icon name="ban" size="sm" /></button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </section>
  <p class="muted small mt-1">Fahrten werden in der App erfasst und bestätigt. Im Web: ansehen, Verlauf prüfen und stornieren. <span class="badge badge-warn">ca.</span> = geschätzter Kilometerstand.</p>

  <HistoryPanel :tenant="tenant" :entity="history.sel.value?.entity ?? null" :id="history.sel.value?.id ?? null" :title="history.sel.value?.title" @close="history.close" />
  <ConfirmDialog
    :open="storno.state.open"
    title="Fahrt stornieren"
    confirm-label="Stornieren"
    danger
    :reason="storno.state.reason"
    :busy="storno.state.busy"
    :error="storno.state.error"
    @close="storno.close"
    @confirm="storno.confirm"
  >
    <p><strong>{{ storno.state.label }}</strong></p>
    <p class="muted">Die Fahrt wird nicht gelöscht, sondern als storniert markiert und bleibt im Änderungsprotokoll sichtbar.</p>
  </ConfirmDialog>
</template>
