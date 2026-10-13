#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Comprehensive test suite for sqlpysim
.DESCRIPTION
    Tests all major functionality including connection modes, parameters, timeouts,
    file parsing, concurrency, error handling, and output validation.
    Aligned with sqlsim's full-test-suite.ps1 test coverage.
.PARAMETER ServerName
    SQL Server name (default: localhost)
.PARAMETER DatabaseName
    Database name (default: master)
.PARAMETER UseToken
    Access token for Azure SQL Database authentication
    The token, like -Password, reaches sqlpysim on stdin (-T -, -P -), so it never
    appears in a process list.
.PARAMETER Username
    SQL username for SQL Authentication
.PARAMETER Password
    SQL password for SQL Authentication
.PARAMETER SkipInstall
    Skip pip install check
.PARAMETER StopOnError
    Stop on first test failure
.PARAMETER Verbose
    Show verbose output (0=normal, 1=detailed)
.EXAMPLE
    .\full-test-suite.ps1
    .\full-test-suite.ps1 -ServerName "myserver.database.windows.net" -DatabaseName "mydb" -UseToken $token
#>

param(
    [string]$ServerName = "localhost",
    [string]$DatabaseName = "master",
    [string]$UseToken = "",
    [string]$Username = "",
    [string]$Password = "",
    [switch]$SkipInstall,
    [switch]$StopOnError,
    [int]$Verbose = 0
)

$ErrorActionPreference = "Stop"
$script:testsPassed = 0
$script:testsFailed = 0
$script:testsSkipped = 0
$startTime = Get-Date

$scriptPath = Join-Path $PSScriptRoot "sqlpysim.py"
$testDir = Join-Path $PSScriptRoot "testing"

# Verify sqlpysim.py exists
if (-not (Test-Path $scriptPath)) {
    Write-Host "ERROR: sqlpysim.py not found at $scriptPath" -ForegroundColor Red
    exit 1
}

# Create testing directory
New-Item -Path $testDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

# Check Python and mssql-python
if (-not $SkipInstall) {
    Write-Host "Checking mssql-python driver..." -ForegroundColor Cyan
    python -c "import mssql_python" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Installing mssql-python..." -ForegroundColor Yellow
        pip install mssql-python
    } else {
        Write-Host "  ✓ mssql-python installed" -ForegroundColor Green
    }
}

# Auto-detect Azure
$IsAzure = $ServerName -match 'database\.windows\.net|database\.fabric\.microsoft\.com'

# Set authentication
$script:AuthSecret = $null
if ($Username -and $Password) {
    $script:BaseAuthArgs = @("-S", $ServerName, "-d", $DatabaseName, "-U", $Username, "-P", "-")
    $script:AuthSecret = $Password
    # Non-Azure targets commonly present a self-signed certificate.
    if (-not $IsAzure) { $script:BaseAuthArgs += "-C" }
    $AuthMethod = "SQL Authentication"
} elseif ($UseToken) {
    $script:BaseAuthArgs = @("-S", $ServerName, "-d", $DatabaseName, "-T", "-")
    $script:AuthSecret = $UseToken
    $AuthMethod = "Access Token"
} elseif ($IsAzure) {
    $script:BaseAuthArgs = @("-S", $ServerName, "-d", $DatabaseName, "-A")
    $AuthMethod = "Microsoft Entra Interactive"
} else {
    $script:BaseAuthArgs = @("-S", $ServerName, "-d", $DatabaseName, "-E", "-C")
    $AuthMethod = "Windows Integrated"
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "SQLPYSIM FULL TEST SUITE" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Server: $ServerName" -ForegroundColor White
Write-Host "Database: $DatabaseName" -ForegroundColor White
Write-Host "Environment: $(if ($IsAzure) { 'Azure SQL Database' } else { 'SQL Server' })" -ForegroundColor White
Write-Host "Authentication: $AuthMethod" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan

# Runs sqlpysim, writing the secret to stdin when the arguments ask for it with
# -T - or -P -, so the token or password never appears in a process list.
# Input piped by the caller is passed through unchanged.
$script:EngineScript = $scriptPath
$runSqlPySim = {
    $engineArgs = @(foreach ($a in $args) { $a })
    $readsSecret = $false
    for ($i = 0; $i -lt $engineArgs.Count - 1; $i++) {
        if ($engineArgs[$i] -cin '-T', '-P' -and $engineArgs[$i + 1] -eq '-') { $readsSecret = $true }
    }
    if ($MyInvocation.ExpectingInput) { $input | python $script:EngineScript @engineArgs }
    elseif ($readsSecret -and $null -ne $script:AuthSecret) { $script:AuthSecret | python $script:EngineScript @engineArgs }
    else { python $script:EngineScript @engineArgs }
}

function Invoke-SqlPySim {
    $allArgs = $script:BaseAuthArgs + $args
    & $runSqlPySim @allArgs
}

# The suite uses only portable T-SQL, so it never changes the target
# database's compatibility level or any other persistent setting.

function Test-Command {
    param(
        [string]$Name,
        [string]$Description,
        [scriptblock]$Command,
        [string]$ExpectedOutput = $null,
        [string]$ExpectedError = $null,
        [bool]$ShouldFail = $false
    )
    
    Write-Host "TEST: $Name" -ForegroundColor Yellow
    Write-Host "  Description: $Description" -ForegroundColor Gray
    
    try {
        $resultArray = & $Command 2>&1
        $output = $resultArray -join "`n"
        $exitCode = $LASTEXITCODE
        
        $passed = $true
        
        if ($ShouldFail) {
            if ($exitCode -eq 0) {
                Write-Host "  FAILED: Expected non-zero exit code but got 0" -ForegroundColor Red
                $passed = $false
            }
        } else {
            if ($exitCode -ne 0) {
                Write-Host "  FAILED: Exit code $exitCode" -ForegroundColor Red
                $passed = $false
            }
        }
        
        if ($passed -and $ExpectedOutput -and $output -notmatch $ExpectedOutput) {
            Write-Host "  FAILED: Output didn't contain expected: $ExpectedOutput" -ForegroundColor Red
            $passed = $false
        }
        
        if ($passed -and $ExpectedError -and $output -notmatch $ExpectedError) {
            Write-Host "  FAILED: Output didn't contain expected error: $ExpectedError" -ForegroundColor Red
            $passed = $false
        }
        
        if ($passed) {
            Write-Host "  PASSED" -ForegroundColor Green
            $script:testsPassed++
        } else {
            if ($Verbose -ge 1) {
                Write-Host "  Output: $($output.Substring(0, [Math]::Min(300, $output.Length)))" -ForegroundColor DarkGray
            }
            $script:testsFailed++
            if ($StopOnError) { exit 1 }
        }
    }
    catch {
        if ($ShouldFail) {
            Write-Host "  PASSED (expected failure)" -ForegroundColor Green
            $script:testsPassed++
        } else {
            Write-Host "  FAILED: Exception - $_" -ForegroundColor Red
            $script:testsFailed++
            if ($StopOnError) { exit 1 }
        }
    }
    Write-Host ""
}

function Test-Condition {
    param(
        [string]$Name,
        [string]$Description,
        [bool]$Condition
    )
    
    Write-Host "TEST: $Name" -ForegroundColor Yellow
    Write-Host "  Description: $Description" -ForegroundColor Gray
    
    if ($Condition) {
        Write-Host "  PASSED" -ForegroundColor Green
        $script:testsPassed++
    } else {
        Write-Host "  FAILED" -ForegroundColor Red
        $script:testsFailed++
        if ($StopOnError) { exit 1 }
    }
    Write-Host ""
}

# ========================================
# BASIC FUNCTIONALITY TESTS
# ========================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "BASIC FUNCTIONALITY TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Test-Command -Name "Help Display" -Description "Verify help text is shown" `
    -Command { & $runSqlPySim -h } `
    -ExpectedOutput "usage:"

Test-Command -Name "Version Display" -Description "Show version information" `
    -Command { & $runSqlPySim --version } `
    -ExpectedOutput "sqlpysim"

Test-Command -Name "No Arguments" -Description "Run without arguments shows error" `
    -Command { & $runSqlPySim } `
    -ShouldFail $true

Test-Command -Name "Simple Query" -Description "Execute simple query" `
    -Command { Invoke-SqlPySim -Q "SELECT 1" -q } `
    -ExpectedOutput "Total Runtime:"

Test-Command -Name "Default Localhost" -Description "Connect without explicit -S" `
    -Command { & $runSqlPySim -E -C -d master -Q "SELECT 1" -q } `
    -ExpectedOutput "Total Runtime:"

Test-Command -Name "Verbose Output" -Description "Verify verbose mode shows phases" `
    -Command { Invoke-SqlPySim -Q "SELECT 1" -v -q } `
    -ExpectedOutput "\[PHASE"

Test-Command -Name "Batch Terminology" -Description "Output uses 'batches' not 'queries'" `
    -Command { Invoke-SqlPySim -Q "SELECT 1" -q } `
    -ExpectedOutput "Batches in workload"

Test-Command -Name "Multiple Iterations" -Description "Run 5 iterations with 2 threads" `
    -Command { Invoke-SqlPySim -Q "SELECT 1" -n 2 -r 5 -q } `
    -ExpectedOutput "Total Runtime:"

# ========================================
# FILE PARSING TESTS
# ========================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "FILE PARSING TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$testFile = Join-Path $testDir "test_queries.sql"
@"
SELECT 1 AS Test1
GO
SELECT 2 AS Test2
GO
SELECT 3 AS Test3
"@ | Out-File -FilePath $testFile -Encoding UTF8

Test-Command -Name "File Parsing" -Description "Parse and execute queries from file" `
    -Command { Invoke-SqlPySim -i $testFile -q } `
    -ExpectedOutput "Batches in workload: 3"

Test-Command -Name "Query And File Are Mutually Exclusive" `
    -Description "Match sqlsim validation for -Q combined with -i" `
    -Command { Invoke-SqlPySim -Q "SELECT 1" -i $testFile -q } `
    -ExpectedError "Cannot use -Q with -i" `
    -ShouldFail $true

Remove-Item $testFile -ErrorAction SilentlyContinue

# ========================================
# TIMEOUT TESTS
# ========================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "TIMEOUT TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Test-Command -Name "Login Timeout (Invalid Server)" -Description "Verify timeout on invalid server" `
    -Command { & $runSqlPySim -S "invalid-server-12345.example.com" -E -C -l 2 -Q "SELECT 1" -q } `
    -ShouldFail $true

# ========================================
# PARAMETER VALIDATION TESTS
# ========================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "PARAMETER VALIDATION TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Test-Command -Name "Invalid Thread Count (Zero)" -Description "Reject thread count = 0" `
    -Command { Invoke-SqlPySim -Q "SELECT 1" -n 0 } `
    -ShouldFail $true

Test-Command -Name "Invalid Iteration Count" -Description "Reject zero iterations" `
    -Command { Invoke-SqlPySim -Q "SELECT 1" -r 0 } `
    -ShouldFail $true

# ========================================
# AUTHENTICATION TESTS
# ========================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "AUTHENTICATION TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Test-Command -Name "Missing Authentication" -Description "Reject missing auth method" `
    -Command { & $runSqlPySim -S localhost -Q "SELECT 1" } `
    -ExpectedError "Must specify authentication" `
    -ShouldFail $true

if (-not $IsAzure -and -not $UseToken) {
    Test-Command -Name "Windows Auth Query" -Description "Execute with Windows Auth" `
        -Command { & $runSqlPySim -S localhost -E -C -Q "SELECT 1" -q } `
        -ExpectedOutput "Total Runtime:"
}

# ========================================
# CONNECTION STRING TESTS
# ========================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "CONNECTION STRING TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

if (-not $UseToken -and -not $IsAzure) {
    Test-Command -Name "Connection String Mode" -Description "Execute using -c connection string" `
        -Command { & $runSqlPySim -c "Server=localhost;Trusted_Connection=yes;TrustServerCertificate=yes" -Q "SELECT 1" -q } `
        -ExpectedOutput "Total Runtime:"
} else {
    Write-Host "TEST: Connection String Mode" -ForegroundColor Yellow
    Write-Host "  SKIPPED: Not applicable for token/Azure auth" -ForegroundColor Yellow
    $script:testsSkipped++
    Write-Host ""
}

Test-Command -Name "Connection String And Components Are Mutually Exclusive" `
    -Description "Reject -c combined with server, database, or authentication components" `
    -Command {
        & $runSqlPySim -c "Server=localhost;Trusted_Connection=yes;TrustServerCertificate=yes" `
            -S localhost -Q "SELECT 1" -q
    } `
    -ExpectedError "Cannot use both -c and -S/-d/-E/-A/-T/-U/-P options" `
    -ShouldFail $true

Test-Command -Name "Authentication Methods Are Mutually Exclusive" `
    -Description "Reject mixed authentication methods with the sqlsim diagnostic" `
    -Command {
        & $runSqlPySim -S localhost -E -T "0123456789" -Q "SELECT 1" -q
    } `
    -ExpectedError "Cannot mix authentication methods \(-E, -A, -T, -U/-P\)" `
    -ShouldFail $true

# ========================================
# ENCRYPTION TESTS
# ========================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "ENCRYPTION TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Test-Command -Name "Trust Server Certificate" -Description "Connect with -C flag" `
    -Command { Invoke-SqlPySim -Q "SELECT 1" -q } `
    -ExpectedOutput "Total Runtime:"

Test-Command -Name "Invalid Encryption Level" -Description "Reject unsupported -N values" `
    -Command { Invoke-SqlPySim -N x -Q "SELECT 1" -q } `
    -ExpectedError "Invalid encryption level 'x'.*Valid options: o.*m.*s" `
    -ShouldFail $true

# ========================================
# CONCURRENCY TESTS
# ========================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "CONCURRENCY TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Test-Command -Name "Low Concurrency (5 threads)" -Description "5 threads x 10 iterations" `
    -Command { Invoke-SqlPySim -Q "SELECT 1" -n 5 -r 10 -q } `
    -ExpectedOutput "Total Runtime:"

Test-Command -Name "Medium Concurrency (25 threads)" -Description "25 threads x 10 iterations" `
    -Command { Invoke-SqlPySim -Q "SELECT 1" -n 25 -r 10 -q } `
    -ExpectedOutput "Total Runtime:"

Test-Command -Name "High Concurrency (50 threads)" -Description "50 threads x 5 iterations" `
    -Command { Invoke-SqlPySim -Q "SELECT 1" -n 50 -r 5 -q } `
    -ExpectedOutput "Total Runtime:"

Test-Command -Name "Reconnect Mode" -Description "Reconnect after each iteration" `
    -Command { Invoke-SqlPySim -Q "SELECT 1" -n 3 -r 3 -reconnect -q } `
    -ExpectedOutput "Total Runtime:"

Test-Command -Name "Connection Pooling Without Reconnect" `
    -Description "Match sqlsim validation that -usepool requires -reconnect" `
    -Command { Invoke-SqlPySim -Q "SELECT 1" -usepool -q } `
    -ExpectedError "-usepool requires -reconnect" `
    -ShouldFail $true

$connectionIdQuery = "SELECT connection_id FROM sys.dm_exec_connections WHERE session_id = @@SPID"
$pooledOutput = (Invoke-SqlPySim -Q $connectionIdQuery -r 3 -reconnect -usepool | Out-String)
$pooledIds = @([regex]::Matches(
    $pooledOutput,
    '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
) | ForEach-Object Value | Select-Object -Unique)
Test-Condition -Name "Connection Pooling Reuses Physical Connection" `
    -Description "-usepool returns the same connection_id across reconnect cycles" `
    -Condition ($pooledIds.Count -eq 1)

$unpooledOutput = (Invoke-SqlPySim -Q $connectionIdQuery -r 3 -reconnect | Out-String)
$unpooledIds = @([regex]::Matches(
    $unpooledOutput,
    '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
) | ForEach-Object Value | Select-Object -Unique)
Test-Condition -Name "Connection Pooling Is Off By Default" `
    -Description "Reconnect creates distinct physical connections without -usepool" `
    -Condition ($unpooledIds.Count -eq 3)

# ========================================
# ERROR HANDLING TESTS
# ========================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "ERROR HANDLING TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Test-Command -Name "SQL Error Detection" -Description "Detect invalid object error" `
    -Command { Invoke-SqlPySim -Q "SELECT * FROM nonexistent_table_xyz" -q } `
    -ShouldFail $true

Test-Command -Name "Invalid Server" -Description "Handle connection failure" `
    -Command { & $runSqlPySim -S "invalid.server.name" -E -C -Q "SELECT 1" -q } `
    -ShouldFail $true

# ========================================
# GO BATCH SEPARATOR TESTS
# ========================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "GO BATCH SEPARATOR TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$goBatchFile = Join-Path $testDir "go_batch_test.sql"
@"
SELECT 1 AS Batch1
GO
SELECT 2 AS Batch2
GO
SELECT 3 AS Batch3
GO
SELECT 4 AS Batch4
GO
SELECT 5 AS Batch5
"@ | Out-File -FilePath $goBatchFile -Encoding UTF8

Test-Command -Name "Multiple GO Batches" -Description "Parse 5 GO-separated batches" `
    -Command { Invoke-SqlPySim -i $goBatchFile -q } `
    -ExpectedOutput "Batches in workload: 5"

Remove-Item $goBatchFile -ErrorAction SilentlyContinue

Test-Command -Name "GO in Query String" -Description "GO separator in -Q parameter" `
    -Command { Invoke-SqlPySim -Q "SELECT 1`nGO`nSELECT 2" -q } `
    -ExpectedOutput "Batches in workload: 2"

# ========================================
# OUTPUT FORMAT TESTS
# ========================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "OUTPUT FORMAT TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Test-Command -Name "Timestamp Format" -Description "Verify timestamp in output" `
    -Command { Invoke-SqlPySim -Q "SELECT 1" -q } `
    -ExpectedOutput "\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}"

Test-Command -Name "Text Summary Parity" -Description "Match sqlsim summary headings and timing fields" `
    -Command { Invoke-SqlPySim -Q "SELECT 1" -q } `
    -ExpectedOutput "Performance Metric Summary[\s\S]*Start Time: [\d-]+T[\d:.]+[\s\S]*End Time:\s+[\d-]+T[\d:.]+[\s\S]*Avg Connect Time:[\s\S]*Avg Elapsed:"

Test-Command -Name "JSON Output Valid" -Description "Verify valid JSON output" `
    -Command { Invoke-SqlPySim -Q "SELECT 1" -json } `
    -ExpectedOutput '"version"'

Test-Command -Name "JSON Has Configuration" -Description "JSON includes configuration section" `
    -Command { Invoke-SqlPySim -Q "SELECT 1" -json } `
    -ExpectedOutput '"configuration"'

Test-Command -Name "JSON Has Metrics" -Description "JSON includes metrics section" `
    -Command { Invoke-SqlPySim -Q "SELECT 1" -json } `
    -ExpectedOutput '"metrics"'

$queryStatsFile = Join-Path $testDir "querystats.json"
Test-Command -Name "Querystats JSON" -Description "Collect sqlsim-compatible per-query statistics" `
    -Command { Invoke-SqlPySim -Q "SELECT TOP 5 name FROM sys.objects ORDER BY object_id" -querystats -json -q -r 3 -o $queryStatsFile }

if (Test-Path $queryStatsFile) {
    $queryStatsDocument = Get-Content $queryStatsFile -Raw | ConvertFrom-Json
    $queryStatsQuery = @($queryStatsDocument.query_stats.queries)[0]
    Test-Condition -Name "Querystats Executions" -Description "Reports three successful executions" `
        -Condition ($queryStatsQuery.executions -eq 3 -and $queryStatsQuery.failures -eq 0)
    Test-Condition -Name "Querystats Logical Reads" -Description "Reports deterministic logical reads" `
        -Condition ($queryStatsQuery.logical_reads.avg -gt 0)
    Test-Condition -Name "Querystats Totals" -Description "Per-query totals agree with summary totals" `
        -Condition ($queryStatsDocument.query_stats.totals.logical_reads -eq ($queryStatsQuery.logical_reads.avg * $queryStatsQuery.executions))
    Test-Condition -Name "Querystats SPIDs" -Description "Reports the one SQL Server SPID that ran the query, as sqlsim does" `
        -Condition (@($queryStatsQuery.spids).Count -eq 1 -and $queryStatsQuery.spid_count -eq 1 -and $queryStatsQuery.spids[0] -gt 0)
    Remove-Item $queryStatsFile -ErrorAction SilentlyContinue
}

$jsonFile = Join-Path $testDir "output.json"
Test-Command -Name "JSON to File" -Description "Write JSON output to file" `
    -Command { Invoke-SqlPySim -Q "SELECT 1" -json -o $jsonFile }

# Verify JSON file is valid
if (Test-Path $jsonFile) {
    $jsonContent = Get-Content $jsonFile -Raw
    $isValidJson = $false
    $hasSharedSchema = $false
    try {
        $jsonDocument = $jsonContent | ConvertFrom-Json
        $isValidJson = $true
        $hasSharedSchema = $jsonDocument.configuration.odbc_driver -eq "mssql-python" -and
            $null -ne $jsonDocument.metrics.odbc_driver_version -and
            $null -ne $jsonDocument.metrics.warnings.list -and
            -not [string]::IsNullOrWhiteSpace($jsonDocument.server_edition) -and
            -not [string]::IsNullOrWhiteSpace($jsonDocument.server_version)
    } catch {}
    Test-Condition -Name "JSON File Valid" -Description "Output file contains valid JSON" -Condition $isValidJson
    Test-Condition -Name "JSON Shared Schema" -Description "Uses sqlsim driver and warning field names" -Condition $hasSharedSchema
    Remove-Item $jsonFile -ErrorAction SilentlyContinue
}

# ========================================
# VERBOSE MODE TESTS
# ========================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "VERBOSE MODE TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Test-Command -Name "Verbose Phase 1" -Description "Shows configuration phase" `
    -Command { Invoke-SqlPySim -Q "SELECT 1" -v -q } `
    -ExpectedOutput "PHASE 1"

Test-Command -Name "Verbose Phase 5" -Description "Shows completion phase" `
    -Command { Invoke-SqlPySim -Q "SELECT 1" -v -q } `
    -ExpectedOutput "PHASE 5"

Test-Command -Name "Verbose Connection String" -Description "Shows connection string" `
    -Command { Invoke-SqlPySim -Q "SELECT 1" -v -q } `
    -ExpectedOutput "Connection String:"

Test-Command -Name "Verbose Metrics" -Description "Shows percentile metrics" `
    -Command { Invoke-SqlPySim -Q "SELECT 1" -n 5 -r 10 -v -q } `
    -ExpectedOutput "P50 Latency"

Test-Command -Name "Verbose Credential Redaction" -Description "Masks password, token, and connection-string credentials in command display" `
    -Command {
        $redactionScript = @'
import importlib.util
import pathlib
import sys

module_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("sqlpysim_script", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

cases = [
    (["sqlpysim.py", "-U", "user-secret", "-P", "password-secret", "-T", "token-secret", "-t", "30"],
     "sqlpysim.py -U ******** -P ******** -T ******** -t 30"),
    (["sqlpysim.py", "-c", "Server=x;UID=user-secret;PWD=password-secret;Encrypt=yes"],
     "sqlpysim.py -c Server=x;UID=********;PWD=********;Encrypt=yes"),
]
raise SystemExit(0 if all(module.mask_command_line(args) == expected for args, expected in cases) else 1)
'@
        $redactionScript | python - $scriptPath
    }

# ========================================
# QUIET MODE TESTS
# ========================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "QUIET MODE TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Test-Command -Name "Quiet Suppresses Results" -Description "No row output in quiet mode" `
    -Command { Invoke-SqlPySim -Q "SELECT 1 AS ShouldNotShow" -q } `
    -ExpectedOutput "Total Runtime:"

# ========================================
# CONNECTION TEST ONLY
# ========================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "CONNECTION TEST ONLY" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Test-Command -Name "Connection Test Only" -Description "No query, just test connection" `
    -Command { Invoke-SqlPySim } `
    -ExpectedOutput "Connection test"

Test-Command -Name "Connection Test JSON" -Description "Connection test with JSON output" `
    -Command { Invoke-SqlPySim -json } `
    -ExpectedOutput "connection_test_only"

# ========================================
# RESULT SET TESTS
# ========================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "RESULT SET TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Test-Command -Name "Single Column Result" -Description "Display single column" `
    -Command { Invoke-SqlPySim -Q "SELECT 1 AS SingleCol" } `
    -ExpectedOutput "SingleCol"

Test-Command -Name "Multiple Column Result" -Description "Display multiple columns" `
    -Command { Invoke-SqlPySim -Q "SELECT 1 AS A, 2 AS B, 3 AS C" } `
    -ExpectedOutput "row.*affected"

Test-Command -Name "Multiple Rows" -Description "Display multiple rows" `
    -Command { Invoke-SqlPySim -Q "SELECT v.value FROM (VALUES (1), (2), (3), (4), (5)) AS v(value)" } `
    -ExpectedOutput "5 row.*affected"

# Every execution prints its own result set, as sqlsim does. Printing only the
# first thread's first iteration made a run of many executions look like one,
# and hid whether later executions returned anything at all.
Test-Command -Name "Result Set Per Execution" -Description "Every execution prints a result set, not just the first" `
    -Command {
        $output = Invoke-SqlPySim -Q "SELECT 1 AS PerExecution" -n 4 -r 2 | Out-String
        $sets = ([regex]::Matches($output, "1 row\(s\) affected")).Count
        if ($sets -eq 8) {
            "Printed 8 result sets for 8 executions"
        } else {
            throw "Expected 8 result sets for 4 connections x 2 iterations, saw $sets"
        }
    } `
    -ExpectedOutput "Printed 8 result sets"

# Concurrent threads each print whole result sets, so each one is written under
# a single lock. Without that, one thread's rows appear inside another's.
Test-Command -Name "Result Sets Do Not Interleave" -Description "Concurrent result sets stay intact" `
    -Command {
        $output = Invoke-SqlPySim -Q "SELECT v.value FROM (VALUES (1), (2), (3)) AS v(value)" -n 6 -r 2 | Out-String
        $lines = ($output -split "`n") | ForEach-Object { ($_ -replace '^\S+ \S+ \| ', '').TrimEnd() }
        $headers = 0
        $malformed = 0
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -ne 'value') { continue }
            $headers++
            if ($lines[$i + 1] -notmatch '^-{80}$') { $malformed++; continue }
            foreach ($offset in 2..4) {
                if ($lines[$i + $offset] -notmatch '^\d+$') { $malformed++ }
            }
        }
        if ($headers -eq 12 -and $malformed -eq 0) {
            "12 result sets, none interleaved"
        } else {
            throw "Expected 12 intact result sets, saw $headers headers with $malformed malformed lines"
        }
    } `
    -ExpectedOutput "none interleaved"

# Every failing execution reports. Printing only the first thread's error left
# a run stating it had several errors while showing one message, which hides
# the case where threads fail for different reasons.
#
# Test-Condition rather than Test-Command: the query is meant to fail, and
# Test-Command with -ShouldFail treats any exception, including an assertion
# of its own, as the expected failure.
$parityErrorOutput = Invoke-SqlPySim -Q "SELECT * FROM dbo.NoSuchTableForParityTest" -n 4 -r 1 2>&1 | Out-String
$parityErrorCount = ([regex]::Matches($parityErrorOutput, "Invalid object name")).Count
Test-Condition -Name "Error Text Per Failure" `
    -Description "Every failing execution prints its error (expected 4, saw $parityErrorCount)" `
    -Condition ($parityErrorCount -eq 4)

Test-Command -Name "Quiet Mode Still Suppresses Rows" -Description "-q suppresses result sets from every thread" `
    -Command {
        $output = Invoke-SqlPySim -Q "SELECT 1 AS Suppressed" -n 4 -r 2 -q | Out-String
        $sets = ([regex]::Matches($output, "row\(s\) affected")).Count
        if ($sets -eq 0) {
            "No result sets printed in quiet mode"
        } else {
            throw "Expected no result sets with -q, saw $sets"
        }
    } `
    -ExpectedOutput "No result sets printed"

# A query that matches nothing still returned a result set. Skipping it left
# the user unable to tell an empty result from a statement that never ran.
Test-Command -Name "Empty Result Set Reported" -Description "A query matching no rows still prints its header and count" `
    -Command { Invoke-SqlPySim -Q "SELECT name FROM sys.objects WHERE 1 = 0" } `
    -ExpectedOutput "0 row\(s\) affected"

# ========================================
# WORKLOAD FILE TESTS
# ========================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "WORKLOAD FILE TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$workloadDir = Join-Path ([IO.Path]::GetTempPath()) ("sqlpysim-workload-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workloadDir -Force | Out-Null

$singleGroupFile = Join-Path $workloadDir 'single.json'
'{ "workloads": [ { "queries": ["SELECT 1 AS G1"], "threads": 2, "iterations": 3 } ] }' |
    Set-Content -LiteralPath $singleGroupFile -Encoding UTF8

# Comments are part of the format sqlsim accepts, and strict JSON rejects them.
$commentedFile = Join-Path $workloadDir 'commented.json'
@'
{
    // Two groups of differing shape.
    "workloads": [
        { "queries": ["SELECT 1 AS A"], "threads": 2, "iterations": 2 },
        { "queries": ["SELECT 2 AS B", "SELECT 3 AS C"], "threads": 1, "iterations": 3 }
    ]
}
'@ | Set-Content -LiteralPath $commentedFile -Encoding UTF8

$durationFile = Join-Path $workloadDir 'duration.json'
'{ "duration_seconds": 2, "workloads": [ { "queries": ["SELECT 1 AS D"], "threads": 2 } ] }' |
    Set-Content -LiteralPath $durationFile -Encoding UTF8

$thinkFile = Join-Path $workloadDir 'think.json'
'{ "workloads": [ { "queries": ["SELECT 1 AS T"], "threads": 1, "iterations": 5, "think_time_ms": 200 } ] }' |
    Set-Content -LiteralPath $thinkFile -Encoding UTF8

Test-Command -Name "Workload Single Group" -Description "Runs a one-group workload file" `
    -Command { Invoke-SqlPySim -workload $singleGroupFile -q } `
    -ExpectedOutput "Workload groups: 1"

Test-Command -Name "Workload Thread Count From Groups" -Description "Thread count is the sum of the groups, not -n" `
    -Command { Invoke-SqlPySim -workload $commentedFile -q } `
    -ExpectedOutput "Threads: 3"

Test-Command -Name "Workload Total Batches" -Description "Total batches multiplies threads, iterations and batches per group" `
    -Command { Invoke-SqlPySim -workload $commentedFile -q } `
    -ExpectedOutput "Total batches to execute: 10"

Test-Command -Name "Workload Comments Accepted" -Description "A workload file with // comments parses" `
    -Command { Invoke-SqlPySim -workload $commentedFile -q } `
    -ExpectedOutput "Workload groups: 2"

Test-Command -Name "Workload JSON Output" -Description "JSON reports the workload file and its group count" `
    -Command { Invoke-SqlPySim -workload $commentedFile -q -json } `
    -ExpectedOutput '"workload_groups": 2'

Test-Command -Name "Workload Duration Mode" -Description "duration_seconds replaces the iteration count" `
    -Command { Invoke-SqlPySim -workload $durationFile -q } `
    -ExpectedOutput "Duration: 2 seconds"

# Think time is the one setting whose effect is only visible in the clock.
Test-Command -Name "Workload Think Time Delays" -Description "Five iterations at 200 ms think take at least a second" `
    -Command {
        $output = Invoke-SqlPySim -workload $thinkFile -q -json | Out-String
        $runtime = ($output | ConvertFrom-Json).metrics.total_runtime_seconds
        if ($runtime -ge 0.9) {
            "Think time applied: ${runtime}s"
        } else {
            throw "Expected at least 0.9s from 5 iterations at 200ms think, saw ${runtime}s"
        }
    } `
    -ExpectedOutput "Think time applied"

Test-Command -Name "Workload Rejects Missing Key" -Description "A file without a workloads key is refused" `
    -Command {
        $bad = Join-Path $workloadDir 'nokey.json'
        '{ "duration_seconds": 3 }' | Set-Content -LiteralPath $bad -Encoding UTF8
        Invoke-SqlPySim -workload $bad -q 2>&1
    } `
    -ShouldFail $true `
    -ExpectedError 'workloads.*required'

Test-Command -Name "Workload Rejects Both Sources" -Description "A group with file and queries is refused" `
    -Command {
        $bad = Join-Path $workloadDir 'both.json'
        '{ "workloads": [ { "file": "x.sql", "queries": ["SELECT 1"], "threads": 1, "iterations": 1 } ] }' |
            Set-Content -LiteralPath $bad -Encoding UTF8
        Invoke-SqlPySim -workload $bad -q 2>&1
    } `
    -ShouldFail $true `
    -ExpectedError 'cannot have both'

Test-Command -Name "Workload Rejects Query Source Conflict" -Description "-Q with -workload is refused" `
    -Command { Invoke-SqlPySim -workload $singleGroupFile -Q "SELECT 1" -q 2>&1 } `
    -ShouldFail $true `
    -ExpectedError 'Cannot use -Q with -workload'

Remove-Item -LiteralPath $workloadDir -Recurse -Force -ErrorAction SilentlyContinue

# ========================================
# EXAMPLE FILE TESTS
# ========================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "EXAMPLE FILE TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$examplesDir = Join-Path $PSScriptRoot "examples"
if (Test-Path $examplesDir) {
    # Only test 01-simple-queries.sql by default (works on any database)
    # Files 02-09 require AdventureWorksLT database
    $universalFile = Join-Path $examplesDir "sql\01-simple-queries.sql"
    if (Test-Path $universalFile) {
        Test-Command -Name "Example: 01-simple-queries.sql" -Description "Execute catalog view queries (works on any database)" `
            -Command { & $runSqlPySim @script:BaseAuthArgs -i $universalFile -q } `
            -ExpectedOutput "Total Runtime:"
    }
}

# ========================================
# LIVE TELEMETRY TESTS
# ========================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "LIVE TELEMETRY TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

function Get-StreamEvents {
    param([string[]]$ExtraArguments)

    $allArgs = $script:BaseAuthArgs + $ExtraArguments
    $resultArray = & $runSqlPySim @allArgs 2>&1
    $exitCode = $LASTEXITCODE
    $lines = @($resultArray | ForEach-Object { "$_" } | Where-Object { $_.Trim() -ne '' })
    $events = @()
    $unparsed = @()
    foreach ($line in $lines) {
        try { $events += ($line | ConvertFrom-Json) } catch { $unparsed += $line }
    }
    [pscustomobject]@{
        ExitCode = $exitCode
        Events   = $events
        Unparsed = $unparsed
        Lines    = $lines
    }
}

# A run longer than the one-second tick must produce intermediate events.
# Without this the stream would technically be valid while telling a watching
# operator nothing until the run was already over.
$streamLong = Get-StreamEvents -ExtraArguments @(
    "-Q", "WAITFOR DELAY '00:00:04'; SELECT 1 AS StreamProgress", "-stream-json", "-q")
$progressEvents = @($streamLong.Events | Where-Object { $_.type -eq 'progress' })

Test-Condition -Name "Stream Progress Cadence" `
    -Description "A four-second run emits at least three progress events" `
    -Condition ($progressEvents.Count -ge 3)

Test-Condition -Name "Stream Event Order" `
    -Description "The stream starts with started and ends with completed" `
    -Condition ($streamLong.Events.Count -ge 2 -and
                $streamLong.Events[0].type -eq 'started' -and
                $streamLong.Events[-1].type -eq 'completed')

# Anything that is not an event corrupts the stream for a machine reader, so
# the timestamped text output must be fully suppressed.
Test-Condition -Name "Stream Purity" `
    -Description "Every line on the stream parses as JSON" `
    -Condition ($streamLong.Unparsed.Count -eq 0)

Test-Condition -Name "Stream Started Fields" `
    -Description "The started event carries the version and thread count" `
    -Condition ($null -ne $streamLong.Events[0].version -and
                $streamLong.Events[0].threads -eq 1)

$progressWithMetadata = @($progressEvents | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_.odbc_driver_version) -and
    -not [string]::IsNullOrWhiteSpace($_.server_version) -and
    -not [string]::IsNullOrWhiteSpace($_.server_edition)
})
Test-Condition -Name "Stream Environment Metadata" `
    -Description "Progress and completed events identify the driver and SQL Server" `
    -Condition ($progressWithMetadata.Count -ge 1 -and
                -not [string]::IsNullOrWhiteSpace($streamLong.Events[-1].odbc_driver_version) -and
                -not [string]::IsNullOrWhiteSpace($streamLong.Events[-1].server_version) -and
                -not [string]::IsNullOrWhiteSpace($streamLong.Events[-1].server_edition))

# Elapsed time must advance across events; a constant value would mean the
# clock is read once and reused.
$elapsedValues = @($progressEvents | ForEach-Object { [double]$_.elapsed_seconds })
$elapsedAdvances = $true
for ($i = 1; $i -lt $elapsedValues.Count; $i++) {
    if ($elapsedValues[$i] -le $elapsedValues[$i - 1]) { $elapsedAdvances = $false }
}
Test-Condition -Name "Stream Elapsed Advances" `
    -Description "elapsed_seconds increases from one progress event to the next" `
    -Condition ($elapsedValues.Count -ge 2 -and $elapsedAdvances)

# The stream is a channel for a supervising process, so -o must not divert it
# into the results file the way ordinary output is diverted.
$streamOutputFile = Join-Path $testDir "stream-redirect.log"
$streamRedirected = Get-StreamEvents -ExtraArguments @(
    "-Q", "SELECT 1 AS StreamRedirect", "-stream-json", "-q", "-o", $streamOutputFile)
Test-Condition -Name "Stream Ignores Output File" `
    -Description "Events still reach stdout when -o is supplied" `
    -Condition (@($streamRedirected.Events | Where-Object { $_.type -eq 'completed' }).Count -eq 1)

# Counters must reflect the work, not the request: a run whose size is known
# is the only way to tell collection from echo.
$streamThreads = Get-StreamEvents -ExtraArguments @(
    "-Q", "SELECT 1 AS StreamThreads", "-n", "6", "-r", "7", "-stream-json", "-q")
$streamThreadsCompleted = @($streamThreads.Events | Where-Object { $_.type -eq 'completed' })
Test-Condition -Name "Stream Counters Under Concurrency" `
    -Description "Six threads by seven iterations reports 42 executions" `
    -Condition ($streamThreadsCompleted.Count -eq 1 -and
                $streamThreadsCompleted[0].successful_executions -eq 42)

Test-Condition -Name "Stream Throughput Reported" `
    -Description "Throughput is a positive number once work has completed" `
    -Condition ($streamThreadsCompleted.Count -eq 1 -and
                [double]$streamThreadsCompleted[0].throughput_per_second -gt 0)

Test-Command -Name "Stream Canonical JSON Requires Output File" `
    -Description "Combined -json and -stream-json requires -o" `
    -Command { & $runSqlPySim @script:BaseAuthArgs -Q "SELECT 1" -json -stream-json -q } `
    -ShouldFail:$true `
    -ExpectedError "requires -o"

$streamFinalFile = Join-Path $testDir "stream-final.json"
Remove-Item $streamFinalFile -ErrorAction SilentlyContinue
$streamFinal = Get-StreamEvents -ExtraArguments @(
    "-Q", "SELECT 1 AS StreamFinal", "-stream-json", "-json", "-o", $streamFinalFile, "-q")
$streamFinalDocument = try {
    Get-Content $streamFinalFile -Raw | ConvertFrom-Json
} catch {
    $null
}
Test-Condition -Name "Stream Writes Canonical Final JSON" `
    -Description "NDJSON stays on stdout and -o receives the canonical final document" `
    -Condition ($streamFinal.ExitCode -eq 0 -and
                @($streamFinal.Events | Where-Object { $_.type -eq 'completed' }).Count -eq 1 -and
                $null -ne $streamFinalDocument -and
                $streamFinalDocument.success -eq $true -and
                $streamFinalDocument.configuration.total_batches -eq 1 -and
                $streamFinalDocument.configuration.stream_json -eq $true)
Remove-Item $streamFinalFile -ErrorAction SilentlyContinue

# The errors list is trimmed to ten entries, so the reported total has to come
# from a counter. sqlsim reports every error here and so must sqlpysim.
$errorTotalOutput = (Invoke-SqlPySim -Q "SELECT * FROM dbo.NoSuchTable_TotalProbe" -n 1 -r 12 -json -q) -join "`n"
$reportedTotal = if ($errorTotalOutput -match '"total":\s*(\d+)') { [int]$Matches[1] } else { -1 }
Test-Condition -Name "Error Total Is Not Capped" `
    -Description "Twelve failures report a total of 12, not the trimmed list length" `
    -Condition ($reportedTotal -eq 12)

# ========================================
# PERIODIC QUERY STATISTICS TESTS
# ========================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "PERIODIC QUERY STATISTICS TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# A snapshot only earns its name if it appears while the run is still going and
# is always readable. Polling a run in flight tests both at once: a partial
# write would surface here as a parse failure.
$pollTarget = Join-Path $testDir "poll-snapshot.json"
$pollScript = {
    param($ScriptPath, $AuthArgs, $Target, $Secret)
    $arguments = $AuthArgs + @(
        "-Q", "WAITFOR DELAY '00:00:00.100'; SELECT TOP 50 name FROM sys.objects",
        "-n", "4", "-r", "15", "-querystats-interval", "1",
        "-querystats-file", $Target, "-q")
    # The job is a separate process, so it receives the secret and pipes it itself.
    if ($null -ne $Secret) { $Secret | python $ScriptPath @arguments | Out-Null }
    else { python $ScriptPath @arguments | Out-Null }
}
Remove-Item $pollTarget -Force -ErrorAction SilentlyContinue
$pollJob = Start-Job -ScriptBlock $pollScript -ArgumentList $scriptPath, $script:BaseAuthArgs, $pollTarget, $script:AuthSecret

$runningSnapshots = 0
$unreadableSnapshots = 0
$observedCounts = @()
while ($pollJob.State -eq 'Running') {
    if (Test-Path $pollTarget) {
        try {
            $sample = Get-Content $pollTarget -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($sample.status -eq 'running') {
                $runningSnapshots++
                $observedCounts += [int]$sample.query_stats.totals.executions
            }
        } catch {
            $unreadableSnapshots++
        }
    }
    Start-Sleep -Milliseconds 50
}
Receive-Job $pollJob | Out-Null
Remove-Job $pollJob

Test-Condition -Name "Snapshot Appears While Running" `
    -Description "At least one snapshot carries status 'running'" `
    -Condition ($runningSnapshots -gt 0)

Test-Condition -Name "Snapshot Is Never Partially Written" `
    -Description "Every snapshot read during the run parsed as JSON" `
    -Condition ($unreadableSnapshots -eq 0)

Test-Condition -Name "Snapshot Counts Advance" `
    -Description "Execution counts increase across snapshots taken while running" `
    -Condition (($observedCounts | Sort-Object -Unique).Count -gt 1)

$finalSnapshot = $null
if (Test-Path $pollTarget) {
    $finalSnapshot = Get-Content $pollTarget -Raw | ConvertFrom-Json
}

Test-Condition -Name "Snapshot Final Status" `
    -Description "The last snapshot is marked complete with every execution counted" `
    -Condition ($null -ne $finalSnapshot -and
                $finalSnapshot.status -eq 'complete' -and
                [int]$finalSnapshot.query_stats.totals.executions -eq 60)

Test-Condition -Name "Snapshot Peak Throughput Retained" `
    -Description "Peak throughput is at least the final throughput" `
    -Condition ($null -ne $finalSnapshot -and
                [double]$finalSnapshot.peak_throughput -ge [double]$finalSnapshot.throughput)

Test-Condition -Name "Snapshot Config Block" `
    -Description "The snapshot describes the run it came from" `
    -Condition ($null -ne $finalSnapshot -and
                [int]$finalSnapshot.config.threads -eq 4 -and
                [int]$finalSnapshot.config.total_batches -eq 60)

# Errors belong in the snapshot too: for a live run it is the only channel
# carrying error text while the run is still going.
$errorSnapshot = Join-Path $testDir "error-snapshot.json"
Invoke-SqlPySim -Q "SELECT * FROM dbo.NoSuchTable_SnapshotSuite" -n 1 -r 3 `
    -querystats-interval 1 -querystats-file $errorSnapshot -q | Out-Null
$errorSnapshotJson = if (Test-Path $errorSnapshot) { Get-Content $errorSnapshot -Raw | ConvertFrom-Json } else { $null }

Test-Condition -Name "Snapshot Records Errors" `
    -Description "Three failures are counted and their text is carried" `
    -Condition ($null -ne $errorSnapshotJson -and
                [int]$errorSnapshotJson.total_errors -eq 3 -and
                @($errorSnapshotJson.recent_errors).Count -gt 0 -and
                $errorSnapshotJson.recent_errors[0].message -match 'Invalid object name')

Test-Condition -Name "Snapshot Records Failed Executions" `
    -Description "The query totals report failures rather than executions" `
    -Condition ($null -ne $errorSnapshotJson -and
                [int]$errorSnapshotJson.query_stats.totals.failures -eq 3)

# The default name matters: Studio and any other supervisor rely on it when no
# path is given.
$defaultDirectory = Join-Path $testDir "default-snapshot"
New-Item -ItemType Directory -Force -Path $defaultDirectory | Out-Null
Push-Location $defaultDirectory
Invoke-SqlPySim -Q "SELECT 1 AS DefaultSnapshot" -n 1 -r 2 -querystats-interval 1 -q | Out-Null
$defaultWritten = Test-Path "querystats-live.json"
Pop-Location

Test-Condition -Name "Snapshot Default File Name" `
    -Description "Without -querystats-file the snapshot lands in querystats-live.json" `
    -Condition $defaultWritten

Test-Command -Name "Snapshot Rejects Non-Numeric Interval" `
    -Description "-querystats-interval requires a number" `
    -Command { & $runSqlPySim @script:BaseAuthArgs -Q "SELECT 1" -querystats-interval "soon" -q } `
    -ShouldFail:$true `
    -ExpectedError "Invalid value for -querystats-interval"

# ========================================
# CLEANUP AND SUMMARY
# ========================================

Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue

$duration = (Get-Date) - $startTime
$totalTests = $script:testsPassed + $script:testsFailed + $script:testsSkipped

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "FULL TEST SUITE RESULTS" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Total Tests: $totalTests" -ForegroundColor White
Write-Host "Passed: $($script:testsPassed)" -ForegroundColor $(if ($script:testsPassed -eq $totalTests) { "Green" } else { "Yellow" })
Write-Host "Skipped: $($script:testsSkipped)" -ForegroundColor $(if ($script:testsSkipped -eq 0) { "Green" } else { "Yellow" })
Write-Host "Failed: $($script:testsFailed)" -ForegroundColor $(if ($script:testsFailed -eq 0) { "Green" } else { "Red" })
Write-Host "Duration: $($duration.TotalSeconds.ToString('F1')) seconds" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Cyan

if ($script:testsFailed -eq 0) {
    Write-Host "`n✓ ALL TESTS PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n✗ SOME TESTS FAILED" -ForegroundColor Red
    exit 1
}
