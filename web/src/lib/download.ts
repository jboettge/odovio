// Dateien (PDF/CSV/Belege) per Bearer abrufen und als Blob-URL speichern/anzeigen.
import { sanitizeFilename, type BlobResult } from '../api/client'

export function saveBlob(res: BlobResult, fallbackName: string): void {
  const url = URL.createObjectURL(res.blob)
  const a = document.createElement('a')
  a.href = url
  a.download = sanitizeFilename(res.filename) ?? fallbackName
  a.rel = 'noopener'
  document.body.appendChild(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 60_000)
}

/** Blob in neuem Tab öffnen (gleiche Origin, keine Tokens in der URL). */
export function openBlob(res: BlobResult): void {
  const url = URL.createObjectURL(res.blob)
  window.open(url, '_blank', 'noopener')
  setTimeout(() => URL.revokeObjectURL(url), 120_000)
}
