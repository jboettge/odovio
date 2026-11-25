// Web Worker für Auswertungen über grosse Datenmengen (eigene Datei unter /assets → CSP worker-src/script-src 'self').
// Hält eine schlanke Kopie der Fahrten im Speicher des Workers (keine Persistenz).
import { AnalyticsEngine, handle, type EngineRequest } from '../lib/analytics'

const engine = new AnalyticsEngine()
const scope = self as unknown as { onmessage: ((ev: MessageEvent<EngineRequest>) => void) | null; postMessage: (m: unknown) => void }

scope.onmessage = (ev) => {
  const res = handle(engine, ev.data)
  if (res) scope.postMessage(res)
}
