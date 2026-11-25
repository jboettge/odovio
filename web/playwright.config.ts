import { defineConfig, devices } from '@playwright/test'

const PORT = 4319
/** Lasttest: eigener Mock mit grossem Datenbestand (--seed large) */
export const PERF_PORT = 4321

const browser = {
  ...devices['Desktop Chrome'],
  viewport: { width: 1440, height: 900 },
  locale: 'de-CH',
  timezoneId: 'Europe/Zurich',
  trace: 'off',
  screenshot: 'off',
  video: 'off',
  acceptDownloads: true,
} as const

export default defineConfig({
  testDir: 'tests/e2e',
  testMatch: '**/*.spec.ts',
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 30_000,
  reporter: [['list']],
  use: browser,
  projects: [
    {
      name: 'functional',
      testIgnore: '**/*.perf.spec.ts',
      use: { ...browser, baseURL: `http://localhost:${PORT}` },
    },
    {
      name: 'perf',
      testMatch: '**/*.perf.spec.ts',
      timeout: 120_000,
      use: { ...browser, baseURL: `http://localhost:${PERF_PORT}` },
    },
  ],
  webServer: [
    {
      // Mock-API + OIDC + gebaute SPA (dist) mit CSP-Headern wie in Produktion
      command: `node mock/server.mjs --port ${PORT} --static dist`,
      url: `http://localhost:${PORT}/auth/config`,
      reuseExistingServer: false,
      timeout: 20_000,
    },
    {
      // grosser Datenbestand: 3 Fahrzeuge × 30k Fahrten, 5k Tankvorgänge, > 90k Journal-Einträge
      command: `node mock/server.mjs --port ${PERF_PORT} --static dist --seed large`,
      url: `http://localhost:${PERF_PORT}/auth/config`,
      reuseExistingServer: false,
      timeout: 90_000,
    },
  ],
})
