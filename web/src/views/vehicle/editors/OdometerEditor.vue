<script setup lang="ts">
// Abgelesenen Kilometerstand im Web erfassen/bearbeiten.
import { computed, ref } from 'vue'
import Field from '../../../components/Field.vue'
import CorrectionReason from '../../../components/CorrectionReason.vue'
import EditorModal from '../../masterdata/EditorModal.vue'
import { correctionNeedsReason, numOrNull, strOrNull, useEditor } from '../../../composables'
import { useKmContext } from '../../../use/kmContext'
import type { OdometerReading } from '../../../api/types'
import { isoDate, km as fmtKm } from '../../../lib/format'
import { MIN_REASON } from '../../../lib/trips'

const { vid, current, warn } = useKmContext()
const ed = useEditor('odometer', () => ({ vehicle_id: vid.value, date: isoDate(), km: '', note: '' }))
const e = computed(() => ed.state.errors)
const original = ref<OdometerReading | null>(null)
const reason = ref('')
const reasonError = ref<string | undefined>()
const needsReason = computed(() => correctionNeedsReason(vid.value, ed.state.form.date, ed.state.form.km, original.value))
const kmWarn = computed(() => warn(ed.state.form.date, numOrNull(ed.state.form.km), ed.state.id))

function open(rec: OdometerReading | null) {
  original.value = rec
  reason.value = ''
  reasonError.value = undefined
  if (rec) ed.edit(rec)
  else ed.create()
}
defineExpose({ create: () => open(null), edit: (rec: OdometerReading) => open(rec) })

function save() {
  if (needsReason.value && reason.value.trim().length < MIN_REASON) {
    reasonError.value = `Begründung mit mindestens ${MIN_REASON} Zeichen erforderlich`
    return
  }
  reasonError.value = undefined
  void ed.save((f) => ({ ...f, vehicle_id: vid.value, km: numOrNull(f.km), note: strOrNull(f.note) }), { reason: needsReason.value ? reason.value : undefined })
}
</script>

<template>
  <EditorModal :open="ed.state.open" :title="ed.state.id ? 'Kilometerstand bearbeiten' : 'Kilometerstand erfassen'" :busy="ed.state.busy" :error="ed.state.error" @close="ed.close" @save="save">
    <Field v-slot="f" label="Datum" required :error="e.date"><input :id="f.id" v-model="ed.state.form.date" type="date" class="input" :max="isoDate()" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
    <Field v-slot="f" label="Kilometerstand" required :error="e.km" :hint="`Bisher höchster Stand: ${fmtKm(current)}`" :warning="kmWarn">
      <input :id="f.id" v-model="ed.state.form.km" class="input" inputmode="numeric" autocomplete="off" :aria-invalid="f.invalid" :aria-describedby="f.describedby" />
    </Field>
    <Field v-slot="f" label="Notiz" span :error="e.note"><textarea :id="f.id" v-model="ed.state.form.note" class="textarea" maxlength="2000" placeholder="z. B. Service-Heft, MFK"></textarea></Field>
    <CorrectionReason v-if="needsReason" v-model="reason" :error="reasonError" />
  </EditorModal>
</template>
