// Sicherheits-Hilfen: Links aus Daten, verständliche Fehlertexte ohne technische Details.
import { ApiError, isAbort } from '../api/client'

/** Nur https:-Links oder relative Pfade derselben App zulassen; sonst null (als Text anzeigen). */
export function safeHref(v: unknown): string | null {
  if (typeof v !== 'string') return null
  const s = v.trim()
  if (s.startsWith('/') && !s.startsWith('//') && !s.startsWith('/\\')) return s
  try {
    const u = new URL(s)
    return u.protocol === 'https:' ? u.href : null
  } catch {
    return null
  }
}

/** Nutzerfreundliche Meldung: API-Fehler mit Server-Detail, alles andere generisch (kein Stacktrace). */
export function userMessage(e: unknown): string {
  if (e instanceof ApiError) return e.message
  if (isAbort(e)) return 'Anfrage abgebrochen.'
  if (e instanceof Error && e.name === 'SyncRejected') return e.message
  return 'Unerwarteter Fehler – bitte Seite neu laden und erneut versuchen.'
}
