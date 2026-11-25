<script setup lang="ts">
import { computed } from 'vue'
import type { TripStatus } from '../api/types'
import { STATUS_LABELS } from '../lib/labels'
import Icon from './Icon.vue'
const props = defineProps<{ status: TripStatus }>()
const cls = computed(() => ({ draft: 'badge-warn', suggested: 'badge-warn', confirmed: 'badge-ok', locked: 'badge-info' })[props.status] ?? '')
</script>

<template>
  <span :class="['badge', cls]"><Icon v-if="status === 'locked'" name="lock" size="sm" />{{ STATUS_LABELS[status] ?? status }}</span>
</template>
