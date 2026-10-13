const views = document.querySelectorAll('.view');
const tabs = document.querySelectorAll('.view-tab');
const modeButtons = document.querySelectorAll('.segmented button');
const modePanels = document.querySelectorAll('.mode-panel');
const toast = document.querySelector('#toast');
let elapsedTimer;
let runPollTimer;
let elapsedSeconds = 0;
let chartValues = [];
let plannedExecutions = 0;
let lastProgressTimestamp = null;
// Whether a workload is executing right now. Closing the tab while one is
// running leaves it running against the database, so that case is confirmed
// with the user rather than allowed to happen silently.
let workloadIsRunning = false;
// Set once the user confirms Shut down, so the deliberate exit is not also
// challenged by the unsaved-work prompt.
let shuttingDown = false;
// The engine reports throughput cumulatively, which flattens as a run goes on.
// Keeping the previous tick lets the monitor show the rate over the last interval.
let previousTick = null;
let intervalRate = null;
let liveStatisticsSource = 'none';
let selectedMode = 'workload';
let selectedEngine = 'sqlsim';
let selectedSqlFile = null;
let selectedReplayFile = null;
let workloadGroups = [];
let runHistory = [];
let latestSnapshot = null;
const themeStorageKey = 'sqlsimstudio.theme';
const configurationSchema = 'sqlsimstudio.configuration';
const configurationVersion = 1;
const systemTheme = window.matchMedia('(prefers-color-scheme: dark)');
// Color themes build on Light or Dark; the accent supplies the palette.
const accentThemes = {
  blue: 'dark', 'red-blue': 'dark', 'royal-blue': 'light', green: 'light', 'green-black': 'dark', 'green-gold': 'dark'
};
const themePreferences = ['system', 'light', 'dark', ...Object.keys(accentThemes)];

function storedTheme() {
  // Studio writes the theme saved in the user's profile into the page, because
  // a new port at each launch gives the browser a fresh local storage.
  const saved = document.documentElement.dataset.savedTheme;
  if (themePreferences.includes(saved)) return saved;
  try {
    const value = window.localStorage.getItem(themeStorageKey);
    return themePreferences.includes(value) ? value : 'system';
  } catch {
    return 'system';
  }
}

function applyTheme(preference) {
  const accent = Object.hasOwn(accentThemes, preference) ? preference : null;
  const resolved = preference === 'system'
    ? (systemTheme.matches ? 'dark' : 'light')
    : accent ? accentThemes[accent] : preference;
  document.documentElement.dataset.theme = resolved;
  document.documentElement.dataset.themePreference = preference;
  if (accent) {
    document.documentElement.dataset.accent = accent;
  } else {
    delete document.documentElement.dataset.accent;
  }
  document.documentElement.style.colorScheme = resolved;
}

function saveTheme(preference) {
  try {
    window.localStorage.setItem(themeStorageKey, preference);
  } catch {
  }
  applyTheme(preference);
  if (isServerMode()) {
    document.documentElement.dataset.savedTheme = preference;
    fetch('/api/settings', {
      method: 'PUT',
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ theme: preference })
    }).then(response => {
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
    }).catch(() => {
      showError('Theme applied, but Studio could not save it for future sessions.');
    });
  }
}

applyTheme(storedTheme());

function refreshIcons() {
  if (window.lucide) {
    window.lucide.createIcons({ attrs: { 'stroke-width': 1.8 } });
  }
}

function applyEngineVersions(engines) {
  const descriptions = { sqlsim: 'Native ODBC', sqlpysim: 'mssql-python' };
  const problems = new Set(['not found', 'Python not found', 'mssql-python not installed', 'could not start']);
  Object.entries(descriptions).forEach(([engine, description]) => {
    const option = document.querySelector(`#execution-engine option[value="${engine}"]`);
    const info = engines?.[engine];
    const version = typeof info?.version === 'string' && /^[0-9A-Za-z.+-]{1,32}$/.test(info.version) ? ` ${info.version}` : '';
    const problem = info?.available === false
      ? 'not found'
      : problems.has(info?.problem) ? info.problem : '';
    option.textContent = `${engine}${version} · ${description}${problem ? ` · ${problem}` : ''}`;
  });
}

async function loadEngineVersions() {
  try {
    const response = await fetch('/api/engines', { credentials: 'same-origin', cache: 'no-store' });
    if (response.ok) applyEngineVersions(await response.json());
  } catch {
    // The engine labels remain usable without versions.
  }
}

async function connectStudioRuntime() {
  if (window.location.protocol === 'file:') return;
  const status = document.querySelector('#runtime-status');
  try {
    const response = await fetch('/api/health', { credentials: 'same-origin', cache: 'no-store' });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const health = await response.json();
    status.classList.remove('offline');
    document.querySelector('#product-stage').textContent = health.releaseStage;
    status.querySelector('span:last-child').textContent = `Studio ready · v${health.version}`;
    status.title = `Studio app ready · ${health.application} ${health.version} ${health.releaseStage} · ${health.os} · ${health.architecture}. SQL target status is shown when a workload runs.`;
    applyEntraInteractiveSupport(health.supportsEntraInteractive !== false);
    loadEngineVersions();
  } catch {
    status.classList.add('offline');
    status.querySelector('span:last-child').textContent = 'Disconnected';
    status.title = 'Studio server is unavailable';
  }
}

function markStudioOffline() {
  const status = document.querySelector('#runtime-status');
  if (!status) return;
  status.classList.add('offline');
  status.querySelector('span:last-child').textContent = 'Disconnected';
  status.title = 'Studio server is unavailable';
}

// A rejected fetch means the server is unreachable: Studio has exited, or this
// tab belongs to an instance that is no longer running. The browser reports
// that as "Failed to fetch", which tells the user nothing and looks like a
// defect in the workload rather than a missing server.
async function studioFetch(url, options) {
  try {
    return await fetch(url, options);
  } catch {
    markStudioOffline();
    throw new Error('sqlsim Studio is no longer running. Start it again and use the browser tab it opens.');
  }
}

// ODBC Driver 18 implements interactive Entra sign-in on Windows only.
function applyEntraInteractiveSupport(supported) {
  const option = document.querySelector('#authentication option[value="interactive"]');
  option.disabled = !supported;
  option.textContent = supported
    ? 'Microsoft Entra interactive'
    : 'Microsoft Entra interactive · Windows only';
  if (!supported && authentication.value === 'interactive') {
    authentication.value = 'token';
    syncAuthenticationFields();
  }
}

const appSettingsDialog = document.querySelector('#app-settings-dialog');
const appTheme = document.querySelector('#app-theme');
let originalThemePreference = storedTheme();
let pendingThemePreference = originalThemePreference;
appTheme.value = storedTheme();
document.querySelector('#open-app-settings').addEventListener('click', () => {
  originalThemePreference = storedTheme();
  pendingThemePreference = originalThemePreference;
  appTheme.value = originalThemePreference;
  appSettingsDialog.showModal();
  appTheme.focus();
});
function cancelAppSettings() {
  applyTheme(originalThemePreference);
  appTheme.value = originalThemePreference;
  appSettingsDialog.close();
}
document.querySelector('#close-app-settings').addEventListener('click', cancelAppSettings);
document.querySelector('#cancel-app-settings').addEventListener('click', cancelAppSettings);
document.querySelector('#apply-app-settings').addEventListener('click', () => {
  saveTheme(pendingThemePreference);
  originalThemePreference = pendingThemePreference;
  appSettingsDialog.close();
});
appSettingsDialog.addEventListener('click', event => {
  if (event.target === appSettingsDialog) cancelAppSettings();
});
appSettingsDialog.addEventListener('cancel', event => {
  event.preventDefault();
  cancelAppSettings();
});
appTheme.addEventListener('change', () => {
  pendingThemePreference = appTheme.value;
  applyTheme(pendingThemePreference);
});
systemTheme.addEventListener('change', () => {
  if (storedTheme() === 'system') applyTheme('system');
});

function previewArgument(value, placeholder) {
  const text = String(value || '').trim();
  if (!text) return placeholder;
  return `"${text.replaceAll('"', '\\"').replaceAll('\r', ' ').replaceAll('\n', ' ')}"`;
}

// Blank numeric and text inputs mean "leave the flag off" rather than send an empty value.
function optionalNumber(selector) {
  const raw = document.querySelector(selector).value.trim();
  if (!raw) return null;
  const value = Number(raw);
  return Number.isFinite(value) ? value : null;
}

function optionalText(selector) {
  return document.querySelector(selector).value.trim() || null;
}

function connectionOptionFlags() {
  const parts = [];
  const loginTimeout = optionalNumber('#login-timeout');
  if (loginTimeout !== null) parts.push(` -l ${loginTimeout}`);
  const applicationName = optionalText('#application-name');
  // Belt and braces: the field is blanked for sqlpysim, but the preview must
  // never show a flag the server will not send even if that blanking regresses.
  if (applicationName && selectedEngine !== 'sqlpysim') parts.push(` -app ${previewArgument(applicationName, '')}`);
  const retryCount = optionalNumber('#retry-count');
  if (retryCount) parts.push(` -retry ${retryCount}`);
  const encryption = document.querySelector('#encryption').value;
  if (encryption === 'optional') parts.push(' -N o');
  if (encryption === 'mandatory') parts.push(' -N m');
  if (encryption === 'strict') parts.push(' -N s');
  const certificateHostname = optionalText('#certificate-hostname');
  if (certificateHostname) parts.push(` -F ${previewArgument(certificateHostname, '')}`);
  if (document.querySelector('#read-only-intent').checked) parts.push(' -R');
  if (document.querySelector('#multi-subnet-failover').checked) parts.push(' -M');
  return parts.join('');
}

function executionOptionFlags() {
  const parts = [];
  const queryTimeout = optionalNumber('#query-timeout');
  if (queryTimeout !== null) parts.push(` -t ${queryTimeout}`);
  if (document.querySelector('#prepared-statements').checked) parts.push(' -p');
  if (document.querySelector('#reconnect-each-iteration').checked) parts.push(' -reconnect');
  if (document.querySelector('#connection-pooling').checked) parts.push(' -usepool');
  return parts.join('');
}

function commandBase() {
  const executable = selectedEngine === 'sqlsim' ? 'sqlsim' : 'python sqlpysim.py';
  const server = previewArgument(document.querySelector('#server').value, '<server>');
  const database = previewArgument(document.querySelector('#database').value, '<database>');
  const authenticationMode = document.querySelector('#authentication').value;
  const username = previewArgument(document.querySelector('#auth-username').value, '<username>');
  const authenticationFlags = {
    integrated: '-E',
    sql: `-U ${username} -P -`,
    token: '-T -',
    interactive: '-A ActiveDirectoryInteractive',
    // A username here is a user-assigned managed identity client ID.
    managed: document.querySelector('#auth-username').value.trim()
      ? `-A ActiveDirectoryMsi -U ${username}`
      : '-A ActiveDirectoryMsi',
    'service-principal': `-A ActiveDirectoryServicePrincipal -U ${username} -P -`
  };
  let source;
  if (selectedMode === 'query') {
    const threads = document.querySelector('#query-mode .simple-threads').value;
    const iterations = document.querySelector('#query-mode .simple-iterations').value;
    source = `-Q ${previewArgument(document.querySelector('#query-text').value, '<query>')} -n ${threads} -r ${iterations}`;
  } else if (selectedMode === 'file') {
    const threads = document.querySelector('#file-mode .simple-threads').value;
    const iterations = document.querySelector('#file-mode .simple-iterations').value;
    source = `-i <private-temp>/input.sql -n ${threads} -r ${iterations}`;
  } else if (selectedMode === 'workload') {
    source = '-workload <private-temp>/workload.json';
  } else {
    const replayMode = document.querySelector('#replay-mode-select').value;
    const stressThreads = replayMode === 'stress' ? ` -n ${document.querySelector('#replay-threads').value}` : '';
    source = `-replay ${replayMode} -replayfile <private-temp>/replay.xml${stressThreads} -r ${document.querySelector('#replay-iterations').value}`;
  }
  return `${executable} -S ${server} -d ${database} ${authenticationFlags[authenticationMode]} ${source}`;
}

function updateCommandPreview() {
  const telemetryValue = document.querySelector('#telemetry-mode').value;
  const runtimeStats = selectedEngine === 'sqlsim'
    && document.querySelector('#statistics-source').value === 'runtime';
  // Live runs add the snapshot file; it is what feeds measured duration to the monitor.
  const queryStats = runtimeStats
    ? telemetryValue === 'live'
      ? ' -querystats -querystats-interval 1 -querystats-file studio-querystats.json'
      : ' -querystats'
    : '';
  const telemetry = telemetryValue === 'live'
    ? ' -stream-json -json -o studio-results.json'
    : telemetryValue === 'final' ? ' -json -o studio-results.json' : '';
  const quiet = document.querySelector('#quiet-mode-toggle').checked ? ' -q' : '';
  const trustCertificate = document.querySelector('#trust-server-certificate').checked ? ' -C' : '';
  const stopOnError = document.querySelector('#stop-on-error').checked ? ' -stoponerror' : '';
  const command = `${commandBase()}${connectionOptionFlags()}${executionOptionFlags()}${quiet}${trustCertificate}${stopOnError}${queryStats}${telemetry}`;
  const commandText = document.querySelector('#command-text');
  commandText.textContent = command;
  // The preview scrolls, but telemetry flags are appended last and a long
  // server name can push them out of view. The tooltip shows the whole
  // command without requiring the user to find the scrollbar.
  commandText.title = command;
}

// Errors stay until dismissed or until the user leaves the view that raised them.
function showToast(message, tone = 'info') {
  toast.textContent = message;
  toast.classList.remove('hidden');
  toast.classList.toggle('toast-error', tone === 'error');
  toast.title = tone === 'error' ? 'Click to dismiss' : '';
  toast.dataset.errorView = document.querySelector('.view.active')?.id.replace(/-view$/, '') || '';
  window.clearTimeout(showToast.timeout);
  if (tone !== 'error') {
    showToast.timeout = window.setTimeout(() => toast.classList.add('hidden'), 2200);
  }
}

toast.addEventListener('click', () => toast.classList.add('hidden'));

function showError(message) {
  showToast(message, 'error');
}

function switchView(name) {
  if (toast.classList.contains('toast-error') && toast.dataset.errorView && toast.dataset.errorView !== name) {
    toast.classList.add('hidden');
  }
  views.forEach(view => view.classList.toggle('active', view.id === `${name}-view`));
  tabs.forEach(tab => tab.classList.toggle('active', tab.dataset.view === name));
  if (window.location.hash !== `#${name}`) {
    window.history.replaceState(null, '', `#${name}`);
  }
  if (name === 'monitor') requestAnimationFrame(drawChart);
}

tabs.forEach(tab => tab.addEventListener('click', () => {
  switchView(tab.dataset.view);
  if (tab.dataset.view === 'compare') loadRunHistory().catch(error => showError(error.message));
}));

modeButtons.forEach(button => button.addEventListener('click', () => {
  modeButtons.forEach(item => item.classList.toggle('active', item === button));
  modePanels.forEach(panel => panel.classList.toggle('hidden', panel.id !== `${button.dataset.mode}-mode`));
  const labels = { query: 'Run query', file: 'Run script', workload: 'Run workload', replay: 'Run replay' };
  selectedMode = button.dataset.mode;
  if (selectedMode === 'replay') {
    document.querySelector('#telemetry-mode').value = 'final';
    document.querySelector('#telemetry-mode').dispatchEvent(new Event('change'));
  }
  syncReplayDiagnostics();
  updateCommandPreview();
  refreshLoadShapeTotals();
  updateRunSummary();
  document.querySelector('#run-label').textContent = labels[button.dataset.mode];
}));

const statisticsSource = document.querySelector('#statistics-source');
statisticsSource.addEventListener('change', () => {
  const source = statisticsSource.value;
  const note = document.querySelector('#statistics-source-note');
  const container = document.querySelector('#query-stats-row');
  const preflight = document.querySelector('#query-store-preflight');
  container.classList.toggle('warning', source === 'query-store');
  preflight.classList.toggle('hidden', source !== 'query-store');
  if (source === 'runtime') {
    note.textContent = selectedMode === 'replay'
      ? 'Replay diagnostics compare exact SQL-text matches with original XEvent duration, CPU, reads, rows, and outcomes. Adds workload overhead.'
      : 'Per-execution CPU, elapsed time, and I/O from SET STATISTICS TIME/IO. Adds workload overhead; sqlsim only.';
  } else if (source === 'query-store') {
    note.textContent = 'Studio compares Query Store snapshots before and after the run. Requires Query Store plus database performance-state permission. Results are aggregated and may include other sessions executing the same query.';
  } else {
    note.textContent = 'Live monitoring remains available without server statistics.';
  }
  refreshIcons();
  updateCommandPreview();
  const replayDiagnostics = document.querySelector('#replay-diagnostics');
  if (replayDiagnostics) replayDiagnostics.checked = source === 'runtime';
});

function syncReplayDiagnostics() {
  const replay = selectedMode === 'replay';
  document.querySelector('#statistics-source-label').textContent =
    replay ? 'Replay diagnostics' : 'Studio server statistics';
  const diagnostics = document.querySelector('#replay-diagnostics');
  diagnostics.checked = statisticsSource.value === 'runtime';
  if (replay && statisticsSource.value === 'runtime') {
    document.querySelector('#statistics-source-note').textContent =
      'Replay diagnostics compare exact SQL-text matches with original XEvent metrics. Adds workload overhead.';
  }
}

document.querySelector('#replay-diagnostics').addEventListener('change', event => {
  statisticsSource.value = event.target.checked ? 'runtime' : 'none';
  statisticsSource.dispatchEvent(new Event('change'));
});

const telemetryMode = document.querySelector('#telemetry-mode');
telemetryMode.addEventListener('change', () => {
  const consoleMode = telemetryMode.value === 'console';
  const quietToggle = document.querySelector('#quiet-mode-toggle');
  const quietRow = document.querySelector('#quiet-mode-row');
  quietToggle.disabled = !consoleMode;
  quietToggle.checked = !consoleMode;
  quietRow.classList.toggle('capability-disabled', !consoleMode);
  document.querySelector('#quiet-mode-note').textContent = consoleMode
    ? 'Leave off to include rows from the first execution'
    : 'Required by structured JSON telemetry';
  document.querySelector('#telemetry-note').textContent = telemetryMode.value === 'live'
    ? 'Streams aggregate progress once per second while the workload runs.'
    : telemetryMode.value === 'final'
      ? 'No per-operation progress channel. Studio tracks process state and loads final JSON after exit.'
      : 'Runs without JSON output and captures bounded console text, including result rows.';
  updateCommandPreview();
});
document.querySelector('#quiet-mode-toggle').addEventListener('change', updateCommandPreview);
document.querySelector('#trust-server-certificate').addEventListener('change', updateCommandPreview);
document.querySelector('#stop-on-error').addEventListener('change', updateCommandPreview);
document.querySelector('#server').addEventListener('input', updateCommandPreview);
document.querySelector('#database').addEventListener('input', updateCommandPreview);
document.querySelector('#query-text').addEventListener('input', updateCommandPreview);
document.querySelector('#auth-username').addEventListener('input', updateCommandPreview);

[
  '#login-timeout',
  '#application-name',
  '#retry-count',
  '#encryption',
  '#certificate-hostname',
  '#read-only-intent',
  '#multi-subnet-failover',
  '#query-timeout',
  '#prepared-statements'
].forEach(selector => {
  const element = document.querySelector(selector);
  element.addEventListener(element.tagName === 'SELECT' || element.type === 'checkbox' ? 'change' : 'input', updateCommandPreview);
});

// Both engines reject -usepool without -reconnect.
function syncPoolingAvailability() {
  const reconnect = document.querySelector('#reconnect-each-iteration').checked;
  const pooling = document.querySelector('#connection-pooling');
  const available = reconnect;
  pooling.disabled = !available;
  if (!available) pooling.checked = false;
  document.querySelector('#pooling-row').classList.toggle('capability-disabled', !available);
  document.querySelector('#pooling-note').textContent = reconnect
    ? 'Pools connections across reconnect cycles'
    : 'Requires reconnect';
}

document.querySelector('#reconnect-each-iteration').addEventListener('change', () => {
  syncPoolingAvailability();
  updateCommandPreview();
});
document.querySelector('#connection-pooling').addEventListener('change', updateCommandPreview);

document.querySelector('#replay-mode-select').addEventListener('change', event => {
  const stress = event.target.value === 'stress';
  const threadsField = document.querySelector('#replay-threads-field');
  const threads = document.querySelector('#replay-threads');
  threads.disabled = !stress;
  threadsField.classList.toggle('capability-disabled', !stress);
  document.querySelector('#replay-note').innerHTML = stress
    ? '<i data-lucide="gauge"></i><span>Load stress flattens recognized events and distributes executable work across the selected connections. Session boundaries are not preserved.</span>'
    : '<i data-lucide="route"></i><span>Session order creates one worker per captured session and runs each session as fast as possible while preserving its event order.</span>';
  refreshIcons();
  updateCommandPreview();
  updateRunSummary();
  if (selectedReplayFile?.summary) renderReplayCaptureContents(selectedReplayFile.summary);
});
document.querySelector('#replay-threads').addEventListener('input', updateCommandPreview);
document.querySelector('#replay-iterations').addEventListener('input', updateCommandPreview);
document.querySelector('#replay-threads').addEventListener('input', updateRunSummary);
document.querySelector('#replay-iterations').addEventListener('input', updateRunSummary);

document.querySelector('#execution-engine').addEventListener('change', event => {
  selectedEngine = event.target.value;
  const pythonEngine = selectedEngine === 'sqlpysim';
  const engineNote = document.querySelector('#engine-note');
  const replayButton = document.querySelector('#replay-mode-button');
  const queryStatsRow = document.querySelector('#query-stats-row');
  const runtimeOption = document.querySelector('#statistics-source option[value="runtime"]');
  const liveOption = document.querySelector('#telemetry-mode option[value="live"]');

  engineNote.classList.toggle('limited', pythonEngine);
  engineNote.innerHTML = pythonEngine
    ? '<strong>Python engine</strong><span>Driver comparison · Query, SQL file and mixed workload modes · live progress · runtime query statistics</span>'
    : '<strong>Native engine</strong><span>Lowest client overhead · mixed workloads · query statistics · live monitoring</span>';
  replayButton.disabled = pythonEngine;
  runtimeOption.disabled = false;
  liveOption.disabled = false;
  syncPoolingAvailability();
  document.querySelector('#prepared-note').textContent = pythonEngine
    ? 'Accepted but ignored by sqlpysim'
    : 'Prepare once per connection';
  queryStatsRow.classList.remove('capability-disabled');

  // mssql-python reserves the application name and always reports
  // "MSSQL-Python" to the server, so sqlpysim refuses -app rather than accept
  // a value that cannot take effect. The field is emptied as well as
  // disabled: a greyed-out box still showing a name reads as though that name
  // applies. Switching back to sqlsim restores the value that was there.
  const applicationNameInput = document.querySelector('#application-name');
  if (pythonEngine) {
    if (!applicationNameInput.disabled) {
      applicationNameInput.dataset.previousValue = applicationNameInput.value;
    }
    applicationNameInput.value = '';
    applicationNameInput.disabled = true;
    applicationNameInput.title = 'Application name is not supported with sqlpysim.';
  } else {
    if (applicationNameInput.disabled && applicationNameInput.dataset.previousValue !== undefined) {
      applicationNameInput.value = applicationNameInput.dataset.previousValue;
      delete applicationNameInput.dataset.previousValue;
    }
    applicationNameInput.disabled = false;
    applicationNameInput.title = '';
  }

  const servicePrincipal = document.querySelector('#authentication option[value="service-principal"]');
  servicePrincipal.disabled = false;
  servicePrincipal.textContent = 'Service principal';

  if (pythonEngine && selectedMode === 'replay') {
    document.querySelector('[data-mode="file"]').click();
  }
  updateCommandPreview();
});

// Recalculated rather than trusting the markup, so a displayed total is always derived.
const loadShapeRefreshers = [];

document.querySelectorAll('.load-shape').forEach(loadShape => {
  const threads = loadShape.querySelector('.simple-threads');
  const iterations = loadShape.querySelector('.simple-iterations');
  const total = loadShape.querySelector('.simple-total');
  if (!threads || !iterations || !total) return;
  const updateTotal = () => {
    const batches = Number(total.dataset.batches || 1);
    const executions = Math.max(1, Number(threads.value)) * Math.max(1, Number(iterations.value)) * batches;
    total.textContent = executions.toLocaleString();
  };
  loadShapeRefreshers.push(updateTotal);
  threads.addEventListener('input', updateTotal);
  iterations.addEventListener('input', updateTotal);
  threads.addEventListener('input', updateCommandPreview);
  iterations.addEventListener('input', updateCommandPreview);
  threads.addEventListener('input', updateRunSummary);
  iterations.addEventListener('input', updateRunSummary);
});

function refreshLoadShapeTotals() {
  loadShapeRefreshers.forEach(refresh => refresh());
}

function replayChildValue(eventElement, childType, name) {
  const child = Array.from(eventElement.children).find(element =>
    element.localName === childType &&
    (element.getAttribute('name') || '') === name);
  if (!child) return '';
  const value = Array.from(child.children).find(element => element.localName === 'value');
  return value?.textContent?.trim() || '';
}

function replayNumberValue(eventElement, name, divisor = 1) {
  const raw = replayChildValue(eventElement, 'data', name);
  if (raw === '') return null;
  const value = Number(raw);
  return Number.isFinite(value) ? value / divisor : null;
}

function classifyReplayEvent(event) {
  const eventName = event.getAttribute('name') || '';
  const objectName = replayChildValue(event, 'data', 'object_name');
  const normalizedObjectName = objectName.toLowerCase();
  const statement = eventName === 'sql_batch_completed'
    ? replayChildValue(event, 'data', 'batch_text')
    : replayChildValue(event, 'data', 'statement');
  let recognized = false;
  let stressIncluded = false;
  if (eventName === 'sql_batch_completed') {
    recognized = true;
    stressIncluded = true;
  } else if (eventName === 'rpc_completed' && !normalizedObjectName.startsWith('sp_cursor')) {
    recognized = true;
    stressIncluded = !['sp_prepare', 'sp_unprepare', 'sp_reset_connection'].includes(normalizedObjectName) &&
      (normalizedObjectName !== 'sp_execute' || statement !== '');
  }
  return {
    eventName,
    objectName,
    statement,
    recognized,
    stressIncluded,
    sessionId: replayChildValue(event, 'action', 'session_id') || '0',
    database: replayChildValue(event, 'action', 'database_name'),
    timestamp: event.getAttribute('timestamp') || '',
    originalDurationMs: replayNumberValue(event, 'duration', 1000),
    originalCpuMs: replayNumberValue(event, 'cpu_time'),
    logicalReads: replayNumberValue(event, 'logical_reads'),
    physicalReads: replayNumberValue(event, 'physical_reads'),
    writes: replayNumberValue(event, 'writes'),
    rowCount: replayNumberValue(event, 'row_count'),
    originalResult: replayNumberValue(event, 'result')
  };
}

function inspectReplayXml(content) {
  const documentXml = new DOMParser().parseFromString(content, 'application/xml');
  if (documentXml.getElementsByTagName('parsererror').length > 0) {
    throw new Error('The replay file is not well-formed XML.');
  }
  if (documentXml.documentElement?.localName !== 'replay') {
    throw new Error('The replay file must have a <replay> root element.');
  }

  const events = Array.from(documentXml.documentElement.children)
    .filter(element => element.localName === 'event');
  if (events.length === 0) {
    throw new Error('The replay file does not contain any <event> elements.');
  }
  if (events.length > 100_000) {
    throw new Error('The replay file exceeds the 100,000 event limit.');
  }
  let recognizedEvents = 0;
  let skippedEvents = 0;
  const sessions = new Set();
  const databases = new Set();
  const captureEvents = [];
  for (const event of events) {
    const captureEvent = classifyReplayEvent(event);
    captureEvents.push(captureEvent);
    if (captureEvent.recognized) {
      recognizedEvents++;
      sessions.add(captureEvent.sessionId);
    } else {
      skippedEvents++;
    }
    if (captureEvent.database) databases.add(captureEvent.database);
  }

  if (recognizedEvents === 0) {
    throw new Error('The replay file has no sql_batch_completed or supported rpc_completed events.');
  }
  if (databases.size > 1) {
    throw new Error(
      `This Studio release supports one captured database per Replay file. This file contains: ${Array.from(databases).join(', ')}.`);
  }

  return {
    totalEvents: events.length,
    recognizedEvents,
    skippedEvents,
    sessionCount: sessions.size,
    databases: Array.from(databases),
    events: captureEvents
  };
}

function retargetReplayDatabase(content, targetDatabase) {
  const documentXml = new DOMParser().parseFromString(content, 'application/xml');
  Array.from(documentXml.getElementsByTagName('action'))
    .filter(action => action.getAttribute('name') === 'database_name')
    .forEach(action => {
      const value = Array.from(action.children).find(child => child.localName === 'value');
      if (value) value.textContent = targetDatabase;
    });
  documentXml.documentElement.removeAttribute('target_database');
  return new XMLSerializer().serializeToString(documentXml);
}

function replayModeDecision(event, stress) {
  if (!event.recognized) return 'Skipped';
  if (stress && !event.stressIncluded) return 'Excluded in stress';
  return stress ? 'Flattened' : 'Session ordered';
}

function renderReplayCaptureContents(summary) {
  const table = document.querySelector('#replay-capture-table');
  table.querySelectorAll('.replay-capture-row').forEach(row => row.remove());
  const stress = document.querySelector('#replay-mode-select').value === 'stress';
  const displayed = summary.events.filter(event => event.statement || !event.recognized).slice(0, 100);
  displayed.forEach(event => {
    const row = document.createElement('div');
    row.className = 'replay-capture-row';
    row.innerHTML = '<div><strong></strong><span></span></div><span></span><span></span><span></span><span></span><span></span>';
    row.querySelector('strong').textContent = event.statement || '(no executable SQL)';
    row.querySelector('div span').textContent = event.timestamp || 'No timestamp';
    const values = row.querySelectorAll(':scope > span');
    values[0].textContent = event.objectName || event.eventName;
    values[1].textContent = event.sessionId;
    values[2].textContent = event.database || 'Selected target';
    // Long event and database names are truncated to fit; keep them readable on hover.
    [values[0], values[2]].forEach(value => { value.title = value.textContent; });
    values[3].textContent = replayModeDecision(event, stress);
    values[3].className = event.recognized && (!stress || event.stressIncluded) ? 'ok' : 'muted';
    values[4].textContent = event.originalDurationMs === null
      ? 'Not captured'
      : `${event.originalDurationMs.toFixed(3)} ms`;
    table.appendChild(row);
  });
  const hiddenCount = summary.events.length - displayed.length;
  const overflow = document.querySelector('#replay-capture-overflow');
  overflow.classList.toggle('hidden', hiddenCount <= 0);
  overflow.textContent = hiddenCount > 0
    ? `${hiddenCount.toLocaleString()} additional events are not shown in this bounded preview.`
    : '';
}

function showReplayPreflight(summary) {
  document.querySelector('#replay-event-count').textContent = summary.totalEvents.toLocaleString();
  document.querySelector('#replay-recognized-count').textContent = summary.recognizedEvents.toLocaleString();
  document.querySelector('#replay-skipped-count').textContent = summary.skippedEvents.toLocaleString();
  document.querySelector('#replay-session-count').textContent = summary.sessionCount.toLocaleString();
  document.querySelector('#replay-database-summary').textContent = summary.databases.length === 0
    ? 'Database context: selected Studio target (none captured)'
    : `Captured database ${summary.databases[0]} will be redirected to the selected Studio target.`;
  renderReplayCaptureContents(summary);
  document.querySelector('#replay-preflight').classList.remove('hidden');
}

function setReplayFile(name, content, size, detail) {
  const summary = inspectReplayXml(content);
  selectedReplayFile = { name, content, summary };
  document.querySelector('#replay-file-title').textContent = name;
  document.querySelector('#replay-file-detail').textContent =
    `${(size / 1024).toFixed(1)} KB · ${detail}`;
  showReplayPreflight(summary);
  updateCommandPreview();
  updateRunSummary();
}

function renderSqlFilePreview(content) {
  const maximumPreviewCharacters = 20_000;
  const preview = document.querySelector('#sql-file-preview');
  const output = document.querySelector('#sql-file-preview-content');
  const overflow = document.querySelector('#sql-file-preview-overflow');
  output.textContent = content.slice(0, maximumPreviewCharacters);
  const hiddenCharacters = Math.max(0, content.length - maximumPreviewCharacters);
  overflow.classList.toggle('hidden', hiddenCharacters === 0);
  overflow.textContent = hiddenCharacters > 0
    ? `${hiddenCharacters.toLocaleString()} additional characters are not shown in this bounded preview. The complete script will run.`
    : '';
  preview.classList.remove('hidden');
}

async function selectInputFile(file, kind) {
  if (!file) return;
  const isSql = kind === 'sql';
  const expectedExtension = isSql ? '.sql' : '.xml';
  const maximumBytes = isSql ? 1_000_000 : 100_000_000;
  if (!file.name.toLowerCase().endsWith(expectedExtension)) {
    showError(`Choose a ${expectedExtension} file.`);
    return;
  }
  if (file.size > maximumBytes) {
    showError(`${file.name} exceeds the ${isSql ? '1 MB' : '100 MB'} limit.`);
    return;
  }

  const content = await file.text();
  if (isSql) {
    selectedSqlFile = { name: file.name, content };
    document.querySelector('#sql-file-title').textContent = file.name;
    const batches = content.split(/^\s*GO\s*(?:--.*)?$/gmi).filter(value => value.trim()).length;
    document.querySelector('#sql-file-detail').textContent = `${batches} batch${batches === 1 ? '' : 'es'} · ${(file.size / 1024).toFixed(1)} KB`;
    document.querySelector('#file-batch-note').textContent = `${batches} batch${batches === 1 ? '' : 'es'} in selected script`;
    const total = document.querySelector('#file-mode .simple-total');
    total.dataset.batches = String(Math.max(1, batches));
    renderSqlFilePreview(content);
    document.querySelector('#file-mode .simple-threads').dispatchEvent(new Event('input'));
  } else {
    try {
      setReplayFile(file.name, content, file.size, 'preflight passed');
    } catch (error) {
      selectedReplayFile = null;
      document.querySelector('#replay-file-title').textContent = 'Choose a replay XML file';
      document.querySelector('#replay-file-detail').textContent = 'Converted sqlsim XEvent replay XML · maximum 100 MB';
      document.querySelector('#replay-preflight').classList.add('hidden');
      showError(error.message);
      return;
    }
  }
  updateCommandPreview();
}

function configureFilePicker(inputSelector, browseSelector, dropSelector, kind) {
  const input = document.querySelector(inputSelector);
  const browse = document.querySelector(browseSelector);
  const drop = document.querySelector(dropSelector);
  browse.addEventListener('click', event => { event.stopPropagation(); input.click(); });
  drop.addEventListener('click', event => { if (!event.target.closest('button')) input.click(); });
  input.addEventListener('change', () => selectInputFile(input.files[0], kind));
  ['dragenter', 'dragover'].forEach(name => drop.addEventListener(name, event => {
    event.preventDefault();
    drop.classList.add('drag-active');
  }));
  ['dragleave', 'drop'].forEach(name => drop.addEventListener(name, event => {
    event.preventDefault();
    drop.classList.remove('drag-active');
  }));
  drop.addEventListener('drop', event => selectInputFile(event.dataTransfer.files[0], kind));
}

configureFilePicker('#sql-file-input', '#browse-sql-file', '#sql-file-drop', 'sql');
configureFilePicker('#replay-file-input', '#browse-replay-file', '#replay-file-drop', 'replay');

function updateWorkloadTotals() {
  const totalThreads = workloadGroups.reduce((sum, group) => sum + group.threads, 0);
  document.querySelector('#workload-group-count').textContent = workloadGroups.length === 0
    ? 'No workload groups'
    : `${workloadGroups.length} workload group${workloadGroups.length === 1 ? '' : 's'}`;
  document.querySelector('#workload-thread-count').textContent = workloadGroups.length === 0
    ? 'Add one or more SQL scripts'
    : `${totalThreads.toLocaleString()} connections total`;
  updateRunSummary();
}

function updateRunSummary() {
  let threads = 0;
  let executions = 0;
  let executionLabel = 'Estimated executions';
  let connectionLabel = 'Total connections';
  if (selectedMode === 'workload') {
    threads = workloadGroups.reduce((sum, group) => sum + group.threads, 0);
    executions = workloadGroups.reduce(
      (sum, group) => sum + group.threads * group.iterations * group.batchCount, 0);
  } else if (selectedMode === 'replay') {
    const stress = document.querySelector('#replay-mode-select').value === 'stress';
    executionLabel = 'Replay passes';
    connectionLabel = stress ? 'Stress connections' : 'Captured SPIDs';
    threads = stress
      ? Math.max(1, Number(document.querySelector('#replay-threads').value))
      : selectedReplayFile?.summary?.sessionCount ?? null;
    executions = Math.max(1, Number(document.querySelector('#replay-iterations').value));
  } else {
    const panel = selectedMode === 'query' ? '#query-mode' : '#file-mode';
    const iterations = Math.max(1, Number(document.querySelector(`${panel} .simple-iterations`).value));
    const batches = selectedMode === 'file'
      ? Math.max(1, Number(document.querySelector('#file-mode .simple-total').dataset.batches || 1))
      : 1;
    threads = Math.max(1, Number(document.querySelector(`${panel} .simple-threads`).value));
    executions = threads * iterations * batches;
  }
  document.querySelector('#execution-summary-label').textContent = executionLabel;
  document.querySelector('#connection-summary-label').textContent = connectionLabel;
  document.querySelector('#estimated-executions').textContent = executions.toLocaleString();
  document.querySelector('#total-threads').textContent = threads === null ? '—' : threads.toLocaleString();
}

function renderWorkloadGroups() {
  const rows = document.querySelector('#workload-rows');
  rows.replaceChildren();
  if (workloadGroups.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'workload-empty';
    empty.textContent = 'Select SQL scripts to create independently configured workload groups.';
    rows.appendChild(empty);
  }

  workloadGroups.forEach((group, index) => {
    const row = document.createElement('div');
    row.className = 'workload-row';
    row.innerHTML = '<div class="script-cell"><span class="file-icon">SQL</span><div><strong></strong><span></span></div></div>' +
      '<input class="group-threads" type="number" min="1" aria-label="Connections">' +
      '<input class="group-iterations" type="number" min="1" aria-label="Iterations per connection">' +
      '<div class="unit-input"><input class="group-think" type="number" min="0" aria-label="Think time"><span>ms</span></div>' +
      '<button class="row-action remove-group" title="Remove group" aria-label="Remove group"><i data-lucide="trash-2"></i></button>';
    row.querySelector('.script-cell strong').textContent = group.fileName;
    row.querySelector('.script-cell span:last-child').textContent = `${group.batchCount} batch${group.batchCount === 1 ? '' : 'es'}`;
    const threads = row.querySelector('.group-threads');
    const iterations = row.querySelector('.group-iterations');
    const thinkTime = row.querySelector('.group-think');
    threads.value = group.threads;
    iterations.value = group.iterations;
    thinkTime.value = group.thinkTimeMs;
    threads.addEventListener('input', () => { group.threads = Math.max(1, Number(threads.value)); updateWorkloadTotals(); });
    iterations.addEventListener('input', () => { group.iterations = Math.max(1, Number(iterations.value)); updateWorkloadTotals(); });
    thinkTime.addEventListener('input', () => { group.thinkTimeMs = Math.max(0, Number(thinkTime.value)); });
    row.querySelector('.remove-group').addEventListener('click', () => {
      workloadGroups.splice(index, 1);
      renderWorkloadGroups();
    });
    rows.appendChild(row);
  });
  updateWorkloadTotals();
  updateCommandPreview();
  refreshIcons();
}

async function addWorkloadFiles(files) {
  for (const file of files) {
    if (workloadGroups.length >= 20) {
      showError('A workload can contain at most 20 groups.');
      break;
    }
    if (!file.name.toLowerCase().endsWith('.sql') || file.size > 1_000_000) {
      showError(`${file.name} must be a .sql file no larger than 1 MB.`);
      continue;
    }
    const content = await file.text();
    const batchCount = Math.max(1, content.split(/^\s*GO\s*(?:--.*)?$/gmi).filter(value => value.trim()).length);
    workloadGroups.push({ fileName: file.name, content, threads: 1, iterations: 1, thinkTimeMs: 0, batchCount });
  }
  renderWorkloadGroups();
}

const workloadFileInput = document.querySelector('#workload-file-input');
document.querySelector('#add-script').addEventListener('click', () => workloadFileInput.click());
document.querySelector('#add-group').addEventListener('click', () => workloadFileInput.click());
workloadFileInput.addEventListener('change', async () => {
  await addWorkloadFiles([...workloadFileInput.files]);
  workloadFileInput.value = '';
});
renderWorkloadGroups();

const authentication = document.querySelector('#authentication');

// Mirrors the engines' own rules so an unusable combination is refused before a run.
const authenticationRules = {
  integrated: { user: 'none', secret: 'none', note: '' },
  token: {
    user: 'none', secret: 'required', secretLabel: 'Access token',
    note: 'az account get-access-token --resource https://database.windows.net --query accessToken -o tsv'
  },
  interactive: {
    user: 'none', secret: 'none',
    note: 'Opens a browser sign-in prompt. Supported on Windows only.'
  },
  managed: {
    user: 'optional', userLabel: 'User-assigned client ID',
    secret: 'none',
    note: 'Uses the identity of the host Studio runs on. Leave the client ID empty for a system-assigned identity.'
  },
  'service-principal': {
    user: 'required', userLabel: 'Application (client) ID',
    secret: 'required', secretLabel: 'Client secret',
    note: 'Requires an application client ID and secret.'
  },
  sql: { user: 'required', userLabel: 'Username', secret: 'required', secretLabel: 'Password', note: '' }
};

function syncAuthenticationFields() {
  const rule = authenticationRules[authentication.value] ?? authenticationRules.integrated;
  const username = document.querySelector('#auth-username');
  const secret = document.querySelector('#auth-secret');

  username.required = rule.user === 'required';
  secret.required = rule.secret === 'required';
  document.querySelector('#username-field').classList.toggle('hidden', rule.user === 'none');
  document.querySelector('#secret-field').classList.toggle('hidden', rule.secret === 'none');
  if (rule.user === 'none') username.value = '';
  if (rule.secret === 'none') secret.value = '';

  const requiredMark = ' <b class="required-mark" aria-hidden="true">*</b>';
  document.querySelector('#username-label').innerHTML =
    (rule.userLabel ?? 'Username / client ID') + (rule.user === 'required' ? requiredMark : '');
  document.querySelector('#secret-label').innerHTML =
    (rule.secretLabel ?? 'Password / token') + (rule.secret === 'required' ? requiredMark : '');

  const note = document.querySelector('#authentication-note');
  note.textContent = rule.note;
  note.classList.toggle('hidden', !rule.note);
  updateCommandPreview();
}

authentication.addEventListener('change', syncAuthenticationFields);

function selectedSourceConfiguration() {
  if (selectedMode === 'query') {
    return {
      query: document.querySelector('#query-text').value,
      threads: Number(document.querySelector('#query-mode .simple-threads').value),
      iterations: Number(document.querySelector('#query-mode .simple-iterations').value)
    };
  }
  if (selectedMode === 'file') {
    return {
      fileName: selectedSqlFile?.name || null,
      content: selectedSqlFile?.content || null,
      threads: Number(document.querySelector('#file-mode .simple-threads').value),
      iterations: Number(document.querySelector('#file-mode .simple-iterations').value)
    };
  }
  if (selectedMode === 'workload') {
    return {
      groups: workloadGroups.map(group => ({
        fileName: group.fileName,
        content: group.content,
        threads: group.threads,
        iterations: group.iterations,
        thinkTimeMs: group.thinkTimeMs
      }))
    };
  }
  return {
    fileName: selectedReplayFile?.name || null,
    content: selectedReplayFile?.content || null,
    replayMode: document.querySelector('#replay-mode-select').value,
    iterations: Number(document.querySelector('#replay-iterations').value),
    threads: Number(document.querySelector('#replay-threads').value)
  };
}

function createConfigurationProfile() {
  return {
    schema: configurationSchema,
    version: configurationVersion,
    savedAt: new Date().toISOString(),
    configuration: {
      engine: selectedEngine,
      mode: selectedMode,
      connection: {
        server: document.querySelector('#server').value,
        database: document.querySelector('#database').value,
        authentication: authentication.value,
        username: document.querySelector('#auth-username').value || null,
        trustServerCertificate: document.querySelector('#trust-server-certificate').checked,
        loginTimeoutSeconds: optionalNumber('#login-timeout'),
        applicationName: optionalText('#application-name'),
        retryCount: optionalNumber('#retry-count'),
        encryption: document.querySelector('#encryption').value,
        certificateHostname: optionalText('#certificate-hostname'),
        readOnlyIntent: document.querySelector('#read-only-intent').checked,
        multiSubnetFailover: document.querySelector('#multi-subnet-failover').checked
      },
      source: selectedSourceConfiguration(),
      execution: {
        telemetry: telemetryMode.value,
        quiet: document.querySelector('#quiet-mode-toggle').checked,
        stopOnError: document.querySelector('#stop-on-error').checked,
        statisticsSource: statisticsSource.value,
        queryTimeoutSeconds: optionalNumber('#query-timeout'),
        preparedStatements: document.querySelector('#prepared-statements').checked,
        reconnect: document.querySelector('#reconnect-each-iteration').checked,
        connectionPooling: document.querySelector('#connection-pooling').checked
      }
    }
  };
}

function profileString(value, name, maximumLength, nullable = false) {
  if (nullable && value === null) return null;
  if (typeof value !== 'string' || value.length > maximumLength) {
    throw new Error(`${name} is invalid.`);
  }
  return value;
}

function profileInteger(value, name, minimum, maximum) {
  if (!Number.isInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${name} is invalid.`);
  }
  return value;
}

function profileChoice(value, name, choices) {
  if (!choices.includes(value)) throw new Error(`${name} is invalid.`);
  return value;
}

// Options added after schema version 1, so absent values fall back rather than failing the load.
function profileOptionalInteger(value, name, minimum, maximum, fallback = null) {
  if (value === null || value === undefined) return fallback;
  return profileInteger(value, name, minimum, maximum);
}

function profileOptionalString(value, name, maximumLength, fallback = null) {
  if (value === null || value === undefined) return fallback;
  return profileString(value, name, maximumLength);
}

function validateConfigurationProfile(profile) {
  if (!profile || typeof profile !== 'object' || Array.isArray(profile) ||
      profile.schema !== configurationSchema || profile.version !== configurationVersion) {
    throw new Error('This is not a supported sqlsim Studio configuration.');
  }
  const configuration = profile.configuration;
  if (!configuration || typeof configuration !== 'object' || Array.isArray(configuration)) {
    throw new Error('The configuration is missing.');
  }
  const engine = profileChoice(configuration.engine, 'Execution engine', ['sqlsim', 'sqlpysim']);
  const mode = profileChoice(configuration.mode, 'Workload mode', ['query', 'file', 'workload', 'replay']);
  if (engine === 'sqlpysim' && ['workload', 'replay'].includes(mode)) {
    throw new Error('sqlpysim does not support this workload mode.');
  }
  const connection = configuration.connection;
  const source = configuration.source;
  const execution = configuration.execution;
  if (!connection || !source || !execution) throw new Error('The configuration is incomplete.');
  if (engine === 'sqlpysim' && (execution.telemetry === 'live' || execution.statisticsSource === 'runtime')) {
    throw new Error('sqlpysim does not support this telemetry or statistics configuration.');
  }
  if (execution.telemetry !== 'console' && execution.quiet !== true) {
    throw new Error('Structured telemetry configurations must suppress result rows.');
  }

  const validated = {
    engine,
    mode,
    connection: {
      server: profileString(connection.server, 'Server', 2048),
      database: profileString(connection.database, 'Database', 256),
      authentication: profileChoice(connection.authentication, 'Authentication', ['integrated', 'token', 'interactive', 'managed', 'service-principal', 'sql']),
      username: profileString(connection.username, 'Username', 1024, true),
      trustServerCertificate: connection.trustServerCertificate === true,
      loginTimeoutSeconds: profileOptionalInteger(connection.loginTimeoutSeconds, 'Login timeout', 0, 86400),
      applicationName: profileOptionalString(connection.applicationName, 'Application name', 128),
      retryCount: profileOptionalInteger(connection.retryCount, 'Retry count', 0, 255),
      encryption: connection.encryption === undefined || connection.encryption === null
        ? 'default'
        : profileChoice(connection.encryption, 'Encryption', ['default', 'optional', 'mandatory', 'strict']),
      certificateHostname: profileOptionalString(connection.certificateHostname, 'Certificate hostname', 253),
      readOnlyIntent: connection.readOnlyIntent === true,
      multiSubnetFailover: connection.multiSubnetFailover === true
    },
    execution: {
      telemetry: profileChoice(execution.telemetry, 'Telemetry', ['live', 'final', 'console']),
      quiet: execution.quiet === true,
      stopOnError: execution.stopOnError === true,
      statisticsSource: profileChoice(execution.statisticsSource, 'Statistics source', ['none', 'runtime', 'query-store']),
      queryTimeoutSeconds: profileOptionalInteger(execution.queryTimeoutSeconds, 'Query timeout', 0, 86400),
      preparedStatements: execution.preparedStatements === true,
      reconnect: execution.reconnect === true,
      connectionPooling: execution.connectionPooling === true
    }
  };

  if (mode === 'query') {
    validated.source = {
      query: profileString(source.query, 'Query', 1_000_000),
      threads: profileInteger(source.threads, 'Connections', 1, 1_000_000),
      iterations: profileInteger(source.iterations, 'Iterations', 1, 1_000_000_000)
    };
  } else if (mode === 'file') {
    validated.source = {
      fileName: profileString(source.fileName, 'SQL file name', 260, true),
      content: profileString(source.content, 'SQL file content', 1_000_000, true),
      threads: profileInteger(source.threads, 'Connections', 1, 1_000_000),
      iterations: profileInteger(source.iterations, 'Iterations', 1, 1_000_000_000)
    };
    if ((validated.source.fileName === null) !== (validated.source.content === null)) {
      throw new Error('The SQL file name and content must be saved together.');
    }
  } else if (mode === 'workload') {
    if (!Array.isArray(source.groups) || source.groups.length > 20) throw new Error('Workload groups are invalid.');
    validated.source = {
      groups: source.groups.map((group, index) => ({
        fileName: profileString(group.fileName, `Group ${index + 1} file name`, 260),
        content: profileString(group.content, `Group ${index + 1} content`, 1_000_000),
        threads: profileInteger(group.threads, `Group ${index + 1} connections`, 1, 1_000_000),
        iterations: profileInteger(group.iterations, `Group ${index + 1} iterations`, 1, 1_000_000_000),
        thinkTimeMs: profileInteger(group.thinkTimeMs, `Group ${index + 1} think time`, 0, 86_400_000)
      }))
    };
  } else {
    validated.source = {
      fileName: profileString(source.fileName, 'Replay file name', 260, true),
      content: profileString(source.content, 'Replay file content', 100_000_000, true),
      replayMode: profileChoice(source.replayMode, 'Replay mode', ['fast', 'stress']),
      iterations: profileInteger(source.iterations, 'Replay passes', 1, 1_000_000_000),
      threads: profileInteger(source.threads, 'Stress connections', 1, 1_000_000)
    };
    if ((validated.source.fileName === null) !== (validated.source.content === null)) {
      throw new Error('The replay file name and content must be saved together.');
    }
  }
  return validated;
}

function applyConfigurationProfile(configuration) {
  const engine = document.querySelector('#execution-engine');
  engine.value = configuration.engine;
  engine.dispatchEvent(new Event('change'));

  document.querySelector('#server').value = configuration.connection.server;
  document.querySelector('#database').value = configuration.connection.database;
  authentication.value = configuration.connection.authentication;
  authentication.dispatchEvent(new Event('change'));
  document.querySelector('#auth-username').value = configuration.connection.username || '';
  document.querySelector('#auth-secret').value = '';
  document.querySelector('#trust-server-certificate').checked = configuration.connection.trustServerCertificate;
  document.querySelector('#login-timeout').value = configuration.connection.loginTimeoutSeconds ?? '';
  const applicationNameField = document.querySelector('#application-name');
  const profileApplicationName = configuration.connection.applicationName ?? '';
  if (applicationNameField.disabled) {
    // The engine handler above blanked the field for sqlpysim. Park the
    // profile's name so switching back to sqlsim restores it, rather than
    // writing it into a greyed-out box where it would read as though it applies.
    applicationNameField.dataset.previousValue = profileApplicationName;
  } else {
    applicationNameField.value = profileApplicationName;
  }
  document.querySelector('#retry-count').value = configuration.connection.retryCount ?? '';
  document.querySelector('#encryption').value = configuration.connection.encryption ?? 'default';
  document.querySelector('#certificate-hostname').value = configuration.connection.certificateHostname ?? '';
  document.querySelector('#read-only-intent').checked = configuration.connection.readOnlyIntent === true;
  document.querySelector('#multi-subnet-failover').checked = configuration.connection.multiSubnetFailover === true;
  document.querySelector(`[data-mode="${configuration.mode}"]`).click();

  selectedSqlFile = null;
  selectedReplayFile = null;
  workloadGroups = [];
  document.querySelector('#sql-file-title').textContent = 'Choose a SQL script';
  document.querySelector('#sql-file-detail').textContent = 'or drop a .sql file here · maximum 1 MB';
  document.querySelector('#file-mode .simple-total').dataset.batches = '1';
  document.querySelector('#sql-file-preview').classList.add('hidden');
  document.querySelector('#sql-file-preview-content').textContent = '';
  document.querySelector('#replay-file-title').textContent = 'Choose a replay XML file';
  document.querySelector('#replay-file-detail').textContent = 'Converted sqlsim XEvent replay XML · maximum 100 MB';
  document.querySelector('#replay-preflight').classList.add('hidden');
  const source = configuration.source;
  if (configuration.mode === 'query') {
    document.querySelector('#query-text').value = source.query;
    document.querySelector('#query-mode .simple-threads').value = source.threads;
    document.querySelector('#query-mode .simple-iterations').value = source.iterations;
    document.querySelector('#query-mode .simple-threads').dispatchEvent(new Event('input'));
  } else if (configuration.mode === 'file') {
    document.querySelector('#file-mode .simple-threads').value = source.threads;
    document.querySelector('#file-mode .simple-iterations').value = source.iterations;
    if (source.fileName !== null && source.content !== null) {
      selectedSqlFile = { name: source.fileName, content: source.content };
      document.querySelector('#sql-file-title').textContent = source.fileName;
      const batches = Math.max(1, source.content.split(/^\s*GO\s*(?:--.*)?$/gmi).filter(value => value.trim()).length);
      document.querySelector('#sql-file-detail').textContent = `${batches} batch${batches === 1 ? '' : 'es'} · loaded from configuration`;
      document.querySelector('#file-mode .simple-total').dataset.batches = String(batches);
      renderSqlFilePreview(source.content);
    }
    document.querySelector('#file-mode .simple-threads').dispatchEvent(new Event('input'));
  } else if (configuration.mode === 'workload') {
    workloadGroups = source.groups.map(group => ({
      ...group,
      batchCount: Math.max(1, group.content.split(/^\s*GO\s*(?:--.*)?$/gmi).filter(value => value.trim()).length)
    }));
    renderWorkloadGroups();
  } else {
    if (source.fileName !== null && source.content !== null) {
      setReplayFile(
        source.fileName,
        source.content,
        new Blob([source.content]).size,
        'loaded from configuration · preflight passed');
    }
    document.querySelector('#replay-mode-select').value = source.replayMode;
    document.querySelector('#replay-iterations').value = source.iterations;
    document.querySelector('#replay-threads').value = source.threads;
    document.querySelector('#replay-mode-select').dispatchEvent(new Event('change'));
  }

  telemetryMode.value = configuration.execution.telemetry;
  telemetryMode.dispatchEvent(new Event('change'));
  document.querySelector('#quiet-mode-toggle').checked = configuration.execution.quiet;
  document.querySelector('#stop-on-error').checked = configuration.execution.stopOnError;
  document.querySelector('#query-timeout').value = configuration.execution.queryTimeoutSeconds ?? '';
  document.querySelector('#prepared-statements').checked = configuration.execution.preparedStatements === true;
  document.querySelector('#reconnect-each-iteration').checked = configuration.execution.reconnect === true;
  syncPoolingAvailability();
  document.querySelector('#connection-pooling').checked =
    configuration.execution.connectionPooling === true && !document.querySelector('#connection-pooling').disabled;
  statisticsSource.value = configuration.execution.statisticsSource;
  statisticsSource.dispatchEvent(new Event('change'));
  updateCommandPreview();
  updateRunSummary();
}

function configurationFileName() {
  const database = document.querySelector('#database').value.trim().replace(/[^a-z0-9._-]+/gi, '-').replace(/^-+|-+$/g, '');
  return `sqlsimstudio-${database || 'configuration'}.json`;
}

document.querySelector('#save-profile').addEventListener('click', () => {
  const json = JSON.stringify(createConfigurationProfile(), null, 2);
  downloadBlob(new Blob([json], { type: 'application/json' }), configurationFileName());
  showToast('Configuration saved. Secrets were not included.');
});

function downloadBlob(blob, fileName) {
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = fileName;
  link.click();
  window.setTimeout(() => URL.revokeObjectURL(url), 0);
}

const configurationFileInput = document.querySelector('#configuration-file-input');
document.querySelector('#load-profile').addEventListener('click', () => configurationFileInput.click());
configurationFileInput.addEventListener('change', async () => {
  const file = configurationFileInput.files[0];
  configurationFileInput.value = '';
  if (!file) return;
  try {
    if (file.size > 125_000_000) throw new Error('Configuration files cannot exceed 125 MB.');
    const profile = JSON.parse(await file.text());
    applyConfigurationProfile(validateConfigurationProfile(profile));
    showToast('Configuration loaded. Enter any required secret before running.');
  } catch (error) {
    showError(error instanceof SyntaxError ? 'The configuration file is not valid JSON.' : error.message);
  }
});

document.querySelector('.reveal').addEventListener('click', event => {
  const input = event.currentTarget.previousElementSibling;
  const revealing = input.type === 'password';
  input.type = revealing ? 'text' : 'password';
  event.currentTarget.textContent = revealing ? 'Hide' : 'Show';
});

function setLogOpen(open) {
  document.querySelector('#log-drawer').classList.toggle('hidden', !open);
  document.querySelector('#drawer-backdrop').classList.toggle('hidden', !open);
  document.body.style.overflow = open ? 'hidden' : '';
  if (open) refreshIcons();
}

document.querySelectorAll('[data-open-log]').forEach(button => {
  button.addEventListener('click', () => setLogOpen(true));
});
document.querySelector('#close-log').addEventListener('click', () => setLogOpen(false));
document.querySelector('#drawer-backdrop').addEventListener('click', () => setLogOpen(false));
document.addEventListener('keydown', event => {
  if (event.key === 'Escape') setLogOpen(false);
});

document.querySelectorAll('[data-log-filter]').forEach(button => {
  button.addEventListener('click', () => {
    const filter = button.dataset.logFilter;
    document.querySelectorAll('[data-log-filter]').forEach(item => item.classList.toggle('active', item === button));
    let visible = 0;
    document.querySelectorAll('.log-entry').forEach(entry => {
      const show = filter === 'all' || entry.dataset.level === filter;
      entry.classList.toggle('hidden', !show);
      if (show) visible += 1;
    });
    let empty = document.querySelector('.log-empty');
    if (!empty) {
      empty = document.createElement('div');
      empty.className = 'log-empty hidden';
      empty.textContent = 'No log entries match this filter.';
      document.querySelector('#log-entries').appendChild(empty);
    }
    empty.classList.toggle('hidden', visible !== 0);
  });
});

document.querySelector('#compare-result').addEventListener('click', () => {
  switchView('compare');
  loadRunHistory().catch(error => showError(error.message));
});
document.querySelector('#show-differences').addEventListener('click', () => {
  const differences = document.querySelector('#config-differences');
  differences.classList.toggle('hidden');
  document.querySelector('#show-differences').innerHTML = differences.classList.contains('hidden')
    ? '<i data-lucide="list-tree"></i>View configuration'
    : '<i data-lucide="list-collapse"></i>Hide configuration';
  refreshIcons();
});

document.querySelector('#swap-runs').addEventListener('click', () => {
  const baseline = document.querySelector('#baseline-run');
  const candidate = document.querySelector('#candidate-run');
  const baselineId = baseline.value;
  baseline.value = candidate.value;
  candidate.value = baselineId;
  renderComparison();
});

document.querySelector('#baseline-run').addEventListener('change', renderComparison);
document.querySelector('#candidate-run').addEventListener('change', renderComparison);

const COMPARISON_NOISE_PERCENT = 2;

function comparisonExecutionCount(result) {
  const configuration = result?.configuration || {};
  if (configuration.replay_mode) return result?.replay_summary?.result?.events || 0;
  return configuration.total_batches || 0;
}

// These definitions match sqlsim/examples/reports/comparison-report.ps1.
function comparisonMetrics(run) {
  const result = run.result || {};
  const metrics = result.metrics || {};
  const executions = comparisonExecutionCount(result);
  const runtime = Number(metrics.total_runtime_seconds) || 0;
  const elapsed = Number(result.execution_elapsed_seconds) || runtime;
  const queryTime = Number(metrics.total_query_execution_time_seconds);
  const verboseExecution = Number(metrics.query_execution_operations?.avg_elapsed_ms) || 0;
  return {
    throughput: elapsed > 0 ? executions / elapsed : 0,
    runtime,
    execution: executions > 0 && Number.isFinite(queryTime) ? queryTime * 1000 / executions : verboseExecution,
    connection: Number(metrics.connection_operations?.avg_connect_time_ms) || Number(result.connection_stats?.avg_ms) || 0,
    errors: Number(metrics.errors?.total) || 0
  };
}

function percentChange(baseline, candidate) {
  if (baseline === 0) return candidate === 0 ? 0 : null;
  return (candidate - baseline) / Math.abs(baseline) * 100;
}

function formatChange(change) {
  if (change === null) return 'n/a';
  if (Math.abs(change) < 0.05) return 'No change';
  return `${change > 0 ? '+' : ''}${change.toFixed(1)}%`;
}

function metricOutcome(baseline, candidate, higherIsBetter) {
  const change = percentChange(baseline, candidate);
  if (change !== null && Math.abs(change) < COMPARISON_NOISE_PERCENT) return 'neutral';
  return (candidate > baseline) === higherIsBetter ? 'positive' : 'negative';
}

function renderDeltaCard(id, baseline, candidate, formatter, higherIsBetter, counted = true) {
  const card = document.querySelector(`#${id}`);
  const change = percentChange(baseline, candidate);
  const outcome = metricOutcome(baseline, candidate, higherIsBetter);
  card.classList.remove('positive', 'negative', 'neutral');
  card.classList.add(counted ? outcome : 'neutral');
  card.querySelector('div strong').textContent = formatChange(change);
  card.querySelector('div small').textContent = counted
    ? (higherIsBetter ? 'higher is better' : 'lower is better')
    : 'not in verdict';
  card.title = counted ? '' : 'Connection time counts toward the verdict only when both runs use -reconnect.';
  const values = card.querySelectorAll('p b');
  values[0].textContent = formatter(baseline);
  values[1].textContent = formatter(candidate);
  return counted ? outcome : null;
}

// Without -reconnect, connection time is one-time setup cost and only adds noise.
function connectionCountsInVerdict(run) {
  return run.result?.configuration?.reconnect_per_iteration === true;
}

function renderComparisonBar(name, baseline, candidate) {
  const row = document.querySelector(`[data-comparison-metric="${name}"]`);
  const maximum = Math.max(baseline, candidate);
  row.querySelector('.bar-a').style.width = `${maximum > 0 ? baseline / maximum * 100 : 0}%`;
  row.querySelector('.bar-b').style.width = `${maximum > 0 ? candidate / maximum * 100 : 0}%`;
  row.querySelector('strong').textContent = formatChange(percentChange(baseline, candidate));
}

function comparisonStatisticsLabel(source) {
  return { none: 'Not collected', runtime: 'Per-query (-querystats)', 'query-store': 'Query Store' }[source]
    || source || 'Not recorded';
}

function normalizedQueryText(text) {
  return String(text || '').replace(/\s+/g, ' ').trim();
}

// Matching is by normalized SQL text, the same rule comparison-report.ps1 uses.
function queryComparisonRows(baselineResult, candidateResult) {
  const index = queries => {
    const map = new Map();
    (Array.isArray(queries) ? queries : []).forEach(query => {
      const key = normalizedQueryText(query.query);
      if (key && !map.has(key)) map.set(key, query);
    });
    return map;
  };
  const baseline = index(baselineResult?.query_stats?.queries);
  const candidate = index(candidateResult?.query_stats?.queries);
  const weight = query => (Number(query?.total_elapsed_ms?.avg) || 0) * (Number(query?.executions) || 0);
  return [...new Set([...baseline.keys(), ...candidate.keys()])]
    .map(key => ({ key, a: baseline.get(key), b: candidate.get(key) }))
    .sort((x, y) => Math.max(weight(y.a), weight(y.b)) - Math.max(weight(x.a), weight(x.b)));
}

function queryDeltaCell(a, b, formatter, higherIsBetter = false, measured = true) {
  const cell = document.createElement('span');
  cell.className = 'query-delta';
  const values = document.createElement('b');
  const change = document.createElement('small');
  if (a === null || b === null) {
    values.textContent = `${a === null ? '—' : formatter(a)} → ${b === null ? '—' : formatter(b)}`;
    change.textContent = a === null ? 'Only in B' : 'Only in A';
    change.className = 'unmatched';
  } else {
    values.textContent = `${formatter(a)} → ${formatter(b)}`;
    change.textContent = formatChange(percentChange(a, b));
    change.className = measured ? metricOutcome(a, b, higherIsBetter) : 'neutral';
  }
  cell.append(values, change);
  return cell;
}

function renderQueryComparison(baseline, candidate) {
  const table = document.querySelector('#query-comparison-table');
  const empty = document.querySelector('#query-comparison-empty');
  table.querySelectorAll('.query-comparison-row').forEach(row => row.remove());
  const hasStatistics = run => Array.isArray(run.result?.query_stats?.queries) && run.result.query_stats.queries.length > 0;
  if (!hasStatistics(baseline) || !hasStatistics(candidate)) {
    empty.classList.remove('hidden');
    table.classList.add('hidden');
    return;
  }
  empty.classList.add('hidden');
  table.classList.remove('hidden');
  const value = (query, read) => query ? Number(read(query)) || 0 : null;
  const milliseconds = number => `${number.toFixed(3)} ms`;
  queryComparisonRows(baseline.result, candidate.result).forEach((pair, index) => {
    const row = document.createElement('div');
    row.className = 'query-comparison-row';
    const label = document.createElement('div');
    const name = document.createElement('strong');
    name.textContent = `Query ${index + 1}`;
    const text = document.createElement('span');
    text.textContent = pair.key;
    text.title = pair.key;
    label.append(name, text);
    row.append(
      label,
      queryDeltaCell(value(pair.a, q => q.executions), value(pair.b, q => q.executions), number => number.toLocaleString(), true, false),
      queryDeltaCell(value(pair.a, q => q.total_elapsed_ms?.avg), value(pair.b, q => q.total_elapsed_ms?.avg), milliseconds),
      queryDeltaCell(value(pair.a, q => q.server_cpu_ms?.avg), value(pair.b, q => q.server_cpu_ms?.avg), milliseconds),
      queryDeltaCell(value(pair.a, q => q.logical_reads?.avg), value(pair.b, q => q.logical_reads?.avg), number => number.toFixed(1)),
      queryDeltaCell(value(pair.a, q => q.failures), value(pair.b, q => q.failures), number => number.toLocaleString())
    );
    table.appendChild(row);
  });
}

const MAX_IMPORTED_RUNS = 20;
const comparisonProfiles = new WeakMap();
let importedRuns = [];
let importSequence = 0;

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function comparisonRuns() {
  return [...importedRuns, ...runHistory];
}

function findComparisonRun(id) {
  return comparisonRuns().find(run => run.id === id);
}

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (isPlainObject(value)) {
    return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${stableJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value ?? null);
}

// Display-only fingerprint; comparisons use the full canonical identity.
function fingerprint(text) {
  let hash = 0xcbf29ce484222325n;
  for (const byte of new TextEncoder().encode(text)) {
    hash ^= BigInt(byte);
    hash = (hash * 0x100000001b3n) & 0xffffffffffffffffn;
  }
  return hash.toString(16).padStart(16, '0');
}

function resultMode(configuration) {
  if (configuration.replay_mode) return 'replay';
  if (configuration.workload_file || Array.isArray(configuration.workloads)) return 'workload';
  if (configuration.input_file) return 'file';
  return 'query';
}

function resultEngine(configuration) {
  return configuration.odbc_driver === 'mssql-python' ? 'sqlpysim' : 'sqlsim';
}

function resultWorkloadIdentity(result) {
  const configuration = result.configuration;
  if (configuration.replay_mode) {
    return {
      replayMode: configuration.replay_mode,
      totalEvents: configuration.replay_total_events,
      replayableEvents: configuration.replay_replayable_events,
      skippedEvents: configuration.replay_skipped_events,
      sessions: configuration.replay_sessions,
      capture: Array.isArray(result.replay_capture?.queries)
        ? result.replay_capture.queries.map(query => ({
          eventType: query.event_type,
          query: query.query,
          executions: query.executions,
          sessions: query.sessions,
          capturedSpids: query.captured_spids,
          databases: query.databases
        }))
        : null
    };
  }
  if (Array.isArray(configuration.workloads)) {
    return configuration.workloads.map(group => ({
      threads: group.threads,
      iterations: group.iterations,
      durationSeconds: group.duration_seconds,
      thinkTimeMs: group.think_time_ms || 0,
      batches: group.batches
    }));
  }
  return { batches: configuration.batches };
}

function resultExecutionOptions(configuration) {
  const option = (name, fallback = null) => configuration[name] ?? fallback;
  return {
    authentication: option('authentication'),
    applicationName: option('application_name'),
    preparedStatements: option('prepared_statements', false),
    reconnectPerIteration: option('reconnect_per_iteration', false),
    connectionPooling: option('connection_pooling', false),
    rampBatchSize: option('ramp_batch_size', 0),
    rampDelayMs: option('ramp_delay_ms', 0),
    stopOnError: option('stop_on_error', false),
    loginTimeout: option('login_timeout', 0),
    queryTimeout: option('query_timeout', 0),
    retryCount: option('retry_count', 1),
    retryDelay: option('retry_delay', 10),
    encryption: option('encryption'),
    trustServerCertificate: option('trust_server_certificate', false),
    certificateHostname: option('certificate_hostname'),
    readOnlyIntent: option('read_only_intent', false),
    multiSubnetFailover: option('multi_subnet_failover', false),
    quiet: option('quiet_mode', false)
  };
}

function comparisonTelemetry(run) {
  if (run.telemetry === 'live' || run.telemetry === 'final') return run.telemetry;
  return run.result?.configuration?.stream_json === true ? 'live' : 'final';
}

function comparisonTelemetryLabel(telemetry) {
  return telemetry === 'live' ? 'Live progress' : 'Final results only';
}

// Imported files carry no Studio request, so mixed comparisons use the identity
// recorded in each canonical result instead of Studio's live-run key.
function resultComparisonProfile(run) {
  if (comparisonProfiles.has(run)) return comparisonProfiles.get(run);
  const configuration = run.result.configuration;
  const workload = stableJson(resultWorkloadIdentity(run.result));
  const iterations = configuration.iterations_per_thread ?? (Array.isArray(configuration.workloads) ? 'per group' : '-');
  const profile = {
    engineMode: stableJson([resultEngine(configuration), resultMode(configuration)]),
    target: stableJson([String(configuration.server || '').toLowerCase(), String(configuration.database || '').toLowerCase()]),
    workload,
    workloadHash: fingerprint(workload),
    loadShape: stableJson([configuration.threads, configuration.iterations_per_thread ?? null, comparisonExecutionCount(run.result)]),
    loadLabel: `${configuration.threads} / ${iterations}`,
    statisticsSource: run.statisticsSource,
    telemetry: comparisonTelemetry(run),
    executionOptions: stableJson(resultExecutionOptions(configuration))
  };
  comparisonProfiles.set(run, profile);
  return profile;
}

function resultProfileDifferences(baseline, candidate) {
  const differences = [];
  if (baseline.engineMode !== candidate.engineMode) differences.push('engine or mode');
  if (baseline.target !== candidate.target) differences.push('target');
  if (baseline.workload !== candidate.workload) differences.push('workload');
  if (baseline.loadShape !== candidate.loadShape) differences.push('load shape');
  if (baseline.statisticsSource !== candidate.statisticsSource) differences.push('statistics source');
  if (baseline.telemetry !== candidate.telemetry) differences.push('telemetry');
  if (baseline.executionOptions !== candidate.executionOptions) differences.push('execution options');
  return differences;
}

function usesImportedResult(baseline, candidate) {
  return baseline.source === 'imported' || candidate.source === 'imported';
}

function comparisonDifferences(baseline, candidate) {
  if (baseline.id === candidate.id) return ['same run selected twice'];
  if (usesImportedResult(baseline, candidate)) {
    return resultProfileDifferences(resultComparisonProfile(baseline), resultComparisonProfile(candidate));
  }
  const differences = [];
  if (baseline.engine !== candidate.engine || baseline.mode !== candidate.mode) differences.push('engine or mode');
  if (baseline.server.toLowerCase() !== candidate.server.toLowerCase() ||
      baseline.database.toLowerCase() !== candidate.database.toLowerCase()) differences.push('target');
  if (baseline.workloadHash !== candidate.workloadHash) differences.push('workload');
  if (baseline.threads !== candidate.threads || baseline.iterations !== candidate.iterations) differences.push('load shape');
  if (baseline.statisticsSource !== candidate.statisticsSource) differences.push('statistics source');
  if (comparisonTelemetry(baseline) !== comparisonTelemetry(candidate)) differences.push('telemetry');
  if (differences.length === 0 && baseline.comparisonKey !== candidate.comparisonKey) differences.push('execution options');
  return differences;
}

function comparisonRunLabel(run) {
  if (run.source === 'imported') return `Imported · ${run.fileName}`;
  return `${run.mode} · ${run.database} · ${new Date(run.completedAt).toLocaleString()}`;
}

function renderRunPicker(prefix, run) {
  if (!run) {
    document.querySelector(`#${prefix}-summary`).textContent = `No ${prefix} selected`;
    document.querySelector(`#${prefix}-throughput`).textContent = '0 exec/sec';
    return;
  }
  const metrics = comparisonMetrics(run);
  document.querySelector(`#${prefix}-summary`).textContent = `${run.database} on ${run.server} · ${run.threads} connection${run.threads === 1 ? '' : 's'}`;
  document.querySelector(`#${prefix}-throughput`).textContent = `${Math.round(metrics.throughput).toLocaleString()} exec/sec`;
}

function renderComparison() {
  const baseline = findComparisonRun(document.querySelector('#baseline-run').value);
  const candidate = findComparisonRun(document.querySelector('#candidate-run').value);
  const status = document.querySelector('#comparison-status');
  const empty = document.querySelector('#comparison-empty');
  const analysis = document.querySelector('#comparison-analysis');
  const detailsButton = document.querySelector('#show-differences');
  renderRunPicker('baseline', baseline);
  renderRunPicker('candidate', candidate);

  if (!baseline || !candidate) {
    status.classList.add('invalid');
    document.querySelector('#comparison-status-icon').innerHTML = '<i data-lucide="circle-alert"></i>';
    document.querySelector('#comparison-status-title').textContent = 'Two final-result runs required';
    document.querySelector('#comparison-status-detail').textContent = 'Run Final results only workloads or import saved -json result files.';
    empty.textContent = 'Run the same workload twice using Final results only, or import two saved result files, to create a valid A/B comparison.';
    empty.classList.remove('hidden');
    analysis.classList.add('hidden');
    detailsButton.classList.add('hidden');
    refreshIcons();
    return;
  }

  const differences = comparisonDifferences(baseline, candidate);
  if (differences.length) {
    status.classList.add('invalid');
    document.querySelector('#comparison-status-icon').innerHTML = '<i data-lucide="circle-alert"></i>';
    document.querySelector('#comparison-status-title').textContent = 'Runs are not comparable';
    document.querySelector('#comparison-status-detail').textContent = `Choose runs with matching ${differences.join(', ')}.`;
    empty.textContent = 'No deltas are calculated for incompatible runs.';
    empty.classList.remove('hidden');
    analysis.classList.add('hidden');
    detailsButton.classList.add('hidden');
    refreshIcons();
    return;
  }

  status.classList.remove('invalid');
  document.querySelector('#comparison-status-icon').innerHTML = '<i data-lucide="circle-check"></i>';
  document.querySelector('#comparison-status-title').textContent = 'Runs are comparable';
  document.querySelector('#comparison-status-detail').textContent = 'Target, workload, load shape, statistics, telemetry, and execution options match.';
  empty.classList.add('hidden');
  analysis.classList.remove('hidden');
  detailsButton.classList.remove('hidden');

  const baselineMetrics = comparisonMetrics(baseline);
  const candidateMetrics = comparisonMetrics(candidate);
  const outcomes = [
    renderDeltaCard('delta-throughput', baselineMetrics.throughput, candidateMetrics.throughput, value => `${Math.round(value).toLocaleString()} exec/sec`, true),
    renderDeltaCard('delta-runtime', baselineMetrics.runtime, candidateMetrics.runtime, value => `${value.toFixed(3)} s`, false),
    renderDeltaCard('delta-execution', baselineMetrics.execution, candidateMetrics.execution, value => `${value.toFixed(3)} ms`, false),
    renderDeltaCard('delta-connection', baselineMetrics.connection, candidateMetrics.connection, value => `${value.toFixed(2)} ms`, false,
      connectionCountsInVerdict(baseline) && connectionCountsInVerdict(candidate)),
    renderDeltaCard('delta-errors', baselineMetrics.errors, candidateMetrics.errors, value => value.toLocaleString(), false)
  ].filter(Boolean);
  Object.entries(baselineMetrics).forEach(([name, value]) => renderComparisonBar(name, value, candidateMetrics[name]));

  const improved = outcomes.filter(value => value === 'positive').length;
  const unchanged = outcomes.filter(value => value === 'neutral').length;
  const regressed = outcomes.filter(value => value === 'negative').length;
  document.querySelector('#comparison-improved').textContent = `${improved} improved`;
  document.querySelector('#comparison-unchanged').textContent = `${unchanged} unchanged`;
  document.querySelector('#comparison-regressed').textContent = `${regressed} regressed`;
  document.querySelector('#comparison-verdict-title').textContent = regressed === 0 && improved > 0
    ? 'Candidate improved measured performance'
    : improved === 0 && regressed > 0
      ? 'Candidate regressed measured performance'
      : improved === 0 ? 'No measured change' : 'Candidate has mixed results';
  document.querySelector('#comparison-verdict-detail').textContent = `${improved} metric(s) improved, ${unchanged} unchanged, and ${regressed} regressed.`;

  const mixed = usesImportedResult(baseline, candidate);
  const baselineProfile = mixed ? resultComparisonProfile(baseline) : null;
  const candidateProfile = mixed ? resultComparisonProfile(candidate) : null;
  document.querySelector('#config-workload-a').textContent = (mixed ? baselineProfile.workloadHash : baseline.workloadHash).slice(0, 12);
  document.querySelector('#config-workload-b').textContent = (mixed ? candidateProfile.workloadHash : candidate.workloadHash).slice(0, 12);
  document.querySelector('#config-target-a').textContent = `${baseline.server}/${baseline.database}`;
  document.querySelector('#config-target-b').textContent = `${candidate.server}/${candidate.database}`;
  document.querySelector('#config-load-a').textContent = mixed ? baselineProfile.loadLabel : `${baseline.threads} / ${baseline.iterations}`;
  document.querySelector('#config-load-b').textContent = mixed ? candidateProfile.loadLabel : `${candidate.threads} / ${candidate.iterations}`;
  document.querySelector('#config-statistics-a').textContent = comparisonStatisticsLabel(baseline.statisticsSource);
  document.querySelector('#config-statistics-b').textContent = comparisonStatisticsLabel(candidate.statisticsSource);
  document.querySelector('#config-telemetry-a').textContent = comparisonTelemetryLabel(comparisonTelemetry(baseline));
  document.querySelector('#config-telemetry-b').textContent = comparisonTelemetryLabel(comparisonTelemetry(candidate));
  renderQueryComparison(baseline, candidate);
  const informational = [
    ['engine', run => `${run.engine || resultEngine(run.result?.configuration || {})} ${run.result?.version || ''}`.trim()],
    ['driver', run => run.result?.metrics?.odbc_driver_version || run.result?.configuration?.odbc_driver],
    ['version', run => run.result?.server_version],
    ['edition', run => run.result?.server_edition]
  ];
  let informationalDifferences = 0;
  informational.forEach(([name, value]) => {
    const a = String(value(baseline) || 'Not recorded');
    const b = String(value(candidate) || 'Not recorded');
    const differs = a !== b;
    if (differs) informationalDifferences++;
    document.querySelector(`#config-${name}-a`).textContent = a;
    document.querySelector(`#config-${name}-b`).textContent = b;
    const state = document.querySelector(`#config-${name}-status`);
    state.textContent = differs ? 'Differs' : 'Match';
    state.className = differs ? 'informational' : 'ok';
  });
  if (informationalDifferences > 0) {
    document.querySelector('#comparison-status-detail').textContent =
      'Target, workload, load shape, statistics, telemetry, and execution options match. Engine, ODBC driver, or SQL Server details differ; that may be the change under test.';
  }
  refreshIcons();
}

function comparisonOption(run) {
  const option = document.createElement('option');
  option.value = run.id;
  option.textContent = comparisonRunLabel(run);
  return option;
}

function comparisonOptionGroup(label, runs) {
  const group = document.createElement('optgroup');
  group.label = label;
  group.append(...runs.map(comparisonOption));
  return group;
}

function populateRunPickers(preferred = {}) {
  const baselineSelect = document.querySelector('#baseline-run');
  const candidateSelect = document.querySelector('#candidate-run');
  const runs = comparisonRuns();
  const ids = runs.map(run => run.id);
  const exists = id => ids.includes(id);
  const requestedBaseline = preferred.baseline ?? baselineSelect.value;
  const requestedCandidate = preferred.candidate ?? candidateSelect.value;
  let baselineId = exists(requestedBaseline) ? requestedBaseline : '';
  let candidateId = exists(requestedCandidate) && requestedCandidate !== baselineId ? requestedCandidate : '';
  if (ids.length >= 2) {
    if (!baselineId && !candidateId) {
      baselineId = ids[1];
      candidateId = ids[0];
    } else if (!baselineId) {
      baselineId = ids.find(id => id !== candidateId);
    } else if (!candidateId) {
      candidateId = ids.find(id => id !== baselineId);
    }
  }

  for (const select of [baselineSelect, candidateSelect]) {
    const children = importedRuns.length && runHistory.length
      ? [comparisonOptionGroup('Imported files', importedRuns), comparisonOptionGroup('This session', runHistory)]
      : runs.map(comparisonOption);
    if (ids.length < 2) {
      const placeholder = document.createElement('option');
      placeholder.value = '';
      placeholder.textContent = runs.length ? 'Choose another result' : 'Run or import two final results';
      children.unshift(placeholder);
    }
    select.replaceChildren(...children);
    select.disabled = runs.length === 0;
  }
  baselineSelect.value = baselineId;
  candidateSelect.value = candidateId;
  renderComparison();
}

async function loadRunHistory() {
  const response = await fetch('/api/runs/history', { credentials: 'same-origin', cache: 'no-store' });
  if (!response.ok) throw new Error('Studio could not load run history.');
  runHistory = await response.json();
  populateRunPickers();
}

function validateComparableResult(result, label) {
  if (!isPlainObject(result) || !isPlainObject(result.configuration) || !isPlainObject(result.metrics)) {
    throw new Error(`${label} is not a sqlsim or sqlpysim final result. Import a file written with -json -o.`);
  }
  const { configuration, metrics } = result;
  if (result.success !== true) {
    throw new Error(`${label} records a failed run. Only successful final results can be compared.`);
  }
  if (typeof configuration.server !== 'string' || !Number.isInteger(configuration.threads) || configuration.threads < 1) {
    throw new Error(`${label} does not record its target and connection count.`);
  }
  if (configuration.connection_test_only && !configuration.replay_mode) {
    throw new Error(`${label} is a connection test and has no workload to compare.`);
  }
  if (!(comparisonExecutionCount(result) > 0)) {
    throw new Error(`${label} has no fixed execution count. Duration-based results cannot be compared.`);
  }
  if (![metrics.total_runtime_seconds, metrics.total_query_execution_time_seconds]
    .every(value => Number.isFinite(value) && value >= 0)) {
    throw new Error(`${label} does not contain final timing metrics.`);
  }
}

function importedComparisonRun(result, label, statisticsSource, telemetry) {
  validateComparableResult(result, label);
  const configuration = result.configuration;
  return {
    id: `imported-${++importSequence}`,
    source: 'imported',
    fileName: label,
    completedAt: result.metrics.end_time || result.start_time || null,
    engine: resultEngine(configuration),
    mode: resultMode(configuration),
    server: configuration.server,
    database: String(configuration.database ?? '(default)'),
    threads: configuration.threads,
    iterations: configuration.iterations_per_thread ?? null,
    statisticsSource: ['none', 'runtime', 'query-store'].includes(statisticsSource)
      ? statisticsSource
      : configuration.query_stats ? 'runtime' : 'none',
    telemetry: ['live', 'final'].includes(telemetry) ? telemetry : null,
    workloadHash: null,
    comparisonKey: null,
    result
  };
}

function importedComparisonRuns(value, fileName) {
  if (isPlainObject(value) && value.schema === 'sqlsim-comparison') {
    if (value.version !== 1) throw new Error(`${fileName} uses an unsupported comparison version.`);
    return [['baseline', 'A'], ['candidate', 'B']].map(([side, letter]) =>
      importedComparisonRun(value[side]?.result, `${fileName} (${letter})`, value[side]?.statisticsSource, value[side]?.telemetry));
  }
  return [importedComparisonRun(value, fileName)];
}

const comparisonResultInput = document.querySelector('#comparison-result-input');
let comparisonImportSide = 'baseline';
for (const side of ['baseline', 'candidate']) {
  document.querySelector(`#import-${side}-result`).addEventListener('click', () => {
    comparisonImportSide = side;
    comparisonResultInput.click();
  });
}
comparisonResultInput.addEventListener('change', async () => {
  const file = comparisonResultInput.files[0];
  const side = comparisonImportSide;
  comparisonResultInput.value = '';
  if (!file) return;
  try {
    if (file.size > 125_000_000) throw new Error('Result files cannot exceed 125 MB.');
    const imported = importedComparisonRuns(JSON.parse(await file.text()), file.name);
    importedRuns = [...imported, ...importedRuns].slice(0, MAX_IMPORTED_RUNS);
    populateRunPickers(imported.length === 2
      ? { baseline: imported[0].id, candidate: imported[1].id }
      : { [side]: imported[0].id });
    showToast(imported.length === 2
      ? 'Comparison imported as baseline and candidate.'
      : `Result imported as the ${side}.`);
  } catch (error) {
    showError(error instanceof SyntaxError
      ? `${file.name} is not valid JSON. Import the final result written by -json -o.`
      : error.message);
  }
});

function drawChart() {
  const canvas = document.querySelector('#throughput-chart');
  const styles = getComputedStyle(document.documentElement);
  const lineColor = styles.getPropertyValue('--blue').trim();
  const gridColor = styles.getPropertyValue('--line').trim();
  const fillColor = styles.getPropertyValue('--chart-fill').trim();
  const fillEndColor = styles.getPropertyValue('--chart-fill-end').trim();
  const rect = canvas.getBoundingClientRect();
  const ratio = window.devicePixelRatio || 1;
  canvas.width = Math.max(1, Math.floor(rect.width * ratio));
  canvas.height = Math.floor(180 * ratio);
  const ctx = canvas.getContext('2d');
  ctx.scale(ratio, ratio);
  const width = rect.width;
  const height = 180;
  const top = 14;
  const bottom = 14;
  const min = 0;
  const max = Math.max(1, ...chartValues) * 1.1;

  ctx.clearRect(0, 0, width, height);
  ctx.strokeStyle = gridColor;
  ctx.lineWidth = 1;
  for (let i = 0; i < 4; i += 1) {
    const y = top + ((height - top - bottom) / 3) * i;
    ctx.beginPath();
    ctx.moveTo(0, y);
    ctx.lineTo(width, y);
    ctx.stroke();
  }

  if (chartValues.length === 0) return;

  const points = chartValues.map((value, index) => ({
    x: (index / Math.max(1, chartValues.length - 1)) * width,
    y: top + (1 - (value - min) / (max - min)) * (height - top - bottom)
  }));

  if (points.length > 1) {
    const gradient = ctx.createLinearGradient(0, top, 0, height);
    gradient.addColorStop(0, fillColor);
    gradient.addColorStop(1, fillEndColor);
    ctx.beginPath();
    ctx.moveTo(points[0].x, height - bottom);
    points.forEach(point => ctx.lineTo(point.x, point.y));
    ctx.lineTo(points.at(-1).x, height - bottom);
    ctx.closePath();
    ctx.fillStyle = gradient;
    ctx.fill();

    ctx.beginPath();
    points.forEach((point, index) => index === 0 ? ctx.moveTo(point.x, point.y) : ctx.lineTo(point.x, point.y));
    ctx.strokeStyle = lineColor;
    ctx.lineWidth = 2;
    ctx.stroke();
  }
  const last = points.at(-1);
  ctx.beginPath();
  ctx.arc(last.x - 1, last.y, 4, 0, Math.PI * 2);
  ctx.fillStyle = lineColor;
  ctx.fill();
}

function formatElapsed(seconds) {
  const minutes = Math.floor(seconds / 60).toString().padStart(2, '0');
  const remaining = (seconds % 60).toString().padStart(2, '0');
  return `00:${minutes}:${remaining}`;
}

function isServerMode() {
  return window.location.protocol === 'http:' || window.location.protocol === 'https:';
}

function getPlannedExecutions(request) {
  if (request.mode === 'workload') {
    return workloadGroups.reduce(
      (total, group) => total + group.threads * group.iterations * group.batchCount, 0);
  }
  if (request.mode === 'file' && selectedSqlFile) {
    const batches = selectedSqlFile.content.split(/^\s*GO\s*(?:--.*)?$/gmi).filter(value => value.trim()).length;
    return request.threads * request.iterations * Math.max(1, batches);
  }
  if (request.mode === 'replay' && selectedReplayFile?.summary) {
    const passes = Math.max(1, request.iterations);
    const stressMultiplier = request.replayMode === 'stress' ? Math.max(1, request.threads) : 1;
    return selectedReplayFile.summary.recognizedEvents * passes * stressMultiplier;
  }
  return request.mode === 'query' ? request.threads * request.iterations : 0;
}

function prepareMonitor(liveTelemetry, request) {
  const consoleMode = request.telemetry === 'console';
  switchView('monitor');
  document.querySelector('#nav-live-dot').classList.toggle('hidden', !liveTelemetry);
  document.querySelector('#live-monitor-content').classList.toggle('hidden', !liveTelemetry);
  document.querySelector('#no-live-monitor').classList.toggle('hidden', liveTelemetry);
  document.querySelector('#no-live-monitor-title').textContent = consoleMode
    ? 'Capturing console output'
    : 'Maximum-performance run in progress';
  document.querySelector('#no-live-monitor-note').textContent = consoleMode
    ? 'Studio will open the result rows automatically when the run finishes.'
    : 'Studio is showing run state and elapsed time only. When the run finishes, choose View results for the final statistics.';
  document.querySelector('.run-state').classList.add('running');
  document.querySelector('#run-state-label').textContent = 'Running...';
  document.querySelector('#run-target').textContent = `${request.mode} · ${request.database} on ${request.server}`;
  plannedExecutions = getPlannedExecutions(request);
  lastProgressTimestamp = null;
  chartValues = [];
  previousTick = null;
  intervalRate = null;
  liveStatisticsSource = request.statisticsSource || 'none';
  renderLiveQueryStatistics(null);
  document.querySelector('#avg-duration-block').classList.add('hidden');
  document.querySelector('#avg-duration-value').textContent = '--';
  document.querySelector('#throughput-value').textContent = '0';
  document.querySelector('#execution-count').textContent = '0';
  document.querySelector('#awaiting-first-result').classList.add('hidden');
  document.querySelector('#execution-target').textContent = plannedExecutions > 0
    ? `of ${plannedExecutions.toLocaleString()} configured`
    : 'Total determined by replay file';
  document.querySelector('#connection-count').textContent = '0';
  document.querySelector('#connection-detail').textContent = 'Awaiting telemetry';
  document.querySelector('#failed-connection-count').textContent = '0';
  document.querySelector('#error-count').textContent = '0';
  document.querySelector('#percent-complete').textContent = '0%';
  document.querySelector('#overall-progress-bar').style.width = '0';
  document.querySelector('#aggregate-progress-bar').style.width = '0';
  document.querySelector('#progress-label').textContent = request.mode === 'workload' ? 'Mixed workload' : request.mode;
  document.querySelector('#progress-threads').textContent = `${request.threads.toLocaleString()} configured connection${request.threads === 1 ? '' : 's'}`;
  document.querySelector('#progress-count').textContent = plannedExecutions > 0 ? `0 / ${plannedExecutions.toLocaleString()}` : '0 completed';
  document.querySelector('#progress-errors').textContent = '0 errors';
  document.querySelector('#event-table').replaceChildren();
  const eventEmpty = document.createElement('div');
  eventEmpty.className = 'workload-empty';
  eventEmpty.id = 'event-empty';
  eventEmpty.textContent = 'Awaiting structured events.';
  document.querySelector('#event-table').appendChild(eventEmpty);
  renderRunLogs([]);
  requestAnimationFrame(drawChart);
  const runAction = document.querySelector('#stop-run');
  runAction.disabled = false;
  runAction.dataset.action = 'stop';
  runAction.classList.add('danger');
  runAction.innerHTML = '<i data-lucide="square"></i><span>Stop run</span>';
  refreshIcons();
  window.clearInterval(elapsedTimer);
  elapsedSeconds = 0;
  document.querySelector('#elapsed-time').textContent = formatElapsed(elapsedSeconds);
  elapsedTimer = window.setInterval(() => {
    elapsedSeconds += 1;
    document.querySelector('#elapsed-time').textContent = formatElapsed(elapsedSeconds);
  }, 1000);
}

function appendProgressEvent(progress) {
  if (!progress.timestamp || progress.timestamp === lastProgressTimestamp) return;
  lastProgressTimestamp = progress.timestamp;
  document.querySelector('#event-empty')?.remove();
  const row = document.createElement('div');
  row.className = 'event-row';
  const eventType = progress.type || 'progress';
  const completed = (progress.successful_executions || 0) + (progress.failed_executions || 0);
  const connected = progress.successful_connections || 0;
  const awaitingFirstResult = eventType !== 'started' && completed === 0 && connected > 0;
  const values = [
    new Date(progress.timestamp).toLocaleTimeString([], { hour12: false }),
    eventType,
    eventType === 'started' ? `${progress.threads || 0} connections` : `${completed.toLocaleString()} executions`,
    eventType === 'started'
      ? 'Engine started'
      : awaitingFirstResult
        ? `${connected.toLocaleString()} connected, running`
        : `${Math.round(intervalRate ?? (progress.throughput_per_second || 0)).toLocaleString()} exec/sec`,
    eventType === 'started' ? '' : `${progress.errors || 0} errors`
  ];
  values.forEach((value, index) => {
    const element = document.createElement(index === 0 ? 'time' : 'span');
    element.textContent = value;
    if (index === 1) element.className = `event-type ${eventType}-event`;
    row.appendChild(element);
  });
  const table = document.querySelector('#event-table');
  table.prepend(row);
  while (table.querySelectorAll('.event-row').length > 20) table.lastElementChild.remove();
}

function renderRunLogs(logs = []) {
  const entries = document.querySelector('#log-entries');
  entries.querySelectorAll('.log-entry').forEach(entry => entry.remove());
  logs.forEach(log => {
    const entry = document.createElement('div');
    entry.className = 'log-entry';
    entry.dataset.level = log.level;
    const sourceClass = log.source === 'Studio' ? 'studio-source'
      : log.source === 'Process' ? 'process-source'
        : 'stream-source';
    const timestamp = new Date(log.timestamp).toLocaleTimeString([], {
      hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit', fractionalSecondDigits: 3
    });
    entry.innerHTML = `<time>${timestamp}</time><span class="log-source ${sourceClass}"></span><p></p>`;
    entry.querySelector('.log-source').textContent = log.source;
    entry.querySelector('p').textContent = log.message;
    entries.appendChild(entry);
  });
  document.querySelector('[data-log-filter="error"] b').textContent = logs.filter(log => log.level === 'error').length;
  document.querySelector('[data-log-filter="warning"] b').textContent = logs.filter(log => log.level === 'warning').length;
  document.querySelector('.log-footer > span').textContent = `${logs.length} ${logs.length === 1 ? 'entry' : 'entries'}`;
}

function populateResults(snapshot) {
  latestSnapshot = snapshot;
  const result = snapshot.result;
  const progress = snapshot.progress;
  // Before a live run completes, the querystats snapshot is the only source of
  // timings and connection statistics.
  const live = snapshot.liveQueryStats;
  const liveTotals = live?.query_stats?.totals;
  const configuration = result?.configuration || {};
  const metrics = result?.metrics || {};
  const replayResult = result?.replay_summary?.result;
  const consoleMode = snapshot.telemetry === 'console';
  const success = result ? result.success : consoleMode ? snapshot.state === 'completed' : progress?.status === 'success';
  const executions = configuration.total_batches
    ?? replayResult?.events
    ?? (progress ? (progress.successful_executions || 0) + (progress.failed_executions || 0) : 0);
  const runtime = metrics.total_runtime_seconds ?? progress?.elapsed_seconds ?? 0;
  const errors = metrics.errors?.total ?? progress?.errors ?? (success ? 0 : 1);
  const warnings = metrics.warnings?.total ?? live?.total_warnings ?? 0;
  const queryTime = metrics.total_query_execution_time_seconds
    ?? (typeof liveTotals?.total_elapsed_ms === 'number' ? liveTotals.total_elapsed_ms / 1000 : null);
  const connectionTime = metrics.total_connection_time_seconds
    ?? (live?.connection_stats?.count > 0
      ? live.connection_stats.avg_ms * live.connection_stats.count / 1000
      : null);
  const hasTiming = queryTime !== null || connectionTime !== null;
  const otherTime = Math.max(0, runtime - (queryTime ?? 0) - (connectionTime ?? 0));
  const connections = result?.connection_stats?.count
    ?? (progress ? (progress.successful_connections || 0) + (progress.failed_connections || 0) : 0);
  const avgConnection = result?.connection_stats?.avg_ms ?? live?.connection_stats?.avg_ms ?? null;
  const throughput = runtime > 0 ? executions / runtime : 0;
  const completedAt = snapshot.completedAt || metrics.end_time || result?.start_time;
  const completedLabel = completedAt ? new Date(completedAt).toLocaleString() : 'Completed run';
  const server = configuration.server || 'unknown server';
  const database = configuration.database || 'default database';
  const connectionLabel = `${connections.toLocaleString()} connection${connections === 1 ? '' : 's'}`;

  document.querySelector('#result-subtitle').textContent = consoleMode
    ? `${completedLabel} · console output`
    : `${completedLabel} · ${database} on ${server} · ${connectionLabel}`;

  const statusBanner = document.querySelector('.result-status');
  // Cancelling is a deliberate act, not a failure, so it must not read as one.
  const stopped = snapshot.state === 'stopped';
  const failed = !stopped && (!success || snapshot.state === 'failed');
  statusBanner.classList.toggle('success-result', !failed);
  statusBanner.classList.toggle('error-result', failed);
  statusBanner.querySelector('.result-check').innerHTML = failed
    ? '<i data-lucide="circle-alert"></i>'
    : '<i data-lucide="check"></i>';

  document.querySelector('#result-status-title').textContent = snapshot.state === 'stopped'
    ? 'Run stopped before completion'
    : failed ? 'Run completed with errors' : 'Run completed successfully';

  // Surface the reason here so a failure does not require opening the log drawer.
  const firstError = (snapshot.logs ?? []).find(entry => entry.level === 'error');
  document.querySelector('#result-status-detail').textContent = snapshot.state === 'stopped'
    ? `Cancelled after ${executions.toLocaleString()} executions in ${runtime.toFixed(3)} seconds`
    : failed && firstError
      ? firstError.message
      : consoleMode
        ? `Console workload exited with code ${snapshot.exitCode ?? 'unknown'}`
        : `${executions.toLocaleString()} executions with ${errors} error(s) in ${runtime.toFixed(3)} seconds`;
  document.querySelector('#result-throughput').textContent = Math.round(throughput).toLocaleString();
  document.querySelector('#result-runtime').textContent = runtime.toFixed(3);
  document.querySelector('#result-executions').textContent = executions.toLocaleString();
  document.querySelector('#result-success-detail').textContent = success ? 'Completed successfully' : 'Review the execution log';
  const avgDuration = metrics.query_execution_operations?.avg_elapsed_ms ?? measuredAverageDuration(live);
  const avgInSeconds = avgDuration !== null && avgDuration >= 1000;
  document.querySelector('#result-avg-duration').textContent = avgDuration === null
    ? '--'
    : avgInSeconds ? (avgDuration / 1000).toFixed(2) : Math.round(avgDuration).toLocaleString();
  document.querySelector('#result-avg-duration-detail').textContent = avgDuration === null
    ? 'Not measured'
    : avgInSeconds ? 'seconds per execution' : 'ms per execution';
  document.querySelector('#result-connections').textContent = connections.toLocaleString();
  document.querySelector('#result-connection-detail').textContent = avgConnection === null
    ? 'Average not measured'
    : `${avgConnection.toFixed(1)} ms average`;
  document.querySelector('#result-errors').textContent = errors.toLocaleString();
  document.querySelector('#result-errors').classList.toggle('success-text', errors === 0);
  document.querySelector('#result-warning-detail').textContent = `${warnings} warning(s)`;

  document.querySelector('#result-metrics').classList.toggle('hidden', consoleMode);
  document.querySelector('#result-timing-panel').classList.toggle('hidden', consoleMode || !hasTiming);
  document.querySelector('#result-config-panel').classList.toggle('hidden', consoleMode);
  const consolePanel = document.querySelector('#result-console-panel');
  consolePanel.classList.toggle('hidden', !consoleMode);
  document.querySelector('#result-console-output').textContent = snapshot.consoleOutput || 'No console output was captured.';
  document.querySelector('#result-console-truncated').classList.toggle('hidden', !snapshot.consoleOutputTruncated);

  // Name the flags this run actually used; a live run never produces final JSON.
  const timingSource = result ? '-json' : '-querystats-interval';
  document.querySelector('#result-timing-source').textContent = timingSource;
  document.querySelector('#result-timing-subtitle').textContent = result
    ? 'Client-observed timing from final JSON output'
    : 'Client-observed timing from periodic query-statistics snapshots';

  const timingMaximum = Math.max(runtime, queryTime ?? 0, connectionTime ?? 0, otherTime, 0.001);
  const timingValues = [
    ['query', queryTime],
    ['connection', connectionTime],
    ['other', otherTime]
  ];
  timingValues.forEach(([name, value]) => {
    document.querySelector(`#result-${name}-time-bar`).style.width = `${Math.round((value ?? 0) / timingMaximum * 100)}%`;
    document.querySelector(`#result-${name}-time-detail`).textContent = value === null ? '--' : `${value.toFixed(3)} s`;
  });

  const pathName = value => String(value || '').split(/[\\/]/).at(-1);
  const workloadLabel = configuration.workload_file
    ? pathName(configuration.workload_file)
    : configuration.replay_file
      ? `Replay · ${pathName(configuration.replay_file)}`
      : configuration.input_file
        ? pathName(configuration.input_file)
        : configuration.batch_count === 1 ? 'Query' : 'SQL batches';
  const shape = configuration.workload_groups
    ? `${configuration.workload_groups} group${configuration.workload_groups === 1 ? '' : 's'}`
    : `${configuration.batch_count || live?.config?.total_batches || 0} batch${configuration.batch_count === 1 ? '' : 'es'}`;
  const statisticsLabel = snapshot.queryStore
    ? 'Query Store'
    : (result?.query_stats?.queries?.length || live?.query_stats?.queries?.length)
      ? 'Runtime messages'
      : 'Not collected';
  document.querySelector('#result-config-workload').textContent = workloadLabel;
  document.querySelector('#result-config-shape').textContent = shape;
  document.querySelector('#result-config-connections').textContent = (configuration.threads || live?.config?.threads || connections).toLocaleString();
  document.querySelector('#result-config-statistics').textContent = statisticsLabel;
  document.querySelector('#result-config-driver').textContent =
    metrics.odbc_driver_version || configuration.odbc_driver || progress?.odbc_driver_version || 'Not yet reported';
  document.querySelector('#result-config-engine').textContent = `${snapshot.engine || configuration.application_name || 'Engine'} ${result?.version || progress?.version || ''}`.trim();
  document.querySelector('#result-config-server').textContent = [
    result?.server_version || progress?.server_version,
    result?.server_edition || progress?.server_edition
  ].filter(Boolean).join(' · ') || 'Not yet reported';

  const statisticsPanel = document.querySelector('#result-statistics-panel');
  const statisticsTitle = document.querySelector('#result-statistics-title');
  const statisticsSubtitle = document.querySelector('#result-statistics-subtitle');
  const statisticsSource = document.querySelector('#result-statistics-source');
  const table = document.querySelector('#query-report-table');
  const resultSummary = document.querySelector('#result-query-summary');
  table.querySelectorAll('.query-report-row, .workload-empty').forEach(row => row.remove());
  statisticsPanel.classList.add('hidden');
  resultSummary.classList.add('hidden');

  if (snapshot.queryStore) {
    statisticsPanel.classList.remove('hidden');
    statisticsTitle.textContent = 'Query Store statistics';
    statisticsSubtitle.textContent = 'Aggregate deltas captured between pre-run and post-run snapshots';
    statisticsSource.textContent = 'Studio · Query Store';
    snapshot.queryStore.queries.forEach(query => {
      const row = document.createElement('div');
      row.className = 'query-report-row';
      row.innerHTML = '<div><strong></strong><span></span></div><span></span><span></span><span></span><span></span><span></span><span class="ok">0</span>';
      row.querySelector('strong').textContent = `Query ${query.queryId} · Plan ${query.planId}`;
      row.querySelector('div span').textContent = query.queryText;
      const values = row.querySelectorAll(':scope > span');
      values[0].textContent = query.executionCount.toLocaleString();
      values[1].textContent = 'Not available';
      values[2].textContent = `${query.averageDurationMs.toFixed(2)} ms`;
      values[3].textContent = `${query.averageCpuMs.toFixed(2)} ms`;
      values[4].textContent = query.averageLogicalReads.toFixed(1);
      table.appendChild(row);
    });
    if (snapshot.queryStore.queries.length === 0) {
      const empty = document.createElement('div');
      empty.className = 'workload-empty';
      empty.textContent = 'Query Store recorded no attributable execution delta for this run.';
      table.appendChild(empty);
    }
  } else if (result?.query_stats?.queries?.length || live?.query_stats?.queries?.length) {
    const finalStatistics = Boolean(result?.query_stats?.queries?.length);
    const runtimeStatistics = finalStatistics ? result.query_stats : live.query_stats;
    const queryStats = runtimeStatistics.queries;
    statisticsPanel.classList.remove('hidden');
    statisticsTitle.textContent = 'Runtime query statistics';
    statisticsSubtitle.textContent = !finalStatistics && snapshot.state === 'stopped'
      ? 'Partial per-query diagnostics from the last snapshot before the run stopped'
      : 'Per-query diagnostics returned by sqlsim for this run';
    statisticsSource.textContent = finalStatistics ? '-querystats' : '-querystats-interval';
    resultSummary.classList.remove('hidden');
    renderQueryStatisticsSummary(resultSummary, runtimeStatistics);
    appendRuntimeQueryRows(table, queryStats);
  }
  renderReplayComparison(snapshot);
}

function appendRuntimeQueryRows(table, queryStats) {
  queryStats.forEach((query, index) => {
    const row = document.createElement('div');
    row.className = 'query-report-row';
    row.innerHTML = '<div><strong></strong><span></span></div><span></span><span></span><span></span><span></span><span></span><span class="ok">0</span>';
    row.querySelector('strong').textContent = `Query ${index + 1}`;
    row.querySelector('div span').textContent = query.query;
    row.querySelector('div span').title = query.query || '';
    const values = row.querySelectorAll(':scope > span');
    const spids = Array.isArray(query.spids) ? query.spids : [];
    const hiddenSpids = Math.max(0, (query.spid_count || spids.length) - spids.length);
    const failures = Number(query.failures) || 0;
    values[0].textContent = (Number(query.executions) || 0).toLocaleString();
    values[1].textContent = spids.length > 0
      ? `${spids.join(', ')}${hiddenSpids > 0 ? ` (+${hiddenSpids.toLocaleString()})` : ''}`
      : 'Unavailable';
    values[2].textContent = `${(Number(query.total_elapsed_ms?.avg) || 0).toFixed(2)} ms`;
    values[3].textContent = `${(Number(query.server_cpu_ms?.avg) || 0).toFixed(2)} ms`;
    values[4].textContent = (Number(query.logical_reads?.avg) || 0).toFixed(1);
    values[5].textContent = failures.toLocaleString();
    values[5].className = failures > 0 ? 'error-text' : 'ok';
    table.appendChild(row);
  });
}

function formatLiveMilliseconds(value) {
  return value >= 1000 ? `${(value / 1000).toFixed(2)} s` : `${value.toFixed(value >= 100 ? 0 : 2)} ms`;
}

function renderLiveBars(container, rows, formatter, segmented = false) {
  const maximum = Math.max(0, ...rows.map(row => row.value));
  container.replaceChildren(...rows.map(row => {
    const item = document.createElement('div');
    item.className = 'live-bar-row';
    item.title = row.query;
    const label = document.createElement('span');
    label.textContent = row.label;
    const track = document.createElement('div');
    track.className = 'live-bar-track';
    const primary = document.createElement('i');
    primary.className = segmented ? 'bar-server' : 'bar-value';
    primary.style.width = `${maximum > 0 ? (segmented ? row.server : row.value) / maximum * 100 : 0}%`;
    track.appendChild(primary);
    if (segmented) {
      const client = document.createElement('i');
      client.className = 'bar-client';
      client.style.width = `${maximum > 0 ? row.client / maximum * 100 : 0}%`;
      track.appendChild(client);
    }
    const value = document.createElement('strong');
    value.textContent = formatter(row.value);
    item.append(label, track, value);
    return item;
  }));
}

const QUERY_SUMMARY_MARKUP = `
  <div class="live-query-totals">
    <div><span>Executions</span><strong data-total="executions">0</strong></div>
    <div><span>Total elapsed</span><strong data-total="elapsed">0 ms</strong></div>
    <div><span>Server CPU</span><strong data-total="cpu">0 ms</strong></div>
    <div><span>Logical reads</span><strong data-total="logical">0</strong></div>
    <div><span>Physical reads</span><strong data-total="physical">0</strong></div>
    <div><span>Failures</span><strong data-total="failures">0</strong></div>
  </div>
  <p class="live-query-note" data-summary-note></p>
  <div class="live-query-charts">
    <div class="live-query-chart"><div class="live-chart-heading"><h3>Avg elapsed</h3><div class="legend"><span class="legend-server"></span>Server <span class="legend-client"></span>Client</div></div><div class="live-bars" data-chart="elapsed"></div></div>
    <div class="live-query-chart"><div class="live-chart-heading"><h3>Avg server CPU</h3></div><div class="live-bars" data-chart="cpu"></div></div>
    <div class="live-query-chart"><div class="live-chart-heading"><h3>Avg logical reads</h3></div><div class="live-bars" data-chart="reads"></div></div>
    <div class="live-query-chart"><div class="live-chart-heading"><h3>Execution share</h3></div><div class="live-bars" data-chart="executions"></div></div>
  </div>`;
document.querySelectorAll('.query-stat-summary').forEach(summary => { summary.innerHTML = QUERY_SUMMARY_MARKUP; });

// Shared by Monitor and Results so both views describe a run the same way.
function renderQueryStatisticsSummary(root, queryStats) {
  const queries = Array.isArray(queryStats?.queries) ? queryStats.queries : [];
  const number = value => Number(value) || 0;
  const rows = queries.map((query, index) => {
    const executions = number(query.executions);
    const elapsed = number(query.total_elapsed_ms?.avg);
    const server = Math.min(elapsed, number(query.server_elapsed_ms?.avg));
    return {
      label: `Q${index + 1}`,
      query: query.query || '',
      executions,
      failures: number(query.failures),
      elapsed,
      server,
      client: Math.max(0, elapsed - server),
      cpu: number(query.server_cpu_ms?.avg),
      reads: number(query.logical_reads?.avg),
      weight: elapsed * executions
    };
  });
  const topRows = [...rows].sort((a, b) => b.weight - a.weight || b.executions - a.executions).slice(0, 10);
  const totalExecutions = rows.reduce((sum, row) => sum + row.executions, 0);
  const totals = queryStats?.totals || {};
  const setTotal = (name, text) => { root.querySelector(`[data-total="${name}"]`).textContent = text; };
  setTotal('executions', number(totals.executions ?? totalExecutions).toLocaleString());
  setTotal('elapsed', formatLiveMilliseconds(number(totals.total_elapsed_ms)));
  setTotal('cpu', formatLiveMilliseconds(number(totals.server_cpu_ms)));
  setTotal('logical', Math.round(number(totals.logical_reads)).toLocaleString());
  setTotal('physical', Math.round(number(totals.physical_reads)).toLocaleString());
  const failures = rows.reduce((sum, row) => sum + row.failures, 0);
  setTotal('failures', failures.toLocaleString());
  root.querySelector('[data-total="failures"]').classList.toggle('error-text', failures > 0);
  root.querySelector('[data-summary-note]').textContent = rows.length > topRows.length
    ? `Charts show the ${topRows.length} queries with the most total elapsed time; the table lists all ${rows.length}.`
    : `Charts show all ${rows.length} quer${rows.length === 1 ? 'y' : 'ies'}.`;

  const chart = name => root.querySelector(`[data-chart="${name}"]`);
  renderLiveBars(chart('elapsed'), topRows.map(row => ({ ...row, value: row.elapsed })), formatLiveMilliseconds, true);
  renderLiveBars(chart('cpu'), topRows.map(row => ({ ...row, value: row.cpu })), formatLiveMilliseconds);
  renderLiveBars(chart('reads'), topRows.map(row => ({ ...row, value: row.reads })), value => value.toFixed(1));
  renderLiveBars(chart('executions'), topRows.map(row => ({ ...row, value: totalExecutions > 0 ? row.executions / totalExecutions * 100 : 0 })),
    value => `${value.toFixed(1)}%`);
}

function renderLiveQueryStatistics(liveQueryStats) {
  const queries = Array.isArray(liveQueryStats?.query_stats?.queries) ? liveQueryStats.query_stats.queries : [];
  const empty = document.querySelector('#live-query-empty');
  const content = document.querySelector('#live-query-content');
  const table = document.querySelector('#live-query-table');
  table.querySelectorAll('.query-report-row').forEach(row => row.remove());
  if (queries.length === 0) {
    empty.textContent = liveStatisticsSource === 'runtime'
      ? 'Waiting for the first query-statistics snapshot.'
      : liveStatisticsSource === 'query-store'
        ? 'Query Store statistics appear in Results after the run completes.'
        : 'Enable Collect per-query performance to see live per-query statistics.';
    empty.classList.remove('hidden');
    content.classList.add('hidden');
    return;
  }

  empty.classList.add('hidden');
  content.classList.remove('hidden');
  renderQueryStatisticsSummary(document.querySelector('#live-query-summary'), liveQueryStats.query_stats);
  appendRuntimeQueryRows(table, queries);
}

function formatReplayDelta(original, replay, unit = '%') {
  if (!Number.isFinite(original) || !Number.isFinite(replay) || original === 0) return 'Unavailable';
  const delta = (replay - original) / original * 100;
  return `${delta >= 0 ? '+' : ''}${delta.toFixed(1)}${unit}`;
}

function replayOutcomeText(outcome) {
  if (!outcome) return 'Unavailable';
  return `${(outcome.ok || 0).toLocaleString()} ok · ${(outcome.error || 0).toLocaleString()} error · ${(outcome.abort || 0).toLocaleString()} abort`;
}

function renderReplayComparison(snapshot) {
  const panel = document.querySelector('#result-replay-comparison-panel');
  const result = snapshot.result;
  const captureQueries = result?.replay_capture?.queries;
  if (!Array.isArray(captureQueries)) {
    panel.classList.add('hidden');
    return;
  }

  panel.classList.remove('hidden');
  const originalOutcome = result?.replay_summary?.original;
  const replayOutcome = result?.replay_summary?.result;
  document.querySelector('#replay-original-outcomes').textContent = replayOutcomeText(originalOutcome);
  document.querySelector('#replay-result-outcomes').textContent = replayOutcomeText(replayOutcome);
  const replayMode = result?.configuration?.replay_mode || 'unknown';
  document.querySelector('#replay-result-mode').textContent =
    replayMode === 'stress' ? 'Load stress · transformed' : 'Session order';

  const replayQueries = new Map(
    (result?.query_stats?.queries || []).map(query => [query.query, query]));
  const table = document.querySelector('#replay-comparison-table');
  table.querySelectorAll('.replay-comparison-row, .workload-empty').forEach(row => row.remove());

  captureQueries.forEach((original, index) => {
    const replay = replayQueries.get(original.query);
    const row = document.createElement('div');
    row.className = 'replay-comparison-row';
    row.innerHTML = '<div><strong></strong><span></span></div><span></span><span></span><span></span><span></span><span></span><span></span>';
    row.querySelector('strong').textContent = `Query ${index + 1}`;
    row.querySelector('div span').textContent = original.query;
    const values = row.querySelectorAll(':scope > span');
    values[0].textContent = replay
      ? `${original.executions.toLocaleString()} → ${(replay.executions || 0).toLocaleString()}`
      : original.executions.toLocaleString();
    values[1].textContent = original.avg_duration_ms === null
      ? 'Not captured'
      : `${original.avg_duration_ms.toFixed(3)} ms`;
    values[2].textContent = replay
      ? `${(replay.total_elapsed_ms?.avg || 0).toFixed(3)} ms`
      : 'Enable diagnostics';
    values[3].textContent = replay
      ? formatReplayDelta(original.avg_duration_ms, replay.total_elapsed_ms?.avg)
      : 'Unavailable';
    values[4].textContent = replay
      ? formatReplayDelta(original.avg_logical_reads, replay.logical_reads?.avg)
      : 'Unavailable';
    const failures = replay?.failures || 0;
    values[5].textContent = failures.toLocaleString();
    values[5].className = failures > 0 ? 'error-text' : 'ok';
    table.appendChild(row);
  });

  if (captureQueries.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'workload-empty';
    empty.textContent = 'The capture contains no executable SQL to compare.';
    table.appendChild(empty);
  }

  const hasReplayDiagnostics = replayQueries.size > 0;
  document.querySelector('#result-replay-comparison-subtitle').textContent = hasReplayDiagnostics
    ? 'Exact SQL-text matches between original XEvent metrics and this Replay run'
    : 'Original XEvent metrics are available; enable per-query performance to collect Replay metrics';
  document.querySelector('#replay-comparison-note').textContent = replayMode === 'stress'
    ? 'Load stress flattens sessions and may multiply execution counts. Deltas describe the transformed load, not a like-for-like reproduction.'
    : hasReplayDiagnostics
      ? 'Deltas compare averages from the captured execution with this run. Environment, cache state, concurrency, and diagnostic overhead can affect results.'
      : 'Run again with Collect per-query performance enabled to populate Replay elapsed time, CPU, reads, and failures.';
}

// Averages the per-query measurements the engine writes to its snapshot file,
// weighted by execution count so a hot query does not count the same as a rare one.
function measuredAverageDuration(liveQueryStats) {
  const queries = liveQueryStats?.query_stats?.queries;
  if (!Array.isArray(queries) || queries.length === 0) return null;
  let totalMs = 0;
  let executions = 0;
  queries.forEach(query => {
    const count = Number(query.executions) || 0;
    const average = Number(query.total_elapsed_ms?.avg);
    if (count > 0 && Number.isFinite(average)) {
      totalMs += average * count;
      executions += count;
    }
  });
  return executions > 0 ? totalMs / executions : null;
}

function renderAverageDuration(durationMs) {
  const block = document.querySelector('#avg-duration-block');
  if (durationMs === null) {
    block.classList.add('hidden');
    return;
  }
  const useSeconds = durationMs >= 1000;
  document.querySelector('#avg-duration-value').textContent = useSeconds
    ? (durationMs / 1000).toFixed(1)
    : Math.round(durationMs).toLocaleString();
  document.querySelector('#avg-duration-unit').textContent = useSeconds ? 'sec' : 'ms';
  block.classList.remove('hidden');
}

function applyRunSnapshot(snapshot) {
  workloadIsRunning = snapshot.state === 'running';
  document.querySelector('#run-detach-note').classList.toggle('hidden', !workloadIsRunning);
  renderRunLogs(snapshot.logs);
  if (snapshot.progress) {
    const completed = (snapshot.progress.successful_executions || 0) + (snapshot.progress.failed_executions || 0);
    const successfulConnections = snapshot.progress.successful_connections || 0;
    const failedConnections = snapshot.progress.failed_connections || 0;
    const percent = plannedExecutions > 0 ? Math.min(100, Math.round(completed / plannedExecutions * 100)) : 0;
    // The engine counts executions only on completion, so a query slower than the
    // one-second progress interval reports zero. Say so rather than drawing a zero.
    const awaitingFirstResult = completed === 0 && successfulConnections > 0;
    const isNewTick = snapshot.progress.type !== 'started'
      && snapshot.progress.timestamp !== lastProgressTimestamp;
    const tickElapsed = typeof snapshot.progress.elapsed_seconds === 'number'
      ? snapshot.progress.elapsed_seconds
      : null;
    if (isNewTick && tickElapsed !== null) {
      if (previousTick) {
        const deltaElapsed = tickElapsed - previousTick.elapsed;
        const deltaCompleted = completed - previousTick.completed;
        if (deltaElapsed > 0 && deltaCompleted >= 0) intervalRate = deltaCompleted / deltaElapsed;
      }
      previousTick = { elapsed: tickElapsed, completed };
    }
    // Before the second tick there is no interval to measure, so fall back to the
    // engine's cumulative figure rather than showing nothing.
    const displayRate = intervalRate ?? (snapshot.progress.throughput_per_second || 0);

    document.querySelector('#execution-count').textContent = completed.toLocaleString();
    document.querySelector('#execution-target').textContent = awaitingFirstResult
      ? 'None completed yet'
      : plannedExecutions > 0 ? `of ${plannedExecutions.toLocaleString()} planned` : 'Reported by engine';
    document.querySelector('#throughput-value').textContent = awaitingFirstResult
      ? '--'
      : Math.round(displayRate).toLocaleString();
    renderAverageDuration(measuredAverageDuration(snapshot.liveQueryStats));
    document.querySelector('#error-count').textContent = (snapshot.progress.errors || 0).toLocaleString();
    document.querySelector('#connection-count').textContent = (successfulConnections + failedConnections).toLocaleString();
    document.querySelector('#connection-detail').textContent = awaitingFirstResult
      ? `${successfulConnections.toLocaleString()} connected, running`
      : `${successfulConnections.toLocaleString()} successful`;
    document.querySelector('#failed-connection-count').textContent = failedConnections.toLocaleString();
    document.querySelector('#percent-complete').textContent = plannedExecutions > 0 ? `${percent}%` : 'Running';
    document.querySelector('#overall-progress-bar').style.width = `${percent}%`;
    document.querySelector('#aggregate-progress-bar').style.width = `${percent}%`;
    document.querySelector('#progress-count').textContent = plannedExecutions > 0
      ? `${completed.toLocaleString()} / ${plannedExecutions.toLocaleString()}`
      : `${completed.toLocaleString()} completed`;
    document.querySelector('#progress-errors').textContent = `${snapshot.progress.errors || 0} errors`;
    if (typeof snapshot.progress.elapsed_seconds === 'number') {
      elapsedSeconds = Math.floor(snapshot.progress.elapsed_seconds);
      document.querySelector('#elapsed-time').textContent = formatElapsed(elapsedSeconds);
    }
    if (isNewTick) {
      // Plotting zeros before the first completion would read as a stalled server.
      if (!awaitingFirstResult) {
        chartValues = [...chartValues.slice(-19), displayRate];
        requestAnimationFrame(drawChart);
      }
      document.querySelector('#awaiting-first-result').classList.toggle('hidden', !awaitingFirstResult);
    }
    appendProgressEvent(snapshot.progress);
  }
  if (snapshot.telemetry === 'live') renderLiveQueryStatistics(snapshot.liveQueryStats);

  if (['completed', 'failed', 'stopped'].includes(snapshot.state)) {
    window.clearInterval(runPollTimer);
    window.clearInterval(elapsedTimer);
    document.querySelector('.run-state').classList.remove('running');
    document.querySelector('.run-state').classList.toggle('run-failed', snapshot.state === 'failed');
    document.querySelector('#nav-live-dot').classList.add('hidden');
    document.querySelector('#run-state-label').textContent = snapshot.state === 'completed'
      ? 'Run completed'
      : snapshot.state === 'stopped' ? 'Run stopped' : 'Run failed';
    const action = document.querySelector('#stop-run');
    action.dataset.action = 'results';
    action.classList.remove('danger');
    action.innerHTML = '<i data-lucide="chart-no-axes-combined"></i><span>View results</span>';
    if (snapshot.state === 'completed') {
      const finalExecutions = snapshot.result?.configuration?.total_batches
        ?? snapshot.result?.replay_summary?.result?.events;
      if (typeof finalExecutions === 'number') {
        document.querySelector('#execution-count').textContent = finalExecutions.toLocaleString();
        document.querySelector('#percent-complete').textContent = '100%';
        document.querySelector('#overall-progress-bar').style.width = '100%';
        document.querySelector('#aggregate-progress-bar').style.width = '100%';
        document.querySelector('#progress-count').textContent = plannedExecutions > 0
          ? `${finalExecutions.toLocaleString()} / ${plannedExecutions.toLocaleString()}`
          : `${finalExecutions.toLocaleString()} completed`;
      }
    }
    populateResults(snapshot);
    if (snapshot.telemetry === 'console') {
      switchView('results');
    }
    refreshIcons();
  }
}

function resultFileStem() {
  const configuration = latestSnapshot?.result?.configuration || {};
  const database = String(configuration.database || document.querySelector('#database').value || 'run')
    .replace(/[^a-z0-9._-]+/gi, '-').replace(/^-+|-+$/g, '');
  const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
  return `sqlsim-results-${database || 'run'}-${stamp}`;
}

document.querySelector('#export-results-json').addEventListener('click', () => {
  if (!latestSnapshot?.result) {
    showError('Export requires a completed Final results only run.');
    return;
  }
  const json = JSON.stringify(latestSnapshot.result, null, 2);
  downloadBlob(new Blob([json], { type: 'application/json' }), `${resultFileStem()}.json`);
  showToast('Results JSON exported.');
});

function comparisonSide(run) {
  const mixedProfile = run.source === 'imported' ? resultComparisonProfile(run) : null;
  return {
    id: run.id,
    source: run.source === 'imported' ? 'imported' : 'session',
    fileName: run.fileName || null,
    label: comparisonRunLabel(run),
    engine: run.engine,
    mode: run.mode,
    server: run.server,
    database: run.database,
    threads: run.threads,
    iterations: run.iterations,
    statisticsSource: run.statisticsSource,
    telemetry: comparisonTelemetry(run),
    workloadHash: mixedProfile ? mixedProfile.workloadHash : run.workloadHash,
    completedAt: run.completedAt,
    result: run.result
  };
}

document.querySelector('#export-comparison').addEventListener('click', () => {
  const baseline = findComparisonRun(document.querySelector('#baseline-run').value);
  const candidate = findComparisonRun(document.querySelector('#candidate-run').value);
  if (!baseline?.result || !candidate?.result) {
    showError('Select a baseline and candidate before exporting.');
    return;
  }

  const a = comparisonMetrics(baseline);
  const b = comparisonMetrics(candidate);
  const differences = comparisonDifferences(baseline, candidate);
  const bundle = {
    schema: 'sqlsim-comparison',
    version: 1,
    generated: new Date().toISOString(),
    comparable: differences.length === 0,
    noiseThresholdPercent: COMPARISON_NOISE_PERCENT,
    differences,
    baseline: comparisonSide(baseline),
    candidate: comparisonSide(candidate),
    deltas: Object.fromEntries(['throughput', 'runtime', 'execution', 'connection', 'errors'].map(name => [name, {
      baseline: a[name],
      candidate: b[name],
      percentChange: percentChange(a[name], b[name])
    }]))
  };

  const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
  downloadBlob(new Blob([JSON.stringify(bundle, null, 2)], { type: 'application/json' }),
    `sqlsim-comparison-${stamp}.json`);
  showToast('Comparison exported. Render it with comparison-report.ps1.');
});

// sqlsim workload JSON tolerates // and /* */ comments; JSON.parse does not.
function stripJsonComments(text) {
  return text.replace(/"(?:\\.|[^"\\])*"|\/\*[\s\S]*?\*\/|\/\/[^\n\r]*/g,
    match => match.startsWith('"') ? match : ' ');
}

function importWorkloadDefinition(text) {
  const definition = JSON.parse(stripJsonComments(text));
  const groups = definition?.workloads;
  if (!Array.isArray(groups) || groups.length === 0) {
    throw new Error('The workload file has no "workloads" array.');
  }
  if (groups.length > 20) throw new Error('Studio supports a maximum of 20 workload groups.');

  const imported = [];
  const skipped = [];
  let totalBytes = 0;
  groups.forEach((group, index) => {
    const label = `Group ${index + 1}`;
    if (!Array.isArray(group.queries) || group.queries.length === 0) {
      skipped.push(group.file ? `${label} (references ${group.file})` : label);
      return;
    }
    const content = group.queries.map(query => String(query)).join('\nGO\n');
    const bytes = new TextEncoder().encode(content).length;
    if (bytes > 1_000_000) throw new Error(`${label} exceeds the 1 MB script limit.`);
    totalBytes += bytes;
    if (totalBytes > 10_000_000) throw new Error('Combined workload content exceeds 10 MB.');
    const threads = Math.min(10_000, Math.max(1, Number(group.threads) || 1));
    const iterations = Math.max(1, Number(group.iterations) || 1);
    const thinkTimeMs = Math.min(86_400_000, Math.max(0, Number(group.think_time_ms) || 0));
    imported.push({
      fileName: group.file ? String(group.file).split(/[\\/]/).at(-1) : `group-${index + 1}.sql`,
      content,
      threads,
      iterations,
      thinkTimeMs,
      batchCount: Math.max(1, content.split(/^\s*GO\s*(?:--.*)?$/gmi).filter(value => value.trim()).length)
    });
  });

  if (imported.length === 0) {
    throw new Error('No groups contained inline queries. Studio cannot read scripts referenced by file path.');
  }
  return { imported, skipped, hasDuration: typeof definition.duration_seconds === 'number' };
}

const workloadJsonInput = document.querySelector('#workload-json-input');
document.querySelector('#import-workload-json').addEventListener('click', () => workloadJsonInput.click());
workloadJsonInput.addEventListener('change', async () => {
  const file = workloadJsonInput.files[0];
  workloadJsonInput.value = '';
  if (!file) return;
  try {
    if (file.size > 10_000_000) throw new Error('Workload files cannot exceed 10 MB.');
    const { imported, skipped, hasDuration } = importWorkloadDefinition(await file.text());
    workloadGroups = imported;
    renderWorkloadGroups();
    updateCommandPreview();
    const notes = [`Imported ${imported.length} group${imported.length === 1 ? '' : 's'}.`];
    if (skipped.length > 0) notes.push(`Skipped ${skipped.length} file-based group(s): ${skipped.join(', ')}.`);
    if (hasDuration) notes.push('duration_seconds is not supported by Studio and was ignored.');
    showToast(notes.join(' '));
  } catch (error) {
    showError(error instanceof SyntaxError ? 'The workload file is not valid JSON.' : error.message);
  }
});

function showConnectionTestResult(message, state) {  const target = document.querySelector('#test-connection-result');
  target.textContent = message;
  target.classList.remove('hidden', 'is-success', 'is-error');
  target.classList.add(state === 'success' ? 'is-success' : 'is-error');
}

function connectionProbeRequest(request) {
  if (request) {
    return {
      ...request,
      mode: 'query',
      query: null,
      inputFileName: null,
      inputContent: null,
      replayMode: null,
      workloadGroups: null,
      threads: 1,
      iterations: 1,
      quiet: false,
      stopOnError: true,
      telemetry: 'console',
      statisticsSource: request.statisticsSource,
      retryCount: 0,
      retryDelaySeconds: null,
      preparedStatements: false,
      reconnect: false,
      connectionPooling: false
    };
  }

  return {
    engine: selectedEngine,
    mode: 'query',
    server: document.querySelector('#server').value.trim(),
    database: document.querySelector('#database').value.trim(),
    authentication: authentication.value,
    username: document.querySelector('#auth-username').value.trim() || null,
    secret: document.querySelector('#auth-secret').value || null,
    query: null,
    inputFileName: null,
    inputContent: null,
    replayMode: null,
    workloadGroups: null,
    threads: 1,
    iterations: 1,
    quiet: false,
    trustServerCertificate: document.querySelector('#trust-server-certificate').checked,
    stopOnError: true,
    telemetry: 'console',
    statisticsSource: statisticsSource.value,
    loginTimeoutSeconds: optionalNumber('#login-timeout'),
    applicationName: optionalText('#application-name'),
    retryCount: 0,
    retryDelaySeconds: null,
    encryption: document.querySelector('#encryption').value,
    certificateHostname: optionalText('#certificate-hostname'),
    readOnlyIntent: document.querySelector('#read-only-intent').checked,
    multiSubnetFailover: document.querySelector('#multi-subnet-failover').checked,
    queryTimeoutSeconds: optionalNumber('#query-timeout'),
    preparedStatements: false,
    reconnect: false,
    connectionPooling: false
  };
}

async function testConnection(request = null, source = 'test') {
  const button = document.querySelector(source === 'run' ? '#run-workload' : '#test-connection');
  const label = document.querySelector(source === 'run' ? '#run-label' : '#test-connection-label');
  const idleLabel = source === 'run' ? 'Run workload' : 'Test connection';
  const testingLabel = source === 'run' ? 'Checking connection…' : 'Testing…';
  const probe = connectionProbeRequest(request);
  const server = probe.server;
  const database = probe.database;
  if (!server || !database) {
    showConnectionTestResult('Enter a server and database first.', 'error');
    return null;
  }
  if (!isServerMode()) {
    showConnectionTestResult('Connection testing requires the Studio server.', 'error');
    return null;
  }

  button.disabled = true;
  label.textContent = testingLabel;
  document.querySelector('#test-connection-result').classList.add('hidden');
  try {
    const response = await studioFetch('/api/connection-test', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(probe)
    });
    const result = await response.json();
    if (result.success) {
      const details = [
        result.serverVersion ? `SQL Server ${result.serverVersion}` : null,
        result.edition,
        result.database ? `database ${result.database}` : null,
        result.driver ? `driver ${result.driver}` : null
      ].filter(Boolean).join(' · ');
      showConnectionTestResult(`Connected in ${Math.round(result.elapsedMs)} ms — ${details}`, 'success');
      return result;
    } else {
      showConnectionTestResult(result.error || 'Connection failed.', 'error');
      return null;
    }
  } catch {
    showConnectionTestResult('Studio could not reach the connection test endpoint.', 'error');
    return null;
  } finally {
    button.disabled = false;
    label.textContent = idleLabel;
  }
}

document.querySelector('#test-connection').addEventListener('click', () => testConnection());

async function startRealRun() {
  const authenticationMode = authentication.value;
  if (selectedMode === 'file' && !selectedSqlFile) {
    showError('Choose a SQL file before running.');
    return;
  }
  if (selectedMode === 'replay' && !selectedReplayFile) {
    showError('Choose a replay XML file before running.');
    return;
  }
  if (selectedMode === 'workload' && workloadGroups.length === 0) {
    showError('Add at least one SQL script to the workload.');
    return;
  }
  const databaseField = document.querySelector('#database');
  if (!databaseField.value.trim()) {
    databaseField.focus();
    showError('Enter a database before running.');
    return;
  }
  const secretField = document.querySelector('#auth-secret');
  const simpleMode = selectedMode === 'query' ? '#query-mode' : '#file-mode';
  const replayMode = document.querySelector('#replay-mode-select').value;
  const request = {
    engine: selectedEngine,
    mode: selectedMode,
    server: document.querySelector('#server').value.trim(),
    database: document.querySelector('#database').value.trim(),
    authentication: authenticationMode,
    username: document.querySelector('#auth-username').value.trim() || null,
    secret: secretField.value || null,
    query: selectedMode === 'query' ? document.querySelector('#query-text').value : null,
    inputFileName: selectedMode === 'file' ? selectedSqlFile.name : selectedMode === 'replay' ? selectedReplayFile.name : null,
    inputContent: selectedMode === 'file'
      ? selectedSqlFile.content
      : selectedMode === 'replay'
        ? retargetReplayDatabase(selectedReplayFile.content, databaseField.value.trim())
        : null,
    replayMode: selectedMode === 'replay' ? replayMode : null,
    workloadGroups: selectedMode === 'workload'
      ? workloadGroups.map(group => ({
          fileName: group.fileName,
          content: group.content,
          threads: group.threads,
          iterations: group.iterations,
          thinkTimeMs: group.thinkTimeMs
        }))
      : null,
    threads: selectedMode === 'workload'
      ? workloadGroups.reduce((sum, group) => sum + group.threads, 0)
      : selectedMode === 'replay'
      ? Number(document.querySelector('#replay-threads').value)
      : Number(document.querySelector(`${simpleMode} .simple-threads`).value),
    iterations: selectedMode === 'workload'
      ? 1
      : selectedMode === 'replay'
      ? Number(document.querySelector('#replay-iterations').value)
      : Number(document.querySelector(`${simpleMode} .simple-iterations`).value),
    quiet: document.querySelector('#quiet-mode-toggle').checked,
    trustServerCertificate: document.querySelector('#trust-server-certificate').checked,
    stopOnError: document.querySelector('#stop-on-error').checked,
    telemetry: telemetryMode.value,
    statisticsSource: statisticsSource.value,
    loginTimeoutSeconds: optionalNumber('#login-timeout'),
    applicationName: optionalText('#application-name'),
    retryCount: optionalNumber('#retry-count'),
    retryDelaySeconds: null,
    encryption: document.querySelector('#encryption').value,
    certificateHostname: optionalText('#certificate-hostname'),
    readOnlyIntent: document.querySelector('#read-only-intent').checked,
    multiSubnetFailover: document.querySelector('#multi-subnet-failover').checked,
    queryTimeoutSeconds: optionalNumber('#query-timeout'),
    preparedStatements: document.querySelector('#prepared-statements').checked,
    reconnect: document.querySelector('#reconnect-each-iteration').checked,
    connectionPooling: document.querySelector('#connection-pooling').checked
  };

  const connectionResult = await testConnection(request, 'run');
  if (!connectionResult) {
    document.querySelector('#test-connection-result').scrollIntoView({ block: 'nearest' });
    return;
  }
  const response = await studioFetch('/api/runs', {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(request)
  });
  secretField.value = '';
  if (!response.ok) {
    const failure = await response.json();
    showError(failure.error || 'Studio could not start the workload.');
    return;
  }

  prepareMonitor(request.telemetry === 'live', request);
  window.clearInterval(runPollTimer);
  runPollTimer = window.setInterval(async () => {
    try {
      const statusResponse = await fetch('/api/runs/current', { credentials: 'same-origin', cache: 'no-store' });
      if (statusResponse.ok) applyRunSnapshot(await statusResponse.json());
    } catch {
      // The server went away mid-run. Stop polling and say so once, rather
      // than retrying silently three times a second.
      window.clearInterval(runPollTimer);
      markStudioOffline();
      showError('sqlsim Studio stopped while the workload was running. Any workload it started has been ended.');
    }
  }, 350);
}

document.querySelector('#run-workload').addEventListener('click', () => {
  if (isServerMode()) startRealRun().catch(error => showError(error.message));
  else showError('Start sqlsim Studio to run workloads.');
});
document.querySelector('#stop-run').addEventListener('click', async event => {
  if (event.currentTarget.dataset.action === 'results') {
    switchView('results');
  } else if (isServerMode()) {
    try {
      const response = await studioFetch('/api/runs/current', { method: 'DELETE', credentials: 'same-origin' });
      if (!response.ok) showError('No active workload could be stopped.');
    } catch (error) {
      showError(error.message);
    }
  }
});
window.addEventListener('resize', drawChart);

// Studio keeps running when the browser goes away. A workload outlives the
// page that started it, which is correct for a load test, and the session URL
// is kept on disk so the interface can be reopened. Stopping is therefore
// something the user asks for, through Shut down, rather than something Studio
// infers from a quiet tab.
//
// Closing the tab mid-run is the one case worth interrupting. The workload
// carries on against the database with no interface attached, which is rarely
// what someone reaching for the X expects. Only the browser's own confirmation
// can stop a tab closing, and its wording cannot be changed, so the banner
// below explains what that generic prompt is about.
window.addEventListener('beforeunload', event => {
  if (!isServerMode() || !workloadIsRunning || shuttingDown) return;
  // preventDefault is the current standard; returnValue is what older browsers
  // still read. Neither controls the text the browser shows.
  event.preventDefault();
  event.returnValue = '';
});

// Exposes exactly what the handler above decides on, so a test can check the
// guard is armed during a run and disarmed afterwards. A browser will not let
// an automated close be confirmed or cancelled, so the condition is the only
// part that can be asserted.
window.__studioRunActive = () => isServerMode() && workloadIsRunning && !shuttingDown;

// Studio has no window and no console, so this is the only deliberate way to
// stop it. Confirm first: shutting down kills a running workload, and the page
// stops working immediately afterwards.
const shutdownDialog = document.querySelector('#shutdown-dialog');
document.querySelector('#shutdown-studio').addEventListener('click', async () => {
  let running = false;
  try {
    const response = await fetch('/api/runs/current', { credentials: 'same-origin', cache: 'no-store' });
    if (response.ok) {
      const snapshot = await response.json();
      running = snapshot.state === 'running';
    }
  } catch {
    // Studio is already gone; the dialog still explains what shutting down does.
  }
  document.querySelector('#shutdown-run-warning').classList.toggle('hidden', !running);
  shutdownDialog.showModal();
  document.querySelector('#cancel-shutdown').focus();
});

const closeShutdownDialog = () => shutdownDialog.close();
document.querySelector('#close-shutdown').addEventListener('click', closeShutdownDialog);
document.querySelector('#cancel-shutdown').addEventListener('click', closeShutdownDialog);

document.querySelector('#confirm-shutdown').addEventListener('click', async () => {
  const button = document.querySelector('#confirm-shutdown');
  button.disabled = true;
  button.textContent = 'Shutting down...';
  // This exit is deliberate, so the page must not also challenge it.
  shuttingDown = true;
  try {
    await fetch('/api/session/shutdown', {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' }
    });
  } catch {
    // The reply can be lost to the shutdown it just triggered. That is not a
    // failure: the page below reports the outcome either way.
  }
  shutdownDialog.close();
  markStudioOffline();
  document.body.innerHTML =
    '<div class="shutdown-complete">' +
    '<h1>sqlsim Studio has shut down</h1>' +
    '<p>Any running workload was stopped and this session\'s temporary files were removed. ' +
    'You can close this tab.</p>' +
    '<p>Start Studio again to run another workload.</p>' +
    '</div>';
});

window.addEventListener('load', refreshIcons);
window.addEventListener('load', connectStudioRuntime);
window.addEventListener('hashchange', () => {
  const view = window.location.hash.slice(1);
  if (['configure', 'monitor', 'results', 'compare'].includes(view)) switchView(view);
});
const initialView = window.location.hash.slice(1);
if (['configure', 'monitor', 'results', 'compare'].includes(initialView)) {
  switchView(initialView);
  if (initialView === 'compare') loadRunHistory().catch(error => showError(error.message));
}
syncPoolingAvailability();
syncAuthenticationFields();
updateCommandPreview();
refreshLoadShapeTotals();
updateRunSummary();
refreshIcons();
