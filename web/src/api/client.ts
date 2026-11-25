// HTTP-Client mit Bearer-Token, 401 → einmal erneuern + wiederholen, verständlichen Fehlermeldungen.

export interface TokenProvider {
  /** Aktuelles Access-Token (oder null, wenn nicht angemeldet). */
  getToken(): Promise<string | null>
  /** Token per Refresh-Token erneuern; null = nicht möglich. */
  refresh(): Promise<string | null>
  /** Sitzung abgelaufen: zur Anmeldung leiten. */
  onUnauthorized(): void
}

export interface ConflictDetail {
  message?: string
  [k: string]: unknown
}

export class ApiError extends Error {
  readonly status: number
  readonly detail: unknown
  readonly retryAfter: number | null

  constructor(status: number, message: string, detail: unknown = null, retryAfter: number | null = null) {
    super(message)
    this.name = 'ApiError'
    this.status = status
    this.detail = detail
    this.retryAfter = retryAfter
  }

  /** Strukturiertes Detail (z. B. 409 Monatsabschluss: {message, gaps, mismatches}). */
  get detailObject(): ConflictDetail | null {
    return this.detail && typeof this.detail === 'object' && !Array.isArray(this.detail) ? (this.detail as ConflictDetail) : null
  }
}

/** Retry-After: Sekunden oder HTTP-Datum → Sekunden (≥ 1). */
export function parseRetryAfter(v: string | null, now = Date.now()): number | null {
  if (!v) return null
  const s = v.trim()
  if (/^\d+$/.test(s)) return Math.max(1, Number(s))
  const t = Date.parse(s)
  if (Number.isNaN(t)) return null
  return Math.max(1, Math.ceil((t - now) / 1000))
}

function detailText(detail: unknown): string | null {
  if (typeof detail === 'string') return detail
  if (Array.isArray(detail)) {
    const parts = detail
      .map((e) => {
        if (!e || typeof e !== 'object') return null
        const loc = Array.isArray((e as { loc?: unknown }).loc)
          ? ((e as { loc: unknown[] }).loc.filter((x) => x !== 'body' && x !== 'query').join('.'))
          : ''
        const msg = String((e as { msg?: unknown }).msg ?? '')
        return loc ? `${loc}: ${msg}` : msg
      })
      .filter(Boolean)
    return parts.length ? parts.join('; ') : null
  }
  if (detail && typeof detail === 'object' && typeof (detail as { message?: unknown }).message === 'string') {
    return (detail as { message: string }).message
  }
  return null
}

/** Deutsche, verständliche Meldung je Status. */
export function errorMessage(status: number, detail: unknown, retryAfter: number | null): string {
  const d = detailText(detail)
  switch (status) {
    case 0:
      return 'Keine Verbindung zum Server. Bitte Netzwerk prüfen und erneut versuchen.'
    case 401:
      return 'Sitzung abgelaufen – bitte erneut anmelden.'
    case 403:
      return d ?? 'Keine Berechtigung für diese Aktion.'
    case 404:
      return d ?? 'Nicht gefunden.'
    case 409:
      return d ?? 'Konflikt mit dem aktuellen Stand.'
    case 413:
      return 'Anfrage zu gross.'
    case 422:
      return d ? `Ungültige Eingabe: ${d}` : 'Ungültige Eingabe.'
    case 429:
      return retryAfter
        ? `Zu viele Anfragen – bitte in ${retryAfter} s erneut versuchen.`
        : 'Zu viele Anfragen – bitte später erneut versuchen.'
    case 501:
      return d ?? 'Auf diesem Server nicht eingerichtet.'
    case 503:
      return `Server vorübergehend nicht verfügbar – bitte ${retryAfter ? `in ${retryAfter} s` : 'später'} erneut versuchen.`
    default:
      if (status >= 500) return `Serverfehler (${status}) – bitte später erneut versuchen.`
      return d ?? `Unerwartete Antwort (${status}).`
  }
}

export type Query = Record<string, string | number | boolean | null | undefined>

export interface RequestOptions {
  query?: Query
  body?: unknown
  /** Antwort als Blob (PDF, CSV, Belege) statt JSON. */
  blob?: boolean
  signal?: AbortSignal
}

export interface BlobResult {
  blob: Blob
  filename: string | null
  contentType: string
}

/** Dateiname bereinigen: keine Pfade, Steuer- oder reservierten Zeichen, max. 120 Zeichen. */
export function sanitizeFilename(name: string | null | undefined): string | null {
  if (!name) return null
  const base = name.split(/[\\/]/).pop() ?? ''
  // eslint-disable-next-line no-control-regex
  const clean = base.replace(/[\u0000-\u001f\u007f<>:"|?*]/g, '_').replace(/^[.\s]+/, '').trim().slice(0, 120)
  return clean || null
}

/** Dateiname aus Content-Disposition (filename* bevorzugt), bereinigt. */
export function filenameFromDisposition(v: string | null): string | null {
  return sanitizeFilename(rawFilename(v))
}

function rawFilename(v: string | null): string | null {
  if (!v) return null
  const star = /filename\*\s*=\s*UTF-8''([^;]+)/i.exec(v)
  if (star?.[1]) {
    try {
      return decodeURIComponent(star[1].trim())
    } catch {
      /* Fallback unten */
    }
  }
  const plain = /filename\s*=\s*"?([^";]+)"?/i.exec(v)
  return plain?.[1]?.trim() ?? null
}

export function buildUrl(base: string, path: string, query?: Query): string {
  const qs = new URLSearchParams()
  for (const [k, v] of Object.entries(query ?? {})) {
    if (v !== null && v !== undefined && v !== '') qs.set(k, String(v))
  }
  const s = qs.toString()
  return `${base}${path}${s ? `?${s}` : ''}`
}

export class ApiClient {
  private readonly fetchImpl: typeof fetch
  private refreshing: Promise<string | null> | null = null

  constructor(
    private readonly tokens: TokenProvider,
    private readonly baseUrl = '',
    fetchImpl?: typeof fetch,
  ) {
    this.fetchImpl = fetchImpl ?? ((...a) => fetch(...a))
  }

  private async refreshOnce(): Promise<string | null> {
    // parallele 401 teilen sich eine Erneuerung
    this.refreshing ??= this.tokens.refresh().finally(() => {
      this.refreshing = null
    })
    return this.refreshing
  }

  private async send(method: string, url: string, token: string | null, opts: RequestOptions): Promise<Response> {
    const headers: Record<string, string> = { Accept: opts.blob ? '*/*' : 'application/json' }
    if (token) headers.Authorization = `Bearer ${token}`
    let body: string | undefined
    if (opts.body !== undefined) {
      headers['Content-Type'] = 'application/json'
      body = JSON.stringify(opts.body)
    }
    try {
      return await this.fetchImpl(url, { method, headers, body, signal: opts.signal, credentials: 'omit', cache: 'no-store' })
    } catch (e) {
      if (e instanceof DOMException && e.name === 'AbortError') throw e
      throw new ApiError(0, errorMessage(0, null, null))
    }
  }

  async request<T>(method: string, path: string, opts: RequestOptions = {}): Promise<T> {
    const res = await this.raw(method, path, opts)
    if (opts.blob) {
      return {
        blob: await res.blob(),
        filename: filenameFromDisposition(res.headers.get('Content-Disposition')),
        contentType: res.headers.get('Content-Type') ?? 'application/octet-stream',
      } as T
    }
    if (res.status === 204) return undefined as T
    const text = await res.text()
    return (text ? JSON.parse(text) : undefined) as T
  }

  /** Anfrage mit Fehlerbehandlung; liefert die erfolgreiche Response. */
  async raw(method: string, path: string, opts: RequestOptions = {}): Promise<Response> {
    const url = buildUrl(this.baseUrl, path, opts.query)
    let token = await this.tokens.getToken()
    let res = await this.send(method, url, token, opts)
    if (res.status === 401) {
      token = await this.refreshOnce()
      if (token) res = await this.send(method, url, token, opts)
      if (res.status === 401) {
        this.tokens.onUnauthorized()
        throw new ApiError(401, errorMessage(401, null, null))
      }
    }
    if (!res.ok) {
      let detail: unknown
      try {
        const text = await res.text()
        const parsed = text ? JSON.parse(text) : null
        detail = parsed && typeof parsed === 'object' && 'detail' in parsed ? (parsed as { detail: unknown }).detail : parsed
      } catch {
        detail = null
      }
      const retryAfter = parseRetryAfter(res.headers.get('Retry-After'))
      throw new ApiError(res.status, errorMessage(res.status, detail, retryAfter), detail, retryAfter)
    }
    return res
  }

  get<T>(path: string, query?: Query, signal?: AbortSignal): Promise<T> {
    return this.request<T>('GET', path, { query, signal })
  }

  post<T>(path: string, body?: unknown): Promise<T> {
    return this.request<T>('POST', path, { body: body ?? {} })
  }

  patch<T>(path: string, body: unknown): Promise<T> {
    return this.request<T>('PATCH', path, { body })
  }

  delete<T>(path: string): Promise<T> {
    return this.request<T>('DELETE', path)
  }

  blob(path: string, query?: Query): Promise<BlobResult> {
    return this.request<BlobResult>('GET', path, { query, blob: true })
  }
}
