<script setup lang="ts">
import { onMounted, ref } from 'vue'

defineProps<{ title: string; subtitle?: string; eyebrow?: string }>()
const h1 = ref<HTMLElement | null>(null)
// Fokus nach Seitenwechsel auf die Überschrift (Screenreader), ohne sichtbaren Rahmen
onMounted(() => {
  if (document.activeElement === document.body || document.activeElement?.closest('.sidenav, .tabs, .topbar')) {
    h1.value?.focus({ preventScroll: true })
  }
})
</script>

<template>
  <header class="page-header">
    <div>
      <div v-if="eyebrow" class="eyebrow">{{ eyebrow }}</div>
      <h1 ref="h1" tabindex="-1">{{ title }}</h1>
      <p v-if="subtitle" class="subtitle">{{ subtitle }}</p>
      <slot name="meta" />
    </div>
    <div v-if="$slots.default" class="page-header-actions"><slot /></div>
  </header>
</template>
