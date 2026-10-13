#!/usr/bin/env pwsh
# Run basic AdventureWorksLT tests on localhost

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
Write-Host "BASIC TESTS - AdventureWorksLT" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# First test: Demonstrate localhost default behavior (no -S required)
# -d AdventureWorksLT = Database name
# -E = Windows Authentication
# -C = Trust server certificate
# -i = Input SQL file to execute
Invoke-Example 'Test 1: Localhost default (no -S parameter)' @('-d', 'AdventureWorksLT', '-E', '-C', '-i', (Join-Path $PSScriptRoot '..\sql\01-simple-queries.sql'))

# Remaining tests: Explicit -S localhost
Invoke-Example 'Test 2: Customer queries' @('-S', 'localhost', '-d', 'AdventureWorksLT', '-E', '-C', '-i', (Join-Path $PSScriptRoot '..\sql\02-customer-queries-adventureworkslt.sql'))
Invoke-Example 'Test 3: Product queries' @('-S', 'localhost', '-d', 'AdventureWorksLT', '-E', '-C', '-i', (Join-Path $PSScriptRoot '..\sql\03-product-queries-adventureworkslt.sql'))
Invoke-Example 'Test 4: Sales queries' @('-S', 'localhost', '-d', 'AdventureWorksLT', '-E', '-C', '-i', (Join-Path $PSScriptRoot '..\sql\04-sales-queries-adventureworkslt.sql'))

Complete-Examples 'Basic tests'