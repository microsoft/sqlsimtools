const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const { chromium } = require('@playwright/test');

const studioRoot = path.resolve(__dirname, '..');
const studioExecutable = path.join(studioRoot, 'build', 'win-x64', 'SqlSimStudio.exe');
const sqlsimExecutable = path.join(studioRoot, 'build', 'win-x64', 'sqlsim', 'sqlsim.exe');
const replayFile = path.resolve(studioRoot, '..', 'sqlsim', 'testing', 'replay-test-data.xml');
const frameDirectory = path.join(studioRoot, 'build', 'demo-gif-frames');
const blogHeroPath = path.resolve(studioRoot, '..', 'assets', 'sqlsimstudio-blog-hero.png');
const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'sqlsimstudio-demo-'));
const bootstrapFile = path.join(temporaryDirectory, 'bootstrap.txt');
const demoSqlFile = path.join(temporaryDirectory, 'adventureworks-demo.sql');
const adventureWorksQuery = `WITH Product AS (
  SELECT * FROM (VALUES
    (707, N'Sport-100 Helmet', CAST(34.99 AS decimal(10,2))),
    (708, N'Mountain Bike Socks', CAST(9.50 AS decimal(10,2))),
    (709, N'Road Bottle Cage', CAST(8.99 AS decimal(10,2))),
    (710, N'HL Mountain Tire', CAST(35.00 AS decimal(10,2))),
    (711, N'Cycling Cap', CAST(8.99 AS decimal(10,2)))
  ) AS products(ProductID, Name, ListPrice)
), SalesOrderDetail AS (
  SELECT TOP (5000)
    707 + ((ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1) % 5) AS ProductID,
    1 + ((ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1) % 4) AS OrderQty
  FROM sys.all_objects AS source_a
  CROSS JOIN sys.all_objects AS source_b
)
SELECT TOP (5)
  product.Name,
  SUM(detail.OrderQty) AS UnitsSold,
  CAST(SUM(detail.OrderQty * product.ListPrice) AS decimal(18,2)) AS Revenue
FROM Product AS product
JOIN SalesOrderDetail AS detail ON detail.ProductID = product.ProductID
GROUP BY product.Name
ORDER BY Revenue DESC;`;

function delay(milliseconds) {
  return new Promise(resolve => setTimeout(resolve, milliseconds));
}

function escapeHtml(value) {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
}

async function waitForBootstrap(studio) {
  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    if (fs.existsSync(bootstrapFile)) {
      const url = fs.readFileSync(bootstrapFile, 'utf8').trim();
      if (url) return url;
    }
    if (studio.exitCode !== null) {
      throw new Error(`Studio exited before bootstrap with code ${studio.exitCode}.`);
    }
    await delay(100);
  }
  throw new Error('Studio did not create its bootstrap file within 20 seconds.');
}

async function capture(page, name, caption) {
  await page.evaluate(text => {
    document.querySelector('#demo-gif-caption')?.remove();
    const caption = document.createElement('div');
    caption.id = 'demo-gif-caption';
    caption.textContent = text;
    const configureActive = document.querySelector('#configure-view')?.classList.contains('active');
    Object.assign(caption.style, {
      position: 'fixed',
      right: '24px',
      bottom: configureActive ? '92px' : '24px',
      zIndex: '2147483647',
      pointerEvents: 'none',
      maxWidth: '680px',
      padding: '11px 16px',
      border: '1px solid rgba(217, 224, 230, 0.38)',
      borderRadius: '8px',
      background: 'rgba(11, 47, 91, 0.94)',
      color: '#ffffff',
      boxShadow: '0 8px 24px rgba(4, 30, 66, 0.22)',
      font: '600 16px/1.25 Segoe UI, sans-serif'
    });
    document.body.append(caption);
  }, caption);
  await delay(200);
  await page.screenshot({ path: path.join(frameDirectory, name) });
}

async function configureQuery(page, telemetry) {
  await page.locator('[data-view="configure"]').click();
  await page.locator('[data-mode="query"]').click();
  await page.locator('#server').fill('localhost');
  await page.locator('#database').fill('tempdb');
  await page.locator('#authentication').selectOption('integrated');
  await page.locator('#query-text').fill(adventureWorksQuery);
  await page.locator('#query-mode .simple-threads').fill('2');
  await page.locator('#query-mode .simple-iterations').fill('4');
  await page.locator('#statistics-source').selectOption('none');
  await page.locator('#telemetry-mode').selectOption(telemetry);
}

async function runAndOpenResults(page) {
  await page.locator('#run-workload').click();
  await page.waitForSelector('#monitor-view.active');
  await page.locator('#stop-run').filter({ hasText: 'View results' }).waitFor({ timeout: 45_000 });
  await page.locator('#stop-run').click();
  await page.waitForSelector('#results-view.active');
  await page.locator('#result-status-title').filter({ hasText: 'Run completed successfully' }).waitFor();
}

async function main() {
  for (const requiredPath of [studioExecutable, sqlsimExecutable, replayFile]) {
    if (!fs.existsSync(requiredPath)) throw new Error(`Missing required executable: ${requiredPath}`);
  }

  fs.rmSync(frameDirectory, { recursive: true, force: true });
  fs.mkdirSync(frameDirectory, { recursive: true });
  fs.writeFileSync(demoSqlFile, adventureWorksQuery, 'utf8');

  const studio = spawn(studioExecutable, ['--no-open', '--bootstrap-file', bootstrapFile], {
    cwd: path.dirname(studioExecutable),
    env: { ...process.env, SQLSIMSTUDIO_SETTINGS_DIR: path.join(temporaryDirectory, 'settings') },
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe']
  });
  let studioError = '';
  studio.stderr.on('data', chunk => { studioError += chunk.toString(); });

  const browser = await chromium.launch({ channel: 'msedge', headless: true });
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 });

  try {
    const bootstrapUrl = await waitForBootstrap(studio);
    await page.goto(bootstrapUrl);
    await page.waitForSelector('#runtime-status:not(.offline)');

    const blogContext = await browser.newContext({
      viewport: { width: 1440, height: 900 },
      deviceScaleFactor: 2,
      storageState: await page.context().storageState()
    });
    const blogPage = await blogContext.newPage();
    await blogPage.goto(page.url());
    await blogPage.waitForSelector('#runtime-status:not(.offline)');
    await configureQuery(blogPage, 'live');
    await blogPage.locator('#database').fill('AdventureWorksLT');
    await blogPage.screenshot({ path: blogHeroPath });
    await blogContext.close();

    await configureQuery(page, 'live');
    await page.locator('#execution-engine').evaluate(element => {
      element.style.outline = '4px solid #f7b32b';
      element.style.outlineOffset = '3px';
    });
    await capture(page, '00-engine-sqlsim.png', 'Execution engine: choose native sqlsim for the lowest client overhead');
    await page.locator('#execution-engine').selectOption('sqlpysim');
    await capture(page, '01-engine-sqlpysim.png', 'Execution engine: switch to sqlpysim for the mssql-python driver');
    await page.locator('#execution-engine').selectOption('sqlsim');
    await page.locator('#execution-engine').evaluate(element => {
      element.style.outline = '';
      element.style.outlineOffset = '';
    });
    await capture(page, '02-query.png', 'Query: define SQL, connections, iterations, and live telemetry');

    await page.locator('#open-app-settings').click();
    await page.locator('#app-theme').selectOption('dark');
    await page.locator('#apply-app-settings').click();
    await capture(page, '02a-dark-theme.png', 'Themes: use light, dark, or system appearance without changing the workload');
    await page.locator('#open-app-settings').click();
    await page.locator('#app-theme').selectOption('light');
    await page.locator('#apply-app-settings').click();

    await page.locator('[data-mode="file"]').click();
    await page.locator('#sql-file-input').setInputFiles({
      name: 'demo-script.sql',
      mimeType: 'text/plain',
      buffer: Buffer.from('SELECT 101 AS FirstBatch;\nGO\nSELECT 202 AS SecondBatch;')
    });
    await page.locator('#file-mode .simple-threads').fill('3');
    await page.locator('#file-mode .simple-iterations').fill('5');
    await capture(page, '03-sql-script.png', 'SQL File: load a multi-batch script and shape its execution');

    await page.locator('[data-mode="workload"]').click();
    await page.locator('#workload-file-input').setInputFiles([
      { name: 'read-orders.sql', mimeType: 'text/plain', buffer: Buffer.from('SELECT TOP (10) name FROM sys.objects;') },
      { name: 'write-audit.sql', mimeType: 'text/plain', buffer: Buffer.from('SELECT SYSDATETIME() AS AuditTime;') }
    ]);
    await page.locator('.group-threads').first().fill('4');
    await page.locator('.group-iterations').first().fill('25');
    await page.locator('.group-threads').last().fill('2');
    await page.locator('.group-iterations').last().fill('10');
    await page.locator('.group-think').last().fill('50');
    await capture(page, '04-workload-json.png', 'Workload JSON: Studio generates a mixed workload from configured groups');

    await page.locator('[data-mode="replay"]').click();
    await page.locator('#replay-file-input').setInputFiles(replayFile);
    await page.locator('#replay-mode-select').selectOption('stress');
    await page.locator('#replay-threads').fill('4');
    await capture(page, '05-replay.png', 'Replay: load captured sessions and choose fast or stress execution');

    await configureQuery(page, 'live');
    await page.locator('#run-workload').click();
    await page.waitForSelector('#monitor-view.active');
    await page.waitForSelector('#run-state-label:text-is("Running...")');
    await page.waitForSelector('#event-table .event-row', { timeout: 30_000 });
    try {
      await page.locator('#stop-run').filter({ hasText: 'View results' }).waitFor({ timeout: 45_000 });
    } catch (error) {
      const diagnostic = await page.evaluate(async () => {
        const response = await fetch('/api/runs/current', { credentials: 'same-origin', cache: 'no-store' });
        const snapshot = await response.json();
        return {
          state: snapshot.state,
          exitCode: snapshot.exitCode,
          progress: snapshot.progress,
          errors: (snapshot.logs || [])
            .filter(log => log.level === 'error' || log.level === 'warning')
            .map(log => ({ source: log.source, level: log.level, message: log.message })),
          logs: (snapshot.logs || []).slice(-8).map(log => ({ source: log.source, level: log.level, message: log.message }))
        };
      });
      console.error(`Live run diagnostic: ${JSON.stringify(diagnostic)}`);
      throw error;
    }
    await page.waitForFunction(() => {
      const value = document.querySelector('#execution-count')?.textContent?.replaceAll(',', '') || '0';
      return Number(value) > 0;
    }, { timeout: 5_000 });
    await capture(page, '06-monitor.png', 'Monitor: review streamed progress across concurrent workers');
    await page.locator('#stop-run').click();
    await page.waitForSelector('#results-view.active');
    await capture(page, '07-results.png', 'Results: inspect throughput, timing, and completed executions');

    await configureQuery(page, 'final');
    await page.locator('#query-mode .simple-iterations').fill('1');
    await runAndOpenResults(page);
    await configureQuery(page, 'final');
    await page.locator('#query-mode .simple-iterations').fill('1');
    await runAndOpenResults(page);
    await page.locator('#compare-result').click();
    await page.locator('#comparison-status-title').filter({ hasText: 'Runs are comparable' }).waitFor();
    await capture(page, '08-comparison.png', 'Compare: measure two real compatible runs side by side');

    await configureQuery(page, 'console');
    await page.locator('#query-mode .simple-threads').fill('1');
    await page.locator('#query-mode .simple-iterations').fill('1');
    await capture(page, '09-console-mode.png', 'Console output: show result rows directly in Studio');
    await page.locator('#run-workload').click();
    await page.waitForSelector('#results-view.active', { timeout: 45_000 });
    await page.locator('#result-console-panel:not(.hidden)').waitFor();
    await page.locator('#result-console-output').filter({ hasText: 'Sport-100 Helmet' }).waitFor();
    await page.locator('#result-console-output').filter({ hasText: 'Revenue' }).waitFor();
    await capture(page, '10-console-results.png', 'Results: inspect the actual query rows captured from sqlsim stdout');

    const displayCommand = 'sqlsim.exe -S localhost -d tempdb -E -i .\\adventureworks-demo.sql -n 2 -r 1 -q';
    const execution = spawnSync(sqlsimExecutable, [
      '-S', 'localhost', '-d', 'tempdb', '-E', '-i', demoSqlFile, '-n', '2', '-r', '1', '-q'
    ], { cwd: temporaryDirectory, encoding: 'utf8', windowsHide: true });
    if (execution.status !== 0) {
      throw new Error(`sqlsim terminal demo failed with code ${execution.status}: ${execution.stderr}`);
    }
    const terminalOutput = `${execution.stdout}${execution.stderr}`
      .replace(/\x1b\[[0-9;]*m/g, '')
      .trim();

    const terminalHtml = (command, output = '', title = 'sqlsim') => `
      <style>
        html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: #012456; }
        .terminal { position: absolute; inset: 0; overflow: hidden; background: #012456; border: 1px solid #4a4a4a; box-sizing: border-box; }
        .titlebar { display: flex; align-items: center; height: 32px; background: #202020; color: #ffffff; font: 12px/1 'Segoe UI', sans-serif; user-select: none; }
        .powershell-icon { display: grid; place-items: center; width: 18px; height: 18px; margin: 0 8px; border-radius: 2px; background: #2671be; color: #ffffff; font: 700 11px Consolas, monospace; }
        .window-title { white-space: nowrap; }
        .window-controls { display: flex; height: 32px; margin-left: auto; }
        .window-controls span { display: grid; place-items: center; width: 46px; color: #ffffff; font: 12px 'Segoe UI Symbol', sans-serif; }
        .window-controls .close { font-size: 15px; }
        .terminal-body { position: relative; height: calc(100vh - 32px); background: #012456; }
        pre { margin: 0; padding: 10px 12px; white-space: pre-wrap; color: #ffffff; font: 18px/1.35 Consolas, monospace; }
        .prompt, .command, .output { color: #ffffff; }
        .cursor { display: inline-block; width: 10px; height: 20px; margin-left: 1px; vertical-align: -3px; background: #ffffff; }
        .scrollbar { position: absolute; top: 0; right: 0; bottom: 0; width: 17px; background: #f0f0f0; }
        .scrollbar::before { content: '▲'; display: grid; place-items: center; height: 17px; color: #222222; font: 9px sans-serif; }
        .scrollbar::after { content: '▼'; position: absolute; right: 0; bottom: 0; display: grid; place-items: center; width: 17px; height: 17px; color: #222222; font: 9px sans-serif; }
      </style>
      <section class="terminal">
        <div class="titlebar"><span class="powershell-icon">&gt;_</span><span class="window-title">Windows PowerShell - ${escapeHtml(title)}</span><div class="window-controls"><span>─</span><span>□</span><span class="close">×</span></div></div>
        <div class="terminal-body"><pre><span class="prompt">PS C:\\sqlsimtools&gt; </span><span class="command">${escapeHtml(command)}</span>${output ? `\n\n<span class="output">${escapeHtml(output)}\n\nPS C:\\sqlsimtools&gt; </span><span class="cursor"></span>` : '<span class="cursor"></span>'}</pre><div class="scrollbar"></div></div>
      </section>
    `;

    const terminalPage = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 });
    await terminalPage.setContent(terminalHtml(displayCommand.slice(0, 30)));
    await terminalPage.screenshot({ path: path.join(frameDirectory, '11-powershell-type.png') });
    await terminalPage.setContent(terminalHtml(displayCommand));
    await terminalPage.screenshot({ path: path.join(frameDirectory, '12-powershell-command.png') });
    await terminalPage.setContent(terminalHtml(displayCommand, terminalOutput));
    await terminalPage.screenshot({ path: path.join(frameDirectory, '13-powershell-output.png') });
    const pluginCommand = 'copilot plugin install sqlsim@sqlsimtools';
    await terminalPage.setContent(terminalHtml(
      pluginCommand,
      'Installed plugin sqlsim@sqlsimtools\nSkills and agent guidance are ready for Copilot.',
      'Agent Plugins'
    ));
    await terminalPage.screenshot({ path: path.join(frameDirectory, '14-agent-plugin.png') });
    const skillsOutput = `Copilot CLI
> /skills

Installed skills:
  sqlsim        Build and run native SQL Server workloads
  sqlpysim      Run workloads with the mssql-python driver
  sqlsimstudio  Configure, monitor, replay, and compare in Studio`;
    await terminalPage.setContent(terminalHtml('copilot', skillsOutput, 'Agent Skills'));
    await terminalPage.screenshot({ path: path.join(frameDirectory, '15-agent-skills.png') });
    await terminalPage.close();
  } finally {
    await browser.close();
    if (studio.exitCode === null) studio.kill();
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }

  if (studioError) process.stderr.write(studioError);
  console.log(frameDirectory);
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});