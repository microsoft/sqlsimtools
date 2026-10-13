const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { test, expect } = require('@playwright/test');

test('saves and loads a configuration without credentials', async ({ page }) => {
  const clientPath = path.join(__dirname, '..', 'client', 'index.html');
  await page.goto(`${pathToFileURL(clientPath).href}#configure`);

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

test('restores embedded SQL file and mixed workload sources', async ({ page }) => {
  const clientPath = path.join(__dirname, '..', 'client', 'index.html');
  await page.goto(`${pathToFileURL(clientPath).href}#configure`);
  const baseProfile = {
    schema: 'sqlsimstudio.configuration',
    version: 1,
    savedAt: '2026-09-20T00:00:00.000Z',
    configuration: {
      engine: 'sqlsim',
      mode: 'file',
      connection: {
        server: 'localhost',
        database: 'tempdb',
        authentication: 'integrated',
        username: null,
        trustServerCertificate: false
      },
      source: {
        fileName: 'saved-script.sql',
        content: 'SELECT 1;\nGO\nSELECT 2;',
        threads: 4,
        iterations: 5
      },
      execution: {
        telemetry: 'final',
        quiet: true,
        stopOnError: false,
        statisticsSource: 'none'
      }
    }
  };

  await page.locator('#configuration-file-input').setInputFiles({
    name: 'file-profile.json',
    mimeType: 'application/json',
    buffer: Buffer.from(JSON.stringify(baseProfile))
  });
  await expect(page.locator('[data-mode="file"]')).toHaveClass(/active/);
  await expect(page.locator('#sql-file-title')).toHaveText('saved-script.sql');
  await expect(page.locator('#sql-file-detail')).toContainText('2 batches');
  await expect(page.locator('#file-mode .simple-threads')).toHaveValue('4');
  await expect(page.locator('#file-mode .simple-iterations')).toHaveValue('5');

  baseProfile.configuration.mode = 'workload';
  baseProfile.configuration.source = {
    groups: [
      { fileName: 'read.sql', content: 'SELECT 1;', threads: 2, iterations: 10, thinkTimeMs: 0 },
      { fileName: 'write.sql', content: 'SELECT 2;\nGO\nSELECT 3;', threads: 1, iterations: 3, thinkTimeMs: 25 }
    ]
  };
  await page.locator('#configuration-file-input').setInputFiles({
    name: 'workload-profile.json',
    mimeType: 'application/json',
    buffer: Buffer.from(JSON.stringify(baseProfile))
  });
  await expect(page.locator('[data-mode="workload"]')).toHaveClass(/active/);
  await expect(page.locator('.workload-row')).toHaveCount(2);
  await expect(page.locator('#workload-group-count')).toContainText('2 workload groups');
  await expect(page.locator('.group-threads').first()).toHaveValue('2');
  await expect(page.locator('.group-think').last()).toHaveValue('25');
  await expect(page.locator('#estimated-executions')).toHaveText('26');

  baseProfile.configuration.mode = 'replay';
  baseProfile.configuration.source = {
    fileName: 'saved-replay.xml',
    content: '<replay><event name="sql_batch_completed"><data name="batch_text"><value>SELECT 1</value></data><action name="session_id"><value>51</value></action></event></replay>',
    replayMode: 'stress',
    iterations: 6,
    threads: 8
  };
  await page.locator('#configuration-file-input').setInputFiles({
    name: 'replay-profile.json',
    mimeType: 'application/json',
    buffer: Buffer.from(JSON.stringify(baseProfile))
  });
  await expect(page.locator('[data-mode="replay"]')).toHaveClass(/active/);
  await expect(page.locator('#replay-file-title')).toHaveText('saved-replay.xml');
  await expect(page.locator('#replay-mode-select')).toHaveValue('stress');
  await expect(page.locator('#replay-iterations')).toHaveValue('6');
  await expect(page.locator('#replay-threads')).toHaveValue('8');
  await expect(page.locator('#replay-threads')).toBeEnabled();
  await expect(page.locator('#replay-preflight')).toBeVisible();
  await expect(page.locator('#replay-event-count')).toHaveText('1');
});