<script setup lang="ts">
// Eigene Strichsymbole (gebündelt, keine externen Ressourcen).
import { computed } from 'vue'

const PATHS: Record<string, string[]> = {
  car: ['M5 17h14', 'M3 17v-4l2-5a2 2 0 0 1 2-1.4h10A2 2 0 0 1 19 8l2 5v4a1 1 0 0 1-1 1h-1', 'M5 18H4a1 1 0 0 1-1-1', 'M7.5 17a1.5 1.5 0 1 0 0 .01', 'M16.5 17a1.5 1.5 0 1 0 0 .01', 'M4 12h16'],
  home: ['M3 11l9-7 9 7', 'M5 10v10h14V10', 'M10 20v-6h4v6'],
  grid: ['M4 4h7v7H4z', 'M13 4h7v7h-7z', 'M4 13h7v7H4z', 'M13 13h7v7h-7z'],
  route: ['M6 19a2 2 0 1 0 0-.01', 'M18 5a2 2 0 1 0 0-.01', 'M6 17V9a3 3 0 0 1 3-3h1', 'M18 7v8a3 3 0 0 1-3 3h-1'],
  fuel: ['M4 20V5a1 1 0 0 1 1-1h8a1 1 0 0 1 1 1v15', 'M3 20h12', 'M6 8h6', 'M14 10h2a2 2 0 0 1 2 2v4a1.5 1.5 0 0 0 3 0V8l-3-3'],
  wrench: ['M14.7 6.3a4 4 0 0 0-5.4 5.2L4 16.8V20h3.2l5.3-5.3a4 4 0 0 0 5.2-5.4l-2.4 2.4-2.6-.4-.4-2.6z'],
  gauge: ['M12 13l3-3', 'M4.6 18a9 9 0 1 1 14.8 0', 'M12 13a1 1 0 1 0 0 .01'],
  file: ['M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z', 'M14 3v5h5', 'M9 13h6', 'M9 17h6'],
  lock: ['M6 11h12v9H6z', 'M8 11V8a4 4 0 0 1 8 0v3'],
  shield: ['M12 3l8 3v6c0 4.5-3.4 8-8 9-4.6-1-8-4.5-8-9V6z', 'M9 12l2 2 4-4'],
  users: ['M9 11a3.5 3.5 0 1 0 0-.01', 'M3 20a6 6 0 0 1 12 0', 'M16 4.5a3.5 3.5 0 0 1 0 6.8', 'M18 14a6 6 0 0 1 3 6'],
  user: ['M12 12a4 4 0 1 0 0-.01', 'M5 20a7 7 0 0 1 14 0'],
  database: ['M4 6c0-1.7 3.6-3 8-3s8 1.3 8 3-3.6 3-8 3-8-1.3-8-3z', 'M4 6v12c0 1.7 3.6 3 8 3s8-1.3 8-3V6', 'M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3'],
  activity: ['M3 12h4l3-8 4 16 3-8h4'],
  check: ['M5 12l5 5 9-10'],
  checkCircle: ['M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z', 'M8 12l3 3 5-6'],
  xCircle: ['M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z', 'M9 9l6 6', 'M15 9l-6 6'],
  x: ['M6 6l12 12', 'M18 6L6 18'],
  alert: ['M12 4l9 16H3z', 'M12 10v4', 'M12 17.5v.01'],
  info: ['M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z', 'M12 11v5', 'M12 8v.01'],
  help: ['M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z', 'M9.5 9.5a2.5 2.5 0 1 1 3.5 2.3c-.6.3-1 .9-1 1.6v.6', 'M12 17v.01'],
  logout: ['M15 4h3a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-3', 'M10 16l-4-4 4-4', 'M6 12h10'],
  download: ['M12 4v11', 'M7 10l5 5 5-5', 'M5 20h14'],
  history: ['M3 12a9 9 0 1 0 3-6.7', 'M3 4v4h4', 'M12 8v4l3 2'],
  search: ['M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14z', 'M20 20l-4-4'],
  plus: ['M12 5v14', 'M5 12h14'],
  edit: ['M4 20h4L19 9l-4-4L4 16z', 'M13.5 6.5l4 4'],
  trash: ['M4 7h16', 'M9 7V4h6v3', 'M6 7l1 13h10l1-13'],
  ban: ['M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z', 'M6 6l12 12'],
  chevronRight: ['M9 6l6 6-6 6'],
  chevronDown: ['M6 9l6 6 6-6'],
  chevronLeft: ['M15 6l-6 6 6 6'],
  chevronsLeft: ['M17 6l-6 6 6 6', 'M11 6l-6 6 6 6'],
  chevronsRight: ['M7 6l6 6-6 6', 'M13 6l6 6-6 6'],
  calendar: ['M4 6h16v14H4z', 'M4 10h16', 'M8 3v4', 'M16 3v4'],
  pin: ['M12 21s-6-5.6-6-11a6 6 0 0 1 12 0c0 5.4-6 11-6 11z', 'M12 10a2 2 0 1 0 0-.01'],
  briefcase: ['M4 8h16v11H4z', 'M9 8V5h6v3', 'M4 13h16'],
  percent: ['M19 5L5 19', 'M7 8a1 1 0 1 0 0-.01', 'M17 16a1 1 0 1 0 0-.01'],
  box: ['M4 8l8-4 8 4v8l-8 4-8-4z', 'M4 8l8 4 8-4', 'M12 12v8'],
  rules: ['M4 6h10', 'M4 12h16', 'M4 18h7', 'M18 4v4', 'M16 6h4'],
  refresh: ['M20 11a8 8 0 0 0-14.5-4.5L4 8', 'M4 4v4h4', 'M4 13a8 8 0 0 0 14.5 4.5L20 16', 'M20 20v-4h-4'],
  eye: ['M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z', 'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z'],
  eyeOff: ['M3 3l18 18', 'M10.6 5.1A10 10 0 0 1 12 5c6.5 0 10 7 10 7a17 17 0 0 1-3 3.9', 'M6.6 6.6A17 17 0 0 0 2 12s3.5 7 10 7a9.6 9.6 0 0 0 5.4-1.6', 'M9.9 9.9a3 3 0 0 0 4.2 4.2'],
  image: ['M4 5h16v14H4z', 'M4 16l5-5 4 4 3-3 4 4', 'M15 9a1 1 0 1 0 0-.01'],
}

const props = withDefaults(defineProps<{ name: string; size?: 'sm' | 'md' | 'lg'; label?: string }>(), { size: 'md', label: undefined })
const paths = computed(() => PATHS[props.name] ?? PATHS.info!)
const cls = computed(() => ['icon', props.size === 'sm' ? 'icon-sm' : props.size === 'lg' ? 'icon-lg' : ''])
</script>

<template>
  <svg :class="cls" viewBox="0 0 24 24" :aria-hidden="label ? undefined : 'true'" :role="label ? 'img' : undefined" :aria-label="label" focusable="false">
    <path v-for="(d, i) in paths" :key="i" :d="d" />
  </svg>
</template>
