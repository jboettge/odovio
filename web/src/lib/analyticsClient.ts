// Zugriff auf die Auswertungen: bevorzugt im Web Worker (Hauptthread bleibt beim Rechnen über 100k Fahrten frei),
// sonst im Hauptthread (Tests/jsdom, Browser ohne Worker, Worker-Fehler). Gleiche Engine, gleiche Ergebnisse.
// Die Engine wird in beiden Fällen erst bei Bedarf geladen (nicht Teil des Startpfads).
import type { AnalyticsEngine, EngineRequest, EngineResponse } from './analytics'
import type { Delta, HealthResult, MonthSummary, TripQuery, TripQueryResult } from './slim'

export type AnalyticsMode = 'worker' | 'inline' | 'starting'

type Call = Extract<EngineRequest, { id: number }>
type CallInit = Call extends infer C ? (C extends Call ? Omit<C, 'id'> : never) : never

interface Pending {
  msg: Call
  resolve: (v: unknown) => void
  reject: (e: unknown) => void
}

interface Inline {
  engine: AnalyticsEngine
  handle: (e: AnalyticsEngine, m: EngineRequest) => EngineResponse | null
}

export interface AnalyticsOptions {
  /** Worker verwenden (Standard: wenn `Worker` verfügbar). */
  useWorker?: boolean
  /** Worker erzeugen (Tests). */
  createWorker?: () => Promise<Worker>
}

export class Analytics {
  private inline: Inline | null = null
  private worker: Worker | null = null
  /** Nachrichten, bis Worker bzw. Engine bereit ist */
  private queue: EngineRequest[] = []
  private pending = new Map<number, Pending>()
  private seq = 0
  private replay: (() => Delta) | null = null
  private falling = false
  mode: AnalyticsMode = 'starting'

  constructor(opts: AnalyticsOptions = {}) {
    const useWorker = opts.useWorker ?? typeof Worker !== 'undefined'
    if (!useWorker) {
      void this.fallback()
      return
    }
    const create = opts.createWorker ?? defaultWorker
    create().then(
      (w) => this.attach(w),
      () => void this.fallback(),
    )
  }

  /** Liefert den vollständigen aktuellen Datenstand (Neustart im Hauptthread nach einem Worker-Fehler). */
  setReplay(fn: () => Delta): void {
    this.replay = fn
  }

  private attach(w: Worker): void {
    if (this.falling) {
      w.terminate()
      return
    }
    w.onmessage = (ev: MessageEvent<EngineResponse>) => {
      const p = this.pending.get(ev.data.id)
      if (!p) return
      this.pending.delete(ev.data.id)
      if ('error' in ev.data) p.reject(new Error(ev.data.error))
      else p.resolve(ev.data.result)
    }
    w.onerror = (ev) => {
      ev.preventDefault?.()
      void this.fallback()
    }
    w.onmessageerror = () => void this.fallback()
    for (const m of this.queue) w.postMessage(m)
    this.queue = []
    // Anfragen, die vor dem Start gestellt wurden
    for (const p of this.pending.values()) w.postMessage(p.msg)
    this.worker = w
    this.mode = 'worker'
  }

  /** Im Hauptthread rechnen: Engine laden, Daten einspielen, offene Anfragen dort beantworten. */
  private async fallback(): Promise<void> {
    if (this.falling) return
    this.falling = true
    const hadWorker = this.worker !== null
    this.worker?.terminate()
    this.worker = null
    const mod = await import('./analytics')
    const inline: Inline = { engine: new mod.AnalyticsEngine(), handle: mod.handle }
    const queued = this.queue
    this.queue = []
    if (this.replay && (hadWorker || queued.length)) {
      // aktueller Datenstand aus dem Store (deckt alle bisherigen apply/reset ab)
      inline.engine.apply(this.replay())
    } else {
      for (const m of queued) inline.handle(inline.engine, m)
    }
    this.inline = inline
    this.mode = 'inline'
    const open = [...this.pending.values()]
    this.pending.clear()
    for (const p of open) this.settle(p)
  }

  private settle(p: Pending): void {
    const res = this.inline!.handle(this.inline!.engine, p.msg)
    if (res && 'error' in res) p.reject(new Error(res.error))
    else p.resolve(res?.result)
  }

  private post(m: EngineRequest): void {
    if (this.inline) this.inline.handle(this.inline.engine, m)
    else if (this.worker) this.worker.postMessage(m)
    else if (!('id' in m)) this.queue.push(m)
  }

  private call<T>(init: CallInit): Promise<T> {
    const msg = { ...init, id: ++this.seq } as Call
    return new Promise<T>((resolve, reject) => {
      const p: Pending = { msg, resolve: resolve as (v: unknown) => void, reject }
      if (this.inline) {
        // asynchron wie beim Worker (gleiches Verhalten für Aufrufer)
        queueMicrotask(() => this.settle(p))
        return
      }
      this.pending.set(msg.id, p)
      if (this.worker) this.worker.postMessage(msg)
    })
  }

  reset(): void {
    this.post({ op: 'reset' })
  }

  apply(delta: Delta): void {
    if (!delta.trips?.length && !delta.periods?.length && !delta.places?.length && !delta.customers?.length) return
    this.post({ op: 'apply', delta })
  }

  health(vids: string[]): Promise<Record<string, HealthResult>> {
    return this.call({ op: 'health', args: [vids] })
  }

  query(q: TripQuery): Promise<TripQueryResult> {
    return this.call({ op: 'query', args: [q] })
  }

  monthSummary(vid: string, month: string): Promise<MonthSummary> {
    return this.call({ op: 'monthSummary', args: [vid, month] })
  }

  dispose(): void {
    this.worker?.terminate()
    this.worker = null
  }
}

async function defaultWorker(): Promise<Worker> {
  // eigene Datei (kein blob:/data:-Worker) → CSP-konform mit script-src 'self'
  const { default: AnalyticsWorker } = await import('../workers/analytics.worker?worker')
  return new AnalyticsWorker({ name: 'analytics' })
}

let instance: Analytics | null = null

export function analytics(): Analytics {
  return (instance ??= new Analytics())
}

/** Bestehende Instanz (ohne einen Worker zu starten). */
export function existingAnalytics(): Analytics | null {
  return instance
}

/** Nur für Tests: eigene Instanz setzen. */
export function setAnalytics(a: Analytics | null): void {
  instance?.dispose()
  instance = a
}
