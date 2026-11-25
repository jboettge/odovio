<script setup lang="ts">
import type { TripCategory } from '../api/types'
import { CATEGORY_LABELS } from '../lib/labels'
defineProps<{ category: TripCategory }>()
</script>

<template>
  <span :class="['badge', `cat-${category}`]">{{ CATEGORY_LABELS[category] ?? category }}</span>
</template>
