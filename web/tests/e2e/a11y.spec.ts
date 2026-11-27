// Review 11/2026 W19: einfache Barrierefreiheits-Prüfung ohne zusätzliche Abhängigkeit, hell und dunkel –
// Formularfelder beschriftet, Knöpfe/Links mit Namen, Textkontrast (WCAG 1.4.3: 4.5:1, grosse Schrift 3:1).
import { test, expect, login } from './fixtures'
import type { Page } from '@playwright/test'

/** Läuft im Browser; liefert Verstösse als Text. */
function audit(): string[] {
  const out: string[] = []
  const visible = (el: Element) => {
    const r = (el as HTMLElement).getBoundingClientRect()
    const s = getComputedStyle(el)
    return r.width > 1 && r.height > 1 && s.visibility !== 'hidden' && s.display !== 'none' && !el.closest('[aria-hidden="true"], .sr-only')
  }
  const desc = (el: Element) => `${el.tagName.toLowerCase()}${el.id ? `#${el.id}` : ''}${el.className && typeof el.className === 'string' ? `.${el.className.trim().split(/\s+/).join('.')}` : ''}`
  const name = (el: Element) =>
    (el.getAttribute('aria-label') ?? '').trim() ||
    (el.getAttribute('aria-labelledby') ?? '').split(/\s+/).map((id) => document.getElementById(id)?.textContent ?? '').join(' ').trim() ||
    (el.textContent ?? '').trim() ||
    (el.getAttribute('title') ?? '').trim()

  for (const el of document.querySelectorAll('input:not([type=hidden]), select, textarea')) {
    if (!visible(el) && !(el as HTMLInputElement).labels?.length) continue
    const labelled = (el as HTMLInputElement).labels?.length || el.getAttribute('aria-label') || el.getAttribute('aria-labelledby') || el.getAttribute('title')
    if (!labelled) out.push(`Feld ohne Beschriftung: ${desc(el)}`)
  }
  for (const el of document.querySelectorAll('button, a[href], [role=button]')) {
    if (visible(el) && !name(el)) out.push(`Knopf/Link ohne Namen: ${desc(el)}`)
  }

  // Kontrast: Textfarbe gegen den ersten deckenden Hintergrund der Vorfahren
  const rgb = (c: string) => (c.match(/[\d.]+/g) ?? []).map(Number)
  const lum = ([r, g, b]: number[]) => {
    const f = (v: number) => {
      const x = v / 255
      return x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4
    }
    return 0.2126 * f(r!) + 0.7152 * f(g!) + 0.0722 * f(b!)
  }
  const bgOf = (el: Element | null): number[] | null => {
    for (let e = el; e; e = e.parentElement) {
      const s = getComputedStyle(e)
      if (s.backgroundImage !== 'none') return null // Verlauf/Bild: nicht prüfbar
      const c = rgb(s.backgroundColor)
      if (c.length >= 3 && (c.length < 4 || c[3]! >= 0.99)) return c.slice(0, 3)
      if (c.length >= 4 && c[3]! > 0) return null // halbtransparent: nicht prüfbar
    }
    return [255, 255, 255]
  }
  const seen = new Set<Element>()
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT)
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    const el = n.parentElement
    if (!el || seen.has(el) || !(n.textContent ?? '').trim() || !visible(el)) continue
    seen.add(el)
    if (el.closest('[disabled], [aria-disabled="true"], option, .is-deleted, del')) continue // deaktiviert/storniert: ausgenommen
    const s = getComputedStyle(el)
    const fg = rgb(s.color)
    if (fg.length >= 4 && fg[3]! < 0.99) continue
    const bg = bgOf(el)
    if (!bg) continue
    const [a, b] = [lum(fg), lum(bg)].sort((x, y) => y - x)
    const ratio = (a! + 0.05) / (b! + 0.05)
    const size = parseFloat(s.fontSize)
    const large = size >= 24 || (size >= 18.66 && Number(s.fontWeight) >= 700)
    if (ratio < (large ? 3 : 4.5) - 0.01) out.push(`Kontrast ${ratio.toFixed(2)}: «${(n.textContent ?? '').trim().slice(0, 40)}» (${desc(el)})`)
  }
  return out
}

async function check(page: Page, path: string, scheme: string) {
  await page.goto(path)
  await expect(page.locator('main h1')).toBeVisible()
  await page.waitForLoadState('networkidle')
  await expect(page.locator('.loading')).toHaveCount(0)
  return (await page.evaluate(audit)).map((p) => `${scheme} ${path}: ${p}`)
}

for (const scheme of ['light', 'dark'] as const) {
  test(`Barrierefreiheit ${scheme === 'light' ? 'hell' : 'dunkel'}: Beschriftungen, Namen, Kontrast`, async ({ page, problems: _p }) => {
    test.setTimeout(60_000)
    await page.emulateMedia({ colorScheme: scheme })
    await login(page, 'jakob', '/uebersicht?buch=privat')
    await page.getByRole('link', { name: 'Skoda Octavia öffnen' }).click()
    await expect(page).toHaveURL(/\/fahrzeuge\/[^/]+$/)
    const vehicle = new URL(page.url()).pathname
    const body = await page.evaluate(() => getComputedStyle(document.body).backgroundColor)
    // dunkles Schema wirklich aktiv (Hintergrund dunkel) bzw. hell
    const lum = (await page.evaluate(() => (getComputedStyle(document.body).backgroundColor.match(/\d+/g) ?? []).slice(0, 3).map(Number))).reduce((a, b) => a + b, 0) / 3
    expect(scheme === 'dark' ? lum < 80 : lum > 180, `Hintergrund ${body}`).toBe(true)

    const problems: string[] = []
    for (const path of ['/uebersicht', vehicle, `${vehicle}/fahrten`, `${vehicle}/tanken`, `${vehicle}/wartungen`, `${vehicle}/berichte`, `${vehicle}/monatsabschluss`, '/aktivitaet', '/stammdaten/fahrzeuge', '/verwaltung/mitglieder']) {
      problems.push(...(await check(page, path, scheme)))
    }
    // Dialog mit Feldfehlern
    await page.goto(`${vehicle}/tanken`)
    await page.getByRole('button', { name: 'Tankvorgang erfassen' }).click()
    const dlg = page.getByRole('dialog', { name: 'Tankvorgang erfassen' })
    await dlg.getByRole('button', { name: 'Speichern' }).click()
    await expect(dlg.getByText('Pflichtfeld').first()).toBeVisible()
    problems.push(...(await page.evaluate(audit)).map((p) => `${scheme} Dialog Tanken: ${p}`))
    expect(problems).toEqual([])
  })
}

test('Prüfung erkennt Verstösse (Selbsttest)', async ({ page, problems: _p }) => {
  await login(page, 'jakob', '/uebersicht?buch=privat')
  await expect(page.locator('main h1')).toBeVisible()
  await page.evaluate(() => {
    const box = document.createElement('div')
    box.style.background = '#ffffff'
    const p = document.createElement('p')
    p.textContent = 'Blasser Text'
    p.style.color = '#bbbbbb'
    const input = document.createElement('input')
    const btn = document.createElement('button')
    btn.style.width = '20px'
    btn.style.height = '20px'
    box.append(p, input, btn)
    document.querySelector('main')!.prepend(box)
  })
  const found = await page.evaluate(audit)
  expect(found.some((f) => f.startsWith('Kontrast') && f.includes('Blasser Text'))).toBe(true)
  expect(found.some((f) => f.startsWith('Feld ohne Beschriftung'))).toBe(true)
  expect(found.some((f) => f.startsWith('Knopf/Link ohne Namen'))).toBe(true)
})
