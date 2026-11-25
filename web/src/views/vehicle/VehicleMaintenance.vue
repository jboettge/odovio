<script setup lang="ts">
import { computed, ref } from 'vue'
import Icon from '../../components/Icon.vue'
import HistoryPanel from '../../components/HistoryPanel.vue'
import ConfirmDialog from '../../components/ConfirmDialog.vue'
import EmptyState from '../../components/EmptyState.vue'
import AttachmentThumb from '../../components/AttachmentThumb.vue'
import { useHistory, useStorno, useVehicle } from '../../composables'
import { all } from '../../store/data'
import type { Maintenance } from '../../api/types'
import { chf, date, km, num } from '../../lib/format'

const { maintenance, tenant, writable } = useVehicle()
const history = useHistory()
const storno = useStorno()
const showDeleted = ref(false)
const openIds = ref<Set<string>>(new Set())

const rows = computed(() =>
  [...maintenance.value].filter((m) => showDeleted.value || !m.deleted).sort((a, b) => b.date.localeCompare(a.date)),
)
const itemsOf = (id: string) => all('maintenance_item').filter((i) => i.maintenance_id === id && !i.deleted).sort((a, b) => a.position - b.position)
const materialsOf = (id: string) => all('maintenance_material').filter((i) => i.maintenance_id === id && !i.deleted).sort((a, b) => a.position - b.position)
const attachmentsOf = (id: string) => all('attachment').filter((a) => a.maintenance_id === id)
const materialSum = (id: string) => materialsOf(id).reduce((a, m) => a + m.quantity * (m.unit_price ?? 0), 0)
const cost = (m: Maintenance) => m.cost ?? materialSum(m.id)

function toggle(id: string) {
  const s = new Set(openIds.value)
  if (s.has(id)) s.delete(id)
  else s.add(id)
  openIds.value = s
}
const total = computed(() => rows.value.filter((m) => !m.deleted).reduce((a, m) => a + cost(m), 0))
</script>

<template>
  <div class="row-between">
    <p class="muted small">{{ rows.length }} Wartungen · Kosten total {{ chf(total) }}</p>
    <label class="check"><input v-model="showDeleted" type="checkbox" />Stornierte anzeigen</label>
  </div>
  <EmptyState v-if="!rows.length" title="Keine Wartungen" icon="wrench" />
  <div class="stack mt-1">
    <article v-for="m in rows" :key="m.id" class="card" :aria-labelledby="`m-${m.id}`">
      <div class="card-header">
        <span class="vehicle-icon"><Icon name="wrench" /></span>
        <div>
          <h2 :id="`m-${m.id}`" :class="{ strike: m.deleted }">{{ m.title }}</h2>
          <div class="muted small">{{ date(m.date) }}<template v-if="m.km !== null"> · {{ km(m.km) }}</template> · erfasst von {{ m.created_by || '–' }}</div>
        </div>
        <div class="actions">
          <span v-if="m.deleted" class="badge badge-danger">storniert</span>
          <strong>{{ chf(cost(m)) }}</strong>
          <button type="button" class="btn btn-ghost btn-icon btn-sm" :aria-label="`Verlauf ${m.title}`" @click="history.show('maintenance', m.id, 'Verlauf der Wartung')"><Icon name="history" size="sm" /></button>
          <button v-if="writable && !m.deleted" type="button" class="btn btn-ghost btn-icon btn-sm" :aria-label="`${m.title} stornieren`" @click="storno.ask('maintenance', m, `${m.title} · ${date(m.date)}`)"><Icon name="ban" size="sm" /></button>
        </div>
      </div>
      <div class="row small">
        <span v-if="m.next_due_km !== null || m.next_due_date" class="badge badge-info">Nächste Wartung: {{ [m.next_due_km !== null ? km(m.next_due_km) : '', m.next_due_date ? date(m.next_due_date) : ''].filter(Boolean).join(' / ') }}</span>
        <span v-if="m.cost === null && materialsOf(m.id).length" class="badge badge-outline">Kosten aus Material</span>
        <span v-if="itemsOf(m.id).length" class="badge">{{ itemsOf(m.id).filter((i) => i.done).length }}/{{ itemsOf(m.id).length }} erledigt</span>
      </div>
      <p v-if="m.note" class="mt-1">{{ m.note }}</p>
      <button type="button" class="btn btn-sm btn-ghost mt-1" :aria-expanded="openIds.has(m.id)" :aria-controls="`md-${m.id}`" @click="toggle(m.id)">
        <Icon :name="openIds.has(m.id) ? 'chevronDown' : 'chevronRight'" size="sm" />Checkliste, Material und Belege
      </button>
      <div v-if="openIds.has(m.id)" :id="`md-${m.id}`" class="grid grid-2 mt-1">
        <div>
          <h3 class="section-title">Checkliste</h3>
          <p v-if="!itemsOf(m.id).length" class="muted small">Keine Checkliste.</p>
          <ul v-else class="callout-list">
            <li v-for="i in itemsOf(m.id)" :key="i.id">
              <Icon :name="i.done ? 'checkCircle' : 'xCircle'" :class="i.done ? 'check-ok' : 'check-na'" :label="i.done ? 'erledigt' : 'offen'" />
              <span :class="{ muted: !i.done }">{{ i.label }}</span>
            </li>
          </ul>
        </div>
        <div>
          <h3 class="section-title">Material</h3>
          <p v-if="!materialsOf(m.id).length" class="muted small">Kein Material erfasst.</p>
          <div v-else class="table-wrap">
            <table class="table">
              <thead><tr><th scope="col">Artikel</th><th scope="col" class="num">Menge</th><th scope="col" class="num">Preis</th><th scope="col" class="num">Total</th></tr></thead>
              <tbody>
                <tr v-for="x in materialsOf(m.id)" :key="x.id">
                  <td>{{ x.name }}<span v-if="x.part_number" class="cell-sub mono">{{ x.part_number }}</span></td>
                  <td class="num">{{ num(x.quantity, 0, 2) }} {{ x.unit }}</td>
                  <td class="num">{{ chf(x.unit_price) }}</td>
                  <td class="num">{{ chf(x.quantity * (x.unit_price ?? 0)) }}</td>
                </tr>
              </tbody>
              <tfoot><tr><td colspan="3">Material total</td><td class="num">{{ chf(materialSum(m.id)) }}</td></tr></tfoot>
            </table>
          </div>
        </div>
        <div v-if="attachmentsOf(m.id).length" class="span-2">
          <h3 class="section-title">Belege</h3>
          <div class="thumbs"><AttachmentThumb v-for="a in attachmentsOf(m.id)" :key="a.id" :tenant="tenant" :attachment="a" /></div>
        </div>
      </div>
    </article>
  </div>
  <HistoryPanel :tenant="tenant" :entity="history.sel.value?.entity ?? null" :id="history.sel.value?.id ?? null" :title="history.sel.value?.title" @close="history.close" />
  <ConfirmDialog :open="storno.state.open" title="Wartung stornieren" confirm-label="Stornieren" danger :reason="storno.state.reason" :busy="storno.state.busy" :error="storno.state.error" @close="storno.close" @confirm="storno.confirm">
    <p><strong>{{ storno.state.label }}</strong></p>
    <p class="muted">Der Eintrag bleibt im Änderungsprotokoll sichtbar.</p>
  </ConfirmDialog>
</template>
