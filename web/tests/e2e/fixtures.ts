import { test as base, expect, type Page } from '@playwright/test'

/** Jeder Test: Mock zurücksetzen und CSP-Verstösse/Seitenfehler sammeln (müssen leer bleiben). */
export const test = base.extend<{ problems: string[] }>({
  problems: async ({ page, request }, use) => {
    await request.post('/__mock/reset')
    const problems: string[] = []
    page.on('console', (m) => {
      const t = m.text()
      if (/Content Security Policy|Refused to/i.test(t)) problems.push(`CSP: ${t}`)
    })
    page.on('pageerror', (e) => problems.push(`pageerror: ${e.message}`))
    await use(problems)
    expect(problems, 'CSP-Verstösse oder Seitenfehler').toEqual([])
  },
})
export { expect }

/** Anmeldung über den Mock-Keycloak; optional Fahrzeugbuch wählen. */
export async function login(page: Page, user: 'jakob' | 'anna' | 'treuhand' | 'lea' | 'neu', path = '/uebersicht', tenant?: string) {
  await page.goto(path)
  await page.locator(`button[data-user="${user}"]`).click()
  if (tenant) {
    await page.getByRole('button', { name: new RegExp(`^${tenant.replace('-', '\\-')}`) }).click()
  }
}
