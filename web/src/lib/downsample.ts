// Ausdünnen langer Zeitreihen für Diagramme (Largest-Triangle-Three-Buckets): Form und Ausreisser bleiben
// erhalten, gezeichnet werden höchstens `max` Punkte (statt tausender SVG-Elemente). Erster/letzter Punkt bleiben.
export function downsample<T>(points: readonly T[], max: number, value: (p: T) => number): T[] {
  const n = points.length
  if (max >= n || max < 3) return points.slice()
  const out: T[] = [points[0]!]
  const bucket = (n - 2) / (max - 2)
  let a = 0
  for (let i = 0; i < max - 2; i++) {
    // Mittelwert des nächsten Eimers
    const nStart = Math.floor((i + 1) * bucket) + 1
    const nEnd = Math.min(n, Math.floor((i + 2) * bucket) + 1)
    let avgX = 0
    let avgY = 0
    for (let j = nStart; j < nEnd; j++) {
      avgX += j
      avgY += value(points[j]!)
    }
    const cnt = Math.max(1, nEnd - nStart)
    avgX /= cnt
    avgY /= cnt
    // Punkt im aktuellen Eimer mit grösster Dreiecksfläche
    const start = Math.floor(i * bucket) + 1
    const end = Math.floor((i + 1) * bucket) + 1
    const ay = value(points[a]!)
    let best = start
    let bestArea = -1
    for (let j = start; j < end; j++) {
      const area = Math.abs((a - avgX) * (value(points[j]!) - ay) - (a - j) * (avgY - ay))
      if (area > bestArea) {
        bestArea = area
        best = j
      }
    }
    out.push(points[best]!)
    a = best
  }
  out.push(points[n - 1]!)
  return out
}
