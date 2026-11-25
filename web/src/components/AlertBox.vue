<script setup lang="ts">
import { computed } from 'vue'
import Icon from './Icon.vue'

const props = withDefaults(defineProps<{ kind?: 'info' | 'ok' | 'warn' | 'danger'; title?: string; live?: boolean }>(), {
  kind: 'info',
  title: undefined,
  live: false,
})
const icon = computed(() => ({ info: 'info', ok: 'checkCircle', warn: 'alert', danger: 'xCircle' })[props.kind])
</script>

<template>
  <div :class="['alert', `alert-${kind}`]" :role="live ? (kind === 'danger' ? 'alert' : 'status') : undefined">
    <Icon :name="icon" class="alert-icon" />
    <div class="alert-body">
      <div v-if="title" class="alert-title">{{ title }}</div>
      <slot />
    </div>
  </div>
</template>
