<script setup lang="ts">
import { computed, ref, shallowRef } from 'vue'
import Icon from '../../components/Icon.vue'
import Modal from '../../components/Modal.vue'
import HistoryPanel from '../../components/HistoryPanel.vue'
import ConfirmDialog from '../../components/ConfirmDialog.vue'
import EmptyState from '../../components/EmptyState.vue'
import AttachmentThumb from '../../components/AttachmentThumb.vue'
import VPad from '../../components/VPad.vue'
import { useHistory, useStorno, useVehicle } from '../../composables'
import { childrenOf } from '../../store/data'
import type { FuelEntry } from '../../api/types'
import { chf, date, km, liters, num, byCode } from '../../lib/format'
import { useVirtualRows } from '../../use/virtualRows'

const { fuel, tenant, writable } = useVehicle()
const history = useHistory()
const storno = useStorno()
const showDeleted = ref(false)
const preview = shallowRef<FuelEntry | null>(null)

const rows = computed(() =>
  fuel.value.filter((f) => showDeleted.value || !f.deleted).sort((a, b) => byCode(b.date, a.date) || b.km - a.km || byCode(a.id, b.id)),
)
const totals = computed(() => {
  let l = 0
  let sum = 0
  for (const f of rows.value) {
    if (f.deleted) continue
    l += f.liters
    sum += f.price_total
  }
  return { l, chf: sum }
})
// Belege aus dem Index (je Tankvorgang), nur für sichtbare Zeilen
const allAtt = (id: string) => childrenOf('attachment', 'fuel_id', id)
const { el: tableEl, items: visible, start: vStart, padTop, padBottom } = useVirtualRows(rows)
const visibleRows = computed(() => visible.value.map((f) => ({ f, att: allAtt(f.id).filter((a) => !a.deleted).length })))
</script>

<template>
  <section class="card card-flush" aria-labelledby="fuel-h">
    <div class="card-header">
      <h2 id="fuel-h">Tankvorgänge</h2>
      <span class="muted small">{{ num(rows.length) }} Einträge</span>
      <div class="actions"><label class="check"><input v-model="showDeleted" type="checkbox" />Stornierte anzeigen</label></div>
    </div>
    <EmptyState v-if="!rows.length" title="Keine Tankvorgänge" icon="fuel" />
    <div v-else ref="tableEl" class="table-wrap vtable">
      <table class="table" :aria-rowcount="rows.length + 2">
        <thead>
          <tr aria-rowindex="1">
            <th scope="col">Datum</th>
            <th scope="col" class="num">Kilometerstand</th>
            <th scope="col" class="num">Liter</th>
            <th scope="col" class="num">Betrag</th>
            <th scope="col" class="num">CHF/l</th>
            <th scope="col">Füllung</th>
            <th scope="col">Tankstelle</th>
            <th scope="col">Belege</th>
            <th scope="col">Erfasst von</th>
            <th scope="col"><span class="sr-only">Aktionen</span></th>
          </tr>
        </thead>
        <tbody>
          <VPad :height="padTop" :cols="10" />
          <tr v-for="({ f, att }, i) in visibleRows" :key="f.id" v-memo="[f, att, writable, vStart + i]" :aria-rowindex="vStart + i + 2" :class="{ 'is-deleted': f.deleted }">
            <td class="nowrap strike-cell">{{ date(f.date) }}<span v-if="f.deleted" class="badge badge-danger">storniert</span></td>
            <td class="num">{{ km(f.km) }}</td>
            <td class="num">{{ liters(f.liters) }}</td>
            <td class="num">{{ chf(f.price_total) }}</td>
            <td class="num">{{ f.liters ? num(f.price_total / f.liters, 3) : '–' }}</td>
            <td><span :class="['badge', f.full_tank ? 'badge-ok' : 'badge-outline']">{{ f.full_tank ? 'voll' : 'teil' }}</span></td>
            <td>{{ f.station || '–' }}<span v-if="f.note" class="cell-sub">{{ f.note }}</span></td>
            <td>
              <button v-if="att" type="button" class="btn btn-sm" :aria-label="`${att} Belege vom ${date(f.date)} anzeigen`" @click="preview = f">
                <Icon name="image" size="sm" />{{ att }}
              </button>
              <span v-else class="muted">–</span>
            </td>
            <td>{{ f.created_by || '–' }}</td>
            <td class="actions">
              <button type="button" class="btn btn-ghost btn-icon btn-sm" :aria-label="`Verlauf Tankvorgang ${date(f.date)}`" @click="history.show('fuel', f.id, 'Verlauf des Tankvorgangs')"><Icon name="history" size="sm" /></button>
              <button v-if="writable && !f.deleted" type="button" class="btn btn-ghost btn-icon btn-sm" :aria-label="`Tankvorgang ${date(f.date)} stornieren`" @click="storno.ask('fuel', f, `${date(f.date)} · ${liters(f.liters)} · ${chf(f.price_total)}`)"><Icon name="ban" size="sm" /></button>
            </td>
          </tr>
          <VPad :height="padBottom" :cols="10" />
        </tbody>
        <tfoot>
          <tr :aria-rowindex="rows.length + 2"><td colspan="2">Total</td><td class="num">{{ liters(totals.l, 1) }}</td><td class="num">{{ chf(totals.chf) }}</td><td colspan="6"></td></tr>
        </tfoot>
      </table>
    </div>
  </section>

  <Modal :open="preview !== null" :title="preview ? `Belege vom ${date(preview.date)}` : 'Belege'" wide @close="preview = null">
    <div v-if="preview" class="thumbs">
      <AttachmentThumb v-for="a in allAtt(preview.id)" :key="a.id" :tenant="tenant" :attachment="a" />
    </div>
    <p class="muted small mt-2">Belege werden mit Prüfsumme (SHA-256) gespeichert und in der Integritätsprüfung kontrolliert.</p>
  </Modal>
  <HistoryPanel :tenant="tenant" :entity="history.sel.value?.entity ?? null" :id="history.sel.value?.id ?? null" :title="history.sel.value?.title" @close="history.close" />
  <ConfirmDialog :open="storno.state.open" title="Tankvorgang stornieren" confirm-label="Stornieren" danger :reason="storno.state.reason" :busy="storno.state.busy" :error="storno.state.error" @close="storno.close" @confirm="storno.confirm">
    <p><strong>{{ storno.state.label }}</strong></p>
    <p class="muted">Der Eintrag bleibt im Änderungsprotokoll sichtbar.</p>
  </ConfirmDialog>
</template>
