#!/usr/bin/env pwsh
# Simple localhost connection test examples
# Demonstrates sqlpysim's localhost default behavior (matches sqlsim/sqlcmd)

$script = Join-Path $PSScriptRoot "..\..\sqlpysim.py"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "LOCALHOST DEFAULT BEHAVIOR EXAMPLES" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "Example 1: Basic localhost connection (no -S needed)" -ForegroundColor Yellow
Write-Host "Command: python sqlpysim.py -E -C -Q `"SELECT @@VERSION`"`n" -ForegroundColor Gray
# -E = Windows Authentication
# -C = Trust server certificate
# -Q = Execute single query
python $script -E -C -Q "SELECT @@VERSION"

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Example 2: Specify database without server" -ForegroundColor Yellow
Write-Host "Command: python sqlpysim.py -d master -E -C -Q `"SELECT @@SERVERNAME`"`n" -ForegroundColor Gray
# -d master = Database name
# -E = Windows Authentication
# -C = Trust server certificate
# -Q = Execute single query
python $script -d master -E -C -Q "SELECT @@SERVERNAME"

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Example 3: Connection test only (no queries)" -ForegroundColor Yellow
Write-Host "Command: python sqlpysim.py -E -C -v`n" -ForegroundColor Gray
# -E = Windows Authentication
# -C = Trust server certificate
# -v = Verbose mode (show detailed execution phases)
python $script -E -C -v

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Example 4: Run catalog view queries from file" -ForegroundColor Yellow
Write-Host "Command: python sqlpysim.py -E -C -i ..\sql\01-simple-queries.sql`n" -ForegroundColor Gray
# -E = Windows Authentication
# -C = Trust server certificate
# -i = Input SQL file to execute
python $script -E -C -i (Join-Path $PSScriptRoot "..\sql\01-simple-queries.sql")

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Example 5: Multiple iterations on localhost" -ForegroundColor Yellow
Write-Host "Command: python sqlpysim.py -E -C -Q `"SELECT GETDATE()`" -r 5 -q`n" -ForegroundColor Gray
# -E = Windows Authentication
# -C = Trust server certificate
# -Q = Execute single query
# -r 5 = Run 5 iterations
# -q = Quiet mode (suppress result output)
python $script -E -C -Q "SELECT GETDATE()" -r 5 -q

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Example 6: Multi-threaded test" -ForegroundColor Yellow
Write-Host "Command: python sqlpysim.py -E -C -Q `"SELECT 1`" -n 5 -r 10 -q`n" -ForegroundColor Gray
# -n 5 = 5 concurrent threads
# -r 10 = 10 iterations per thread
# -q = Quiet mode
python $script -E -C -Q "SELECT 1" -n 5 -r 10 -q

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "All examples completed!" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Cyan
