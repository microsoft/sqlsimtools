const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { test, expect } = require('@playwright/test');

// Sweeps every view across desktop widths and fails on text that spills out of
// its box, is clipped, overlaps other text, or wraps where it must stay on one
// line. Like interface.spec.cjs, it loads the client directly: no Studio
// process and no SQL target are required.

const clientUrl = `${pathToFileURL(path.join(__dirname, '..', 'client', 'index.html')).href}#configure`;
const resultFixture = JSON.parse(fs.readFileSync(
  path.join(__dirname, 'fixtures', 'workload-querystats-result.json'), 'utf8'));
const screenshotRoot = process.env.SQLSIMSTUDIO_RESPONSIVE_SCREENSHOTS === '1'
  ? path.join(__dirname, '..', 'build', 'responsive-screenshots')
  : null;

// Both sides of every layout breakpoint, plus common laptop and desktop widths.
// 1280 and 1536 are 1920-wide displays at 150% and 125% Windows scaling.
const widths = [761, 800, 821, 900, 1001, 1024, 1121, 1180, 1240, 1241, 1280, 1300,
  1366, 1440, 1536, 1600, 1680, 1920, 2560];
const screenshotWidths = new Set([800, 1024, 1280, 1366, 1536, 1920]);

// Text that should never wrap at desktop widths. Prose, notes, and values may.
const singleLineSelectors = [
  'button', 'summary', 'dt', '.view-tab', '.segmented button',
  '.field > span', '.metric-box > span', '.result-metrics > div > span',
  '.run-summary span', '.panel-heading h2', '.section-title h2',
  '.workload-header > span', '.query-report-header > span',
  '.replay-capture-header > span', '.replay-comparison-header > span',
  '.config-diff-table > div:first-child > span', '.live-query-totals span', '.live-chart-heading h3',
  '.query-comparison-header > span'
];

// Windows-only interface fonts fall back to wider system fonts on macOS and
// Linux. Verdana is metrically close to DejaVu Sans, the usual Linux fallback,
// and wider than Helvetica, the macOS fallback, so it bounds both.
const wideFontCss = ['Bahnschrift', 'Aptos'].map(family => `
  @font-face { font-family: "${family}"; src: local("Verdana"); font-weight: 100 549; }
  @font-face { font-family: "${family}"; src: local("Verdana Bold"); font-weight: 550 1000; }`).join('')
  + ['Cascadia Mono', 'Consolas'].map(family => `
  @font-face { font-family: "${family}"; src: local("Courier New"); font-weight: 100 549; }
  @font-face { font-family: "${family}"; src: local("Courier New Bold"); font-weight: 550 1000; }`).join('');

function writeTemporaryFile(name, contents) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'sqlsimstudio-responsive-'));
  const target = path.join(directory, name);
  fs.writeFileSync(target, contents, 'utf8');
  return target;
}

async function openStudio(page, testInfo) {
  await page.goto(clientUrl);
  if (testInfo.project.metadata?.wideFont) {
    await page.addStyleTag({ content: wideFontCss });
  }
  await page.evaluate(() => document.fonts.ready);
  await page.locator('#server').fill('sql-prod-eastus2-01.database.windows.net');
  await page.locator('#database').fill('AdventureWorksLT');
}

function completedSnapshot(result, extra = {}) {
  return {
    state: 'completed',
    telemetry: 'final',
    engine: 'sqlsim',
    completedAt: '2026-10-10T17:39:09Z',
    logs: [
      { level: 'info', source: 'Studio', timestamp: '2026-10-10T17:39:07Z', message: 'Starting sqlsim with a private workload definition.' },
      { level: 'warning', source: 'Process', timestamp: '2026-10-10T17:39:08Z', message: 'Changed database context to \'AdventureWorksLT\'.' }
    ],
    result,
    ...extra
  };
}

function replayResult() {
  const longQuery = 'SELECT c.CustomerID, c.CompanyName, SUM(h.TotalDue) AS TotalDue FROM SalesLT.Customer AS c '
    + 'INNER JOIN SalesLT.SalesOrderHeader AS h ON h.CustomerID = c.CustomerID GROUP BY c.CustomerID, c.CompanyName '
    + 'ORDER BY TotalDue DESC;';
  return {
    success: true,
    version: '1.0.0',
    configuration: {
      server: 'sql-prod-eastus2-01.database.windows.net',
      database: 'AdventureWorksLT',
      replay_file: 'C:\\captures\\adventureworks-peak-hour-capture.xml',
      replay_mode: 'fast'
    },
    metrics: { total_runtime_seconds: 12.5, errors: { total: 1 }, warnings: { total: 0 } },
    replay_summary: {
      original: { ok: 1840, error: 2, abort: 1 },
      result: { ok: 1839, error: 3, abort: 0, events: 1842 }
    },
    replay_capture: {
      queries: [
        { query: longQuery, executions: 1200, avg_duration_ms: 4.125, avg_logical_reads: 220 },
        { query: 'SELECT 1;', executions: 640, avg_duration_ms: 0.15, avg_logical_reads: 0 },
        { query: 'EXEC dbo.uspCaptureOnly @Region = N\'Northwest\';', executions: 2, avg_duration_ms: null, avg_logical_reads: null }
      ]
    },
    query_stats: {
      queries: [
        { query: longQuery, executions: 1200, failures: 3, spids: [51, 52, 53, 54, 55, 56, 57, 58, 59, 60], spid_count: 64,
          total_elapsed_ms: { avg: 5.02 }, server_cpu_ms: { avg: 1.4 }, logical_reads: { avg: 232 } },
        { query: 'SELECT 1;', executions: 640, failures: 0, spids: [61], spid_count: 1,
          total_elapsed_ms: { avg: 0.2 }, server_cpu_ms: { avg: 0 }, logical_reads: { avg: 0 } }
      ]
    }
  };
}

function historyRun(id, runtimeSeconds, threads) {
  const result = structuredClone(resultFixture);
  result.metrics.total_runtime_seconds = runtimeSeconds;
  return {
    id,
    mode: 'workload',
    engine: 'sqlsim',
    server: 'sql-prod-eastus2-01.database.windows.net',
    database: 'AdventureWorksLT',
    completedAt: '2026-10-10T17:39:09Z',
    threads,
    iterations: 4,
    workloadHash: '3f9a1c2b7d4e5f60718293a4b5c6d7e8',
    statisticsSource: 'Runtime messages',
    comparisonKey: 'workload|sqlsim|runtime',
    result
  };
}

async function showRunHistory(page, runs) {
  // Studio's own loader renders the pickers; only the server response is stubbed.
  await page.evaluate(history => {
    window.fetch = async () => new Response(JSON.stringify(history), {
      status: 200, headers: { 'Content-Type': 'application/json' }
    });
  }, runs);
  await page.locator('[data-view="compare"]').click();
  await page.evaluate(() => loadRunHistory());
}

// Runs in the page. Kept self-contained because Playwright serializes it.
function auditLayout({ checkWrapping, singleLineSelectors: selectors }) {
  const findings = [];
  const tolerance = 1;
  const describe = element => {
    const id = element.id ? `#${element.id}` : '';
    const classes = typeof element.className === 'string' && element.className.trim()
      ? `.${element.className.trim().split(/\s+/).join('.')}` : '';
    const text = (element.textContent || '').trim().replace(/\s+/g, ' ').slice(0, 48);
    return `${element.tagName.toLowerCase()}${id}${classes} "${text}"`;
  };
  const visible = element => element.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
  const isInline = element => ['inline', 'contents'].includes(getComputedStyle(element).display);
  const isInlineLevel = element => {
    const display = getComputedStyle(element).display;
    return display.startsWith('inline') || display === 'contents';
  };
  const containerOf = element => {
    let node = element;
    while (node.parentElement && isInline(node)) node = node.parentElement;
    return node;
  };
  // Visible area of a text line after every clipping or scrolling ancestor.
  const clipToAncestors = (element, rect) => {
    let { left, right, top, bottom } = rect;
    for (let node = element; node && node !== document.documentElement; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (style.overflowX === 'visible' && style.overflowY === 'visible') continue;
      const box = node.getBoundingClientRect();
      if (style.overflowX !== 'visible') { left = Math.max(left, box.left); right = Math.min(right, box.right); }
      if (style.overflowY !== 'visible') { top = Math.max(top, box.top); bottom = Math.min(bottom, box.bottom); }
    }
    return right - left > 0 && bottom - top > 0
      ? { left, right, top, bottom, width: right - left, height: bottom - top }
      : null;
  };
  // Groups rects into visual lines: inline code chips and icons sit a few
  // pixels off the text baseline but are still on the same line.
  const countLines = rects => {
    const lines = [];
    for (const rect of [...rects].sort((a, b) => a.top - b.top)) {
      const line = lines.find(item => Math.min(item.bottom, rect.bottom) - Math.max(item.top, rect.top)
        > 0.5 * Math.min(item.bottom - item.top, rect.height));
      if (line) {
        line.top = Math.min(line.top, rect.top);
        line.bottom = Math.max(line.bottom, rect.bottom);
      } else {
        lines.push({ top: rect.top, bottom: rect.bottom });
      }
    }
    return lines.length;
  };
  const intentionallyTruncated = (element, container) => {
    for (let node = element; node; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (style.textOverflow === 'ellipsis' && style.overflowX !== 'visible') return true;
      if (node === container) break;
    }
    return false;
  };
  const scrollsWithin = container => ['auto', 'scroll'].includes(getComputedStyle(container).overflowX);
  const layerOf = element => {
    for (let node = element; node; node = node.parentElement) {
      if (node.tagName === 'DIALOG') return node;
      if (['fixed', 'sticky'].includes(getComputedStyle(node).position)) return node;
    }
    return document.body;
  };

  const excludedParents = 'script, style, noscript, select, option, textarea';
  const runs = [];
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if (!node.textContent.trim()) continue;
    const owner = node.parentElement;
    if (!owner || owner.closest(excludedParents) || !visible(owner)) continue;
    const range = document.createRange();
    range.selectNodeContents(node);
    const rects = [...range.getClientRects()].filter(rect => rect.width > 0 && rect.height > 0);
    const lines = rects.map(rect => clipToAncestors(owner, rect)).filter(Boolean);
    if (lines.length) runs.push({ owner, rects, lines, container: containerOf(owner), layer: layerOf(owner) });
  }

  // Text that runs past the edge of its own box either paints over its
  // neighbours or is cut off by a clipping ancestor.
  const reported = new Set();
  for (const run of runs) {
    if (reported.has(run.container) || scrollsWithin(run.container)) continue;
    if (intentionallyTruncated(run.owner, run.container)) continue;
    const box = run.container.getBoundingClientRect();
    const escapes = run.rects.some(line =>
      line.left < box.left - tolerance || line.right > box.right + tolerance);
    if (escapes) {
      reported.add(run.container);
      findings.push(`text escapes its box: ${describe(run.container)}`);
    }
  }

  // Overlapping text is compared only within one stacking layer, so content
  // scrolled beneath the fixed command bar or a dialog is not a collision.
  const entries = runs.flatMap(run => run.lines.map(line => ({ run, line })))
    .sort((a, b) => a.line.top - b.line.top);
  const collisions = new Set();
  for (let i = 0; i < entries.length; i += 1) {
    const a = entries[i];
    for (let j = i + 1; j < entries.length && entries[j].line.top < a.line.bottom; j += 1) {
      const b = entries[j];
      if (a.run === b.run || a.run.layer !== b.run.layer) continue;
      if (a.run.owner.contains(b.run.owner) || b.run.owner.contains(a.run.owner)) continue;
      const width = Math.min(a.line.right, b.line.right) - Math.max(a.line.left, b.line.left);
      const height = Math.min(a.line.bottom, b.line.bottom) - Math.max(a.line.top, b.line.top);
      if (width > 2 && height > 0.35 * Math.min(a.line.height, b.line.height)) {
        const key = `${describe(a.run.owner)} / ${describe(b.run.owner)}`;
        if (!collisions.has(key)) {
          collisions.add(key);
          findings.push(`text overlaps: ${key}`);
        }
      }
    }
  }

  if (checkWrapping) {
    const labels = new Set(selectors.flatMap(selector => [...document.querySelectorAll(selector)]));
    for (const label of labels) {
      if (!visible(label)) continue;
      const rects = [];
      const labelWalker = document.createTreeWalker(label, NodeFilter.SHOW_TEXT);
      for (let node = labelWalker.nextNode(); node; node = labelWalker.nextNode()) {
        if (!node.textContent.trim()) continue;
        // Block-level children such as stacked metric captions are laid out
        // on separate lines by design; only the label's own inline text counts.
        let inlineText = true;
        for (let parent = node.parentElement; parent && parent !== label; parent = parent.parentElement) {
          if (!isInlineLevel(parent)) { inlineText = false; break; }
        }
        if (!inlineText) continue;
        const range = document.createRange();
        range.selectNodeContents(node);
        rects.push(...[...range.getClientRects()].filter(rect => rect.width > 0 && rect.height > 0));
      }
      const lines = countLines(rects);
      if (lines > 1) findings.push(`label wraps onto ${lines} lines: ${describe(label)}`);
    }
  }

  if (document.documentElement.scrollWidth > window.innerWidth + tolerance) {
    // Name the outermost elements that cross the viewport edge while their
    // parent does not; content clipped by a scroll container does not count.
    const culprits = [...document.body.querySelectorAll('*')].filter(element => {
      if (!visible(element) || !element.parentElement) return false;
      const rect = element.getBoundingClientRect();
      if (rect.right <= window.innerWidth + tolerance) return false;
      if (element.parentElement.getBoundingClientRect().right > window.innerWidth + tolerance) return false;
      const shown = clipToAncestors(element.parentElement, rect);
      return shown && shown.right > window.innerWidth + tolerance;
    }).slice(0, 3).map(describe);
    findings.push(`page scrolls horizontally: ${document.documentElement.scrollWidth}px content in ${window.innerWidth}px`
      + (culprits.length ? ` (${culprits.join('; ')})` : ''));
  }
  return findings;
}

async function sweep(page, testInfo, state) {
  const failures = [];
  for (const width of widths) {
    await page.setViewportSize({ width, height: 900 });
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    const findings = await page.evaluate(auditLayout, { checkWrapping: true, singleLineSelectors });
    if (findings.length) {
      failures.push(`${width}px\n    ${findings.join('\n    ')}`);
      await testInfo.attach(`${state}-${width}px`, {
        body: await page.screenshot({ fullPage: true }), contentType: 'image/png'
      });
    }
    if (screenshotRoot && (findings.length || screenshotWidths.has(width))) {
      const directory = path.join(screenshotRoot, testInfo.project.name);
      fs.mkdirSync(directory, { recursive: true });
      await page.screenshot({
        path: path.join(directory, `${state.replace(/[^a-z0-9]+/gi, '-')}-${width}.png`), fullPage: true
      });
    }
  }
  expect(failures, `Layout defects in ${state} (${testInfo.project.name}):\n  ${failures.join('\n  ')}`).toEqual([]);
}

test.describe.configure({ mode: 'parallel' });

test('configure: query with sqlpysim', async ({ page }, testInfo) => {
  await openStudio(page, testInfo);
  await page.locator('#execution-engine').selectOption('sqlpysim');
  await page.locator('[data-mode="query"]').click();
  await sweep(page, testInfo, 'configure-query-sqlpysim');
});

test('configure: SQL file preview and SQL authentication', async ({ page }, testInfo) => {
  await openStudio(page, testInfo);
  await page.locator('#authentication').selectOption('sql');
  await page.locator('#auth-username').fill('studio_load_test');
  await page.locator('[data-mode="file"]').click();
  await page.locator('#sql-file-input').setInputFiles(writeTemporaryFile(
    'adventureworks-customer-order-history-report.sql',
    'SELECT c.CustomerID, c.CompanyName, h.SalesOrderID, h.OrderDate, h.TotalDue FROM SalesLT.Customer AS c INNER JOIN SalesLT.SalesOrderHeader AS h ON h.CustomerID = c.CustomerID;\nGO\nSELECT COUNT(*) FROM SalesLT.Product;\nGO\n'));
  await expect(page.locator('#sql-file-preview')).toBeVisible();
  await page.locator('details.advanced').evaluateAll(details => details.forEach(item => { item.open = true; }));
  await sweep(page, testInfo, 'configure-file-sql-auth');
});

test('configure: workload groups with Query Store', async ({ page }, testInfo) => {
  await openStudio(page, testInfo);
  await page.locator('[data-mode="workload"]').click();
  await page.locator('#workload-file-input').setInputFiles([
    writeTemporaryFile('orders-by-customer-with-a-deliberately-long-script-name.sql', 'SELECT 1;\nGO\nSELECT 2;\n'),
    writeTemporaryFile('audit.sql', 'SELECT 3;\n'),
    writeTemporaryFile('inventory-rebalance.sql', 'SELECT 4;\n')
  ]);
  await expect(page.locator('#workload-rows .workload-row')).toHaveCount(3);
  await page.locator('#statistics-source').selectOption('query-store');
  await sweep(page, testInfo, 'configure-workload-query-store');
});

test('configure: replay preflight in load stress mode', async ({ page }, testInfo) => {
  await openStudio(page, testInfo);
  await page.locator('[data-mode="replay"]').click();
  await page.locator('#replay-file-input').setInputFiles(writeTemporaryFile('adventureworks-peak-hour-capture.xml', `<?xml version="1.0"?>
    <replay>
      <event name="sql_batch_completed"><data name="batch_text"><value>SELECT c.CustomerID, c.CompanyName FROM SalesLT.Customer AS c WHERE c.CompanyName LIKE N'A%' ORDER BY c.CompanyName;</value></data><action name="session_id"><value>51</value></action><action name="database_name"><value>AdventureWorksLT_Production_Capture</value></action></event>
      <event name="rpc_completed"><data name="object_name"><value>sp_executesql</value></data><data name="statement"><value>SELECT 2</value></data><action name="session_id"><value>1052</value></action><action name="database_name"><value>AdventureWorksLT_Production_Capture</value></action></event>
      <event name="attention"><action name="session_id"><value>1052</value></action></event>
    </replay>`));
  await expect(page.locator('#replay-preflight')).toBeVisible();
  await page.locator('#replay-mode-select').selectOption('stress');
  await sweep(page, testInfo, 'configure-replay-stress');
});

test('monitor: live run with event stream and log drawer', async ({ page }, testInfo) => {
  await openStudio(page, testInfo);
  await page.evaluate(() => {
    plannedExecutions = 76000;
    const progress = (second, completed) => ({
      type: 'progress', timestamp: `2026-10-10T17:39:${String(second).padStart(2, '0')}Z`,
      elapsed_seconds: second, successful_executions: completed, failed_executions: 12,
      successful_connections: 1020, failed_connections: 4, errors: 12, throughput_per_second: 4210
    });
    const logs = [
      { level: 'info', source: 'Studio', timestamp: '2026-10-10T17:39:01Z', message: 'Starting sqlsim with a private workload definition.' },
      { level: 'error', source: 'stream', timestamp: '2026-10-10T17:39:03Z', message: '[Microsoft][ODBC Driver 18 for SQL Server][SQL Server]Transaction (Process ID 1052) was deadlocked on lock resources with another process and has been chosen as the deadlock victim. Rerun the transaction.' }
    ];
    const queryStat = (index, executions, elapsed) => ({
      query: index === 0 ? 'SELECT o.name, s.name FROM sys.objects AS o INNER JOIN sys.schemas AS s ON s.schema_id = o.schema_id ORDER BY o.object_id;' : `SELECT ${index} AS value;`,
      executions, failures: index === 2 ? 3 : 0, spids: [51 + index], spid_count: 1,
      total_elapsed_ms: { avg: elapsed }, server_elapsed_ms: { avg: elapsed * 0.72 },
      server_cpu_ms: { avg: elapsed * 0.4 }, logical_reads: { avg: 20 + index * 7 }
    });
    const liveQueryStats = { query_stats: {
      queries: Array.from({ length: 12 }, (_, index) => queryStat(index, 1200 - index * 60, 2.5 + index * 0.35)),
      totals: { executions: 10440, total_elapsed_ms: 48210.5, server_cpu_ms: 17300.2, logical_reads: 412000, physical_reads: 220 }
    } };
    applyRunSnapshot({ state: 'running', telemetry: 'live', logs, progress: progress(1, 4100) });
    applyRunSnapshot({ state: 'running', telemetry: 'live', logs, progress: progress(2, 8420), liveQueryStats });
  });
  await page.locator('[data-view="monitor"]').click();
  await expect(page.locator('#live-query-content')).toBeVisible();
  await sweep(page, testInfo, 'monitor-live');
  await page.locator('#monitor-view [data-open-log]').first().click();
  await sweep(page, testInfo, 'monitor-log-drawer');
});

test('results: runtime query statistics', async ({ page }, testInfo) => {
  await openStudio(page, testInfo);
  await page.evaluate(snapshot => applyRunSnapshot(snapshot), completedSnapshot(resultFixture));
  await page.locator('[data-view="results"]').click();
  await expect(page.locator('#query-report-table .query-report-row')).toHaveCount(3);
  await sweep(page, testInfo, 'results-runtime-statistics');
});

test('results: Query Store statistics', async ({ page }, testInfo) => {
  await openStudio(page, testInfo);
  await page.evaluate(snapshot => applyRunSnapshot(snapshot), completedSnapshot(resultFixture, {
    queryStore: {
      queries: [
        { queryId: 18234, planId: 40211, queryText: resultFixture.query_stats.queries[0].query, executionCount: 48, averageDurationMs: 12.4, averageCpuMs: 2.35, averageLogicalReads: 62 },
        { queryId: 18235, planId: 40212, queryText: 'SELECT TOP (3) name FROM sys.databases ORDER BY name;', executionCount: 28, averageDurationMs: 0.8, averageCpuMs: 0.1, averageLogicalReads: 4 }
      ]
    }
  }));
  await page.locator('[data-view="results"]').click();
  await sweep(page, testInfo, 'results-query-store');
});

test('results: replay comparison', async ({ page }, testInfo) => {
  await openStudio(page, testInfo);
  await page.evaluate(snapshot => applyRunSnapshot(snapshot), completedSnapshot(replayResult()));
  await page.locator('[data-view="results"]').click();
  await expect(page.locator('#result-replay-comparison-panel')).toBeVisible();
  await sweep(page, testInfo, 'results-replay-comparison');
});

test('compare: comparable runs with configuration', async ({ page }, testInfo) => {
  await openStudio(page, testInfo);
  await showRunHistory(page, [historyRun('run-b', 0.92, 20), historyRun('run-a', 1.17, 20)]);
  await expect(page.locator('#comparison-analysis')).toBeVisible();
  await page.locator('#show-differences').click();
  await sweep(page, testInfo, 'compare-comparable');
});

test('compare: incompatible runs', async ({ page }, testInfo) => {
  await openStudio(page, testInfo);
  await showRunHistory(page, [historyRun('run-b', 0.92, 40), historyRun('run-a', 1.17, 20)]);
  await expect(page.locator('#comparison-status-title')).toHaveText('Runs are not comparable');
  await sweep(page, testInfo, 'compare-incompatible');
});

test('overlays: app settings dialog', async ({ page }, testInfo) => {
  await openStudio(page, testInfo);
  await page.locator('#open-app-settings').click();
  await expect(page.locator('#app-settings-dialog')).toBeVisible();
  await sweep(page, testInfo, 'app-settings-dialog');
});
