// Screenshots der Hauptseiten (hell + dunkel, 1440×900, deviceScaleFactor 1) nach screenshots/*.png.
// Voraussetzung: npm run build. Startet den Mock-Server selbst.
import { spawn } from 'node:child_process'
import { mkdir } from 'node:fs/promises'
import { chromium } from '@playwright/test'

const PORT = 4320
const BASE = `http://localhost:${PORT}`
const OUT = new URL('../../screenshots/', import.meta.url).pathname

const server = spawn(process.execPath, ['mock/server.mjs', '--port', String(PORT), '--static', 'dist'], { stdio: ['ignore', 'pipe', 'inherit'] })
await new Promise((resolve, reject) => {
  server.stdout.on('data', (d) => String(d).includes('Mock-Server') && resolve())
  server.on('exit', (c) => reject(new Error(`Mock beendet (${c})`)))
})

async function login(page, user, path, tenant) {
  await page.goto(BASE + path)
  await page.locator(`button[data-user="${user}"]`).click()
  if (tenant) await page.getByRole('button', { name: new RegExp(`^${tenant}`) }).click()
  await page.waitForLoadState('networkidle')
}

async function shot(page, name, scheme) {
  await page.waitForLoadState('networkidle')
  await page.mouse.move(0, 899)
  await page.waitForTimeout(250)
  await page.screenshot({ path: `${OUT}${name}-${scheme}.png` })
  console.log(`screenshots/${name}-${scheme}.png`)
}

await mkdir(OUT, { recursive: true })
const browser = await chromium.launch()
try {
  for (const scheme of ['light', 'dark']) {
    await fetch(`${BASE}/__mock/reset`, { method: 'POST' })
    const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1, colorScheme: scheme, locale: 'de-CH', timezoneId: 'Europe/Zurich' })
    const page = await ctx.newPage()
    await page.goto(BASE + '/')
    await shot(page, '01-start', scheme)

    await login(page, 'jakob', '/uebersicht', 'privat')
    await shot(page, '02-dashboard', scheme)
    const skoda = page.getByRole('link', { name: 'Skoda Octavia öffnen' })
    await skoda.click()
    await page.getByRole('heading', { name: 'Verbrauch' }).waitFor()
    await shot(page, '03-fahrzeug-uebersicht', scheme)
    const vid = page.url().split('/fahrzeuge/')[1]
    const go = async (sub) => {
      await page.goto(`${BASE}/fahrzeuge/${vid}${sub}`)
      await page.waitForLoadState('networkidle')
    }
    await go('/fahrten')
    await shot(page, '04-fahrten', scheme)
    await page.locator('tbody tr').first().getByRole('button', { name: /Verlauf/ }).click()
    await page.getByRole('dialog').waitFor()
    await shot(page, '05-verlauf-panel', scheme)
    await page.keyboard.press('Escape')
    await go('/tanken')
    await shot(page, '06-tankvorgaenge', scheme)
    await page.getByRole('button', { name: /Belege vom/ }).first().click()
    await page.getByRole('dialog').locator('img').first().waitFor()
    await shot(page, '07-belege', scheme)
    await page.keyboard.press('Escape')
    await go('/wartungen')
    await page.getByRole('button', { name: /Checkliste, Material und Belege/ }).nth(1).click()
    await shot(page, '08-wartungen', scheme)
    await go('/kilometerstaende')
    await shot(page, '09-kilometerstaende', scheme)
    await go('/berichte')
    await page.getByText('Kilometer nach Kategorie').waitFor()
    await page.mouse.wheel(0, 380)
    await shot(page, '10-berichte', scheme)
    await go('/monatsabschluss')
    await page.getByText('Alle Fahrten bestätigt').waitFor()
    await shot(page, '11-monatsabschluss', scheme)
    await page.getByRole('button', { name: 'Monat abschliessen …' }).click()
    await shot(page, '12-monatsabschluss-bestaetigen', scheme)
    await page.keyboard.press('Escape')

    await page.goto(`${BASE}/aktivitaet`)
    await shot(page, '13-aktivitaet', scheme)
    await page.goto(`${BASE}/integritaet`)
    await page.getByRole('button', { name: 'Prüfung starten' }).click()
    await page.getByText('Keine Unstimmigkeiten gefunden').waitFor()
    await shot(page, '14-integritaet', scheme)
    await page.goto(`${BASE}/stammdaten/orte`)
    await shot(page, '15-stammdaten-orte', scheme)
    await page.goto(`${BASE}/stammdaten/fahrzeuge`)
    await page.getByRole('button', { name: 'Skoda Octavia bearbeiten' }).click()
    await shot(page, '16-stammdaten-fahrzeug-bearbeiten', scheme)
    await page.keyboard.press('Escape')
    await page.goto(`${BASE}/stammdaten/steuerparameter`)
    await page.getByText('Wirksame Werte').waitFor()
    await shot(page, '17-steuerparameter', scheme)
    await page.goto(`${BASE}/verwaltung/mitglieder`)
    await page.getByRole('heading', { name: 'Mitglieder', level: 2 }).waitFor()
    await shot(page, '18-mitglieder', scheme)
    await page.goto(`${BASE}/konto`)
    await shot(page, '19-konto', scheme)
    await ctx.close()

    // Leserolle (Treuhand): Privatfahrten maskiert, keine Verwaltung
    const ctx2 = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1, colorScheme: scheme, locale: 'de-CH', timezoneId: 'Europe/Zurich' })
    const p2 = await ctx2.newPage()
    await login(p2, 'treuhand', `/fahrzeuge/${vid}/fahrten?buch=privat`)
    await p2.getByLabel('Kategorie').selectOption('private')
    await shot(p2, '20-leserolle-fahrten', scheme)
    await ctx2.close()
  }
} finally {
  await browser.close()
  server.kill()
}
