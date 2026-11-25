import { test, expect, login } from './fixtures'

test('Login mit PKCE, Fahrzeugbuch wählen, Rolle sichtbar', async ({ page, problems: _p }) => {
  await page.goto('/')
  await page.getByRole('button', { name: 'Mit Keycloak anmelden' }).click()
  await expect(page).toHaveURL(/protocol\/openid-connect\/auth\?.*code_challenge_method=S256/)
  await page.locator('button[data-user="jakob"]').click()
  await expect(page.getByRole('heading', { name: 'Fahrzeugbuch wählen' })).toBeVisible()
  await page.getByRole('button', { name: /^privat/ }).click()
  await expect(page).toHaveURL(/\/uebersicht$/)
  await expect(page.getByRole('heading', { level: 1, name: 'Übersicht' })).toBeVisible()
  await expect(page.locator('.topbar .badge')).toHaveText('Verwalten')
  // Tokens nur im sessionStorage, nie im localStorage
  const ls = await page.evaluate(() => JSON.stringify(window.localStorage))
  expect(ls).not.toMatch(/access_token|refresh_token/)
  const ss = await page.evaluate(() => Object.keys(window.sessionStorage).join(','))
  expect(ss).toMatch(/oidc\.user/)
})

test('Deep-Link /verwaltung/mitglieder?buch=privat führt nach Login zurück', async ({ page, problems: _p }) => {
  await login(page, 'jakob', '/verwaltung/mitglieder?buch=privat')
  await expect(page).toHaveURL(/\/verwaltung\/mitglieder/)
  await expect(page.getByRole('heading', { level: 1, name: 'Mitglieder' })).toBeVisible()
  await expect(page.getByRole('cell', { name: 'Anna Beispiel', exact: true })).toBeVisible()
})

test('Deep-Link /stammdaten/steuerparameter: Schreibrolle kann bearbeiten', async ({ page, problems: _p }) => {
  await login(page, 'anna', '/stammdaten/steuerparameter')
  await expect(page.getByRole('heading', { name: /Steuerparameter \d{4}/ })).toBeVisible()
  await expect(page.getByText('Annahmen – mit Treuhand prüfen')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Parameter erfassen' })).toBeVisible()
  // Schreibrolle: keine Verwaltung in der Navigation, Monatsabschluss vorhanden
  await expect(page.getByRole('navigation', { name: 'Hauptnavigation' }).getByRole('link', { name: 'Mitglieder' })).toHaveCount(0)
})

test('Leserolle: keine Verwaltung, kein Monatsabschluss, Privatfahrten maskiert', async ({ page, problems: _p }) => {
  await login(page, 'treuhand', '/uebersicht', 'privat')
  const nav = page.getByRole('navigation', { name: 'Hauptnavigation' })
  await expect(nav.getByRole('link', { name: 'Mitglieder' })).toHaveCount(0)
  await nav.getByRole('link', { name: 'Skoda Octavia' }).click()
  await expect(page.getByRole('navigation', { name: 'Bereiche des Fahrzeugs' }).getByRole('link', { name: 'Monatsabschluss' })).toHaveCount(0)
  await page.getByRole('link', { name: 'Fahrten', exact: true }).click()
  await page.getByLabel('Kategorie').selectOption('private')
  const first = page.locator('tbody tr').first()
  await expect(first).toContainText('Privatfahrt')
  await expect(page.locator('tbody')).not.toContainText('Luzern')
  // direkte Adresse → kein Zugriff
  await page.goto('/verwaltung/mitglieder')
  await expect(page.getByRole('heading', { level: 1, name: 'Kein Zugriff' })).toBeVisible()
  // Stammdaten nur ansehen
  await page.goto('/stammdaten/orte')
  await expect(page.getByText('Nur Lesezugriff')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Ort erfassen' })).toHaveCount(0)
  await expect(page.getByRole('cell', { name: 'Privater Ort vertraulich' })).toBeVisible()
})

test('Abgelaufenes Token wird per Refresh-Token erneuert', async ({ page, request, problems: _p }) => {
  await login(page, 'anna')
  await expect(page.getByRole('heading', { level: 1, name: 'Übersicht' })).toBeVisible()
  await request.post('/__mock/expire-tokens')
  await page.getByRole('navigation', { name: 'Hauptnavigation' }).getByRole('link', { name: 'Integrität' }).click()
  await page.getByRole('button', { name: 'Prüfung starten' }).click()
  await expect(page.getByText('Keine Unstimmigkeiten gefunden')).toBeVisible()
})

test('Abmelden leert die Sitzung', async ({ page, problems: _p }) => {
  await login(page, 'anna')
  await expect(page.getByRole('heading', { level: 1, name: 'Übersicht' })).toBeVisible()
  await page.getByRole('button', { name: 'Abmelden' }).click()
  await expect(page.getByRole('button', { name: 'Mit Keycloak anmelden' })).toBeVisible()
  const ss = await page.evaluate(() => Object.keys(window.sessionStorage).filter((k) => k.startsWith('oidc')))
  expect(ss).toEqual([])
})
