<script setup lang="ts">
// Natives <dialog>: Fokusfalle, Esc zum Schliessen, Fokus-Rückgabe durch den Browser.
import { nextTick, onBeforeUnmount, onMounted, ref, useId, watch } from 'vue'
import Icon from './Icon.vue'

const props = withDefaults(defineProps<{ open: boolean; title: string; variant?: 'modal' | 'panel'; wide?: boolean }>(), {
  variant: 'modal',
  wide: false,
})
const emit = defineEmits<{ close: [] }>()
const dlg = ref<HTMLDialogElement | null>(null)
const titleId = useId()
let opener: Element | null = null

function sync(open: boolean) {
  const d = dlg.value
  if (!d) return
  if (open && !d.open) {
    opener = document.activeElement
    d.showModal()
    void nextTick(() => {
      const first = d.querySelector<HTMLElement>('[autofocus], .dialog-body input:not([type=hidden]), .dialog-body select, .dialog-body textarea, .dialog-body button, .dialog-foot button')
      first?.focus()
    })
  } else if (!open && d.open) {
    d.close()
    if (opener instanceof HTMLElement && document.contains(opener)) opener.focus()
  }
}

watch(() => props.open, sync)
onMounted(() => sync(props.open))
onBeforeUnmount(() => dlg.value?.open && dlg.value.close())

function onCancel(e: Event) {
  e.preventDefault()
  emit('close')
}
function onBackdrop(e: MouseEvent) {
  if (e.target === dlg.value) emit('close')
}
</script>

<template>
  <dialog ref="dlg" :class="[variant, wide ? 'modal-wide' : '']" :aria-labelledby="titleId" @cancel="onCancel" @click="onBackdrop">
    <div class="dialog-inner">
      <div class="dialog-head">
        <h2 :id="titleId">{{ title }}</h2>
        <button type="button" class="btn btn-ghost btn-icon" aria-label="Schliessen" @click="emit('close')"><Icon name="x" /></button>
      </div>
      <div class="dialog-body"><slot /></div>
      <div v-if="$slots.footer" class="dialog-foot"><slot name="footer" /></div>
    </div>
  </dialog>
</template>
