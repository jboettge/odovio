<script setup lang="ts">
// Begründung für Erfassen/Ändern im abgeschlossenen Monat (Server verlangt sie, mind. MIN_REASON Zeichen).
import Field from './Field.vue'
import { MIN_REASON } from '../lib/trips'

defineProps<{ error?: string }>()
const model = defineModel<string>({ required: true })
</script>

<template>
  <Field v-slot="f" label="Begründung der Korrektur" required span :hint="`Der Monat ist abgeschlossen – die Änderung wird mit Begründung protokolliert (mind. ${MIN_REASON} Zeichen).`" :error="error">
    <textarea :id="f.id" v-model="model" class="textarea" maxlength="500" :aria-invalid="f.invalid" :aria-describedby="f.describedby"></textarea>
  </Field>
</template>
