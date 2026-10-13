#!/usr/bin/env pwsh
# JSON output format examples
# Demonstrates sqlsim's JSON output mode for programmatic consumption

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
    Write-Host "ERROR: sqlsim.exe not found in the release folder, a source build, or PATH." -ForegroundColor Red
    exit 1
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "JSON OUTPUT FORMAT EXAMPLES" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "Example 1: Basic JSON output" -ForegroundColor Yellow
Write-Host "Command: sqlsim -E -Q `"SELECT 1 AS Value`" -json`n" -ForegroundColor Gray
# -json = Output results in JSON format
# Note: Configuration includes 'batches' array with the actual queries executed
#       This is useful for workload analysis and audit trails
& $exe -E -Q "SELECT 1 AS Value" -json

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Example 2: JSON with multiple batches (GO separator)" -ForegroundColor Yellow
Write-Host "Command: sqlsim -E -Q `"SELECT 1`nGO`nSELECT 2`nGO`nSELECT 3`" -json -q`n" -ForegroundColor Gray
# Multiple batches separated by GO are captured in the 'batches' array
& $exe -E -Q "SELECT 1`nGO`nSELECT 2`nGO`nSELECT 3" -json -q

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Example 3: JSON output with optional features" -ForegroundColor Yellow
Write-Host "Command: sqlsim -E -Q `"SELECT 1`" -json -l 30 -t 60 -app `"MyTestApp`"`n" -ForegroundColor Gray
# -l 30 = Login timeout (shown in configuration because explicitly set)
# -t 60 = Query timeout (shown in configuration because explicitly set)
# -app = Application name (shown in configuration because explicitly set)
& $exe -E -Q "SELECT 1" -json -l 30 -t 60 -app "MyTestApp"

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Example 4: JSON connection test only" -ForegroundColor Yellow
Write-Host "Command: sqlsim -E -json`n" -ForegroundColor Gray
# No -Q or -i = Connection test only mode
# Configuration shows "connection_test_only": true instead of batch counts
& $exe -E -json

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Example 5: JSON with verbose mode (detailed per-thread metrics)" -ForegroundColor Yellow
Write-Host "Command: sqlsim -E -Q `"SELECT @@VERSION`" -json -v -n 2 -r 3`n" -ForegroundColor Gray
# -json -v = JSON output with verbose details
# Adds: connection_string, thread_connections, thread_iterations arrays
# Also adds: connection_operations, query_execution_operations, fetch_operations
& $exe -E -Q "SELECT @@VERSION" -json -v -n 2 -r 3

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Example 6: JSON output to file" -ForegroundColor Yellow
Write-Host "Command: sqlsim -E -Q `"SELECT GETDATE()`" -json -o results.json`n" -ForegroundColor Gray
# -o results.json = Write JSON output to file
& $exe -E -Q "SELECT GETDATE()" -json -o results.json
Write-Host "Output written to results.json" -ForegroundColor Green
Write-Host "File contents:" -ForegroundColor Gray
Get-Content results.json
Remove-Item results.json -ErrorAction SilentlyContinue

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Example 7: Parse JSON in PowerShell" -ForegroundColor Yellow
Write-Host "Command: `$result = sqlsim -E -Q `"SELECT 1`" -json | ConvertFrom-Json`n" -ForegroundColor Gray
# Capture compact JSON output and parse it in PowerShell
$result = & $exe -E -Q "SELECT 1" -json 2>&1 | Out-String | ConvertFrom-Json
Write-Host "Parsed compact JSON object:" -ForegroundColor Green
Write-Host "  Version: $($result.version)"
Write-Host "  Server: $($result.configuration.server)"
Write-Host "  Batches: $($result.configuration.batches -join ', ')"
Write-Host "  Success: $($result.success)"
Write-Host "  Total Runtime: $($result.metrics.total_runtime_seconds) seconds"

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Example 8: Parse verbose JSON for detailed metrics" -ForegroundColor Yellow
Write-Host "Command: `$result = sqlsim -E -Q `"SELECT 1`" -n 5 -r 10 -json -v | ConvertFrom-Json`n" -ForegroundColor Gray
# Capture verbose JSON to access connection_operations, query_execution_operations
$result = & $exe -E -Q "SELECT 1" -n 5 -r 10 -json -v 2>&1 | Out-String | ConvertFrom-Json
Write-Host "Parsed verbose JSON object:" -ForegroundColor Green
Write-Host "  Total Runtime: $($result.metrics.total_runtime_seconds) seconds"
Write-Host "  Connection Metrics (verbose only):"
Write-Host "    Total Connections: $($result.metrics.connection_operations.total)"
Write-Host "    Avg Connection Time: $($result.metrics.connection_operations.avg_connect_time_ms) ms"
Write-Host "  Query Execution Metrics (verbose only):"
Write-Host "    Total Queries: $($result.metrics.query_execution_operations.total)"
Write-Host "    Avg Query Elapsed: $($result.metrics.query_execution_operations.avg_elapsed_ms) ms"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "JSON OUTPUT EXAMPLES COMPLETE" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan
