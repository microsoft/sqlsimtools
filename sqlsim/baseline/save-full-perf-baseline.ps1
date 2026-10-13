#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Run the full-level performance baseline (3 scenarios) and save results.

.DESCRIPTION
    Matches the full-test-suite.ps1 performance tests. Runs multiple times per
    scenario to get medians, and saves timestamped results to the baseline/ folder.

    Scenarios:
    1. Single-thread SELECT 1 x1000 (pure client overhead, threshold < 5s)
    2. 4-thread SELECT 1 x1000 (multi-thread overhead, threshold < 10s)
    3. 4-thread sys.objects x500 (real data query, threshold < 30s)

.PARAMETER Server
    SQL Server instance (default: localhost)

.PARAMETER Database
    Database name for data query tests (default: tempdb)

.PARAMETER Runs
    Number of runs per scenario for median calculation (default: 3)

.EXAMPLE
    .\baseline\save-full-perf-baseline.ps1
    .\baseline\save-full-perf-baseline.ps1 -Runs 5
#>

param(
    [string]$Server = "localhost",
    [string]$Database = "tempdb",
    [int]$Runs = 5
)

$ErrorActionPreference = "Stop"
$sqlsimPath = "$PSScriptRoot\..\build\x64\Release\sqlsim.exe"

if (-not (Test-Path $sqlsimPath)) {
    Write-Host "ERROR: sqlsim.exe not found at $sqlsimPath. Run build.ps1 first." -ForegroundColor Red
    exit 1
}

$timestamp = Get-Date -Format "yyyy-MM-dd-HHmmss"

# Collect machine configuration
$cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1)
$cpuName = $cpu.Name.Trim()
$cpuCores = $cpu.NumberOfCores
$cpuLogical = $cpu.NumberOfLogicalProcessors
$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
$osVersion = (Get-CimInstance Win32_OperatingSystem).Caption.Trim()
$hostname = $env:COMPUTERNAME

# Get SQL Server version via sqlsim (single lightweight call with -v for version info)
$sqlVerOut = & $sqlsimPath -S $Server -E -Q "SELECT 1" -v -json -q 2>$null
$sqlVerJson = ($sqlVerOut -join "`n" | ConvertFrom-Json)
$sqlEdition = if ($sqlVerJson.server_edition) { $sqlVerJson.server_edition } else { "Unknown" }
$sqlVersion = if ($sqlVerJson.server_version) { $sqlVerJson.server_version } else { "Unknown" }

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "FULL PERFORMANCE BASELINE" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Timestamp : $timestamp" -ForegroundColor White
Write-Host "Server    : $Server" -ForegroundColor White
Write-Host "Hostname  : $hostname" -ForegroundColor White
Write-Host "Database  : $Database" -ForegroundColor White
Write-Host "Runs/test : $Runs" -ForegroundColor White
Write-Host "----------------------------------------" -ForegroundColor Cyan
Write-Host "CPU       : $cpuName" -ForegroundColor White
Write-Host "Cores     : $cpuCores physical / $cpuLogical logical" -ForegroundColor White
Write-Host "RAM       : ${ramGB} GB" -ForegroundColor White
Write-Host "OS        : $osVersion" -ForegroundColor White
Write-Host "SQL Server:" -ForegroundColor White
Write-Host "  $sqlEdition (v$sqlVersion)" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan

function Get-Median([double[]]$values) {
    $sorted = $values | Sort-Object
    $count = $sorted.Count
    if ($count % 2 -eq 0) {
        return ($sorted[$count/2 - 1] + $sorted[$count/2]) / 2
    } else {
        return $sorted[[math]::Floor($count/2)]
    }
}

function Run-PerfScenario {
    param(
        [string]$Name,
        [string[]]$ExeArgs
    )
    Write-Host "Scenario: $Name" -ForegroundColor Yellow
    $times = @()
    foreach ($i in 1..$Runs) {
        $out = & $sqlsimPath @ExeArgs 2>$null
        $json = ($out -join "`n" | ConvertFrom-Json)
        $t = $json.metrics.total_runtime_seconds
        $times += $t
        Write-Host "  Run ${i}: ${t}s" -ForegroundColor Gray
    }
    $median = Get-Median $times
    Write-Host "  Median: ${median}s`n" -ForegroundColor Green
    return @{
        name = $Name
        runs = $times
        median = $median
    }
}

# Scenario 1: Single-threaded SELECT 1 x1000 (pure client overhead)
$s1 = Run-PerfScenario -Name "Single-thread SELECT 1 x1000" `
    -ExeArgs @("-S", $Server, "-d", $Database, "-E", "-q", "-n", "1", "-r", "1000", "-Q", "SELECT 1", "-json")

# Scenario 2: Multi-threaded SELECT 1 x1000 (4 threads = 4000 total)
$s2 = Run-PerfScenario -Name "4-thread SELECT 1 x1000" `
    -ExeArgs @("-S", $Server, "-d", $Database, "-E", "-q", "-n", "4", "-r", "1000", "-Q", "SELECT 1", "-json")

# Scenario 3: Multi-threaded with data (4 threads x 500 iter)
$s3 = Run-PerfScenario -Name "4-thread sys.objects x500" `
    -ExeArgs @("-S", $Server, "-d", $Database, "-E", "-q", "-n", "4", "-r", "500", "-Q", "SELECT TOP 50 * FROM sys.objects", "-json")

$baseline = [ordered]@{
    timestamp = $timestamp
    source = "save-full-perf-baseline"
    machine = [ordered]@{
        hostname = $hostname
        cpu = $cpuName
        cores_physical = $cpuCores
        cores_logical = $cpuLogical
        ram_gb = $ramGB
        os = $osVersion
    }
    server = $Server
    sql_server_edition = $sqlEdition
    sql_server_version = $sqlVersion
    database = $Database
    runs_per_scenario = $Runs
    scenarios = @(
        [ordered]@{ name = $s1.name; median_seconds = $s1.median; threshold = 5.0; runs = $s1.runs }
        [ordered]@{ name = $s2.name; median_seconds = $s2.median; threshold = 10.0; runs = $s2.runs }
        [ordered]@{ name = $s3.name; median_seconds = $s3.median; threshold = 30.0; runs = $s3.runs }
    )
}

$outFile = Join-Path $PSScriptRoot "full-perf-$timestamp.json"
$baseline | ConvertTo-Json -Depth 5 | Set-Content $outFile -Encoding UTF8

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "BASELINE SAVED: $outFile" -ForegroundColor Green
Write-Host ""
Write-Host "Summary:" -ForegroundColor White
foreach ($s in $baseline.scenarios) {
    Write-Host "  $($s.name): $($s.median_seconds)s (threshold: $($s.threshold)s)" -ForegroundColor White
}
Write-Host "========================================" -ForegroundColor Cyan
