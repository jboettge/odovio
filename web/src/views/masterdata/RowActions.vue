<script setup lang="ts">
import Icon from '../../components/Icon.vue'
defineProps<{ label: string; writable: boolean; deleted?: boolean }>()
const emit = defineEmits<{ edit: []; history: []; storno: [] }>()
</script>

<template>
  <td class="actions">
    <button type="button" class="btn btn-ghost btn-icon btn-sm" :aria-label="`Verlauf ${label}`" @click="emit('history')"><Icon name="history" size="sm" /></button>
    <template v-if="writable && !deleted">
      <button type="button" class="btn btn-ghost btn-icon btn-sm" :aria-label="`${label} bearbeiten`" @click="emit('edit')"><Icon name="edit" size="sm" /></button>
      <button type="button" class="btn btn-ghost btn-icon btn-sm" :aria-label="`${label} stornieren`" @click="emit('storno')"><Icon name="ban" size="sm" /></button>
    </template>
  </td>
</template>
