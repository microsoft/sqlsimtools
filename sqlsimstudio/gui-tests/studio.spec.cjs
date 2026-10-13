const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { once } = require('node:events');
const { spawn } = require('node:child_process');
const { test, expect } = require('@playwright/test');

const executable = process.env.SQLSIMSTUDIO_EXE;
const server = process.env.SQLSIMSTUDIO_SERVER || 'localhost';
const database = process.env.SQLSIMSTUDIO_DATABASE || 'tempdb';
const queryStoreDatabase = process.env.SQLSIMSTUDIO_QUERY_STORE_DATABASE || '';
const replayFile = process.env.SQLSIMSTUDIO_REPLAY_FILE;
const captureScreenshots = process.env.SQLSIMSTUDIO_CAPTURE_SCREENSHOTS === '1';

function delay(milliseconds) {
  return new Promise(resolve => setTimeout(resolve, milliseconds));
}

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
    await delay(100);
  }
  throw new Error('Studio did not create its bootstrap file within 20 seconds.');
}

async function configureQuery(page, { engine = 'sqlsim', telemetry = 'final', query, statistics = 'none' }) {
  await page.locator('[data-view="configure"]').click();
  await page.locator('#execution-engine').selectOption(engine);
  await page.locator('[data-mode="query"]').click();
  await page.locator('#server').fill(server);
  await page.locator('#database').fill(database);
  await page.locator('#authentication').selectOption('integrated');
  await page.locator('#query-text').fill(query);
  await page.locator('#query-mode .simple-threads').fill('1');
  await page.locator('#query-mode .simple-iterations').fill('1');
  await page.locator('#statistics-source').selectOption(statistics);
  await page.locator('#telemetry-mode').selectOption(telemetry);
}

async function runAndOpenResults(page, { automatic = false, requireRunning = false } = {}) {
  await page.locator('#run-workload').click();
  await expect(page.locator('#monitor-view')).toHaveClass(/active/);
  await expect(page.locator('#stop-run')).toBeEnabled();
  if (requireRunning) {
    await expect(page.locator('#run-state-label')).toHaveText('Running...');
    await expect(page.locator('.run-state')).toHaveClass(/running/);
  }
  if (automatic) {
    await expect(page.locator('#results-view')).toHaveClass(/active/, { timeout: 45_000 });
  } else {
    await expect(page.locator('#stop-run')).toContainText('View results', { timeout: 45_000 });
    await page.locator('#stop-run').click();
    await expect(page.locator('#results-view')).toHaveClass(/active/);
  }
  await expect(page.locator('#result-status-title')).toHaveText('Run completed successfully');
}

test('exercises sqlsim Studio GUI workflows', async ({ page }) => {
  test.skip(!executable, 'SQLSIMSTUDIO_EXE is required.');
  test.skip(!replayFile, 'SQLSIMSTUDIO_REPLAY_FILE is required.');

  const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'sqlsimstudio-gui-'));
  const bootstrapFile = path.join(temporaryDirectory, 'bootstrap.txt');
  const studio = spawn(executable, ['--no-open', '--bootstrap-file', bootstrapFile], {
    cwd: path.dirname(executable),
    env: { ...process.env, SQLSIMSTUDIO_SETTINGS_DIR: path.join(temporaryDirectory, 'settings') },
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe']
  });
  let processError = '';
  studio.stderr.on('data', chunk => { processError += chunk.toString(); });
  const browserErrors = [];
  page.on('console', message => {
    if (message.type() === 'error') browserErrors.push(message.text());
  });
  page.on('pageerror', error => browserErrors.push(error.message));

  try {
    const bootstrapUrl = await waitForBootstrap(bootstrapFile, studio);
    await page.goto(bootstrapUrl);
    await expect(page).toHaveURL(/#configure$/);
    await expect(page.locator('#runtime-status')).not.toHaveClass(/offline/);
    await expect(page.locator('#runtime-status')).toContainText(/Studio ready · v\d+\.\d+\.\d+/);
    await expect(page.locator('#execution-engine option[value="sqlsim"]')).toHaveText(/^sqlsim \d+\.\d+\.\d+ · Native ODBC$/);
    await expect(page.locator('#execution-engine option[value="sqlpysim"]')).toHaveText(/^sqlpysim \d+\.\d+\.\d+ · mssql-python$/);
    await expect(page.locator('#runtime-status')).toHaveAttribute('title', /SQL target status is shown when a workload runs/);
    const expectedStage = process.platform === 'linux' || process.platform === 'darwin' || process.arch === 'arm64'
      ? 'Private Preview'
      : 'Public Preview';
    await expect(page.locator('#product-stage')).toHaveText(expectedStage);

    await test.step('run validates the target before opening Monitor', async () => {
      await configureQuery(page, {
        engine: 'sqlsim', telemetry: 'final',
        query: 'SELECT 1 AS ShouldNotRun'
      });
      await page.locator('#database').fill('__sqlsimstudio_missing_database__');
      await page.locator('#run-workload').click();
      await expect(page.locator('#configure-view')).toHaveClass(/active/);
      await expect(page.locator('#test-connection-result')).toBeVisible();
      await expect(page.locator('#test-connection-result')).toHaveClass(/is-error/);
      await expect(page.locator('#run-workload')).toBeEnabled();
      await expect(page.locator('#run-label')).toHaveText('Run workload');
    });

    await test.step('closing the tab mid-run is challenged', async () => {
      // Studio keeps running when the browser goes away, so a run started here
      // would carry on against the database with no interface attached. The
      // browser's own confirmation is the only thing that can interrupt a tab
      // closing, and its wording cannot be set, so a banner explains it.
      // The query outlasts every wait below, so the stop always lands mid-run;
      // it is stopped, so the length costs nothing.
      await configureQuery(page, {
        engine: 'sqlsim', telemetry: 'live',
        query: "WAITFOR DELAY '00:01:00'; SELECT 701 AS GuiDetachResult"
      });
      await page.locator('#run-workload').click();
      await expect(page.locator('#run-state-label')).toHaveText('Running...');
      // Wait for the engine to report in, rather than racing the first poll.
      // The banner is driven by the run snapshot, so asserting it before any
      // snapshot has arrived tests the starting state, not the running one.
      await expect(page.locator('#execution-count')).toBeVisible();

      await expect(page.locator('#run-detach-note')).toBeVisible({ timeout: 20_000 });
      await expect(page.locator('#run-detach-note')).toContainText('will not stop this run');

      // The guard is armed only while something is running. Asserting the flag
      // the handler reads is the only way to check this without a real tab
      // close, which Playwright cannot confirm either way.
      expect(await page.evaluate(() => window.__studioRunActive())).toBe(true);

      // Stop it rather than waiting out the delay, so the step stays quick.
      await page.locator('#stop-run').click();
      await expect(page.locator('#run-state-label')).toHaveText('Run stopped', { timeout: 30_000 });
      // Once the run is over, closing the tab costs nothing, so the challenge
      // must disappear rather than nag on every future close.
      await expect(page.locator('#run-detach-note')).toBeHidden();
      expect(await page.evaluate(() => window.__studioRunActive())).toBe(false);
    });

    await test.step('shut down confirms before stopping', async () => {
      // The only deliberate exit. It must warn rather than stop on one click:
      // Studio has no window, so a mis-click cannot be undone, and shutting
      // down kills whatever workload is running.
      await page.locator('#shutdown-studio').click();
      await expect(page.locator('#shutdown-dialog')).toBeVisible();
      await expect(page.locator('#shutdown-dialog')).toContainText('Any running workload will be terminated');
      // Nothing is running here, so the workload warning stays hidden.
      await expect(page.locator('#shutdown-run-warning')).toBeHidden();
      await page.locator('#cancel-shutdown').click();
      await expect(page.locator('#shutdown-dialog')).toBeHidden();
      // Cancelling must leave Studio usable, not half torn down.
      await expect(page.locator('#run-workload')).toBeEnabled();
    });

    await test.step('app settings and themes', async () => {
      const initialTheme = await page.locator('html').getAttribute('data-theme');
      await page.locator('#open-app-settings').click();
      await expect(page.locator('#app-settings-dialog')).toBeVisible();
      await expect(page.locator('#app-settings-dialog .settings-note')).toContainText('does not change sqlsim workload settings');
      await page.locator('#app-theme').selectOption('dark');
      await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
      expect(await page.locator('body').evaluate(element => getComputedStyle(element).backgroundColor)).toBe('rgb(8, 15, 24)');
      await expect(page.locator('#apply-app-settings')).toHaveCSS('background-color', 'rgb(0, 53, 148)');
      if (captureScreenshots) {
        const screenshotDirectory = path.join(__dirname, '..', 'build', 'gui-screenshots');
        fs.mkdirSync(screenshotDirectory, { recursive: true });
        await delay(250);
        await page.screenshot({ path: path.join(screenshotDirectory, 'settings-dark.png') });
      }
      await page.locator('#cancel-app-settings').click();
      await expect(page.locator('html')).toHaveAttribute('data-theme', initialTheme);

      await page.locator('#open-app-settings').click();
      await page.locator('#app-theme').selectOption('dark');
      await page.locator('#apply-app-settings').click();
      // OK saves the theme for the user, not just this browser, so it survives
      // the new port Studio takes at its next launch.
      await expect.poll(() => page.evaluate(async () =>
        (await (await fetch('/api/settings', { cache: 'no-store' })).json()).theme)).toBe('dark');
      if (captureScreenshots) {
        await page.screenshot({ path: path.join(__dirname, '..', 'build', 'gui-screenshots', 'configure-dark.png'), fullPage: true });
      }
      await page.reload();
      await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
      await page.locator('#open-app-settings').click();
      await expect(page.locator('#app-theme')).toHaveValue('dark');
      await page.locator('#app-theme').selectOption('light');
      await expect(page.locator('html')).toHaveAttribute('data-theme', 'light');
      await page.locator('#close-app-settings').click();
      await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');

      await page.locator('#open-app-settings').click();
      await page.locator('#app-theme').selectOption('system');
      await page.locator('#apply-app-settings').click();
      await expect(page.locator('html')).toHaveAttribute('data-theme-preference', 'system');
    });

    await test.step('navigation and responsive layout', async () => {
      await page.locator('[data-view="monitor"]').click();
      await expect(page.locator('#run-state-label')).toHaveText('No active run');
      await expect(page.locator('#stop-run')).toBeDisabled();
      for (const view of ['monitor', 'results', 'compare', 'configure']) {
        await page.locator(`[data-view="${view}"]`).click();
        await expect(page.locator(`#${view}-view`)).toHaveClass(/active/);
      }
      if (captureScreenshots) {
        const screenshotDirectory = path.join(__dirname, '..', 'build', 'gui-screenshots');
        fs.mkdirSync(screenshotDirectory, { recursive: true });
        await page.locator('[data-view="configure"]').click();
        await page.screenshot({ path: path.join(screenshotDirectory, 'configure-desktop.png'), fullPage: true });
      }
      await page.setViewportSize({ width: 390, height: 844 });
      await expect(page.locator('#configure-view')).toBeVisible();
      await expect(page.locator('#open-app-settings')).toBeVisible();
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBeTruthy();
      if (captureScreenshots) {
        await page.screenshot({ path: path.join(__dirname, '..', 'build', 'gui-screenshots', 'configure-mobile.png'), fullPage: true });
      }
      await page.setViewportSize({ width: 1440, height: 1000 });
    });

    await test.step('authentication and option controls', async () => {
      for (const selector of ['#execution-engine', '#server', '#database', '#authentication', '#query-text', '#telemetry-mode']) {
        await expect(page.locator(selector)).toHaveAttribute('required', '');
      }
      await expect(page.locator('.required-legend')).toContainText('Required fields');
      await expect(page.locator('#server').locator('xpath=preceding-sibling::span').locator('.required-mark')).toBeVisible();
      await expect(page.locator('#database').locator('xpath=preceding-sibling::span').locator('.required-mark')).toBeVisible();
      expect(await page.locator('.cli-option').allTextContents()).toEqual(['-n', '-r', '-n', '-r', '-r', '-n', '-q']);
      for (const option of await page.locator('.cli-option').all()) {
        await expect(option).toHaveCSS('text-transform', 'none');
      }

      const authentication = page.locator('#authentication');
      await authentication.selectOption('token');
      await expect(page.locator('#secret-field')).toBeVisible();
      await expect(page.locator('#username-field')).toBeHidden();
      await expect(page.locator('#auth-secret')).toHaveAttribute('required', '');
      await expect(page.locator('#auth-username')).not.toHaveAttribute('required', '');
      await page.locator('#auth-secret').fill('gui-test-placeholder');
      await page.locator('.reveal').click();
      await expect(page.locator('#auth-secret')).toHaveAttribute('type', 'text');
      await page.locator('.reveal').click();
      await authentication.selectOption('sql');
      await expect(page.locator('#username-field')).toBeVisible();
      await expect(page.locator('#secret-field')).toBeVisible();
      await expect(page.locator('#auth-username')).toHaveAttribute('required', '');
      await authentication.selectOption('service-principal');
      await expect(page.locator('#username-field')).toBeVisible();
      // Managed identity takes an optional user-assigned client ID but never a secret.
      await authentication.selectOption('managed');
      await expect(page.locator('#username-field')).toBeVisible();
      await expect(page.locator('#secret-field')).toBeHidden();
      for (const mode of ['interactive', 'integrated']) {
        await authentication.selectOption(mode);
        await expect(page.locator('#username-field')).toBeHidden();
        await expect(page.locator('#secret-field')).toBeHidden();
      }

      await page.locator('details.advanced').first().locator('summary').click();
      await page.locator('#trust-server-certificate').check();
      await expect(page.locator('#command-text')).toContainText('-C');
      await page.locator('#stop-on-error').check();
      await expect(page.locator('#command-text')).toContainText('-stoponerror');
      const prepared = page.locator('label.toggle-row').filter({ hasText: 'Prepared statements' }).locator('input');
      const reconnect = page.locator('label.toggle-row').filter({ hasText: 'Reconnect each iteration' }).locator('input');
      const pooling = page.locator('label.toggle-row').filter({ hasText: 'Connection pooling' }).locator('input');
      await expect(prepared).toBeEnabled();
      await expect(reconnect).toBeEnabled();
      await expect(pooling).toBeDisabled();
      await reconnect.check();
      await expect(pooling).toBeEnabled();
      await reconnect.uncheck();
      await expect(page.locator('#load-profile')).toBeEnabled();
      await expect(page.locator('#save-profile')).toBeEnabled();
      await expect(page.locator('#test-connection')).toBeEnabled();

      await page.locator('#telemetry-mode').selectOption('live');
      await expect(page.locator('#command-text')).toContainText('-stream-json');
      await expect(page.locator('#quiet-mode-toggle')).toBeDisabled();
      await page.locator('#telemetry-mode').selectOption('final');
      // -v carries the verbose fields the reporting scripts require.
      await expect(page.locator('#command-text')).toContainText('-json -o studio-results.json');
      await page.locator('#telemetry-mode').selectOption('console');
      await expect(page.locator('#quiet-mode-toggle')).toBeEnabled();
      await expect(page.locator('#quiet-mode-toggle')).not.toBeChecked();
      await expect(page.locator('#command-text')).not.toContainText('-json');
      await page.locator('#statistics-source').selectOption('runtime');
      await expect(page.locator('#command-text')).toContainText('-querystats');
      await page.locator('#statistics-source').selectOption('query-store');
      await expect(page.locator('#query-store-preflight')).toBeVisible();
      await page.locator('#statistics-source').selectOption('none');

      const canvas = await page.locator('body').evaluate(element => getComputedStyle(element).backgroundColor);
      const resolvedTheme = await page.locator('html').getAttribute('data-theme');
      expect(canvas).toBe(resolvedTheme === 'dark' ? 'rgb(8, 15, 24)' : 'rgb(245, 246, 248)');
      const fieldLabelSize = await page.locator('#database').locator('xpath=preceding-sibling::span').evaluate(element => getComputedStyle(element).fontSize);
      expect(fieldLabelSize).toBe('12px');
    });

    await test.step('save and load configuration without secrets', async () => {
      await page.locator('[data-view="configure"]').click();
      await page.locator('#execution-engine').selectOption('sqlsim');
      await page.locator('[data-mode="query"]').click();
      await page.locator('#server').fill('saved-server.example.test');
      await page.locator('#database').fill('SavedDatabase');
      await page.locator('#authentication').selectOption('sql');
      await page.locator('#auth-username').fill('saved-user');
      await page.locator('#auth-secret').fill('must-not-be-saved');
      await page.locator('#query-text').fill('SELECT 42 AS SavedConfiguration;');
      await page.locator('#query-mode .simple-threads').fill('3');
      await page.locator('#query-mode .simple-iterations').fill('7');
      await page.locator('#telemetry-mode').selectOption('console');
      await page.locator('#quiet-mode-toggle').check();
      await page.locator('#stop-on-error').check();

      const downloadPromise = page.waitForEvent('download');
      await page.locator('#save-profile').click();
      const download = await downloadPromise;
      expect(download.suggestedFilename()).toBe('sqlsimstudio-SavedDatabase.json');
      const configurationPath = await download.path();
      const savedText = fs.readFileSync(configurationPath, 'utf8');
      const saved = JSON.parse(savedText);
      expect(saved.schema).toBe('sqlsimstudio.configuration');
      expect(saved.version).toBe(1);
      expect(savedText).not.toContain('must-not-be-saved');
      expect(saved.configuration.connection).not.toHaveProperty('secret');

      await page.locator('#server').fill('changed-server');
      await page.locator('#database').fill('ChangedDatabase');
      await page.locator('#auth-secret').fill('clear-me-on-load');
      await page.locator('#query-text').fill('SELECT -1;');
      await page.locator('#query-mode .simple-threads').fill('1');
      await page.locator('#configuration-file-input').setInputFiles(configurationPath);

      await expect(page.locator('#server')).toHaveValue('saved-server.example.test');
      await expect(page.locator('#database')).toHaveValue('SavedDatabase');
      await expect(page.locator('#authentication')).toHaveValue('sql');
      await expect(page.locator('#auth-username')).toHaveValue('saved-user');
      await expect(page.locator('#auth-secret')).toHaveValue('');
      await expect(page.locator('#query-text')).toHaveValue('SELECT 42 AS SavedConfiguration;');
      await expect(page.locator('#query-mode .simple-threads')).toHaveValue('3');
      await expect(page.locator('#query-mode .simple-iterations')).toHaveValue('7');
      await expect(page.locator('#telemetry-mode')).toHaveValue('console');
      await expect(page.locator('#quiet-mode-toggle')).toBeChecked();
      await expect(page.locator('#stop-on-error')).toBeChecked();
    });

    // requireRunning checks the Running state, so each run must last long
    // enough to be seen running after Monitor opens, even on a fast local server.
    const comparableQuery = "WAITFOR DELAY '00:00:03'; SELECT 101 AS GuiFinalResult";
    await test.step('final results and A/B comparison', async () => {
      for (let run = 0; run < 2; run += 1) {
        await configureQuery(page, { telemetry: 'final', query: comparableQuery });
        await runAndOpenResults(page, { requireRunning: true });
        await expect(page.locator('#result-config-workload')).toHaveText('Query');
      }
      await page.locator('#compare-result').click();
      await expect(page.locator('#comparison-status-title')).toHaveText('Runs are comparable');
      await expect(page.locator('#comparison-analysis')).toBeVisible();
      await expect(page.locator('#baseline-run option')).toHaveCount(2);
      const baselineBeforeSwap = await page.locator('#baseline-run').inputValue();
      await page.locator('#swap-runs').click();
      expect(await page.locator('#candidate-run').inputValue()).toBe(baselineBeforeSwap);
    });

    await test.step('console rows and automatic results', async () => {
      await configureQuery(page, {
        telemetry: 'console',
        query: "WAITFOR DELAY '00:00:03'; SELECT 202 AS GuiConsoleResult"
      });
      await runAndOpenResults(page, { automatic: true, requireRunning: true });
      await expect(page.locator('#result-console-panel')).toBeVisible();
      await expect(page.locator('#result-console-output')).toContainText('GuiConsoleResult');
      await expect(page.locator('#result-console-output')).toContainText('202');
    });

    await test.step('runtime query statistics', async () => {
      await configureQuery(page, {
        telemetry: 'final',
        statistics: 'runtime',
        query: 'SELECT 252 AS GuiRuntimeStatisticsResult'
      });
      await runAndOpenResults(page);
      await expect(page.locator('#result-statistics-panel')).toBeVisible();
      await expect(page.locator('#result-statistics-title')).toHaveText('Runtime query statistics');
      await expect(page.locator('#query-report-table .query-report-row > span:nth-child(3)')).not.toHaveText('Unavailable');
    });

    await test.step('live progress and cancellation', async () => {
      await configureQuery(page, {
        telemetry: 'live',
        query: "WAITFOR DELAY '00:00:03'; SELECT 303 AS GuiLiveResult"
      });
      await page.locator('#run-workload').click();
      await expect(page.locator('#run-state-label')).toHaveText('Running...');
      await expect(page.locator('#live-monitor-content')).toBeVisible();
      // The engine reports once a second, so a run can produce more than one
      // event before this check; at least one proves the stream arrived.
      await expect(page.locator('#event-table .event-row').first()).toBeVisible({ timeout: 10_000 });
      await expect(page.locator('#stop-run')).toContainText('View results', { timeout: 45_000 });

      await configureQuery(page, {
        telemetry: 'final',
        query: "WAITFOR DELAY '00:01:00'; SELECT 404 AS GuiCancelledResult"
      });
      await page.locator('#run-workload').click();
      await expect(page.locator('#run-state-label')).toHaveText('Running...');
      await page.locator('#stop-run').click();
      await expect(page.locator('#run-state-label')).toHaveText('Run stopped', { timeout: 15_000 });
    });

    await test.step('live per-query statistics', async () => {
      await configureQuery(page, {
        telemetry: 'live',
        statistics: 'runtime',
        query: "WAITFOR DELAY '00:00:03'; SELECT 707 AS GuiLiveStatisticsResult"
      });
      await page.locator('#run-workload').click();
      await expect(page.locator('#run-state-label')).toHaveText('Running...');
      await expect(page.locator('#live-query-table .query-report-row')).toHaveCount(1, { timeout: 30_000 });
      await expect(page.locator('#live-query-table .query-report-row')).toContainText('GuiLiveStatisticsResult');
      await expect(page.locator('#live-query-summary [data-chart="elapsed"] .live-bar-row')).toHaveCount(1);
      await expect(page.locator('#live-query-summary [data-total="executions"]')).not.toHaveText('0');
      await expect(page.locator('#stop-run')).toContainText('View results', { timeout: 45_000 });
    });

    await test.step('application name is blanked and locked for sqlpysim', async () => {
      await page.locator('[data-view="configure"]').click();
      const applicationName = page.locator('#application-name');
      await page.locator('#execution-engine').selectOption('sqlsim');
      await applicationName.fill('GuiAppNameProbe');
      await expect(applicationName).toBeEnabled();
      await expect(page.locator('#command-text')).toContainText('-app "GuiAppNameProbe"');

      // mssql-python reserves the application name, so the field must be both
      // emptied and locked. A greyed-out box still showing a name would read
      // as though that name reaches the server, which it never does.
      await page.locator('#execution-engine').selectOption('sqlpysim');
      await expect(applicationName).toBeDisabled();
      await expect(applicationName).toHaveValue('');
      await expect(page.locator('#command-text')).not.toContainText('-app');

      await page.locator('#execution-engine').selectOption('sqlsim');
      await expect(applicationName).toBeEnabled();
      await expect(applicationName).toHaveValue('GuiAppNameProbe');
    });

    await test.step('sqlpysim final results', async () => {
      await configureQuery(page, { engine: 'sqlpysim', telemetry: 'final', query: 'SELECT 505 AS GuiPythonResult' });
      // Workload mode is available to sqlpysim now that it implements
      // -workload. Replay remains sqlsim only.
      await expect(page.locator('#workload-mode-button')).toBeEnabled();
      await expect(page.locator('#replay-mode-button')).toBeDisabled();
      await runAndOpenResults(page);
      await expect(page.locator('#result-config-engine')).toContainText('sqlpysim');

      await configureQuery(page, { engine: 'sqlpysim', telemetry: 'console', query: 'SELECT 506 AS GuiPythonConsoleResult' });
      await runAndOpenResults(page, { automatic: true });
      await expect(page.locator('#result-console-output')).toContainText('GuiPythonConsoleResult');
      await expect(page.locator('#result-console-output')).toContainText('506');
    });

    await test.step('sqlpysim live progress', async () => {
      // sqlpysim gained -stream-json, so the live option is no longer
      // disabled for the Python engine. Asserting the execution counter
      // rather than merely reaching a finished state proves the numbers came
      // off the stream: a run that emitted nothing would still complete.
      await configureQuery(page, {
        engine: 'sqlpysim', telemetry: 'live',
        query: "WAITFOR DELAY '00:00:02'; SELECT 507 AS GuiPythonLiveResult"
      });
      await expect(page.locator('#telemetry-mode option[value="live"]')).toBeEnabled();
      await page.locator('#query-mode .simple-threads').fill('2');
      await page.locator('#query-mode .simple-iterations').fill('3');
      await expect(page.locator('#command-text')).toContainText('-stream-json');

      await page.locator('#run-workload').click();
      await expect(page.locator('#monitor-view')).toHaveClass(/active/);
      await expect(page.locator('#run-state-label')).toHaveText('Run completed', { timeout: 60_000 });
      await expect(page.locator('#execution-count')).toHaveText('6');
      await expect(page.locator('#connection-count')).toHaveText('2');
      await expect(page.locator('#error-count')).toHaveText('0');
    });

    await test.step('SQL file mode', async () => {
      await page.locator('[data-view="configure"]').click();
      await page.locator('#execution-engine').selectOption('sqlsim');
      await page.locator('[data-mode="file"]').click();
      await page.locator('#database').fill(database);
      await page.locator('#telemetry-mode').selectOption('final');
      await page.locator('#statistics-source').selectOption('none');
      await page.locator('#file-mode .simple-threads').fill('1');
      await page.locator('#file-mode .simple-iterations').fill('1');
      await page.locator('#sql-file-input').setInputFiles({
        name: 'gui-smoke.sql',
        mimeType: 'text/plain',
        buffer: Buffer.from('SELECT 1 AS FirstBatch;\nGO\nSELECT 2 AS SecondBatch;')
      });
      await expect(page.locator('#sql-file-detail')).toContainText('2 batches');
      await runAndOpenResults(page);
      await expect(page.locator('#result-config-shape')).toHaveText('2 batches');
    });

    await test.step('mixed workload mode', async () => {
      await page.locator('[data-view="configure"]').click();
      await page.locator('[data-mode="workload"]').click();
      await page.locator('#database').fill(database);
      await page.locator('#telemetry-mode').selectOption('final');
      await page.locator('#statistics-source').selectOption('runtime');
      await page.locator('#workload-file-input').setInputFiles([
        { name: 'read.sql', mimeType: 'text/plain', buffer: Buffer.from('SELECT 1 AS ReadValue;') },
        { name: 'write.sql', mimeType: 'text/plain', buffer: Buffer.from('SELECT 2 AS WriteValue;') }
      ]);
      await expect(page.locator('#workload-group-count')).toContainText('2 workload groups');
      await page.locator('.group-threads').first().fill('2');
      await page.locator('.group-iterations').last().fill('2');
      await page.locator('.group-think').last().fill('1');
      await runAndOpenResults(page);
      await expect(page.locator('#result-config-shape')).toHaveText('2 groups');
      await expect(page.locator('#query-report-table .query-report-row > span:nth-child(3)').first()).not.toHaveText('Unavailable');
    });

    await test.step('replay fast and stress modes', async () => {
      await page.locator('[data-view="configure"]').click();
      await page.locator('[data-mode="replay"]').click();
      await page.locator('#database').fill(database);
      await page.locator('#telemetry-mode').selectOption('final');
      await page.locator('#replay-file-input').setInputFiles({
        name: 'targeted-replay.xml',
        mimeType: 'application/xml',
        buffer: Buffer.from('<replay><event name="sql_batch_completed"><data name="batch_text"><value>SELECT DB_NAME()</value></data><action name="session_id"><value>51</value></action><action name="database_name"><value>CapturedSourceDatabase</value></action></event></replay>')
      });
      await page.locator('#database').fill(database);
      await expect(page.locator('#replay-database-summary')).toContainText('CapturedSourceDatabase will be redirected');
      await runAndOpenResults(page);
      await expect(page.locator('#result-errors')).toHaveText('0');

      await page.locator('[data-view="configure"]').click();
      await page.locator('[data-mode="replay"]').click();
      await page.locator('#replay-file-input').setInputFiles(replayFile);
      await page.locator('#replay-mode-select').selectOption('stress');
      await expect(page.locator('#replay-threads')).toBeEnabled();
      await page.locator('#replay-threads').fill('2');
      await runAndOpenResults(page);
      const stressReplaySpids = page.locator('#query-report-table .query-report-row > span:nth-child(3)');
      await expect(stressReplaySpids.first()).toContainText(',');

      await page.locator('[data-view="configure"]').click();
      await page.locator('[data-mode="replay"]').click();
      await page.locator('#replay-mode-select').selectOption('fast');
      await expect(page.locator('#replay-threads')).toBeDisabled();
      await runAndOpenResults(page);
      await expect(page.locator('#result-status-title')).toHaveText('Run completed successfully');

      await page.locator('[data-view="configure"]').click();
      await page.locator('[data-mode="replay"]').click();
      await page.locator('#database').fill(database);
      await page.locator('#replay-file-input').setInputFiles({
        name: 'multi-database-replay.xml',
        mimeType: 'application/xml',
        buffer: Buffer.from(`<replay>
          <event name="sql_batch_completed"><data name="batch_text"><value>SELECT 1</value></data><action name="session_id"><value>51</value></action><action name="database_name"><value>${database}</value></action></event>
          <event name="sql_batch_completed"><data name="batch_text"><value>SELECT 2</value></data><action name="session_id"><value>52</value></action><action name="database_name"><value>SqlsimStudioMissingDatabase</value></action></event>
        </replay>`)
      });
      await expect(page.locator('#toast')).toContainText('supports one captured database per Replay file');
      await expect(page.locator('#replay-preflight')).toBeHidden();
    });

    if (queryStoreDatabase) {
      await test.step('optional Query Store collection', async () => {
        await configureQuery(page, {
          telemetry: 'final',
          statistics: 'query-store',
          query: 'SELECT TOP (10) name FROM sys.objects ORDER BY object_id'
        });
        await page.locator('#database').fill(queryStoreDatabase);
        await runAndOpenResults(page);
        await expect(page.locator('#result-statistics-title')).toHaveText('Query Store statistics');
      });
    }

    expect(browserErrors, browserErrors.join('\n')).toEqual([]);
  } finally {
    if (studio.exitCode === null) {
      studio.kill();
      await Promise.race([once(studio, 'exit'), delay(5_000)]);
    }
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
    if (studio.exitCode && studio.exitCode !== 0) {
      console.error(processError.trim());
    }
  }
});