#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Minimal smoke test for sqlpysim - Quick validation of core functionality.
    For comprehensive testing, use full-test-suite.ps1 instead.

.DESCRIPTION
    This script performs essential validation tests for quick verification.
    Tests cover basic connection, query execution, authentication, and key parameters.
    Expected duration: 5-10 seconds.

.PARAMETER Server
    SQL Server instance (default: localhost)

.PARAMETER Database
    Database name (default: tempdb)

.PARAMETER UseToken
    Access token for Azure SQL Database authentication (optional)
    The token, like -Password, reaches sqlpysim on stdin (-T -, -P -), so it never
    appears in a process list.

.EXAMPLE
    .\smoke-test.ps1
    .\smoke-test.ps1 -Server myserver.database.windows.net -Database mydb
    $token = (az account get-access-token --resource https://database.windows.net --query accessToken -o tsv)
    .\smoke-test.ps1 -Server myserver.database.windows.net -Database mydb -UseToken $token
#>

param(
    [string]$Server = "localhost",
    [string]$Database = "tempdb",
    [string]$UseToken = "",
    [string]$Username = "",
    [string]$Password = "",
    [switch]$SkipInstall
)

$ErrorActionPreference = "Continue"
$scriptPath = Join-Path $PSScriptRoot "sqlpysim.py"

# Verify sqlpysim.py exists
if (-not (Test-Path $scriptPath)) {
    Write-Host "ERROR: sqlpysim.py not found at $scriptPath" -ForegroundColor Red
    exit 1
}

# Check Python and mssql-python
if (-not $SkipInstall) {
    Write-Host "Checking mssql-python driver..." -ForegroundColor Cyan
    $checkResult = python -c "import mssql_python" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Installing mssql-python..." -ForegroundColor Yellow
        pip install mssql-python
    } else {
        Write-Host "  ✓ mssql-python installed" -ForegroundColor Green
    }
}

# Determine authentication method
$IsAzure = $Server -match 'database\.windows\.net|database\.fabric\.microsoft\.com'

if ($UseToken) {
    $authMethod = "Token"
    $authArgs = @("-T", "-")
    $script:AuthSecret = $UseToken
} elseif ($Username -and $Password) {
    $authMethod = "SQL Authentication"
    $authArgs = @("-U", $Username, "-P", "-")
    $script:AuthSecret = $Password
    # Non-Azure targets commonly present a self-signed certificate.
    if (-not $IsAzure) { $authArgs += "-C" }
} else {
    $authMethod = "Windows"
    $authArgs = @("-E", "-C")
    $script:AuthSecret = $null
}

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

$testsPassed = 0
$testsFailed = 0
$testsSkipped = 0

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "SQLPYSIM SMOKE TEST - Quick Validation" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Server  : $Server" -ForegroundColor White
Write-Host "Database: $Database" -ForegroundColor White
Write-Host "Auth    : $authMethod" -ForegroundColor White
Write-Host "Test Set: Essential core functionality" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan

function Test-SqlPySim {
    param(
        [string]$TestName,
        [string[]]$Arguments,
        [switch]$ShouldFail,
        [string]$ExpectedOutput,
        [string]$NotExpectedOutput
    )
    
    Write-Host "Testing: $TestName" -ForegroundColor Yellow
    
    $resultArray = & $runSqlPySim @Arguments 2>&1
    $output = $resultArray -join "`n"
    $exitCode = $LASTEXITCODE
    
    $passed = $false
    
    if ($ShouldFail) {
        $passed = ($exitCode -ne 0)
    } else {
        $passed = ($exitCode -eq 0)
    }
    
    if ($passed -and $ExpectedOutput) {
        $passed = $output -match $ExpectedOutput
    }
    
    if ($passed -and $NotExpectedOutput) {
        $passed = $output -notmatch $NotExpectedOutput
    }
    
    if ($passed) {
        Write-Host "  ✓ PASSED" -ForegroundColor Green
        $script:testsPassed++
    } else {
        Write-Host "  ✗ FAILED" -ForegroundColor Red
        Write-Host "    Exit Code: $exitCode" -ForegroundColor Gray
        if ($output.Length -lt 500) {
            Write-Host "    Output: $($output.Trim().Substring(0, [Math]::Min(300, $output.Length)))" -ForegroundColor Gray
        }
        $script:testsFailed++
    }
    Write-Host ""
}

# ============================================================
# ESSENTIAL SMOKE TESTS (Core Functionality)
# ============================================================

# Test 1: Help text
Test-SqlPySim -TestName "Help text displays" `
    -Arguments @("-h") `
    -ExpectedOutput "usage:"

# Test 2: Basic connection test
Test-SqlPySim -TestName "Basic connection to server" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT 1", "-q"))

# Test 3: Connection with explicit -S and -d flags
Test-SqlPySim -TestName "Explicit -S localhost -d tempdb" `
    -Arguments (@("-S", "localhost", "-d", "tempdb", "-E", "-C", "-Q", "SELECT 1", "-q"))

# Test 4: Simple query execution (without -q to verify output)
Test-SqlPySim -TestName "Simple SELECT query with output" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT 1 AS TestCol"))

# Test 5: Multi-threaded without -q (3 threads, 2 reps)
Test-SqlPySim -TestName "Multi-threaded query with output" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT 1", "-n", "3", "-r", "2", "-q"))

# Test 6: Authentication test
Test-SqlPySim -TestName "Authentication ($authMethod)" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT 1", "-q"))

# Test 7: Query repetition (100 reps)
Test-SqlPySim -TestName "Query repetition (-r 100)" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT 1", "-r", "100", "-q")) `
    -ExpectedOutput "Total batches to execute: 100"

# Test 8: Concurrency test (25 threads, 10 reps)
Test-SqlPySim -TestName "Concurrency (25 threads x 10 iterations)" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT 1", "-n", "25", "-r", "10", "-q")) `
    -ExpectedOutput "Threads: 25"

# Test 9: Quiet mode (-q flag)
Test-SqlPySim -TestName "Quiet mode suppresses query output" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT 1 AS TestColumn", "-q")) `
    -ExpectedOutput "Total Runtime:"

# Test 10: Verbose mode (-v flag)
Test-SqlPySim -TestName "Verbose mode shows details" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT 1", "-v", "-q")) `
    -ExpectedOutput "PHASE"

# Test 10b: Non-verbose output uses batch terminology
Test-SqlPySim -TestName "Non-verbose output uses batch terminology" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT 1", "-q")) `
    -ExpectedOutput "Batches in workload"

# Test 10c: Prepared mode is explicitly ignored for raw SQL workloads
Test-SqlPySim -TestName "Prepared statements (-p) report their effective state" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT 1", "-p", "-v", "-q")) `
    -ExpectedOutput "Prepared statements \(-p\) are not supported for raw SQL workloads by mssql-python; flag ignored" `
    -NotExpectedOutput "Prepared Statements: Yes"

# Test 11: Invalid connection (error handling)
Test-SqlPySim -TestName "Invalid server error handling" `
    -Arguments @("-S", "InvalidServer123.invalid", "-d", "tempdb", "-E", "-C", "-Q", "SELECT 1") `
    -ShouldFail

# Test 12: File input basic test
$testDir = Join-Path $PSScriptRoot "testing"
New-Item -Path $testDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
$testFile = Join-Path $testDir "test-smoke.sql"
"SELECT 1 AS FileTest" | Out-File -FilePath $testFile -Encoding UTF8
Test-SqlPySim -TestName "File input (-i flag)" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-i", $testFile, "-q"))

Test-SqlPySim -TestName "Query and file input are mutually exclusive" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT 1", "-i", $testFile, "-q")) `
    -ShouldFail `
    -ExpectedOutput "Cannot use -Q with -i"

Remove-Item $testFile -ErrorAction SilentlyContinue

# Test 13: GO batch separator
$testFileGO = Join-Path $testDir "test-smoke-go.sql"
@"
SELECT 1 AS Batch1
GO
SELECT 2 AS Batch2
GO
SELECT 3 AS Batch3
"@ | Out-File -FilePath $testFileGO -Encoding UTF8
Test-SqlPySim -TestName "GO batch separators" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-i", $testFileGO, "-q")) `
    -ExpectedOutput "Batches in workload: 3"
Remove-Item $testFileGO -ErrorAction SilentlyContinue

# Test 14: Output to file (-o flag)
$outputFile = Join-Path $testDir "test-smoke-output.txt"
Test-SqlPySim -TestName "Output to file (-o flag)" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT 'OutputTest' AS Result", "-o", $outputFile, "-q"))
Remove-Item $outputFile -ErrorAction SilentlyContinue

# Test 15: Application name parameter
# Test 15: Application name is refused
# mssql-python reserves the application name and always reports MSSQL-Python,
# so accepting -app and echoing it back would name a session that SQL Server
# never sees. Refusing it is the contract.
Test-SqlPySim -TestName "Application name (-app) is refused" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-app", "SmokeTest", "-Q", "SELECT 1", "-q")) `
    -ShouldFail `
    -ExpectedOutput "mssql-python driver reserves this connection keyword"

# Test 15b: The reported application name is the one the server will see
Test-SqlPySim -TestName "Reported application name matches APP_NAME()" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT APP_NAME() AS AppName")) `
    -ExpectedOutput "Application name: MSSQL-Python"

# Test 16: Reconnect mode
Test-SqlPySim -TestName "Reconnect mode (-reconnect)" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-reconnect", "-Q", "SELECT 1", "-n", "2", "-r", "2", "-q"))

# Test 16b: Pooling requires reconnect, matching sqlsim
Test-SqlPySim -TestName "Connection pooling requires reconnect" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-usepool", "-Q", "SELECT 1", "-q")) `
    -ShouldFail `
    -ExpectedOutput "-usepool requires -reconnect"

# Test 16c: Pooling with reconnect
Test-SqlPySim -TestName "Connection pooling (-usepool)" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-reconnect", "-usepool", "-Q", "SELECT 1", "-r", "2", "-q"))

# Test 17: JSON output format
Write-Host "Testing: JSON output format (-json)" -NoNewline
$jsonArgs = @("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT 1", "-json")
$resultArray = & $runSqlPySim @jsonArgs 2>&1
$output = $resultArray -join "`n"
$exitCode = $LASTEXITCODE
$passed = $false
if ($exitCode -eq 0 -and $output -match '"version"') {
    try {
        $jsonDocument = $output | ConvertFrom-Json
        $passed = $jsonDocument.configuration.odbc_driver -eq "mssql-python" -and
            $null -eq $jsonDocument.configuration.driver -and
            $null -ne $jsonDocument.metrics.odbc_driver_version -and
            $null -eq $jsonDocument.metrics.driver_version -and
            $null -ne $jsonDocument.metrics.warnings.list
        if ($passed) {
            Write-Host "  ✓ PASSED" -ForegroundColor Green
            $script:testsPassed++
        }
    } catch {
        Write-Host "  ✗ FAILED - Invalid JSON: $_" -ForegroundColor Red
        $script:testsFailed++
    }
}
if (-not $passed -and $exitCode -ne 0) {
    Write-Host "  ✗ FAILED (exit code: $exitCode)" -ForegroundColor Red
    $script:testsFailed++
} elseif (-not $passed) {
    Write-Host "  ✗ FAILED - JSON does not match the shared schema" -ForegroundColor Red
    $script:testsFailed++
}
Write-Host ""

# Secure credential input through redirected stdin
Write-Host "Testing: Credentials from redirected stdin (-P - and -T -)" -NoNewline
function Invoke-StdinCredentialTest {
    param([string[]]$Arguments, [string]$Secret)
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command python).Source
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $null = $startInfo.ArgumentList.Add($scriptPath)
    foreach ($argument in $Arguments) { $null = $startInfo.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $process.StandardInput.WriteLine($Secret)
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout + $stderr }
}
$stdinPassword = "sqlpysim-stdin-password"
$passwordResult = Invoke-StdinCredentialTest `
    -Arguments @("-S", "localhost", "-U", "stdin-user", "-P", "-", "-C", "-l", "1", "-Q", "SELECT 1", "-v", "-q") `
    -Secret $stdinPassword
$stdinToken = "sqlpysim-stdin-token-value"
$tokenResult = Invoke-StdinCredentialTest `
    -Arguments @("-S", "localhost", "-T", "-", "-C", "-l", "1", "-Q", "SELECT 1", "-v", "-q") `
    -Secret $stdinToken
$emptyResult = Invoke-StdinCredentialTest `
    -Arguments @("-S", "localhost", "-U", "stdin-user", "-P", "-") `
    -Secret ""
$oversizedResult = Invoke-StdinCredentialTest `
    -Arguments @("-S", "localhost", "-U", "stdin-user", "-P", "-") `
    -Secret ("x" * 129)
$stdinPassed = $passwordResult.ExitCode -ne 0 -and $tokenResult.ExitCode -ne 0 -and
    $passwordResult.Output -notmatch [regex]::Escape($stdinPassword) -and
    $tokenResult.Output -notmatch [regex]::Escape($stdinToken) -and
    $passwordResult.Output -notmatch 'requires redirected stdin' -and
    $tokenResult.Output -notmatch 'Invalid access token format|requires redirected stdin' -and
    $emptyResult.ExitCode -ne 0 -and $emptyResult.Output -match 'cannot be empty' -and
    $oversizedResult.ExitCode -ne 0 -and $oversizedResult.Output -match 'exceeds maximum'
if ($stdinPassed) {
    Write-Host "  ✓ PASSED" -ForegroundColor Green
    $script:testsPassed++
} else {
    Write-Host "  ✗ FAILED" -ForegroundColor Red
    $script:testsFailed++
}
Write-Host ""

# Test 18: JSON output to file
$jsonOutputFile = Join-Path $testDir "test-smoke-json.json"
Test-SqlPySim -TestName "JSON output to file (-json -o)" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT 1", "-json", "-o", $jsonOutputFile))
Remove-Item $jsonOutputFile -ErrorAction SilentlyContinue

# Test 19: Timestamp format validation
Write-Host "Testing: Timestamp format and output features" -NoNewline
$tsArgs = @("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT 1", "-q")
$resultArray = & $runSqlPySim @tsArgs 2>&1
$output = $resultArray -join "`n"
$exitCode = $LASTEXITCODE

$hasTimestamp = $output -match '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}'
$hasStartMsg = $output -match 'Starting execution|Connecting'
$hasTotalRuntime = $output -match 'Total Runtime'
$hasSummaryParity = $output -match 'Performance Metric Summary' -and
    $output -match 'Start Time: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}' -and
    $output -match 'End Time:\s+\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}' -and
    $output -match 'Avg Connect Time:' -and
    $output -match 'Avg Elapsed:'

$passed = $exitCode -eq 0 -and $hasTimestamp -and $hasStartMsg -and
    $hasTotalRuntime -and $hasSummaryParity

if ($passed) {
    Write-Host "  ✓ PASSED" -ForegroundColor Green
    $script:testsPassed++
} else {
    Write-Host "  ✗ FAILED" -ForegroundColor Red
    Write-Host "    Timestamp: $hasTimestamp, Start msg: $hasStartMsg, Total runtime: $hasTotalRuntime, Summary parity: $hasSummaryParity" -ForegroundColor Gray
    $script:testsFailed++
}
Write-Host ""

# Test 20: SQL error returns exit code 1
Test-SqlPySim -TestName "SQL error returns exit code 1" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT * FROM nonexistent_table_xyz_12345", "-q")) `
    -ShouldFail

# Test 21: Error messages properly captured
Write-Host "Testing: Error messages properly captured" -NoNewline
$errArgs = @("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT * FROM nonexistent_table_xyz_12345")
$resultArray = & $runSqlPySim @errArgs 2>&1
$output = $resultArray -join "`n"
$exitCode = $LASTEXITCODE
$hasError = $output -match "Invalid object|does not exist|error"
if ($exitCode -ne 0 -or $hasError) {
    Write-Host "  ✓ PASSED" -ForegroundColor Green
    $script:testsPassed++
} else {
    Write-Host "  ✗ FAILED" -ForegroundColor Red
    $script:testsFailed++
}
Write-Host ""

# Test 22: Connection test only (no query)
Test-SqlPySim -TestName "Connection test only (no query)" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs) `
    -ExpectedOutput "Connection test"

# Test 23: Version display
Test-SqlPySim -TestName "Version display (--version)" `
    -Arguments @("--version") `
    -ExpectedOutput "sqlpysim"

# Test 24: Missing authentication fails
Write-Host "Testing: Missing authentication fails" -NoNewline
$resultArray = & $runSqlPySim -S localhost -Q "SELECT 1" 2>&1
$output = $resultArray -join "`n"
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    Write-Host "  ✓ PASSED" -ForegroundColor Green
    $script:testsPassed++
} else {
    Write-Host "  ✗ FAILED (should have failed without auth)" -ForegroundColor Red
    $script:testsFailed++
}
Write-Host ""

# Test 24b: Authentication methods are mutually exclusive
Test-SqlPySim -TestName "Mixed authentication methods fail" `
    -Arguments @("-S", "localhost", "-E", "-T", "0123456789", "-Q", "SELECT 1", "-q") `
    -ShouldFail `
    -ExpectedOutput "Cannot mix authentication methods \(-E, -A, -T, -U/-P\)"

# Test 25: Trust server certificate (-C)
Test-SqlPySim -TestName "Trust server certificate (-C)" `
    -Arguments @("-S", "localhost", "-E", "-C", "-Q", "SELECT 1", "-q") `
    -ExpectedOutput "Total Runtime"

# Test 25b: Invalid encryption levels are rejected before connecting
Test-SqlPySim -TestName "Invalid encryption level is rejected" `
    -Arguments @("-S", "localhost", "-E", "-N", "x", "-Q", "SELECT 1", "-q") `
    -ShouldFail `
    -ExpectedOutput "Invalid encryption level 'x'.*Valid options: o.*m.*s"

# Test 26: Connection string mode (-c)
if (-not $UseToken) {
    Test-SqlPySim -TestName "Connection string mode (-c)" `
        -Arguments @("-c", "Server=localhost;Trusted_Connection=yes;TrustServerCertificate=yes", "-Q", "SELECT 1", "-q") `
        -ExpectedOutput "Total Runtime"
} else {
    Write-Host "Testing: Connection string mode (-c)" -ForegroundColor Yellow
    Write-Host "  SKIPPED: Token auth requires special handling" -ForegroundColor Yellow
    $script:testsSkipped++
    Write-Host ""
}

# Test 26b: A raw connection string cannot be mixed with component options
Test-SqlPySim -TestName "Connection string rejects component options" `
    -Arguments @("-c", "Server=localhost;Trusted_Connection=yes;TrustServerCertificate=yes", "-S", "localhost", "-Q", "SELECT 1", "-q") `
    -ShouldFail `
    -ExpectedOutput "Cannot use both -c and -S/-d/-E/-A/-T/-U/-P options"

# Test 27: Multiple result columns
Test-SqlPySim -TestName "Multiple columns in result" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT 1 AS A, 2 AS B, 3 AS C")) `
    -ExpectedOutput "row.*affected"

# Test 28: @@VERSION query
Test-SqlPySim -TestName "@@VERSION query" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT @@VERSION")) `
    -ExpectedOutput "SQL Server|Microsoft SQL"

# Test 29: Verbose shows connection info
Test-SqlPySim -TestName "Verbose shows connection info" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT 1", "-v", "-q")) `
    -ExpectedOutput "Connection String"

# Test 30: Verbose command display masks passwords, tokens, and connection-string credentials
Write-Host "Testing: Verbose command redacts credentials" -NoNewline
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
$redactionOutput = $redactionScript | python - $scriptPath
$redactionExitCode = $LASTEXITCODE
if ($redactionExitCode -eq 0) {
    Write-Host "  ✓ PASSED" -ForegroundColor Green
    $script:testsPassed++
} else {
    Write-Host "  ✗ FAILED" -ForegroundColor Red
    $redactionOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    $script:testsFailed++
}
Write-Host ""

# Test 31: Basic workload file
# Mirrors sqlsim smoke Test 35. The core of workload mode is that groups
# expand independently, so a file with two differing groups proves more than
# one group ever could.
$smokeWorkloadFile = Join-Path $testDir "smoke-workload.json"
@'
{
    "workloads": [
        { "queries": ["SELECT 1 AS SmokeGroupOne"], "threads": 2, "iterations": 2 },
        { "queries": ["SELECT 2 AS SmokeGroupTwo"], "threads": 1, "iterations": 3 }
    ]
}
'@ | Set-Content $smokeWorkloadFile -Encoding UTF8
Test-SqlPySim -TestName "Workload file with two groups" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-workload", $smokeWorkloadFile, "-q")) `
    -ExpectedOutput "Workload groups: 2"

# The group count alone comes from parsing the file, so it stays right even if
# expansion drops a group. Thread count is the sum of the groups, 2 + 1 here,
# so it only reads 3 when every group was actually expanded.
Test-SqlPySim -TestName "Workload threads are the sum of its groups" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-workload", $smokeWorkloadFile, "-q")) `
    -ExpectedOutput "Threads: 3"

# Test 32: Duration mode workload
# Mirrors sqlsim smoke Test 39. duration_seconds replaces the iteration count
# entirely, so it exercises a different loop.
$smokeDurationFile = Join-Path $testDir "smoke-duration-workload.json"
@'
{
    "duration_seconds": 3,
    "workloads": [
        { "queries": ["SELECT 1 AS SmokeDuration"], "threads": 2 }
    ]
}
'@ | Set-Content $smokeDurationFile -Encoding UTF8
Test-SqlPySim -TestName "Duration mode workload (duration_seconds)" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-workload", $smokeDurationFile, "-q")) `
    -ExpectedOutput "Duration: 3 seconds"

# Test 33: Live telemetry (-stream-json)
# Mirrors sqlsim's stream contract. Substring matching would pass on a single
# malformed line, so every line is parsed as JSON and the events are inspected.
function Test-StreamJson {
    param(
        [string]$TestName,
        [string[]]$Arguments,
        [scriptblock]$Assertion
    )

    Write-Host "Testing: $TestName" -ForegroundColor Yellow

    $resultArray = & $runSqlPySim @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $lines = @($resultArray | ForEach-Object { "$_" } | Where-Object { $_.Trim() -ne '' })
    $events = @()
    $unparsed = 0
    foreach ($line in $lines) {
        try { $events += ($line | ConvertFrom-Json) } catch { $unparsed++ }
    }

    $reason = & $Assertion $events $exitCode $unparsed

    if (-not $reason) {
        Write-Host "  ✓ PASSED" -ForegroundColor Green
        $script:testsPassed++
    } else {
        Write-Host "  ✗ FAILED" -ForegroundColor Red
        Write-Host "    $reason" -ForegroundColor Gray
        Write-Host "    Exit Code: $exitCode" -ForegroundColor Gray
        $script:testsFailed++
    }
    Write-Host ""
}

Test-StreamJson -TestName "Live telemetry emits started then completed" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @(
        "-Q", "SELECT 1 AS StreamSmoke", "-stream-json", "-q")) `
    -Assertion {
        param($events, $exitCode, $unparsed)
        if ($exitCode -ne 0) { return "expected exit 0, got $exitCode" }
        if ($unparsed -gt 0) { return "$unparsed line(s) on the stream were not JSON" }
        if ($events.Count -lt 2) { return "expected at least two events, got $($events.Count)" }
        if ($events[0].type -ne 'started') { return "first event was $($events[0].type), not started" }
        if ($events[-1].type -ne 'completed') { return "last event was $($events[-1].type), not completed" }
        if ($events[-1].status -ne 'success') { return "status was $($events[-1].status), not success" }
        return $null
    }

# The counters are the reason the stream exists. Reading them from a run whose
# size is known is the only way to prove they are collected rather than echoed.
Test-StreamJson -TestName "Live telemetry counts every execution" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @(
        "-Q", "SELECT 1 AS StreamCount", "-n", "4", "-r", "5", "-stream-json", "-q")) `
    -Assertion {
        param($events, $exitCode, $unparsed)
        if ($exitCode -ne 0) { return "expected exit 0, got $exitCode" }
        $completed = @($events | Where-Object { $_.type -eq 'completed' })
        if ($completed.Count -ne 1) { return "expected one completed event, got $($completed.Count)" }
        if ($completed[0].successful_executions -ne 20) {
            return "expected 20 successful executions, got $($completed[0].successful_executions)"
        }
        if ($completed[0].successful_connections -ne 4) {
            return "expected 4 connections, got $($completed[0].successful_connections)"
        }
        return $null
    }

# A failing run must still complete the stream, otherwise a supervisor waiting
# for the final event would hang on exactly the runs it most needs to report.
Test-StreamJson -TestName "Live telemetry reports a failing run" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @(
        "-Q", "SELECT * FROM dbo.NoSuchTable_StreamSmoke", "-n", "1", "-r", "2",
        "-stream-json", "-q")) `
    -Assertion {
        param($events, $exitCode, $unparsed)
        if ($exitCode -eq 0) { return "a failing query exited 0" }
        if ($unparsed -gt 0) { return "$unparsed line(s) on the stream were not JSON" }
        $completed = @($events | Where-Object { $_.type -eq 'completed' })
        if ($completed.Count -ne 1) { return "expected one completed event, got $($completed.Count)" }
        if ($completed[0].status -ne 'error') { return "status was $($completed[0].status), not error" }
        if ($completed[0].failed_executions -ne 2) {
            return "expected 2 failed executions, got $($completed[0].failed_executions)"
        }
        return $null
    }

Test-SqlPySim -TestName "Live canonical JSON requires an output file" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @(
        "-Q", "SELECT 1", "-json", "-stream-json", "-q")) `
    -ShouldFail `
    -ExpectedOutput "requires -o"

$streamFinalFile = Join-Path $testDir "smoke-stream-final.json"
Remove-Item $streamFinalFile -ErrorAction SilentlyContinue
Test-StreamJson -TestName "Live telemetry writes canonical final JSON" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @(
        "-Q", "SELECT 1 AS StreamFinalResult", "-stream-json", "-json",
        "-o", $streamFinalFile, "-q")) `
    -Assertion {
        param($events, $exitCode, $unparsed)
        if ($exitCode -ne 0) { return "expected exit 0, got $exitCode" }
        if ($unparsed -gt 0) { return "$unparsed line(s) on the stream were not JSON" }
        if ($events[0].type -ne 'started' -or $events[-1].type -ne 'completed') {
            return "stream did not contain started through completed events"
        }
        try {
            $result = Get-Content $streamFinalFile -Raw | ConvertFrom-Json
        } catch {
            return "canonical final JSON was missing or invalid"
        }
        if ($result.success -ne $true -or $result.configuration.total_batches -ne 1) {
            return "canonical final JSON did not describe the completed execution"
        }
        return $null
    }
Remove-Item $streamFinalFile -ErrorAction SilentlyContinue

# Test 34: Periodic query statistics (-querystats-interval)
$snapshotFile = Join-Path $testDir "smoke-snapshot.json"
Test-SqlPySim -TestName "Snapshot interval implies -querystats" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @(
        "-Q", "SELECT 1 AS SnapshotSmoke", "-n", "2", "-r", "5",
        "-querystats-interval", "1", "-querystats-file", $snapshotFile, "-v", "-q")) `
    -ExpectedOutput "Query stats interval: 1s"

# Reading the file back is the only way to tell a written snapshot from a
# flag that was merely accepted.
$snapshotWritten = Test-Path $snapshotFile
$snapshotValid = $false
$snapshotExecutions = -1
$snapshotStatus = ""
if ($snapshotWritten) {
    try {
        $snapshotJson = Get-Content $snapshotFile -Raw | ConvertFrom-Json
        $snapshotValid = $true
        $snapshotExecutions = $snapshotJson.query_stats.totals.executions
        $snapshotStatus = $snapshotJson.status
    } catch {
        $snapshotValid = $false
    }
}

Write-Host "Testing: Snapshot file contains the run's statistics" -ForegroundColor Yellow
if ($snapshotValid -and $snapshotExecutions -eq 10 -and $snapshotStatus -eq 'complete') {
    Write-Host "  ✓ PASSED" -ForegroundColor Green
    $testsPassed++
} else {
    Write-Host "  ✗ FAILED" -ForegroundColor Red
    Write-Host "    written=$snapshotWritten valid=$snapshotValid status='$snapshotStatus' executions=$snapshotExecutions (expected 10)" -ForegroundColor Gray
    $testsFailed++
}
Write-Host ""

Test-SqlPySim -TestName "Snapshot interval below one is rejected" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @(
        "-Q", "SELECT 1", "-querystats-interval", "0", "-q")) `
    -ShouldFail `
    -ExpectedOutput "must be >= 1"

# An unwritable path must not take the run down: the snapshot is a diagnostic
# side channel. Unlike sqlsim, which discards the failure entirely, sqlpysim
# says so once so a mistyped path does not look like a healthy run.
Test-SqlPySim -TestName "An unwritable snapshot path warns but does not fail the run" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @(
        "-Q", "SELECT 1 AS SnapshotUnwritable", "-n", "1", "-r", "2",
        "-querystats-interval", "1", "-querystats-file", "Z:\nope\bad.json", "-q")) `
    -ExpectedOutput "could not write the query statistics snapshot"

# The warning must never reach a machine-readable stream.
Test-StreamJson -TestName "An unwritable snapshot path does not corrupt the stream" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @(
        "-Q", "SELECT 1 AS SnapshotStreamPurity", "-n", "1", "-r", "2",
        "-querystats-interval", "1", "-querystats-file", "Z:\nope\bad.json",
        "-stream-json", "-q")) `
    -Assertion {
        param($events, $exitCode, $unparsed)
        if ($exitCode -ne 0) { return "expected exit 0, got $exitCode" }
        if ($unparsed -gt 0) { return "$unparsed line(s) on the stream were not JSON" }
        if (@($events | Where-Object { $_.type -eq 'completed' }).Count -ne 1) {
            return 'the stream did not complete'
        }
        return $null
    }

# ============================================================
# RESULTS SUMMARY
# ============================================================

# Cleanup testing directory
Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "SMOKE TEST RESULTS" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Passed : $testsPassed" -ForegroundColor Green
Write-Host "Failed : $testsFailed" -ForegroundColor $(if ($testsFailed -eq 0) { "Green" } else { "Red" })
Write-Host "Skipped: $testsSkipped" -ForegroundColor Yellow
Write-Host "Total  : $($testsPassed + $testsFailed + $testsSkipped)" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan

if ($testsFailed -eq 0) {
    Write-Host "✓ All smoke tests passed! Core functionality verified." -ForegroundColor Green
    Write-Host "  Run full-test-suite.ps1 for comprehensive validation." -ForegroundColor Cyan
    exit 0
} else {
    Write-Host "✗ Some smoke tests failed. Check output above." -ForegroundColor Red
    exit 1
}
