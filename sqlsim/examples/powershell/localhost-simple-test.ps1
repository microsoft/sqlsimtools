#!/usr/bin/env pwsh
# Simple localhost connection test examples
# Demonstrates sqlsim's localhost default behavior (matches sqlcmd)

# Find sqlsim: the installed release for this machine's architecture, then the
# x64 release (ARM64 Windows can run it), then a source build, then PATH.
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'ARM64' } else { 'x64' }
$searchPaths = @(
    (Join-Path $PSScriptRoot "..\..\$arch\sqlsim.exe"),
    (Join-Path $PSScriptRoot "..\..\x64\sqlsim.exe"),
    (Join-Path $PSScriptRoot "..\..\build\$arch\Release\sqlsim.exe")
)
$exe = $searchPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $exe) { $exe = (Get-Command sqlsim -ErrorAction SilentlyContinue).Source }

if (-not $exe) {
    Write-Host "ERROR: sqlsim.exe not found. Searched:" -ForegroundColor Red
    $searchPaths | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}

$sqlDir = Join-Path $PSScriptRoot "..\sql"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "LOCALHOST DEFAULT BEHAVIOR EXAMPLES" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "Example 1: Basic localhost connection (no -S needed)" -ForegroundColor Yellow
Write-Host "Command: sqlsim -E -Q `"SELECT @@VERSION`"`n" -ForegroundColor Gray
# -E = Windows Authentication
# -Q = Execute single query
& $exe -E -Q "SELECT @@VERSION"

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Example 2: Specify database without server" -ForegroundColor Yellow
Write-Host "Command: sqlsim -d master -E -Q `"SELECT @@SERVERNAME`"`n" -ForegroundColor Gray
# -d master = Database name
# -E = Windows Authentication
# -Q = Execute single query
& $exe -d master -E -Q "SELECT @@SERVERNAME"

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Example 3: Connection test only (no queries)" -ForegroundColor Yellow
Write-Host "Command: sqlsim -E -v`n" -ForegroundColor Gray
# -E = Windows Authentication
# -v = Verbose mode (show detailed execution phases)
& $exe -E -v

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Example 4: Run catalog view queries from file" -ForegroundColor Yellow
Write-Host "Command: sqlsim -E -i sql\01-simple-queries.sql`n" -ForegroundColor Gray
# -E = Windows Authentication
# -i = Input SQL file to execute
& $exe -E -i (Join-Path $sqlDir "01-simple-queries.sql")

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Example 5: Multiple iterations on localhost" -ForegroundColor Yellow
Write-Host "Command: sqlsim -E -Q `"SELECT GETDATE()`" -r 5 -q`n" -ForegroundColor Gray
# -E = Windows Authentication
# -Q = Execute single query
# -r 5 = Run 5 iterations
# -q = Quiet mode (suppress result output)
& $exe -E -Q "SELECT GETDATE()" -r 5 -q

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Example 6: Localhost with multiple threads" -ForegroundColor Yellow
Write-Host "Command: sqlsim -d tempdb -E -Q `"SELECT 1`" -n 4 -r 10 -q`n" -ForegroundColor Gray
# -d tempdb = Database name
# -E = Windows Authentication
# -Q = Execute single query
# -n 4 = Number of concurrent threads
# -r 10 = Iterations per thread (40 total queries)
# -q = Quiet mode (suppress result output)
& $exe -d tempdb -E -Q "SELECT 1" -n 4 -r 10 -q

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "All examples completed!" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Cyan
