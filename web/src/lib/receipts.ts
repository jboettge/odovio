// Belege im Web hinzufügen: Typ über Magic Bytes erkennen (wie der Server), andere Bildformate (PNG, WebP …)
// und zu grosse Fotos als JPEG neu kodieren, Prüfsumme (SHA-256) für die Metadaten berechnen.
import type { Attachment } from '../api/types'

export const MAX_RECEIPT_BYTES = 8 * 1024 * 1024
export const RECEIPT_ACCEPT = 'image/jpeg,image/png,image/webp,image/heic,image/heif,application/pdf,.heic,.heif'
/** Längste Bildkante beim Neukodieren (Beleg bleibt lesbar, Datei klein). */
const MAX_EDGE = 3000

export type ReceiptMime = Attachment['mime']

export interface PreparedReceipt {
  /** feste ID ab Auswahl (Wiederholen legt nichts doppelt an) */
  id: string
  name: string
  mime: ReceiptMime
  size: number
  sha256: string
  blob: Blob
  /** als JPEG neu kodiert (z. B. PNG-Bildschirmfoto) */
  converted: boolean
}

export class ReceiptError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'ReceiptError'
  }
}

/** Typ aus den ersten Bytes: JPEG FF D8 FF, PDF %PDF, HEIC/HEIF ISO-BMFF (ftyp + Marke), sonst sonstiges Bild. */
export function sniff(head: Uint8Array): ReceiptMime | 'image' | null {
  if (head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff) return 'image/jpeg'
  if (head[0] === 0x25 && head[1] === 0x50 && head[2] === 0x44 && head[3] === 0x46) return 'application/pdf'
  const ascii = (a: number, b: number) => String.fromCharCode(...head.slice(a, b))
  if (head.length >= 12 && ascii(4, 8) === 'ftyp') {
    return ['heic', 'heix', 'heim', 'heis', 'hevc', 'hevx', 'mif1', 'msf1'].includes(ascii(8, 12)) ? 'image/heic' : null
  }
  // PNG, GIF, WebP, BMP → im Browser dekodierbar, wird als JPEG gespeichert
  if (head[0] === 0x89 && ascii(1, 4) === 'PNG') return 'image'
  if (ascii(0, 3) === 'GIF') return 'image'
  if (ascii(0, 4) === 'RIFF' && ascii(8, 12) === 'WEBP') return 'image'
  if (ascii(0, 2) === 'BM') return 'image'
  return null
}

export function hex(buf: ArrayBuffer): string {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('')
}

export async function sha256(blob: Blob): Promise<string> {
  return hex(await crypto.subtle.digest('SHA-256', await blob.arrayBuffer()))
}

/** Bild als JPEG neu kodieren (längste Kante höchstens MAX_EDGE). */
async function toJpeg(file: Blob): Promise<Blob> {
  if (typeof createImageBitmap !== 'function') throw new ReceiptError('Dieses Bildformat kann der Browser nicht umwandeln – bitte JPEG oder PDF wählen.')
  let bmp: ImageBitmap
  try {
    bmp = await createImageBitmap(file)
  } catch {
    throw new ReceiptError('Bild konnte nicht gelesen werden – bitte JPEG oder PDF wählen.')
  }
  const scale = Math.min(1, MAX_EDGE / Math.max(bmp.width, bmp.height))
  const w = Math.max(1, Math.round(bmp.width * scale))
  const h = Math.max(1, Math.round(bmp.height * scale))
  const canvas = document.createElement('canvas')
  canvas.width = w
  canvas.height = h
  const ctx = canvas.getContext('2d')
  if (!ctx) throw new ReceiptError('Bild konnte nicht umgewandelt werden.')
  ctx.fillStyle = '#fff' // Transparenz (PNG) auf Weiss
  ctx.fillRect(0, 0, w, h)
  ctx.drawImage(bmp, 0, 0, w, h)
  bmp.close()
  const out = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, 'image/jpeg', 0.85))
  if (!out) throw new ReceiptError('Bild konnte nicht umgewandelt werden.')
  return out
}

/** Datei prüfen und vorbereiten. Fehler als ReceiptError mit deutscher Meldung. */
export async function prepareReceipt(file: File, id: string): Promise<PreparedReceipt> {
  if (!file.size) throw new ReceiptError(`«${file.name}» ist leer.`)
  const kind = sniff(new Uint8Array(await file.slice(0, 16).arrayBuffer()))
  if (!kind) throw new ReceiptError(`«${file.name}»: nur Fotos (JPEG, HEIC, PNG …) oder PDF.`)
  let blob: Blob = file
  let mime: ReceiptMime
  let converted = false
  if (kind === 'image' || (kind === 'image/jpeg' && file.size > MAX_RECEIPT_BYTES)) {
    blob = await toJpeg(file)
    mime = 'image/jpeg'
    converted = kind === 'image'
  } else {
    mime = kind
  }
  if (blob.size > MAX_RECEIPT_BYTES) {
    throw new ReceiptError(`«${file.name}» ist zu gross (höchstens ${MAX_RECEIPT_BYTES / 1024 / 1024} MB).`)
  }
  return { id, name: file.name, mime, size: blob.size, sha256: await sha256(blob), blob, converted }
}
