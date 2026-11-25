// Entprellte Eingabe (Suche/Filter): Berechnung erst nach einer Tipp-Pause, leeren sofort.
import { onBeforeUnmount, ref, watch, type Ref } from 'vue'

export const DEBOUNCE_MS = 200

export function useDebounced<T>(source: Ref<T>, ms = DEBOUNCE_MS): Ref<T> {
  const out = ref(source.value) as Ref<T>
  let t: ReturnType<typeof setTimeout> | undefined
  watch(source, (v) => {
    clearTimeout(t)
    if (v === '' || v === null) out.value = v
    else t = setTimeout(() => (out.value = v), ms)
  })
  onBeforeUnmount(() => clearTimeout(t))
  return out
}
