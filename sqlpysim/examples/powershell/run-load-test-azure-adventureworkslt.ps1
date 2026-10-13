#!/usr/bin/env pwsh
# Run load tests against Azure SQL Database using access token

$script = Join-Path $PSScriptRoot "..\..\sqlpysim.py"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "AZURE SQL - LOAD TESTS (TOKEN AUTH)" -ForegroundColor Cyan
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
# -n = Number of concurrent threads
# -r = Iterations per thread
# -q = Quiet mode (suppress result output)

Write-Host "Load Test 1: 1 thread x 50 iterations" -ForegroundColor Yellow
$token | python $script -S $server -d $database -T - -i (Join-Path $PSScriptRoot "..\sql\08-mixed-workload-adventureworkslt.sql") -n 1 -r 50 -q

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Load Test 2: 5 threads x 50 iterations" -ForegroundColor Yellow
$token | python $script -S $server -d $database -T - -i (Join-Path $PSScriptRoot "..\sql\08-mixed-workload-adventureworkslt.sql") -n 5 -r 50 -q

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Load Test 3: 10 threads x 50 iterations" -ForegroundColor Yellow
$token | python $script -S $server -d $database -T - -i (Join-Path $PSScriptRoot "..\sql\08-mixed-workload-adventureworkslt.sql") -n 10 -r 50 -q

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Load Test 4: 25 threads x 50 iterations" -ForegroundColor Yellow
$token | python $script -S $server -d $database -T - -i (Join-Path $PSScriptRoot "..\sql\08-mixed-workload-adventureworkslt.sql") -n 25 -r 50 -q

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Load Test 5: 50 threads x 50 iterations" -ForegroundColor Yellow
$token | python $script -S $server -d $database -T - -i (Join-Path $PSScriptRoot "..\sql\08-mixed-workload-adventureworkslt.sql") -n 50 -r 50 -q

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Azure load tests completed!" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Cyan
