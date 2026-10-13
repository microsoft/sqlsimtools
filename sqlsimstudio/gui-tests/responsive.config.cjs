const path = require('node:path');
const { defineConfig } = require('@playwright/test');

// Responsive layout sweep across browser engines. Run with:
//   playwright test --config gui-tests/responsive.config.cjs [--project <name>]
// Set SQLSIMSTUDIO_BROWSER_CHANNEL=chromium to replace the installed Edge and
// Chrome channels with Playwright's bundled Chromium, as CI does.
const bundledChromium = process.env.SQLSIMSTUDIO_BROWSER_CHANNEL === 'chromium';
const wideFontChannel = bundledChromium ? {} : { channel: 'msedge' };

const chromiumProjects = bundledChromium
  ? [{ name: 'chromium', use: { browserName: 'chromium' } }]
  : [
    // Windows display scaling changes pixel rounding, so cover 150% and 125%.
    { name: 'edge', use: { browserName: 'chromium', channel: 'msedge', deviceScaleFactor: 1.5 } },
    { name: 'chrome', use: { browserName: 'chromium', channel: 'chrome', deviceScaleFactor: 1.25 } }
  ];

module.exports = defineConfig({
  testDir: __dirname,
  testMatch: 'responsive.spec.cjs',
  fullyParallel: true,
  // Each test drives one browser through 19 widths; more workers only contend.
  workers: 4,
  timeout: 180_000,
  expect: { timeout: 15_000 },
  outputDir: path.join(__dirname, '..', 'build', 'responsive-test-results'),
  reporter: [['list'], ['html', {
    outputFolder: path.join(__dirname, '..', 'build', 'responsive-test-report'),
    open: 'never'
  }]],
  use: {
    headless: process.env.SQLSIMSTUDIO_HEADED !== '1',
    trace: 'retain-on-failure',
    viewport: { width: 1440, height: 900 }
  },
  projects: [
    ...chromiumProjects,
    { name: 'firefox', use: { browserName: 'firefox' } },
    // WebKit is Safari's engine; this is the closest Windows can get to Safari.
    { name: 'webkit', use: { browserName: 'webkit' } },
    {
      name: 'wide-font',
      use: { browserName: 'chromium', ...wideFontChannel },
      metadata: { wideFont: true }
    }
  ]
});
