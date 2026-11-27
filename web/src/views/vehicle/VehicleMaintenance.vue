<script setup lang="ts">
import { computed, ref } from 'vue'
import Icon from '../../components/Icon.vue'
import HistoryPanel from '../../components/HistoryPanel.vue'
import ConfirmDialog from '../../components/ConfirmDialog.vue'
import EmptyState from '../../components/EmptyState.vue'
import AttachmentThumb from '../../components/AttachmentThumb.vue'
import Pager from '../../components/Pager.vue'
import PendingUploads from '../../components/PendingUploads.vue'
import MaintenanceEditor from './editors/MaintenanceEditor.vue'
import { useOpenOnQuery } from '../../use/openOnQuery'
import { useHistory, useStorno, useVehicle } from '../../composables'
import { childrenOf } from '../../store/data'
import { usePager } from '../../use/pager'
import type { Maintenance } from '../../api/types'
import { chf, date, km, num, byCode } from '../../lib/format'

const { maintenance, tenant, writable } = useVehicle()
const history = useHistory()
const storno = useStorno()
const showDeleted = ref(false)
const openIds = ref<Set<string>>(new Set())
const editor = ref<InstanceType<typeof MaintenanceEditor> | null>(null)
useOpenOnQuery(() => editor.value?.create(), () => writable.value)

const rows = computed(() =>
  maintenance.value.filter((m) => showDeleted.value || !m.deleted).sort((a, b) => byCode(b.date, a.date) || byCode(a.id, b.id)),
)
// Kinder aus dem Index je Wartung (kein Filter über alle Checklisten-/Materialposten des Mandanten)
const byPos = <T extends { position: number; deleted: boolean }>(xs: T[]) => xs.filter((x) => !x.deleted).sort((a, b) => a.position - b.position)
const itemsOf = (id: string) => byPos(childrenOf('maintenance_item', 'maintenance_id', id))
const materialsOf = (id: string) => byPos(childrenOf('maintenance_material', 'maintenance_id', id))
const attachmentsOf = (id: string) => childrenOf('attachment', 'maintenance_id', id)
const materialSum = (id: string) => materialsOf(id).reduce((a, m) => a + m.quantity * (m.unit_price ?? 0), 0)
const cost = (m: Maintenance) => m.cost ?? materialSum(m.id)
// Karten haben variable Höhe (aufklappbar) → Seitenaufteilung statt virtuellem Scrollen
const pager = usePager(rows, { resetOn: [showDeleted] })
/** Anzeige-Werte je Karte der aktuellen Seite einmal berechnen */
const cards = computed(() =>
  pager.items.map((m) => {
    const items = itemsOf(m.id)
    const materials = materialsOf(m.id)
    return { m, items, done: items.filter((i) => i.done).length, materials, materialSum: materials.reduce((a, x) => a + x.quantity * (x.unit_price ?? 0), 0), attachments: attachmentsOf(m.id), cost: cost(m) }
  }),
)

function toggle(id: string) {
  const s = new Set(openIds.value)
  if (s.has(id)) s.delete(id)
  else s.add(id)
  openIds.value = s
}
const total = computed(() => rows.value.reduce((a, m) => a + (m.deleted ? 0 : cost(m)), 0))
</script>

<template>
  <div class="row-between">
    <p class="muted small">{{ rows.length }} Wartungen · Kosten total {{ chf(total) }}</p>
    <div class="row">
      <label class="check"><input v-model="showDeleted" type="checkbox" />Stornierte anzeigen</label>
      <button v-if="writable" type="button" class="btn btn-primary btn-sm" @click="editor?.create()"><Icon name="plus" size="sm" />Wartung erfassen</button>
    </div>
  </div>
  <PendingUploads />
  <EmptyState v-if="!rows.length" title="Keine Wartungen" icon="wrench" />
  <div class="stack mt-1">
    <article v-for="{ m, items, done, materials, materialSum: matSum, attachments, cost: mCost } in cards" :key="m.id" class="card" :aria-labelledby="`m-${m.id}`">
      <div class="card-header">
        <span class="vehicle-icon"><Icon name="wrench" /></span>
        <div>
          <h2 :id="`m-${m.id}`" :class="{ strike: m.deleted }">{{ m.title }}</h2>
          <div class="muted small">{{ date(m.date) }}<template v-if="m.km !== null"> · {{ km(m.km) }}</template> · erfasst von {{ m.created_by || '–' }}</div>
        </div>
        <div class="actions">
          <span v-if="m.deleted" class="badge badge-danger">storniert</span>
          <strong>{{ chf(mCost) }}</strong>
          <button type="button" class="btn btn-ghost btn-icon btn-sm" :aria-label="`Verlauf ${m.title} vom ${date(m.date)}`" @click="history.show('maintenance', m.id, 'Verlauf der Wartung')"><Icon name="history" size="sm" /></button>
          <button v-if="writable && !m.deleted" type="button" class="btn btn-ghost btn-icon btn-sm" :aria-label="`${m.title} vom ${date(m.date)} bearbeiten`" @click="editor?.edit(m)"><Icon name="edit" size="sm" /></button>
          <button v-if="writable && !m.deleted" type="button" class="btn btn-ghost btn-icon btn-sm" :aria-label="`${m.title} vom ${date(m.date)} stornieren`" @click="storno.ask('maintenance', m, `${m.title} · ${date(m.date)}`)"><Icon name="ban" size="sm" /></button>
        </div>
      </div>
      <div class="row small">
        <span v-if="m.next_due_km !== null || m.next_due_date" class="badge badge-info">Nächste Wartung: {{ [m.next_due_km !== null ? km(m.next_due_km) : '', m.next_due_date ? date(m.next_due_date) : ''].filter(Boolean).join(' / ') }}</span>
        <span v-if="m.cost === null && materials.length" class="badge badge-outline">Kosten aus Material</span>
        <span v-if="items.length" class="badge">{{ done }}/{{ items.length }} erledigt</span>
      </div>
      <p v-if="m.note" class="mt-1">{{ m.note }}</p>
      <button type="button" class="btn btn-sm btn-ghost mt-1" :aria-expanded="openIds.has(m.id)" :aria-controls="`md-${m.id}`" @click="toggle(m.id)">
        <Icon :name="openIds.has(m.id) ? 'chevronDown' : 'chevronRight'" size="sm" />Checkliste, Material und Belege
      </button>
      <div v-if="openIds.has(m.id)" :id="`md-${m.id}`" class="grid grid-2 mt-1">
        <div>
          <h3 class="section-title">Checkliste</h3>
          <p v-if="!items.length" class="muted small">Keine Checkliste.</p>
          <ul v-else class="callout-list">
            <li v-for="i in items" :key="i.id">
              <Icon :name="i.done ? 'checkCircle' : 'xCircle'" :class="i.done ? 'check-ok' : 'check-na'" :label="i.done ? 'erledigt' : 'offen'" />
              <span :class="{ muted: !i.done }">{{ i.label }}</span>
            </li>
          </ul>
        </div>
        <div>
          <h3 class="section-title">Material</h3>
          <p v-if="!materials.length" class="muted small">Kein Material erfasst.</p>
          <div v-else class="table-wrap">
            <table class="table">
              <thead><tr><th scope="col">Artikel</th><th scope="col" class="num">Menge</th><th scope="col" class="num">Preis</th><th scope="col" class="num">Total</th></tr></thead>
              <tbody>
                <tr v-for="x in materials" :key="x.id">
                  <td>{{ x.name }}<span v-if="x.part_number" class="cell-sub mono">{{ x.part_number }}</span></td>
                  <td class="num">{{ num(x.quantity, 0, 2) }} {{ x.unit }}</td>
                  <td class="num">{{ chf(x.unit_price) }}</td>
                  <td class="num">{{ chf(x.quantity * (x.unit_price ?? 0)) }}</td>
                </tr>
              </tbody>
              <tfoot><tr><td colspan="3">Material total</td><td class="num">{{ chf(matSum) }}</td></tr></tfoot>
            </table>
          </div>
        </div>
        <div v-if="attachments.length" class="span-2">
          <h3 class="section-title">Belege</h3>
          <div class="thumbs"><AttachmentThumb v-for="a in attachments" :key="a.id" :tenant="tenant" :attachment="a" /></div>
        </div>
      </div>
    </article>
  </div>
  <Pager v-model:page="pager.page" v-model:size="pager.size" :total="pager.total" label="Seiten der Wartungen" />
  <MaintenanceEditor ref="editor" />
  <HistoryPanel :tenant="tenant" :entity="history.sel.value?.entity ?? null" :id="history.sel.value?.id ?? null" :title="history.sel.value?.title" @close="history.close" />
  <ConfirmDialog :open="storno.state.open" title="Wartung stornieren" confirm-label="Stornieren" danger :reason="storno.state.reason" :busy="storno.state.busy" :error="storno.state.error" @close="storno.close" @confirm="storno.confirm">
    <p><strong>{{ storno.state.label }}</strong></p>
    <p class="muted">Der Eintrag bleibt im Änderungsprotokoll sichtbar.</p>
  </ConfirmDialog>
</template>
