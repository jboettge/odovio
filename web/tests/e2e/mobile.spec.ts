// Review 11/2026 W4/W19: schmale Bildschirme – Navigation als Ausklappmenü, Kopfzeile nicht sticky, Dialoge ohne
// horizontales Scrollen (WCAG 1.4.10).
import { test, expect, login } from './fixtures'
import type { Locator, Page } from '@playwright/test'

test.describe('390 px', () => {
  test.use({ viewport: { width: 390, height: 844 } })

  test('Navigation als Ausklappmenü, Inhalt sofort sichtbar, Kopfzeile scrollt mit', async ({ page, problems: _p }) => {
    await login(page, 'jakob', '/uebersicht?buch=privat')
    const h1 = page.getByRole('heading', { level: 1, name: 'Übersicht' })
    await expect(h1).toBeVisible()
    const nav = page.getByRole('navigation', { name: 'Hauptnavigation' })
    const toggle = page.getByRole('button', { name: 'Menü' })
    await expect(nav).toBeHidden()
    await expect(toggle).toHaveAttribute('aria-expanded', 'false')
    // Überschrift im ersten Viertel des Bildschirms (vorher erst nach ~1000 px Navigation)
    expect((await h1.boundingBox())!.y).toBeLessThan(844 / 4)
    expect(await page.locator('.topbar').evaluate((el) => getComputedStyle(el).position)).toBe('static')

    await toggle.click()
    await expect(toggle).toHaveAttribute('aria-expanded', 'true')
    await expect(nav).toBeVisible()
    await nav.getByRole('link', { name: 'Aktivität' }).focus()
    await page.keyboard.press('Escape')
    await expect(nav).toBeHidden()
    await expect(toggle).toBeFocused()

    // Auswahl eines Eintrags klappt das Menü wieder zu
    await toggle.click()
    await nav.getByRole('link', { name: 'Skoda Octavia' }).click()
    await expect(page).toHaveURL(/\/fahrzeuge\/[^/]+$/)
    await expect(nav).toBeHidden()
    await expect(page.getByRole('heading', { level: 1, name: 'Skoda Octavia' })).toBeVisible()
  })

  /** Dialog passt in die Breite, kein horizontales Scrollen im Dialog oder auf der Seite. */
  async function fits(page: Page, dlg: Locator, what: string) {
    await expect(dlg, what).toBeVisible()
    const m = await dlg.evaluate((d) => {
      const r = d.getBoundingClientRect()
      const body = d.querySelector('.dialog-body') as HTMLElement | null
      return { left: r.left, right: r.right, sw: body?.scrollWidth ?? 0, cw: body?.clientWidth ?? 0, vw: document.documentElement.clientWidth }
    })
    expect(m.left, `${what}: links im Bild`).toBeGreaterThanOrEqual(0)
    expect(m.right, `${what}: rechts im Bild`).toBeLessThanOrEqual(m.vw)
    expect(m.sw, `${what}: kein horizontales Scrollen im Dialog`).toBeLessThanOrEqual(m.cw)
  }

  test('Dialoge (Erfassen, Bearbeiten, Monatsabschluss, Verlauf) ohne horizontales Scrollen', async ({ page, problems: _p }) => {
    test.setTimeout(60_000)
    await login(page, 'jakob', '/uebersicht?buch=privat')
    await page.getByRole('link', { name: 'Skoda Octavia öffnen' }).click()
    await expect(page).toHaveURL(/\/fahrzeuge\/[^/]+$/)
    const vehicle = new URL(page.url()).pathname

    await page.getByRole('link', { name: 'Tanken erfassen' }).click()
    let dlg = page.getByRole('dialog', { name: 'Tankvorgang erfassen' })
    await dlg.getByRole('button', { name: 'Speichern' }).click() // mit Fehlermeldungen
    await fits(page, dlg, 'Tanken')
    await page.keyboard.press('Escape')
    await expect(dlg).toBeHidden()

    await page.goto(`${vehicle}/wartungen`)
    await page.getByRole('button', { name: 'Wartung erfassen' }).click()
    dlg = page.getByRole('dialog', { name: 'Wartung erfassen' })
    await dlg.getByRole('button', { name: 'Position hinzufügen' }).click()
    await dlg.getByRole('button', { name: 'Freie Position' }).click()
    await fits(page, dlg, 'Wartung mit Positionen')
    await dlg.getByRole('button', { name: 'Abbrechen' }).click()
    await page.getByRole('dialog', { name: 'Änderungen verwerfen?' }).getByRole('button', { name: 'Verwerfen' }).click()
    await expect(dlg).toBeHidden()

    await page.goto(`${vehicle}/kilometerstaende`)
    await page.getByRole('button', { name: 'Kilometerstand erfassen' }).click()
    await fits(page, page.getByRole('dialog', { name: 'Kilometerstand erfassen' }), 'Kilometerstand')
    await page.keyboard.press('Escape')

    await page.goto(`${vehicle}/monatsabschluss`)
    await expect(page.getByText('Alle Fahrten bestätigt')).toBeVisible()
    await page.getByRole('button', { name: 'Monat abschliessen …' }).click()
    await fits(page, page.getByRole('dialog', { name: /abschliessen$/ }), 'Monatsabschluss')
    await page.keyboard.press('Escape')

    await page.goto(`${vehicle}/fahrten`)
    await page.locator('tbody tr').first().getByRole('button', { name: /Verlauf/ }).click()
    await fits(page, page.getByRole('dialog').first(), 'Verlauf')
    await page.keyboard.press('Escape')

    await page.goto('/stammdaten/fahrzeuge')
    await page.getByRole('button', { name: 'Skoda Octavia bearbeiten' }).click()
    await fits(page, page.getByRole('dialog', { name: 'Fahrzeug bearbeiten' }), 'Fahrzeug bearbeiten')
    const m = await page.evaluate(() => ({ sw: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth }))
    expect(m.sw).toBeLessThanOrEqual(m.cw)
  })
})

test('1440 px: Navigation immer sichtbar, kein Menü-Knopf', async ({ page, problems: _p }) => {
  await login(page, 'jakob', '/uebersicht?buch=privat')
  await expect(page.getByRole('heading', { level: 1, name: 'Übersicht' })).toBeVisible()
  await expect(page.getByRole('navigation', { name: 'Hauptnavigation' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Menü' })).toBeHidden()
})
