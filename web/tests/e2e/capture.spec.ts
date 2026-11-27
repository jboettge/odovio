// Erfassen im Web: Tanken (mit Beleg), Wartung (Checkliste, Material aus dem Stamm), Kilometerstand.
import { fileURLToPath } from 'node:url'
import { test, expect, login } from './fixtures'

const asset = (name: string) => fileURLToPath(new URL(`../../mock/assets/${name}`, import.meta.url))
const iso = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`

async function openSkoda(page: import('@playwright/test').Page, tab?: string) {
  await login(page, 'anna')
  await page.getByRole('link', { name: 'Skoda Octavia öffnen' }).click()
  if (tab) await page.getByRole('link', { name: tab, exact: true }).click()
}

test('Tankvorgang mit Beleg erfassen, Plausibilität, danach bearbeiten', async ({ page, problems: _p }) => {
  await openSkoda(page)
  // Schnellaktion der Übersicht öffnet direkt das Formular
  await page.getByRole('link', { name: 'Tanken erfassen' }).click()
  const dlg = page.getByRole('dialog', { name: 'Tankvorgang erfassen' })
  await expect(dlg).toBeVisible()
  await expect(dlg.getByLabel('Kilometerstand')).not.toHaveValue('') // Vorschlag: aktueller Stand

  await dlg.getByRole('button', { name: 'Speichern' }).click()
  await expect(dlg.getByText('Pflichtfeld').first()).toBeVisible()

  await dlg.getByLabel('Kilometerstand').fill('53000')
  await expect(dlg.getByText(/Kleiner als .* – bitte prüfen/)).toBeVisible()
  await dlg.getByLabel('Kilometerstand').fill('53500')
  await dlg.getByLabel('Liter').fill('41,5')
  await dlg.getByLabel('Betrag (CHF)').fill('9')
  await expect(dlg.getByText(/CHF\/l wirkt ungewöhnlich/)).toBeVisible()
  await dlg.getByLabel('Betrag (CHF)').fill('78.40')
  await dlg.getByLabel('Tankstelle').fill('Migrol Testhausen')
  await dlg.getByLabel('Foto oder PDF hinzufügen').setInputFiles(asset('receipt.jpg'))
  await expect(dlg.getByText('receipt.jpg')).toBeVisible()
  await dlg.getByRole('button', { name: 'Speichern' }).click()
  await expect(dlg).toBeHidden()
  await expect(page.getByRole('status').filter({ hasText: 'Gespeichert' })).toBeVisible()

  const row = page.locator('tbody tr', { hasText: 'Migrol Testhausen' })
  await expect(row).toContainText('41.50 l')
  await row.getByRole('button', { name: /1 Belege .* anzeigen/ }).click()
  const prev = page.getByRole('dialog', { name: /Belege vom/ })
  await expect(prev.locator('img')).toBeVisible()
  await page.keyboard.press('Escape')

  await row.getByRole('button', { name: /bearbeiten/ }).click()
  const edit = page.getByRole('dialog', { name: 'Tankvorgang bearbeiten' })
  await expect(edit.getByLabel('Tankstelle')).toHaveValue('Migrol Testhausen')
  await expect(edit.getByText('Quittung · Foto')).toBeVisible()
  await edit.getByLabel('Betrag (CHF)').fill('79.10')
  await edit.getByRole('button', { name: 'Speichern' }).click()
  await expect(edit).toBeHidden()
  await expect(page.locator('tbody tr', { hasText: 'Migrol Testhausen' })).toContainText('79.10')
})

test('Fehlgeschlagener Beleg-Upload lässt sich wiederholen', async ({ page, request, problems: _p }) => {
  await openSkoda(page, 'Tankvorgänge')
  await request.post('/__mock/config', { data: { failUploadOnce: true } })
  await page.getByRole('button', { name: 'Tankvorgang erfassen' }).click()
  const dlg = page.getByRole('dialog', { name: 'Tankvorgang erfassen' })
  await dlg.getByLabel('Liter').fill('30')
  await dlg.getByLabel('Betrag (CHF)').fill('57')
  await dlg.getByLabel('Tankstelle').fill('Upload-Test')
  await dlg.getByLabel('Foto oder PDF hinzufügen').setInputFiles(asset('invoice.pdf'))
  await dlg.getByRole('button', { name: 'Speichern' }).click()
  await expect(dlg).toBeHidden()
  const box = page.getByText('Belege nicht hochgeladen')
  await expect(box).toBeVisible()
  await page.getByRole('button', { name: 'Erneut versuchen' }).click()
  await expect(page.getByRole('status').filter({ hasText: 'Beleg hochgeladen' })).toBeVisible()
  await expect(box).toBeHidden()
})

test('Wartung mit Checkliste und Material aus dem Stamm erfassen und Menge ändern', async ({ page, problems: _p }) => {
  await openSkoda(page, 'Wartungen')
  await page.getByRole('button', { name: 'Wartung erfassen' }).click()
  const dlg = page.getByRole('dialog', { name: 'Wartung erfassen' })
  await dlg.getByLabel('Bezeichnung').fill('Ölservice Web')
  await dlg.getByLabel('Kilometerstand', { exact: true }).fill('53600')
  await dlg.getByRole('button', { name: 'Position hinzufügen' }).click()
  await dlg.getByLabel('Checkliste Position 1', { exact: true }).fill('Öl gewechselt')
  await dlg.getByLabel('Material aus dem Stamm wählen').selectOption({ label: 'Motoröl 5W-30 (VW 504 00) · CHF 18.00/l' })
  await dlg.getByLabel('Menge').fill('4,5')
  await expect(dlg.getByText('Material total CHF 81.00')).toBeVisible()
  await expect(dlg.getByText('Leer = Summe Material (CHF 81.00)')).toBeVisible()
  await dlg.getByRole('button', { name: 'Speichern' }).click()
  await expect(dlg).toBeHidden()

  const card = page.locator('article', { hasText: 'Ölservice Web' })
  await expect(card).toContainText('CHF 81.00')
  await expect(card).toContainText('1/1 erledigt')
  await card.getByRole('button', { name: /bearbeiten/ }).click()
  const edit = page.getByRole('dialog', { name: 'Wartung bearbeiten' })
  await expect(edit.getByLabel('Artikel 1')).toHaveValue('Motoröl 5W-30')
  await edit.getByLabel('Menge').fill('5')
  await edit.getByRole('button', { name: 'Speichern' }).click()
  await expect(edit).toBeHidden()
  await expect(card).toContainText('CHF 90.00')
})

test('Kilometerstand erfassen; im abgeschlossenen Monat nur mit Begründung', async ({ page, problems: _p }) => {
  await openSkoda(page, 'Kilometerstände')
  await page.getByRole('button', { name: 'Kilometerstand erfassen' }).click()
  const dlg = page.getByRole('dialog', { name: 'Kilometerstand erfassen' })
  const now = new Date()
  await dlg.getByLabel('Datum').fill(iso(new Date(now.getFullYear(), now.getMonth() - 3, 2)))
  await dlg.getByLabel('Kilometerstand').fill('45000')
  await expect(dlg.getByLabel('Begründung der Korrektur')).toBeVisible()
  await dlg.getByRole('button', { name: 'Speichern' }).click()
  await expect(dlg.getByText('mindestens 10 Zeichen erforderlich')).toBeVisible()
  await dlg.getByLabel('Begründung der Korrektur').fill('Nachtrag aus dem Serviceheft')
  await dlg.getByLabel('Notiz').fill('Serviceheft')
  await dlg.getByRole('button', { name: 'Speichern' }).click()
  await expect(dlg).toBeHidden()
  await expect(page.locator('.timeline li', { hasText: 'Serviceheft' })).toBeVisible()
})

test('Lesezugriff: keine Erfassen-Knöpfe', async ({ page, problems: _p }) => {
  await login(page, 'treuhand', '/uebersicht', 'privat')
  await page.getByRole('link', { name: 'Skoda Octavia öffnen' }).click()
  await expect(page.getByRole('link', { name: 'Tanken erfassen' })).toHaveCount(0)
  await page.getByRole('link', { name: 'Tankvorgänge', exact: true }).click()
  await expect(page.getByRole('heading', { name: 'Tankvorgänge' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Tankvorgang erfassen' })).toHaveCount(0)
  await expect(page.getByRole('button', { name: /bearbeiten/ })).toHaveCount(0)
})
