// Lasttest gegen den Mock mit grossem Datenbestand (--seed large, Port 4321): 3 Fahrzeuge × 30k Fahrten,
// 5k Tankvorgänge, > 90k Journal-Einträge. Misst Zeit bis Übersicht sichtbar und bis Fahrtentabelle bedienbar,
// scrollt über alle 30k Zeilen und prüft: keine Long Tasks > 200 ms, höchstens 200 <tr> im DOM, nie eine leere
// Fläche statt Zeilen. Messwerte werden ausgegeben (CI-Log).
import { test, expect } from './fixtures'

/** Budgets (ms bzw. Anzahl) – grosszügig für CI-Runner, deutlich unter der Wahrnehmungsgrenze für «hängt». */
export const BUDGET = {
  /** Anmeldung bis Übersicht mit Kennzahlen und offenen Bestätigungen aller Fahrzeuge (inkl. Laden von ~96k Datensätzen) */
  dashboardMs: 15_000,
  /** Klick auf «Fahrten» bis Tabelle mit 30k Fahrten bedienbar */
  tripsInteractiveMs: 3_000,
  /** längster Long Task während des Scrollens */
  longTaskMs: 200,
  /** höchstens so viele Tabellenzeilen im DOM */
  maxRows: 200,
  /** Suche (inkl. 200 ms Entprellung) bis Ergebnis */
  searchMs: 3_000,
} as const

type PerfWindow = Window & { __longtasks: { start: number; duration: number }[] }

test('Grosser Datenbestand: Übersicht, Fahrtentabelle, Scrollen über 30k Zeilen, Suche', async ({ page, problems: _p }) => {
  const workers: string[] = []
  page.on('worker', (w) => workers.push(w.url()))
  const encodings = new Map<string, string>()
  page.on('response', (r) => {
    if (/\/assets\/.*\.js$/.test(r.url())) encodings.set(r.url(), r.headers()['content-encoding'] ?? 'identity')
  })
  // Long Tasks ab Seitenstart sammeln (Init-Skript via DevTools-Protokoll, nicht von der CSP betroffen)
  await page.addInitScript(() => {
    const w = window as unknown as PerfWindow
    w.__longtasks = []
    try {
      new PerformanceObserver((list) => {
        for (const e of list.getEntries()) w.__longtasks.push({ start: e.startTime, duration: e.duration })
      }).observe({ type: 'longtask', buffered: true })
    } catch {
      /* Browser ohne Long-Task-API */
    }
  })

  // ---------- Übersicht ----------
  await page.goto('/uebersicht')
  const t0 = Date.now()
  await page.locator('button[data-user="anna"]').click()
  const tiles = page.locator('a.vehicle-tile')
  await expect(tiles).toHaveCount(3, { timeout: BUDGET.dashboardMs })
  for (const name of ['Skoda Octavia', 'Toyota Corolla', 'VW Touran']) {
    const tile = page.getByRole('link', { name: `${name} öffnen` })
    await expect(tile).toContainText('4 Fahrten bestätigen', { timeout: BUDGET.dashboardMs })
    await expect(tile).toContainText(/\d[’']\d{3} km/, { timeout: BUDGET.dashboardMs })
  }
  const dashboardMs = Date.now() - t0
  const loadTasks = await page.evaluate(() => (window as unknown as PerfWindow).__longtasks.map((t) => t.duration))

  // ---------- Fahrtentabelle ----------
  await page.getByRole('link', { name: 'Skoda Octavia öffnen' }).click()
  await expect(page.getByRole('heading', { name: 'Skoda Octavia' })).toBeVisible()
  const t1 = Date.now()
  await page.getByRole('link', { name: 'Fahrten', exact: true }).click()
  const table = page.locator('table[aria-rowcount]')
  await expect(table).toHaveAttribute('aria-rowcount', '30001', { timeout: BUDGET.tripsInteractiveMs * 3 })
  const firstHistory = page.locator('tbody tr[aria-rowindex="2"]').getByRole('button', { name: /Verlauf/ })
  await expect(firstHistory).toBeEnabled()
  const tripsMs = Date.now() - t1
  await expect(page.getByText(/30[’']000 Fahrten/)).toBeVisible()

  // ---------- Scrollen über alle Zeilen ----------
  await page.evaluate(() => {
    ;(window as unknown as PerfWindow).__longtasks = []
  })
  const scrollHeight = await page.evaluate(() => document.documentElement.scrollHeight)
  const viewport = page.viewportSize()!.height
  const positions: number[] = []
  // grobe Sprünge über die ganze Liste + ein Abschnitt Zeile für Zeile (Bildschirmhöhe)
  for (let i = 0; i <= 80; i++) positions.push(Math.round((i / 80) * (scrollHeight - viewport)))
  for (let i = 0; i < 25; i++) positions.push(Math.round(scrollHeight / 2) + i * Math.round(viewport * 0.8))
  let maxRows = 0
  let blank = 0
  const t2 = Date.now()
  for (const y of positions) {
    const r = await page.evaluate(async (top) => {
      window.scrollTo(0, top)
      await new Promise((res) => requestAnimationFrame(() => requestAnimationFrame(() => res(null))))
      const rows = document.querySelectorAll('tr').length
      // Bildschirmmitte muss in einer echten Zeile liegen (kein leerer Platzhalter sichtbar)
      const tableBox = document.querySelector('table[aria-rowcount]')!.getBoundingClientRect()
      const midY = Math.min(Math.max(window.innerHeight / 2, tableBox.top + 60), tableBox.bottom - 5)
      const el = document.elementFromPoint(tableBox.left + 40, midY)
      const inRow = Boolean(el?.closest('tr[aria-rowindex]'))
      return { rows, inRow }
    }, y)
    maxRows = Math.max(maxRows, r.rows)
    if (!r.inRow) blank++
  }
  const scrollMs = Date.now() - t2
  // ans Ende: letzte Zeile hat aria-rowindex = 30001
  await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight))
  await expect(page.locator('tbody tr[aria-rowindex="30001"]')).toBeAttached()
  const scrollTasks = await page.evaluate(() => (window as unknown as PerfWindow).__longtasks.map((t) => t.duration))
  const maxLongTask = Math.max(0, ...scrollTasks)

  // ---------- Suche (Web Worker) ----------
  await page.evaluate(() => window.scrollTo(0, 0))
  await page.evaluate(() => {
    ;(window as unknown as PerfWindow).__longtasks = []
  })
  const t3 = Date.now()
  await page.getByLabel('Suche').fill('Kunde 042 AG')
  await expect(page.getByText(/^\d[\d’']* Fahrten ·/)).not.toHaveText(/^30[’']000 Fahrten/, { timeout: BUDGET.searchMs * 2 })
  const searchMs = Date.now() - t3
  const found = await page.locator('tbody tr[aria-rowindex]').first().textContent()
  expect(found).toContain('Kunde 042 AG')
  const searchTasks = await page.evaluate(() => (window as unknown as PerfWindow).__longtasks.map((t) => t.duration))

  const metrics = {
    dashboardMs,
    tripsInteractiveMs: tripsMs,
    scrollSteps: positions.length,
    scrollMs,
    maxRowsInDom: maxRows,
    blankViewports: blank,
    longTasksScroll: scrollTasks.length,
    maxLongTaskScrollMs: Math.round(maxLongTask),
    longTasksDuringLoad: loadTasks.length,
    maxLongTaskLoadMs: Math.round(Math.max(0, ...loadTasks)),
    searchMs,
    maxLongTaskSearchMs: Math.round(Math.max(0, ...searchTasks)),
    worker: workers.some((u) => /analytics/.test(u)),
    jsEncodings: [...new Set(encodings.values())].join(','),
  }
  console.log(`PERF ${JSON.stringify(metrics)}`)
  test.info().annotations.push({ type: 'perf', description: JSON.stringify(metrics) })

  expect(metrics.worker, 'Auswertungen laufen im Web Worker').toBe(true)
  expect(dashboardMs).toBeLessThan(BUDGET.dashboardMs)
  expect(tripsMs).toBeLessThan(BUDGET.tripsInteractiveMs)
  expect(maxRows, 'Tabellenzeilen im DOM').toBeLessThan(BUDGET.maxRows)
  expect(blank, 'sichtbare Bereiche ohne Zeilen').toBe(0)
  expect(maxLongTask, 'längster Long Task beim Scrollen (ms)').toBeLessThan(BUDGET.longTaskMs)
  expect(searchMs).toBeLessThan(BUDGET.searchMs)
  expect(metrics.maxLongTaskSearchMs, 'längster Long Task bei der Suche (ms)').toBeLessThan(BUDGET.longTaskMs)
})
