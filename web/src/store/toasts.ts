// Kurze Meldungen (aria-live) für Erfolg/Fehler.
import { reactive } from 'vue'

export interface Toast {
  id: number
  kind: 'ok' | 'error' | 'info'
  text: string
}

export const toasts = reactive<Toast[]>([])
let next = 1

export function notify(text: string, kind: Toast['kind'] = 'ok', ms = 5000): void {
  const id = next++
  toasts.push({ id, kind, text })
  if (ms > 0) setTimeout(() => dismiss(id), ms)
}

export function dismiss(id: number): void {
  const i = toasts.findIndex((t) => t.id === id)
  if (i >= 0) toasts.splice(i, 1)
}

export { userMessage as errorText } from '../lib/security'
