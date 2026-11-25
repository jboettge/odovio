import { describe, expect, it, vi } from 'vitest'
import { ApiClient, ApiError, errorMessage, filenameFromDisposition, parseRetryAfter, sanitizeFilename, type TokenProvider } from '../../src/api/client'

function res(status: number, body: unknown = {}, headers: Record<string, string> = {}): Response {
  return new Response(body === null ? null : JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...headers } })
}

function tokens(over: Partial<TokenProvider> = {}): TokenProvider {
  return { getToken: vi.fn(async () => 'old'), refresh: vi.fn(async () => 'new'), onUnauthorized: vi.fn(), ...over }
}

describe('ApiClient', () => {
  it('sendet Bearer-Token und keine Cookies', async () => {
    const fetchMock = vi.fn(async () => res(200, { ok: true }))
    const c = new ApiClient(tokens(), '', fetchMock as unknown as typeof fetch)
    await c.get('/api/me')
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
    expect(url).toBe('/api/me')
    expect((init.headers as Record<string, string>).Authorization).toBe('Bearer old')
    expect(init.credentials).toBe('omit')
  })

  it('401 → einmal erneuern und wiederholen', async () => {
    const fetchMock = vi.fn().mockResolvedValueOnce(res(401, { detail: 'abgelaufen' })).mockResolvedValueOnce(res(200, { name: 'x' }))
    const t = tokens()
    const c = new ApiClient(t, '', fetchMock as unknown as typeof fetch)
    await expect(c.get('/api/me')).resolves.toEqual({ name: 'x' })
    expect(t.refresh).toHaveBeenCalledTimes(1)
    const second = fetchMock.mock.calls[1] as unknown as [string, RequestInit]
    expect((second[1].headers as Record<string, string>).Authorization).toBe('Bearer new')
    expect(t.onUnauthorized).not.toHaveBeenCalled()
  })

  it('401 trotz Erneuerung → Anmeldung', async () => {
    const fetchMock = vi.fn(async () => res(401))
    const t = tokens({ refresh: vi.fn(async () => null) })
    const c = new ApiClient(t, '', fetchMock as unknown as typeof fetch)
    await expect(c.get('/api/me')).rejects.toMatchObject({ status: 401 })
    expect(t.onUnauthorized).toHaveBeenCalledTimes(1)
  })

  it('parallele 401 teilen sich eine Erneuerung', async () => {
    let n = 0
    const fetchMock = vi.fn(async (_u: string, init: RequestInit) =>
      (init.headers as Record<string, string>).Authorization === 'Bearer new' ? res(200, { n: ++n }) : res(401),
    )
    const t = tokens({ refresh: vi.fn(() => new Promise<string>((r) => setTimeout(() => r('new'), 5))) })
    const c = new ApiClient(t, '', fetchMock as unknown as typeof fetch)
    await Promise.all([c.get('/a'), c.get('/b'), c.get('/c')])
    expect(t.refresh).toHaveBeenCalledTimes(1)
  })

  it('429 mit Retry-After → verständliche Meldung, keine Wiederholung', async () => {
    const fetchMock = vi.fn(async () => res(429, { detail: 'Zu viele Anfragen' }, { 'Retry-After': '30' }))
    const c = new ApiClient(tokens(), '', fetchMock as unknown as typeof fetch)
    const err = (await c.get('/x').catch((e) => e)) as ApiError
    expect(err).toBeInstanceOf(ApiError)
    expect(err.status).toBe(429)
    expect(err.retryAfter).toBe(30)
    expect(err.message).toBe('Zu viele Anfragen – bitte in 30 s erneut versuchen.')
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it('409 mit strukturiertem Detail (Monatsabschluss)', async () => {
    const detail = { message: 'km-Lücken vorhanden', gaps: [{ km: 12 }], mismatches: [] }
    const fetchMock = vi.fn(async () => res(409, { detail }))
    const c = new ApiClient(tokens(), '', fetchMock as unknown as typeof fetch)
    const err = (await c.post('/close', { force: false }).catch((e) => e)) as ApiError
    expect(err.status).toBe(409)
    expect(err.message).toBe('km-Lücken vorhanden')
    expect(err.detailObject).toEqual(detail)
  })

  it('422-Liste, 403, 501, 503 und Netzwerkfehler', async () => {
    expect(errorMessage(422, [{ loc: ['body', 'ops', 0, 'id'], msg: 'invalid uuid' }], null)).toBe('Ungültige Eingabe: ops.0.id: invalid uuid')
    expect(errorMessage(403, 'Verwaltung nur im Webfrontend', null)).toBe('Verwaltung nur im Webfrontend')
    expect(errorMessage(403, null, null)).toBe('Keine Berechtigung für diese Aktion.')
    expect(errorMessage(503, 'x', 30)).toBe('Server vorübergehend nicht verfügbar – bitte in 30 s erneut versuchen.')
    expect(errorMessage(500, '<html>Traceback…</html>', null)).toBe('Serverfehler (500) – bitte später erneut versuchen.')
    const c = new ApiClient(tokens(), '', vi.fn(async () => Promise.reject(new TypeError('Failed to fetch'))) as unknown as typeof fetch)
    await expect(c.get('/x')).rejects.toMatchObject({ status: 0, message: expect.stringContaining('Keine Verbindung') })
  })

  it('Retry-After als HTTP-Datum', () => {
    const now = Date.parse('2026-11-25T12:00:00Z')
    expect(parseRetryAfter('Wed, 25 Nov 2026 12:01:00 GMT', now)).toBe(60)
    expect(parseRetryAfter('abc')).toBeNull()
    expect(parseRetryAfter(null)).toBeNull()
  })

  it('Blob-Antworten mit bereinigtem Dateinamen', async () => {
    const fetchMock = vi.fn(async () => new Response('PDF', { status: 200, headers: { 'Content-Type': 'application/pdf', 'Content-Disposition': `attachment; filename="x.pdf"; filename*=UTF-8''Fahrtenbuch_Skoda%20Octavia_2026-10.pdf` } }))
    const c = new ApiClient(tokens(), '', fetchMock as unknown as typeof fetch)
    const r = await c.blob('/a.pdf')
    expect(r.filename).toBe('Fahrtenbuch_Skoda Octavia_2026-10.pdf')
    expect(r.contentType).toBe('application/pdf')
  })

  it('Dateinamen ohne Pfade/Steuerzeichen', () => {
    expect(sanitizeFilename('../../etc/passwd')).toBe('passwd')
    expect(sanitizeFilename('..\\..\\a<b>.pdf')).toBe('a_b_.pdf')
    expect(sanitizeFilename('.hidden')).toBe('hidden')
    expect(sanitizeFilename('')).toBeNull()
    expect(filenameFromDisposition(`attachment; filename*=UTF-8''%2E%2E%2Fevil.pdf`)).toBe('evil.pdf')
    expect(filenameFromDisposition('inline; filename="Beleg_receipt_1.jpg"')).toBe('Beleg_receipt_1.jpg')
  })
})
