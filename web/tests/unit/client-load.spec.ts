// Lastschutz im API-Client: begrenzte Parallelität, zusammengelegte GETs, Abbruch, Wiederholung nur für GET 502/503/504.
import { describe, expect, it, vi } from 'vitest'
import { ApiClient, ApiError, Limiter, isAbort, type ClientOptions, type TokenProvider } from '../../src/api/client'

const tokens = (): TokenProvider => ({ getToken: vi.fn(async () => 't'), refresh: vi.fn(async () => 't2'), onUnauthorized: vi.fn() })
const json = (status: number, body: unknown = {}, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...headers } })

/** fetch, dessen Antworten der Test einzeln freigibt; respektiert AbortSignal. */
function controlledFetch() {
  const calls: { url: string; init: RequestInit; resolve: (r: Response) => void }[] = []
  const fn = vi.fn(
    (url: string, init: RequestInit) =>
      new Promise<Response>((resolve, reject) => {
        calls.push({ url, init, resolve })
        init.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')))
      }),
  )
  return { fn, calls }
}
const tick = () => new Promise((r) => setTimeout(r, 0))
const client = (f: unknown, opts: ClientOptions = {}) => new ApiClient(tokens(), '', f as typeof fetch, opts)

describe('Limiter', () => {
  it('führt höchstens max Aufträge gleichzeitig aus, Rest wartet in Reihenfolge', async () => {
    const l = new Limiter(2)
    let running = 0
    let peak = 0
    const order: number[] = []
    const job = (i: number) => async () => {
      running++
      peak = Math.max(peak, running)
      await tick()
      order.push(i)
      running--
      return i
    }
    const res = await Promise.all([1, 2, 3, 4, 5].map((i) => l.run(job(i))))
    expect(res).toEqual([1, 2, 3, 4, 5])
    expect(peak).toBe(2)
    expect(order).toEqual([1, 2, 3, 4, 5])
  })

  it('wartender Auftrag ist abbrechbar und belegt keinen Platz', async () => {
    const l = new Limiter(1)
    let release!: () => void
    const first = l.run(() => new Promise<void>((r) => (release = r)))
    const ctrl = new AbortController()
    const second = l.run(async () => 'nie', ctrl.signal)
    expect(l.waiting).toBe(1)
    ctrl.abort()
    await expect(second).rejects.toSatisfy(isAbort)
    expect(l.waiting).toBe(0)
    release()
    await first
    expect(l.running).toBe(0)
  })
})

describe('ApiClient unter Last', () => {
  it('höchstens 4 parallele Anfragen', async () => {
    const f = controlledFetch()
    const c = client(f.fn)
    const ps = Array.from({ length: 10 }, (_, i) => c.get(`/x/${i}`))
    await tick()
    expect(f.calls).toHaveLength(4)
    expect(c.load.waiting).toBe(6)
    for (let done = 0; done < 10; done++) {
      await tick()
      f.calls[done]!.resolve(json(200, { i: done }))
    }
    await expect(Promise.all(ps)).resolves.toHaveLength(10)
    expect(f.fn).toHaveBeenCalledTimes(10)
  })

  it('gleichzeitige identische GETs → eine Anfrage, gleiches Ergebnis; POST nie zusammengelegt', async () => {
    const f = vi.fn(async () => json(200, { ok: 1 }))
    const c = client(f)
    const [a, b] = await Promise.all([c.get('/api/t/x/stats', { a: 1 }), c.get('/api/t/x/stats', { a: 1 })])
    expect(a).toEqual({ ok: 1 })
    expect(b).toBe(a)
    expect(f).toHaveBeenCalledTimes(1)
    await Promise.all([c.post('/sync', {}), c.post('/sync', {})])
    expect(f).toHaveBeenCalledTimes(3)
    // nach Abschluss wieder neu laden
    await c.get('/api/t/x/stats', { a: 1 })
    expect(f).toHaveBeenCalledTimes(4)
  })

  it('Abbruch eines Wartenden lässt die gemeinsame Anfrage für die anderen laufen; Abbruch aller bricht sie ab', async () => {
    const f = controlledFetch()
    const c = client(f.fn)
    const c1 = new AbortController()
    const c2 = new AbortController()
    const p1 = c.get('/a', undefined, c1.signal)
    const p2 = c.get('/a', undefined, c2.signal)
    await tick()
    expect(f.calls).toHaveLength(1)
    c1.abort()
    await expect(p1).rejects.toSatisfy(isAbort)
    expect((f.calls[0]!.init.signal as AbortSignal).aborted).toBe(false)
    f.calls[0]!.resolve(json(200, { v: 2 }))
    await expect(p2).resolves.toEqual({ v: 2 })

    const c3 = new AbortController()
    const p3 = c.get('/b', undefined, c3.signal)
    await tick()
    c3.abort()
    await expect(p3).rejects.toSatisfy(isAbort)
    expect((f.calls[1]!.init.signal as AbortSignal).aborted).toBe(true)
    expect(c.load.shared).toBe(0)
  })

  it('Standard-Signal (Route) bricht GETs ab, nicht POSTs', async () => {
    const f = controlledFetch()
    let route = new AbortController()
    const c = client(f.fn, { defaultSignal: () => route.signal })
    const g = c.get('/seite')
    const p = c.post('/sync', { ops: [] })
    await tick()
    route.abort()
    route = new AbortController()
    await expect(g).rejects.toSatisfy(isAbort)
    f.calls[1]!.resolve(json(200, { results: [] }))
    await expect(p).resolves.toEqual({ results: [] })
  })

  it('GET 503/502 → höchstens 2 Wiederholungen mit Backoff + Jitter, dann Fehler', async () => {
    const sleeps: number[] = []
    const f = vi.fn().mockResolvedValueOnce(json(503, { detail: 'x' })).mockResolvedValueOnce(json(502)).mockResolvedValueOnce(json(200, { ok: true }))
    const c = client(f, { retryBaseMs: 100, random: () => 0.5, sleep: async (ms) => void sleeps.push(ms) })
    await expect(c.get('/x')).resolves.toEqual({ ok: true })
    expect(f).toHaveBeenCalledTimes(3)
    expect(sleeps).toEqual([150, 250])

    const g = vi.fn(async () => json(504))
    const c2 = client(g, { retryBaseMs: 1, sleep: async () => undefined })
    const err = (await c2.get('/y').catch((e) => e)) as ApiError
    expect(err.status).toBe(504)
    expect(g).toHaveBeenCalledTimes(3)
  })

  it('keine Wiederholung für POST, 429, 500 oder langes Retry-After', async () => {
    const sleep = vi.fn(async () => undefined)
    for (const [method, status, headers] of [
      ['POST', 503, {}],
      ['GET', 429, { 'Retry-After': '2' }],
      ['GET', 500, {}],
      ['GET', 503, { 'Retry-After': '120' }],
    ] as const) {
      const f = vi.fn(async () => json(status, {}, headers))
      const c = client(f, { sleep })
      await expect(method === 'GET' ? c.get('/x') : c.post('/x', {})).rejects.toBeInstanceOf(ApiError)
      expect(f).toHaveBeenCalledTimes(1)
    }
    expect(sleep).not.toHaveBeenCalled()
  })

  it('Retry-After ≤ 10 s wird als Mindestwartezeit beachtet', async () => {
    const sleeps: number[] = []
    const f = vi.fn().mockResolvedValueOnce(json(503, {}, { 'Retry-After': '3' })).mockResolvedValueOnce(json(200, {}))
    const c = client(f, { retryBaseMs: 100, random: () => 0, sleep: async (ms) => void sleeps.push(ms) })
    await c.get('/x')
    expect(sleeps).toEqual([3000])
  })

  it('Abbruch während des Backoffs beendet die Wiederholung', async () => {
    const f = vi.fn(async () => json(503))
    const ctrl = new AbortController()
    const c = client(f, { retryBaseMs: 10_000 })
    const p = c.get('/x', undefined, ctrl.signal)
    await tick()
    ctrl.abort()
    await expect(p).rejects.toSatisfy(isAbort)
    expect(f).toHaveBeenCalledTimes(1)
  })
})
