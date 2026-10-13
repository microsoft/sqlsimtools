#!/usr/bin/env pwsh
# Run basic AdventureWorksLT tests on Azure SQL Database using access token

$script = Join-Path $PSScriptRoot "..\..\sqlpysim.py"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "AZURE SQL - BASIC TESTS (TOKEN AUTH)" -ForegroundColor Cyan
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

Write-Host "Test 1: Simple queries" -ForegroundColor Yellow
$token | python $script -S $server -d $database -T - -i (Join-Path $PSScriptRoot "..\sql\01-simple-queries.sql")

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Test 2: Customer queries" -ForegroundColor Yellow
$token | python $script -S $server -d $database -T - -i (Join-Path $PSScriptRoot "..\sql\02-customer-queries-adventureworkslt.sql")

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Test 3: Product queries" -ForegroundColor Yellow
$token | python $script -S $server -d $database -T - -i (Join-Path $PSScriptRoot "..\sql\03-product-queries-adventureworkslt.sql")

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Test 4: Sales queries" -ForegroundColor Yellow
$token | python $script -S $server -d $database -T - -i (Join-Path $PSScriptRoot "..\sql\04-sales-queries-adventureworkslt.sql")

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Azure basic tests completed!" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Cyan
