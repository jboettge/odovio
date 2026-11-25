/* eslint-disable vue/one-component-per-file -- Test-Hilfskomponenten */
// Grosse Listen: virtuelles Scrollen (Bereichsberechnung, ARIA), Seitenaufteilung, Entprellung, Ausdünnen von
// Diagrammreihen, begrenzter Beleg-Cache mit Freigabe der blob:-URLs.
import { describe, expect, it, vi } from 'vitest'
import { createApp, defineComponent, h, nextTick, ref } from 'vue'
import { computeRange } from '../../src/use/virtualRows'
import { usePager } from '../../src/use/pager'
import { useDebounced } from '../../src/use/debounced'
import { downsample } from '../../src/lib/downsample'
import { BlobCache } from '../../src/lib/blobCache'
import LineChart from '../../src/components/LineChart.vue'

vi.mock('../../src/store/data', () => ({ onDataReset: vi.fn() }))

function mount<T>(setup: () => T): { result: T; unmount: () => void } {
  let result!: T
  const el = document.createElement('div')
  const app = createApp(defineComponent({ setup: () => ((result = setup()), () => h('div')) }))
  app.mount(el)
  return { result, unmount: () => app.unmount() }
}

describe('computeRange', () => {
  it('rendert sichtbaren Bereich + Puffer, Platzhalter passen zur Zeilenhöhe', () => {
    expect(computeRange(30_000, 50, 0, 900, 10)).toEqual({ start: 0, end: 28 })
    expect(computeRange(30_000, 50, 50_000, 50_900, 10)).toEqual({ start: 990, end: 1028 })
    expect(computeRange(30_000, 50, 1e9, 1e9 + 900, 10)).toMatchObject({ end: 30_000 })
    expect(computeRange(0, 50, 0, 900, 10)).toEqual({ start: 0, end: 0 })
  })

  it('bei kleineren Zeilen als dem Mittel wird bis zum unteren Rand aufgefüllt', () => {
    const r = computeRange(30_000, 90, 90_000, 90_900, 10, 45)
    // Platzhalter oben = start · 90; mit 45 px hohen Zeilen müssen sie bis 90'900 reichen
    expect(r.start * 90 + (r.end - r.start) * 45).toBeGreaterThanOrEqual(90_900)
    expect(r.end - r.start).toBeLessThan(200)
  })
})

describe('usePager', () => {
  it('Seiten, Grenzen, Zurücksetzen bei Filter', async () => {
    const rows = ref(Array.from({ length: 230 }, (_, i) => i))
    const filter = ref('')
    const { result: p, unmount } = mount(() => usePager(rows, { resetOn: [filter] }))
    expect(p.items).toHaveLength(50)
    expect(p.pages).toBe(5)
    p.page = 5
    expect(p.items).toEqual([200, 201, 202, 203, 204, 205, 206, 207, 208, 209, 210, 211, 212, 213, 214, 215, 216, 217, 218, 219, 220, 221, 222, 223, 224, 225, 226, 227, 228, 229])
    expect([p.from, p.to]).toEqual([201, 230])
    rows.value = rows.value.slice(0, 120)
    await nextTick()
    expect(p.page).toBe(3)
    p.size = 100
    await nextTick()
    expect(p.page).toBe(1)
    p.page = 2
    filter.value = 'x'
    await nextTick()
    expect(p.page).toBe(1)
    unmount()
  })
})

describe('useDebounced', () => {
  it('übernimmt erst nach der Pause, Leeren sofort', async () => {
    vi.useFakeTimers()
    const src = ref('')
    const { result: d, unmount } = mount(() => useDebounced(src, 200))
    src.value = 'a'
    await nextTick()
    src.value = 'ab'
    await nextTick()
    vi.advanceTimersByTime(199)
    expect(d.value).toBe('')
    vi.advanceTimersByTime(1)
    expect(d.value).toBe('ab')
    src.value = ''
    await nextTick()
    expect(d.value).toBe('')
    unmount()
    vi.useRealTimers()
  })
})

describe('downsample (LTTB)', () => {
  it('höchstens max Punkte, erster/letzter und Ausreisser bleiben', () => {
    const pts = Array.from({ length: 5000 }, (_, i) => ({ i, v: i === 2500 ? 1000 : Math.sin(i / 50) }))
    const out = downsample(pts, 100, (p) => p.v)
    expect(out).toHaveLength(100)
    expect(out[0]!.i).toBe(0)
    expect(out.at(-1)!.i).toBe(4999)
    expect(out.some((p) => p.i === 2500)).toBe(true)
    expect(downsample(pts.slice(0, 10), 100, (p) => p.v)).toHaveLength(10)
  })

  it('LineChart zeichnet bei 5000 Werten nur verdichtete Punkte; Datentabelle erst beim Öffnen', async () => {
    const el = document.createElement('div')
    document.body.appendChild(el)
    const points = Array.from({ length: 5000 }, (_, i) => ({ label: `P${i}`, value: 5 + Math.sin(i / 30) }))
    const app = createApp({ render: () => h(LineChart, { title: 'Verbrauch', seriesLabel: 'Verbrauch', points, format: (v: number) => String(v) }) })
    app.mount(el)
    await nextTick()
    const dots = el.querySelectorAll('circle.series-dot').length
    expect(dots).toBeGreaterThan(10)
    expect(dots).toBeLessThanOrEqual(400)
    expect(el.textContent).toContain('verdichtet')
    expect(el.querySelectorAll('.data-table tbody tr')).toHaveLength(0)
    const details = el.querySelector('details')!
    details.open = true
    details.dispatchEvent(new Event('toggle'))
    await nextTick()
    expect(el.querySelectorAll('.data-table tbody tr')).toHaveLength(50)
    expect(el.querySelectorAll('[style]')).toHaveLength(0)
    app.unmount()
    el.remove()
  })
})

describe('BlobCache', () => {
  const blob = (n: number) => new Blob([new Uint8Array(n)])
  it('LRU nach Anzahl und Bytes; verdrängte Object-URLs werden freigegeben', () => {
    const revoked: string[] = []
    const c = new BlobCache(3, 1000, (u) => revoked.push(u))
    const put = (k: string, n = 10) => c.set(k, { result: { blob: blob(n), filename: null, contentType: 'image/jpeg' }, url: `blob:${k}` })
    put('a')
    put('b')
    put('c')
    c.get('a') // a zuletzt verwendet
    put('d')
    expect(revoked).toEqual(['blob:b'])
    expect(c.get('b')).toBeUndefined()
    put('big', 990)
    expect(c.totalBytes).toBeLessThanOrEqual(1000)
    expect(revoked).toContain('blob:c')
    c.clear()
    expect(c.size).toBe(0)
    expect(revoked).toEqual(expect.arrayContaining(['blob:a', 'blob:d', 'blob:big']))
  })
})
