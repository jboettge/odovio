// Asynchron berechneter oder geladener Wert (Auswertung im Web Worker, Server-Abfrage): neu bei geänderten
// Eingaben, veraltete Antworten werden verworfen (nur das Ergebnis der letzten Anfrage zählt). Die vorherige
// Anfrage wird zusätzlich per AbortSignal abgebrochen (bei Seitenwechsel ebenso). `reload()` lädt erneut
// (z. B. «Erneut versuchen»).
import { getCurrentScope, onScopeDispose, ref, shallowRef, watch, type Ref, type ShallowRef } from 'vue'
import { isAbort } from '../api/client'
import { userMessage } from '../lib/security'

export interface AsyncValue<T> {
  data: ShallowRef<T>
  pending: Ref<boolean>
  error: Ref<string | null>
  /** Fehler der letzten Anfrage (z. B. für Statusabfragen wie 404) */
  failure: ShallowRef<unknown>
  reload: () => Promise<void>
}

export function useAsync<A, T>(
  args: () => A,
  run: (a: A, signal: AbortSignal) => Promise<T>,
  initial: T,
  opts: { resetOnError?: boolean } = {},
): AsyncValue<T> {
  const data = shallowRef(initial) as ShallowRef<T>
  const pending = ref(false)
  const error = ref<string | null>(null)
  const failure = shallowRef<unknown>(null)
  let seq = 0
  let ctrl: AbortController | null = null

  async function exec(a: A): Promise<void> {
    const my = ++seq
    ctrl?.abort()
    const c = (ctrl = new AbortController())
    pending.value = true
    try {
      const r = await run(a, c.signal)
      if (my !== seq) return
      data.value = r
      error.value = null
      failure.value = null
    } catch (e) {
      if (my !== seq || isAbort(e)) return
      if (opts.resetOnError) data.value = initial
      failure.value = e
      error.value = userMessage(e)
    } finally {
      if (my === seq) {
        pending.value = false
        ctrl = null
      }
    }
  }

  watch(args, (a) => void exec(a), { immediate: true })
  if (getCurrentScope()) {
    onScopeDispose(() => {
      seq++
      ctrl?.abort()
    })
  }
  return { data, pending, error, failure, reload: () => exec(args()) }
}
