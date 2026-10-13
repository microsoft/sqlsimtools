#!/usr/bin/env pwsh
# Run all tests (01-09) on Azure SQL Database using access token

$script = Join-Path $PSScriptRoot "..\..\sqlpysim.py"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "AZURE SQL - ALL TESTS (TOKEN AUTH)" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# IMPORTANT: Update server name before running!
$server = "myserver.database.windows.net"
$database = "AdventureWorksLT"

# Get access token using Azure CLI
Write-Host "Getting access token..." -ForegroundColor Gray
$token = (az account get-access-token --resource https://database.windows.net --query accessToken -o tsv)

if (-not $token) {
    Write-Host "ERROR: Failed to get access token. Make sure you're logged in with 'az login'" -ForegroundColor Red
    exit 1
}
Write-Host "Token acquired successfully" -ForegroundColor Green

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

# -S = Azure SQL Server name
# -d AdventureWorksLT = Database name
# -T - = Access token authentication, read from stdin. Piping $token keeps it out
#        of the process list, where other tools and users could read it.
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
    Write-Host "Test $testNum`: $test" -ForegroundColor Yellow
    $token | python $script -S $server -d $database -T - -i (Join-Path $PSScriptRoot "..\sql\$test")
    Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan
    $testNum++
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Azure all tests completed!" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Cyan
