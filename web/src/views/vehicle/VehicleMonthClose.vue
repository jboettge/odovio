<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import Field from '../../components/Field.vue'
import Icon from '../../components/Icon.vue'
import Modal from '../../components/Modal.vue'
import Loading from '../../components/Loading.vue'
import AlertBox from '../../components/AlertBox.vue'
import { useVehicle } from '../../composables'
import { endpoints } from '../../api/endpoints'
import { ApiError } from '../../api/client'
import type { CloseConflictDetail, TripCheck, TripMismatch } from '../../api/types'
import { byId, dataState, refresh, tick } from '../../store/data'
import { notify, errorText } from '../../store/toasts'
import { currentMonth, date, km, month as monthLabel, num, previousMonth, time, weekdayDate, byCode } from '../../lib/format'
import { routeText } from '../../lib/privacy'
import { MIN_REASON } from '../../lib/trips'
import { analytics } from '../../lib/analyticsClient'
import { useAsync } from '../../use/async'
import type { Trip } from '../../api/types'

const { vid, periods, tenant } = useVehicle()
const cur = currentMonth()
const months = computed(() => {
  const out: string[] = []
  let m = cur
  for (let i = 0; i < 13; i++) {
    out.push(m)
    m = previousMonth(m)
  }
  return out
})
const month = ref(previousMonth(cur))
const check = ref<TripCheck | null>(null)
const loading = ref(false)
const error = ref<string | null>(null)

async function loadCheck() {
  loading.value = true
  error.value = null
  try {
    check.value = await endpoints.tripCheck(tenant.value, vid.value, month.value)
  } catch (e) {
    check.value = null
    error.value = errorText(e)
  } finally {
    loading.value = false
  }
}
watch([month, vid, () => dataState.loadedAt], loadCheck, { immediate: true })

const lookup = (id: string) => byId('place', id)
function tripLabel(id: string): string {
  const t = byId('trip', id)
  return t ? `${weekdayDate(t.start_at)} ${time(t.start_at)} · ${routeText(t, lookup).text}` : 'Fahrt'
}
// Monatsübersicht (Anzahl, offene Fahrten) im Web Worker über alle Fahrten des Fahrzeugs
const summary = useAsync(
  () => ({ vid: vid.value, month: month.value, data: tick('trip') }),
  (a) => analytics().monthSummary(a.vid, a.month),
  { trips: 0, open: [] as string[] },
)
const monthTripCount = computed(() => summary.data.value.trips)
const openTrips = computed(() => summary.data.value.open.map((id) => byId('trip', id)).filter((t): t is Trip => Boolean(t)))
const closedMonths = computed(() => new Set(periods.value.map((p) => p.month)))
const periodsSorted = computed(() => [...periods.value].sort((a, b) => byCode(b.month, a.month)))

function mm(pred: (m: TripMismatch) => boolean) {
  return (check.value?.mismatches ?? []).filter(pred)
}
const purposeMissing = computed(() => mm((m) => m.reason.startsWith('Zweck fehlt')))
const kmOrEndMissing = computed(() => mm((m) => m.reason.startsWith('km-Stand Beginn') || m.reason.startsWith('Endzeit')))
const estimated = computed(() => mm((m) => m.reason.startsWith('km-Stand geschätzt')))
const hints = computed(() => mm((m) => !m.blocking))
const blocking = computed(() => mm((m) => m.blocking))
const period = computed(() => periods.value.find((p) => p.month === month.value))
const running = computed(() => month.value >= cur)

const canClose = computed(() => check.value && !check.value.closed && !running.value && check.value.unconfirmed === 0)
const needsForce = computed(() => Boolean(check.value && (check.value.gaps.length || blocking.value.length)))

// ---------- Abschluss ----------
const dlg = ref(false)
const force = ref(false)
const reason = ref('')
const busy = ref(false)
const closeError = ref<string | null>(null)
const conflict = ref<CloseConflictDetail | null>(null)
const reasonError = computed(() => (force.value && reason.value.trim().length < MIN_REASON ? `Begründung mit mindestens ${MIN_REASON} Zeichen erforderlich` : undefined))

function openDialog() {
  force.value = false
  reason.value = ''
  closeError.value = null
  conflict.value = null
  dlg.value = true
}

async function doClose() {
  if (needsForce.value && !force.value) {
    closeError.value = 'Es gibt Lücken oder unvollständige Fahrten. Zum Abschliessen «Trotzdem abschliessen» wählen und begründen.'
    return
  }
  if (reasonError.value) return
  busy.value = true
  closeError.value = null
  conflict.value = null
  try {
    const res = await endpoints.closeMonth(tenant.value, vid.value, month.value, force.value, force.value ? reason.value.trim() : null)
    notify(`${monthLabel(month.value)} abgeschlossen – ${res.locked_trips} Fahrten gesperrt`)
    dlg.value = false
    await refresh()
  } catch (e) {
    if (e instanceof ApiError && e.status === 409) {
      conflict.value = e.detailObject as CloseConflictDetail
      closeError.value = e.message
    } else if (e instanceof ApiError && e.status === 422) {
      closeError.value = e.message
    } else closeError.value = errorText(e)
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div class="grid grid-2">
    <section class="card" aria-labelledby="mc-h">
      <div class="card-header">
        <h2 id="mc-h">Monatsabschluss</h2>
        <div class="actions">
          <label for="mc-month" class="sr-only">Monat</label>
          <select id="mc-month" v-model="month" class="select">
            <option v-for="m in months" :key="m" :value="m">{{ monthLabel(m) }}{{ m >= cur ? ' (läuft)' : '' }}{{ closedMonths.has(m) ? ' – abgeschlossen' : '' }}</option>
          </select>
        </div>
      </div>
      <Loading v-if="loading" text="Prüfung läuft …" />
      <AlertBox v-else-if="error" kind="danger" live>{{ error }}</AlertBox>
      <template v-else-if="check">
        <p class="row"><strong>{{ check.trips }} Fahrten</strong><span class="muted">im {{ monthLabel(check.month) }}</span>
          <span v-if="check.closed" class="badge badge-info"><Icon name="lock" size="sm" />abgeschlossen</span>
          <span v-else-if="running" class="badge badge-outline">läuft</span>
        </p>
        <h3 class="section-title mt-2">Checkliste</h3>
        <ul class="checklist">
          <li>
            <Icon :name="check.unconfirmed ? 'xCircle' : 'checkCircle'" :class="check.unconfirmed ? 'check-fail' : 'check-ok'" :label="check.unconfirmed ? 'nicht erfüllt' : 'erfüllt'" />
            <div>
              <strong>Alle Fahrten bestätigt</strong>
              <div v-if="check.unconfirmed" class="muted small">{{ check.unconfirmed }} offen – in der App bestätigen</div>
              <ul v-if="openTrips.length"><li v-for="t in openTrips" :key="t.id">{{ tripLabel(t.id) }}</li></ul>
            </div>
          </li>
          <li>
            <Icon :name="purposeMissing.length ? 'xCircle' : 'checkCircle'" :class="purposeMissing.length ? 'check-fail' : 'check-ok'" :label="purposeMissing.length ? 'nicht erfüllt' : 'erfüllt'" />
            <div><strong>Geschäftliche Fahrten mit Zweck</strong>
              <ul v-if="purposeMissing.length"><li v-for="m in purposeMissing" :key="m.trip_id + m.reason">{{ tripLabel(m.trip_id) }}</li></ul>
            </div>
          </li>
          <li>
            <Icon :name="kmOrEndMissing.length ? 'xCircle' : 'checkCircle'" :class="kmOrEndMissing.length ? 'check-fail' : 'check-ok'" :label="kmOrEndMissing.length ? 'nicht erfüllt' : 'erfüllt'" />
            <div><strong>Kilometerstand und Endzeit erfasst</strong>
              <ul v-if="kmOrEndMissing.length"><li v-for="m in kmOrEndMissing" :key="m.trip_id + m.reason">{{ tripLabel(m.trip_id) }}: {{ m.reason }}</li></ul>
            </div>
          </li>
          <li>
            <Icon :name="estimated.length ? 'xCircle' : 'checkCircle'" :class="estimated.length ? 'check-fail' : 'check-ok'" :label="estimated.length ? 'nicht erfüllt' : 'erfüllt'" />
            <div><strong>Kilometerstände abgelesen (nicht geschätzt)</strong>
              <div v-if="estimated.length" class="muted small">{{ estimated.length }} geschätzt</div>
              <ul v-if="estimated.length"><li v-for="m in estimated" :key="m.trip_id">{{ tripLabel(m.trip_id) }}</li></ul>
            </div>
          </li>
          <li>
            <Icon :name="check.gaps.length ? 'xCircle' : 'checkCircle'" :class="check.gaps.length ? 'check-fail' : 'check-ok'" :label="check.gaps.length ? 'nicht erfüllt' : 'erfüllt'" />
            <div><strong>Keine Lücke in der Kilometerkette</strong>
              <div v-if="check.gaps.length" class="muted small">{{ check.gaps.length }} Lücke(n) · {{ km(check.gaps.reduce((a, g) => a + Math.abs(g.km), 0)) }}</div>
              <ul v-if="check.gaps.length"><li v-for="g in check.gaps" :key="g.after_trip_id">{{ num(g.km_from) }} → {{ num(g.km_to) }} ({{ g.km > 0 ? `${num(g.km)} km fehlen` : `${num(-g.km)} km Überschneidung` }})</li></ul>
            </div>
          </li>
          <li>
            <Icon
              :name="check.odometer_check.ok === null ? 'help' : check.odometer_check.ok ? 'checkCircle' : 'alert'"
              :class="check.odometer_check.ok === null ? 'check-na' : check.odometer_check.ok ? 'check-ok' : 'check-warn'"
              :label="check.odometer_check.ok === null ? 'nicht prüfbar' : check.odometer_check.ok ? 'erfüllt' : 'Abweichung'"
            />
            <div><strong>Abgleich mit Tankvorgängen/Kilometerständen</strong>
              <div class="muted small">
                <template v-if="check.odometer_check.ok === null">{{ check.odometer_check.note }}</template>
                <template v-else>Fahrten {{ km(check.odometer_check.trip_km, 1) }} · Tacho {{ km(check.odometer_check.odometer_km) }} · Differenz {{ km(check.odometer_check.diff_km, 1) }}</template>
              </div>
            </div>
          </li>
        </ul>
        <AlertBox v-if="hints.length" kind="info" title="Hinweise (blockieren nicht)" class="mt-2">
          <ul><li v-for="h in hints" :key="h.trip_id + h.reason">{{ tripLabel(h.trip_id) }}: {{ h.reason }}</li></ul>
        </AlertBox>
        <div class="row mt-2">
          <button type="button" class="btn btn-primary" :disabled="!canClose" @click="openDialog"><Icon name="lock" size="sm" />Monat abschliessen …</button>
          <span v-if="running" class="muted small">Nur abgelaufene Monate können abgeschlossen werden.</span>
          <span v-else-if="check.closed" class="muted small">Dieser Monat ist bereits abgeschlossen.</span>
          <span v-else-if="check.unconfirmed" class="muted small">Zuerst alle Fahrten bestätigen.</span>
        </div>
      </template>
    </section>

    <section class="card" aria-labelledby="mc-closed">
      <h2 id="mc-closed" class="section-title">Abgeschlossene Monate</h2>
      <p v-if="!periods.length" class="muted">Noch kein Monat abgeschlossen.</p>
      <div v-else class="table-wrap">
        <table class="table">
          <thead><tr><th scope="col">Monat</th><th scope="col" class="num">Fahrten</th><th scope="col" class="num">Geschäftl.</th><th scope="col" class="num">Privat</th><th scope="col">Abgeschlossen</th><th scope="col" class="num"><abbr title="Korrekturen nach dem Abschluss">Korr.</abbr></th></tr></thead>
          <tbody>
            <tr v-for="p in periodsSorted" :key="p.id">
              <td class="nowrap"><button type="button" class="linkish" @click="month = p.month">{{ monthLabel(p.month) }}</button></td>
              <td class="num">{{ p.trips_count }}</td>
              <td class="num">{{ km(p.business_km + p.field_km, 0) }}</td>
              <td class="num">{{ km(p.private_km, 0) }}</td>
              <td class="nowrap">{{ date(p.closed_at) }}<span class="cell-sub">{{ p.closed_by || '–' }}</span></td>
              <td class="num"><span :class="['badge', p.corrections ? 'badge-warn' : 'badge-outline']">{{ p.corrections }}</span></td>
            </tr>
          </tbody>
        </table>
      </div>
      <p v-if="period?.note" class="muted small mt-1">Begründung Abschluss {{ monthLabel(period.month) }}: {{ period.note }}</p>
      <p class="muted small mt-2">Der Abschluss sperrt alle Fahrten des Monats, friert Orts- und Kundennamen ein und setzt einen signierten Anker. Korrekturen danach nur per Storno mit Begründung.</p>
    </section>
  </div>

  <Modal :open="dlg" :title="`${monthLabel(month)} abschliessen`" @close="dlg = false">
    <form id="close-form" class="stack" @submit.prevent="doClose">
      <p>{{ monthTripCount }} Fahrten werden <strong>unveränderlich gesperrt</strong>. Danach sind Korrekturen nur noch per Storno mit Begründung möglich.</p>
      <template v-if="needsForce">
        <AlertBox kind="warn" title="Abweichungen vorhanden">
          <p>{{ check?.gaps.length ?? 0 }} Lücke(n), {{ blocking.length }} unvollständige Angabe(n).</p>
        </AlertBox>
        <label class="check"><input v-model="force" type="checkbox" />Trotzdem abschliessen (erzwingen)</label>
        <Field v-if="force" v-slot="f" label="Begründung" required :error="reason && reasonError ? reasonError : undefined" hint="Wird im Änderungsprotokoll gespeichert.">
          <textarea :id="f.id" v-model="reason" class="textarea" maxlength="500" :aria-invalid="f.invalid" :aria-describedby="f.describedby"></textarea>
        </Field>
      </template>
      <AlertBox v-if="closeError" kind="danger" live :title="conflict ? 'Abschluss nicht möglich' : undefined">
        <p>{{ closeError }}</p>
        <ul v-if="conflict?.gaps?.length"><li v-for="g in conflict.gaps" :key="g.after_trip_id">Lücke {{ num(g.km_from) }} → {{ num(g.km_to) }} ({{ num(g.km) }} km)</li></ul>
        <ul v-if="conflict?.mismatches?.length"><li v-for="m in conflict.mismatches" :key="m.trip_id + m.reason">{{ tripLabel(m.trip_id) }}: {{ m.reason }}</li></ul>
        <ul v-if="conflict?.trips?.length"><li v-for="t in conflict.trips" :key="t.id">{{ tripLabel(t.id) }} ({{ t.status }})</li></ul>
      </AlertBox>
    </form>
    <template #footer>
      <button type="button" class="btn" @click="dlg = false">Abbrechen</button>
      <button type="submit" form="close-form" class="btn btn-primary" :disabled="busy || (force && Boolean(reasonError))">{{ busy ? 'Wird abgeschlossen …' : 'Verbindlich abschliessen' }}</button>
    </template>
  </Modal>
</template>
