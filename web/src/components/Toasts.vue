<script setup lang="ts">
import { dismiss, toasts } from '../store/toasts'
import Icon from './Icon.vue'
</script>

<template>
  <div class="toasts" aria-live="polite" aria-atomic="false">
    <div v-for="t in toasts" :key="t.id" :class="['toast', `toast-${t.kind}`]" :role="t.kind === 'error' ? 'alert' : 'status'">
      <p>{{ t.text }}</p>
      <button type="button" class="btn btn-ghost btn-icon btn-sm" aria-label="Meldung schliessen" @click="dismiss(t.id)"><Icon name="x" size="sm" /></button>
    </div>
  </div>
</template>
