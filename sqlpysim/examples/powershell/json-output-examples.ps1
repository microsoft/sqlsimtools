#!/usr/bin/env pwsh
# JSON output format examples
# Demonstrates sqlpysim's JSON output mode for programmatic consumption

$script = Join-Path $PSScriptRoot "..\..\sqlpysim.py"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "JSON OUTPUT FORMAT EXAMPLES" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "Example 1: Basic JSON output" -ForegroundColor Yellow
Write-Host "Command: python sqlpysim.py -E -C -Q `"SELECT 1 AS Value`" -json`n" -ForegroundColor Gray
# -json = Output results in JSON format
python $script -E -C -Q "SELECT 1 AS Value" -json

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Example 2: JSON with multiple batches (GO separator)" -ForegroundColor Yellow
Write-Host "Command: python sqlpysim.py -E -C -Q `"SELECT 1`nGO`nSELECT 2`nGO`nSELECT 3`" -json -q`n" -ForegroundColor Gray
# Multiple batches separated by GO are captured in the 'batches' array
python $script -E -C -Q "SELECT 1`nGO`nSELECT 2`nGO`nSELECT 3" -json -q

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Example 3: JSON output with optional features" -ForegroundColor Yellow
Write-Host "Command: python sqlpysim.py -E -C -Q `"SELECT 1`" -json -l 30 -t 60`n" -ForegroundColor Gray
# -l 30 = Login timeout
# -t 60 = Query timeout
# -app is not supported: mssql-python reserves the application name.
python $script -E -C -Q "SELECT 1" -json -l 30 -t 60

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Example 4: JSON connection test only" -ForegroundColor Yellow
Write-Host "Command: python sqlpysim.py -E -C -json`n" -ForegroundColor Gray
# No -Q or -i = Connection test only mode
python $script -E -C -json

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Example 5: JSON with verbose mode (detailed metrics)" -ForegroundColor Yellow
Write-Host "Command: python sqlpysim.py -E -C -Q `"SELECT @@VERSION`" -json -v -n 2 -r 3`n" -ForegroundColor Gray
# -json -v = JSON output with verbose details
python $script -E -C -Q "SELECT @@VERSION" -json -v -n 2 -r 3

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Example 6: JSON output to file" -ForegroundColor Yellow
Write-Host "Command: python sqlpysim.py -E -C -Q `"SELECT GETDATE()`" -json -o results.json`n" -ForegroundColor Gray
# -o results.json = Write JSON output to file
python $script -E -C -Q "SELECT GETDATE()" -json -o results.json
Write-Host "Output written to results.json" -ForegroundColor Green
Write-Host "File contents:" -ForegroundColor Gray
Get-Content results.json
Remove-Item results.json -ErrorAction SilentlyContinue

Write-Host "`n----------------------------------------`n" -ForegroundColor Cyan

Write-Host "Example 7: Parse JSON in PowerShell" -ForegroundColor Yellow
Write-Host "Command: `$result = python sqlpysim.py -E -C -Q `"SELECT 1`" -json | ConvertFrom-Json`n" -ForegroundColor Gray
# Capture JSON output and parse it in PowerShell
$result = python $script -E -C -Q "SELECT 1" -json 2>&1 | Out-String | ConvertFrom-Json
Write-Host "Parsed JSON object:" -ForegroundColor Green
Write-Host "  Version: $($result.version)"
Write-Host "  Server: $($result.configuration.server)"
Write-Host "  Success: $($result.success)"
Write-Host "  Total Runtime: $($result.metrics.total_runtime_seconds) seconds"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "JSON examples completed!" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Cyan
