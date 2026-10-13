<#
.SYNOPSIS
    Generate an interactive HTML report from sqlsim -json output (no -querystats required).

.DESCRIPTION
    Parses JSON output from sqlsim and generates a professional HTML report with
    interactive Chart.js charts showing overall execution performance, latency
    distributions, per-thread timing, and error/warning details.

    This report works with any sqlsim JSON output. For per-query performance
    breakdowns, use querystats-chart.ps1 with -querystats output instead.

    Can run sqlsim directly or accept saved JSON file input.
    Opens the HTML report in your default browser automatically.

.PARAMETER JsonFile
    Path to a JSON file containing sqlsim output (from -json -o).

.PARAMETER ServerName
    Server name for running sqlsim directly (default: localhost).

.PARAMETER DatabaseName
    Database name for running sqlsim directly.

.PARAMETER SqlFile
    SQL script file to run with sqlsim.

.PARAMETER WorkloadFile
    Workload JSON definition file to run with sqlsim.

.PARAMETER Query
    Ad-hoc query to run with sqlsim.

.PARAMETER Threads
    Number of threads (default: 1).

.PARAMETER Iterations
    Iterations per thread (default: 1).

.PARAMETER OutputFile
    Path for the HTML output file (default: execution-report.html in current directory).

.PARAMETER NoOpen
    Don't automatically open the HTML file in the browser.

.EXAMPLE
    # Generate report from saved JSON
    .\execution-report.ps1 -JsonFile results.json

.EXAMPLE
    # Run sqlsim and generate report
    .\execution-report.ps1 -SqlFile examples\sql\01-simple-queries.sql -Threads 4 -Iterations 100

.EXAMPLE
    # Report from workload file
    .\execution-report.ps1 -WorkloadFile examples\workload\workload-test.json

.EXAMPLE
    # Save to specific location without opening
    .\execution-report.ps1 -JsonFile results.json -OutputFile C:\reports\exec.html -NoOpen
#>

param(
    [string]$JsonFile,
    [string]$ServerName = "localhost",
    [string]$DatabaseName,
    [string]$SqlFile,
    [string]$WorkloadFile,
    [string]$Query,
    [int]$Threads = 1,
    [int]$Iterations = 1,
    [string]$OutputFile = "execution-report.html",
    [switch]$NoOpen
)

# --- Get JSON Data ---

function ConvertTo-HtmlText {
    param($Value)
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function ConvertTo-ReportNumber {
    param($Value)
    $number = 0.0
    $parsed = [double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$number)
    if ($parsed -and -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number)) { return $number }
    return 0.0
}

function ConvertTo-JsNumber {
    param($Value)
    return (ConvertTo-ReportNumber $Value).ToString('R', [Globalization.CultureInfo]::InvariantCulture)
}

Write-Host "sqlsim Execution Report Generator" -ForegroundColor Cyan
Write-Host ""

$jsonText = $null

if ($JsonFile) {
    if (-not (Test-Path $JsonFile)) {
        Write-Host "Error: File not found: $JsonFile" -ForegroundColor Red
        exit 1
    }
    $jsonText = Get-Content $JsonFile -Raw
    Write-Host "Reading JSON from: $JsonFile" -ForegroundColor Gray

} elseif ($SqlFile -or $WorkloadFile -or $Query) {
    # Run sqlsim directly
    # Find sqlsim: the installed release for this machine's architecture, then the
    # x64 release (ARM64 Windows can run it), then a source build, then PATH.
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'ARM64' } else { 'x64' }
    $searchPaths = @(
        (Join-Path $PSScriptRoot "..\..\$arch\sqlsim.exe"),
        (Join-Path $PSScriptRoot "..\..\x64\sqlsim.exe"),
        (Join-Path $PSScriptRoot "..\..\build\$arch\Release\sqlsim.exe")
    )
    $sqlsimPath = $searchPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $sqlsimPath) { $sqlsimPath = (Get-Command sqlsim -ErrorAction SilentlyContinue).Source }
    if (-not $sqlsimPath) { $sqlsimPath = 'sqlsim.exe' }

    # Run from workspace root so workload file paths resolve correctly
    $workspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
    Push-Location $workspaceRoot

    $sqlsimArgs = @("-S", $ServerName, "-E", "-json", "-q", "-v")
    if ($DatabaseName) { $sqlsimArgs += @("-d", $DatabaseName) }

    if ($WorkloadFile) {
        $sqlsimArgs += @("-workload", $WorkloadFile)
        Write-Host "Running: sqlsim -workload $WorkloadFile -json -q -v" -ForegroundColor Gray
    } elseif ($SqlFile) {
        $sqlsimArgs += @("-i", $SqlFile, "-n", $Threads, "-r", $Iterations)
        Write-Host "Running: sqlsim -i $SqlFile -n $Threads -r $Iterations -json -q -v" -ForegroundColor Gray
    } elseif ($Query) {
        $sqlsimArgs += @("-Q", $Query, "-n", $Threads, "-r", $Iterations)
        Write-Host "Running: sqlsim -Q `"$Query`" -n $Threads -r $Iterations -json -q -v" -ForegroundColor Gray
    }

    Write-Host ""
    $jsonText = & $sqlsimPath @sqlsimArgs 2>$null | Out-String
    Pop-Location

} else {
    Write-Host "Usage: Provide -JsonFile, -SqlFile, -WorkloadFile, or -Query." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Gray
    Write-Host "  .\execution-report.ps1 -JsonFile results.json" -ForegroundColor Gray
    Write-Host "  .\execution-report.ps1 -SqlFile examples\sql\01-simple-queries.sql -Threads 4 -Iterations 100" -ForegroundColor Gray
    Write-Host "  .\execution-report.ps1 -WorkloadFile examples\workload\workload-test.json" -ForegroundColor Gray
    Write-Host "  .\execution-report.ps1 -Query `"SELECT * FROM sys.databases`" -Threads 5 -Iterations 10" -ForegroundColor Gray
    exit 1
}

# --- Parse JSON ---

try {
    $data = $jsonText | ConvertFrom-Json
} catch {
    Write-Host "Error: Failed to parse JSON output" -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor DarkRed
    exit 1
}

# --- Extract Data ---

$config = $data.configuration
$metrics = $data.metrics
$connStats = $data.connection_stats

$server = $config.server
$database = $config.database
$authMethod = ConvertTo-HtmlText $config.authentication
$isWorkloadMode = $null -ne $config.workload_groups
$cfgThreads = if ($isWorkloadMode) { "&lt;various&gt;" } else { ConvertTo-HtmlText $config.threads }
$cfgIterations = if ($isWorkloadMode) { "&lt;various&gt;" } else { ConvertTo-HtmlText $config.iterations_per_thread }
$totalBatches = ConvertTo-ReportNumber $config.total_batches
$workloadFile = $config.workload_file

$runtime = ConvertTo-ReportNumber $metrics.total_runtime_seconds
$connTime = ConvertTo-ReportNumber $metrics.total_connection_time_seconds
$queryTime = ConvertTo-ReportNumber $metrics.total_query_execution_time_seconds
$execRuntime = if ($data.execution_elapsed_seconds) { ConvertTo-ReportNumber $data.execution_elapsed_seconds } else { $runtime }
$throughput = if ($execRuntime -gt 0 -and $totalBatches -gt 0) { "{0:N1}" -f ($totalBatches / $execRuntime) } else { "--" }
$peakThroughput = if ($data.peak_throughput) { "{0:N1}" -f (ConvertTo-ReportNumber $data.peak_throughput) } else { $null }
$avgConnMs = if ($metrics.connection_operations -and $metrics.connection_operations.avg_connect_time_ms) {
    "{0:N1}" -f (ConvertTo-ReportNumber $metrics.connection_operations.avg_connect_time_ms)
} elseif ($connStats -and (ConvertTo-ReportNumber $connStats.count) -gt 0) {
    "{0:N1}" -f (ConvertTo-ReportNumber $connStats.avg_ms)
} else { "--" }
$avgElapsedMs = if ($metrics.query_execution_operations -and $metrics.query_execution_operations.avg_elapsed_ms) {
    "{0:N2}" -f (ConvertTo-ReportNumber $metrics.query_execution_operations.avg_elapsed_ms)
} elseif ($totalBatches -gt 0 -and $queryTime -gt 0) {
    # Without -v there is no per-operation block; derive the average the same
    # way Studio Compare and comparison-report.ps1 do.
    "{0:N2}" -f ($queryTime * 1000 / $totalBatches)
} else { "--" }
$serverEdition = $data.server_edition
$serverVersion = $data.server_version

$errorCount = if ($metrics.errors) { [int](ConvertTo-ReportNumber $metrics.errors.total) } else { 0 }
$warningCount = if ($metrics.warnings) { [int](ConvertTo-ReportNumber $metrics.warnings.total) } else { 0 }
$errorList = if ($metrics.errors -and $metrics.errors.list) { @($metrics.errors.list) } else { @() }
$warningList = if ($metrics.warnings -and $metrics.warnings.list) { @($metrics.warnings.list) } else { @() }

$timestamp = ConvertTo-HtmlText $data.start_time
$endTime = ConvertTo-HtmlText $metrics.end_time

# Badge
if ($errorCount -gt 0 -and $warningCount -gt 0) {
    $badgeClass = "badge-error"
    $badgeText = "ERRORS: $errorCount | WARNINGS: $warningCount"
} elseif ($errorCount -gt 0) {
    $badgeClass = "badge-error"
    $badgeText = "ERRORS: $errorCount"
} elseif ($warningCount -gt 0) {
    $badgeClass = "badge-warning"
    $badgeText = "WARNINGS: $warningCount"
} else {
    $badgeClass = "badge-success"
    $badgeText = "SUCCESS"
}

# Workload config card
$workloadCard = if ($workloadFile) { "<span><span class='cfg-label'>Workload</span>$([System.Net.WebUtility]::HtmlEncode($workloadFile))</span>" } else { "" }

# Batches list
$batchesHtml = ""
if ($config.batches) {
    for ($i = 0; $i -lt $config.batches.Count; $i++) {
        $batchText = ($config.batches[$i] -replace '\r?\n', ' ' -replace '\s+', ' ').Trim()
        $encoded = [System.Net.WebUtility]::HtmlEncode($batchText)
        $batchesHtml += "            <tr><td class='query-num'>B$($i+1)</td><td class='query-text' title='$encoded'>$encoded</td></tr>`n"
    }
} elseif ($config.workloads) {
    $batchIdx = 1
    for ($g = 0; $g -lt $config.workloads.Count; $g++) {
        $wg = $config.workloads[$g]
        $batchesHtml += "            <tr><td colspan='2' style='font-weight:600;color:#656d76;padding-top:8px'>Group $($g+1): $(ConvertTo-ReportNumber $wg.threads) thread(s), $(ConvertTo-ReportNumber $wg.iterations) iteration(s), $(ConvertTo-ReportNumber $wg.batch_count) batch(es)</td></tr>`n"
        # Show queries from JSON batches array (included in workload JSON output)
        if ($wg.batches) {
            foreach ($q in $wg.batches) {
                $qText = ($q -replace '\r?\n', ' ' -replace '\s+', ' ').Trim()
                $encoded = [System.Net.WebUtility]::HtmlEncode($qText)
                $batchesHtml += "            <tr><td class='query-num' style='padding-left:20px'>B$batchIdx</td><td class='query-text' title='$encoded'>$encoded</td></tr>`n"
                $batchIdx++
            }
        } else {
            $batchIdx += [int](ConvertTo-ReportNumber $wg.batch_count)
        }
    }
}

# Error/warning alert HTML (similar to querystats report)
$alertHtml = ""
if ($errorCount -gt 0) {
    $errorRows = ""
    foreach ($err in $errorList) {
        $ts = if ($err.timestamp) { [System.Net.WebUtility]::HtmlEncode($err.timestamp) } else { "" }
        $qText = ""
        if ($err.query) {
            $preview = ($err.query -replace '\r?\n', ' ' -replace '\s+', ' ').Trim()
            if ($preview.Length -gt 60) { $preview = $preview.Substring(0, 60) + "..." }
            $qText = [System.Net.WebUtility]::HtmlEncode($preview)
        }
        $msg = [System.Net.WebUtility]::HtmlEncode($err.message)
        $errorRows += "            <tr><td class='msg-time'>$ts</td><td class='query-num'>$qText</td><td>$msg</td></tr>`n"
    }
    $suffix = if ($errorCount -gt $errorList.Count) { " (showing $($errorList.Count) of $errorCount)" } else { "" }
    $alertHtml += @"
    <div class="alert-box alert-error" id="errors-section">
        <h4>Errors: ${errorCount}${suffix}</h4>
        <table class="alert-table">
            <tr><th>Time</th><th>Query</th><th>Error</th></tr>
$errorRows        </table>
    </div>
"@
}
if ($warningCount -gt 0) {
    $warningRows = ""
    foreach ($warn in $warningList) {
        $ts = if ($warn.timestamp) { [System.Net.WebUtility]::HtmlEncode($warn.timestamp) } else { "" }
        $qText = ""
        if ($warn.query) {
            $preview = ($warn.query -replace '\r?\n', ' ' -replace '\s+', ' ').Trim()
            if ($preview.Length -gt 60) { $preview = $preview.Substring(0, 60) + "..." }
            $qText = [System.Net.WebUtility]::HtmlEncode($preview)
        }
        $msg = [System.Net.WebUtility]::HtmlEncode($warn.message)
        $warningRows += "            <tr><td class='msg-time'>$ts</td><td class='query-num'>$qText</td><td>$msg</td></tr>`n"
    }
    $suffix = if ($warningCount -gt $warningList.Count) { " (showing $($warningList.Count) of $warningCount)" } else { "" }
    $alertHtml += @"
    <div class="alert-box alert-warning" id="warnings-section">
        <h4>Warnings: ${warningCount}${suffix}</h4>
        <table class="alert-table">
            <tr><th>Time</th><th>Query</th><th>Warning</th></tr>
$warningRows        </table>
    </div>
"@
}

$generatedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

# --- Load Chart.js for offline embedding ---

$chartJsPath = Join-Path $PSScriptRoot "chart.umd.min.js"
if (-not (Test-Path $chartJsPath)) {
    Write-Host "Error: chart.umd.min.js not found in script directory." -ForegroundColor Red
    Write-Host "Expected at: $chartJsPath" -ForegroundColor DarkRed
    Write-Host "Download it: Invoke-WebRequest -Uri 'https://cdn.jsdelivr.net/npm/chart.js@4.4.7/dist/chart.umd.min.js' -OutFile '$chartJsPath'" -ForegroundColor Yellow
    exit 1
}
$chartJsContent = Get-Content $chartJsPath -Raw

# Peak throughput card
$peakCard = ""
if ($peakThroughput) {
    $peakCard = @"
        <div class="metric-card">
            <div class="label">Peak Throughput</div>
            <div class="value color-steel">$peakThroughput<span class="unit"> batch/s</span></div>
        </div>
"@
}

# Server edition for config bar (verbose only)
$editionInfo = ""
if ($serverEdition) {
    $editionDisplay = $serverEdition -replace 'Microsoft SQL Server ', '' -replace ' Edition', ''
    if ($serverVersion) {
        $editionDisplay = "$editionDisplay (v$serverVersion)"
    }
    if ($editionDisplay.Length -gt 60) { $editionDisplay = $editionDisplay.Substring(0, 57) + "..." }
    $editionInfo = "<span><span class='cfg-label'>Edition</span>$([System.Net.WebUtility]::HtmlEncode($editionDisplay))</span>"
}

# --- Generate HTML ---

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>sqlsim Execution Report</title>
    <script>$chartJsContent</script>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, sans-serif;
            background: #f6f8fa;
            color: #1f2328;
            padding: 16px;
            line-height: 1.4;
        }
        .container { max-width: 1400px; margin: 0 auto; }

        .header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 10px;
            padding-bottom: 8px;
            border-bottom: 1px solid #d0d7de;
        }
        .header h1 { font-size: 16px; font-weight: 600; color: #0969da; }
        .header h1 span { color: #656d76; font-weight: 400; font-size: 13px; }
        .badge { display: inline-block; padding: 3px 10px; border-radius: 20px; font-size: 12px; font-weight: 600; }
        .badge-success { background: #1a7f37; color: #fff; }
        .badge-warning { background: #d4a017; color: #fff; }
        .badge-error { background: #cf222e; color: #fff; }

        .metrics-bar { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 10px; }
        .metric-card { background: #ffffff; border: 1px solid #d0d7de; border-radius: 6px; padding: 6px 10px; flex: 1; min-width: 120px; }
        .metric-card .label { font-size: 10px; color: #656d76; text-transform: uppercase; letter-spacing: 0.5px; }
        .metric-card .value { font-size: 18px; font-weight: 700; font-variant-numeric: tabular-nums; }
        .metric-card .unit { font-size: 11px; color: #656d76; font-weight: 400; }
        .color-blue { color: #0969da; }
        .color-purple { color: #8250df; }
        .color-green { color: #1a7f37; }
        .color-teal { color: #0d9488; }
        .color-steel { color: #4a6fa5; }
        .color-red { color: #cf222e; }
        .color-amber { color: #d4a017; }

        .alert-box { border-radius: 6px; padding: 10px 14px; margin-bottom: 10px; font-size: 12px; }
        .alert-error { background: #fef2f2; border: 1px solid #fca5a5; color: #991b1b; }
        .alert-warning { background: #fefce8; border: 1px solid #fde68a; color: #854d0e; }
        .alert-box h4 { margin: 0 0 8px 0; font-size: 13px; }
        .alert-table { width: 100%; border-collapse: collapse; }
        .alert-table th { text-align: left; font-size: 10px; text-transform: uppercase; letter-spacing: 0.5px; padding: 4px 8px; border-bottom: 1px solid rgba(0,0,0,0.15); }
        .alert-table td { padding: 4px 8px; border-bottom: 1px solid rgba(0,0,0,0.08); font-size: 12px; vertical-align: top; }
        .alert-table .msg-time { color: #9ca3af; font-size: 11px; white-space: nowrap; font-family: "Cascadia Code","Consolas",monospace; }
        .alert-table .query-num { color: #bc4c00; font-weight: 600; white-space: nowrap; }

        .info-grid {
            font-size: 11px;
            color: #656d76;
            margin-bottom: 8px;
            padding: 4px 0;
        }
        .info-grid span { margin-right: 14px; }
        .info-grid .cfg-label { font-weight: 600; color: #8b949e; text-transform: uppercase; font-size: 10px; letter-spacing: 0.3px; margin-right: 3px; }

        .section {
            background: #ffffff;
            border: 1px solid #d0d7de;
            border-radius: 6px;
            padding: 14px;
            margin-bottom: 10px;
        }
        .section h3 { font-size: 14px; font-weight: 600; margin-bottom: 10px; color: #1f2328; }

        .detail-table { width: 100%; border-collapse: collapse; font-size: 12px; }
        .detail-table th { text-align: left; font-size: 10px; text-transform: uppercase; letter-spacing: 0.5px; color: #656d76; padding: 6px 8px; border-bottom: 2px solid #d0d7de; }
        .detail-table td { padding: 6px 8px; border-bottom: 1px solid #eaeef2; }
        .detail-table .query-num { font-weight: 700; color: #0969da; white-space: nowrap; }
        .detail-table .query-text { max-width: 500px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-family: "Cascadia Code","Consolas",monospace; font-size: 11px; color: #1f2328; }
        .detail-table .num { text-align: right; font-variant-numeric: tabular-nums; font-family: "Cascadia Code","Consolas",monospace; }

        .footer { text-align: center; padding: 8px; font-size: 10px; color: #8b949e; }
    </style>
</head>
<body>
<div class="container">
    <div class="header">
        <h1>sqlsim Execution Report <span>Start Run: $timestamp$(if ($endTime) { " &mdash; End Run: $endTime" })</span></h1>
        <span class="badge $badgeClass">$badgeText</span>
    </div>

    <div class="info-grid">
        <span><span class="cfg-label">Server</span>$([System.Net.WebUtility]::HtmlEncode($server))</span>
        <span><span class="cfg-label">Database</span>$([System.Net.WebUtility]::HtmlEncode($database))</span>
        <span><span class="cfg-label">Auth</span>$authMethod</span>
        <span><span class="cfg-label">Threads</span>$cfgThreads</span>
        <span><span class="cfg-label">Iterations</span>$cfgIterations</span>
        <span><span class="cfg-label">ODBC</span>$(ConvertTo-HtmlText $config.odbc_driver)</span>
        $workloadCard
        $editionInfo
    </div>

    <div class="metrics-bar">
        <div class="metric-card">
            <div class="label">Total Runtime</div>
            <div class="value color-blue">$("{0:N3}" -f $runtime)<span class="unit"> sec</span></div>
        </div>
        <div class="metric-card">
            <div class="label">Batches Executed</div>
            <div class="value color-purple">$totalBatches</div>
        </div>
        <div class="metric-card">
            <div class="label">Throughput</div>
            <div class="value color-green">$throughput<span class="unit"> batch/s</span></div>
        </div>
        $peakCard
        <div class="metric-card">
            <div class="label">Avg Connect Time</div>
            <div class="value color-teal">$avgConnMs<span class="unit"> ms</span></div>
        </div>
        <div class="metric-card">
            <div class="label">Avg Elapsed</div>
            <div class="value color-steel">$avgElapsedMs<span class="unit"> ms</span></div>
        </div>
        <div class="metric-card$(if ($errorCount -gt 0) { ' style="cursor:pointer" onclick="document.getElementById(''errors-section'').scrollIntoView({behavior:''smooth''})"' })">
            <div class="label">Errors</div>
            <div class="value $(if ($errorCount -gt 0) { 'color-red' } else { 'color-green' })">$errorCount</div>
        </div>
        <div class="metric-card">
            <div class="label">Warnings</div>
            <div class="value $(if ($warningCount -gt 0) { 'color-amber' } else { 'color-green' })">$warningCount</div>
        </div>
    </div>

    <!-- Batches: What Ran -->
$(if ($batchesHtml) { @"
    <div class="section">
        <h3>Batches</h3>
        <table class="detail-table">
            <tr><th>#</th><th>Query / Batch</th></tr>
$batchesHtml        </table>
    </div>
"@ })

    <!-- Time breakdown: connection vs query execution -->
    <div class="section">
        <h3>Time Breakdown</h3>
        <div style="display:flex;gap:16px;align-items:center;flex-wrap:wrap">
            <div style="flex:1;min-width:300px">
                <canvas id="timeBreakdownChart" height="60"></canvas>
            </div>
            <div style="font-size:12px;color:#656d76">
                <div style="margin-bottom:4px"><span style="display:inline-block;width:12px;height:12px;background:#0969da;border-radius:2px;vertical-align:middle;margin-right:6px"></span>Connection: $("{0:N3}" -f $connTime) sec</div>
                <div><span style="display:inline-block;width:12px;height:12px;background:#8250df;border-radius:2px;vertical-align:middle;margin-right:6px"></span>Query Execution: $("{0:N3}" -f $queryTime) sec</div>
            </div>
        </div>
    </div>

"@

# Errors/warnings at the bottom
if ($alertHtml) {
$html += @"
    $alertHtml
"@
}

# JavaScript for charts
$html += @"
    <div class="footer">
        Generated by sqlsim execution-report.ps1 | $generatedAt
    </div>
</div>

<script>
(function() {
    const connTime = $(ConvertTo-JsNumber $connTime);
    const queryTime = $(ConvertTo-JsNumber $queryTime);

    // Time breakdown horizontal stacked bar
    new Chart(document.getElementById('timeBreakdownChart'), {
        type: 'bar',
        data: {
            labels: [''],
            datasets: [
                { label: 'Connection', data: [connTime], backgroundColor: '#0969da', borderRadius: 3 },
                { label: 'Query Execution', data: [queryTime], backgroundColor: '#8250df', borderRadius: 3 }
            ]
        },
        options: {
            indexAxis: 'y',
            responsive: true,
            maintainAspectRatio: true,
            plugins: {
                legend: { display: false },
                tooltip: {
                    callbacks: {
                        label: ctx => ctx.dataset.label + ': ' + ctx.parsed.x.toFixed(3) + ' sec'
                    }
                }
            },
            scales: {
                x: { stacked: true, title: { display: true, text: 'Seconds' }, grid: { color: '#eaeef2' } },
                y: { stacked: true, display: false }
            }
        }
    });

"@



$html += @"
})();
</script>
</body>
</html>
"@

# --- Write Output ---

$html | Out-File -FilePath $OutputFile -Encoding UTF8
Write-Host "Report generated: $((Resolve-Path $OutputFile).Path)" -ForegroundColor Green

if (-not $NoOpen) {
    Write-Host "Opening in browser..."
    Start-Process $OutputFile
}
