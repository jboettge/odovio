<script setup lang="ts">
// Bestätigung (z. B. Stornieren) mit optionaler/erforderlicher Begründung.
import { computed, ref, watch } from 'vue'
import Modal from './Modal.vue'
import Field from './Field.vue'
import AlertBox from './AlertBox.vue'
import { MIN_REASON } from '../lib/trips'

const props = withDefaults(
  defineProps<{
    open: boolean
    title: string
    confirmLabel?: string
    danger?: boolean
    reason?: 'none' | 'optional' | 'required'
    reasonHint?: string
    busy?: boolean
    error?: string | null
  }>(),
  { confirmLabel: 'Bestätigen', danger: false, reason: 'none', reasonHint: undefined, busy: false, error: null },
)
const emit = defineEmits<{ close: []; confirm: [reason: string] }>()
const text = ref('')
watch(
  () => props.open,
  (o) => {
    if (o) text.value = ''
  },
)
const tooShort = computed(() => props.reason === 'required' && text.value.trim().length < MIN_REASON)
const reasonError = ref<string | undefined>()
function submit() {
  if (tooShort.value) {
    reasonError.value = `Begründung mit mindestens ${MIN_REASON} Zeichen erforderlich`
    return
  }
  reasonError.value = undefined
  emit('confirm', text.value.trim())
}
</script>

<template>
  <Modal :open="open" :title="title" @close="emit('close')">
    <form id="confirm-form" class="stack" @submit.prevent="submit">
      <slot />
      <Field
        v-if="reason !== 'none'"
        v-slot="f"
        :label="reason === 'required' ? 'Begründung' : 'Begründung (optional)'"
        :required="reason === 'required'"
        :hint="reasonHint ?? (reason === 'required' ? `Abgeschlossener Monat: mindestens ${MIN_REASON} Zeichen, wird im Änderungsprotokoll gespeichert.` : undefined)"
        :error="reasonError"
      >
        <textarea :id="f.id" v-model="text" class="textarea" maxlength="300" :aria-invalid="f.invalid" :aria-describedby="f.describedby"></textarea>
      </Field>
      <AlertBox v-if="error" kind="danger" live>{{ error }}</AlertBox>
    </form>
    <template #footer>
      <button type="button" class="btn" @click="emit('close')">Abbrechen</button>
      <button type="submit" form="confirm-form" :class="['btn', danger ? 'btn-danger' : 'btn-primary']" :disabled="busy">
        {{ busy ? 'Bitte warten …' : confirmLabel }}
      </button>
    </template>
  </Modal>
</template>
