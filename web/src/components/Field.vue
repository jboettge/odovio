<script setup lang="ts">
// Beschriftetes Formularfeld; Slot erhält id/aria-Attribute für das Eingabeelement.
// Bindet das Eingabeelement die Attribute nicht selbst, setzt Field aria-describedby (Hinweis, Warnung, Fehler)
// und aria-invalid am Element mit der Feld-ID – Fehler sind so immer mit dem Feld verknüpft (WCAG 1.3.1/3.3.1).
import { computed, onUpdated, ref, useId, watch } from 'vue'
const props = defineProps<{ label: string; error?: string; hint?: string; warning?: string | null; required?: boolean; span?: boolean }>()
const id = useId()
const root = ref<HTMLElement | null>(null)
const describedby = computed(() => [props.hint ? `${id}-hint` : '', props.warning ? `${id}-warn` : '', props.error ? `${id}-err` : ''].filter(Boolean).join(' ') || undefined)

/** von Field gesetzte Attribute (vom Slot selbst gebundene werden nicht angefasst) */
const owned = new Set<string>()
let lastEl: Element | null = null
function link() {
  const el = root.value?.querySelector(`[id="${id}"]`) ?? null
  if (el !== lastEl) {
    owned.clear()
    lastEl = el
  }
  if (!el) return
  const want: Record<string, string | undefined> = { 'aria-describedby': describedby.value, 'aria-invalid': props.error ? 'true' : undefined }
  for (const [attr, value] of Object.entries(want)) {
    if (el.hasAttribute(attr) && !owned.has(attr)) continue
    if (value) {
      el.setAttribute(attr, value)
      owned.add(attr)
    } else {
      el.removeAttribute(attr)
      owned.delete(attr)
    }
  }
}
// nach dem Einhängen und bei geändertem Hinweis/Fehler (nach dem Rendern)
watch([root, describedby, () => props.error], link, { flush: 'post' })
onUpdated(link)
</script>

<template>
  <div ref="root" :class="['field', span ? 'span-2' : '']">
    <label :for="id">{{ label }}<span v-if="required" aria-hidden="true"> *</span></label>
    <slot :id="id" :invalid="error ? true : undefined" :describedby="describedby" />
    <span v-if="hint" :id="`${id}-hint`" class="hint">{{ hint }}</span>
    <span v-if="warning" :id="`${id}-warn`" class="field-warn">{{ warning }}</span>
    <span v-if="error" :id="`${id}-err`" class="error">{{ error }}</span>
  </div>
</template>
