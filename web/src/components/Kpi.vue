<script setup lang="ts">
defineProps<{ label: string; value: string; sub?: string }>()
</script>

<template>
  <div class="kpi">
    <div class="kpi-label">{{ label }}</div>
    <div class="kpi-value">{{ value }}</div>
    <div v-if="sub" class="kpi-sub">{{ sub }}</div>
    <slot />
  </div>
</template>
