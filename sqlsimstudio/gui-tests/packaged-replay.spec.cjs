const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { once } = require('node:events');
const { spawn } = require('node:child_process');
const { test, expect } = require('@playwright/test');

const executable = process.env.SQLSIMSTUDIO_EXE;
const runLiveReplay = process.env.SQLSIMSTUDIO_LIVE_REPLAY_EXAMPLE === '1';
const server = process.env.SQLSIMSTUDIO_SERVER || 'localhost';
const database = process.env.SQLSIMSTUDIO_DATABASE || 'tempdb';
const replayFixture = path.join(__dirname, 'fixtures', 'replay-comparison.xml');

async function waitForBootstrap(bootstrapFile, process) {
  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    if (fs.existsSync(bootstrapFile)) {
      const url = fs.readFileSync(bootstrapFile, 'utf8').trim();
      if (url) return url;
    }
    if (process.exitCode !== null) {
      throw new Error(`Studio exited before bootstrap with code ${process.exitCode}.`);
    }
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error('Studio did not create its bootstrap file within 20 seconds.');
}

test('loads a converted replay file and compares its captured metrics', async ({ page }) => {
  test.skip(!executable, 'SQLSIMSTUDIO_EXE is required.');

  const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'sqlsimstudio-replay-'));
  const bootstrapFile = path.join(temporaryDirectory, 'bootstrap.txt');
  const studio = spawn(executable, ['--no-open', '--bootstrap-file', bootstrapFile], {
    cwd: path.dirname(executable),
    env: { ...process.env, SQLSIMSTUDIO_SETTINGS_DIR: path.join(temporaryDirectory, 'settings') },
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe']
  });

  try {
    const bootstrapUrl = await waitForBootstrap(bootstrapFile, studio);
    await page.goto(bootstrapUrl);
    await page.locator('[data-mode="replay"]').click();
    await page.locator('#replay-file-input').setInputFiles(replayFixture);

    await expect(page.locator('#replay-file-title')).toHaveText('replay-comparison.xml');
    await expect(page.locator('#replay-preflight')).toBeVisible();
    await expect(page.locator('#replay-event-count')).toHaveText('4');
    await expect(page.locator('#replay-recognized-count')).toHaveText('4');
    await expect(page.locator('#replay-skipped-count')).toHaveText('0');
    await expect(page.locator('#replay-session-count')).toHaveText('2');
    await expect(page.locator('#connection-summary-label')).toHaveText('Captured SPIDs');
    await expect(page.locator('#replay-capture-table .replay-capture-header')).toContainText('Captured SPID');
    await expect(page.locator('#total-threads')).toHaveText('2');

    if (runLiveReplay) {
      await page.locator('#server').fill(server);
      await page.locator('#database').fill(database);
      await page.locator('#authentication').selectOption('integrated');
      await page.locator('#telemetry-mode').selectOption('live');
      await page.locator('#replay-diagnostics').check();
      await expect(page.locator('#statistics-source')).toHaveValue('runtime');
      await page.locator('#run-workload').click();
      await expect(page.locator('#stop-run')).toContainText('View results', { timeout: 45_000 });
      await expect(page.locator('#run-state-label')).toHaveText('Run completed');
      await expect(page.locator('#percent-complete')).toHaveText('100%');
      await expect(page.locator('#progress-count')).toHaveText('4 / 4');
      await page.locator('#stop-run').click();
      await expect(page.locator('#result-status-title')).toHaveText('Run completed successfully');
      await expect(page.locator('#result-executions')).toHaveText('4');
      await expect(page.locator('#result-errors')).toHaveText('0');
      await expect(page.locator('#result-statistics-panel')).toBeVisible();
      await expect(page.locator('#result-statistics-title')).toHaveText('Runtime query statistics');
      await expect(page.locator('#query-report-table .query-report-row')).toHaveCount(3);
      await expect(page.locator('#result-replay-comparison-panel')).toBeVisible();
      await expect(page.locator('#replay-comparison-table .replay-comparison-row')).toHaveCount(3);
      const replaySpidCells = page.locator('#query-report-table .query-report-row > span:nth-child(3)');
      await expect(replaySpidCells).toHaveCount(3);
      const replaySpids = await replaySpidCells.allTextContents();
      expect(new Set(replaySpids).size).toBeGreaterThan(1);
      expect(replaySpids).not.toContain('Unavailable');
      await expect(page.locator('#replay-original-outcomes')).toContainText('4 ok');
      await expect(page.locator('#replay-result-outcomes')).toContainText('4 ok');
      await expect(page.locator('#replay-comparison-table')).not.toContainText('Not captured');
      await expect(page.locator('#replay-comparison-table')).not.toContainText('Enable diagnostics');
      await expect(page.locator('#export-results-json')).toBeEnabled();
    }
  } finally {
    if (studio.exitCode === null) {
      studio.kill();
      await once(studio, 'exit');
    }
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});
