<script setup lang="ts">
// Zeitachse aller Kilometerstände: abgelesen, beim Tanken, bei Wartungen (aktueller Stand = Maximum).
import { computed, ref } from 'vue'
import Icon from '../../components/Icon.vue'
import HistoryPanel from '../../components/HistoryPanel.vue'
import ConfirmDialog from '../../components/ConfirmDialog.vue'
import EmptyState from '../../components/EmptyState.vue'
import LineChart from '../../components/LineChart.vue'
import Pager from '../../components/Pager.vue'
import OdometerEditor from './editors/OdometerEditor.vue'
import { useOpenOnQuery } from '../../use/openOnQuery'
import { useHistory, useStorno, useVehicle } from '../../composables'
import { usePager } from '../../use/pager'
import type { OdometerReading } from '../../api/types'
import { date, km, num, byCode } from '../../lib/format'

const { vehicle, odometer, fuel, maintenance, tenant, writable } = useVehicle()
const history = useHistory()
const storno = useStorno()
const editor = ref<InstanceType<typeof OdometerEditor> | null>(null)
useOpenOnQuery(() => editor.value?.create(), () => writable.value)

interface Reading {
  key: string
  date: string
  km: number
  source: 'odometer' | 'fuel' | 'maintenance' | 'start'
  label: string
  rec?: OdometerReading
  entityId?: string
}

const readings = computed<Reading[]>(() => {
  const out: Reading[] = []
  for (const o of odometer.value) if (!o.deleted) out.push({ key: `o${o.id}`, date: o.date, km: o.km, source: 'odometer', label: o.note || 'Abgelesen', rec: o, entityId: o.id })
  for (const f of fuel.value) if (!f.deleted) out.push({ key: `f${f.id}`, date: f.date, km: f.km, source: 'fuel', label: `Tanken${f.station ? ` · ${f.station}` : ''}`, entityId: f.id })
  for (const m of maintenance.value) if (!m.deleted && m.km !== null) out.push({ key: `m${m.id}`, date: m.date, km: m.km, source: 'maintenance', label: m.title, entityId: m.id })
  out.sort((a, b) => byCode(b.date, a.date) || b.km - a.km || byCode(a.key, b.key))
  return out
})
// Zeitachse seitenweise (Abstand zum Vorgänger auch über Seitengrenzen korrekt)
const pager = usePager(readings)
const withDelta = computed(() => {
  const all = readings.value
  const offset = pager.from ? pager.from - 1 : 0
  return pager.items.map((r, i) => ({ ...r, delta: offset + i + 1 < all.length ? r.km - all[offset + i + 1]!.km : null }))
})
const chartPoints = computed(() => [...readings.value].reverse().map((r) => ({ label: date(r.date), value: r.km, detail: r.label })))
const ICON = { odometer: 'gauge', fuel: 'fuel', maintenance: 'wrench', start: 'car' } as const
const SOURCE = { odometer: 'Kilometerstand', fuel: 'Tankvorgang', maintenance: 'Wartung', start: 'Start' } as const
</script>

<template>
  <div class="grid grid-2">
    <section class="card" aria-labelledby="odo-h">
      <div class="card-header">
        <h2 id="odo-h">Zeitachse</h2><span class="muted small">Start-km {{ km(vehicle?.initial_km) }}</span>
        <div class="actions"><button v-if="writable" type="button" class="btn btn-primary btn-sm" @click="editor?.create()"><Icon name="plus" size="sm" />Kilometerstand erfassen</button></div>
      </div>
      <EmptyState v-if="!readings.length" title="Keine Kilometerstände" icon="gauge" />
      <ol v-else class="timeline">
        <li v-for="r in withDelta" :key="r.key">
          <span :class="['timeline-dot', r.source === 'odometer' ? '' : 'dot-muted']" aria-hidden="true"></span>
          <div class="row-between">
            <strong>{{ km(r.km) }}</strong>
            <span class="row">
              <span class="muted small">{{ date(r.date) }}</span>
              <button v-if="r.entityId" type="button" class="btn btn-ghost btn-icon btn-sm" :aria-label="`Verlauf ${SOURCE[r.source]} ${date(r.date)}`" @click="history.show(r.source, r.entityId!)"><Icon name="history" size="sm" /></button>
              <button v-if="writable && r.rec" type="button" class="btn btn-ghost btn-icon btn-sm" :aria-label="`Kilometerstand ${date(r.date)} bearbeiten`" @click="editor?.edit(r.rec!)"><Icon name="edit" size="sm" /></button>
              <button v-if="writable && r.rec" type="button" class="btn btn-ghost btn-icon btn-sm" :aria-label="`Kilometerstand ${date(r.date)} stornieren`" @click="storno.ask('odometer', r.rec!, `${date(r.date)} · ${km(r.km)}`)"><Icon name="ban" size="sm" /></button>
            </span>
          </div>
          <div class="row small">
            <Icon :name="ICON[r.source]" size="sm" /><span>{{ SOURCE[r.source] }}</span><span class="muted">· {{ r.label }}</span>
            <span v-if="r.delta !== null" :class="['badge', r.delta < 0 ? 'badge-danger' : 'badge-outline']">{{ r.delta >= 0 ? '+' : '' }}{{ num(r.delta) }} km</span>
          </div>
        </li>
      </ol>
      <Pager v-model:page="pager.page" v-model:size="pager.size" :total="pager.total" label="Seiten der Zeitachse" />
    </section>
    <section class="card" aria-labelledby="odo-chart">
      <h2 id="odo-chart" class="section-title">Verlauf</h2>
      <LineChart v-if="chartPoints.length > 1" title="Kilometerstand über die Zeit" series-label="Kilometerstand" :points="chartPoints" :format="(v: number) => num(v)" />
      <p v-else class="muted">Zu wenige Werte für ein Diagramm.</p>
      <p class="muted small mt-2">Der aktuelle Kilometerstand ist das Maximum aus abgelesenen Ständen, Tankvorgängen und Wartungen. Ein negativer Abstand deutet auf einen Erfassungsfehler hin.</p>
    </section>
  </div>
  <OdometerEditor ref="editor" />
  <HistoryPanel :tenant="tenant" :entity="history.sel.value?.entity ?? null" :id="history.sel.value?.id ?? null" @close="history.close" />
  <ConfirmDialog :open="storno.state.open" title="Kilometerstand stornieren" confirm-label="Stornieren" danger :reason="storno.state.reason" :busy="storno.state.busy" :error="storno.state.error" @close="storno.close" @confirm="storno.confirm">
    <p><strong>{{ storno.state.label }}</strong></p>
  </ConfirmDialog>
</template>
