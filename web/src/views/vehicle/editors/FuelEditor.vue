<script setup lang="ts">
// Tankvorgang im Web erfassen/bearbeiten, mit Belegen (Foto/PDF).
import { computed, ref } from 'vue'
import Field from '../../../components/Field.vue'
import CorrectionReason from '../../../components/CorrectionReason.vue'
import ReceiptPicker from '../../../components/ReceiptPicker.vue'
import EditorModal from '../../masterdata/EditorModal.vue'
import { correctionNeedsReason, numOrNull, strOrNull, useEditor } from '../../../composables'
import { useKmContext } from '../../../use/kmContext'
import { childrenOf } from '../../../store/data'
import { attachmentOp, uploadReceipts } from '../../../store/uploads'
import type { FuelEntry } from '../../../api/types'
import { deleteOp } from '../../../lib/schema'
import { isoDate } from '../../../lib/format'
import { MIN_REASON } from '../../../lib/trips'
import { pricePerLiterWarning } from '../../../lib/readings'
import type { PreparedReceipt } from '../../../lib/receipts'

const { vid, tenant, current, warn } = useKmContext()
const ed = useEditor('fuel', () => ({ vehicle_id: vid.value, date: isoDate(), km: current.value || '', liters: '', price_total: '', full_tank: true, station: '', note: '' }))
const e = computed(() => ed.state.errors)
const original = ref<FuelEntry | null>(null)
const reason = ref('')
const reasonError = ref<string | undefined>()
const added = ref<PreparedReceipt[]>([])
const removed = ref<string[]>([])

const existing = computed(() => (ed.state.id ? childrenOf('attachment', 'fuel_id', ed.state.id) : []))
const needsReason = computed(() => correctionNeedsReason(vid.value, ed.state.form.date, ed.state.form.km, original.value))
const kmHint = computed(() => warn(ed.state.form.date, numOrNull(ed.state.form.km), ed.state.id))
const priceHint = computed(() => pricePerLiterWarning(numOrNull(ed.state.form.liters), numOrNull(ed.state.form.price_total)))

function reset(rec: FuelEntry | null) {
  original.value = rec
  reason.value = ''
  reasonError.value = undefined
  added.value = []
  removed.value = []
}
function create() {
  reset(null)
  ed.create()
}
function edit(rec: FuelEntry) {
  reset(rec)
  ed.edit(rec)
}
defineExpose({ create, edit })

function save() {
  if (needsReason.value && reason.value.trim().length < MIN_REASON) {
    reasonError.value = `Begründung mit mindestens ${MIN_REASON} Zeichen erforderlich`
    return
  }
  reasonError.value = undefined
  const receipts = added.value
  void ed.save(
    (f) => ({
      ...f,
      vehicle_id: vid.value,
      km: numOrNull(f.km),
      liters: numOrNull(f.liters),
      price_total: numOrNull(f.price_total),
      full_tank: Boolean(f.full_tank),
      station: strOrNull(f.station),
      note: strOrNull(f.note),
    }),
    {
      reason: needsReason.value ? reason.value : undefined,
      extra: (id) => [
        ...receipts.map((r) => attachmentOp(r, { fuel_id: id }, vid.value)),
        ...existing.value.filter((a) => removed.value.includes(a.id) && !a.deleted).map((a) => deleteOp('attachment', a.id, a.version)),
      ],
      after: async () => {
        if (receipts.length) await uploadReceipts(tenant.value, receipts)
      },
    },
  )
}
</script>

<template>
  <EditorModal :open="ed.state.open" :title="ed.state.id ? 'Tankvorgang bearbeiten' : 'Tankvorgang erfassen'" :busy="ed.state.busy" :error="ed.state.error" @close="ed.close" @save="save">
    <Field v-slot="f" label="Datum" required :error="e.date"><input :id="f.id" v-model="ed.state.form.date" type="date" class="input" :max="isoDate()" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
    <Field v-slot="f" label="Kilometerstand" required :error="e.km" :warning="kmHint">
      <input :id="f.id" v-model="ed.state.form.km" class="input" inputmode="numeric" autocomplete="off" :aria-invalid="f.invalid" :aria-describedby="f.describedby" />
    </Field>
    <Field v-slot="f" label="Liter" required :error="e.liters"><input :id="f.id" v-model="ed.state.form.liters" class="input" inputmode="decimal" autocomplete="off" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
    <Field v-slot="f" label="Betrag (CHF)" required :error="e.price_total" :warning="priceHint">
      <input :id="f.id" v-model="ed.state.form.price_total" class="input" inputmode="decimal" autocomplete="off" :aria-invalid="f.invalid" :aria-describedby="f.describedby" />
    </Field>
    <Field v-slot="f" label="Tankstelle" :error="e.station"><input :id="f.id" v-model="ed.state.form.station" class="input" maxlength="100" /></Field>
    <div class="field"><span class="label">Füllung</span><label class="check"><input v-model="ed.state.form.full_tank" type="checkbox" />Vollgetankt (für Verbrauchsberechnung)</label></div>
    <Field v-slot="f" label="Notiz" span :error="e.note"><textarea :id="f.id" v-model="ed.state.form.note" class="textarea" maxlength="2000"></textarea></Field>
    <ReceiptPicker v-model:added="added" v-model:removed="removed" :existing="existing" />
    <CorrectionReason v-if="needsReason" v-model="reason" :error="reasonError" />
  </EditorModal>
</template>
