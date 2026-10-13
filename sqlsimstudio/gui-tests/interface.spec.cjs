const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { test, expect } = require('@playwright/test');

// These tests load the client directly, so they need no Studio process and no SQL target.

const clientUrl = `${pathToFileURL(path.join(__dirname, '..', 'client', 'index.html')).href}#configure`;

async function openStudio(page) {
  await page.goto(clientUrl);
  await page.locator('#server').fill('localhost');
  await page.locator('#database').fill('tempdb');
}

function writeTemporaryFile(name, contents) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'sqlsimstudio-ui-'));
  const target = path.join(directory, name);
  fs.writeFileSync(target, contents, 'utf8');
  return target;
}

test('never shows a load shape total it has not calculated', async ({ page }) => {
  await openStudio(page);

  // The markup must not ship sample figures that survive until the first keystroke.
  await page.locator('[data-mode="query"]').click();
  await expect(page.locator('#query-mode .simple-total')).toHaveText('1,000');

  await page.locator('#query-mode .simple-threads').fill('1');
  await page.locator('#query-mode .simple-iterations').fill('1');
  await expect(page.locator('#query-mode .simple-total')).toHaveText('1');
  await expect(page.locator('#estimated-executions')).toHaveText('1');

  await page.locator('#query-mode .simple-iterations').fill('7');
  await expect(page.locator('#query-mode .simple-total')).toHaveText('7');

  // SQL file mode must not claim a batch count before a script is chosen.
  await page.locator('[data-mode="file"]').click();
  await expect(page.locator('#file-batch-note')).toContainText('Choose a script');
  await expect(page.locator('#file-mode .simple-total')).toHaveText('1,000');

  const sqlFile = writeTemporaryFile('two-batches.sql', 'SELECT 1;\nGO\nSELECT 2;\n');
  await page.locator('#sql-file-input').setInputFiles(sqlFile);
  await expect(page.locator('#file-batch-note')).toContainText('2 batches');
  await expect(page.locator('#file-mode .simple-total')).toHaveText('2,000');
  await expect(page.locator('#sql-file-preview')).toBeVisible();
  await expect(page.locator('#sql-file-preview-content')).toHaveText('SELECT 1;\nGO\nSELECT 2;');
});

test('reports workload estimates and replay preflight without inventing replay executions', async ({ page }) => {
  await openStudio(page);

  // Query mode: connections x iterations.
  await page.locator('[data-mode="query"]').click();
  await page.locator('#query-mode .simple-threads').fill('10');
  await page.locator('#query-mode .simple-iterations').fill('100');
  await expect(page.locator('#total-threads')).toHaveText('10');
  await expect(page.locator('#estimated-executions')).toHaveText('1,000');

  await page.locator('#query-mode .simple-threads').fill('3');
  await expect(page.locator('#estimated-executions')).toHaveText('300');

  // SQL File mode multiplies by the batch count parsed from the script.
  const sqlFile = writeTemporaryFile('three-batches.sql',
    'SELECT 1;\nGO\nSELECT 2;\nGO\nSELECT 3;\n');
  await page.locator('[data-mode="file"]').click();
  await page.locator('#sql-file-input').setInputFiles(sqlFile);
  await page.locator('#file-mode .simple-threads').fill('2');
  await page.locator('#file-mode .simple-iterations').fill('5');
  await expect(page.locator('#total-threads')).toHaveText('2');
  await expect(page.locator('#estimated-executions')).toHaveText('30');

  const replayFile = writeTemporaryFile('capture.xml', `<?xml version="1.0"?>
    <replay>
      <event name="sql_batch_completed"><data name="batch_text"><value>SELECT 1</value></data><action name="session_id"><value>51</value></action><action name="database_name"><value>CapturedSales</value></action></event>
      <event name="rpc_completed"><data name="object_name"><value>sp_executesql</value></data><data name="statement"><value>SELECT 2</value></data><action name="session_id"><value>52</value></action><action name="database_name"><value>CapturedSales</value></action></event>
      <event name="attention"><action name="session_id"><value>52</value></action></event>
    </replay>`);
  await page.locator('[data-mode="replay"]').click();
  await expect(page.locator('#telemetry-mode')).toHaveValue('final');
  await page.locator('#telemetry-mode').selectOption('live');
  await expect(page.locator('#telemetry-mode')).toHaveValue('live');
  await expect(page.locator('#command-text')).toContainText('-stream-json -json -o studio-results.json');
  await page.locator('#replay-file-input').setInputFiles(replayFile);
  await expect(page.locator('#replay-preflight')).toBeVisible();
  await expect(page.locator('#replay-event-count')).toHaveText('3');
  await expect(page.locator('#replay-recognized-count')).toHaveText('2');
  await expect(page.locator('#replay-skipped-count')).toHaveText('1');
  await expect(page.locator('#replay-session-count')).toHaveText('2');
  await expect(page.locator('#replay-database-summary')).toHaveText('Captured database CapturedSales will be redirected to the selected Studio target.');
  await expect(page.locator('.replay-database-warning')).toContainText('not schema or data equivalence');
  await expect(page.locator('#replay-capture-table .replay-capture-header')).toContainText('Captured SPID');
  await expect(page.locator('#replay-capture-table')).toContainText('51');
  await expect(page.locator('#replay-capture-table')).toContainText('52');
  await expect(page.locator('#replay-capture-table .replay-capture-row')).toHaveCount(3);
  await expect(page.locator('#replay-capture-table')).toContainText('Session ordered');
  await page.locator('#replay-mode-select').selectOption('fast');
  await page.locator('#replay-iterations').fill('4');
  await expect(page.locator('#execution-summary-label')).toHaveText('Replay passes');
  await expect(page.locator('#connection-summary-label')).toHaveText('Captured SPIDs');
  await expect(page.locator('#total-threads')).toHaveText('2');
  await expect(page.locator('#estimated-executions')).toHaveText('4');

  await page.locator('#replay-mode-select').selectOption('stress');
  await page.locator('#replay-threads').fill('6');
  await expect(page.locator('#connection-summary-label')).toHaveText('Stress connections');
  await expect(page.locator('#total-threads')).toHaveText('6');
  await expect(page.locator('#estimated-executions')).toHaveText('4');
  await expect(page.locator('#replay-capture-table')).toContainText('Flattened');

  // Mixed workload sums its groups.
  await page.locator('[data-mode="workload"]').click();
  await page.locator('#workload-file-input').setInputFiles([
    writeTemporaryFile('group-a.sql', 'SELECT 1;\n'),
    writeTemporaryFile('group-b.sql', 'SELECT 2;\n')
  ]);
  await expect(page.locator('#workload-rows .workload-row')).toHaveCount(2);
  const rows = page.locator('#workload-rows .workload-row');
  await rows.nth(0).locator('input').nth(0).fill('4');
  await rows.nth(0).locator('input').nth(1).fill('10');
  await rows.nth(1).locator('input').nth(0).fill('2');
  await rows.nth(1).locator('input').nth(1).fill('5');
  await expect(page.locator('#total-threads')).toHaveText('6');
  await expect(page.locator('#estimated-executions')).toHaveText('50');
});

test('rejects malformed or unsupported replay XML during preflight', async ({ page }) => {
  await openStudio(page);
  await page.locator('[data-mode="replay"]').click();

  await page.locator('#replay-file-input').setInputFiles(
    writeTemporaryFile('malformed.xml', '<replay><event></replay>'));
  await expect(page.locator('#toast')).toContainText('not well-formed XML');
  await expect(page.locator('#replay-preflight')).toBeHidden();

  await page.locator('#toast').click();
  await page.locator('#replay-file-input').setInputFiles(
    writeTemporaryFile('wrong-root.xml', '<events><event name="sql_batch_completed" /></events>'));
  await expect(page.locator('#toast')).toContainText('must have a <replay> root element');
  await expect(page.locator('#replay-file-title')).toHaveText('Choose a replay XML file');

  await page.locator('#toast').click();
  await page.locator('#replay-file-input').setInputFiles(
    writeTemporaryFile('multi-database.xml', `<replay>
      <event name="sql_batch_completed"><data name="batch_text"><value>SELECT 1</value></data><action name="database_name"><value>Sales</value></action></event>
      <event name="sql_batch_completed"><data name="batch_text"><value>SELECT 2</value></data><action name="database_name"><value>Inventory</value></action></event>
    </replay>`));
  await expect(page.locator('#toast')).toContainText('supports one captured database per Replay file');
  await expect(page.locator('#toast')).toContainText('Sales, Inventory');
  await expect(page.locator('#replay-preflight')).toBeHidden();
});

test('defaults connection options to the SSMS-equivalent settings', async ({ page }) => {
  await openStudio(page);

  await expect(page.locator('#encryption')).toHaveValue('mandatory');
  await expect(page.locator('#trust-server-certificate')).toBeChecked();
  await expect(page.locator('#application-name')).toHaveValue('sqlsimstudio');
  await expect(page.locator('#login-timeout')).toHaveValue('15');
  await expect(page.locator('#query-timeout')).toHaveValue('30');
  await expect(page.locator('#retry-count')).toHaveValue('0');

  await page.locator('[data-mode="query"]').click();
  const preview = page.locator('#command-text');
  await expect(preview).toContainText('-N m');
  await expect(preview).toContainText('-C');
  await expect(preview).toContainText('-app "sqlsimstudio"');
  await expect(preview).toContainText('-l 15');
  await expect(preview).toContainText('-t 30');
});

test('gates connection pooling behind reconnect', async ({ page }) => {
  await openStudio(page);
  await page.locator('[data-mode="query"]').click();

  const reconnect = page.locator('#reconnect-each-iteration');
  const pooling = page.locator('#connection-pooling');
  await expect(pooling).toBeDisabled();

  await reconnect.check();
  await expect(pooling).toBeEnabled();
  await pooling.check();
  await expect(page.locator('#command-text')).toContainText('-usepool');

  // Clearing reconnect must also clear pooling, which sqlsim rejects on its own.
  await reconnect.uncheck();
  await expect(pooling).toBeDisabled();
  await expect(pooling).not.toBeChecked();
  await expect(page.locator('#command-text')).not.toContainText('-usepool');
});

test('offers only implemented controls', async ({ page }) => {
  await openStudio(page);

  for (const id of ['#test-connection', '#export-results-json', '#import-workload-json',
    '#export-comparison', '#import-baseline-result', '#import-candidate-result', '#save-profile', '#load-profile']) {
    await expect(page.locator(id)).toBeEnabled();
  }

  // Removed rather than shipped disabled, so a visible button always does something.
  for (const label of ['Copy events', 'Run again', 'Open configuration', 'Clear display',
    'Save HTML report', 'Ramp batch']) {
    await expect(page.getByText(label, { exact: false })).toHaveCount(0);
  }
  await expect(page.locator('[aria-label="Copy log"]')).toHaveCount(0);
  await expect(page.locator('[aria-label="Export log"]')).toHaveCount(0);

  for (const value of ['integrated', 'token', 'interactive', 'managed', 'service-principal', 'sql']) {
    await expect(page.locator(`#authentication option[value="${value}"]`)).not.toHaveAttribute('disabled', '');
  }
});

test('shows the credential fields each authentication mode actually needs', async ({ page }) => {
  await openStudio(page);
  await page.locator('[data-mode="query"]').click();
  const username = page.locator('#username-field');
  const secret = page.locator('#secret-field');
  const preview = page.locator('#command-text');

  await page.locator('#authentication').selectOption('integrated');
  await expect(username).toBeHidden();
  await expect(secret).toBeHidden();
  await expect(preview).toContainText('-E');

  await page.locator('#authentication').selectOption('token');
  await expect(username).toBeHidden();
  await expect(secret).toBeVisible();
  await expect(preview).toContainText('-T -');

  // Interactive takes no credentials at all.
  await page.locator('#authentication').selectOption('interactive');
  await expect(username).toBeHidden();
  await expect(secret).toBeHidden();
  await expect(preview).toContainText('-A ActiveDirectoryInteractive');

  // Managed identity accepts an optional user-assigned client ID, never a secret.
  await page.locator('#authentication').selectOption('managed');
  await expect(username).toBeVisible();
  await expect(secret).toBeHidden();
  await expect(preview).toContainText('-A ActiveDirectoryMsi');
  await expect(preview).not.toContainText('-P');
  await page.locator('#auth-username').fill('11111111-2222-3333-4444-555555555555');
  await expect(preview).toContainText('-A ActiveDirectoryMsi -U "11111111-2222-3333-4444-555555555555"');

  // Switching to a mode that takes no credentials must not retain the previous ones.
  await page.locator('#authentication').selectOption('sql');
  await page.locator('#auth-secret').fill('should-not-survive');
  await page.locator('#authentication').selectOption('interactive');
  await expect(page.locator('#auth-secret')).toHaveValue('');
  await expect(page.locator('#auth-username')).toHaveValue('');
});

test('imports a sqlsim workload definition, comments and all', async ({ page }) => {
  await openStudio(page);
  await page.locator('[data-mode="workload"]').click();

  // sqlsim tolerates // and /* */ comments in workload JSON; JSON.parse does not.
  const workload = writeTemporaryFile('workload.json', `{
  // Reporting queries
  "workloads": [
    {
      "queries": ["SELECT 1;"],
      "threads": 4,
      "iterations": 25,
      "think_time_ms": 10
    },
    /* Group defined by external file reference */
    {
      "file": "somewhere.sql",
      "threads": 2,
      "iterations": 3
    }
  ]
}`);

  await page.locator('#workload-json-input').setInputFiles(workload);

  // The inline group imports; the file-backed group cannot, because the browser
  // cannot resolve a path recorded inside a JSON document.
  await expect(page.locator('#workload-rows .workload-row')).toHaveCount(1);
  const row = page.locator('#workload-rows .workload-row').first();
  await expect(row.locator('input').nth(0)).toHaveValue('4');
  await expect(row.locator('input').nth(1)).toHaveValue('25');
  await expect(page.locator('#estimated-executions')).toHaveText('100');
});

function comparisonResult({ runtime, threads = 4, queryTime = runtime / 2, batches = ['SELECT 1;'] } = {}) {
  return {
    version: '1.0.0',
    start_time: '2026-10-12 09:00:00.000',
    configuration: {
      odbc_driver: 'ODBC Driver 18 for SQL Server',
      server: 'localhost',
      database: 'tempdb',
      authentication: 'Windows',
      threads,
      iterations_per_thread: 25,
      total_batches: threads * 25 * batches.length,
      batch_count: batches.length,
      batches,
      quiet_mode: true
    },
    metrics: {
      total_runtime_seconds: runtime,
      total_query_execution_time_seconds: queryTime,
      end_time: '2026-10-12 09:00:02.000',
      errors: { total: 0 },
      warnings: { total: 0 }
    },
    success: true
  };
}

async function importComparisonResult(page, side, name, value) {
  const file = writeTemporaryFile(name, typeof value === 'string' ? value : JSON.stringify(value));
  const chooser = page.waitForEvent('filechooser');
  await page.locator(`#import-${side}-result`).click();
  await (await chooser).setFiles(file);
}

test('compares saved result files and reloads exported comparisons', async ({ page }) => {
  await openStudio(page);
  await page.evaluate(() => {
    window.fetch = async () => new Response('[]', { status: 200, headers: { 'Content-Type': 'application/json' } });
  });
  await page.locator('[data-view="compare"]').click();
  await expect(page.locator('#comparison-status-title')).toHaveText('Two final-result runs required');

  await importComparisonResult(page, 'baseline', 'before.json', comparisonResult({ runtime: 2 }));
  await expect(page.locator('#baseline-run')).toHaveValue(/imported-/);
  await expect(page.locator('#baseline-run option:checked')).toHaveText('Imported · before.json');
  await expect(page.locator('#comparison-status-title')).toHaveText('Two final-result runs required');

  await importComparisonResult(page, 'candidate', 'after.json', comparisonResult({ runtime: 1 }));
  await expect(page.locator('#candidate-run option:checked')).toHaveText('Imported · after.json');
  await expect(page.locator('#comparison-status-title')).toHaveText('Runs are comparable');
  await expect(page.locator('#delta-throughput strong')).toHaveText('+100.0%');
  await expect(page.locator('#delta-runtime strong')).toHaveText('-50.0%');
  await page.locator('#show-differences').click();
  await expect(page.locator('#config-load-a')).toHaveText('4 / 25');
  await expect(page.locator('#config-statistics-b')).toHaveText('Not collected');
  await expect(page.locator('#query-comparison-empty')).toBeVisible();

  const newerDriver = comparisonResult({ runtime: 1 });
  newerDriver.metrics.odbc_driver_version = '18.99.0001';
  await importComparisonResult(page, 'candidate', 'newer-driver.json', newerDriver);
  await expect(page.locator('#comparison-status-title')).toHaveText('Runs are comparable');
  await expect(page.locator('#comparison-status-detail')).toContainText('Engine, ODBC driver, or SQL Server details differ');
  await expect(page.locator('#config-driver-status')).toHaveText('Differs');

  const reconnecting = (runtime, connectMs) => {
    const result = comparisonResult({ runtime });
    result.configuration.reconnect_per_iteration = true;
    result.connection_stats = { avg_ms: connectMs, count: 4 };
    return result;
  };
  await importComparisonResult(page, 'baseline', 'reconnect-a.json', reconnecting(2, 40));
  await importComparisonResult(page, 'candidate', 'reconnect-b.json', reconnecting(2, 60));
  await expect(page.locator('#delta-connection')).toHaveClass(/negative/);
  await expect(page.locator('#delta-connection div small')).toHaveText('lower is better');
  await expect(page.locator('#comparison-regressed')).toHaveText('1 regressed');

  await importComparisonResult(page, 'candidate', 'different-load.json', comparisonResult({ runtime: 1, threads: 8 }));
  await expect(page.locator('#comparison-status-title')).toHaveText('Runs are not comparable');
  await expect(page.locator('#comparison-status-detail')).toContainText('load shape');

  await importComparisonResult(page, 'candidate', 'different-workload.json',
    comparisonResult({ runtime: 1, batches: ['SELECT 2;'] }));
  await expect(page.locator('#comparison-status-detail')).toContainText('workload');

  const liveProgress = comparisonResult({ runtime: 1 });
  liveProgress.configuration.stream_json = true;
  await importComparisonResult(page, 'candidate', 'live-progress.json', liveProgress);
  await expect(page.locator('#comparison-status-title')).toHaveText('Runs are not comparable');
  await expect(page.locator('#comparison-status-detail')).toContainText('telemetry');

  const differentApplication = comparisonResult({ runtime: 1 });
  differentApplication.configuration.application_name = 'Reporting';
  await importComparisonResult(page, 'candidate', 'different-application.json', differentApplication);
  await expect(page.locator('#comparison-status-detail')).toContainText('execution options');

  const failedRun = comparisonResult({ runtime: 1 });
  failedRun.success = false;
  await importComparisonResult(page, 'candidate', 'failed.json', failedRun);
  await expect(page.locator('#toast')).toContainText('failed.json records a failed run');
  await page.locator('#toast').click();

  const replay = database => {
    const result = comparisonResult({ runtime: 1, threads: 1 });
    Object.assign(result.configuration, {
      iterations_per_thread: 1,
      connection_test_only: true,
      replay_mode: 'fast',
      replay_total_events: 1,
      replay_replayable_events: 1,
      replay_skipped_events: 0,
      replay_sessions: 1
    });
    delete result.configuration.total_batches;
    delete result.configuration.batch_count;
    delete result.configuration.batches;
    result.replay_capture = { queries: [{
      event_type: 'sql_batch_completed', query: 'SELECT 1', executions: 1,
      sessions: 1, captured_spids: [51], databases: [database]
    }] };
    result.replay_summary = { result: { events: 1, ok: 1, error: 0, abort: 0 } };
    return result;
  };
  await importComparisonResult(page, 'baseline', 'replay-sales.json', replay('Sales'));
  await importComparisonResult(page, 'candidate', 'replay-inventory.json', replay('Inventory'));
  await expect(page.locator('#comparison-status-detail')).toContainText('workload');

  const connectionTest = comparisonResult({ runtime: 1 });
  delete connectionTest.configuration.total_batches;
  connectionTest.configuration.connection_test_only = true;
  await importComparisonResult(page, 'candidate', 'connection-test.json', connectionTest);
  await expect(page.locator('#toast')).toContainText('connection-test.json is a connection test');
  await page.locator('#toast').click();

  await importComparisonResult(page, 'candidate', 'stream.ndjson', '{"event":"started"}\n{"event":"completed"}');
  await expect(page.locator('#toast')).toContainText('stream.ndjson is not valid JSON');
  await page.locator('#toast').click();

  await importComparisonResult(page, 'baseline', 'saved-comparison.json', {
    schema: 'sqlsim-comparison',
    version: 1,
    baseline: { statisticsSource: 'query-store', result: comparisonResult({ runtime: 4 }) },
    candidate: { statisticsSource: 'query-store', result: comparisonResult({ runtime: 2 }) }
  });
  await expect(page.locator('#baseline-run option:checked')).toHaveText('Imported · saved-comparison.json (A)');
  await expect(page.locator('#candidate-run option:checked')).toHaveText('Imported · saved-comparison.json (B)');
  await expect(page.locator('#comparison-status-title')).toHaveText('Runs are comparable');
  await expect(page.locator('#config-statistics-a')).toHaveText('Query Store');
});

test('shows live per-query statistics in Monitor', async ({ page }) => {
  await openStudio(page);
  const request = { telemetry: 'live', mode: 'query', database: 'tempdb', server: 'localhost', threads: 4, iterations: 10 };

  await page.evaluate(value => prepareMonitor(true, { ...value, statisticsSource: 'none' }), request);
  await expect(page.locator('#live-query-empty')).toHaveText('Enable Collect per-query performance to see live per-query statistics.');
  await expect(page.locator('#live-query-content')).toBeHidden();

  await page.evaluate(value => prepareMonitor(true, { ...value, statisticsSource: 'runtime' }), request);
  await page.evaluate(() => applyRunSnapshot({ state: 'running', telemetry: 'live', logs: [] }));
  await expect(page.locator('#live-query-empty')).toHaveText('Waiting for the first query-statistics snapshot.');

  await page.evaluate(() => {
    const queries = Array.from({ length: 12 }, (_, index) => ({
      query: index === 0 ? '<img src=x onerror=alert(1)>' : `SELECT ${index};`,
      executions: 100 + index,
      failures: index === 1 ? 2 : 0,
      total_elapsed_ms: { avg: 1 + index },
      server_elapsed_ms: { avg: 0.5 + index },
      server_cpu_ms: { avg: 0.25 + index },
      logical_reads: { avg: 10 + index }
    }));
    applyRunSnapshot({ state: 'running', telemetry: 'live', logs: [], liveQueryStats: { query_stats: {
      queries,
      totals: { executions: 1266, total_elapsed_ms: 1500, server_cpu_ms: 250.5, logical_reads: 12345, physical_reads: 7 }
    } } });
  });

  await expect(page.locator('#live-query-content')).toBeVisible();
  await expect(page.locator('#live-query-summary [data-total="executions"]')).toHaveText('1,266');
  await expect(page.locator('#live-query-summary [data-total="elapsed"]')).toHaveText('1.50 s');
  await expect(page.locator('#live-query-summary [data-total="cpu"]')).toHaveText('251 ms');
  await expect(page.locator('#live-query-summary [data-total="logical"]')).toHaveText('12,345');
  await expect(page.locator('#live-query-summary [data-total="failures"]')).toHaveText('2');
  await expect(page.locator('#live-query-summary [data-summary-note]')).toContainText('the 10 queries with the most total elapsed time; the table lists all 12');
  for (const id of ['elapsed', 'cpu', 'reads', 'executions']) {
    await expect(page.locator(`#live-query-summary [data-chart="${id}"] .live-bar-row`)).toHaveCount(10);
  }
  await expect(page.locator('#live-query-summary [data-chart="elapsed"] .live-bar-row').first().locator('span')).toHaveText('Q12');
  await expect(page.locator('#live-query-table .query-report-row')).toHaveCount(12);
  await expect(page.locator('#live-query-table .query-report-row').first()).toContainText('<img src=x onerror=alert(1)>');
  await expect(page.locator('#live-query-panel img')).toHaveCount(0);

  await page.evaluate(value => prepareMonitor(true, { ...value, statisticsSource: 'query-store' }), request);
  await expect(page.locator('#live-query-empty')).toHaveText('Query Store statistics appear in Results after the run completes.');
  await expect(page.locator('#live-query-table .query-report-row')).toHaveCount(0);
});

test('shows the same query-statistics summary in Results', async ({ page }) => {
  await openStudio(page);
  await page.evaluate(() => {
    const queryStats = executions => ({
      queries: [
        { query: 'SELECT 1;', executions, failures: 0, total_elapsed_ms: { avg: 2 }, server_elapsed_ms: { avg: 1.5 }, server_cpu_ms: { avg: 1 }, logical_reads: { avg: 4 } },
        { query: 'SELECT 2;', executions: executions / 2, failures: 1, total_elapsed_ms: { avg: 5 }, server_elapsed_ms: { avg: 4 }, server_cpu_ms: { avg: 3 }, logical_reads: { avg: 9 } }
      ],
      totals: { executions: executions * 1.5, total_elapsed_ms: 900, server_cpu_ms: 450, logical_reads: 1800, physical_reads: 3 }
    });
    populateResults({
      state: 'completed', telemetry: 'final', engine: 'sqlsim', logs: [],
      result: {
        success: true,
        configuration: { server: 'localhost', database: 'tempdb', threads: 2, total_batches: 300 },
        metrics: { total_runtime_seconds: 1, total_query_execution_time_seconds: 0.9, errors: { total: 0 }, warnings: { total: 0 } },
        query_stats: queryStats(200)
      }
    });
    window.stoppedStatistics = queryStats(40);
  });
  await page.locator('[data-view="results"]').click();
  await expect(page.locator('#result-query-summary')).toBeVisible();
  await expect(page.locator('#result-query-summary [data-total="executions"]')).toHaveText('300');
  await expect(page.locator('#result-query-summary [data-chart="elapsed"] .live-bar-row')).toHaveCount(2);
  await expect(page.locator('#result-statistics-source')).toHaveText('-querystats');
  await expect(page.locator('#query-report-table .query-report-row')).toHaveCount(2);

  await page.evaluate(() => populateResults({
    state: 'stopped', telemetry: 'live', engine: 'sqlsim', logs: [],
    progress: { elapsed_seconds: 2, successful_executions: 60, failed_executions: 0, successful_connections: 2 },
    liveQueryStats: { query_stats: window.stoppedStatistics }
  }));
  await expect(page.locator('#result-statistics-subtitle')).toHaveText('Partial per-query diagnostics from the last snapshot before the run stopped');
  await expect(page.locator('#result-statistics-source')).toHaveText('-querystats-interval');
  await expect(page.locator('#result-query-summary [data-total="executions"]')).toHaveText('60');
  await expect(page.locator('#result-query-summary [data-total="failures"]')).toHaveText('1');
  await expect(page.locator('#query-report-table .query-report-row')).toHaveCount(2);
});

test('labels execution engines with their installed versions', async ({ page }) => {
  await openStudio(page);
  await page.evaluate(() => applyEngineVersions({
    sqlsim: { available: true, version: '1.2.3' },
    sqlpysim: { available: false, version: null }
  }));
  await expect(page.locator('#execution-engine option[value="sqlsim"]')).toHaveText('sqlsim 1.2.3 · Native ODBC');
  await expect(page.locator('#execution-engine option[value="sqlpysim"]')).toHaveText('sqlpysim · mssql-python · not found');

  await page.evaluate(() => applyEngineVersions({ sqlsim: { available: true, version: '<img src=x>' } }));
  await expect(page.locator('#execution-engine option[value="sqlsim"]')).toHaveText('sqlsim · Native ODBC');

  await page.evaluate(() => applyEngineVersions({
    sqlsim: { available: true, version: '1.0.0', problem: '<b>bad</b>' },
    sqlpysim: { available: true, version: '1.0.0', problem: 'mssql-python not installed' }
  }));
  await expect(page.locator('#execution-engine option[value="sqlsim"]')).toHaveText('sqlsim 1.0.0 · Native ODBC');
  await expect(page.locator('#execution-engine option[value="sqlpysim"]')).toHaveText('sqlpysim 1.0.0 · mssql-python · mssql-python not installed');

  await page.evaluate(() => applyEngineVersions({ sqlpysim: { available: true, version: null, problem: 'Python not found' } }));
  await expect(page.locator('#execution-engine option[value="sqlpysim"]')).toHaveText('sqlpysim · mssql-python · Python not found');
});

test('refuses Live progress and Final results session runs', async ({ page }) => {
  await openStudio(page);
  const run = (id, telemetry) => ({
    id, engine: 'sqlsim', mode: 'query', server: 'localhost', database: 'tempdb',
    completedAt: '2026-10-12T19:00:00Z', threads: 4, iterations: 25,
    statisticsSource: 'none', telemetry, workloadHash: 'same', comparisonKey: 'same',
    result: comparisonResult({ runtime: 1 })
  });
  await page.evaluate(history => {
    window.fetch = async () => new Response(JSON.stringify(history), { status: 200, headers: { 'Content-Type': 'application/json' } });
  }, [run('final-run', 'final'), run('live-run', 'live')]);
  await page.locator('[data-view="compare"]').click();
  await expect(page.locator('#comparison-status-title')).toHaveText('Runs are not comparable');
  await expect(page.locator('#comparison-status-detail')).toContainText('telemetry');
});

test('clears an error when the user leaves the view that raised it', async ({ page }) => {
  await openStudio(page);
  await page.evaluate(() => showError('Database is required.'));
  await expect(page.locator('#toast')).toBeVisible();
  await page.locator('[data-view="monitor"]').click();
  await expect(page.locator('#toast')).toBeHidden();

  await page.evaluate(() => showError('Monitor-specific error.'));
  await expect(page.locator('#toast')).toBeVisible();
  await page.evaluate(() => switchView('monitor'));
  await expect(page.locator('#toast')).toBeVisible();
  await page.locator('[data-view="results"]').click();
  await expect(page.locator('#toast')).toBeHidden();
});

test('loads the shipped Replay examples in preflight', async ({ page }) => {
  await openStudio(page);
  const examples = path.join(__dirname, '..', 'examples');
  await page.locator('[data-mode="replay"]').click();
  for (const file of [
    path.join(examples, 'any-database', 'replay', 'catalog-replay.xml'),
    path.join(examples, 'adventureworkslt', 'replay', 'portable-replay.xml')
  ]) {
    await page.locator('#replay-file-input').setInputFiles(file);
    await expect(page.locator('#replay-file-title')).toHaveText(path.basename(file));
    await expect(page.locator('#replay-preflight')).toBeVisible();
    await expect(page.locator('#replay-event-count')).toHaveText('9');
    await expect(page.locator('#replay-recognized-count')).toHaveText('9');
    await expect(page.locator('#replay-skipped-count')).toHaveText('0');
    await expect(page.locator('#replay-session-count')).toHaveText('3');
    // Neither capture records a database, so Replay runs in the selected target.
    await expect(page.locator('#replay-database-summary')).toHaveText('Database context: selected Studio target (none captured)');
    await expect(page.locator('#replay-capture-table .replay-capture-row')).toHaveCount(9);
  }
});

test('imports the shipped index comparison examples', async ({ page }) => {
  await openStudio(page);
  await page.evaluate(() => {
    window.fetch = async () => new Response('[]', { status: 200, headers: { 'Content-Type': 'application/json' } });
  });
  await page.locator('[data-view="compare"]').click();
  const examples = path.join(__dirname, '..', '..', 'sqlsim', 'examples', 'results');
  for (const [side, file] of [['baseline', 'index-baseline.json'], ['candidate', 'index-candidate.json']]) {
    const chooser = page.waitForEvent('filechooser');
    await page.locator(`#import-${side}-result`).click();
    await (await chooser).setFiles(path.join(examples, file));
  }
  await expect(page.locator('#comparison-status-title')).toHaveText('Runs are comparable');
  await expect(page.locator('#comparison-verdict-title')).toHaveText('Candidate improved measured performance');
  await expect(page.locator('#delta-throughput')).toHaveClass(/positive/);
  await expect(page.locator('#delta-runtime')).toHaveClass(/positive/);
  // These values must match sqlsim/test-reports.ps1 for comparison-report.ps1.
  await expect(page.locator('#delta-throughput div strong')).toHaveText('+102.4%');
  await expect(page.locator('#delta-runtime div strong')).toHaveText('-47.3%');
  await expect(page.locator('#delta-execution div strong')).toHaveText('-50.2%');
  await expect(page.locator('#delta-connection')).toHaveClass(/neutral/);
  await expect(page.locator('#delta-connection div small')).toHaveText('not in verdict');
  await expect(page.locator('#comparison-improved')).toHaveText('3 improved');
  await expect(page.locator('#comparison-unchanged')).toHaveText('1 unchanged');
  await expect(page.locator('#config-version-a')).toHaveText('17.0.4085.5');
  await expect(page.locator('#config-engine-a')).toHaveText('sqlsim 1.0.0');
  await expect(page.locator('#delta-runtime > span')).toHaveText('Total duration');
  await expect(page.locator('#config-statistics-a')).toHaveText('Per-query (-querystats)');
  const queryRow = page.locator('#query-comparison-table .query-comparison-row');
  await expect(queryRow).toHaveCount(1);
  await expect(queryRow).toContainText("CompanyName = N'Friendly Bike Shop'");
  await expect(queryRow.locator('.query-delta').nth(3)).toContainText('36.0 → 2.0');
  await expect(queryRow.locator('.query-delta').nth(3).locator('small')).toHaveText('-94.4%');
  await expect(queryRow.locator('.query-delta').nth(3).locator('small')).toHaveClass('positive');
});

test('keeps sqlpysim from selecting capabilities it does not support', async ({ page }) => {
  await openStudio(page);
  await page.locator('#execution-engine').selectOption('sqlpysim');

  // Workload mode is available: sqlpysim implements -workload with the same
  // file format and validation as sqlsim. Live progress and runtime query
  // statistics are available too, since sqlpysim implements -stream-json,
  // -querystats-interval and -querystats-file with the same shapes.
  await expect(page.locator('#workload-mode-button')).toBeEnabled();
  await expect(page.locator('#telemetry-mode option[value="live"]')).toBeEnabled();
  await expect(page.locator('#statistics-source option[value="runtime"]')).toBeEnabled();

  await expect(page.locator('#replay-mode-button')).toBeDisabled();
  await expect(page.locator('#connection-pooling')).toBeDisabled();
  await expect(page.locator('#authentication option[value="service-principal"]')).toBeEnabled();
  await expect(page.locator('#prepared-note')).toContainText('sqlpysim');

  await page.locator('#execution-engine').selectOption('sqlsim');
  await expect(page.locator('#replay-mode-button')).toBeEnabled();
});

test('keeps a mixed workload selected when switching to sqlpysim', async ({ page }) => {
  await openStudio(page);
  await page.locator('[data-mode="workload"]').click();
  await expect(page.locator('#workload-mode')).toBeVisible();

  // Switching engines used to bounce the user out of workload mode, because
  // sqlpysim could not run one. It can now, so the selection must survive.
  await page.locator('#execution-engine').selectOption('sqlpysim');
  await expect(page.locator('#workload-mode')).toBeVisible();

  // Replay is still sqlsim only, so that one must still bounce.
  await page.locator('#execution-engine').selectOption('sqlsim');
  await page.locator('[data-mode="replay"]').click();
  await expect(page.locator('#replay-mode')).toBeVisible();
  await page.locator('#execution-engine').selectOption('sqlpysim');
  await expect(page.locator('#replay-mode')).toBeHidden();
});

test('lets the whole command preview be read when it overflows', async ({ page }) => {
  await openStudio(page);
  await page.locator('[data-mode="query"]').click();

  // A realistic Azure target plus a full flag set pushes the command past the
  // width of the bar. The preview used to be overflow:hidden with an ellipsis,
  // so everything past the cut was unreachable: it could not scroll, wrap, or
  // be hovered. Telemetry flags are appended last, which made them the first
  // thing lost.
  await page.locator('#server').fill('contoso-benchmark-eastus.database.windows.net');
  await page.locator('#database').fill('AdventureWorksLT');
  await page.locator('#trust-server-certificate').check();
  await page.locator('#stop-on-error').check();
  await page.locator('#statistics-source').selectOption('runtime');
  await page.locator('#telemetry-mode').selectOption('final');

  const preview = page.locator('#command-text');

  // The tooltip carries the full command regardless of the visible width.
  const command = await preview.textContent();
  await expect(preview).toHaveAttribute('title', command.trim());
  expect(command).toContain('-json');
  expect(command).toContain('-querystats');

  // Overflow must be scrollable rather than clipped.
  const overflowX = await preview.evaluate(element => getComputedStyle(element).overflowX);
  expect(['auto', 'scroll']).toContain(overflowX);

  // And scrolling must actually move when the content is wider than the box.
  const scrolled = await preview.evaluate(element => {
    if (element.scrollWidth <= element.clientWidth) return 'not-overflowing';
    element.scrollLeft = element.scrollWidth;
    return element.scrollLeft > 0 ? 'scrolled' : 'stuck';
  });
  expect(scrolled).not.toBe('stuck');
});

test('keeps the load shape labels on one line and its inputs aligned', async ({ page }) => {
  await openStudio(page);
  await page.locator('[data-mode="query"]').click();

  // Both labels are uppercased at the wider breakpoint, and three columns are
  // kept down to the 760px phone breakpoint, so the columns get narrow. The
  // labels have to be short enough to survive that squeeze. The iterations
  // labels are deliberately shortened to "Iterations".
  for (const width of [1600, 1200, 1121, 1000, 900, 800]) {
    await page.setViewportSize({ width, height: 900 });
    const wrapped = await page.locator('#query-mode .field-grid').evaluate(grid => {
      const wraps = selector => {
        const label = grid.querySelector(selector).closest('.field').querySelector('span');
        // lineHeight computes to "normal", so compare against the font size.
        const fontSize = parseFloat(getComputedStyle(label).fontSize) || 12;
        return label.getBoundingClientRect().height > fontSize * 1.6;
      };
      return { connections: wraps('.simple-threads'), iterations: wraps('.simple-iterations') };
    });

    expect(wrapped.connections, `Connections label wrapped at ${width}px`).toBe(false);
    expect(wrapped.iterations, `Iterations label wrapped at ${width}px`).toBe(false);
  }

  // Should a label ever wrap on an unusual width, the inputs must still line
  // up: they sit beneath their labels, so an extra label line would otherwise
  // push one input down.
  for (const width of [1400, 1100, 900]) {
    await page.setViewportSize({ width, height: 900 });
    const offsets = await page.locator('#query-mode .field-grid').evaluate(grid => {
      const connections = grid.querySelector('.simple-threads').getBoundingClientRect();
      const iterations = grid.querySelector('.simple-iterations').getBoundingClientRect();
      return { connections: connections.top, iterations: iterations.top };
    });
    // Same row, so the inputs must share a top edge within a rounding margin.
    expect(Math.abs(offsets.connections - offsets.iterations)).toBeLessThan(2);
  }
});

test('keeps every mixed workload column inside its table', async ({ page }) => {
  await openStudio(page);
  await page.locator('[data-mode="workload"]').click();
  await expect(page.locator('.workload-header > span').nth(2)).toContainText('Iterations');
  await expect(page.locator('.workload-header > span').nth(2)).not.toContainText('/ connection');
  await page.locator('#workload-file-input').setInputFiles([
    { name: 'read-orders.sql', mimeType: 'text/plain', buffer: Buffer.from('SELECT 1;') },
    { name: 'write-audit.sql', mimeType: 'text/plain', buffer: Buffer.from('SELECT 2;') }
  ]);

  for (const width of [1440, 1280, 1200, 1000, 900, 800]) {
    await page.setViewportSize({ width, height: 900 });
    const layout = await page.locator('.workload-table').evaluate(table => {
      const tableRect = table.getBoundingClientRect();
      const visibleCells = [...table.querySelectorAll('.workload-header > *, .workload-row > *')]
        .filter(cell => getComputedStyle(cell).display !== 'none');
      const headings = [...table.querySelectorAll('.workload-header > span')]
        .filter(cell => cell.textContent.trim() && getComputedStyle(cell).display !== 'none');
      const lineHeight = headings.length ? parseFloat(getComputedStyle(headings[0]).lineHeight) || 16 : 0;
      return {
        overflows: table.scrollWidth > table.clientWidth,
        outside: visibleCells.some(cell => {
          const rect = cell.getBoundingClientRect();
          return rect.left < tableRect.left - 1 || rect.right > tableRect.right + 1;
        }),
        crampedHeadings: headings
          .filter(cell => cell.scrollWidth > cell.clientWidth + 1 || cell.getBoundingClientRect().height > lineHeight * 1.5)
          .map(cell => cell.textContent.trim())
      };
    });
    expect(layout.overflows, `Workload table overflowed at ${width}px`).toBe(false);
    expect(layout.outside, `Workload cell escaped its table at ${width}px`).toBe(false);
    expect(layout.crampedHeadings, `Workload headings wrapped or overflowed at ${width}px`).toEqual([]);
  }
});

test('applies, persists, and cancels the named color themes', async ({ page }) => {
  await openStudio(page);
  const themes = {
    blue: ['Blue', 'dark'], 'red-blue': ['Red & Blue', 'dark'], 'royal-blue': ['Royal Blue', 'light'],
    green: ['Green', 'light'], 'green-black': ['Green & Black', 'dark'], 'green-gold': ['Green & Gold', 'dark']
  };
  const html = page.locator('html');

  for (const [value, [label, base]] of Object.entries(themes)) {
    await page.locator('#open-app-settings').click();
    await page.locator('#app-theme').selectOption({ label });
    await page.locator('#apply-app-settings').click();
    await expect(html).toHaveAttribute('data-theme', base);
    await expect(html).toHaveAttribute('data-accent', value);
    const rail = await page.locator('.app-sidebar').evaluate(element => getComputedStyle(element).backgroundColor);
    expect(rail, `${label} colors the navigation rail`).not.toBe('rgb(255, 255, 255)');
  }

  await page.reload();
  await expect(html).toHaveAttribute('data-accent', 'green-gold');
  await expect(html).toHaveAttribute('data-theme-preference', 'green-gold');

  // Cancel restores the saved theme; Light and Dark carry no accent.
  await page.locator('#open-app-settings').click();
  await page.locator('#app-theme').selectOption('dark');
  await expect(html).not.toHaveAttribute('data-accent', /.+/);
  await page.locator('#cancel-app-settings').click();
  await expect(html).toHaveAttribute('data-accent', 'green-gold');
  await page.locator('#open-app-settings').click();
  await page.locator('#app-theme').selectOption('light');
  await page.locator('#apply-app-settings').click();
  await expect(html).toHaveAttribute('data-theme', 'light');
  await expect(html).not.toHaveAttribute('data-accent', /.+/);
});

test('keeps every primary view and overlay inside responsive viewports', async ({ page }) => {
  await openStudio(page);

  for (const width of [390, 560, 760, 800, 900, 1200, 1440]) {
    await page.setViewportSize({ width, height: 900 });
    for (const view of ['configure', 'monitor', 'results', 'compare']) {
      await page.locator(`[data-view="${view}"]`).click();
      const layout = await page.evaluate(() => ({
        viewportWidth: window.innerWidth,
        documentWidth: document.documentElement.scrollWidth,
        bodyWidth: document.body.scrollWidth
      }));
      expect(layout.documentWidth, `${view} document overflowed at ${width}px`).toBeLessThanOrEqual(layout.viewportWidth);
      expect(layout.bodyWidth, `${view} body overflowed at ${width}px`).toBeLessThanOrEqual(layout.viewportWidth);
    }

    if (width <= 760) {
      const mobileNavigation = await page.locator('.view-tabs').evaluate(nav => {
        const sidebar = nav.closest('.app-sidebar');
        return {
          navigation: getComputedStyle(nav).backgroundColor,
          sidebar: getComputedStyle(sidebar).backgroundColor
        };
      });
      expect(mobileNavigation.navigation).toBe(mobileNavigation.sidebar);
    }
  }

  await page.setViewportSize({ width: 1200, height: 900 });
  const configureTab = page.locator('[data-view="configure"]');
  await expect(page.locator('.brand-copy')).toBeHidden();
  await expect(configureTab.locator('.nav-label')).toBeHidden();
  await configureTab.hover();
  await page.waitForTimeout(200);
  const navigationTooltip = await configureTab.evaluate(tab => ({
    text: getComputedStyle(tab, '::after').content,
    opacity: getComputedStyle(tab, '::after').opacity,
    sidebarWidth: tab.closest('.app-sidebar').getBoundingClientRect().width
  }));
  expect(navigationTooltip.text).toBe('"Configure"');
  expect(navigationTooltip.opacity).toBe('1');
  expect(navigationTooltip.sidebarWidth).toBe(76);

  await page.setViewportSize({ width: 390, height: 844 });
  await page.locator('[data-view="monitor"]').click();
  await page.locator('[data-open-log]').first().click();
  await page.waitForTimeout(250);
  const drawerBounds = await page.locator('#log-drawer').evaluate(drawer => {
    const rect = drawer.getBoundingClientRect();
    return { left: rect.left, right: rect.right, viewportWidth: window.innerWidth };
  });
  expect(drawerBounds.left).toBeGreaterThanOrEqual(0);
  expect(drawerBounds.right).toBeLessThanOrEqual(drawerBounds.viewportWidth);
  await page.locator('#close-log').click();

  await page.locator('#open-app-settings').click();
  const dialogBounds = await page.locator('#app-settings-dialog').evaluate(dialog => {
    const rect = dialog.getBoundingClientRect();
    return { left: rect.left, right: rect.right, viewportWidth: window.innerWidth };
  });
  expect(dialogBounds.left).toBeGreaterThanOrEqual(0);
  expect(dialogBounds.right).toBeLessThanOrEqual(dialogBounds.viewportWidth);
});
