<script setup lang="ts">
withDefaults(defineProps<{ text?: string }>(), { text: 'Wird geladen …' })
</script>

<template>
  <div class="loading" role="status" aria-live="polite"><span class="spinner" aria-hidden="true"></span>{{ text }}</div>
</template>
