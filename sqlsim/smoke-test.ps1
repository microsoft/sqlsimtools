#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Minimal smoke test for sqlsim - Quick validation of core functionality.
    For comprehensive testing, use full-test-suite.ps1 instead.

.DESCRIPTION
    This script performs essential validation tests for quick verification.
    Tests cover basic connection, query execution, authentication, and key parameters.
    Expected duration: 2-3 seconds.

.PARAMETER Server
    SQL Server instance (default: localhost)

.PARAMETER Database
    Database name (default: tempdb)

.PARAMETER UseToken
    Access token for Azure SQL Database authentication (optional)
    The token, like -Password, reaches sqlsim on stdin (-T -, -P -), so it never
    appears in a process list.

.PARAMETER SkipBuild
    Skip the build step and use existing executable.

.PARAMETER Verbose
    Show sqlsim output for each test (0=quiet, 1=show output). Default: 0

.PARAMETER OutputFile
    Write all test output to the specified file (captures console output via transcript).

.EXAMPLE
    .\smoke-test.ps1
    .\smoke-test.ps1 -Verbose 1
    .\smoke-test.ps1 -Verbose 1 -OutputFile smoke-results.txt
    .\smoke-test.ps1 -Server myserver.database.windows.net -Database mydb
    $token = (az account get-access-token --resource https://database.windows.net --query accessToken -o tsv)
    .\smoke-test.ps1 -Server myserver.database.windows.net -Database mydb -UseToken $token
#>

param(
    [switch]$SkipBuild,
    [string]$Server = "localhost",
    [string]$Database = "tempdb",
    [string]$UseToken = "",
    [string]$Username = "",
    [string]$Password = "",
    [int]$Verbose = 0,
    [string]$OutputFile = "",
    [string]$PerfTag = ""
)

$ErrorActionPreference = "Continue"

# Start transcript if output file requested
if ($OutputFile) {
    $OutputFile = [System.IO.Path]::GetFullPath($OutputFile)
    Start-Transcript -Path $OutputFile -Force | Out-Null
}

# Ensure we're in the script directory for relative paths
Push-Location $PSScriptRoot

# Build if needed
if (-not $SkipBuild) {
    Write-Host "Building sqlsim..." -ForegroundColor Cyan
    & "$PSScriptRoot\build.ps1"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Build failed" -ForegroundColor Red
        exit 1
    }
    Write-Host "Build successful`n" -ForegroundColor Green
} else {
    Write-Host "Skipping build (using existing executable)`n" -ForegroundColor Yellow
}

$sqlsimPath = ".\build\x64\Release\sqlsim.exe"

# Verify sqlsim.exe exists
if (-not (Test-Path $sqlsimPath)) {
    Write-Host "ERROR: sqlsim.exe not found at $sqlsimPath" -ForegroundColor Red
    Write-Host "Run build.ps1 first to build the project" -ForegroundColor Yellow
    exit 1
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
    $authArgs = @("-E")
    $script:AuthSecret = $null
}

# Runs sqlsim, writing the secret to stdin when the arguments ask for it with
# -T - or -P -, so the token or password never appears in a process list.
# Input piped by the caller is passed through unchanged.
$script:EnginePath = $sqlsimPath
$runSqlsim = {
    $engineArgs = @(foreach ($a in $args) { $a })
    $readsSecret = $false
    for ($i = 0; $i -lt $engineArgs.Count - 1; $i++) {
        if ($engineArgs[$i] -cin '-T', '-P' -and $engineArgs[$i + 1] -eq '-') { $readsSecret = $true }
    }
    if ($MyInvocation.ExpectingInput) { $input | & $script:EnginePath @engineArgs }
    elseif ($readsSecret -and $null -ne $script:AuthSecret) { $script:AuthSecret | & $script:EnginePath @engineArgs }
    else { & $script:EnginePath @engineArgs }
}

$testsPassed = 0
$testsFailed = 0
$testsSkipped = 0

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "SQLSIM SMOKE TEST - Quick Validation" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Server  : $Server" -ForegroundColor White
Write-Host "Database: $Database" -ForegroundColor White
Write-Host "Auth    : $authMethod" -ForegroundColor White
Write-Host "Test Set: Essential core functionality" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan

# Ensure testing directory and fixtures exist
$testingDir = Join-Path $PSScriptRoot "testing"
if (-not (Test-Path $testingDir)) { New-Item -ItemType Directory -Path $testingDir -Force | Out-Null }
$printTestFile = Join-Path $testingDir "test-print-statements.sql"
if (-not (Test-Path $printTestFile)) {
    @"
PRINT 'Starting test script'
PRINT 'Before SELECT'
SELECT 'TestValue' AS TestColumn
PRINT 'After SELECT'
"@ | Set-Content $printTestFile -Encoding UTF8
}

function Show-VerboseOutput {
    param([string]$Output, [int]$ExitCode)
    if ($script:Verbose -ge 1) {
        Write-Host "    --- sqlsim output ---" -ForegroundColor DarkGray
        $Output.Trim().Split("`n") | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        Write-Host "    --- end output (exit code: $ExitCode) ---" -ForegroundColor DarkGray
    }
}

function Test-SqlSim {
    param(
        [string]$TestName,
        [string[]]$Arguments,
        [switch]$ShouldFail,
        [string]$ExpectedOutput,
        [string]$NotExpectedOutput
    )
    
    Write-Host "Testing: $TestName" -ForegroundColor Yellow
    
    $output = & $runSqlsim @Arguments 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    
    $passed = $false
    
    if ($ShouldFail) {
        $passed = ($exitCode -ne 0)
    } else {
        $passed = ($exitCode -eq 0)
    }
    
    if ($passed -and $ExpectedOutput) {
        $passed = $output -match [regex]::Escape($ExpectedOutput)
    }
    
    if ($passed -and $NotExpectedOutput) {
        $passed = $output -notmatch [regex]::Escape($NotExpectedOutput)
    }
    
    if ($passed) {
        Write-Host "  ✓ PASSED" -ForegroundColor Green
        $script:testsPassed++
    } else {
        Write-Host "  ✗ FAILED" -ForegroundColor Red
        Write-Host "    Exit Code: $exitCode" -ForegroundColor Gray
        if ($output.Length -lt 500) {
            Write-Host "    Output: $($output.Trim())" -ForegroundColor Gray
        }
        $script:testsFailed++
    }
    
    if ($script:Verbose -ge 1) {
        Write-Host "    --- sqlsim output ---" -ForegroundColor DarkGray
        $output.Trim().Split("`n") | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        Write-Host "    --- end output (exit code: $exitCode) ---" -ForegroundColor DarkGray
    }
    Write-Host ""
}

Write-Host "Testing: Verbose command redacts credentials" -NoNewline
$sqlAuthOutput = & $runSqlsim -S localhost -U user-secret -P password-secret -C -l 1 -Q "SELECT 1" -v 2>&1 | Out-String
$tokenOutput = & $runSqlsim -S localhost -T token-secret -C -l 1 -Q "SELECT 1" -v 2>&1 | Out-String
$connectionStringOutput = & $runSqlsim -c "Driver={ODBC Driver 18 for SQL Server};Server=localhost;UID=user-secret;PWD=password-secret;TrustServerCertificate=yes" -l 1 -Q "SELECT 1" -v 2>&1 | Out-String
$sqlAuthCommand = @($sqlAuthOutput -split "`r?`n" | Where-Object { $_ -match 'Command:' }) -join "`n"
$tokenCommand = @($tokenOutput -split "`r?`n" | Where-Object { $_ -match 'Command:' }) -join "`n"
$connectionStringCommand = @($connectionStringOutput -split "`r?`n" | Where-Object { $_ -match 'Command:' }) -join "`n"
$combinedCommandOutput = $sqlAuthCommand + $tokenCommand + $connectionStringCommand
$credentialsLeaked = $combinedCommandOutput -match 'user-secret|password-secret|token-secret'
$expectedMasksPresent =
    $sqlAuthCommand -match '-U \*{8}.*-P \*{8}' -and
    $tokenCommand -match '-T \*{8}' -and
    $connectionStringCommand -match 'UID=\*{8};PWD=\*{8}'
if (-not $credentialsLeaked -and $expectedMasksPresent) {
    Write-Host "  ✓ PASSED" -ForegroundColor Green
    $script:testsPassed++
} else {
    Write-Host "  ✗ FAILED" -ForegroundColor Red
    Write-Host "    Credentials leaked: $credentialsLeaked, Expected masks: $expectedMasksPresent" -ForegroundColor Gray
    $script:testsFailed++
}
Write-Host ""

# ============================================================
# ESSENTIAL SMOKE TESTS (Core Functionality)
# ============================================================

# Test 1: Help text
Test-SqlSim -TestName "Help text displays" `
    -Arguments @("-h") `
    -ExpectedOutput "Usage:"

# Test 2: Basic connection test
Test-SqlSim -TestName "Basic connection to server" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT * FROM sys.objects", "-q"))

# Test 3: Connection with explicit -S and -d flags (localhost/tempdb)
Test-SqlSim -TestName "Explicit -S localhost -d tempdb" `
    -Arguments (@("-S", "localhost", "-d", "tempdb", "-E", "-Q", "SELECT * FROM sys.objects", "-q"))

# Test 4: Simple query execution (without -q to verify output)
Test-SqlSim -TestName "Simple SELECT query with output" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT * FROM sys.objects", "-r", "1"))

# Test 5: Multi-threaded without -q (3 threads, 2 reps)
Test-SqlSim -TestName "Multi-threaded query with output" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT * FROM sys.objects", "-n", "3", "-r", "2"))

# Test 6: Authentication test
Test-SqlSim -TestName "Authentication ($authMethod)" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT * FROM sys.objects", "-q"))

# Test 7: Query repetition (100 reps)
Test-SqlSim -TestName "Query repetition (-n 100)" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT * FROM sys.objects", "-n", "100", "-q")) `
    -ExpectedOutput "Total batches to execute: 100"

# Test 8: Concurrency test (25 threads, 10 reps)
Test-SqlSim -TestName "Concurrency (25 threads x 10 iterations)" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT * FROM sys.objects", "-n", "25", "-r", "10", "-q")) `
    -ExpectedOutput "Threads: 25"

# Test 9: Quiet mode (-q flag) - suppresses result rows but shows configuration
Test-SqlSim -TestName "Quiet mode suppresses query output" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT 1 AS TestColumn", "-q")) `
    -ExpectedOutput "Total Runtime:" `
    -NotExpectedOutput "row(s) affected"

# Test 10: Verbose mode (-v flag) - verify batch terminology
Test-SqlSim -TestName "Verbose mode shows details" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT 1", "-v", "-q")) `
    -ExpectedOutput "Total batches to execute"

# Test 10b: Non-verbose configuration output - verify batch terminology
Test-SqlSim -TestName "Non-verbose output uses batch terminology" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT 1", "-q")) `
    -ExpectedOutput "Batches in workload"

# Test 11: Invalid connection (error handling)
Test-SqlSim -TestName "Invalid server error handling" `
    -Arguments @("-S", "InvalidServer123", "-d", "tempdb", "-E", "-Q", "SELECT 1", "-l", "1", "-q") `
    -ShouldFail

# Test 12: File input basic test
$testFile = "test-smoke.sql"
"SELECT * FROM sys.objects" | Out-File -FilePath $testFile -Encoding UTF8
Test-SqlSim -TestName "File input (-i flag)" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-i", $testFile, "-q"))
Remove-Item $testFile -ErrorAction SilentlyContinue

# Test 13: GO batch separator
$testFileGO = "test-smoke-go.sql"
@"
SELECT * FROM sys.objects
GO
SELECT * FROM sys.databases
GO
SELECT * FROM sys.schemas
"@ | Out-File -FilePath $testFileGO -Encoding UTF8
Test-SqlSim -TestName "GO batch separators" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-i", $testFileGO, "-q"))
Remove-Item $testFileGO -ErrorAction SilentlyContinue

# Test 14: Output to file (-o flag)
$testOutputFile = "testing\test-smoke-output.txt"
Test-SqlSim -TestName "Output to file (-o flag)" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT 'OutputTest' AS Result", "-o", $testOutputFile, "-q"))
if (Test-Path $testOutputFile) {
    Remove-Item $testOutputFile -ErrorAction SilentlyContinue
}

# Test 15: Application name parameter
Test-SqlSim -TestName "Application name (-app)" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-app", "SmokeTest", "-Q", "SELECT * FROM sys.objects", "-q"))

# Test 16: Connection pooling flag
Test-SqlSim -TestName "Connection pooling (-usepool -reconnect)" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-reconnect", "-usepool", "-Q", "SELECT * FROM sys.objects", "-n", "2", "-q"))

# Test 17: JSON output format
Write-Host "Testing: JSON output format (-json)" -NoNewline
$output = & $runSqlsim @("-S", $Server, "-d", $Database) @authArgs @("-Q", "SELECT 1", "-json", "-q") 2>&1 | Out-String
$exitCode = $LASTEXITCODE
$passed = $false
if ($exitCode -eq 0 -and $output -match '"version"') {
    try {
        $null = $output | ConvertFrom-Json
        Write-Host "  ✓ PASSED" -ForegroundColor Green
        $script:testsPassed++
        $passed = $true
    } catch {
        Write-Host "  ✗ FAILED - Invalid JSON: $_" -ForegroundColor Red
        $script:testsFailed++
    }
}
if (-not $passed -and $exitCode -ne 0) {
    Write-Host "  ✗ FAILED" -ForegroundColor Red
    $script:testsFailed++
} elseif (-not $passed) {
    Write-Host "  ✗ FAILED - Missing version or invalid JSON" -ForegroundColor Red
    $script:testsFailed++
}
Show-VerboseOutput $output $exitCode
Write-Host ""

# Stream JSON output format
$streamInputFile = "testing\test-stream-json.sql"
@"
SELECT 1;
GO
WAITFOR DELAY '00:00:02';
GO
SELECT 2;
"@ | Set-Content $streamInputFile
Write-Host "Testing: Streaming JSON output format (-stream-json)" -NoNewline
$output = & $runSqlsim @("-S", $Server, "-d", $Database) @authArgs @("-i", $streamInputFile, "-stream-json", "-q") | Out-String
$exitCode = $LASTEXITCODE
Remove-Item $streamInputFile -ErrorAction SilentlyContinue
$streamPassed = $false
try {
    $events = @($output -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    $started = @($events | Where-Object type -eq "started")
    $progress = @($events | Where-Object type -eq "progress")
    $completed = @($events | Where-Object type -eq "completed")
    # The first progress event can precede a slow login, so require only that some
    # progress event reports a completed execution and discovered environment metadata.
    $progressWithMetadata = @($progress | Where-Object {
        $_.successful_executions -ge 1 -and
        -not [string]::IsNullOrWhiteSpace($_.odbc_driver_version) -and
        -not [string]::IsNullOrWhiteSpace($_.server_version) -and
        -not [string]::IsNullOrWhiteSpace($_.server_edition)
    })
    $streamPassed = $exitCode -eq 0 -and $started.Count -eq 1 -and $progress.Count -ge 1 -and
        $completed.Count -eq 1 -and $completed[0].status -eq "success" -and
        $progressWithMetadata.Count -ge 1 -and
        -not [string]::IsNullOrWhiteSpace($completed[0].odbc_driver_version) -and
        -not [string]::IsNullOrWhiteSpace($completed[0].server_version) -and
        -not [string]::IsNullOrWhiteSpace($completed[0].server_edition)

    $errorOutput = & $runSqlsim @("-S", $Server, "-d", $Database) @authArgs `
        @("-Q", "SELECT 1; RAISERROR('stream error', 16, 1); SELECT 2", "-stream-json", "-q") | Out-String
    $errorExitCode = $LASTEXITCODE
    $errorEvents = @($errorOutput -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    $streamPassed = $streamPassed -and $errorExitCode -eq 1 -and
        $errorEvents[-1].type -eq "completed" -and $errorEvents[-1].status -eq "error" -and
        $errorEvents[-1].errors -ge 1
} catch {
    $streamPassed = $false
}
if ($streamPassed) {
    Write-Host "  ✓ PASSED" -ForegroundColor Green
    $script:testsPassed++
} else {
    Write-Host "  ✗ FAILED - Invalid or incomplete NDJSON event stream" -ForegroundColor Red
    $script:testsFailed++
}
Show-VerboseOutput $output $exitCode
Write-Host ""

# Streaming JSON with canonical final result
$streamFinalFile = "testing\test-stream-final.json"
Remove-Item $streamFinalFile -ErrorAction SilentlyContinue
Write-Host "Testing: Streaming JSON with canonical final result" -NoNewline
$output = & $runSqlsim @("-S", $Server, "-d", $Database) @authArgs @(
    "-Q", "SELECT 1 AS StreamFinalResult", "-stream-json", "-json",
    "-o", $streamFinalFile, "-q") | Out-String
$exitCode = $LASTEXITCODE
$streamFinalPassed = $false
try {
    $events = @($output -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    $finalResult = Get-Content $streamFinalFile -Raw | ConvertFrom-Json
    $invalidOutput = & $runSqlsim @("-S", $Server, "-d", $Database) @authArgs @(
        "-Q", "SELECT 1", "-stream-json", "-json", "-q") | Out-String
    $invalidExitCode = $LASTEXITCODE
    $streamFinalPassed = $exitCode -eq 0 -and
        $events[0].type -eq "started" -and $events[-1].type -eq "completed" -and
        $events[-1].status -eq "success" -and $finalResult.success -eq $true -and
        $finalResult.configuration.total_batches -eq 1 -and
        $finalResult.configuration.stream_json -eq $true -and
        $invalidExitCode -ne 0
} catch {
    $streamFinalPassed = $false
}
Remove-Item $streamFinalFile -ErrorAction SilentlyContinue
if ($streamFinalPassed) {
    Write-Host "  ✓ PASSED" -ForegroundColor Green
    $script:testsPassed++
} else {
    Write-Host "  ✗ FAILED - Stream or canonical final JSON was invalid" -ForegroundColor Red
    $script:testsFailed++
}
Show-VerboseOutput $output $exitCode
Write-Host ""

# Secure credential input through redirected stdin
Write-Host "Testing: Credentials from redirected stdin (-P - and -T -)" -NoNewline
function Invoke-StdinCredentialTest {
    param([string[]]$Arguments, [string]$Secret)
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Resolve-Path $sqlsimPath).Path
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $null = $startInfo.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $process.StandardInput.WriteLine($Secret)
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout + $stderr }
}
$stdinPassword = "sqlsim-stdin-password"
$passwordResult = Invoke-StdinCredentialTest `
    -Arguments @("-S", "192.0.2.1,1433", "-U", "stdin-user", "-P", "-", "-C", "-l", "1", "-Q", "SELECT 1", "-v", "-q") `
    -Secret $stdinPassword
$stdinToken = "sqlsim-stdin-token-value"
$tokenResult = Invoke-StdinCredentialTest `
    -Arguments @("-S", "192.0.2.1,1433", "-T", "-", "-C", "-l", "1", "-Q", "SELECT 1", "-v", "-q") `
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
$jsonOutputFile = "testing\test-smoke-json.json"
Test-SqlSim -TestName "JSON output to file (-json -o)" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT 1", "-json", "-o", $jsonOutputFile, "-q"))
if (Test-Path $jsonOutputFile) {
    $jsonContent = Get-Content $jsonOutputFile -Raw
    $isValidJson = $false
    try {
        $null = $jsonContent | ConvertFrom-Json
        $isValidJson = $true
    } catch {
        Write-Host "  ✗ Invalid JSON in output file" -ForegroundColor Red
    }
    if (-not $isValidJson) {
        $script:testsFailed++
    }
    Remove-Item $jsonOutputFile -ErrorAction SilentlyContinue
}

# Test 19: Timestamp format validation
Write-Host "Testing: Timestamp format and output features" -NoNewline
$output = & $runSqlsim @("-S", $Server, "-d", $Database) @authArgs @("-Q", "SELECT 1", "-q") 2>&1 | Out-String
$exitCode = $LASTEXITCODE

$hasTimestamp = $false
$hasStartMsg = $false
$hasOverhead = $false
$hasPercentages = $false
$hasStartTime = $false
$hasEndTime = $false
$passed = $false

if ($exitCode -eq 0) {
    # Check for timestamp format: YYYY-MM-DD HH:MM:SS.mmm |
    $hasTimestamp = $output -match '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \|'
    # Check for "Starting execution..." message
    $hasStartMsg = $output -match 'Starting execution'
    # Check for "Total Connection Time" in time breakdown
    $hasTotalConnTime = $output -match 'Total Connection Time:'
    # Check for "% of work" percentages in time breakdown
    $hasPercentages = $output -match '% of work\)'
    # Check for Start Time/End Time in summary (ISO format: YYYY-MM-DDTHH:MM:SS.mmm)
    $hasStartTime = $output -match 'Start Time: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}'
    $hasEndTime = $output -match 'End Time:\s+\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}'
    
    $passed = $hasTimestamp -and $hasStartMsg -and $hasTotalConnTime -and $hasPercentages -and $hasStartTime -and $hasEndTime
}

if ($passed) {
    Write-Host "  ✓ PASSED" -ForegroundColor Green
    $script:testsPassed++
} else {
    Write-Host "  ✗ FAILED" -ForegroundColor Red
    Write-Host "    Exit Code: $exitCode" -ForegroundColor Gray
    Write-Host "    Timestamp format found: $hasTimestamp" -ForegroundColor Gray
    Write-Host "    Starting execution message: $hasStartMsg" -ForegroundColor Gray
    Write-Host "    Total Connection Time line: $hasTotalConnTime" -ForegroundColor Gray
    Write-Host "    Percentages (% of work) found: $hasPercentages" -ForegroundColor Gray
    Write-Host "    Start Time line found: $hasStartTime" -ForegroundColor Gray
    Write-Host "    End Time line found: $hasEndTime" -ForegroundColor Gray
    $script:testsFailed++
}
Show-VerboseOutput $output $exitCode
Write-Host ""

# Test 20: SQL error returns exit code 1
Test-SqlSim -TestName "SQL error returns exit code 1" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "SELECT * FROM nonexistent_table_xyz_12345", "-q")) `
    -ShouldFail `
    -ExpectedOutput "Invalid object name"

# Test 21: Error messages properly captured (regression test for SQL_SUCCESS_WITH_INFO handling)
# Validates that actual SQL error text is shown, not "Unknown ODBC error (SQLGetDiagRec returned 1)"
Write-Host "Testing: Error messages properly captured (not Unknown ODBC error)" -NoNewline
$output = & $runSqlsim @("-S", $Server, "-d", $Database) @authArgs @("-Q", "SELECT * FROM nonexistent_table_xyz_12345") 2>&1 | Out-String
$exitCode = $LASTEXITCODE
$hasRealError = $output -match "Invalid object name"
$noUnknownError = $output -notmatch "Unknown ODBC error"
if ($exitCode -eq 1 -and $hasRealError -and $noUnknownError) {
    Write-Host "  ✓ PASSED" -ForegroundColor Green
    $script:testsPassed++
} else {
    Write-Host "  ✗ FAILED" -ForegroundColor Red
    if (-not $hasRealError) { Write-Host "    Missing expected error text 'Invalid object name'" -ForegroundColor Gray }
    if (-not $noUnknownError) { Write-Host "    Found 'Unknown ODBC error' - SQLGetDiagRec handling bug" -ForegroundColor Gray }
    $script:testsFailed++
}
Show-VerboseOutput $output $exitCode
Write-Host ""

# Test 22: Chained error messages captured (regression test for multi-record diagnostic capture)
# Connection failures typically produce multiple chained diagnostic records
Write-Host "Testing: Chained error messages captured (multiple diagnostic records)" -NoNewline
$output = & $runSqlsim @("-S", "InvalidServerXYZ123", "-d", "tempdb", "-E", "-Q", "SELECT 1", "-l", "1") 2>&1 | Out-String
$exitCode = $LASTEXITCODE
# Connection errors produce multiple diagnostic records, each on its own line
# We expect multiple SQLSTATE errors (e.g., 08001, HYT00) on separate lines
$errorLineCount = ([regex]::Matches($output, "\d{5}:")).Count
$hasChainedErrors = $errorLineCount -ge 2
if ($exitCode -eq 1 -and $hasChainedErrors) {
    Write-Host "  ✓ PASSED" -ForegroundColor Green
    $script:testsPassed++
} else {
    Write-Host "  ✗ FAILED" -ForegroundColor Red
    if (-not $hasChainedErrors) { Write-Host "    Expected multiple SQLSTATE errors on separate lines (found $errorLineCount)" -ForegroundColor Gray }
    $script:testsFailed++
}
Show-VerboseOutput $output $exitCode
Write-Host ""

# Test 23: RAISERROR severity <= 10 is info, not error (exit code 0)
Test-SqlSim -TestName "RAISERROR sev 10 is info (exit code 0)" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "RAISERROR('info message', 10, 1)", "-q"))

# Test 24: PRINT + RAISERROR error combo in same batch (nextResultSet bug fix)
# The error surfaces during SQLMoreResults, not initial SQLExecDirect
Write-Host "Testing: PRINT + RAISERROR error combo (exit code 1)" -NoNewline
$output = & $runSqlsim @("-S", $Server, "-d", $Database) @authArgs @("-Q", "PRINT 'info before error'; RAISERROR('sev16 error', 16, 1)") 2>&1 | Out-String
$exitCode = $LASTEXITCODE
$hasInfo = $output -match 'info before error'
$hasError = $output -match 'sev16 error'
$hasTotalErrors = $output -match 'Total Errors: 1'
if ($exitCode -eq 1 -and $hasInfo -and $hasError -and $hasTotalErrors) {
    Write-Host "  `u{2713} PASSED" -ForegroundColor Green
    $script:testsPassed++
} else {
    Write-Host "  `u{2717} FAILED" -ForegroundColor Red
    if ($exitCode -ne 1) { Write-Host "    Expected exit code 1, got $exitCode" -ForegroundColor Gray }
    if (-not $hasInfo) { Write-Host "    Missing PRINT info message in output" -ForegroundColor Gray }
    if (-not $hasError) { Write-Host "    Missing error message in output" -ForegroundColor Gray }
    if (-not $hasTotalErrors) { Write-Host "    Missing 'Total Errors: 1' in output" -ForegroundColor Gray }
    $script:testsFailed++
}
Show-VerboseOutput $output $exitCode
Write-Host ""

# Test 25: Multi-statement batch with error in non-first statement
Write-Host "Testing: Multi-statement error in non-first statement (exit code 1)" -NoNewline
$output = & $runSqlsim @("-S", $Server, "-d", $Database) @authArgs @("-Q", "SELECT 1 AS val; RAISERROR('mid-batch error', 16, 1); SELECT 2 AS val2") 2>&1 | Out-String
$exitCode = $LASTEXITCODE
$hasError = $output -match 'mid-batch error'
$hasTotalErrors = $output -match 'Total Errors: 1'
if ($exitCode -eq 1 -and $hasError -and $hasTotalErrors) {
    Write-Host "  `u{2713} PASSED" -ForegroundColor Green
    $script:testsPassed++
} else {
    Write-Host "  `u{2717} FAILED" -ForegroundColor Red
    if ($exitCode -ne 1) { Write-Host "    Expected exit code 1, got $exitCode" -ForegroundColor Gray }
    if (-not $hasError) { Write-Host "    Missing error message in output" -ForegroundColor Gray }
    if (-not $hasTotalErrors) { Write-Host "    Missing 'Total Errors: 1' in output" -ForegroundColor Gray }
    $script:testsFailed++
}
Show-VerboseOutput $output $exitCode
Write-Host ""

# Test 26: PRINT statements and T-SQL constructs (regression test for SQLSTATE 24000)
Test-SqlSim -TestName "PRINT statements don't cause cursor errors" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-i", "testing\test-print-statements.sql")) `
    -ExpectedOutput "TestValue"

# Test 24: PRINT statement output display
Test-SqlSim -TestName "PRINT statements are displayed in output" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "PRINT 'Hello from PRINT'; SELECT 1 AS Result")) `
    -ExpectedOutput "Hello from PRINT"

Write-Host "Testing: PRINT control characters are sanitized" -NoNewline
$output = & $runSqlsim @("-S", $Server, "-d", $Database) @authArgs @("-Q", "PRINT CHAR(27) + '[31mSECURITY_MARKER'; SELECT 1") 2>&1 | Out-String
$exitCode = $LASTEXITCODE
$hasMarker = $output.Contains('[31mSECURITY_MARKER')
$hasEscape = $output.Contains([char]27)
if ($exitCode -eq 0 -and $hasMarker -and -not $hasEscape) {
    Write-Host "  ✓ PASSED" -ForegroundColor Green
    $script:testsPassed++
} else {
    Write-Host "  ✗ FAILED" -ForegroundColor Red
    Write-Host "    Exit Code: $exitCode, Marker: $hasMarker, Escape: $hasEscape" -ForegroundColor Gray
    $script:testsFailed++
}
Write-Host ""

# Test 26: PRINT statements suppressed in quiet mode (check it's not between "Starting execution" and "Total Runtime")
Write-Host "Testing: PRINT statements suppressed with -q" -NoNewline
$output = & $runSqlsim @("-S", $Server, "-d", $Database) @authArgs @("-Q", "PRINT 'QuietModePrintTest'; SELECT 1", "-q") 2>&1 | Out-String
$exitCode = $LASTEXITCODE
# Extract the execution section (between "Starting execution" and "Total Runtime") using single-line mode
if ($output -match '(?s)Starting execution.*?Total Runtime') {
    $executionSection = $matches[0]
    $printNotShown = $executionSection -notmatch 'QuietModePrintTest'
} else {
    $printNotShown = $false
}
if ($exitCode -eq 0 -and $printNotShown) {
    Write-Host "  ✓ PASSED" -ForegroundColor Green
    $script:testsPassed++
} else {
    Write-Host "  ✗ FAILED" -ForegroundColor Red
    Write-Host "    Exit Code: $exitCode, PRINT should not appear in execution output" -ForegroundColor Gray
    $script:testsFailed++
}
Show-VerboseOutput $output $exitCode
Write-Host ""

# Test 27: Stored procedure with OUTPUT parameter followed by another batch (cursor state fix)
# Regression test: OUTPUT parameters can leave cursor in invalid state causing SQLSTATE 24000
Test-SqlSim -TestName "Stored proc OUTPUT param + second batch (cursor state)" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "DECLARE @result INT; EXEC sp_executesql N'SELECT @out = 1', N'@out INT OUTPUT', @out = @result OUTPUT; SELECT @result AS Result`nGO`nSELECT 'SecondBatchOK' AS Status")) `
    -ExpectedOutput "SecondBatchOK"

# Test 28: Multiple result sets followed by another batch
Test-SqlSim -TestName "Multi-result proc + second batch (cursor state)" `
    -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-Q", "EXEC sp_executesql N'SELECT 1; SELECT 2; SELECT 3'`nGO`nSELECT 'AfterMultiResult' AS Status")) `
    -ExpectedOutput "AfterMultiResult"

# Test 29: Unicode data retrieval (UTF-8 support)
# Tests that Unicode characters are correctly retrieved and output as UTF-8
Write-Host "Testing: Unicode data retrieval (NCHAR function)" -NoNewline
# Use NCHAR to generate Unicode without needing Unicode in the query string
# NCHAR(26085) = 日, NCHAR(26412) = 本, NCHAR(35486) = 語
$unicodeTestFile = Join-Path $PSScriptRoot "testing\unicode_smoke_test.txt"
$null = & $runSqlsim @("-S", $Server, "-d", $Database) @authArgs @("-Q", "SELECT NCHAR(26085) + NCHAR(26412) + NCHAR(35486) AS japanese") @("-o", $unicodeTestFile) 2>&1
$exitCode = $LASTEXITCODE
$unicodePassed = $false
if ($exitCode -eq 0 -and (Test-Path $unicodeTestFile)) {
    # Read file as UTF-8 and check for Japanese characters
    $content = [System.IO.File]::ReadAllText($unicodeTestFile, [System.Text.Encoding]::UTF8)
    # Check for the actual Japanese characters 日本語
    $unicodePassed = $content -match '日本語'
}
if ($unicodePassed) {
    Write-Host "  ✓ PASSED" -ForegroundColor Green
    $script:testsPassed++
} else {
    Write-Host "  ✗ FAILED" -ForegroundColor Red
    Write-Host "    Unicode characters not found in output (expected 日本語)" -ForegroundColor Gray
    $script:testsFailed++
}
if ($exitCode -eq 0 -and (Test-Path $unicodeTestFile)) {
    Show-VerboseOutput ([System.IO.File]::ReadAllText($unicodeTestFile, [System.Text.Encoding]::UTF8)) $exitCode
} else {
    Show-VerboseOutput "(no output file)" $exitCode
}
Remove-Item $unicodeTestFile -ErrorAction SilentlyContinue
Write-Host ""

# Test 30: Filtered messages - "Changed database context" should NOT appear in output
# USE the current database: Azure SQL Database rejects switching to another
# database, but every target still sends the "Changed database context" message.
Write-Host "Testing: USE database message filtered (not displayed)" -NoNewline
$useDatabase = $Database.Replace(']', ']]')
$output = & $runSqlsim @("-S", $Server, "-d", $Database) @authArgs @("-Q", "USE [$useDatabase]; SELECT 'AfterUse' AS Result") 2>&1 | Out-String
$exitCode = $LASTEXITCODE
$hasResult = $output -match 'AfterUse'
$noChangedDb = $output -notmatch 'Changed database context'
if ($exitCode -eq 0 -and $hasResult -and $noChangedDb) {
    Write-Host "  `u{2713} PASSED" -ForegroundColor Green
    $script:testsPassed++
} else {
    Write-Host "  `u{2717} FAILED" -ForegroundColor Red
    if (-not $hasResult) { Write-Host "    Missing 'AfterUse' result" -ForegroundColor Gray }
    if (-not $noChangedDb) { Write-Host "    'Changed database context' should be filtered" -ForegroundColor Gray }
    $script:testsFailed++
}
Show-VerboseOutput $output $exitCode
Write-Host ""

# Test 31: PRINT suppressed in JSON mode
Write-Host "Testing: PRINT suppressed in JSON mode (-json)" -NoNewline
$output = & $runSqlsim @("-S", $Server, "-d", $Database) @authArgs @("-Q", "PRINT 'JsonPrintSmokeTest'; SELECT 1", "-json") 2>&1 | Out-String
$exitCode = $LASTEXITCODE
# Remove the batches array (which contains the query text) before checking
$outputWithoutBatches = $output -replace '"batches":\s*\[[^\]]*\]', '"batches": []'
if ($exitCode -eq 0 -and $outputWithoutBatches -notmatch 'JsonPrintSmokeTest') {
    Write-Host "  `u{2713} PASSED" -ForegroundColor Green
    $script:testsPassed++
} else {
    Write-Host "  `u{2717} FAILED" -ForegroundColor Red
    if ($exitCode -ne 0) { Write-Host "    Expected exit code 0, got $exitCode" -ForegroundColor Gray }
    Write-Host "    PRINT text should not appear as output in JSON mode" -ForegroundColor Gray
    $script:testsFailed++
}
Show-VerboseOutput $output $exitCode
Write-Host ""

# Test 32: Query timeout error (HYT00)
Write-Host "Testing: Query timeout with -t (HYT00 error)" -NoNewline
$output = & $runSqlsim @("-S", $Server, "-d", $Database) @authArgs @("-Q", "WAITFOR DELAY '00:00:05'", "-t", "1", "-q") 2>&1 | Out-String
$exitCode = $LASTEXITCODE
$hasTimeout = $output -match 'HYT00' -or $output -match 'timeout'
if ($exitCode -eq 1 -and $hasTimeout) {
    Write-Host "  `u{2713} PASSED" -ForegroundColor Green
    $script:testsPassed++
} else {
    Write-Host "  `u{2717} FAILED" -ForegroundColor Red
    if ($exitCode -ne 1) { Write-Host "    Expected exit code 1, got $exitCode" -ForegroundColor Gray }
    if (-not $hasTimeout) { Write-Host "    Missing timeout error (HYT00)" -ForegroundColor Gray }
    $script:testsFailed++
}
Show-VerboseOutput $output $exitCode
Write-Host ""

# Test 33: -stoponerror stops on first error
Write-Host "Testing: -stoponerror stops execution on first error" -NoNewline
$output = & $runSqlsim @("-S", $Server, "-d", $Database) @authArgs @("-Q", "SELECT * FROM nonexistent_table_xyz_stop", "-r", "5", "-stoponerror", "-q") 2>&1 | Out-String
$exitCode = $LASTEXITCODE
$hasStopMsg = $output -match 'STOP.*stoponerror'
# With -stoponerror and -r 5, error count should be 1 (not 5)
$hasSingleError = $output -match 'Total Errors: 1'
if ($exitCode -eq 1 -and $hasStopMsg -and $hasSingleError) {
    Write-Host "  `u{2713} PASSED" -ForegroundColor Green
    $script:testsPassed++
} else {
    Write-Host "  `u{2717} FAILED" -ForegroundColor Red
    if ($exitCode -ne 1) { Write-Host "    Expected exit code 1, got $exitCode" -ForegroundColor Gray }
    if (-not $hasStopMsg) { Write-Host "    Missing STOP message" -ForegroundColor Gray }
    if (-not $hasSingleError) { Write-Host "    Expected 'Total Errors: 1' (not more)" -ForegroundColor Gray }
    $script:testsFailed++
}
Show-VerboseOutput $output $exitCode
Write-Host ""

# ============================================================
# Test 34: Live capture and replay (end-to-end)
# ============================================================
Write-Host "Test 34: Live capture and replay (end-to-end)" -ForegroundColor White
$replayXelDir = "C:\temp"
$replayXelPattern = "$replayXelDir\sqlsim_smoke_capture*.xel"
$replayTraceXml = Join-Path $PSScriptRoot "testing\smoke-replay-trace.xml"
# The server writes the .xel file to its own disk and this machine converts it, so
# the capture needs a SQL Server instance on this Windows machine. Ask the server
# rather than trusting the name: localhost can be a Linux container.
$localProbe = "IF CONVERT(nvarchar(128), SERVERPROPERTY('MachineName')) <> N'$($env:COMPUTERNAME)' " +
    "OR (SELECT TOP (1) host_platform FROM sys.dm_os_host_info) <> N'Windows' " +
    "RAISERROR('not a SQL Server instance on this Windows machine', 16, 1)"
& $runSqlsim @("-S", $Server, "-d", $Database) @authArgs @("-app", "sqlsim_admin", "-Q", $localProbe, "-q") *> $null
$isLocalWindowsInstance = ($LASTEXITCODE -eq 0)
$replayCaptureOk = $isLocalWindowsInstance
if (-not $replayCaptureOk) {
    Write-Host "  - SKIPPED: live XEvent capture needs a SQL Server instance on this Windows machine" -ForegroundColor Yellow
    $script:testsSkipped++
}

# Phase 1: Start XEvent capture (using sqlsim_admin app name so setup is excluded)
if ($replayCaptureOk) {
    Write-Host "  Capturing workload via XEvent..." -ForegroundColor Gray
    Remove-Item $replayXelPattern -ErrorAction SilentlyContinue
}
$setupSql = @"
IF EXISTS(SELECT 1 FROM sys.dm_xe_sessions WHERE name = 'sqlsim_smoke_capture')
    ALTER EVENT SESSION sqlsim_smoke_capture ON SERVER STATE = STOP;
IF EXISTS(SELECT 1 FROM sys.server_event_sessions WHERE name = 'sqlsim_smoke_capture')
    DROP EVENT SESSION sqlsim_smoke_capture ON SERVER;

CREATE EVENT SESSION sqlsim_smoke_capture ON SERVER
ADD EVENT sqlserver.sql_batch_completed(
    ACTION(package0.event_sequence, sqlserver.session_id, sqlserver.database_name)
    WHERE sqlserver.client_app_name = 'sqlsim'
),
ADD EVENT sqlserver.rpc_completed(
    ACTION(package0.event_sequence, sqlserver.session_id, sqlserver.database_name)
    WHERE sqlserver.client_app_name = 'sqlsim'
)
ADD TARGET package0.event_file(
    SET filename = N'$replayXelDir\sqlsim_smoke_capture.xel', max_file_size = 5
)
WITH (MAX_MEMORY = 4096 KB, MAX_DISPATCH_LATENCY = 1 SECONDS);

ALTER EVENT SESSION sqlsim_smoke_capture ON SERVER STATE = START;
"@
# Execute each batch separately via GO
$setupBatches = $setupSql -split "`n`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$setupCombined = $setupBatches -join "`nGO`n"
if ($replayCaptureOk) {
    $captureSetupOutput = & $runSqlsim @("-S", $Server) @authArgs @("-app", "sqlsim_admin", "-Q", $setupCombined, "-q") 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  `u{2717} FAILED - Could not start XEvent capture" -ForegroundColor Red
        Write-Host "    $captureSetupOutput" -ForegroundColor Gray
        $script:testsFailed++
        $replayCaptureOk = $false
    }
}

if ($replayCaptureOk) {
    # Phase 2: Run a simple workload (3 queries to capture)
    $workloadOutput = & $runSqlsim @("-S", $Server, "-d", $Database) @authArgs @("-Q", "SELECT 1 AS smoke_replay_q1`nGO`nSELECT 2 AS smoke_replay_q2`nGO`nSELECT 3 AS smoke_replay_q3", "-q") 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  `u{2717} FAILED - Workload execution failed" -ForegroundColor Red
        $script:testsFailed++
        $replayCaptureOk = $false
    }
}

if ($replayCaptureOk) {
    # Phase 3: Wait for flush and stop capture
    Start-Sleep -Seconds 2
    $stopSql = "ALTER EVENT SESSION sqlsim_smoke_capture ON SERVER STATE = STOP;"
    & $runSqlsim @("-S", $Server) @authArgs @("-app", "sqlsim_admin", "-Q", $stopSql, "-q") 2>&1 | Out-Null

    # Phase 4: Convert .xel to replay XML
    $convertScript = Join-Path $PSScriptRoot "replay\convert-xel.ps1"
    & $convertScript -XelFile $replayXelPattern -OutputFile $replayTraceXml -ServerName $Server 2>&1 | Out-Null
    if (-not (Test-Path $replayTraceXml)) {
        Write-Host "  `u{2717} FAILED - Could not convert .xel to XML" -ForegroundColor Red
        $script:testsFailed++
        $replayCaptureOk = $false
    }
}

if ($replayCaptureOk) {
    # Phase 5: Replay and verify
    $replayOutput = & $runSqlsim @("-S", $Server, "-d", $Database) @authArgs @("-replay", "fast", "-replayfile", $replayTraceXml, "-q") 2>&1 | Out-String
    $replayExit = $LASTEXITCODE

    $hasRuntime = $replayOutput -match "Total Runtime:"
    $hasOriginal = $replayOutput -match "Original trace:\s+(\d+) events \((\d+) ok, (\d+) error"
    $originalEvents = if ($hasOriginal) { [int]$Matches[1] } else { 0 }
    $originalOk = if ($hasOriginal) { [int]$Matches[2] } else { 0 }
    $originalError = if ($hasOriginal) { [int]$Matches[3] } else { 0 }
    $hasResult = $replayOutput -match "Replay result:\s+(\d+) events \((\d+) ok, (\d+) error"
    $resultOk = if ($hasResult) { [int]$Matches[2] } else { 0 }
    $resultError = if ($hasResult) { [int]$Matches[3] } else { 0 }

    if ($replayExit -eq 0 -and $hasRuntime -and $originalEvents -gt 0 -and $originalOk -eq $originalEvents -and $originalError -eq 0 -and $resultOk -eq $originalOk -and $resultError -eq 0) {
        Write-Host "  `u{2713} PASSED (captured $originalEvents events, replayed $resultOk ok)" -ForegroundColor Green
        $script:testsPassed++
    } else {
        Write-Host "  `u{2717} FAILED" -ForegroundColor Red
        if ($replayExit -ne 0) { Write-Host "    Exit code: $replayExit" -ForegroundColor Gray }
        if (-not $hasRuntime) { Write-Host "    Missing 'Total Runtime:'" -ForegroundColor Gray }
        if ($originalEvents -eq 0) { Write-Host "    No events captured (empty trace)" -ForegroundColor Gray }
        if ($originalError -gt 0) { Write-Host "    Original trace had errors" -ForegroundColor Gray }
        if ($resultOk -ne $originalOk) { Write-Host "    Replay count mismatch: original=$originalOk result=$resultOk" -ForegroundColor Gray }
        if ($resultError -gt 0) { Write-Host "    Replay had errors: $resultError" -ForegroundColor Gray }
        $script:testsFailed++
    }
    Show-VerboseOutput $replayOutput $replayExit
}

# Cleanup
Remove-Item $replayTraceXml -ErrorAction SilentlyContinue
Remove-Item $replayXelPattern -ErrorAction SilentlyContinue
if ($isLocalWindowsInstance) {
    $cleanupSql = "IF EXISTS(SELECT 1 FROM sys.server_event_sessions WHERE name = 'sqlsim_smoke_capture') DROP EVENT SESSION sqlsim_smoke_capture ON SERVER;"
    & $runSqlsim @("-S", $Server) @authArgs @("-app", "sqlsim_admin", "-Q", $cleanupSql, "-q") 2>&1 | Out-Null
}
Write-Host ""

# ============================================================
# Test 35: Basic workload file
# ============================================================
Write-Host "Test 35: Basic workload file" -ForegroundColor White
$output = & $runSqlsim @("-S", $Server, "-d", $Database) @authArgs @("-workload", "examples\workload\workload-test.json", "-q") 2>&1 | Out-String
$exitCode = $LASTEXITCODE
if ($exitCode -eq 0 -and $output -match "Workload groups: 2" -and $output -match "Total Runtime:") {
    Write-Host "  `u{2713} PASSED" -ForegroundColor Green
    $script:testsPassed++
} else {
    Write-Host "  `u{2717} FAILED" -ForegroundColor Red
    if ($exitCode -ne 0) { Write-Host "    Exit code: $exitCode" -ForegroundColor Gray }
    if ($output -notmatch "Workload groups: 2") { Write-Host "    Missing 'Workload groups: 2'" -ForegroundColor Gray }
    if ($output -notmatch "Total Runtime:") { Write-Host "    Missing 'Total Runtime:'" -ForegroundColor Gray }
    $script:testsFailed++
}
Show-VerboseOutput $output $exitCode
Write-Host ""

# ============================================================
# Test 36: Workload with querystats
# ============================================================
Write-Host "Test 36: Workload with querystats" -ForegroundColor White
$output = & $runSqlsim @("-S", $Server, "-d", $Database) @authArgs @("-workload", "examples\workload\workload-test.json", "-q", "-querystats") 2>&1 | Out-String
$exitCode = $LASTEXITCODE
if ($exitCode -eq 0 -and $output -match "Query Stats" -and $output -match "Totals:" -and $output -match "Executions:") {
    Write-Host "  `u{2713} PASSED" -ForegroundColor Green
    $script:testsPassed++
} else {
    Write-Host "  `u{2717} FAILED" -ForegroundColor Red
    if ($exitCode -ne 0) { Write-Host "    Exit code: $exitCode" -ForegroundColor Gray }
    if ($output -notmatch "Query Stats") { Write-Host "    Missing 'Query Stats'" -ForegroundColor Gray }
    if ($output -notmatch "Totals:") { Write-Host "    Missing 'Totals:'" -ForegroundColor Gray }
    $script:testsFailed++
}
Show-VerboseOutput $output $exitCode
Write-Host ""

# ============================================================
# Test 36b: Snapshot write failure is reported, not discarded
#
# A mistyped -querystats-file used to leave the run looking completely
# healthy: no file, no message, exit 0. The warning is emitted once so a
# per-interval timer cannot flood the output, and never in JSON or
# streaming modes where it would corrupt a machine-read channel.
# ============================================================
Write-Host "Test 36b: Snapshot write failure is reported" -ForegroundColor White
$unwritableSnapshot = Join-Path ([IO.Path]::GetTempPath()) "sqlsim-no-such-directory\snapshot.json"
$output = & $runSqlsim @("-S", $Server, "-d", $Database) @authArgs @(
    "-Q", "WAITFOR DELAY '00:00:02'; SELECT 1 AS SnapshotWarnProbe",
    "-querystats-interval", "1", "-querystats-file", $unwritableSnapshot, "-q") 2>&1 | Out-String
$exitCode = $LASTEXITCODE
$warningCount = ([regex]::Matches($output, 'could not write the query statistics snapshot')).Count

$streamOutput = & $runSqlsim @("-S", $Server, "-d", $Database) @authArgs @(
    "-Q", "SELECT 1 AS SnapshotStreamProbe",
    "-querystats-interval", "1", "-querystats-file", $unwritableSnapshot,
    "-stream-json", "-q") 2>&1 | Out-String
$streamExit = $LASTEXITCODE
$streamNonEvent = @(($streamOutput -split "`r?`n") |
    Where-Object { $_.Trim() -ne '' -and $_ -notmatch '^\{"type"' }).Count

if ($exitCode -eq 0 -and $warningCount -eq 1 -and
    $streamExit -eq 0 -and $streamNonEvent -eq 0 -and
    -not (Test-Path -LiteralPath $unwritableSnapshot)) {
    Write-Host "  `u{2713} PASSED" -ForegroundColor Green
    $script:testsPassed++
} else {
    Write-Host "  `u{2717} FAILED" -ForegroundColor Red
    if ($exitCode -ne 0) { Write-Host "    Exit code: $exitCode (expected 0)" -ForegroundColor Gray }
    if ($warningCount -ne 1) { Write-Host "    Warnings: $warningCount (expected exactly 1)" -ForegroundColor Gray }
    if ($streamNonEvent -ne 0) { Write-Host "    Stream carried $streamNonEvent non-event line(s)" -ForegroundColor Gray }
    $script:testsFailed++
}
Show-VerboseOutput $output $exitCode
Write-Host ""

# ============================================================
# Tests 37-38: sqlsim performance regression checks
#
# Design notes:
#   These checks intentionally measure ONLY sqlsim's own code paths
#   (iteration loop, threading, ODBC round-trip), not SQL Server engine
#   speed. Workload is `SELECT 1` everywhere — engine cost is
#   sub-microsecond, so wall-clock = sqlsim + ODBC + RTT.
#
#   Pass/fail criteria are derived ratios and per-iteration slopes,
#   NOT absolute wall-clock vs a baseline file. This makes the checks
#   machine-independent: process-start, driver-load, login, and OS
#   scheduling overhead cancel out in subtraction or ratio.
#
#   No baseline JSON is consulted. The measurements/ JSON written at
#   the end is for trend tracking only — it never gates pass/fail.
# ============================================================

function Invoke-PerfRun {
    param([string[]]$ExtraArgs)
    $out = & $runSqlsim @("-S", $Server) @authArgs @("-q", "-Q", "SELECT 1", "-json") @ExtraArgs 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { return $null }
    try { return [double](($out | ConvertFrom-Json).metrics.total_runtime_seconds) } catch { return $null }
}

# ------------------------------------------------------------
# Test 37: P1 — sqlsim per-iteration overhead (iteration-loop slope)
#   Two invocations of SELECT 1 at r=2000 and r=10000 (n=1).
#   per_iter_us = (T_large - T_small) / 8000 * 1e6
#   Subtracting T_small cancels startup + login + driver-load cost,
#   isolating sqlsim's hot path (loop + SQLExecDirect + SQLFetch).
#   Pass: positive per_iter < 2000 us. The ratio is retained as trend
#   telemetry but is not a stable gate on short localhost runs.
# ------------------------------------------------------------
Write-Host "Test 37: sqlsim per-iteration overhead (P1)" -ForegroundColor White
$t_r2k = $null; $t_r10k = $null
if (-not $IsAzure) {
    $t_r2k  = Invoke-PerfRun @("-n", "1", "-r", "2000")
    $t_r10k = Invoke-PerfRun @("-n", "1", "-r", "10000")
}
if ($IsAzure) {
    # The 2000 us ceiling measures client overhead; Azure network latency dominates it.
    Write-Host "  - SKIPPED: client-overhead gate needs a low-latency target, not Azure" -ForegroundColor Yellow
    $script:testsSkipped++
} elseif ($t_r2k -and $t_r10k) {
    $perIterUs = (($t_r10k - $t_r2k) / 8000.0) * 1e6
    $scaleRatio = $t_r10k / $t_r2k
    Write-Host ("  r=2000: {0:N3}s  r=10000: {1:N3}s  ratio: {2:N2}x  per-iter: {3:N0} us" -f $t_r2k, $t_r10k, $scaleRatio, $perIterUs) -ForegroundColor Gray
    if ($perIterUs -gt 0 -and $perIterUs -lt 2000) {
        Write-Host ("  `u{2713} PASSED (per-iter {0:N0} us in (0, 2000); ratio {1:N2}x recorded for trend)" -f $perIterUs, $scaleRatio) -ForegroundColor Green
        $script:testsPassed++
    } else {
        $reason = if ($perIterUs -le 0) { "per-iter slope {0:N0} us is not positive" -f $perIterUs }
                  else { "per-iter {0:N0} us exceeds 2000 us ceiling" -f $perIterUs }
        Write-Host "  `u{2717} FAILED: $reason" -ForegroundColor Red
        $script:testsFailed++
    }
} else {
    Write-Host "  `u{2717} FAILED: sqlsim invocation failed (t_r2k=$t_r2k t_r10k=$t_r10k)" -ForegroundColor Red
    $script:testsFailed++
}
Write-Host ""

# ------------------------------------------------------------
# Test 38: P2 — sqlsim thread scaling
#   SELECT 1 r=5000 per thread at n=1 vs n=4.
#   throughput_scale = (4 * 5000 / T_n4) / (5000 / T_n1)
#                    = 4 * T_n1 / T_n4.
#   Pass: throughput scale >= 2.0 (4 threads must give at least 2x even on
#   HT-only / E-core hardware).
# ------------------------------------------------------------
Write-Host "Test 38: sqlsim thread scaling (P2)" -ForegroundColor White
$t_n1 = Invoke-PerfRun @("-n", "1", "-r", "5000")
$t_n4 = Invoke-PerfRun @("-n", "4", "-r", "5000")
if ($t_n1 -and $t_n4) {
    $throughputScale = (4.0 * $t_n1) / $t_n4
    Write-Host ("  n=1: {0:N3}s  n=4: {1:N3}s  throughput scaling: {2:N2}x" -f $t_n1, $t_n4, $throughputScale) -ForegroundColor Gray
    if ($throughputScale -ge 2.0) {
        Write-Host ("  `u{2713} PASSED (throughput scaling {0:N2}x >= 2.0x)" -f $throughputScale) -ForegroundColor Green
        $script:testsPassed++
    } else {
        Write-Host ("  `u{2717} FAILED: throughput scaling {0:N2}x below 2.0x floor \u2014 threading regression suspected" -f $throughputScale) -ForegroundColor Red
        $script:testsFailed++
    }
} else {
    Write-Host "  `u{2717} FAILED: sqlsim invocation failed (t_n1=$t_n1 t_n4=$t_n4)" -ForegroundColor Red
    $script:testsFailed++
}

# Save perf measurements (trend tracking only — no pass/fail gate)
if ($t_r2k -and $t_r10k -and $t_n1 -and $t_n4) {
    $measureDir = Join-Path $PSScriptRoot "measurements"
    if (-not (Test-Path $measureDir)) { New-Item -ItemType Directory -Path $measureDir -Force | Out-Null }
    $ts = Get-Date -Format "yyyy-MM-dd-HHmmss"
    $blCpu = (Get-CimInstance Win32_Processor | Select-Object -First 1)
    $blVerOut = & $runSqlsim -S $Server @authArgs -Q "SELECT 1" -v -json -q 2>$null
    try { $blVerJson = ($blVerOut -join "`n" | ConvertFrom-Json) } catch { $blVerJson = $null }
    $blSqlEd = if ($blVerJson -and $blVerJson.server_edition) { $blVerJson.server_edition } else { "" }
    $blSqlVer = if ($blVerJson -and $blVerJson.server_version) { $blVerJson.server_version } else { "Unknown" }
    $measureData = [ordered]@{
        timestamp = $ts
        source = "smoke-test"
        tag = $PerfTag
        machine = [ordered]@{
            hostname = $env:COMPUTERNAME
            cpu = $blCpu.Name.Trim()
            cores_physical = $blCpu.NumberOfCores
            cores_logical = $blCpu.NumberOfLogicalProcessors
            ram_gb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
            os = (Get-CimInstance Win32_OperatingSystem).Caption.Trim()
        }
        server = $Server
        sql_server_edition = $blSqlEd
        sql_server_version = $blSqlVer
        checks = [ordered]@{
            p1_per_iter_us    = [math]::Round((($t_r10k - $t_r2k) / 8000.0) * 1e6, 1)
            p1_scaling_ratio  = [math]::Round($t_r10k / $t_r2k, 3)
            p2_throughput_scale = [math]::Round((4.0 * $t_n1) / $t_n4, 3)
        }
        raw_seconds = [ordered]@{
            r2000_n1  = $t_r2k
            r10000_n1 = $t_r10k
            r5000_n1  = $t_n1
            r5000_n4  = $t_n4
        }
    }
    $measureFile = Join-Path $measureDir "smoke-perf-$ts.json"
    $measureData | ConvertTo-Json -Depth 5 | Set-Content $measureFile -Encoding UTF8
    Write-Host "  Perf measurement saved: $measureFile" -ForegroundColor DarkGray
    if ($PerfTag) { Write-Host "  Tag: $PerfTag" -ForegroundColor DarkGray }
}
Write-Host ""

# ============================================================
# Test 39: Duration mode workload (duration_seconds)
# ============================================================
Write-Host "Test 39: Duration mode workload (duration_seconds)" -ForegroundColor White
$durationWorkloadFile = "testing\test-duration-workload.json"
@'
{
    "duration_seconds": 3,
    "workloads": [
        {
            "queries": ["SELECT 1"],
            "threads": 2
        }
    ]
}
'@ | Set-Content $durationWorkloadFile -Encoding UTF8
$output = & $runSqlsim @("-S", $Server, "-d", $Database) @authArgs @("-workload", $durationWorkloadFile, "-q") 2>&1 | Out-String
$exitCode = $LASTEXITCODE
$hasDuration = $output -match "Duration: 3 seconds"
$hasRuntime = $output -match "Total Runtime:"
$passed = ($exitCode -eq 0 -and $hasDuration -and $hasRuntime)
if ($passed) {
    Write-Host "  `u{2713} PASSED" -ForegroundColor Green
    $script:testsPassed++
} else {
    Write-Host "  `u{2717} FAILED" -ForegroundColor Red
    if ($exitCode -ne 0) { Write-Host "    Exit code: $exitCode" -ForegroundColor Gray }
    if (-not $hasDuration) { Write-Host "    Missing 'Duration: 3 seconds' in output" -ForegroundColor Gray }
    if (-not $hasRuntime) { Write-Host "    Missing 'Total Runtime:'" -ForegroundColor Gray }
    $script:testsFailed++
}
Show-VerboseOutput $output $exitCode
Remove-Item $durationWorkloadFile -ErrorAction SilentlyContinue
Write-Host ""

# ============================================================
# RESULTS SUMMARY
# ============================================================

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "SMOKE TEST RESULTS" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Passed : $testsPassed" -ForegroundColor Green
Write-Host "Failed : $testsFailed" -ForegroundColor $(if ($testsFailed -eq 0) { "Green" } else { "Red" })
Write-Host "Skipped: $testsSkipped" -ForegroundColor Yellow
Write-Host "Total  : $($testsPassed + $testsFailed + $testsSkipped)" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan

# Restore original directory
Pop-Location

# Stop transcript if active
if ($OutputFile) {
    Stop-Transcript | Out-Null
    Write-Host "Output saved to: $OutputFile" -ForegroundColor Cyan
}

if ($testsFailed -eq 0) {
    Write-Host "✓ All smoke tests passed! Core functionality verified." -ForegroundColor Green
    Write-Host "  Run full-test-suite.ps1 for comprehensive validation." -ForegroundColor Cyan
    exit 0
} else {
    Write-Host "✗ Some smoke tests failed. Check output above." -ForegroundColor Red
    exit 1
}
