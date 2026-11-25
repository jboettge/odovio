import { onBeforeUnmount, onMounted, ref, type Ref } from 'vue'

/** Breite eines Elements (ResizeObserver) – Diagramme rendern in echten Pixeln. */
export function useWidth(el: Ref<HTMLElement | null>, fallback = 640): Ref<number> {
  const width = ref(fallback)
  let ro: ResizeObserver | null = null
  onMounted(() => {
    if (!el.value) return
    width.value = el.value.clientWidth || fallback
    if (typeof ResizeObserver !== 'undefined') {
      ro = new ResizeObserver((entries) => {
        const w = entries[0]?.contentRect.width
        if (w && Math.abs(w - width.value) > 1) width.value = w
      })
      ro.observe(el.value)
    }
  })
  onBeforeUnmount(() => ro?.disconnect())
  return width
}
