#!/usr/bin/env pwsh

<#
.SYNOPSIS
    AdventureWorksLT Load Test - Progressive concurrency testing
    
.DESCRIPTION
    Runs progressive load tests against AdventureWorksLT database with increasing
    thread counts to measure performance characteristics and find optimal concurrency.
    
    Tests multiple workload patterns:
    - Simple queries (fast, minimal blocking)
    - Mixed workload (realistic OLTP simulation)
    - Complex queries (resource-intensive operations)
    
.PARAMETER ServerName
    SQL Server instance name (default: localhost)
    
.PARAMETER DatabaseName
    Database name (default: AdventureWorksLT)
    
.PARAMETER UseToken
    Access token for Azure SQL/Fabric authentication
    
.PARAMETER SkipBuild
    Skip building sqlsim.exe and use existing executable
    
.PARAMETER WorkloadType
    Type of workload to test: Simple, Mixed, Complex, All (default: Mixed)
    
.PARAMETER MaxThreads
    Maximum thread count to test (default: 100)
    
.EXAMPLE
    .\basic-perf-benchmark-adventureworkslt.ps1
    Run mixed workload test on localhost AdventureWorksLT
    
.EXAMPLE
    .\basic-perf-benchmark-adventureworkslt.ps1 -WorkloadType All -MaxThreads 50
    Run all workload types up to 50 threads
    
.EXAMPLE
    $token = (az account get-access-token --resource https://database.windows.net --query accessToken -o tsv)
    .\basic-perf-benchmark-adventureworkslt.ps1 -ServerName "myserver.database.windows.net" -DatabaseName "AdventureWorksLT" -UseToken $token
    Run against Azure SQL Database with access token
#>

param(
    [string]$ServerName = "localhost",
    [string]$DatabaseName = "AdventureWorksLT",
    [string]$UseToken = "",
    [ValidateSet("Simple", "Mixed", "Complex", "All")]
    [string]$WorkloadType = "Mixed",
    [int]$MaxThreads = 100
)

$ErrorActionPreference = "Stop"

# Detect Azure SQL/Fabric
$IsAzure = $ServerName -match 'database\.windows\.net|database\.fabric\.microsoft\.com'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "ADVENTUREWORKSLT LOAD TEST" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "Target Server: $ServerName"
Write-Host "Target Database: $DatabaseName"
Write-Host "Workload Type: $WorkloadType"
Write-Host "Max Threads: $MaxThreads"
if ($IsAzure) {
    Write-Host "Environment: Azure SQL Database / Fabric SQL" -ForegroundColor Yellow
    if ($UseToken) {
        Write-Host "Authentication: Access Token (Automated)" -ForegroundColor Yellow
    } else {
        Write-Host "Authentication: Microsoft Entra Interactive" -ForegroundColor Yellow
    }
} else {
    Write-Host "Environment: SQL Server (on-premises or local)"
    Write-Host "Authentication: Windows Integrated"
}

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

Write-Host "`nUsing executable: $exe"

# Setup authentication parameters. A token is passed with -T - and piped on
# stdin, so it never appears in the process list.
if ($IsAzure -and $UseToken) {
    $script:BaseAuthArgs = @("-S", $ServerName, "-d", $DatabaseName, "-T", "-")
} elseif ($IsAzure) {
    $script:BaseAuthArgs = @("-S", $ServerName, "-d", $DatabaseName, "-A")
} else {
    $script:BaseAuthArgs = @("-S", $ServerName, "-d", $DatabaseName, "-E")
}

# Helper function to invoke sqlsim with proper auth
function Invoke-Sqlsim {
    param([Parameter(ValueFromRemainingArguments=$true)]$AdditionalArgs)
    $allArgs = $script:BaseAuthArgs + $AdditionalArgs
    # Parameters explained:
    # BaseAuthArgs includes: -S (server), -d (database), auth method (-E/-A/-T)
    # AdditionalArgs typically include:
    #   -i = Input SQL file
    #   -n = Number of threads
    #   -r = Iterations per thread
    #   -q = Quiet mode (suppress result output)
    if ($IsAzure -and $UseToken) {
        $UseToken | & $exe @allArgs
    } else {
        & $exe @allArgs
    }
}

# Workload definitions
$workloads = @{
    "Simple" = @{
        File = (Join-Path $PSScriptRoot "..\sql\01-simple-queries.sql")
        Description = "Simple SELECT queries (low resource usage)"
        Iterations = 100
    }
    "Mixed" = @{
        File = (Join-Path $PSScriptRoot "..\sql\08-mixed-workload-adventureworkslt.sql")
        Description = "Mixed OLTP workload (realistic simulation)"
        Iterations = 50
    }
    "Complex" = @{
        File = (Join-Path $PSScriptRoot "..\sql\09-reporting-queries-adventureworkslt.sql")
        Description = "Complex reporting queries (high resource usage)"
        Iterations = 20
    }
}

# Thread progression - more granular at lower counts
$threadCounts = @(1, 2, 5, 10, 20, 30, 50, 75, 100)
$threadCounts = $threadCounts | Where-Object { $_ -le $MaxThreads }

# Determine which workloads to run
$workloadsToRun = @()
if ($WorkloadType -eq "All") {
    $workloadsToRun = @("Simple", "Mixed", "Complex")
} else {
    $workloadsToRun = @($WorkloadType)
}

# Results storage
$results = @()

# Run tests
foreach ($workloadName in $workloadsToRun) {
    $workload = $workloads[$workloadName]
    
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "WORKLOAD: $workloadName" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Description: $($workload.Description)"
    Write-Host "Query File: $($workload.File)"
    Write-Host "Iterations per thread: $($workload.Iterations)`n"
    
    # Verify file exists
    if (-not (Test-Path $workload.File)) {
        Write-Host "WARNING: Query file not found: $($workload.File)" -ForegroundColor Yellow
        Write-Host "Skipping $workloadName workload`n" -ForegroundColor Yellow
        continue
    }
    
    foreach ($threads in $threadCounts) {
        Write-Host "Testing with $threads thread(s)..." -NoNewline
        
        $startTime = Get-Date
        
        # Run the test
        $args = @('-i', $workload.File, '-n', $threads, '-r', $workload.Iterations, '-q')
        $output = (Invoke-Sqlsim @args 2>&1) | Out-String
        $exitCode = $LASTEXITCODE
        
        $endTime = Get-Date
        $duration = ($endTime - $startTime).TotalSeconds
        
        # Parse output for metrics
        $totalQueries = $threads * $workload.Iterations
        $qps = [math]::Round($totalQueries / $duration, 2)
        
        if ($exitCode -eq 0) {
            Write-Host " PASSED" -ForegroundColor Green
            Write-Host "  Duration: $([math]::Round($duration, 2))s | QPS: $qps | Avg: $([math]::Round($duration * 1000 / $totalQueries, 2))ms/query"
            
            # Extract metrics from output if available
            $totalExecTime = 0
            $totalConnTime = 0
            
            if ($output -match "Total Query Execution Time:\s+([\d.]+)") {
                $totalExecTime = [math]::Round([double]$matches[1] * 1000, 2)
            }
            if ($output -match "Total Connection Time:\s+([\d.]+)") {
                $totalConnTime = [math]::Round([double]$matches[1] * 1000, 2)
            }
            
            $results += [PSCustomObject]@{
                Workload = $workloadName
                Threads = $threads
                Iterations = $workload.Iterations
                TotalQueries = $totalQueries
                Duration = [math]::Round($duration, 2)
                QPS = $qps
                TotalQueryTime = $totalExecTime
                TotalConnTime = $totalConnTime
                Status = "PASSED"
            }
        } else {
            Write-Host " FAILED" -ForegroundColor Red
            Write-Host "  Error output: $output" -ForegroundColor Red
            
            $results += [PSCustomObject]@{
                Workload = $workloadName
                Threads = $threads
                Iterations = $workload.Iterations
                TotalQueries = $totalQueries
                Duration = [math]::Round($duration, 2)
                QPS = 0
                TotalQueryTime = "ERROR"
                TotalConnTime = "ERROR"
                Status = "FAILED"
            }
        }
        
        # Brief pause between tests
        Start-Sleep -Milliseconds 500
    }
}

# Summary Report
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "LOAD TEST SUMMARY" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

foreach ($workloadName in $workloadsToRun) {
    $workloadResults = $results | Where-Object { $_.Workload -eq $workloadName }
    
    if ($workloadResults.Count -eq 0) {
        continue
    }
    
    Write-Host "`n$workloadName Workload Results:" -ForegroundColor Yellow
    Write-Host ("-" * 105)
    Write-Host ("{0,-10} {1,-12} {2,-15} {3,-12} {4,-15} {5,-18} {6,-10}" -f `
        "Threads", "Iterations", "Total Queries", "Duration(s)", "QPS", "Total Query(ms)", "Status")
    Write-Host ("-" * 105)
    
    foreach ($result in $workloadResults) {
        $color = if ($result.Status -eq "PASSED") { "Green" } else { "Red" }
        Write-Host ("{0,-10} {1,-12} {2,-15} {3,-12} {4,-15} {5,-18} {6,-10}" -f `
            $result.Threads, $result.Iterations, $result.TotalQueries, `
            $result.Duration, $result.QPS, $result.TotalQueryTime, $result.Status) -ForegroundColor $color
    }
    
    # Calculate statistics
    $passedResults = $workloadResults | Where-Object { $_.Status -eq "PASSED" }
    if ($passedResults.Count -gt 0) {
        $maxQPS = ($passedResults | Measure-Object -Property QPS -Maximum).Maximum
        $bestThreadCount = ($passedResults | Where-Object { $_.QPS -eq $maxQPS } | Select-Object -First 1).Threads
        
        Write-Host "`nPerformance Summary:" -ForegroundColor Cyan
        Write-Host "  Peak QPS: $maxQPS at $bestThreadCount thread(s)"
        Write-Host "  Tests Passed: $($passedResults.Count)/$($workloadResults.Count)"
        
        # Scaling efficiency
        $baseline = $passedResults | Where-Object { $_.Threads -eq 1 } | Select-Object -First 1
        if ($baseline) {
            $maxThreadResult = $passedResults | Where-Object { $_.Threads -eq $bestThreadCount } | Select-Object -First 1
            $scalingEfficiency = [math]::Round(($maxThreadResult.QPS / $baseline.QPS) / $maxThreadResult.Threads * 100, 1)
            Write-Host "  Scaling Efficiency: $scalingEfficiency% (at peak throughput)"
        }
    }
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "LOAD TEST COMPLETED" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Export results to CSV
$csvFile = "load-test-results-$(Get-Date -Format 'yyyy-MM-dd-HHmmss').csv"
$results | Export-Csv -Path $csvFile -NoTypeInformation
Write-Host "Results exported to: $csvFile" -ForegroundColor Green
