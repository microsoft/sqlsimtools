#!/usr/bin/env pwsh
# Basic performance benchmark using sqlpysim
# Compares different thread counts for the same workload

$script = Join-Path $PSScriptRoot "..\..\sqlpysim.py"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "PERFORMANCE BENCHMARK" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$results = @()

# Test configurations: threads, iterations
$configs = @(
    @(1, 100),
    @(2, 50),
    @(5, 20),
    @(10, 10),
    @(20, 5),
    @(50, 2)
)

foreach ($config in $configs) {
    $threads = $config[0]
    $iterations = $config[1]
    $total = $threads * $iterations
    
    Write-Host "Testing: $threads threads x $iterations iterations = $total total executions" -ForegroundColor Yellow
    
    # Run benchmark and capture JSON output
    $output = python $script -E -C -Q "SELECT 1" -n $threads -r $iterations -json -q 2>&1 | Out-String
    
    try {
        $json = $output | ConvertFrom-Json
        $runtime = $json.metrics.total_runtime_seconds
        $rate = [math]::Round($total / $runtime, 2)
        
        Write-Host "  Runtime: $runtime seconds, Rate: $rate executions/second" -ForegroundColor Green
        
        $results += [PSCustomObject]@{
            Threads = $threads
            Iterations = $iterations
            Total = $total
            RuntimeSeconds = $runtime
            ExecutionsPerSecond = $rate
        }
    }
    catch {
        Write-Host "  ERROR: Failed to parse results" -ForegroundColor Red
    }
    
    Write-Host ""
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "BENCHMARK SUMMARY" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
$results | Format-Table -AutoSize

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Benchmark completed!" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Cyan
