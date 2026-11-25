<script setup lang="ts">
// Platzhalterzeile für virtuelles Scrollen. Höhe über das SVG-Attribut `height` (kein Inline-Style → CSP
// style-src 'self' ohne 'unsafe-inline'); für Screenreader verborgen.
defineProps<{ height: number; cols: number }>()
</script>

<template>
  <tr v-if="height > 0" class="vpad" aria-hidden="true">
    <td :colspan="cols"><svg class="vpad-svg" :height="height" width="1" focusable="false"></svg></td>
  </tr>
</template>
