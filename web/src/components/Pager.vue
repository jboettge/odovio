<script setup lang="ts">
// Seitenwahl für Listen im Client (50/100/200 je Seite).
import Icon from './Icon.vue'
import { PAGE_SIZES } from '../use/pager'

const props = withDefaults(defineProps<{ total: number; label?: string }>(), { label: 'Seiten' })
const page = defineModel<number>('page', { required: true })
const size = defineModel<number>('size', { required: true })
const pages = () => Math.max(1, Math.ceil(props.total / size.value))
</script>

<template>
  <nav v-if="total > PAGE_SIZES[0]" class="pager" :aria-label="label">
    <span class="muted small">{{ (page - 1) * size + 1 }}–{{ Math.min(total, page * size) }} von {{ total }}</span>
    <span class="row">
      <button type="button" class="btn btn-sm btn-icon" :disabled="page <= 1" aria-label="Erste Seite" @click="page = 1"><Icon name="chevronsLeft" size="sm" /></button>
      <button type="button" class="btn btn-sm btn-icon" :disabled="page <= 1" aria-label="Vorherige Seite" @click="page = page - 1"><Icon name="chevronLeft" size="sm" /></button>
      <span class="small nowrap" aria-live="polite">Seite {{ page }} von {{ pages() }}</span>
      <button type="button" class="btn btn-sm btn-icon" :disabled="page >= pages()" aria-label="Nächste Seite" @click="page = page + 1"><Icon name="chevronRight" size="sm" /></button>
      <button type="button" class="btn btn-sm btn-icon" :disabled="page >= pages()" aria-label="Letzte Seite" @click="page = pages()"><Icon name="chevronsRight" size="sm" /></button>
    </span>
    <label class="row small">Pro Seite
      <select v-model.number="size" class="select select-sm">
        <option v-for="s in PAGE_SIZES" :key="s" :value="s">{{ s }}</option>
      </select>
    </label>
  </nav>
</template>
