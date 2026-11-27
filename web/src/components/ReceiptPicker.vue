<script setup lang="ts">
// Belege im Formular: vorhandene anzeigen/entfernen, neue Dateien (Foto oder PDF) hinzufügen. Hochgeladen wird
// erst beim Speichern (Metadaten zuerst, dann die Datei).
import { ref, useId } from 'vue'
import Icon from './Icon.vue'
import type { Attachment } from '../api/types'
import { ATTACHMENT_KIND_LABELS } from '../lib/labels'
import { bytes, date } from '../lib/format'
import { prepareReceipt, RECEIPT_ACCEPT, ReceiptError, type PreparedReceipt } from '../lib/receipts'
import { uuid } from '../lib/schema'

const props = defineProps<{ existing: Attachment[] }>()
const added = defineModel<PreparedReceipt[]>('added', { required: true })
const removed = defineModel<string[]>('removed', { required: true })
const id = useId()
const input = ref<HTMLInputElement | null>(null)
const errors = ref<string[]>([])
const busy = ref(false)

async function onPick(e: Event) {
  const files = [...((e.target as HTMLInputElement).files ?? [])]
  errors.value = []
  busy.value = true
  try {
    for (const f of files) {
      try {
        added.value = [...added.value, await prepareReceipt(f, uuid())]
      } catch (err) {
        errors.value.push(err instanceof ReceiptError ? err.message : `«${f.name}» konnte nicht gelesen werden.`)
      }
    }
  } finally {
    busy.value = false
    if (input.value) input.value.value = ''
  }
}
const drop = (rid: string) => (added.value = added.value.filter((r) => r.id !== rid))
const toggleRemove = (aid: string) =>
  (removed.value = removed.value.includes(aid) ? removed.value.filter((x) => x !== aid) : [...removed.value, aid])
const shown = () => props.existing.filter((a) => !a.deleted)
</script>

<template>
  <fieldset class="fieldset span-2">
    <legend>Belege</legend>
    <ul v-if="shown().length || added.length" class="receipt-list">
      <li v-for="a in shown()" :key="a.id" :class="{ strike: removed.includes(a.id) }">
        <Icon :name="a.mime === 'application/pdf' ? 'file' : 'image'" size="sm" />
        <span>{{ ATTACHMENT_KIND_LABELS[a.kind] ?? a.kind }} · {{ a.mime === 'application/pdf' ? 'PDF' : 'Foto' }} · {{ bytes(a.size) }}<template v-if="a.taken_at"> · {{ date(a.taken_at) }}</template></span>
        <button type="button" class="btn btn-ghost btn-sm" @click="toggleRemove(a.id)">{{ removed.includes(a.id) ? 'Behalten' : 'Entfernen' }}</button>
      </li>
      <li v-for="r in added" :key="r.id">
        <Icon :name="r.mime === 'application/pdf' ? 'file' : 'image'" size="sm" />
        <span>{{ r.name }} · {{ bytes(r.size) }}<span v-if="r.converted" class="badge badge-outline">als JPEG</span><span class="badge badge-info">neu</span></span>
        <button type="button" class="btn btn-ghost btn-sm" :aria-label="`${r.name} nicht hinzufügen`" @click="drop(r.id)">Entfernen</button>
      </li>
    </ul>
    <p v-else class="muted small">Noch keine Belege.</p>
    <div class="row mt-1">
      <input :id="id" ref="input" type="file" class="sr-only file-input" multiple :accept="RECEIPT_ACCEPT" :disabled="busy" @change="onPick" />
      <label :for="id" class="btn btn-sm"><Icon name="plus" size="sm" />{{ busy ? 'Wird gelesen …' : 'Foto oder PDF hinzufügen' }}</label>
      <span class="muted small">JPEG, HEIC, PNG oder PDF, höchstens 8 MB. Entfernte Belege bleiben im Protokoll.</span>
    </div>
    <ul v-if="errors.length" class="error small mt-1" role="alert">
      <li v-for="(m, i) in errors" :key="i">{{ m }}</li>
    </ul>
  </fieldset>
</template>
