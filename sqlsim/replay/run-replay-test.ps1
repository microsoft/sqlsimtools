<#
.SYNOPSIS
    End-to-end test of the sqlsim replay workflow.

.DESCRIPTION
    Automates the full capture → convert → replay → verify cycle:
    1. Starts an XEvent capture session
    2. Runs a workload with sqlsim
    3. Stops the capture
    4. Converts .xel to replay XML
    5. Starts a replay capture session
    6. Replays the trace
    7. Stops the replay capture
    8. Compares original vs replay traces

.PARAMETER ServerName
    SQL Server instance (default: localhost).

.PARAMETER SqlSimPath
    Path to sqlsim.exe. Defaults to the source build (build\x64\Release\sqlsim.exe)
    or, in a release package, x64\sqlsim.exe.

.PARAMETER XelDir
    Directory for .xel files (default: C:\temp).

.EXAMPLE
    .\run-replay-test.ps1

.EXAMPLE
    .\run-replay-test.ps1 -ServerName "myserver\instance"
#>

param(
    [string]$ServerName = "localhost",
    [string]$SqlSimPath = "",
    [string]$XelDir = "C:\temp"
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir

if ([string]::IsNullOrWhiteSpace($SqlSimPath)) {
    $SqlSimPath = @("build\x64\Release\sqlsim.exe", "x64\sqlsim.exe") |
        ForEach-Object { Join-Path $rootDir $_ } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1
    if (-not $SqlSimPath) {
        Write-Error "sqlsim.exe not found under $rootDir. Build sqlsim or pass -SqlSimPath."
        exit 1
    }
}
elseif (-not [System.IO.Path]::IsPathRooted($SqlSimPath)) {
    $SqlSimPath = Join-Path $rootDir $SqlSimPath
}

if (-not (Test-Path $SqlSimPath)) {
    Write-Error "sqlsim.exe not found at: $SqlSimPath. Build sqlsim or pass -SqlSimPath."
    exit 1
}

$originalXel = "$XelDir\sqlsim_test_capture*.xel"
$replayXel = "$XelDir\sqlsim_replay_capture*.xel"
$traceXml = Join-Path $rootDir "testing\replay-test-trace.xml"

function Run-SqlSim {
    param(
        [string[]]$Arguments
    )
    $allArgs = @("-S", $ServerName, "-E") + $Arguments
    $result = & $SqlSimPath @allArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host ($result | Out-String) -ForegroundColor Red
        Write-Error "sqlsim failed with exit code $LASTEXITCODE"
    }
    return $result
}

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  sqlsim Replay End-to-End Test" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "Server: $ServerName"
Write-Host "sqlsim: $SqlSimPath"
Write-Host ""

$passed = 0
$failed = 0
$startTime = Get-Date

# ============================================================
# Phase 1: Capture original workload
# ============================================================
Write-Host "--- Phase 1: Capture original workload ---" -ForegroundColor Yellow

Write-Host "  Cleaning old .xel files..." -ForegroundColor Gray
Remove-Item "$XelDir\sqlsim_test_capture*.xel" -ErrorAction SilentlyContinue
Remove-Item "$XelDir\sqlsim_replay_capture*.xel" -ErrorAction SilentlyContinue

# Create test stored proc (using sqlsim_admin so it's not captured)
Write-Host "  Creating test stored procedure..." -ForegroundColor Gray
Run-SqlSim @("-app", "sqlsim_admin", "-d", "tempdb", "-Q", 
    "IF OBJECT_ID('dbo.sqlsim_test_proc','P') IS NOT NULL DROP PROCEDURE dbo.sqlsim_test_proc`nGO`nCREATE PROCEDURE dbo.sqlsim_test_proc @id INT, @name NVARCHAR(100) AS BEGIN SELECT @id AS id, @name AS name END", "-q") | Out-Null

Write-Host "  Starting XEvent capture session..." -ForegroundColor Gray
Run-SqlSim @("-app", "sqlsim_admin", "-i", "replay\setup-test-capture.sql", "-q") | Out-Null

# Workload: SQL batches (generates sql_batch_completed)
Write-Host "  Running SQL batch workload (3 threads, 3 queries)..." -ForegroundColor Gray
Run-SqlSim @("-d", "master", "-Q", "SELECT @@VERSION`nGO`nSELECT name, database_id FROM sys.databases`nGO`nSELECT @@SERVERNAME", "-n", "3", "-q") | Out-Null

# Workload: CALL syntax (generates rpc_completed - user stored proc)
Write-Host "  Running RPC workload: user stored proc via {CALL}..." -ForegroundColor Gray
Run-SqlSim @("-d", "tempdb", "-Q", "{CALL dbo.sqlsim_test_proc(1, N'hello')}`nGO`n{CALL dbo.sqlsim_test_proc(2, N'world')}`nGO`n{CALL dbo.sqlsim_test_proc(3, N'test')}", "-q") | Out-Null

# Workload: CALL sp_executesql (generates rpc_completed - sp_executesql)
Write-Host "  Running RPC workload: sp_executesql via {CALL}..." -ForegroundColor Gray
Run-SqlSim @("-d", "tempdb", "-Q", "{CALL sp_executesql(N'SELECT @p1 AS val', N'@p1 INT', 42)}`nGO`n{CALL sp_executesql(N'SELECT @p1 AS val, @p2 AS label', N'@p1 INT, @p2 NVARCHAR(50)', 99, N'replay_test')}", "-q") | Out-Null

Write-Host "  Waiting for event flush..." -ForegroundColor Gray
Start-Sleep -Seconds 2

Write-Host "  Stopping XEvent capture..." -ForegroundColor Gray
Run-SqlSim @("-app", "sqlsim_admin", "-i", "replay\stop-test-capture.sql", "-q") | Out-Null

# Verify .xel files exist
$xelFiles = Get-ChildItem "$XelDir\sqlsim_test_capture*.xel" -ErrorAction SilentlyContinue
if ($xelFiles.Count -gt 0) {
    Write-Host "  PASS: XEL file(s) created ($($xelFiles.Count) file(s))" -ForegroundColor Green
    $passed++
} else {
    Write-Host "  FAIL: No XEL files found" -ForegroundColor Red
    $failed++
    exit 1
}

# ============================================================
# Phase 2: Convert .xel to replay XML
# ============================================================
Write-Host ""
Write-Host "--- Phase 2: Convert .xel to replay XML ---" -ForegroundColor Yellow

$convertScript = Join-Path $scriptDir "convert-xel.ps1"
& $convertScript -XelFile $originalXel -OutputFile $traceXml -ServerName $ServerName

if (Test-Path $traceXml) {
    $xmlSize = (Get-Item $traceXml).Length
    Write-Host "  PASS: Replay XML created ($([math]::Round($xmlSize / 1KB, 1)) KB)" -ForegroundColor Green
    $passed++
} else {
    Write-Host "  FAIL: Replay XML not created" -ForegroundColor Red
    $failed++
    exit 1
}

# ============================================================
# Phase 3: Replay (fast mode)
# ============================================================
Write-Host ""
Write-Host "--- Phase 3: Replay in fast mode ---" -ForegroundColor Yellow

$replayOutput = Run-SqlSim @("-replay", "fast", "-replayfile", $traceXml, "-q") | Out-String

if ($replayOutput -match "Total Runtime") {
    Write-Host "  PASS: Fast mode replay completed" -ForegroundColor Green
    $passed++
} else {
    Write-Host "  FAIL: Fast mode replay did not complete" -ForegroundColor Red
    $failed++
}

# Check for zero errors
# In non-verbose mode, "Total Errors" only appears if errors > 0
$replayLines = $replayOutput -split "`n"
$totalErrorsLine = $replayLines | Where-Object { $_ -match "Total Errors" } | Select-Object -First 1
if (-not $totalErrorsLine) {
    # No "Total Errors" line means zero errors (non-verbose mode suppresses it when 0)
    Write-Host "  PASS: Zero errors during fast replay" -ForegroundColor Green
    $passed++
} elseif ($totalErrorsLine -match "Total Errors: 0") {
    Write-Host "  PASS: Zero errors during fast replay" -ForegroundColor Green
    $passed++
} else {
    Write-Host "  WARN: Errors during fast replay" -ForegroundColor Yellow
    # Not a failure — some traces may have expected errors
}

# ============================================================
# Phase 4: Replay (stress mode)
# ============================================================
Write-Host ""
Write-Host "--- Phase 4: Replay in stress mode ---" -ForegroundColor Yellow

$stressOutput = Run-SqlSim @("-replay", "stress", "-replayfile", $traceXml, "-n", "2", "-r", "2", "-q") | Out-String

if ($stressOutput -match "Total Runtime") {
    Write-Host "  PASS: Stress mode replay completed (2 threads x 2 iterations)" -ForegroundColor Green
    $passed++
} else {
    Write-Host "  FAIL: Stress mode replay did not complete" -ForegroundColor Red
    $failed++
}

# ============================================================
# Phase 5: Replay fidelity check
# ============================================================
Write-Host ""
Write-Host "--- Phase 5: Replay fidelity verification ---" -ForegroundColor Yellow

# Start replay capture
Write-Host "  Starting replay capture session..." -ForegroundColor Gray
Run-SqlSim @("-app", "sqlsim_admin", "-i", "replay\capture-during-replay.sql", "-q") | Out-Null

# Replay
Write-Host "  Replaying trace (captured by XEvent)..." -ForegroundColor Gray
Run-SqlSim @("-replay", "fast", "-replayfile", $traceXml, "-q") | Out-Null

# Wait + stop
Write-Host "  Waiting for event flush..." -ForegroundColor Gray
Start-Sleep -Seconds 2
Run-SqlSim @("-app", "sqlsim_admin", "-i", "replay\stop-replay-capture.sql", "-q") | Out-Null

# Compare
Write-Host "  Comparing traces..." -ForegroundColor Gray
$compareScript = Join-Path $scriptDir "compare-traces.ps1"
& $compareScript -OriginalXel $originalXel -ReplayXel $replayXel -ServerName $ServerName

if ($LASTEXITCODE -eq 0) {
    Write-Host "  PASS: Replay fidelity verified" -ForegroundColor Green
    $passed++
} else {
    Write-Host "  FAIL: Replay fidelity check failed" -ForegroundColor Red
    $failed++
}

# ============================================================
# Phase 6: JSON output test
# ============================================================
Write-Host ""
Write-Host "--- Phase 6: JSON output ---" -ForegroundColor Yellow

$jsonOutput = Run-SqlSim @("-replay", "fast", "-replayfile", $traceXml, "-json") | Out-String

try {
    $json = $jsonOutput | ConvertFrom-Json
    if ($json.metrics -and $json.configuration.replay_mode -eq "fast") {
        Write-Host "  PASS: JSON output is valid with replay metrics" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "  FAIL: JSON missing expected fields" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "  FAIL: JSON output is not valid JSON" -ForegroundColor Red
    $failed++
}

# ============================================================
# Summary
# ============================================================
$elapsed = (Get-Date) - $startTime

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  RESULTS: $passed passed, $failed failed ($([math]::Round($elapsed.TotalSeconds, 1))s)" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "================================================================" -ForegroundColor Cyan

# Cleanup temp files
Remove-Item $traceXml -ErrorAction SilentlyContinue

exit $failed
