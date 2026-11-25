import { defineConfig, devices } from '@playwright/test'

const PORT = 4319
export default defineConfig({
  testDir: 'tests/e2e',
  testMatch: '**/*.spec.ts',
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 30_000,
  reporter: [['list']],
  use: {
    baseURL: `http://localhost:${PORT}`,
    ...devices['Desktop Chrome'],
    viewport: { width: 1440, height: 900 },
    locale: 'de-CH',
    timezoneId: 'Europe/Zurich',
    trace: 'off',
    screenshot: 'off',
    video: 'off',
    acceptDownloads: true,
  },
  webServer: {
    // Mock-API + OIDC + gebaute SPA (dist) mit CSP-Headern wie in Produktion
    command: `node mock/server.mjs --port ${PORT} --static dist`,
    url: `http://localhost:${PORT}/auth/config`,
    reuseExistingServer: false,
    timeout: 20_000,
  },
})
