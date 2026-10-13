#!/usr/bin/env pwsh
# Run basic AdventureWorksLT tests with verbose output

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
Write-Host "BASIC TESTS (VERBOSE) - AdventureWorksLT" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# -S localhost = Server name
# -d AdventureWorksLT = Database name
# -E = Windows Authentication
# -C = Trust server certificate
# -i = Input SQL file to execute
# -v = Verbose mode

Invoke-Example 'Test 1: Simple queries (verbose)' @('-S', 'localhost', '-d', 'AdventureWorksLT', '-E', '-C', '-i', (Join-Path $PSScriptRoot '..\sql\01-simple-queries.sql'), '-v')
Invoke-Example 'Test 2: Customer queries (verbose)' @('-S', 'localhost', '-d', 'AdventureWorksLT', '-E', '-C', '-i', (Join-Path $PSScriptRoot '..\sql\02-customer-queries-adventureworkslt.sql'), '-v')
Invoke-Example 'Test 3: Product queries (verbose)' @('-S', 'localhost', '-d', 'AdventureWorksLT', '-E', '-C', '-i', (Join-Path $PSScriptRoot '..\sql\03-product-queries-adventureworkslt.sql'), '-v')
Invoke-Example 'Test 4: Sales queries (verbose)' @('-S', 'localhost', '-d', 'AdventureWorksLT', '-E', '-C', '-i', (Join-Path $PSScriptRoot '..\sql\04-sales-queries-adventureworkslt.sql'), '-v')

Complete-Examples 'Verbose tests'