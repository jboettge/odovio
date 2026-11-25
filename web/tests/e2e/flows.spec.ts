import { test, expect, login } from './fixtures'

test('Dashboard zeigt Kacheln, offene Bestätigungen und Lücke', async ({ page, problems: _p }) => {
  await login(page, 'anna')
  const tile = page.getByRole('link', { name: 'Skoda Octavia öffnen' })
  await expect(tile).toContainText(/53[’']410 km/)
  await expect(tile).toContainText('4 Fahrten bestätigen')
  await expect(tile).toContainText('Lücke von 12 km')
  await expect(page.getByRole('heading', { name: 'Letzte Aktivität' })).toBeVisible()
})

test('Fahrten filtern, geschätzte km markiert, Verlauf im Seitenpanel', async ({ page, problems: _p }) => {
  await login(page, 'anna')
  await page.getByRole('link', { name: 'Skoda Octavia öffnen' }).click()
  await page.getByRole('link', { name: '4 Fahrten bestätigen' }).click()
  await expect(page.locator('tbody tr')).toHaveCount(4)
  await expect(page.locator('tbody .badge', { hasText: 'ca.' })).toHaveCount(2)
  await page.locator('tbody tr').first().getByRole('button', { name: /Verlauf/ }).click()
  const panel = page.getByRole('dialog', { name: 'Verlauf der Fahrt' })
  await expect(panel).toBeVisible()
  await expect(panel).toContainText('Erfasst · Version 1')
  await page.keyboard.press('Escape')
  await expect(panel).toBeHidden()
})

test('Storno im abgeschlossenen Monat verlangt Begründung', async ({ page, problems: _p }) => {
  await login(page, 'anna')
  await page.getByRole('link', { name: 'Skoda Octavia öffnen' }).click()
  await page.getByRole('link', { name: 'Fahrten', exact: true }).click()
  await page.getByLabel('Status').selectOption('locked')
  await page.locator('tbody tr').first().getByRole('button', { name: /stornieren/ }).click()
  const dlg = page.getByRole('dialog', { name: 'Fahrt stornieren' })
  await dlg.getByRole('button', { name: 'Stornieren' }).click()
  await expect(dlg.getByText('mindestens 10 Zeichen erforderlich')).toBeVisible()
  await dlg.getByLabel('Begründung').fill('Doppelt erfasst, Korrektur gemäss Tacho')
  await dlg.getByRole('button', { name: 'Stornieren' }).click()
  await expect(page.getByRole('status').filter({ hasText: 'Fahrt storniert' })).toBeVisible()
})

test('Monatsabschluss mit Bestätigung', async ({ page, problems: _p }) => {
  await login(page, 'anna')
  await page.getByRole('link', { name: 'Skoda Octavia öffnen' }).click()
  await page.getByRole('link', { name: 'Monatsabschluss' }).click()
  await expect(page.getByText('Alle Fahrten bestätigt')).toBeVisible()
  await page.getByRole('button', { name: 'Monat abschliessen …' }).click()
  const dlg = page.getByRole('dialog')
  await expect(dlg).toContainText('unveränderlich gesperrt')
  await dlg.getByRole('button', { name: 'Verbindlich abschliessen' }).click()
  await expect(page.getByRole('status').filter({ hasText: 'abgeschlossen' })).toBeVisible()
  await expect(page.locator('.badge', { hasText: 'abgeschlossen' }).first()).toBeVisible()
})

test('Laufender Monat kann nicht abgeschlossen werden', async ({ page, problems: _p }) => {
  await login(page, 'anna')
  await page.getByRole('link', { name: 'Skoda Octavia öffnen' }).click()
  await page.getByRole('link', { name: 'Monatsabschluss' }).click()
  const sel = page.locator('#mc-month')
  await sel.selectOption({ index: 0 })
  await expect(page.getByText('Nur abgelaufene Monate können abgeschlossen werden.')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Monat abschliessen …' })).toBeDisabled()
})

test('Stammdaten: Kunde erfassen mit Validierung (Sync-Op)', async ({ page, problems: _p }) => {
  await login(page, 'anna', '/stammdaten/kunden')
  await page.getByRole('button', { name: 'Kunde erfassen' }).click()
  const dlg = page.getByRole('dialog', { name: 'Kunde erfassen' })
  await dlg.getByRole('button', { name: 'Speichern' }).click()
  await expect(dlg.getByText('Pflichtfeld')).toBeVisible()
  await dlg.getByLabel('Name').fill('Velo Kurier GmbH')
  await dlg.getByLabel('Referenz').fill('K-2001')
  await dlg.getByRole('button', { name: 'Speichern' }).click()
  await expect(dlg).toBeHidden()
  await expect(page.getByRole('cell', { name: 'Velo Kurier GmbH', exact: true })).toBeVisible()
})

test('Steuerparameter erfassen (nur Web-Client)', async ({ page, problems: _p }) => {
  await login(page, 'jakob', '/stammdaten/steuerparameter?buch=privat')
  await page.getByRole('button', { name: 'Parameter erfassen' }).click()
  const dlg = page.getByRole('dialog', { name: 'Steuerparameter erfassen' })
  await dlg.getByLabel('Parameter').selectOption('commute_rate')
  await dlg.getByLabel(/^Wert/).fill('0.7')
  await dlg.getByRole('button', { name: 'Speichern' }).click()
  await expect(dlg).toBeHidden()
  await expect(page.getByRole('cell', { name: 'Arbeitsweg Privatauto commute_rate' })).toBeVisible()
})

test('Mitglieder: einladen, Rolle ändern, entfernen, letzter Verwalter geschützt', async ({ page, problems: _p }) => {
  await login(page, 'jakob', '/verwaltung/mitglieder?buch=privat')
  await page.getByLabel('Benutzername oder E-Mail').fill('nora@example.ch')
  await page.getByLabel('Rolle', { exact: true }).selectOption('read')
  await page.getByRole('button', { name: 'Hinzufügen' }).click()
  await expect(page.getByRole('cell', { name: 'Nora Neu', exact: true })).toBeVisible()
  await page.getByLabel('Rolle von Nora Neu').selectOption('write')
  await expect(page.getByRole('status').filter({ hasText: 'Rolle von Nora Neu: Bearbeiten' })).toBeVisible()
  await page.getByRole('button', { name: 'Nora Neu entfernen' }).click()
  await page.getByRole('dialog', { name: 'Mitglied entfernen' }).getByRole('button', { name: 'Entfernen' }).click()
  await expect(page.getByRole('cell', { name: 'Nora Neu', exact: true })).toHaveCount(0)
  // letzter Verwalter
  await page.getByLabel('Rolle von Jakob Muster').selectOption('write')
  await expect(page.getByRole('alert').filter({ hasText: 'Letzter Verwalter' })).toBeVisible()
})

test('Mitglieder ohne Keycloak-Verwaltung → Hinweis «In Keycloak verwalten», keine Mutationen', async ({ page, request, problems: _p }) => {
  await request.post('/__mock/config', { data: { members501: true } })
  await login(page, 'jakob', '/verwaltung/mitglieder?buch=privat')
  await expect(page.getByText('In Keycloak verwalten')).toBeVisible()
  await expect(page.getByRole('cell', { name: 'Anna Beispiel', exact: true })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Hinzufügen' })).toHaveCount(0)
  await expect(page.getByRole('button', { name: /entfernen/ })).toHaveCount(0)
})

test('429 zeigt Retry-After verständlich an (ohne automatische Wiederholung)', async ({ page, request, problems: _p }) => {
  await login(page, 'anna', '/integritaet')
  await request.post('/__mock/config', { data: { rate429: 'verify' } })
  await page.getByRole('button', { name: 'Prüfung starten' }).click()
  await expect(page.getByText('Zu viele Anfragen – bitte in 30 s erneut versuchen.')).toBeVisible()
})

test('Berichte: Fahrtenbuch-PDF wird heruntergeladen, Jahresbericht-Kacheln', async ({ page, problems: _p }) => {
  await login(page, 'anna')
  await page.getByRole('link', { name: 'Skoda Octavia öffnen' }).click()
  await page.getByRole('link', { name: 'Berichte' }).click()
  await expect(page.getByText('Kilometer nach Kategorie')).toBeVisible()
  await expect(page.getByText('Annahmen – mit Treuhand prüfen')).toBeVisible()
  const [dl] = await Promise.all([
    page.waitForEvent('download'),
    page.getByRole('region', { name: 'Fahrtenbuch (PDF)' }).getByRole('button', { name: 'PDF herunterladen' }).click(),
  ])
  expect(dl.suggestedFilename()).toMatch(/^Fahrtenbuch_.*\.pdf$/)
})

test('Belege-Vorschau als Blob-URL', async ({ page, problems: _p }) => {
  await login(page, 'anna')
  await page.getByRole('link', { name: 'Skoda Octavia öffnen' }).click()
  await page.getByRole('link', { name: 'Tankvorgänge' }).click()
  await page.getByRole('button', { name: /Belege vom/ }).first().click()
  const img = page.getByRole('dialog').locator('img').first()
  await expect(img).toBeVisible()
  expect(await img.getAttribute('src')).toMatch(/^blob:/)
})

test('Aktivität: Nachladen und Filter', async ({ page, problems: _p }) => {
  await login(page, 'anna', '/aktivitaet')
  await expect(page.locator('.feed li').first()).toBeVisible()
  const before = await page.locator('.feed li').count()
  await page.getByRole('button', { name: 'Ältere laden' }).click()
  await expect.poll(() => page.locator('.feed li').count()).toBeGreaterThan(before)
  await page.getByLabel('Objekt').selectOption('fuel')
  await expect(page.locator('.feed li').first()).toContainText('Tankvorgang')
})
