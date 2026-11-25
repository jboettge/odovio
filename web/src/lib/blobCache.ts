// Begrenzter Speicher für Belege (Blob + Object-URL), damit wiederholtes Öffnen nicht neu lädt.
// LRU nach Anzahl und Bytes; verdrängte Einträge geben ihre blob:-URL frei (URL.revokeObjectURL).
// Nur im Speicher; wird beim Mandantenwechsel/Abmelden geleert (Datenschutz).
import type { BlobResult } from '../api/client'
import { onDataReset } from '../store/data'

export interface CachedBlob {
  result: BlobResult
  /** Object-URL für die Anzeige (nur für darstellbare Bilder) */
  url: string | null
}

export class BlobCache {
  private readonly map = new Map<string, CachedBlob>()
  private bytes = 0

  constructor(
    readonly maxEntries = 24,
    readonly maxBytes = 20 * 1024 * 1024,
    private readonly revoke: (url: string) => void = (u) => URL.revokeObjectURL(u),
  ) {}

  get size(): number {
    return this.map.size
  }

  get totalBytes(): number {
    return this.bytes
  }

  get(key: string): CachedBlob | undefined {
    const hit = this.map.get(key)
    if (hit) {
      // zuletzt verwendet ans Ende
      this.map.delete(key)
      this.map.set(key, hit)
    }
    return hit
  }

  set(key: string, entry: CachedBlob): CachedBlob {
    this.delete(key)
    this.map.set(key, entry)
    this.bytes += entry.result.blob.size
    while (this.map.size > this.maxEntries || (this.bytes > this.maxBytes && this.map.size > 1)) {
      const oldest = this.map.keys().next().value as string
      this.delete(oldest)
    }
    return entry
  }

  delete(key: string): void {
    const e = this.map.get(key)
    if (!e) return
    this.map.delete(key)
    this.bytes -= e.result.blob.size
    if (e.url) this.revoke(e.url)
  }

  clear(): void {
    for (const k of [...this.map.keys()]) this.delete(k)
  }
}

export const blobCache = new BlobCache()
onDataReset(() => blobCache.clear())
