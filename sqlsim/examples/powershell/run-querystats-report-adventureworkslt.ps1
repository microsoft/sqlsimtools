<#
.SYNOPSIS
    Run a mixed OLTP workload with query stats and generate an HTML performance report.

.DESCRIPTION
    Demonstrates the full sqlsim query stats workflow:
    1. Runs the 08-mixed-workload-adventureworkslt.sql OLTP workload using sqlsim with -querystats -json
    2. Generates an interactive HTML report with per-query performance charts

    Requires AdventureWorksLT database.
    The generated report includes Chart.js charts showing elapsed time, CPU,
    logical reads, and execution distribution across all queries.

.PARAMETER ServerName
    SQL Server name (default: localhost).

.PARAMETER DatabaseName
    Database name (default: AdventureWorksLT).

.PARAMETER Threads
    Number of concurrent threads (default: 8).

.PARAMETER Iterations
    Iterations per thread (default: 4).

.PARAMETER AccessToken
    Access token for Azure SQL Database authentication.

.PARAMETER OutputFile
    Path for the HTML report (default: querystats-report.html in current directory).

.PARAMETER NoOpen
    Don't automatically open the report in the browser.

.EXAMPLE
    # Local SQL Server with Windows Auth (simplest)
    .\run-querystats-report-adventureworkslt.ps1

.EXAMPLE
    # Higher concurrency
    .\run-querystats-report-adventureworkslt.ps1 -Threads 10 -Iterations 50

.EXAMPLE
    # Azure SQL Database with access token
    $token = (az account get-access-token --resource https://database.windows.net --query accessToken -o tsv)
    .\run-querystats-report-adventureworkslt.ps1 -ServerName myserver.database.windows.net -DatabaseName AdventureWorksLT -AccessToken $token

.EXAMPLE
    # Save report to specific location
    .\run-querystats-report-adventureworkslt.ps1 -OutputFile C:\reports\oltp-stats.html
#>

param(
    [string]$ServerName = "localhost",
    [string]$DatabaseName = "AdventureWorksLT",
    [int]$Threads = 8,
    [int]$Iterations = 4,
    [string]$AccessToken,
    [string]$OutputFile = "querystats-report.html",
    [switch]$NoOpen
)

# --- Find sqlsim.exe ---

# Find sqlsim: the installed release for this machine's architecture, then the
# x64 release (ARM64 Windows can run it), then a source build, then PATH.
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'ARM64' } else { 'x64' }
$searchPaths = @(
    (Join-Path $PSScriptRoot "..\..\$arch\sqlsim.exe"),
    (Join-Path $PSScriptRoot "..\..\x64\sqlsim.exe"),
    (Join-Path $PSScriptRoot "..\..\build\$arch\Release\sqlsim.exe")
)

$exe = $searchPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $exe) { $exe = (Get-Command sqlsim -ErrorAction SilentlyContinue).Source }

if (-not $exe) {
    Write-Host "Error: sqlsim.exe not found in the release folder, a source build, or PATH." -ForegroundColor Red
    exit 1
}

$exe = (Resolve-Path $exe).Path

# --- Find SQL file and chart script ---

$sqlFile = Join-Path $PSScriptRoot "..\sql\08-mixed-workload-adventureworkslt.sql"
$chartScript = Join-Path $PSScriptRoot "..\reports\querystats-chart.ps1"

if (-not (Test-Path $sqlFile)) {
    Write-Host "Error: SQL file not found: $sqlFile" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $chartScript)) {
    Write-Host "Error: Chart script not found: $chartScript" -ForegroundColor Red
    exit 1
}

# --- Header ---

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  QUERY STATS REPORT GENERATOR" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Server     : $ServerName" -ForegroundColor Gray
Write-Host "Database   : $DatabaseName" -ForegroundColor Gray
Write-Host "Workload   : 08-mixed-workload-adventureworkslt.sql" -ForegroundColor Gray
Write-Host "Threads    : $Threads" -ForegroundColor Gray
Write-Host "Iterations : $Iterations" -ForegroundColor Gray
Write-Host "Report     : $OutputFile" -ForegroundColor Gray
Write-Host ""

# --- Step 1: Run sqlsim with querystats ---

Write-Host "Step 1: Running OLTP workload with query stats..." -ForegroundColor White

$jsonFile = [System.IO.Path]::GetTempFileName()

$sqlsimArgs = @("-S", $ServerName, "-d", $DatabaseName)

if ($AccessToken) {
    # -T - reads the token from stdin so it never appears in the process list.
    $sqlsimArgs += @("-T", "-")
} else {
    $sqlsimArgs += "-E"
}

$sqlsimArgs += @("-i", (Resolve-Path $sqlFile).Path, "-n", $Threads, "-r", $Iterations, "-querystats", "-json", "-q")

if ($AccessToken) {
    $AccessToken | & $exe @sqlsimArgs 2>$null | Out-File -FilePath $jsonFile -Encoding utf8
} else {
    & $exe @sqlsimArgs 2>$null | Out-File -FilePath $jsonFile -Encoding utf8
}

$exitCode = $LASTEXITCODE

if ($exitCode -ne 0) {
    Write-Host "  Warning: sqlsim exited with code $exitCode" -ForegroundColor Yellow
}

# Verify JSON was generated
$jsonContent = Get-Content $jsonFile -Raw
if (-not $jsonContent -or $jsonContent.Trim().Length -eq 0) {
    Write-Host "Error: No JSON output generated." -ForegroundColor Red
    Remove-Item $jsonFile -ErrorAction SilentlyContinue
    exit 1
}

$data = $jsonContent | ConvertFrom-Json
$queryCount = $data.query_stats.queries.Count
$totalExec = $data.query_stats.totals.executions
$runtime = $data.metrics.total_runtime_seconds

Write-Host "  Completed: $queryCount unique queries, $totalExec total executions, ${runtime}s runtime" -ForegroundColor Green
Write-Host ""

# --- Step 2: Generate HTML report ---

Write-Host "Step 2: Generating HTML performance report..." -ForegroundColor White

$chartParams = @{
    JsonFile   = $jsonFile
    OutputFile = $OutputFile
}
if ($NoOpen) { $chartParams.NoOpen = $true }

& $chartScript @chartParams

# Clean up temp file
Remove-Item $jsonFile -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  DONE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
