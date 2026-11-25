// Virtuelles Scrollen für grosse Tabellen (Fahrten, Tankvorgänge): Es werden nur die sichtbaren Zeilen plus
// Puffer gerendert; Platzhalter oben/unten halten die Gesamthöhe (Scrollbalken, Seitensprünge stimmen).
// Seite (window) scrollt wie bisher – keine verschachtelte Scrollfläche, Tastatur (Bild ↑/↓, Pos1/Ende, Tab)
// funktioniert unverändert. Zeilenhöhe wird an den gerenderten Zeilen gemessen (laufender Mittelwert über alle
// bisher gesehenen Zeilen → konvergiert, kein Pendeln); gerendert wird so, dass der sichtbare Bereich auch bei den
// kleinsten gemessenen Zeilen gefüllt ist.
// Unterhalb von `threshold` Zeilen wird alles gerendert (kleine Listen bleiben unverändert).
import { computed, onBeforeUnmount, onMounted, ref, shallowRef, toValue, watch, type MaybeRefOrGetter } from 'vue'

export interface VirtualOptions {
  /** angenommene Zeilenhöhe in px, bis gemessen wurde */
  estimate?: number
  /** zusätzliche Zeilen ober-/unterhalb des sichtbaren Bereichs */
  overscan?: number
  /** ab dieser Zeilenzahl virtualisieren */
  threshold?: number
}

export const VIRTUAL_DEFAULTS = { estimate: 48, overscan: 12, threshold: 150 } as const

/**
 * Zu rendernde Zeilen [start, end): Start aus der mittleren Zeilenhöhe `rowH` (Platzhalter oben = start · rowH),
 * Ende so, dass der Bereich bis `viewBottom` auch dann gefüllt ist, wenn alle Zeilen nur `minH` hoch sind.
 */
export function computeRange(
  n: number,
  rowH: number,
  viewTop: number,
  viewBottom: number,
  overscan: number,
  minH = rowH,
): { start: number; end: number } {
  if (n <= 0) return { start: 0, end: 0 }
  const h = Math.max(1, rowH)
  const hMin = Math.max(1, Math.min(minH, h))
  const start = Math.min(Math.max(0, Math.floor(Math.max(0, viewTop) / h) - overscan), Math.max(0, n - 1))
  const padTop = start * h
  const need = Math.ceil(Math.max(0, viewBottom - padTop) / hMin)
  const end = Math.min(n, Math.max(start + 1, start + need + overscan))
  return { start, end }
}

export function useVirtualRows<T>(rows: MaybeRefOrGetter<readonly T[]>, opts: VirtualOptions = {}) {
  const { estimate, overscan, threshold } = { ...VIRTUAL_DEFAULTS, ...opts }
  /** Element, das die Tabelle umschliesst (Bezug für die Position) */
  const el = ref<HTMLElement | null>(null)
  const rowH = ref<number>(estimate)
  const minH = ref<number>(estimate)
  /** gerenderter Bereich samt der dafür verwendeten Zeilenhöhe (Platzhalter passen immer zum Bereich) */
  const range = shallowRef({ start: 0, end: 0, h: estimate })
  const list = computed(() => toValue(rows))
  const enabled = computed(() => list.value.length > threshold)

  function update(): void {
    const n = list.value.length
    let next: { start: number; end: number }
    if (!enabled.value) next = { start: 0, end: n }
    else {
      const vh = (typeof window !== 'undefined' && window.innerHeight) || 800
      const top = el.value?.getBoundingClientRect().top ?? 0
      next = computeRange(n, rowH.value, -top, vh - top, overscan, minH.value)
    }
    const r = range.value
    if (next.start !== r.start || next.end !== r.end || (next.start > 0 && rowH.value !== r.h)) range.value = { ...next, h: rowH.value }
  }

  // gemessene Höhen je Zeile (aria-rowindex → px), begrenzt; Mittelwert/Minimum daraus
  const samples = new Map<number, number>()
  let sum = 0
  let min = Infinity
  const MAX_SAMPLES = 5000

  /** Höhen der gerenderten Zeilen erfassen (nach dem Rendern) und Schätzung nachführen. */
  function measure(): void {
    if (!enabled.value || !el.value) return
    for (const tr of el.value.querySelectorAll<HTMLElement>('tbody > tr[aria-rowindex]')) {
      const idx = Number(tr.getAttribute('aria-rowindex'))
      if (samples.has(idx)) continue
      const h = tr.getBoundingClientRect().height
      if (!(h > 0)) continue
      samples.set(idx, h)
      sum += h
      if (h < min) min = h
      if (samples.size > MAX_SAMPLES) {
        const [k, v] = samples.entries().next().value as [number, number]
        samples.delete(k)
        sum -= v
      }
    }
    if (samples.size < 5) return
    const avg = Math.round((sum / samples.size) * 4) / 4
    let changed = false
    if (Math.abs(avg - rowH.value) >= 0.5) {
      rowH.value = avg
      changed = true
    }
    if (Math.abs(min - minH.value) >= 0.5) {
      minH.value = min
      changed = true
    }
    // im nächsten Frame neu berechnen (nicht synchron im Render-Zyklus → keine Rückkopplung)
    if (changed) schedule()
  }

  function resetSamples(): void {
    samples.clear()
    sum = 0
    min = Infinity
  }

  let frame = 0
  const schedule = () => {
    if (frame) return
    frame = requestAnimationFrame(() => {
      frame = 0
      update()
    })
  }
  let width = 0
  const onResize = () => {
    // andere Breite → andere Zeilenumbrüche → neu messen
    if (window.innerWidth !== width) {
      width = window.innerWidth
      resetSamples()
    }
    schedule()
  }

  onMounted(() => {
    window.addEventListener('scroll', schedule, { passive: true })
    window.addEventListener('resize', onResize, { passive: true })
    width = window.innerWidth
    update()
  })
  onBeforeUnmount(() => {
    window.removeEventListener('scroll', schedule)
    window.removeEventListener('resize', onResize)
    if (frame) cancelAnimationFrame(frame)
  })
  // andere Liste (Filter/Suche): Indizes zeigen auf andere Zeilen → Messung neu beginnen
  watch(list, resetSamples)
  watch(() => [list.value, enabled.value, el.value], update, { immediate: true })
  watch(range, measure, { flush: 'post' })

  const items = computed(() => list.value.slice(range.value.start, range.value.end))
  return {
    el,
    items,
    rowH,
    enabled,
    start: computed(() => range.value.start),
    total: computed(() => list.value.length),
    padTop: computed(() => Math.round(range.value.start * range.value.h)),
    padBottom: computed(() => Math.max(0, Math.round((list.value.length - range.value.end) * range.value.h))),
    update,
  }
}
