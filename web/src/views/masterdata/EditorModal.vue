<script setup lang="ts">
// Gemeinsamer Bearbeiten-Dialog (Stammdaten und Erfassen: Tanken, Wartung, Kilometerstand).
// - Ungespeicherte Änderungen: Esc, Klick auf den Hintergrund, «Schliessen» und «Abbrechen» fragen zuerst nach.
// - Nach «Speichern» mit Feldfehlern springt der Fokus zum ersten markierten Feld (Fehlertext über aria-describedby).
import { nextTick, ref, watch } from 'vue'
import Modal from '../../components/Modal.vue'
import AlertBox from '../../components/AlertBox.vue'
import ConfirmDialog from '../../components/ConfirmDialog.vue'
import { firstInvalid } from '../../lib/focus'

const props = withDefaults(defineProps<{ open: boolean; title: string; busy: boolean; error: string | null; dirty?: boolean }>(), { dirty: false })
const emit = defineEmits<{ close: []; save: [] }>()
const form = ref<HTMLFormElement | null>(null)
const asking = ref(false)

watch(
  () => props.open,
  (o) => {
    if (!o) asking.value = false
  },
)

function requestClose() {
  if (props.dirty && !props.busy) asking.value = true
  else emit('close')
}
async function discard() {
  // erst die Rückfrage schliessen (Fokus zurück in den Dialog), dann den Dialog – Fokus geht so an den Auslöser
  asking.value = false
  await nextTick()
  emit('close')
}

async function submit() {
  emit('save')
  // die Prüfung im Elternteil läuft synchron; nach dem Rendern der Fehler zum ersten markierten Feld
  await nextTick()
  if (form.value) firstInvalid(form.value)?.focus()
}
</script>

<template>
  <Modal :open="open" :title="title" wide @close="requestClose">
    <form id="editor-form" ref="form" novalidate @submit.prevent="submit">
      <div class="form-grid"><slot /></div>
      <AlertBox v-if="error" kind="danger" live class="mt-2">{{ error }}</AlertBox>
    </form>
    <template #footer>
      <button type="button" class="btn" @click="requestClose">Abbrechen</button>
      <button type="submit" form="editor-form" class="btn btn-primary" :disabled="busy">{{ busy ? 'Wird gespeichert …' : 'Speichern' }}</button>
    </template>
  </Modal>
  <ConfirmDialog :open="asking" title="Änderungen verwerfen?" confirm-label="Verwerfen" cancel-label="Weiter bearbeiten" danger @close="asking = false" @confirm="discard">
    <p>Die Eingaben in «{{ title }}» sind noch nicht gespeichert und gehen verloren.</p>
  </ConfirmDialog>
</template>
