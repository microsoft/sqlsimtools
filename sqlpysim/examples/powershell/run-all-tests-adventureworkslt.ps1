#!/usr/bin/env pwsh
# Run all tests (01-09) on localhost with AdventureWorksLT

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
Write-Host "ALL TESTS - AdventureWorksLT" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# -S localhost = Server name
# -d AdventureWorksLT = Database name
# -E = Windows Authentication
# -C = Trust server certificate
# -i = Input SQL file to execute

$tests = @(
    "01-simple-queries.sql",
    "02-customer-queries-adventureworkslt.sql",
    "03-product-queries-adventureworkslt.sql",
    "04-sales-queries-adventureworkslt.sql",
    "05-aggregation-queries-adventureworkslt.sql",
    "06-complex-joins-adventureworkslt.sql",
    "07-insert-test-adventureworkslt.sql",
    "08-mixed-workload-adventureworkslt.sql",
    "09-reporting-queries-adventureworkslt.sql"
)

$testNum = 1
foreach ($test in $tests) {
    Invoke-Example "Test $testNum`: $test" @('-S', 'localhost', '-d', 'AdventureWorksLT', '-E', '-C', '-i', (Join-Path $PSScriptRoot "..\sql\$test"))
    $testNum++
}

Complete-Examples 'All tests'