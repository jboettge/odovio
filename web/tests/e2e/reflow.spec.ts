import { test, expect, login } from './fixtures'

// WCAG 1.4.10 (Reflow): bei 390 px Breite kein horizontales Scrollen der Seite (Tabellen scrollen in ihrem Container).
test.use({ viewport: { width: 390, height: 844 } })

test('Reflow 390 px: Hauptseiten ohne horizontales Scrollen', async ({ page, problems: _p }) => {
  test.setTimeout(60_000)
  await login(page, 'jakob', '/uebersicht?buch=privat')
  await expect(page.getByRole('heading', { level: 1, name: 'Übersicht' })).toBeVisible()
  await page.getByRole('link', { name: 'Skoda Octavia öffnen' }).click()
  await expect(page).toHaveURL(/\/fahrzeuge\/[^/]+$/)
  const vehicle = new URL(page.url()).pathname

  const pages = [
    '/uebersicht',
    vehicle,
    `${vehicle}/fahrten`,
    `${vehicle}/tanken`,
    `${vehicle}/wartungen`,
    `${vehicle}/kilometerstaende`,
    `${vehicle}/berichte`,
    `${vehicle}/monatsabschluss`,
    '/aktivitaet',
    '/integritaet',
    '/stammdaten/fahrzeuge',
    '/stammdaten/orte',
    '/stammdaten/kunden',
    '/stammdaten/regeln',
    '/stammdaten/steuerparameter',
    '/stammdaten/material',
    '/verwaltung/mitglieder',
    '/konto',
  ]
  const overflow: string[] = []
  for (const path of pages) {
    await page.goto(path)
    await expect(page).toHaveURL((u) => u.pathname === path)
    await expect(page.locator('main h1')).toBeVisible()
    await page.waitForLoadState('networkidle')
    await expect(page.locator('.loading')).toHaveCount(0)
    const m = await page.evaluate(() => ({ sw: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth }))
    if (m.sw > m.cw) overflow.push(`${path}: ${m.sw} > ${m.cw}`)
  }
  expect(overflow, 'Seiten mit horizontalem Scrollen').toEqual([])
})
