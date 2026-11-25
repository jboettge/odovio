<script setup lang="ts">
// Gemeinsamer Bearbeiten-Dialog der Stammdaten.
import Modal from '../../components/Modal.vue'
import AlertBox from '../../components/AlertBox.vue'

defineProps<{ open: boolean; title: string; busy: boolean; error: string | null }>()
const emit = defineEmits<{ close: []; save: [] }>()
</script>

<template>
  <Modal :open="open" :title="title" wide @close="emit('close')">
    <form id="editor-form" novalidate @submit.prevent="emit('save')">
      <div class="form-grid"><slot /></div>
      <AlertBox v-if="error" kind="danger" live class="mt-2">{{ error }}</AlertBox>
    </form>
    <template #footer>
      <button type="button" class="btn" @click="emit('close')">Abbrechen</button>
      <button type="submit" form="editor-form" class="btn btn-primary" :disabled="busy">{{ busy ? 'Wird gespeichert …' : 'Speichern' }}</button>
    </template>
  </Modal>
</template>
