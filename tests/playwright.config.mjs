import { defineConfig } from '@playwright/test';

// Studio uses a self-signed cert on https://studio.strike48.local:8888, so TLS
// verification is disabled below. Override BASE_URL if you changed DOMAIN /
// CADDY_HTTP_PORT in .env.
const BASE_URL = process.env.STUDIO_URL || 'https://studio.strike48.local:8888';

export default defineConfig({
  testDir: '.',
  testMatch: /.*\.spec\.mjs/,
  timeout: 120_000,
  expect: { timeout: 30_000 },
  fullyParallel: false,
  retries: 0,
  reporter: [['list']],
  use: {
    baseURL: BASE_URL,
    ignoreHTTPSErrors: true,
    viewport: { width: 1400, height: 900 },
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure',
    // On macOS/Linux with the Playwright-managed browser, leave this unset.
    // On hosts without the bundled Chromium's system libs (e.g. NixOS), point
    // it at a system Chrome:  PLAYWRIGHT_CHROMIUM_PATH=$(command -v google-chrome-stable)
    launchOptions: process.env.PLAYWRIGHT_CHROMIUM_PATH
      ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_PATH }
      : {},
  },
  projects: [{ name: 'chromium', use: { browserName: 'chromium' } }],
});
