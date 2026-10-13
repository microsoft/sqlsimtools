#!/usr/bin/env pwsh
# Run load tests against AdventureWorksLT database on localhost

# Paths are resolved from this script's folder, so it runs from any directory.
$script = Join-Path $PSScriptRoot '..\..\sqlpysim.py'
$failed = [System.Collections.Generic.List[string]]::new()

function Invoke-Example {
    param([string]$Title, [string[]]$Arguments)
    Write-Host $Title -ForegroundColor Yellow
    python $script @Arguments
    if ($LASTEXITCODE -ne 0) {
        $failed.Add("$Title (exit code $LASTEXITCODE)")
    }
    Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan
}

function Complete-Examples {
    param([string]$Label)
    Write-Host "========================================" -ForegroundColor Cyan
    if ($failed.Count -eq 0) {
        Write-Host "$Label completed successfully." -ForegroundColor Green
    } else {
        Write-Host "$Label finished with $($failed.Count) failure(s):" -ForegroundColor Red
        $failed | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    }
    Write-Host "========================================`n" -ForegroundColor Cyan
    exit $(if ($failed.Count -eq 0) { 0 } else { 1 })
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "LOAD TESTS - AdventureWorksLT" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# -S localhost = Server name
# -d AdventureWorksLT = Database name
# -E = Windows Authentication
# -C = Trust server certificate
# -i = Input SQL file to execute
# -n = Number of concurrent threads
# -r = Iterations per thread
# -q = Quiet mode (suppress result output)

$workload = Join-Path $PSScriptRoot '..\sql\08-mixed-workload-adventureworkslt.sql'
$loadTest = 1
foreach ($threads in 1, 5, 10, 25, 50) {
    Invoke-Example "Load Test $loadTest`: $threads thread$(if ($threads -gt 1) { 's' }) x 50 iterations" @('-S', 'localhost', '-d', 'AdventureWorksLT', '-E', '-C', '-i', $workload, '-n', "$threads", '-r', '50', '-q')
    $loadTest++
}

Complete-Examples 'Load tests'