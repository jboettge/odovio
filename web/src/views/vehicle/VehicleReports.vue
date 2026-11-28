<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import Field from '../../components/Field.vue'
import Icon from '../../components/Icon.vue'
import Kpi from '../../components/Kpi.vue'
import Meter from '../../components/Meter.vue'
import Loading from '../../components/Loading.vue'
import AlertBox from '../../components/AlertBox.vue'
import CategoryBadge from '../../components/CategoryBadge.vue'
import { useVehicle } from '../../composables'
import { endpoints } from '../../api/endpoints'
import type { BlobResult } from '../../api/client'
import type { TripCategory, YearReport } from '../../api/types'
import { chf, currentMonth, isoDate, km, month as monthLabel, pct, previousMonth } from '../../lib/format'
import { saveBlob } from '../../lib/download'
import { notify, errorText } from '../../store/toasts'
import { CATEGORY_LABELS, scopeLabel } from '../../lib/labels'
import { useAsync } from '../../use/async'

const { vid, vehicle, tenant } = useVehicle()
const today = new Date()
const yearStart = `${today.getFullYear()}-01-01`

const rFrom = ref(yearStart)
const rTo = ref(isoDate(today))
const lbMode = ref<'month' | 'range'>('month')
const lbMonth = ref(previousMonth(currentMonth()))
const lbFrom = ref(yearStart)
const lbTo = ref(isoDate(today))
const csvFrom = ref(yearStart)
const csvTo = ref(isoDate(today))
const busy = ref<string | null>(null)
const errors = ref<Record<string, string>>({})

const months = computed(() => {
  const out: string[] = []
  let m = currentMonth()
  for (let i = 0; i < 24; i++) {
    out.push(m)
    m = previousMonth(m)
  }
  return out
})

function days(a: string, b: string): number {
  return Math.round((new Date(b).getTime() - new Date(a).getTime()) / 86_400_000)
}
/** Zeitraum prüfen; der Fehler gehört zum Feld, das zu korrigieren ist («Von» fehlt → Von, sonst Bis). */
function rangeError(a: string, b: string, max?: number): { field: 'from' | 'to'; text: string } | null {
  if (!a) return { field: 'from', text: 'Datum «Von» angeben' }
  if (!b) return { field: 'to', text: 'Datum «Bis» angeben' }
  if (a > b) return { field: 'to', text: '«Bis» liegt vor «Von»' }
  if (max && days(a, b) >= max) return { field: 'to', text: `Zeitraum höchstens ${max} Tage` }
  return null
}
/** Feldfehler (für Field/aria-describedby) bzw. allgemeiner Fehler des Downloads */
const fieldError = (key: string, field: 'from' | 'to') => (errors.value[`${key}.${field}`] || undefined)
// Feldfehler verschwinden, sobald der Zeitraum geändert wird
const clearOn = (key: string, refs: (typeof rFrom)[]) =>
  watch(refs, () => {
    if (errors.value[`${key}.from`] || errors.value[`${key}.to`]) errors.value = { ...errors.value, [`${key}.from`]: '', [`${key}.to`]: '' }
  })
clearOn('report', [rFrom, rTo])
clearOn('logbook', [lbFrom, lbTo])
clearOn('csv', [csvFrom, csvTo])

async function download(key: string, fn: () => Promise<BlobResult>, fallback: string, check?: { field: 'from' | 'to'; text: string } | null) {
  errors.value = { ...errors.value, [key]: '', [`${key}.from`]: '', [`${key}.to`]: '' }
  if (check) {
    errors.value = { ...errors.value, [`${key}.${check.field}`]: check.text }
    return
  }
  busy.value = key
  try {
    saveBlob(await fn(), fallback)
    notify('Download gestartet')
  } catch (e) {
    errors.value = { ...errors.value, [key]: errorText(e) }
  } finally {
    busy.value = null
  }
}

const reportPdf = () => download('report', () => endpoints.reportPdf(tenant.value, vid.value, rFrom.value, rTo.value), 'Fahrzeugbuch.pdf', rangeError(rFrom.value, rTo.value))
const logbookPdf = () =>
  download(
    'logbook',
    () => endpoints.logbookPdf(tenant.value, vid.value, lbMode.value === 'month' ? { month: lbMonth.value } : { from: lbFrom.value, to: lbTo.value }),
    'Fahrtenbuch.pdf',
    lbMode.value === 'range' ? rangeError(lbFrom.value, lbTo.value, 366) : null,
  )
const tripsCsv = () => download('csv', () => endpoints.tripsCsv(tenant.value, vid.value, csvFrom.value, csvTo.value), 'Fahrten.csv', rangeError(csvFrom.value, csvTo.value, 366))

// ---------- Jahresbericht ----------
const years = computed(() => Array.from({ length: 6 }, (_, i) => today.getFullYear() - i))
const year = ref(today.getFullYear())
// Jahresbericht vom Server: beim schnellen Jahres-/Fahrzeugwechsel zählt nur die letzte Antwort
const reportRes = useAsync(
  () => ({ tenant: tenant.value, vid: vid.value, year: year.value }),
  (a, signal): Promise<YearReport | null> => endpoints.yearReport(a.tenant, a.vid, a.year, signal),
  null as YearReport | null,
  { resetOnError: true },
)
const report = reportRes.data
const reportError = reportRes.error
const reportLoading = reportRes.pending
const yearPdf = () => download('year', () => endpoints.yearReportPdf(tenant.value, vid.value, year.value), 'Jahresbericht.pdf')
const KM_CATS: TripCategory[] = ['business', 'field', 'commute', 'private', 'unknown']
const items = computed(() => Object.entries(report.value?.items ?? {}))
</script>

<template>
  <div class="grid grid-3">
    <section class="card" aria-labelledby="rep-veh">
      <h2 id="rep-veh" class="section-title">Fahrzeugbericht (PDF)</h2>
      <p class="small muted">Tankvorgänge, Verbrauch, Wartungen und Kosten im Zeitraum – mit signiertem Anker.</p>
      <div class="form-grid date-range mt-1">
        <Field v-slot="f" label="Von" :error="fieldError('report', 'from')"><input :id="f.id" v-model="rFrom" type="date" class="input" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
        <Field v-slot="f" label="Bis" :error="fieldError('report', 'to')"><input :id="f.id" v-model="rTo" type="date" class="input" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
      </div>
      <p v-if="errors.report" class="error small mt-1" role="alert">{{ errors.report }}</p>
      <button type="button" class="btn btn-primary mt-2" :disabled="busy === 'report'" @click="reportPdf"><Icon name="download" size="sm" />{{ busy === 'report' ? 'Wird erstellt …' : 'PDF herunterladen' }}</button>
    </section>

    <section class="card" aria-labelledby="rep-log">
      <h2 id="rep-log" class="section-title">Fahrtenbuch (PDF)</h2>
      <p class="small muted">Alle Fahrten mit Kategorie und Zweck. Privatfahrten ohne Orte für die Leserolle.</p>
      <fieldset class="fieldset mt-1">
        <legend class="sr-only">Zeitraum</legend>
        <div class="row">
          <label class="check"><input v-model="lbMode" type="radio" value="month" />Monat</label>
          <label class="check"><input v-model="lbMode" type="radio" value="range" />Zeitraum (max. 366 Tage)</label>
        </div>
        <Field v-if="lbMode === 'month'" v-slot="f" label="Monat" class="mt-1">
          <select :id="f.id" v-model="lbMonth" class="select"><option v-for="m in months" :key="m" :value="m">{{ monthLabel(m) }}</option></select>
        </Field>
        <div v-else class="form-grid date-range mt-1">
          <Field v-slot="f" label="Von" :error="fieldError('logbook', 'from')"><input :id="f.id" v-model="lbFrom" type="date" class="input" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
          <Field v-slot="f" label="Bis" :error="fieldError('logbook', 'to')"><input :id="f.id" v-model="lbTo" type="date" class="input" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
        </div>
      </fieldset>
      <p v-if="errors.logbook" class="error small mt-1" role="alert">{{ errors.logbook }}</p>
      <button type="button" class="btn btn-primary mt-2" :disabled="busy === 'logbook'" @click="logbookPdf"><Icon name="download" size="sm" />{{ busy === 'logbook' ? 'Wird erstellt …' : 'PDF herunterladen' }}</button>
    </section>

    <section class="card" aria-labelledby="rep-csv">
      <h2 id="rep-csv" class="section-title">Fahrten (CSV)</h2>
      <p class="small muted">Für Tabellenkalkulation/Treuhand. Zeitraum höchstens 366 Tage.</p>
      <div class="form-grid date-range mt-1">
        <Field v-slot="f" label="Von" :error="fieldError('csv', 'from')"><input :id="f.id" v-model="csvFrom" type="date" class="input" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
        <Field v-slot="f" label="Bis" :error="fieldError('csv', 'to')"><input :id="f.id" v-model="csvTo" type="date" class="input" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
      </div>
      <p v-if="errors.csv" class="error small mt-1" role="alert">{{ errors.csv }}</p>
      <button type="button" class="btn btn-primary mt-2" :disabled="busy === 'csv'" @click="tripsCsv"><Icon name="download" size="sm" />{{ busy === 'csv' ? 'Wird erstellt …' : 'CSV herunterladen' }}</button>
    </section>
  </div>

  <section class="card mt-3" aria-labelledby="rep-year">
    <div class="card-header">
      <h2 id="rep-year">Jahresbericht {{ year }}</h2>
      <div class="actions">
        <label for="year-sel" class="sr-only">Jahr</label>
        <select id="year-sel" v-model.number="year" class="select"><option v-for="y in years" :key="y" :value="y">{{ y }}</option></select>
        <button type="button" class="btn" :disabled="busy === 'year'" @click="yearPdf"><Icon name="download" size="sm" />PDF</button>
      </div>
    </div>
    <p v-if="errors.year" class="error small" role="alert">{{ errors.year }}</p>
    <Loading v-if="reportLoading" />
    <AlertBox v-else-if="reportError" kind="danger" live>
      <p>{{ reportError }}</p>
      <button type="button" class="btn btn-sm" @click="reportRes.reload()"><Icon name="refresh" size="sm" />Erneut versuchen</button>
    </AlertBox>
    <template v-else-if="report">
      <div class="grid grid-kpi year-tiles">
        <Kpi label="Fahrten" :value="String(report.trips_count)" :sub="report.unconfirmed ? `${report.unconfirmed} nicht bestätigt` : 'alle bestätigt'" />
        <Kpi label="Kilometer total" :value="km(report.km.total, 0)" :sub="`${report.months_used} Monate mit Nutzung`" />
        <Kpi label="Kosten total" :value="chf(report.costs.total, 0)" :sub="`Treibstoff ${chf(report.costs.fuel, 0)}`" />
        <Kpi label="Wartung" :value="chf(report.costs.maintenance, 0)" :sub="`Fixkosten ${chf(report.costs.fixed, 0)}`" />
      </div>

      <h3 class="section-title mt-3">Kilometer nach Kategorie</h3>
      <div class="table-wrap">
        <table class="table">
          <thead><tr><th scope="col">Kategorie</th><th scope="col" class="num">km</th><th scope="col" class="num">Anteil</th><th scope="col">Verteilung</th></tr></thead>
          <tbody>
            <tr v-for="c in KM_CATS" :key="c">
              <td><CategoryBadge :category="c" /></td>
              <td class="num">{{ km(report.km[c], 0) }}</td>
              <td class="num">{{ pct(report.shares_pct[c]) }}</td>
              <td><Meter :value="report.shares_pct[c] ?? 0" :label="`Anteil ${CATEGORY_LABELS[c]}`" /></td>
            </tr>
          </tbody>
        </table>
      </div>

      <h3 class="section-title mt-3">Steuerliche Hilfsgrössen</h3>
      <div class="grid grid-3">
        <div v-for="[key, it] in items" :key="key" :class="['kpi', 'item-tile', it.applicable ? '' : 'na']">
          <div class="kpi-label">{{ it.label }}</div>
          <div class="kpi-value">{{ it.value !== null ? chf(it.value) : 'nicht anwendbar' }}</div>
          <div class="formula">{{ it.formula }}</div>
          <div v-if="it.reason" class="kpi-sub">{{ it.reason }}</div>
          <div v-if="it.params.length" class="kpi-sub">Parameter: {{ it.params.map((p) => `${p.label} ${p.value} (${scopeLabel(p.scope)})`).join('; ') }}</div>
        </div>
      </div>

      <AlertBox v-for="w in report.warnings" :key="w" kind="warn" class="mt-2">{{ w }}</AlertBox>
      <AlertBox kind="info" title="Annahmen – mit Treuhand prüfen" class="mt-2">
        <p>{{ report.disclaimer }}</p>
      </AlertBox>
      <p class="muted small mt-1">{{ vehicle?.name }} · Kanton {{ report.canton ?? 'nicht gesetzt' }}</p>
    </template>
  </section>
</template>
