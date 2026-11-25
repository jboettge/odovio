<script setup lang="ts">
// Beschriftetes Formularfeld; Slot erhält id/aria-Attribute für das Eingabeelement.
import { computed, useId } from 'vue'
const props = defineProps<{ label: string; error?: string; hint?: string; required?: boolean; span?: boolean }>()
const id = useId()
const describedby = computed(() => [props.hint ? `${id}-hint` : '', props.error ? `${id}-err` : ''].filter(Boolean).join(' ') || undefined)
</script>

<template>
  <div :class="['field', span ? 'span-2' : '']">
    <label :for="id">{{ label }}<span v-if="required" aria-hidden="true"> *</span></label>
    <slot :id="id" :invalid="error ? true : undefined" :describedby="describedby" />
    <span v-if="hint" :id="`${id}-hint`" class="hint">{{ hint }}</span>
    <span v-if="error" :id="`${id}-err`" class="error">{{ error }}</span>
  </div>
</template>
