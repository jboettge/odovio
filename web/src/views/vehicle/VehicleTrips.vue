<script setup lang="ts">
// Fahrten eines Fahrzeugs: Filter/Suche/Summen im Web Worker (100k+ Fahrten), Tabelle virtuell gescrollt
// (nur sichtbare Zeilen im DOM), Suche entprellt.
import { computed, ref } from 'vue'
import { useRoute } from 'vue-router'
import Field from '../../components/Field.vue'
import Icon from '../../components/Icon.vue'
import Loading from '../../components/Loading.vue'
import CategoryBadge from '../../components/CategoryBadge.vue'
import StatusBadge from '../../components/StatusBadge.vue'
import HistoryPanel from '../../components/HistoryPanel.vue'
import ConfirmDialog from '../../components/ConfirmDialog.vue'
import EmptyState from '../../components/EmptyState.vue'
import VPad from '../../components/VPad.vue'
import { useHistory, useStorno, useVehicle } from '../../composables'
import { byId, tick } from '../../store/data'
import type { Trip, TripCategory } from '../../api/types'
import { km, month as monthLabel, num, time, weekdayDate } from '../../lib/format'
import { CATEGORIES, CATEGORY_LABELS, SOURCE_LABELS, STATUS_LABELS, STATUSES } from '../../lib/labels'
import { isMaskedTrip, purposeText, routeText } from '../../lib/privacy'
import { tripKm } from '../../lib/trips'
import { analytics } from '../../lib/analyticsClient'
import type { TripQueryResult } from '../../lib/slim'
import { useAsync } from '../../use/async'
import { useDebounced } from '../../use/debounced'
import { useVirtualRows } from '../../use/virtualRows'

const route = useRoute()
const { vid, tenant, writable } = useVehicle()
const history = useHistory()
const storno = useStorno()

const q = ref('')
const qDebounced = useDebounced(q)
const month = ref(typeof route.query.monat === 'string' ? route.query.monat : '')
const category = ref<'' | TripCategory>('')
const status = ref(typeof route.query.status === 'string' ? route.query.status : '')
const showDeleted = ref(false)

const EMPTY: TripQueryResult = { ids: [], sums: { by: {}, total: 0 }, months: [] }
const result = useAsync(
  () => ({
    query: { vid: vid.value, month: month.value, category: category.value, status: status.value, q: qDebounced.value, showDeleted: showDeleted.value },
    // neu rechnen, wenn sich Fahrten, Orte oder Kunden geändert haben
    data: tick('trip', 'place', 'customer'),
  }),
  (a) => analytics().query(a.query),
  EMPTY,
)
const ready = computed(() => result.data.value !== EMPTY)
const months = computed(() => result.data.value.months)
const sums = computed(() => result.data.value.sums)
const rows = computed(() => {
  const out: Trip[] = []
  for (const id of result.data.value.ids) {
    const t = byId('trip', id)
    if (t) out.push(t)
  }
  return out
})

const lookup = (id: string) => byId('place', id)
function customerText(t: Trip): string | null {
  if (t.customer_name) return t.customer_name
  const c = byId('customer', t.customer_id)
  return c ? (c.ref ? `${c.name} (${c.ref})` : c.name) : null
}
function recordedBy(t: Trip): string {
  return t.driver_name || t.created_by || '–'
}

// virtuelles Scrollen: nur sichtbare Zeilen, Anzeige-Werte je sichtbarer Zeile einmal berechnet
const { el: tableEl, items: visible, start: vStart, padTop, padBottom } = useVirtualRows(rows)
const lookupTick = computed(() => tick('place', 'customer'))
const visibleRows = computed(() =>
  visible.value.map((t) => ({ t, route: routeText(t, lookup), customer: customerText(t), masked: isMaskedTrip(t), km: tripKm(t), by: recordedBy(t) })),
)

function stornoTrip(t: Trip) {
  storno.ask('trip', t, `${weekdayDate(t.start_at)} ${time(t.start_at)} · ${routeText(t, lookup).text}`)
}
</script>

<template>
  <section class="card card-flush" aria-labelledby="trips-h">
    <div class="card-header">
      <h2 id="trips-h">Fahrten</h2>
      <span class="muted small" aria-live="polite">{{ num(rows.length) }} Fahrten · {{ km(sums.total, 0) }}</span>
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
    <Loading v-if="!ready" text="Fahrten werden ausgewertet …" />
    <EmptyState v-else-if="!rows.length" title="Keine Fahrten" icon="route"><p>Für diese Auswahl sind keine Fahrten erfasst.</p></EmptyState>
    <div v-else ref="tableEl" class="table-wrap vtable">
      <table class="table" :aria-rowcount="rows.length + 1">
        <caption class="sr-only">Fahrten, neueste zuerst</caption>
        <thead>
          <tr aria-rowindex="1">
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
          <VPad :height="padTop" :cols="9" />
          <tr
            v-for="(r, i) in visibleRows"
            :key="r.t.id"
            v-memo="[r.t, writable, vStart + i, lookupTick]"
            :aria-rowindex="vStart + i + 2"
            :class="{ 'is-deleted': r.t.deleted }"
          >
            <td class="nowrap">
              {{ weekdayDate(r.t.start_at) }}
              <span class="cell-sub">{{ time(r.t.start_at) }}–{{ r.t.end_at ? time(r.t.end_at) : '?' }}</span>
            </td>
            <td class="strike-cell">
              <span v-if="r.route.masked" class="row"><Icon name="eyeOff" size="sm" />Privatfahrt</span>
              <span v-else>{{ r.route.text }}</span>
              <span v-if="r.t.private_mode" class="cell-sub">Privatmodus</span>
              <span v-else-if="r.t.source !== 'manual'" class="cell-sub">{{ SOURCE_LABELS[r.t.source] }}</span>
            </td>
            <td><CategoryBadge :category="r.t.category" /></td>
            <td>
              <span v-if="r.masked" class="muted">Privatfahrt</span>
              <template v-else>
                {{ purposeText(r.t) }}
                <span v-if="r.customer" class="cell-sub">{{ r.customer }}</span>
              </template>
            </td>
            <td class="num">
              <span v-if="r.t.km_estimated" class="badge badge-warn" title="Kilometerstand aus GPS geschätzt, nicht abgelesen">ca.</span>
              {{ r.t.km_start !== null ? num(r.t.km_start) : '?' }}–{{ r.t.km_end !== null ? num(r.t.km_end) : '?' }}
            </td>
            <td class="num">{{ km(r.km, 0) }}</td>
            <td>
              <StatusBadge :status="r.t.status" />
              <span v-if="r.t.deleted" class="badge badge-danger">storniert</span>
            </td>
            <td>{{ r.by }}</td>
            <td class="actions">
              <button type="button" class="btn btn-ghost btn-icon btn-sm" :aria-label="`Verlauf der Fahrt vom ${weekdayDate(r.t.start_at)}`" @click="history.show('trip', r.t.id, 'Verlauf der Fahrt')"><Icon name="history" size="sm" /></button>
              <button v-if="writable && !r.t.deleted" type="button" class="btn btn-ghost btn-icon btn-sm" :aria-label="`Fahrt vom ${weekdayDate(r.t.start_at)} stornieren`" @click="stornoTrip(r.t)"><Icon name="ban" size="sm" /></button>
            </td>
          </tr>
          <VPad :height="padBottom" :cols="9" />
        </tbody>
      </table>
    </div>
  </section>
  <p class="muted small mt-1">Fahrten werden in der App erfasst und bestätigt. Im Web: ansehen, Verlauf prüfen und stornieren. Tanken, Wartungen und Kilometerstände lassen sich auch im Web erfassen. <span class="badge badge-warn">ca.</span> = geschätzter Kilometerstand.</p>

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
