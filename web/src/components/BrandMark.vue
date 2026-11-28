<script setup lang="ts">
// odovio-Bildmarke «Doppelanzeige» (Tacho + Tankuhr, docs/brand/odovio-mark.svg). Linien in currentColor,
// Nadeln im Marken-Akzent, Aussparung der Tankuhr in der Flächenfarbe → passt sich hell/dunkel an.
withDefaults(defineProps<{ size?: number; label?: string }>(), { size: 32, label: undefined })
</script>

<template>
  <svg
    class="brand-mark"
    :width="Math.round(size * 1.1)"
    :height="size"
    viewBox="0 0 220 200"
    :role="label ? 'img' : undefined"
    :aria-label="label"
    :aria-hidden="label ? undefined : 'true'"
    focusable="false"
  >
    <path d="M42.75 145.25 A64 64 0 1 1 133.25 145.25" fill="none" stroke="currentColor" stroke-opacity="0.18" stroke-width="13" stroke-linecap="round" />
    <path d="M42.75 145.25 A64 64 0 0 1 120 44.57" fill="none" stroke="currentColor" stroke-width="13" stroke-linecap="round" />
    <line x1="88" y1="100" x2="111" y2="60.16" class="brand-needle" stroke-width="8" stroke-linecap="round" />
    <circle cx="88" cy="100" r="10" fill="currentColor" />
    <circle cx="160" cy="118" r="46" class="brand-knockout" />
    <circle cx="160" cy="118" r="45" fill="none" stroke="currentColor" stroke-width="4" />
    <path d="M128.05 106.37 A34 34 0 0 1 177 88.56" fill="none" stroke="currentColor" stroke-width="10" stroke-linecap="round" />
    <line x1="160" y1="118" x2="174" y2="93.75" class="brand-needle" stroke-width="7" stroke-linecap="round" />
    <circle cx="160" cy="118" r="7" fill="currentColor" />
  </svg>
</template>
