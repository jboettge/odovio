<script setup lang="ts">
// Anteil als Balken (SVG statt Inline-Style – CSP).
import { computed } from 'vue'
const props = defineProps<{ value: number; max?: number; label: string }>()
const pctValue = computed(() => {
  const m = props.max ?? 100
  return m > 0 ? Math.max(0, Math.min(100, (props.value / m) * 100)) : 0
})
</script>

<template>
  <div class="meter" role="meter" :aria-valuenow="Math.round(pctValue)" aria-valuemin="0" aria-valuemax="100" :aria-label="label">
    <svg viewBox="0 0 100 8" preserveAspectRatio="none" aria-hidden="true"><rect class="meter-fill" x="0" y="0" :width="pctValue" height="8" /></svg>
  </div>
</template>
