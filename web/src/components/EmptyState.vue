<script setup lang="ts">
import Icon from './Icon.vue'
defineProps<{ title: string; icon?: string }>()
</script>

<template>
  <div class="empty">
    <Icon v-if="icon" :name="icon" size="lg" />
    <h2>{{ title }}</h2>
    <slot />
  </div>
</template>
