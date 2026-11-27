// Review 11/2026 W6 (Rückfrage vor dem Verwerfen), W7 (Feldfehler, Fokus), W14 (Belegvorschau nach Status, Retry).
import { fileURLToPath } from 'node:url'
import { test, expect, login } from './fixtures'

const asset = (name: string) => fileURLToPath(new URL(`../../mock/assets/${name}`, import.meta.url))

test('Ungespeicherte Änderungen: Esc/Abbrechen fragen nach, unverändert schliesst direkt', async ({ page, problems: _p }) => {
  const writes: string[] = []
  page.on('request', (r) => {
    if (r.method() === 'POST' && r.url().includes('/sync')) writes.push(r.url())
  })
  await login(page, 'jakob', '/stammdaten/kunden?buch=privat')
  const open = page.getByRole('button', { name: 'Kunde erfassen' })
  await open.click()
  const dlg = page.getByRole('dialog', { name: 'Kunde erfassen' })
  await expect(dlg).toBeVisible()
  await page.keyboard.press('Escape') // nichts geändert
  await expect(dlg).toBeHidden()

  await open.click()
  await dlg.getByLabel('Name').fill('Entwurf AG')
  await page.keyboard.press('Escape')
  const ask = page.getByRole('dialog', { name: 'Änderungen verwerfen?' })
  await expect(ask).toBeVisible()
  await ask.getByRole('button', { name: 'Weiter bearbeiten' }).click()
  await expect(ask).toBeHidden()
  await expect(dlg).toBeVisible()
  await expect(dlg.getByLabel('Name')).toHaveValue('Entwurf AG')

  await dlg.getByRole('button', { name: 'Abbrechen' }).click()
  await ask.getByRole('button', { name: 'Verwerfen' }).click()
  await expect(dlg).toBeHidden()
  await expect(open).toBeFocused()
  expect(writes).toEqual([])
})

test('Speichern mit Fehlern: Fokus aufs erste Feld, Fehler verschwindet beim Korrigieren', async ({ page, problems: _p }) => {
  await login(page, 'anna')
  await page.getByRole('link', { name: 'Skoda Octavia öffnen' }).click()
  await page.getByRole('link', { name: 'Tankvorgänge', exact: true }).click()
  await page.getByRole('button', { name: 'Tankvorgang erfassen' }).click()
  const dlg = page.getByRole('dialog', { name: 'Tankvorgang erfassen' })
  await dlg.getByRole('button', { name: 'Speichern' }).click()
  const liter = dlg.getByLabel('Liter')
  await expect(liter).toBeFocused()
  await expect(liter).toHaveAttribute('aria-invalid', 'true')
  await expect(liter).toHaveAccessibleDescription('Pflichtfeld')
  await expect(dlg.getByText('Pflichtfeld')).toHaveCount(2)
  await liter.fill('40')
  await expect(liter).not.toHaveAttribute('aria-invalid', 'true')
  await expect(dlg.getByText('Pflichtfeld')).toHaveCount(1)
  await dlg.getByLabel('Betrag (CHF)').fill('80')
  await expect(dlg.getByText('Bitte die markierten Felder prüfen.')).toBeHidden()
})

test('Belegvorschau: Datei fehlt (404) vs. anderer Fehler mit «Erneut versuchen»', async ({ page, request, problems: _p }) => {
  await login(page, 'anna')
  await page.getByRole('link', { name: 'Skoda Octavia öffnen' }).click()
  await page.getByRole('link', { name: 'Tankvorgänge', exact: true }).click()
  // Beleg mit Metadaten, aber ohne Datei: Upload schlägt fehl und wird verworfen
  await request.post('/__mock/config', { data: { failUploadOnce: true } })
  await page.getByRole('button', { name: 'Tankvorgang erfassen' }).click()
  const dlg = page.getByRole('dialog', { name: 'Tankvorgang erfassen' })
  await dlg.getByLabel('Liter').fill('30')
  await dlg.getByLabel('Betrag (CHF)').fill('57')
  await dlg.getByLabel('Tankstelle').fill('Ohne Datei')
  await dlg.getByLabel('Foto oder PDF hinzufügen').setInputFiles(asset('receipt.jpg'))
  await dlg.getByRole('button', { name: 'Speichern' }).click()
  await expect(dlg).toBeHidden()
  await page.getByRole('button', { name: 'Verwerfen' }).click()

  const row = page.locator('tbody tr', { hasText: 'Ohne Datei' })
  await row.getByRole('button', { name: /1 Beleg vom .* anzeigen/ }).click()
  const prev = page.getByRole('dialog', { name: /Belege vom/ })
  await expect(prev.getByText('Datei nicht vorhanden – noch nicht hochgeladen')).toBeVisible()
  await expect(prev.getByText('Lädt …')).toBeHidden()
  await page.keyboard.press('Escape')

  // anderer Fehler (500, ohne automatische Wiederholung): Meldung + «Erneut versuchen» lädt nach
  let fail = true
  await page.route('**/attachments/*/blob', async (route) => {
    if (fail && route.request().method() === 'GET') {
      fail = false
      await route.fulfill({ status: 500, contentType: 'application/json', body: JSON.stringify({ detail: 'Interner Fehler' }) })
    } else await route.continue()
  })
  const other = page.locator('tbody tr').filter({ has: page.getByRole('button', { name: /Belege? vom .* anzeigen/ }) }).filter({ hasNotText: 'Ohne Datei' }).first()
  await other.getByRole('button', { name: /Belege? vom .* anzeigen/ }).click()
  const prev2 = page.getByRole('dialog', { name: /Belege vom/ })
  const retry = prev2.getByRole('button', { name: /erneut laden/ }).first()
  await expect(retry).toBeVisible()
  await retry.click()
  await expect(prev2.locator('img').first()).toBeVisible()
})
