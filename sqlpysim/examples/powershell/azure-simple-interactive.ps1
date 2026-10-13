#!/usr/bin/env pwsh
# Simple Azure SQL Database example using interactive Microsoft Entra authentication (-A)
# This will prompt for credentials via browser-based device code flow
# For automated scripts, use access tokens (-T) instead (see other Azure examples)

$script = Join-Path $PSScriptRoot "..\..\sqlpysim.py"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "AZURE SQL - INTERACTIVE AUTH EXAMPLES" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# IMPORTANT: Update server name before running!
$server = "myserver.database.windows.net"

Write-Host "Example 1: Simple query with interactive auth" -ForegroundColor Yellow
Write-Host "Command: python sqlpysim.py -S $server -d master -A -Q `"SELECT @@VERSION`"`n" -ForegroundColor Gray
# -S = Azure SQL Server name
# -d master = Database name
# -A = Microsoft Entra Interactive authentication (browser-based)
# -Q = Execute single query
python $script -S $server -d master -A -Q "SELECT @@VERSION"

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Example 2: Run catalog view queries (works on any database)" -ForegroundColor Yellow
Write-Host "Command: python sqlpysim.py -S $server -d master -A -i ..\sql\01-simple-queries.sql`n" -ForegroundColor Gray
# -S = Azure SQL Server name
# -d master = Database name
# -A = Microsoft Entra Interactive authentication (browser-based)
# -i = Input SQL file to execute
python $script -S $server -d master -A -i (Join-Path $PSScriptRoot "..\sql\01-simple-queries.sql")

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Interactive auth examples completed!" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Cyan
