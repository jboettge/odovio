// Auslieferung der gebauten SPA: vorkomprimierte Varianten (.br/.gz) je nach Accept-Encoding, Vary, Caching,
// CSP; Startpfad lädt keine Routen-Chunks vorab.
import { test, expect } from './fixtures'

async function entryScripts(request: import('@playwright/test').APIRequestContext): Promise<string[]> {
  const html = await (await request.get('/', { headers: { 'Accept-Encoding': 'identity' } })).text()
  return [...html.matchAll(/<script type="module"[^>]*src="([^"]+)"/g)].map((m) => m[1]!)
}

test('Vorkomprimierte Assets: br vor gzip, unkomprimiert ohne Accept-Encoding, Vary gesetzt', async ({ playwright, baseURL, problems: _p }) => {
  // eigener Kontext ohne automatisches Dekomprimieren durch Accept-Encoding-Vorgaben des Browsers
  const request = await playwright.request.newContext({ baseURL })
  const [script] = await entryScripts(request)
  expect(script).toMatch(/^\/assets\/.+\.js$/)
  const identity = await request.get(script!, { headers: { 'Accept-Encoding': 'identity' } })
  const raw = await identity.body()
  expect(identity.headers()['content-encoding']).toBeUndefined()
  expect(identity.headers()['vary']).toBe('Accept-Encoding')
  expect(identity.headers()['cache-control']).toBe('public, max-age=31536000, immutable')

  const br = await request.get(script!, { headers: { 'Accept-Encoding': 'gzip, deflate, br' } })
  expect(br.headers()['content-encoding']).toBe('br')
  const gz = await request.get(script!, { headers: { 'Accept-Encoding': 'gzip' } })
  expect(gz.headers()['content-encoding']).toBe('gzip')
  // Playwright dekomprimiert selbst – Inhalt identisch zur unkomprimierten Datei
  expect((await br.body()).equals(raw)).toBe(true)
  expect((await gz.body()).equals(raw)).toBe(true)

  // index.html (SPA-Fallback): Vary gesetzt, nicht cachebar (unter 1 KiB → ohne vorkomprimierte Variante)
  const html = await request.get('/fahrzeuge/x/fahrten', { headers: { 'Accept-Encoding': 'br' } })
  expect(html.headers()['vary']).toBe('Accept-Encoding')
  expect(html.headers()['content-encoding'] ?? 'identity').toMatch(/^(br|identity)$/)
  expect(html.headers()['cache-control']).toBe('no-cache')
  expect(html.headers()['content-security-policy']).toContain("script-src 'self'")
  await request.dispose()
})

test('Vorkomprimierte Dateien nur über Accept-Encoding, nicht direkt abrufbar (wie der Server)', async ({ request, problems: _p }) => {
  const [script] = await entryScripts(request)
  expect((await request.get(`${script}.br`)).status()).toBe(404)
  expect((await request.get(`${script}.gz`)).status()).toBe(404)
})

test('Browser lädt komprimiert; Startseite lädt nur Startpfad-Chunks', async ({ page, problems: _p }) => {
  const js: { url: string; enc: string }[] = []
  page.on('response', (r) => {
    if (r.url().endsWith('.js')) js.push({ url: r.url(), enc: r.headers()['content-encoding'] ?? 'identity' })
  })
  await page.goto('/')
  await expect(page.locator('#app')).not.toBeEmpty()
  const names = js.map((j) => j.url.split('/').pop()!)
  expect(names.some((n) => n.startsWith('vendor-vue-'))).toBe(true)
  // keine Seiten-Chunks anderer Routen vorab
  expect(names.filter((n) => /^(Dashboard|Vehicle|Activity|Integrity|Members)/.test(n))).toEqual([])
  expect(js.filter((j) => j.enc !== 'identity').length).toBeGreaterThan(0)
})
