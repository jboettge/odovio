// Asynchron berechneter Wert (z. B. Auswertung im Web Worker): neu bei geänderten Eingaben, veraltete Antworten
// werden verworfen (nur das Ergebnis der letzten Anfrage zählt).
import { ref, shallowRef, watch, type Ref, type ShallowRef } from 'vue'
import { userMessage } from '../lib/security'

export function useAsync<A, T>(args: () => A, run: (a: A) => Promise<T>, initial: T): { data: ShallowRef<T>; pending: Ref<boolean>; error: Ref<string | null> } {
  const data = shallowRef(initial) as ShallowRef<T>
  const pending = ref(false)
  const error = ref<string | null>(null)
  let seq = 0
  watch(
    args,
    async (a) => {
      const my = ++seq
      pending.value = true
      try {
        const r = await run(a)
        if (my !== seq) return
        data.value = r
        error.value = null
      } catch (e) {
        if (my === seq) error.value = userMessage(e)
      } finally {
        if (my === seq) pending.value = false
      }
    },
    { immediate: true },
  )
  return { data, pending, error }
}
