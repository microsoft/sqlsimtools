const path = require('node:path');
const { defineConfig } = require('@playwright/test');

// 'chromium' selects Playwright's bundled browser instead of an installed channel,
// so hosted runners need no Edge or Chrome present.
const browserChannel = process.env.SQLSIMSTUDIO_BROWSER_CHANNEL || 'msedge';

module.exports = defineConfig({
  testDir: __dirname,
  // The responsive sweep runs across engines under responsive.config.cjs.
  testIgnore: 'responsive.spec.cjs',
  fullyParallel: false,
  workers: 1,
  timeout: 180_000,
  expect: { timeout: 15_000 },
  outputDir: path.join(__dirname, '..', 'build', 'gui-test-results'),
  reporter: [['list'], ['html', {
    outputFolder: path.join(__dirname, '..', 'build', 'gui-test-report'),
    open: 'never'
  }]],
  use: {
    ...(browserChannel === 'chromium' ? {} : { channel: browserChannel }),
    headless: process.env.SQLSIMSTUDIO_HEADED !== '1',
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure',
    video: 'retain-on-failure',
    viewport: { width: 1440, height: 1000 }
  }
});