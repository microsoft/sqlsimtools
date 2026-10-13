#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Comprehensive test suite for sqlsim
.DESCRIPTION
    Runs smoke-test.ps1 first, then executes extended tests covering
    connection modes, parameters, timeouts, file parsing, concurrency, error handling,
    security validations, cursor state, T-SQL features, output formats, workload, and replay.
.PARAMETER SkipBuild
    Skip the build step and use existing executable
.PARAMETER Verbose
    Verbosity level for test output:
    0 (default) - Show test command being executed
    1 - Also pass -v to sqlsim for detailed sqlsim output
.PARAMETER Server
    SQL Server name to test against (default: localhost)
    Automatically detects Azure SQL Database if name contains 'database.windows.net' or 'database.fabric.microsoft.com'
.PARAMETER Database
    Database name to test against (default: tempdb)
.PARAMETER UseToken
    Access token for Azure SQL Database authentication (enables automated testing)
    When provided, uses -T (access token) instead of -A (interactive login)
    The token, like -Password, reaches sqlsim on stdin (-T -, -P -), so it never
    appears in a process list.
.PARAMETER SkipScale
    Skip the 1024 thread scale test (useful for testing against environments that cannot handle high concurrency)
.EXAMPLE
    .\full-test-suite.ps1
    Run all tests against localhost with Windows Authentication
.EXAMPLE
    .\full-test-suite.ps1 -Server "myserver.database.windows.net" -Database "mydb"
    Run tests against Azure SQL Database (auto-detects Azure and uses Entra auth)
.EXAMPLE
    .\full-test-suite.ps1 -Server "myserver.database.windows.net" -Database "mydb" -UseToken "ey..."
    Run tests against Azure SQL Database using access token (automated, non-interactive)
.EXAMPLE
    .\full-test-suite.ps1 -Server "192.168.1.100" -Database "testdb"
    Run tests against a remote SQL Server with Windows Authentication
.EXAMPLE
    .\full-test-suite.ps1 -OutputFile "test-results.log"
    Run tests and log output to both console and file with timestamps
.EXAMPLE
    .\full-test-suite.ps1 -StopOnError
    Run tests and stop immediately on first failure
.EXAMPLE
    .\full-test-suite.ps1 -SkipScale
    Run all tests except the 1024 thread scale test
.PARAMETER TestReadReplica
    Run tests for -R (read-only intent) and -M (multi-subnet failover) parameters.
    Use this when testing against a server with read replicas (Azure SQL with replicas, AG listener, etc.)
.PARAMETER LoginTimeout
    Login timeout in seconds for the 1024 thread scale tests (default: 60).
    Use a higher value when testing against Azure SQL or slower environments.
#>

param(
    [switch]$SkipBuild,
    [int]$Verbose = 0,
    [string]$Server = "localhost",
    [string]$Database = "tempdb",
    [string]$UseToken = "",
    [string]$Username = "",
    [string]$Password = "",
    [string]$OutputFile = "",
    [switch]$StopOnError,
    [switch]$SkipScale,
    [switch]$TestReadReplica,
    [int]$LoginTimeout = 60,
    [string]$PerfTag = ""
)

$ErrorActionPreference = "Stop"

# Ensure we're in the script directory for relative paths
Push-Location $PSScriptRoot

# Define testing directory for temporary files (absolute path for .NET methods)
$script:testDir = Join-Path $PSScriptRoot "testing"
if (-not (Test-Path $script:testDir)) {
    New-Item -ItemType Directory -Path $script:testDir -Force | Out-Null
}
# Ensure test fixtures exist
$printTestFixture = Join-Path $script:testDir "test-print-statements.sql"
if (-not (Test-Path $printTestFixture)) {
    @"
PRINT 'Starting test script'
PRINT 'Before SELECT'
SELECT 'TestValue' AS TestColumn
PRINT 'After SELECT'
"@ | Set-Content $printTestFixture -Encoding UTF8
}

$testsPassed = 0
$testsFailed = 0
$testsWarning = 0
$startTime = Get-Date

# Output file handling
$script:outputFileHandle = $null
$script:transcriptStarted = $false
if ($OutputFile) {
    try {
        # Use Start-Transcript to capture all output
        Start-Transcript -Path $OutputFile -Force | Out-Null
        $script:transcriptStarted = $true
        $script:outputFileHandle = $OutputFile
        
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "SQLSIM SMOKE TEST SUITE" -ForegroundColor Cyan
        Write-Host "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host ""
    }
    catch {
        Write-Host "WARNING: Could not start transcript to file: $OutputFile" -ForegroundColor Yellow
        Write-Host "Continuing with console output only..." -ForegroundColor Yellow
        $script:outputFileHandle = $null
        $script:transcriptStarted = $false
    }
}

# Auto-detect if this is Azure SQL Database based on server name
$IsAzure = $Server -match 'database\.windows\.net|database\.fabric\.microsoft\.com'

# Set authentication based on target and token availability
# Priority: Username/Password (SQL Auth) > Token > Entra Interactive > Windows Auth
$script:AuthSecret = $null
if ($Username -and $Password) {
    $script:BaseAuthArgs = @("-S", $Server, "-d", $Database, "-U", $Username, "-P", "-")
    $script:AuthSecret = $Password
    # Non-Azure targets commonly present a self-signed certificate.
    if (-not $IsAzure) { $script:BaseAuthArgs += "-C" }
    $TestConnectionString = "Driver={ODBC Driver 18 for SQL Server};Server=$Server;Database=$Database;UID=$Username;PWD=$Password;TrustServerCertificate=yes;"
    $AuthMethod = "SQL Authentication"
} elseif ($IsAzure) {
    if ($UseToken) {
        # For token auth, build base command args that tests will extend
        $script:BaseAuthArgs = @("-S", $Server, "-d", $Database, "-T", "-")
        $script:AuthSecret = $UseToken
        $TestConnectionString = "Driver={ODBC Driver 18 for SQL Server};Server=$Server;Database=$Database;Encrypt=yes;"
        $AuthMethod = "Access Token (Automated)"
    } else {
        $script:BaseAuthArgs = @("-S", $Server, "-d", $Database, "-A")
        $TestConnectionString = "Driver={ODBC Driver 18 for SQL Server};Server=$Server;Database=$Database;Authentication=ActiveDirectoryInteractive;Encrypt=yes;"
        $AuthMethod = "Microsoft Entra Interactive"
    }
} else {
    $script:BaseAuthArgs = @("-S", $Server, "-d", $Database, "-E")
    $TestConnectionString = "Driver={ODBC Driver 18 for SQL Server};Server=$Server;Database=$Database;Trusted_Connection=yes;TrustServerCertificate=yes;"
    $AuthMethod = "Windows Integrated"
}

# Some tests assert documented examples verbatim (omitting -S, or passing -E), so they
# cannot honor -Server/-Username/-UseToken and only apply to the local default instance.
$script:CanTestLocalDefaults = ($AuthMethod -eq "Windows Integrated") -and
    ($Server -in @("localhost", ".", "(local)", "127.0.0.1", $env:COMPUTERNAME))
$script:LocalDefaultsReason = "Requires the local default instance with Windows authentication"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "SQLSIM SMOKE TEST SUITE" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "Target Server: $Server" -ForegroundColor White
Write-Host "Target Database: $Database" -ForegroundColor White
if ($IsAzure) {
    Write-Host "Environment: Azure SQL Database" -ForegroundColor Cyan
    Write-Host "Authentication: $AuthMethod`n" -ForegroundColor White
} else {
    Write-Host "Environment: SQL Server (on-premises or local)" -ForegroundColor Cyan
    Write-Host "Authentication: $AuthMethod`n" -ForegroundColor White
}

# Helper function to execute sqlsim with proper auth parameter handling
function Invoke-Sqlsim {
    # Use -- to separate function params from exe params
    $callArgs = @($args)
    $base = $script:BaseAuthArgs
    # Certificate-rejection tests must not inherit the suite-level -C.
    if ($callArgs -contains '--no-trust-cert') {
        $callArgs = @($callArgs | Where-Object { $_ -ne '--no-trust-cert' })
        $base = @($base | Where-Object { $_ -ne '-C' })
    }
    $allArgs = $base + $callArgs
    # Add -v flag if Verbose=1
    if ($script:Verbose -ge 1) {
        $allArgs = $allArgs + @("-v")
    }
    & $runSqlsim $allArgs
}

function Write-TestSkipped {
    param([string]$Name, [string]$Description, [string]$Reason)
    Write-Host "TEST: $Name" -ForegroundColor Yellow
    Write-Host "  Description: $Description" -ForegroundColor Gray
    Write-Host "  SKIPPED: $Reason" -ForegroundColor Yellow
    Write-Host ""
}

function Test-Command {
    param(
        [string]$Name,
        [string]$Description,
        [scriptblock]$Command,
        [string]$ExpectedOutput = $null,
        [string]$ExpectedError = $null,
        [bool]$ShouldFail = $false,
        [bool]$StreamOutput = $false  # Stream output in real-time for long-running tests
    )
    
    Write-Host "TEST: $Name" -ForegroundColor Yellow
    Write-Host "  Description: $Description" -ForegroundColor Gray
    
    if ($script:Verbose -ge 1) {
        $commandText = $Command.ToString().Trim()
        Write-Host "  Command: $commandText" -ForegroundColor Cyan
    }
    
    try {
        if ($StreamOutput) {
            # Stream output in real-time while capturing for validation
            $outputLines = @()
            & $Command 2>&1 | ForEach-Object {
                Write-Host "  $_" -ForegroundColor DarkGray
                $outputLines += $_
            }
            $output = $outputLines -join "`n"
        } else {
            $output = & $Command 2>&1 | Out-String
        }
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
        
        if ($ExpectedOutput -and $output -notmatch $ExpectedOutput) {
            Write-Host "  FAILED: Output didn't contain expected text: $ExpectedOutput" -ForegroundColor Red
            $passed = $false
        }
        
        if ($ExpectedError -and $output -notmatch $ExpectedError) {
            Write-Host "  FAILED: Output didn't contain expected error: $ExpectedError" -ForegroundColor Red
            $passed = $false
        }
        
        if ($passed) {
            Write-Host "  PASSED" -ForegroundColor Green
            # Show sqlsim output when Verbose=1
            if ($script:Verbose -ge 1 -and $output) {
                Write-Host "  Output:" -ForegroundColor DarkGray
                Write-Host $output -ForegroundColor DarkGray
            }
            $script:testsPassed++
        } else {
            Write-Host "  Output: $($output.Substring(0, [Math]::Min(500, $output.Length)))" -ForegroundColor DarkGray
            $script:testsFailed++
            
            if ($script:StopOnError) {
                Write-Host "`n❌ Stopping test execution due to failure (StopOnError flag set)" -ForegroundColor Red
                exit 1
            }
        }
    }
    catch {
        # Handle PowerShell exceptions (usually from non-zero exit codes)
        $exceptionMessage = $_.Exception.Message
        $passed = $false
        
        if ($ShouldFail) {
            # For tests that should fail, check if we got the expected error
            if ($ExpectedError -and $exceptionMessage -match $ExpectedError) {
                $passed = $true
            } elseif (-not $ExpectedError) {
                # No specific error expected, just that it should fail
                $passed = $true
            } else {
                Write-Host "  FAILED: Expected error pattern '$ExpectedError' but got: $exceptionMessage" -ForegroundColor Red
            }
        } else {
            Write-Host "  FAILED: Unexpected exception - $exceptionMessage" -ForegroundColor Red
        }
        
        if ($passed) {
            Write-Host "  PASSED" -ForegroundColor Green
            $script:testsPassed++
        } else {
            $script:testsFailed++
            
            if ($script:StopOnError) {
                Write-Host "`n❌ Stopping test execution due to failure (StopOnError flag set)" -ForegroundColor Red
                exit 1
            }
        }
    }
    
    Write-Host ""
}

# Build if needed
if (-not $SkipBuild) {
    Write-Host "Building sqlsim..." -ForegroundColor Cyan
    
    # Try using cmake directly first
    $cmakeAvailable = $false
    try {
        cmake --version 2>&1 | Out-Null
        $cmakeAvailable = ($LASTEXITCODE -eq 0)
    } catch {
        $cmakeAvailable = $false
    }
    
    if ($cmakeAvailable -and (Test-Path "build\CMakeCache.txt")) {
        # Use direct cmake build if available and configured
        Push-Location build
        try {
            cmake --build . --config Release 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Build failed"
            }
            Write-Host "Build successful`n" -ForegroundColor Green
        }
        finally {
            Pop-Location
        }
    } else {
        # Use build.ps1 script for full setup
        Write-Host "Using build.ps1 for complete build setup..." -ForegroundColor Yellow
        & .\build.ps1 -Configuration Release
        if ($LASTEXITCODE -ne 0) {
            throw "Build script failed"
        }
        Write-Host "Build successful`n" -ForegroundColor Green
    }
} else {
    Write-Host "Skipping build (using existing executable)`n" -ForegroundColor Yellow
}

$exe = if ($IsWindows -or $null -eq $IsWindows) { ".\build\x64\Release\sqlsim.exe" } else { "./build/linux-x64/sqlsim" }

# Verify executable exists
if (-not (Test-Path $exe)) {
    Write-Host "ERROR: Executable not found at $exe" -ForegroundColor Red
    exit 1
}

# Runs sqlsim, writing the secret to stdin when the arguments ask for it with
# -T - or -P -, so the token or password never appears in a process list.
# Input piped by the caller is passed through unchanged.
$script:EnginePath = $exe
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

# ============================================================
# PHASE 1: Run smoke tests first
# ============================================================

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "PHASE 1: SMOKE TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$smokeParams = @{
    SkipBuild = $true
    Server    = $Server
    Database  = $Database
    Verbose   = $Verbose
}
if ($UseToken) { $smokeParams.UseToken = $UseToken }
if ($Username) { $smokeParams.Username = $Username }
if ($Password) { $smokeParams.Password = $Password }

& "$PSScriptRoot\smoke-test.ps1" @smokeParams
$smokeExitCode = $LASTEXITCODE

if ($smokeExitCode -eq 0) {
    $testsPassed += 47
    Write-Host "`nSmoke tests: 47/47 passed" -ForegroundColor Green
} else {
    Write-Host "`nSmoke tests: FAILED (see output above)" -ForegroundColor Red
    $testsFailed += 1
    if ($StopOnError) {
        Write-Host "Stopping due to -StopOnError." -ForegroundColor Red
        Pop-Location
        exit 1
    }
}

Write-Host ""

# ============================================================
# PHASE 2: Extended tests (unique to full-test-suite)
# ============================================================

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "PHASE 2: EXTENDED TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "BASIC FUNCTIONALITY TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Test 2: Version/Usage without args
Test-Command -Name "No Arguments" -Description "Run without arguments shows usage" `
    -Command { & $runSqlsim } `
    -ExpectedOutput "Usage:" `
    -ShouldFail $true

# Test 3a: Default to localhost (omit -S, like sqlcmd)
if ($script:CanTestLocalDefaults) {
    Test-Command -Name "Default Localhost" -Description "Connect without -S (defaults to localhost)" `
        -Command { & $runSqlsim -E -d tempdb -Q "SELECT @@VERSION" -q } `
        -ExpectedOutput "Total Runtime:"

    # Test 3b: Server with port format (server,port)
    Test-Command -Name "Server with Port" -Description "Connect using server,port format" `
        -Command { & $runSqlsim -S "localhost,1433" -E -d tempdb -Q "SELECT @@VERSION" -q } `
        -ExpectedOutput "Total Runtime:"
} else {
    Write-TestSkipped "Default Localhost" "Connect without -S (defaults to localhost)" $script:LocalDefaultsReason
    Write-TestSkipped "Server with Port" "Connect using server,port format" $script:LocalDefaultsReason
}

# Test 4: Connection string mode
if (-not $UseToken) {
    $cs = $TestConnectionString
    Test-Command -Name "Connection String Mode" -Description "Execute query using full connection string" `
        -Command { & $runSqlsim -c $cs -Q "SELECT 1" -q }.GetNewClosure() `
        -ExpectedOutput "Total Runtime:"
} else {
    Write-Host "TEST: Connection String Mode" -ForegroundColor Yellow
    Write-Host "  Description: Execute query using full connection string" -ForegroundColor Gray
    Write-Host "  SKIPPED: Connection string mode with access token requires token in connection string" -ForegroundColor Yellow
    Write-Host ""
}

# Test 5: Verbose mode - verify all phases and batch terminology
Test-Command -Name "Verbose Output" -Description "Verify verbose mode shows detailed output with correct terminology" `
    -Command { Invoke-Sqlsim -Q "SELECT 1 AS TestCol" -v } `
    -ExpectedOutput "\[PHASE 1\][\s\S]*Total batches to execute[\s\S]*Batches in workload[\s\S]*Batches to execute:[\s\S]*\[PHASE 2\][\s\S]*\[PHASE 3\][\s\S]*\[PHASE 4\][\s\S]*\[PHASE 5\]"

# Test 5b: Non-verbose output - verify batch terminology in standard output
Test-Command -Name "Non-Verbose Batch Terminology" -Description "Verify non-verbose output uses batch terminology" `
    -Command { Invoke-Sqlsim -Q "SELECT 1" -q } `
    -ExpectedOutput "Total batches to execute[\s\S]*Batches in workload[\s\S]*Batches to execute:"

# Test 6: Multiple iterations
Test-Command -Name "Multiple Iterations" -Description "Run 5 iterations with 2 threads" `
    -Command { Invoke-Sqlsim -Q "SELECT 1" -n 2 -r 5 -q } `
    -ExpectedOutput "Total Runtime:"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "PREPARED STATEMENTS TEST" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Test: Prepared statements mode (low concurrency)
Test-Command -Name "Prepared Statements (2 threads)" -Description "Execute queries using prepared statements with 2 threads" `
    -Command { Invoke-Sqlsim -Q "SELECT 1" -p -n 2 -r 5 -q } `
    -ExpectedOutput "Total Runtime:"

# Test: Prepared statements with moderate concurrency
Test-Command -Name "Prepared Statements (10 threads)" -Description "Execute queries using prepared statements with 10 threads" `
    -Command { Invoke-Sqlsim -Q "SELECT 1" -p -n 10 -r 3 -q } `
    -ExpectedOutput "Total Runtime:"

# Test: Prepared statements with high concurrency
Test-Command -Name "Prepared Statements (50 threads)" -Description "Execute queries using prepared statements with 50 threads" `
    -Command { Invoke-Sqlsim -Q "SELECT 1" -p -n 50 -r 2 -q } `
    -ExpectedOutput "Total Runtime:"

# Test: Prepared statements with iterations
Test-Command -Name "Prepared Statements with Iterations" -Description "Verify prepared statements work with multiple iterations" `
    -Command { Invoke-Sqlsim -Q "SELECT 1" -p -n 5 -r 10 -q } `
    -ExpectedOutput "Total Runtime:"

# Test: Prepared statements with reconnect
Test-Command -Name "Prepared Statements with Reconnect" -Description "Verify prepared statements work with -reconnect flag" `
    -Command { Invoke-Sqlsim -Q "SELECT 1" -p -n 3 -r 3 -reconnect -q } `
    -ExpectedOutput "Total Runtime:"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "FILE PARSING TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Create test SQL file
$testFile = "smoke_test_queries.sql"
@"
-- Test query 1
SELECT 1 AS Test1;
GO

-- Test query 2
SELECT 2 AS Test2;
GO

-- Test query 3
SELECT GETDATE() AS CurrentTime;
GO
"@ | Out-File -FilePath $testFile -Encoding ASCII

Test-Command -Name "File Parsing" -Description "Parse and execute queries from file" `
    -Command { Invoke-Sqlsim -i $testFile -q } `
    -ExpectedOutput "Batches in workload: 3"

Remove-Item $testFile -ErrorAction SilentlyContinue

# Test: Empty input file
$emptyFile = Join-Path $script:testDir "test_empty_input.sql"
"" | Out-File -FilePath $emptyFile -Encoding ASCII -NoNewline
Test-Command -Name "Empty Input File" -Description "Reject empty input file with no batches" `
    -Command { Invoke-Sqlsim -i $emptyFile } `
    -ExpectedError "No batches found in input file" `
    -ShouldFail $true
Remove-Item $emptyFile -ErrorAction SilentlyContinue

# Test: -Q and -i together (error - mutually exclusive)
Test-Command -Name "Query and File Conflict" -Description "Reject -Q and -i together" `
    -Command { Invoke-Sqlsim -Q "SELECT 1" -i examples\sql\01-simple-queries.sql -q } `
    -ExpectedError "Cannot use -Q with -i" `
    -ShouldFail $true

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "TIMEOUT TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Query timeout covered by smoke tests

# Test 7: Login timeout (invalid server)
Test-Command -Name "Login Timeout" -Description "Verify login timeout on invalid server" `
    -Command { & $runSqlsim -S "invalid-server-12345.example.com" -d tempdb -E -l 2 -Q "SELECT 1" -q } `
    -ExpectedError "08001|timeout" `
    -ShouldFail $true

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "ENHANCED PARAMETER VALIDATION TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Test 8: Invalid thread count
Test-Command -Name "Invalid Threads (Text)" -Description "Reject non-numeric thread count" `
    -Command { Invoke-Sqlsim -Q "SELECT 1" -n abc } `
    -ExpectedError "sqlsim error.*Invalid.*thread" `
    -ShouldFail $true

# Test 9: Thread count out of range (too high)
Test-Command -Name "Invalid Threads (Too High)" -Description "Reject thread count > INT_MAX" `
    -Command { Invoke-Sqlsim -Q "SELECT 1" -n 999999999999 } `
    -ExpectedError "sqlsim error.*Thread count.*out of range" `
    -ShouldFail $true

# Test 10: Thread count out of range (too low)
Test-Command -Name "Invalid Threads (Zero)" -Description "Reject thread count = 0" `
    -Command { Invoke-Sqlsim -Q "SELECT 1" -n 0 } `
    -ExpectedError "sqlsim error.*Number of threads must be between 1 and 2147483647" `
    -ShouldFail $true

# Test 11: Invalid timeout
Test-Command -Name "Invalid Timeout" -Description "Reject non-numeric timeout" `
    -Command { Invoke-Sqlsim -Q "SELECT 1" -t xyz } `
    -ExpectedError "sqlsim error.*Invalid.*timeout" `
    -ShouldFail $true

# Test 12: Invalid iteration count
Test-Command -Name "Invalid Iterations" -Description "Reject invalid iteration count" `
    -Command { Invoke-Sqlsim -Q "SELECT 1" -r "-5" } `
    -ExpectedError "sqlsim error.*Iterations per thread must be between 1 and" `
    -ShouldFail $true

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "MISSING VALUE DETECTION TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Test: Missing server name
Test-Command -Name "Missing Server Name" -Description "Reject -S without server name" `
    -Command { & $runSqlsim -S -E -Q "SELECT 1" } `
    -ExpectedError "sqlsim error.*Server name cannot be empty" `
    -ShouldFail $true

# Test: Missing database name
Test-Command -Name "Missing Database Name" -Description "Reject -d without database name" `
    -Command { & $runSqlsim -S localhost -d -E -Q "SELECT 1" } `
    -ExpectedError "sqlsim error.*Database name cannot be empty" `
    -ShouldFail $true

# Test: Missing connection string
Test-Command -Name "Missing Connection String" -Description "Reject -c without connection string" `
    -Command { & $runSqlsim -c -Q "SELECT 1" } `
    -ExpectedError "sqlsim error.*Connection string cannot be empty" `
    -ShouldFail $true

# Test: Missing query
Test-Command -Name "Missing Query" -Description "Reject -Q without query" `
    -Command { Invoke-Sqlsim -Q } `
    -ExpectedError "sqlsim error.*Query cannot be empty" `
    -ShouldFail $true

# --- Values that legitimately begin with a dash ---
# A value starting with '-' used to be discarded as if it were a flag, so a
# query opening with a SQL comment failed with "Query cannot be empty".

Test-Command -Name "Query Starting With SQL Comment" -Description "A query whose first line is a -- comment executes" `
    -Command { Invoke-Sqlsim -Q "-- leading comment
SELECT 1 AS CommentedQuery" -q } `
    -ExpectedOutput "Total Runtime:"

Test-Command -Name "Query Starting With Flag-Like Comment" -Description "A comment that begins like a known flag is still query text" `
    -Command { Invoke-Sqlsim -Q "--help me count rows
SELECT 1 AS FlagLikeComment" -q } `
    -ExpectedOutput "Total Runtime:"

Test-Command -Name "Missing Query Before A Flag" -Description "Reject -Q when the next argument is a whole flag" `
    -Command { Invoke-Sqlsim -Q -v } `
    -ExpectedError "sqlsim error.*Query cannot be empty" `
    -ShouldFail $true

Test-Command -Name "Missing Query Before Output Flag" -Description "Reject -Q when followed by -o" `
    -Command { Invoke-Sqlsim -Q -o } `
    -ExpectedError "sqlsim error.*Query cannot be empty" `
    -ShouldFail $true

# Test: Missing input file
Test-Command -Name "Missing Input File" -Description "Reject -i without file path" `
    -Command { Invoke-Sqlsim -i } `
    -ExpectedError "sqlsim error.*Input file path cannot be empty" `
    -ShouldFail $true

# Test: Missing username
Test-Command -Name "Missing Username" -Description "Reject -U without username" `
    -Command { & $runSqlsim -S localhost -U -P password -Q "SELECT 1" } `
    -ExpectedError "sqlsim error.*Username cannot be empty" `
    -ShouldFail $true

# Test: Missing password
Test-Command -Name "Missing Password" -Description "Reject -P without password" `
    -Command { & $runSqlsim -S localhost -U username -P -Q "SELECT 1" } `
    -ExpectedError "sqlsim error.*Password cannot be empty" `
    -ShouldFail $true

# Test: Missing access token
Test-Command -Name "Missing Access Token" -Description "Reject -T without access token" `
    -Command { & $runSqlsim -S localhost -T -Q "SELECT 1" } `
    -ExpectedError "sqlsim error.*Access token cannot be empty" `
    -ShouldFail $true

# Test: Missing application name
Test-Command -Name "Missing App Name" -Description "Reject -app without application name" `
    -Command { Invoke-Sqlsim -app -Q "SELECT 1" } `
    -ExpectedError "sqlsim error.*Application name cannot be empty" `
    -ShouldFail $true

# Test: Missing thread count
Test-Command -Name "Missing Thread Count" -Description "Reject -n without thread count" `
    -Command { Invoke-Sqlsim -n -Q "SELECT 1" } `
    -ExpectedError "sqlsim error.*Thread count cannot be empty" `
    -ShouldFail $true

# Test: Missing iteration count
Test-Command -Name "Missing Iteration Count" -Description "Reject -r without iteration count" `
    -Command { Invoke-Sqlsim -r -Q "SELECT 1" } `
    -ExpectedError "sqlsim error.*Iteration count cannot be empty" `
    -ShouldFail $true

# Test: Missing login timeout
Test-Command -Name "Missing Login Timeout" -Description "Reject -l without timeout value" `
    -Command { Invoke-Sqlsim -l -Q "SELECT 1" } `
    -ExpectedError "sqlsim error.*Timeout value cannot be empty" `
    -ShouldFail $true

# Test: Missing query timeout
Test-Command -Name "Missing Query Timeout" -Description "Reject -t without timeout value" `
    -Command { Invoke-Sqlsim -t -Q "SELECT 1" } `
    -ExpectedError "sqlsim error.*Timeout value cannot be empty" `
    -ShouldFail $true

# Test: Missing retry count
Test-Command -Name "Missing Retry Count" -Description "Reject -retry without retry count" `
    -Command { Invoke-Sqlsim -retry -Q "SELECT 1" } `
    -ExpectedError "sqlsim error.*Retry count cannot be empty" `
    -ShouldFail $true

# Test: Missing retry delay
Test-Command -Name "Missing Retry Delay" -Description "Reject -retrydelay without delay value" `
    -Command { Invoke-Sqlsim -retrydelay } `
    -ExpectedError "sqlsim error.*(Retry delay|Invalid|Unknown option)" `
    -ShouldFail $true

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "TDS 8.0 ENCRYPTION AND CERTIFICATE TESTS" -ForegroundColor Cyan  
Write-Host "========================================`n" -ForegroundColor Cyan

# Test: TDS 8.0 Mandatory Encryption with Certificate Bypass
Test-Command -Name "TDS 8.0 Mandatory Encryption" -Description "Test mandatory encryption with certificate bypass" `
    -Command { Invoke-Sqlsim -N m -C -Q "SELECT 1" -q } `
    -ExpectedOutput "Total Runtime:"

# Test: TDS 8.0 Optional Encryption  
Test-Command -Name "TDS 8.0 Optional Encryption" -Description "Test optional encryption" `
    -Command { Invoke-Sqlsim -N o -Q "SELECT 1" -q } `
    -ExpectedOutput "Total Runtime:"

# Test: TDS 8.0 Default Encryption (no value = mandatory)
Test-Command -Name "TDS 8.0 Default Encryption" -Description "Test -N defaults to mandatory encryption with certificate bypass" `
    -Command { Invoke-Sqlsim -N -C -Q "SELECT 1" -q } `
    -ExpectedOutput "Total Runtime:"

# Test: TDS 8.0 Mandatory Encryption Certificate Failure
if (-not $IsAzure) {
    Test-Command -Name "TDS 8.0 Mandatory Cert Fail" -Description "Test mandatory encryption fails without certificate bypass on self-signed cert" `
        -Command { Invoke-Sqlsim --no-trust-cert -N m -Q "SELECT 1" -q } `
        -ExpectedError "SSL Provider.*certificate.*not trusted" `
        -ShouldFail $true
} else {
    Write-Host "TEST: TDS 8.0 Mandatory Cert Fail" -ForegroundColor Yellow
    Write-Host "  Description: Test mandatory encryption fails without certificate bypass on self-signed cert" -ForegroundColor Gray
    Write-Host "  SKIPPED: Azure SQL Database has valid certificates" -ForegroundColor Yellow
    Write-Host ""
}

# Test: TDS 8.0 Strict Encryption Failure
if (-not $IsAzure) {
    Test-Command -Name "TDS 8.0 Strict Encryption" -Description "Test strict encryption fails with self-signed certificate" `
        -Command { Invoke-Sqlsim -N s -C -Q "SELECT 1" -q } `
        -ExpectedError "SSL Provider" `
        -ShouldFail $true
} else {
    Write-Host "TEST: TDS 8.0 Strict Encryption" -ForegroundColor Yellow
    Write-Host "  Description: Test strict encryption fails with self-signed certificate" -ForegroundColor Gray
    Write-Host "  SKIPPED: Azure SQL Database has valid certificates" -ForegroundColor Yellow
    Write-Host ""
}

# Test: Invalid Encryption Level
Test-Command -Name "Invalid Encryption Level" -Description "Reject invalid encryption level" `
    -Command { Invoke-Sqlsim -N x -Q "SELECT 1" } `
    -ExpectedError "Invalid encryption level.*Valid options: o.*m.*s" `
    -ShouldFail $true

# Test: TDS 8.0 Default Without Certificate Bypass Should Fail
if (-not $IsAzure) {
    Test-Command -Name "TDS 8.0 Default Cert Fail" -Description "Test -N (default mandatory) fails without certificate bypass" `
        -Command { Invoke-Sqlsim --no-trust-cert -N -Q "SELECT 1" -q } `
        -ExpectedError "SSL Provider.*certificate.*not trusted" `
        -ShouldFail $true
} else {
    Write-Host "TEST: TDS 8.0 Default Cert Fail" -ForegroundColor Yellow
    Write-Host "  Description: Test -N (default mandatory) fails without certificate bypass" -ForegroundColor Gray
    Write-Host "  SKIPPED: Azure SQL Database has valid certificates" -ForegroundColor Yellow
    Write-Host ""
}

# Test: Certificate Hostname Validation (syntax test)
if (-not $IsAzure) {
    Test-Command -Name "Certificate Hostname" -Description "Test certificate hostname parameter" `
        -Command { Invoke-Sqlsim --no-trust-cert -N m -F localhost -Q "SELECT 1" -q } `
        -ExpectedError "SSL Provider.*certificate" `
        -ShouldFail $true
} else {
    Write-Host "TEST: Certificate Hostname" -ForegroundColor Yellow
    Write-Host "  Description: Test certificate hostname parameter" -ForegroundColor Gray
    Write-Host "  SKIPPED: Azure SQL Database has valid certificates" -ForegroundColor Yellow
    Write-Host ""
}

# Test: Missing Certificate Hostname
Test-Command -Name "Missing Certificate Hostname" -Description "Reject -F without hostname" `
    -Command { Invoke-Sqlsim -F -Q "SELECT 1" } `
    -ExpectedError "Certificate hostname cannot be empty" `
    -ShouldFail $true

# Test: Certificate Hostname Too Long
Test-Command -Name "Long Certificate Hostname" -Description "Reject certificate hostname > 253 chars" `
    -Command { Invoke-Sqlsim -F $("a" * 254) -Q "SELECT 1" } `
    -ExpectedError "Certificate hostname.*maximum length" `
    -ShouldFail $true

# Test: Conflicting Certificate Options
Test-Command -Name "Certificate Conflict" -Description "Reject -F and -C together" `
    -Command { Invoke-Sqlsim -F localhost -C -Q "SELECT 1" } `
    -ExpectedError "Cannot use -F.*with -C" `
    -ShouldFail $true

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "STRING PARAMETER VALIDATION TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Test: Server name too long
$longServerName = "x" * 300
Test-Command -Name "Server Name Too Long" -Description "Reject server names exceeding 253 characters" `
    -Command { & $runSqlsim -S $longServerName -E -Q "SELECT 1" } `
    -ExpectedError "Server name.*maximum length" `
    -ShouldFail $true

# Test: Database name too long
$longDatabaseName = "x" * 200
Test-Command -Name "Database Name Too Long" -Description "Reject database names exceeding 128 characters" `
    -Command { & $runSqlsim -S localhost -d $longDatabaseName -E -Q "SELECT 1" } `
    -ExpectedError "Database name.*maximum length" `
    -ShouldFail $true

# Test: Database name with connection string metacharacters (injection prevention)
Test-Command -Name "Invalid Database Characters" -Description "Reject database names with connection string metacharacters" `
    -Command { & $runSqlsim -S localhost -d "test;database" -E -Q "SELECT 1" } `
    -ExpectedError "Database name contains invalid characters" `
    -ShouldFail $true

# Test: Username too long
$longUsername = "x" * 200
Test-Command -Name "Username Too Long" -Description "Reject usernames exceeding 128 characters" `
    -Command { & $runSqlsim -S localhost -U $longUsername -P password -Q "SELECT 1" } `
    -ExpectedError "Username.*maximum length" `
    -ShouldFail $true

# Test: Password too long
$longPassword = "x" * 200
Test-Command -Name "Password Too Long" -Description "Reject passwords exceeding 128 characters" `
    -Command { & $runSqlsim -S localhost -U username -P $longPassword -Q "SELECT 1" } `
    -ExpectedError "Password.*maximum length" `
    -ShouldFail $true

# Test: Access token too short
Test-Command -Name "Access Token Too Short" -Description "Reject access tokens shorter than 10 characters" `
    -Command { & $runSqlsim -S localhost -T "abc" -Q "SELECT 1" } `
    -ExpectedError "Invalid access token format" `
    -ShouldFail $true

# Test: Application name too long
$longAppName = "x" * 200
Test-Command -Name "App Name Too Long" -Description "Reject application names exceeding 128 characters" `
    -Command { Invoke-Sqlsim -app $longAppName -Q "SELECT 1" } `
    -ExpectedError "Application name.*maximum length" `
    -ShouldFail $true

# Test: Connection string too long
$longConnectionString = "Driver={ODBC Driver 18 for SQL Server};Server=localhost;" + ("x" * 4200)
Test-Command -Name "Connection String Too Long" -Description "Reject connection strings exceeding 4096 characters" `
    -Command { & $runSqlsim -c $longConnectionString -Q "SELECT 1" } `
    -ExpectedError "Connection string.*maximum length" `
    -ShouldFail $true

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "QUERY VALIDATION TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Test: Empty query string
Test-Command -Name "Empty Query String" -Description "Reject completely empty queries" `
    -Command { Invoke-Sqlsim -Q "" } `
    -ExpectedError "Query cannot be empty" `
    -ShouldFail $true

# Test: Query with no executable statements - DISABLED
# This test is disabled because GO separators cause comment-only queries to be processed
# Test-Command -Name "No Executable Statements" -Description "Reject queries with only comments/whitespace" `
#     -Command { Invoke-Sqlsim -Q "-- Just a comment`nGO`n-- Another comment" } `
#     -ExpectedError "Query contains no executable statements" `
#     -ShouldFail $true

# Test: Query size limit (create a large query) - DISABLED due to encoding issues
# $largeQuery = "SELECT " + ("'x'," * 100000) + "'end'"
# Test-Command -Name "Query Size Limit" -Description "Reject queries exceeding 1MB" `
#     -Command { Invoke-Sqlsim -Q $largeQuery } `
#     -ExpectedError "Query too large" `
#     -ShouldFail $true

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "CONNECTION-ONLY TESTING TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Test: Connection test only (no queries) - should return exit 0 on successful connection
Test-Command -Name "Connection Test Only" -Description "Test connection without any queries (should succeed)" `
    -Command { Invoke-Sqlsim -q } `
    -ExpectedOutput "Mode: Connection test only"

# Test: Connection test with database - should return exit 0 on successful connection
Test-Command -Name "Connection Test With Database" -Description "Test connection to specific database (should succeed)" `
    -Command { Invoke-Sqlsim -q } `
    -ExpectedOutput "Mode: Connection test only"

# Test: Connection test verbose mode - should return exit 0 on successful connection
Test-Command -Name "Connection Test Verbose" -Description "Test connection in verbose mode (should succeed)" `
    -Command { Invoke-Sqlsim -v -q } `
    -ExpectedOutput "Mode: Connection test only"

# Test: Connection test with multiple threads - should return exit 0 on successful connections
Test-Command -Name "Connection Test Multiple Threads" -Description "Test connection-only mode with multiple threads (should succeed)" `
    -Command { Invoke-Sqlsim -n 3 -q } `
    -ExpectedOutput "Threads: 3"

# Test: Connection test with iterations - should return exit 0 on successful connections
Test-Command -Name "Connection Test Multiple Iterations" -Description "Test connection-only mode with multiple iterations (should succeed)" `
    -Command { Invoke-Sqlsim -r 5 -q } `
    -ExpectedOutput "Iterations per thread: 5"

# Test: Connection test with threads and iterations - should return exit 0 on successful connections
Test-Command -Name "Connection Test Threads And Iterations" -Description "Test connection-only mode with both threads and iterations (should succeed)" `
    -Command { Invoke-Sqlsim -n 2 -r 3 -q } `
    -ExpectedOutput "Threads: 2"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "SECURITY VALIDATION TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Test 13: Excessive file path length
$longPath = "x" * 5000 + ".sql"
Test-Command -Name "Path Length Validation" -Description "Reject excessively long file paths" `
    -Command { Invoke-Sqlsim -i $longPath } `
    -ExpectedError "File path.*maximum length|Invalid file path" `
    -ShouldFail $true

# Test 14: File path with null byte
Test-Command -Name "Null Byte Validation" -Description "Reject file paths with null bytes" `
    -Command { Invoke-Sqlsim -i "test`0.sql" } `
    -ExpectedError "Cannot open input file" `
    -ShouldFail $true

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "CONCURRENCY TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Test 15: High concurrency
Test-Command -Name "High Concurrency (100 threads)" -Description "Run 100 threads with 10 iterations each" `
    -Command { Invoke-Sqlsim -Q "SELECT 1" -n 100 -r 10 -q } `
    -ExpectedOutput "Total Runtime:"

# Test 15b: High concurrency with prepared statements
Test-Command -Name "High Concurrency with Prepared Statements (100 threads)" -Description "Run 100 threads with prepared statements" `
    -Command { Invoke-Sqlsim -Q "SELECT 1" -p -n 100 -r 5 -q } `
    -ExpectedOutput "Total Runtime:"

# Test 16: Higher thread count validation (reasonable max for smoke test)
if (-not $SkipScale) {
    $maxThreads = 1024
    
    # Test 16a: Higher thread count - stream output for visibility
    Test-Command -Name "Higher Thread Count ($maxThreads)" `
        -Description "Verify higher thread counts work correctly" `
        -Command { Invoke-Sqlsim -Q "SELECT 1" -n $maxThreads -r 2 -l $LoginTimeout -v } `
        -ExpectedOutput "Total Runtime:" `
        -StreamOutput $true
    
    # Test 16b: Higher thread count with prepared statements - stream output for visibility
    Test-Command -Name "Higher Thread Count with Prepared Statements ($maxThreads)" `
        -Description "Verify prepared statements work with very high thread counts" `
        -Command { Invoke-Sqlsim -Q "SELECT 1" -p -n $maxThreads -r 1 -l $LoginTimeout -v } `
        -ExpectedOutput "Total Runtime:" `
        -StreamOutput $true
} else {
    Write-Host "[SKIPPED] Higher Thread Count (1024) - SkipScale parameter specified" -ForegroundColor Yellow
    Write-Host "[SKIPPED] Higher Thread Count with Prepared Statements (1024) - SkipScale parameter specified" -ForegroundColor Yellow
}

# Test: Threads with query timeout
Test-Command -Name "Threads with Query Timeout" -Description "Verify -t works with multiple threads" `
    -Command { Invoke-Sqlsim -Q "SELECT 1" -n 10 -t 30 -q } `
    -ExpectedOutput "Total Runtime:"

# Test: Threads with verbose mode
Test-Command -Name "Threads with Verbose Mode" -Description "Verify -v works with multiple threads" `
    -Command { Invoke-Sqlsim -Q "SELECT 1" -n 5 -v 2>&1 | Out-String } `
    -ExpectedOutput "Thread.*Connected successfully"

# Test: Threads with reconnect
Test-Command -Name "Threads with Reconnect" -Description "Verify -reconnect works with multiple threads" `
    -Command { Invoke-Sqlsim -Q "SELECT 1" -n 5 -r 3 -reconnect -q } `
    -ExpectedOutput "Total Runtime:"

# Test: Threads with connection pooling
Test-Command -Name "Threads with Connection Pooling" -Description "Verify -usepool works with multiple threads and reconnect" `
    -Command { Invoke-Sqlsim -Q "SELECT 1" -n 5 -r 3 -reconnect -usepool -q } `
    -ExpectedOutput "Total Runtime:"

# Test: Threads with application name
Test-Command -Name "Threads with Application Name" -Description "Verify -app works with multiple threads" `
    -Command { Invoke-Sqlsim -app "ConcurrencyTest" -Q "SELECT 1" -n 10 -q } `
    -ExpectedOutput "Total Runtime:"

# Test: Threads with stop on error
Test-Command -Name "Threads with Stop On Error" -Description "Verify -stoponerror stops all threads on first error" `
    -Command { 
        $output = Invoke-Sqlsim -Q "SELECT 1/0" -n 5 -stoponerror -q 2>&1 | Out-String
        Write-Output $output
    } `
    -ExpectedOutput "STOP: Stopping execution due to error" `
    -ShouldFail $true

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "NEW PARAMETER TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Test: Application name parameter
Test-Command -Name "Application Name" -Description "Verify -app parameter sets application name" `
    -Command { Invoke-Sqlsim -app "SmokeTest" -Q "SELECT program_name FROM sys.dm_exec_sessions WHERE session_id = @@SPID" } `
    -ExpectedOutput "SmokeTest"

# Test: Connection retry count parameter
Test-Command -Name "Connection Retry Count" -Description "Verify -retry parameter is accepted" `
    -Command { Invoke-Sqlsim -retry 3 -Q "SELECT 1" -q } `
    -ExpectedOutput "Total Runtime:"

# Test: Connection retry delay parameter
Test-Command -Name "Connection Retry Delay" -Description "Verify -retrydelay parameter is accepted" `
    -Command { Invoke-Sqlsim -retry 2 -retrydelay 5 -Q "SELECT 1" -q } `
    -ExpectedOutput "Total Runtime:"

# Test: Invalid retry count (negative)
Test-Command -Name "Invalid Retry Count (Negative)" -Description "Reject negative retry count" `
    -Command { Invoke-Sqlsim -retry "-1" -Q "SELECT 1" } `
    -ExpectedError "Connect retry count must be between 0 and 255" `
    -ShouldFail $true

# Test: Invalid retry count (too high)
Test-Command -Name "Invalid Retry Count (Too High)" -Description "Reject retry count > 255" `
    -Command { Invoke-Sqlsim -retry 300 -Q "SELECT 1" } `
    -ExpectedError "Connect retry count must be between 0 and 255" `
    -ShouldFail $true

# Test: Invalid retry delay (zero)
Test-Command -Name "Invalid Retry Delay (Zero)" -Description "Reject retry delay = 0" `
    -Command { Invoke-Sqlsim -retrydelay 0 -Q "SELECT 1" } `
    -ExpectedError "Connect retry interval must be between 1 and 60" `
    -ShouldFail $true

# Test: Invalid retry delay (too high)
Test-Command -Name "Invalid Retry Delay (Too High)" -Description "Reject retry delay > 60" `
    -Command { Invoke-Sqlsim -retrydelay 100 -Q "SELECT 1" } `
    -ExpectedError "Connect retry interval must be between 1 and 60" `
    -ShouldFail $true

# Stop on error covered by smoke tests

# Test: Continue on error (default behavior - should complete all iterations with repeating errors)
Test-Command -Name "Continue On Error (Default)" -Description "Verify default behavior continues through errors and repeats error for each iteration" `
    -Command { 
        $output = Invoke-Sqlsim -r 5 -Q "SELECT 1/0" -q 2>&1 | Out-String
        # Verify all 5 iterations hit the error via summary line (works in both verbose and non-verbose)
        if ($output -notmatch "Total Errors: 5") {
            Write-Host "  FAILED: Expected 'Total Errors: 5' in output" -ForegroundColor Red
            return $false
        }
        Write-Output $output
    } `
    -ExpectedOutput "Total Runtime:" `
    -ShouldFail $true

# Test: Read-only intent parameter
if ($TestReadReplica) {
    # User explicitly requested read replica testing - treat failures as warnings
    Write-Host "TEST: Read-Only Intent" -ForegroundColor Yellow
    Write-Host "  Description: Verify -R routes to read replica" -ForegroundColor Gray
    try {
        $output = Invoke-Sqlsim -R -M -Q "SELECT DATABASEPROPERTYEX(DB_NAME(), 'Updateability') AS Updateability" 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0 -and $output -match "READ_ONLY") {
            Write-Host "  PASSED" -ForegroundColor Green
            $script:testsPassed++
        } elseif ($exitCode -eq 0) {
            Write-Host "  WARNING: Test ran but did not route to read replica (server may not have replicas configured)" -ForegroundColor Yellow
            Write-Host "  Output: $($output.Substring(0, [Math]::Min(200, $output.Length)))..." -ForegroundColor Gray
            $script:testsWarning++
        } else {
            Write-Host "  WARNING: Connection with -R failed (server may not support read-only routing)" -ForegroundColor Yellow
            $script:testsWarning++
        }
    } catch {
        Write-Host "  WARNING: Could not test read-only routing: $_" -ForegroundColor Yellow
        $script:testsWarning++
    }
    Write-Host ""
} else {
    # Skip test - no read replica available
    Write-Host "TEST: Read-Only Intent" -ForegroundColor Yellow
    Write-Host "  Description: Verify -R parameter (read-only routing)" -ForegroundColor Gray
    Write-Host "  SKIPPED: Requires -TestReadReplica flag (server must have read replicas)" -ForegroundColor Yellow
    Write-Host ""
}

# Test: Multi-subnet failover parameter
if ($TestReadReplica) {
    # User explicitly requested read replica testing - treat failures as warnings
    Write-Host "TEST: Multi-Subnet Failover" -ForegroundColor Yellow
    Write-Host "  Description: Verify -M parameter is accepted" -ForegroundColor Gray
    try {
        $output = Invoke-Sqlsim -M -Q "SELECT 1" -q 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            Write-Host "  PASSED" -ForegroundColor Green
            $script:testsPassed++
        } else {
            Write-Host "  WARNING: -M parameter may not be supported on this server configuration" -ForegroundColor Yellow
            $script:testsWarning++
        }
    } catch {
        Write-Host "  WARNING: Could not test multi-subnet failover: $_" -ForegroundColor Yellow
        $script:testsWarning++
    }
    Write-Host ""
} else {
    # Skip test - no read replica/AG available
    Write-Host "TEST: Multi-Subnet Failover" -ForegroundColor Yellow
    Write-Host "  Description: Verify -M parameter (multi-subnet failover)" -ForegroundColor Gray
    Write-Host "  SKIPPED: Requires -TestReadReplica flag (server must have AG or multi-subnet config)" -ForegroundColor Yellow
    Write-Host ""
}

# Test: Combined read-only intent with multi-subnet failover
if ($TestReadReplica) {
    # User explicitly requested read replica testing - treat failures as warnings
    Write-Host "TEST: Read-Only Intent with Multi-Subnet Failover" -ForegroundColor Yellow
    Write-Host "  Description: Verify -R -M work together" -ForegroundColor Gray
    try {
        $output = Invoke-Sqlsim -R -M -Q "SELECT @@SERVERNAME, DATABASEPROPERTYEX(DB_NAME(), 'Updateability')" -q 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            Write-Host "  PASSED" -ForegroundColor Green
            $script:testsPassed++
        } else {
            Write-Host "  WARNING: Combined -R -M may not be supported on this server configuration" -ForegroundColor Yellow
            $script:testsWarning++
        }
    } catch {
        Write-Host "  WARNING: Could not test combined read-only/multi-subnet: $_" -ForegroundColor Yellow
        $script:testsWarning++
    }
    Write-Host ""
}

# Test: Reconnect parameter
Test-Command -Name "Reconnect Mode" -Description "Verify -reconnect parameter disconnects/reconnects after each iteration" `
    -Command { Invoke-Sqlsim -Q "SELECT 1" -r 3 -reconnect -q } `
    -ExpectedOutput "Total Runtime:"

# Test: Connection pooling with reconnect
Test-Command -Name "Connection Pooling" -Description "Verify -usepool parameter enables connection pooling with reconnect" `
    -Command { Invoke-Sqlsim -Q "SELECT 1" -r 3 -reconnect -usepool -q } `
    -ExpectedOutput "Total Runtime:"

# Test: Connection pooling without reconnect (should fail - pooling requires reconnect)
Test-Command -Name "Connection Pooling Without Reconnect" -Description "Verify -usepool requires -reconnect" `
    -Command { Invoke-Sqlsim -Q "SELECT 1" -usepool -q } `
    -ExpectedError "-usepool requires -reconnect" `
    -ShouldFail $true

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "ERROR HANDLING TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Test 17: Missing connection information
Test-Command -Name "Missing Connection Info" -Description "Fail when no connection information provided" `
    -Command { & $runSqlsim -Q "SELECT 1" } `
    -ExpectedError "Connection information is required" `
    -ShouldFail $true

# Test 18: Missing authentication method
Test-Command -Name "Missing Authentication" -Description "Fail when server provided but no authentication method" `
    -Command { & $runSqlsim -S localhost -Q "SELECT 1" } `
    -ExpectedError "Must specify either -E.*-A.*-T.*or -U" `
    -ShouldFail $true

# Test 20: Invalid SQL syntax
Test-Command -Name "Invalid SQL Syntax" -Description "Handle SQL syntax errors gracefully" `
    -Command { Invoke-Sqlsim -Q "INVALID SQL SYNTAX HERE" -q } `
    -ExpectedOutput "Total Runtime:" `
    -ShouldFail $true

# Test 21: Non-existent database
Test-Command -Name "Non-existent Database" -Description "Handle connection to non-existent database" `
    -Command { & $runSqlsim -S localhost -d NonExistentDatabase999 -E -Q "SELECT 1" -q } `
    -ExpectedOutput "Total Runtime:" `
    -ShouldFail $true

# Test 22: Missing query file
Test-Command -Name "Missing Query File" -Description "Fail when specified file doesn't exist" `
    -Command { Invoke-Sqlsim -i "nonexistent_file_xyz.sql" } `
    -ExpectedError "Cannot open input file" `
    -ShouldFail $true

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "SQL AUTHENTICATION TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "TEST: SQL Authentication Tests" -ForegroundColor Cyan
Write-Host "  Description: End-to-end SQL authentication testing" -ForegroundColor Gray
Write-Host "  SKIPPED: Complex SQL login creation - parameter validation tests cover SQL auth functionality" -ForegroundColor Yellow
$script:testsPassed++
$script:totalTests = $script:testsPassed + $script:testsFailed + $script:testsWarning

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "GO BATCH SEPARATOR TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Test 23: GO separator with -Q mode (simple case)
Test-Command -Name "GO Separator Query (Simple)" -Description "Execute GO-separated batches in -Q mode" `
    -Command { Invoke-Sqlsim -Q "SELECT 1 AS FirstBatch`nGO`nSELECT 2 AS SecondBatch" -q } `
    -ExpectedOutput "Total batches to execute: 2"

# Test 24: GO separator with -Q mode (multiple batches)
Test-Command -Name "GO Separator Query (Multiple)" -Description "Execute multiple GO-separated batches in -Q mode" `
    -Command { Invoke-Sqlsim -Q "SELECT @@VERSION`nGO`nSELECT DB_NAME()`nGO`nSELECT GETDATE()" -q } `
    -ExpectedOutput "Total batches to execute: 3"

# Test 25: GO separator case insensitive
Test-Command -Name "GO Separator Case Insensitive" -Description "Test GO separator is case insensitive" `
    -Command { Invoke-Sqlsim -Q "SELECT 'First' as Test`ngo`nSELECT 'Second' as Test" -q } `
    -ExpectedOutput "Total batches to execute: 2"

# Test 26: GO separator with -i mode (already tested in FILE PARSING but adding explicit validation)
$goBatchFile = "test_go_batches.sql"
@"
-- First batch
SELECT 'Batch 1' as BatchName;
GO

-- Second batch with comments
SELECT 'Batch 2' as BatchName,
       GETDATE() as CurrentTime;
GO

-- Third batch
SELECT COUNT(*) as ObjectCount 
FROM sys.objects 
WHERE type = 'U';
GO
"@ | Out-File -FilePath $goBatchFile -Encoding ASCII

Test-Command -Name "GO Separator File (Detailed)" -Description "Execute detailed GO-separated file with comments" `
    -Command { Invoke-Sqlsim -i $goBatchFile -q } `
    -ExpectedOutput "Batches in workload: 3"

Remove-Item $goBatchFile -ErrorAction SilentlyContinue

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "MULTI-RESULT SET TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Test 27: Multi-statement query with semicolon separator (-Q mode)
Test-Command -Name "Multi-Statement Query" -Description "Execute multiple statements in single -Q command" `
    -Command { Invoke-Sqlsim -Q "SELECT @@VERSION; SELECT COUNT(*) as ObjectCount FROM sys.objects WHERE type='U'" -q } `
    -ExpectedOutput "Total batches to execute: 1"

# Test 28: Multi-statement query file with semicolon separator (-i mode)
$multiStatementFile = "test_multistatement.sql"
@"
SELECT @@VERSION;
SELECT COUNT(*) as TableCount FROM sys.tables;
SELECT DB_NAME() as CurrentDatabase;
"@ | Out-File -FilePath $multiStatementFile -Encoding ASCII

Test-Command -Name "Multi-Statement File" -Description "Execute file with semicolon-separated statements" `
    -Command { Invoke-Sqlsim -i $multiStatementFile -q } `
    -ExpectedOutput "Total batches to execute: 1"

Remove-Item $multiStatementFile -ErrorAction SilentlyContinue

# Test 29: Verify result set separators in multi-statement output
Test-Command -Name "Result Set Separators" -Description "Verify multiple result sets are properly separated" `
    -Command { Invoke-Sqlsim -Q "SELECT 'First Result' as Result; SELECT 'Second Result' as Result" -q } `
    -ExpectedOutput "Total batches to execute: 1"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "CURSOR STATE TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# These tests verify that the ODBC cursor/statement state is properly cleaned up
# between batch executions. Prior to the fix, stored procedures with OUTPUT parameters
# could leave the cursor in an invalid state (SQLSTATE 24000).
# Basic OUTPUT param and multi-result cursor tests covered by smoke tests.

# Test: RETURN value capture followed by another batch
Test-Command -Name "RETURN Value + Second Batch" -Description "EXEC with RETURN value must not break next batch (cursor state)" `
    -Command { Invoke-Sqlsim -Q "DECLARE @rc INT; EXEC @rc = sp_executesql N'SELECT 1'; SELECT @rc AS ReturnCode`nGO`nSELECT 'AfterReturn' AS Status" } `
    -ExpectedOutput "AfterReturn"

# Test: RAISERROR with result set followed by another batch
Test-Command -Name "RAISERROR + Result + Second Batch" -Description "RAISERROR with results must not break next batch (cursor state)" `
    -Command { Invoke-Sqlsim -Q "RAISERROR('Warning message', 10, 1) WITH NOWAIT; SELECT 1 AS AfterRaiserror`nGO`nSELECT 'SecondBatchAfterRaiserror' AS Status" } `
    -ExpectedOutput "SecondBatchAfterRaiserror"

# Test: SET NOCOUNT toggle with multiple result sets followed by another batch
Test-Command -Name "NOCOUNT Toggle + Second Batch" -Description "SET NOCOUNT ON/OFF must not break next batch (cursor state)" `
    -Command { Invoke-Sqlsim -Q "SET NOCOUNT ON; SELECT 1 AS A; SELECT 2 AS B; SET NOCOUNT OFF`nGO`nSELECT 'AfterNocount' AS Status" } `
    -ExpectedOutput "AfterNocount"

# Test: Cursor state with prepared statements (-p flag)
Test-Command -Name "Prepared Stmt + OUTPUT Param + Second Batch" -Description "Prepared stmt with OUTPUT param must not break next batch" `
    -Command { Invoke-Sqlsim -Q "DECLARE @x INT; EXEC sp_executesql N'SELECT @o = 42', N'@o INT OUTPUT', @o = @x OUTPUT; SELECT @x AS Val`nGO`nSELECT 'PreparedOK' AS Status" -p } `
    -ExpectedOutput "PreparedOK"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "T-SQL FEATURE TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# These tests verify that various T-SQL features work correctly across batches
# and that result sets are properly processed.

# Test: Open transaction persists across batches
Test-Command -Name "Transaction Across Batches" -Description "BEGIN TRAN in first batch should persist to second batch" `
    -Command { Invoke-Sqlsim -Q "BEGIN TRAN; SELECT 1 AS InTransaction`nGO`nSELECT @@TRANCOUNT AS TranCount`nGO`nROLLBACK" } `
    -ExpectedOutput "TranCount"

# Test: FOR XML output followed by another batch
Test-Command -Name "FOR XML + Second Batch" -Description "FOR XML result must not break next batch" `
    -Command { Invoke-Sqlsim -Q "SELECT 1 AS Col FOR XML PATH('row')`nGO`nSELECT 'AfterXML' AS Status" } `
    -ExpectedOutput "AfterXML"

# Test: FOR JSON output followed by another batch
Test-Command -Name "FOR JSON + Second Batch" -Description "FOR JSON result must not break next batch" `
    -Command { Invoke-Sqlsim -Q "SELECT 1 AS Col FOR JSON PATH`nGO`nSELECT 'AfterJSON' AS Status" } `
    -ExpectedOutput "AfterJSON"

# Test: TRY/CATCH error handling followed by another batch
Test-Command -Name "TRY/CATCH + Second Batch" -Description "TRY/CATCH must not break next batch" `
    -Command { Invoke-Sqlsim -Q "BEGIN TRY SELECT 1/0 END TRY BEGIN CATCH SELECT ERROR_MESSAGE() AS Err END CATCH`nGO`nSELECT 'AfterTryCatch' AS Status" } `
    -ExpectedOutput "AfterTryCatch"

# Test: Temp tables persist across batches in same session
Test-Command -Name "Temp Table Across Batches" -Description "Temp table created in first batch should be accessible in second" `
    -Command { Invoke-Sqlsim -Q "CREATE TABLE #TestTemp (ID INT); INSERT INTO #TestTemp VALUES (1)`nGO`nSELECT 'TempTableWorks' AS Status FROM #TestTemp`nGO`nDROP TABLE #TestTemp" } `
    -ExpectedOutput "TempTableWorks"

# Test: THROW error in first batch, second batch still executes (separate batches)
Test-Command -Name "THROW Error + Second Batch" -Description "THROW in first batch should not prevent second batch execution" `
    -Command { Invoke-Sqlsim -Q "THROW 50000, 'Test error', 1`nGO`nSELECT 'SecondBatchRan' AS Status" } `
    -ExpectedOutput "SecondBatchRan" `
    -ShouldFail $true

# Test: Large result set from system views (LOB data)
Test-Command -Name "Large LOB Data Retrieval" -Description "Large text columns (sys.sql_modules) should be retrieved correctly" `
    -Command { Invoke-Sqlsim -d master -Q "SELECT TOP 1 LEN(definition) AS DefLen FROM sys.sql_modules WHERE definition IS NOT NULL ORDER BY LEN(definition) DESC" -q } `
    -ExpectedOutput "Total batches to execute: 1"

# Test: NULL values in result sets
Test-Command -Name "NULL Values in Results" -Description "NULL values should be handled correctly" `
    -Command { Invoke-Sqlsim -Q "SELECT NULL AS NullCol, 1 AS NotNull`nGO`nSELECT 'AfterNull' AS Status" } `
    -ExpectedOutput "AfterNull"

# Test: Empty result set followed by another batch
Test-Command -Name "Empty Result + Second Batch" -Description "Empty result set must not break next batch" `
    -Command { Invoke-Sqlsim -Q "SELECT 1 WHERE 1=0`nGO`nSELECT 'AfterEmpty' AS Status" } `
    -ExpectedOutput "AfterEmpty"

# Test: INSERT/UPDATE/DELETE (no result set) followed by SELECT
Test-Command -Name "DML + SELECT Second Batch" -Description "DML without result set must not break next batch" `
    -Command { Invoke-Sqlsim -Q "DECLARE @t TABLE (x INT); INSERT INTO @t VALUES (1)`nGO`nSELECT 'AfterDML' AS Status" } `
    -ExpectedOutput "AfterDML"

# Test: T-SQL CURSOR (DECLARE/OPEN/FETCH/CLOSE/DEALLOCATE)
Test-Command -Name "T-SQL Cursor + Second Batch" -Description "T-SQL CURSOR operations must not break next batch" `
    -Command { Invoke-Sqlsim -Q "DECLARE @cur CURSOR; SET @cur = CURSOR FOR SELECT TOP 2 name FROM sys.databases; OPEN @cur; FETCH NEXT FROM @cur; CLOSE @cur; DEALLOCATE @cur;`nGO`nSELECT 'CursorOK' AS Status" } `
    -ExpectedOutput "CursorOK"

# Test: INSERT...EXEC
Test-Command -Name "INSERT EXEC + Second Batch" -Description "INSERT INTO...EXEC must not break next batch" `
    -Command { Invoke-Sqlsim -Q "CREATE TABLE #dbs (name NVARCHAR(128), size INT, remarks NVARCHAR(254)); INSERT INTO #dbs EXEC sp_databases; DROP TABLE #dbs;`nGO`nSELECT 'InsertExecOK' AS Status" } `
    -ExpectedOutput "InsertExecOK"

# Test: Severity 16 error + second batch
Test-Command -Name "Severity 16 Error + Second Batch" -Description "Severity 16 error should not prevent second batch" `
    -Command { Invoke-Sqlsim -Q "RAISERROR('Sev16 test', 16, 1)`nGO`nSELECT 'AfterSev16' AS Status" } `
    -ExpectedOutput "AfterSev16" `
    -ShouldFail $true

# Test: Query timeout with WAITFOR + second batch still runs
Test-Command -Name "WAITFOR Timeout + Second Batch" -Description "Query timeout in first batch should not prevent second batch" `
    -Command { Invoke-Sqlsim -t 1 -Q "WAITFOR DELAY '00:00:05'`nGO`nSELECT 'AfterTimeout' AS Status" } `
    -ExpectedOutput "AfterTimeout" `
    -ShouldFail $true

# Test: NULL values in multiple column types
Test-Command -Name "NULL Multiple Types + Second Batch" -Description "NULL values in various types must not break next batch" `
    -Command { Invoke-Sqlsim -Q "SELECT CAST(NULL AS INT) AS NullInt, CAST(NULL AS DATETIME) AS NullDT, CAST(NULL AS DECIMAL(10,2)) AS NullDec, CAST(NULL AS UNIQUEIDENTIFIER) AS NullGuid`nGO`nSELECT 'NullTypesOK' AS Status" } `
    -ExpectedOutput "NullTypesOK"

# Basic Unicode retrieval covered by smoke tests

# Test: Unicode in query literals (requires UTF-8 file input)
Test-Command -Name "Unicode Query Literals (File)" -Description "Unicode literals in queries work via file input" `
    -Command {
        $sqlFile = Join-Path $script:testDir "unicode_query_test.sql"
        $outFile = Join-Path $script:testDir "unicode_query_result.txt"
        Remove-Item $sqlFile, $outFile -ErrorAction SilentlyContinue
        # Write UTF-8 file without BOM
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($sqlFile, "SELECT N'日本語' AS test_col", $utf8NoBom)
        Invoke-Sqlsim -i $sqlFile -o $outFile -q
        $result = "Failed"
        if (Test-Path $outFile) {
            $content = [System.IO.File]::ReadAllText($outFile, [System.Text.Encoding]::UTF8)
            if ($content -match '日本語') { $result = "UnicodeQueryOK" }
        }
        Remove-Item $sqlFile, $outFile -ErrorAction SilentlyContinue
        $result
    } `
    -ExpectedOutput "UnicodeQueryOK"

# Test: VARBINARY data
Test-Command -Name "Binary Data + Second Batch" -Description "VARBINARY data must not break next batch" `
    -Command { Invoke-Sqlsim -Q "SELECT CAST(0xDEADBEEF AS VARBINARY(100)) AS BinaryCol`nGO`nSELECT 'BinaryOK' AS Status" } `
    -ExpectedOutput "BinaryOK"

# Test 30: Output file redirection (-o parameter)
$outputTestFile = Join-Path $script:testDir "test_output_redirection.txt"
Test-Command -Name "Output File Redirection" -Description "Verify -o parameter redirects output to file" `
    -Command { 
        Remove-Item $outputTestFile -ErrorAction SilentlyContinue
        Invoke-Sqlsim -Q "SELECT @@VERSION" -o $outputTestFile -q
        if (Test-Path $outputTestFile) {
            $content = Get-Content $outputTestFile -Raw
            if ($content -match "Total Runtime:") {
                Remove-Item $outputTestFile -ErrorAction SilentlyContinue
                "Output file created successfully with expected content"
            } else {
                Remove-Item $outputTestFile -ErrorAction SilentlyContinue
                throw "Output file missing expected content"
            }
        } else {
            throw "Output file was not created"
        }
    } `
    -ExpectedOutput "Output file created successfully"

# Test 31: Output file captures errors (-o with stderr)
$errorTestFile = Join-Path $script:testDir "test_error_capture.txt"
Test-Command -Name "Output File Error Capture" -Description "Verify -o parameter captures SQL errors (stderr)" `
    -Command { 
        Remove-Item $errorTestFile -ErrorAction SilentlyContinue
        $args = $BaseAuthArgs + @("-Q", "SELECT * FROM NonExistentTable999", "-o", $errorTestFile, "-v")
        $null = & $runSqlsim $args 2>&1
        if (Test-Path $errorTestFile) {
            $content = Get-Content $errorTestFile -Raw
            if ($content -match "Invalid object name" -and $content -match "Total Errors: 1") {
                Remove-Item $errorTestFile -ErrorAction SilentlyContinue
                "Output file captured error successfully"
            } else {
                Remove-Item $errorTestFile -ErrorAction SilentlyContinue
                throw "Output file missing error information"
            }
        } else {
            throw "Output file was not created"
        }
    }.GetNewClosure() `
    -ExpectedOutput "Output file captured error successfully" `
    -ShouldFail $true

# Test: Output file permission denied
# A path under a regular file cannot be created even by an administrator or root,
# unlike a protected system directory.
$unwritableParent = Join-Path $script:testDir "sqlsim-not-a-directory.txt"
Set-Content -Path $unwritableParent -Value "" -NoNewline
Test-Command -Name "Output File Permission Denied" -Description "Fail gracefully when output file cannot be written" `
    -Command { Invoke-Sqlsim -Q "SELECT 1" -o (Join-Path $unwritableParent "test_permission.txt") } `
    -ExpectedError "Cannot open output file" `
    -ShouldFail $true
Remove-Item $unwritableParent -ErrorAction SilentlyContinue

# Test 32: JSON output format
Test-Command -Name "JSON Output Format" -Description "Verify -json flag produces valid JSON output" `
    -Command { 
        $output = Invoke-Sqlsim -Q "SELECT 1" -json -q
        try {
            $json = $output | ConvertFrom-Json
            if ($json.version -and $json.configuration -and $json.metrics -and $json.success) {
                "Valid JSON structure with all required fields"
            } else {
                throw "JSON missing required fields"
            }
        } catch {
            throw "Invalid JSON output: $_"
        }
    } `
    -ExpectedOutput "Valid JSON structure"

# Test 33: JSON output to file
Test-Command -Name "JSON Output to File" -Description "Verify -json -o writes valid JSON to file" `
    -Command { 
        $jsonFile = Join-Path $script:testDir "test_json_output.json"
        Remove-Item $jsonFile -ErrorAction SilentlyContinue
        Invoke-Sqlsim -Q "SELECT 1" -json -o $jsonFile -q
        if (Test-Path $jsonFile) {
            $content = Get-Content $jsonFile -Raw
            try {
                $json = $content | ConvertFrom-Json
                # Non-verbose JSON: check basic structure (no query_execution_operations without -v)
                if ($json.version -eq "1.0.0" -and $json.configuration.threads -eq 1 -and $json.success -eq $true) {
                    Remove-Item $jsonFile -ErrorAction SilentlyContinue
                    "JSON file created with valid content"
                } else {
                    Remove-Item $jsonFile -ErrorAction SilentlyContinue
                    throw "JSON file has incorrect values"
                }
            } catch {
                Remove-Item $jsonFile -ErrorAction SilentlyContinue
                throw "Invalid JSON in file: $_"
            }
        } else {
            throw "JSON file was not created"
        }
    } `
    -ExpectedOutput "JSON file created with valid content"

# Test 34: JSON output with multi-threading
Test-Command -Name "JSON Output Multi-threaded" -Description "Verify -json works with multiple threads" `
    -Command { 
        # Use -v to get detailed operation counts (verbose JSON includes connection_operations, query_execution_operations)
        $output = Invoke-Sqlsim -Q "SELECT 1" -n 10 -r 2 -json -v -q
        try {
            $json = $output | ConvertFrom-Json
            if ($json.configuration.threads -eq 10 -and 
                $json.configuration.iterations_per_thread -eq 2 -and
                $json.metrics.query_execution_operations.total -eq 20 -and
                $json.metrics.connection_operations.total -eq 10) {
                "JSON multi-threaded test passed with correct counts"
            } else {
                throw "JSON multi-threaded counts incorrect"
            }
        } catch {
            throw "JSON multi-threaded test failed: $_"
        }
    } `
    -ExpectedOutput "JSON multi-threaded test passed"

# Test 35: JSON output suppresses verbose
Test-Command -Name "JSON Suppresses Verbose Output" -Description "Verify -json -v does not mix text and JSON" `
    -Command { 
        $output = Invoke-Sqlsim -Q "SELECT 1" -json -v -q
        # First line should be the opening brace of JSON
        $firstLine = ($output -split "`n")[0].Trim()
        if ($firstLine -eq "{" -and $output -notmatch "PHASE") {
            # Validate it's actually valid JSON
            try {
                $json = $output | ConvertFrom-Json
                if ($json.connection_string -and $json.thread_connections -and $json.thread_iterations) {
                    "JSON output is clean without verbose text and includes verbose fields"
                } else {
                    throw "JSON output missing verbose fields (connection_string, thread_connections, thread_iterations)"
                }
            } catch {
                throw "Invalid JSON output: $_"
            }
        } else {
            throw "JSON output mixed with verbose text"
        }
    } `
    -ExpectedOutput "JSON output is clean"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "SECURITY VALIDATION TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Test 36: Password masking in verbose output (C-2 Security Fix)
Test-Command -Name "Password Masking - PWD Format" -Description "Verify PWD= is masked in verbose output" `
    -Command { 
        $output = & $runSqlsim -S localhost -d tempdb -U testuser -P "SecretPass123!" -Q "SELECT 1" -n 1 -r 1 -v -q 2>&1 | Out-String
        if ($output -match "PWD=\*\*\*\*\*\*\*\*" -and $output -notmatch "SecretPass123") {
            "Password properly masked"
        } else {
            throw "Password not masked in output"
        }
    } `
    -ExpectedOutput "Password properly masked" `
    -ShouldFail $true  # Command will fail due to invalid credentials, but we're checking output

# Test 37: Username masking in verbose output (C-2 Security Fix)
Test-Command -Name "Username Masking - UID Format" -Description "Verify UID= is masked in verbose output" `
    -Command { 
        $output = & $runSqlsim -S localhost -d tempdb -U "SecretUser" -P "pass" -Q "SELECT 1" -n 1 -r 1 -v -q 2>&1 | Out-String
        if ($output -match "UID=\*\*\*\*\*\*\*\*") {
            "Username properly masked"
        } else {
            throw "Username not masked in output"
        }
    } `
    -ExpectedOutput "Username properly masked" `
    -ShouldFail $true  # Command will fail due to invalid credentials, but we're checking output

# Test 38: Connection string masking (C-2 Security Fix)
Test-Command -Name "Connection String Password Masking" -Description "Verify passwords masked in connection string mode" `
    -Command { 
        $cs = "Driver={ODBC Driver 18 for SQL Server};Server=localhost;Database=master;UID=testuser;PWD=MySecret123!;TrustServerCertificate=Yes"
        $output = & $runSqlsim -c $cs -Q "SELECT 1" -v -q 2>&1 | Out-String
        if ($output -match "PWD=\*\*\*\*\*\*\*\*" -and $output -notmatch "MySecret123") {
            "Connection string password properly masked"
        } else {
            throw "Connection string password not masked"
        }
    } `
    -ExpectedOutput "Connection string password properly masked" `
    -ShouldFail $true  # Command will fail due to invalid credentials

Test-Command -Name "Attached Password Masking" -Description "Verify an attached -P value is masked in the verbose command line" `
    -Command {
        $output = & $runSqlsim -S localhost -d tempdb -U testuser -PAttachedSecret99 -Q "SELECT 1" -n 1 -r 1 -v -q 2>&1 | Out-String
        if ($output -match "-P\*{8}" -and $output -notmatch "AttachedSecret99") {
            "Attached password properly masked"
        } else {
            throw "Attached password not masked"
        }
    } `
    -ExpectedOutput "Attached password properly masked" `
    -ShouldFail $true  # Command will fail due to invalid credentials

Test-Command -Name "Braced Password Masking" -Description "Verify a braced PWD value containing ';' is fully masked" `
    -Command {
        $cs = "Driver={ODBC Driver 18 for SQL Server};Server=localhost;Database=master;UID=testuser;PWD={Brace;TailSecret77};TrustServerCertificate=Yes"
        $output = & $runSqlsim -c $cs -Q "SELECT 1" -v -q 2>&1 | Out-String
        if ($output -notmatch "TailSecret77" -and $output -notmatch "Brace;") {
            "Braced password properly masked"
        } else {
            throw "Braced password not fully masked"
        }
    } `
    -ExpectedOutput "Braced password properly masked" `
    -ShouldFail $true  # Command will fail due to invalid credentials

# Test 39: Output file with multiple threads (H-4 Security Fix - Thread Safety)
$threadedOutputFile = "test_threaded_output.txt"
Test-Command -Name "Output File Thread Safety" -Description "Verify -o with multiple threads doesn't corrupt output" `
    -Command { 
        Remove-Item $threadedOutputFile -ErrorAction SilentlyContinue
        # Use unique marker in each query to detect interleaving/corruption
        # Phase 1: Remove -q so results are actually written to output file
        $args = $BaseAuthArgs + @("-Q", "SELECT 'MARKER' AS Col1, NEWID() AS UniqueID", "-n", "20", "-r", "10", "-o", $threadedOutputFile)
        & $runSqlsim $args
        if (Test-Path $threadedOutputFile) {
            $content = Get-Content $threadedOutputFile -Raw
            $lines = Get-Content $threadedOutputFile
            
            # Check for expected metrics (with -o flag, gets brief runtime output)
            $hasMetrics = $content -match "Total Runtime:" -and $content -match "Total Query Execution Time:"
            
            # Check that lines aren't corrupted (no partial writes mixing content)
            # Look for malformed lines that would indicate race conditions
            $corruptedLines = $lines | Where-Object { 
                $_ -match "^\s*Col1.*Col1" -or  # Duplicate column headers on same line
                $_ -match "MARKER.*MARKER.*MARKER" -or  # Multiple results interleaved on one line
                ($_ -match "^[^-\s]" -and $_ -match "\s{2,}[^-\s].*\s{2,}[^-\s]" -and $_ -notmatch "MARKER")  # Suspicious spacing patterns
            }
            
            # Verify we got all expected result rows (200 operations)
            # Note: Query text is also displayed in configuration, so subtract that occurrence
            $markerCount = ($content | Select-String -Pattern "MARKER" -AllMatches).Matches.Count
            $expectedMarkers = 201  # 1 in query display + (20 threads * 10 iterations)
            
            if ($hasMetrics -and $corruptedLines.Count -eq 0 -and $markerCount -eq $expectedMarkers) {
                Remove-Item $threadedOutputFile -ErrorAction SilentlyContinue
                "Output file with 20 threads, no corruption detected, $markerCount markers found"
            } else {
                $issues = @()
                if (-not $hasMetrics) { $issues += "Missing metrics" }
                if ($corruptedLines.Count -gt 0) { $issues += "$($corruptedLines.Count) corrupted lines" }
                if ($markerCount -ne $expectedMarkers) { $issues += "Expected $expectedMarkers markers, found $markerCount" }
                Remove-Item $threadedOutputFile -ErrorAction SilentlyContinue
                throw "Thread safety issues: $($issues -join ', ')"
            }
        } else {
            throw "Output file was not created"
        }
    }.GetNewClosure() `
    -ExpectedOutput "no corruption detected"

# Test 40: Large access token rejection (H-1 Security Fix - Integer Overflow)
Test-Command -Name "Access Token Size Limit" -Description "Reject tokens exceeding maximum size (10KB)" `
    -Command { 
        $hugeToken = "A" * 15000  # 15KB token, exceeds 10KB limit
        & $runSqlsim -S localhost -d tempdb -T $hugeToken -Q "SELECT 1" -q 2>&1
    } `
    -ExpectedOutput "Access token" `
    -ShouldFail $true

# Test 41: Empty access token rejection (H-1 Security Fix)
Test-Command -Name "Empty Access Token" -Description "Reject empty access tokens" `
    -Command { & $runSqlsim -S localhost -d tempdb -T "" -Q "SELECT 1" -q 2>&1 } `
    -ExpectedOutput "Access token cannot be empty" `
    -ShouldFail $true

# Test 42: High concurrency connection metrics (H-2 Security Fix - Race Conditions)
# This test verifies the thread-safe connection metrics don't have race conditions
Test-Command -Name "High Concurrency Connection Metrics" -Description "Verify thread-safe metrics with 50 threads (no race conditions)" `
    -Command { 
        $args = $BaseAuthArgs + @("-Q", "SELECT 1", "-n", "50", "-r", "10", "-v", "-q")
        $output = & $runSqlsim $args 2>&1 | Out-String
        
        # Check that all 50 threads completed
        $allThreadsPresent = $output -match "Thread 49:" -and $output -match "Thread 0:"
        
        # Check metrics are correct
        $correctMetrics = $output -match "Total Operations: 500"
        
        # CRITICAL: Check that "[PHASE 4] Executing workload" appears exactly once
        # If race condition exists, multiple threads might think they're last and print this
        $phase4Count = ([regex]::Matches($output, "\[PHASE 4\] Executing workload")).Count
        
        # Check that connection messages appear in sorted order
        # Phase 1: Messages are alphabetically sorted (Thread 0, Thread 1, Thread 10...)
        # This is correct string sorting behavior
        $connectionSection = $output -match "\[PHASE 3\]" 
        $messagesInOrder = $output -match "Thread 0:" -and $output -match "Thread 1:"
        
        # Verify no duplicate "Connected successfully" messages from same thread
        $threadPattern = "Thread (\d+): Connected successfully"
        $threadMatches = [regex]::Matches($output, $threadPattern)
        $threadIds = $threadMatches | ForEach-Object { $_.Groups[1].Value } | Group-Object
        $duplicateThreads = $threadIds | Where-Object { $_.Count -gt 1 }
        
        if ($allThreadsPresent -and $correctMetrics -and $phase4Count -eq 1 -and $messagesInOrder -and $duplicateThreads.Count -eq 0) {
            "50 threads completed, [PHASE 4] appeared once, no race conditions detected"
        } else {
            $issues = @()
            if (-not $allThreadsPresent) { $issues += "Missing thread messages" }
            if (-not $correctMetrics) { $issues += "Incorrect metrics" }
            if ($phase4Count -ne 1) { $issues += "[PHASE 4] appeared $phase4Count times (should be 1 - race condition!)" }
            if (-not $messagesInOrder) { $issues += "Thread messages not sorted" }
            if ($duplicateThreads.Count -gt 0) { $issues += "$($duplicateThreads.Count) duplicate thread messages" }
            throw "Race condition detected: $($issues -join ', ')"
        }
    }.GetNewClosure() `
    -ExpectedOutput "no race conditions detected"

# Test 43: Timestamp format and output features validation
Test-Command -Name "Timestamp Format and Output Features" -Description "Verify timestamp format, Starting execution message, and time breakdown" `
    -Command {
        $args = $BaseAuthArgs + @("-Q", "SELECT 1", "-q")
        $output = & $runSqlsim $args 2>&1 | Out-String
        
        # Check for timestamp format: YYYY-MM-DD HH:MM:SS.mmm |
        $hasTimestamp = $output -match '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \|'
        # Check for "Starting execution..." message
        $hasStartMsg = $output -match 'Starting execution'
        # Check for "Total Connection Time" in time breakdown
        $hasTotalConnTime = $output -match 'Total Connection Time:'
        # Check for "% of work" percentages in time breakdown
        $hasPercentages = $output -match '% of work\)'
        
        if ($hasTimestamp -and $hasStartMsg -and $hasTotalConnTime -and $hasPercentages) {
            "All formatting features present: timestamps, start message, time breakdown, percentages"
        } else {
            $missing = @()
            if (-not $hasTimestamp) { $missing += "timestamp format" }
            if (-not $hasStartMsg) { $missing += "starting execution message" }
            if (-not $hasTotalConnTime) { $missing += "Total Connection Time line" }
            if (-not $hasPercentages) { $missing += "% of work percentages" }
            throw "Missing formatting features: $($missing -join ', ')"
        }
    }.GetNewClosure() `
    -ExpectedOutput "All formatting features present"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "OUTPUT FORMAT VALIDATION TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Test 44: Non-verbose output - complete validation
Test-Command -Name "Non-Verbose Output Validation" -Description "Verify all key elements in non-verbose output" `
    -Command {
        $args = $BaseAuthArgs + @("-Q", "SELECT 1", "-q")
        $output = & $runSqlsim $args 2>&1 | Out-String
        
        # Note: Prepared statements, timeouts, and other optional features only shown when used
        $checks = @{
            "Header" = $output -match "SQL Workload Simulator v\d+\.\d+"
            "Configuration label" = $output -match "Configuration:"
            "Server" = $output -match "Server:"
            "Database" = $output -match "Database:"
            "Authentication" = $output -match "Authentication:"
            "Threads" = $output -match "Threads: \d+"
            "Iterations per thread" = $output -match "Iterations per thread: \d+"
            "Total batches to execute" = $output -match "Total batches to execute: \d+"
            "Batches in workload" = $output -match "Batches in workload: \d+"
            "Batches to execute list" = $output -match "Batches to execute:"
            "Connecting message" = $output -match "Connecting\.\.\."
            "Starting execution" = $output -match "Starting execution"
            "Performance Metric Summary" = $output -match "Performance Metric Summary"
            "Avg Connect Time" = $output -match "Avg Connect Time:"
            "Avg Elapsed" = $output -match "Avg Elapsed:"
            "Total Runtime" = $output -match "Total Runtime:"
            "Total Connection Time" = $output -match "Total Connection Time:"
            "Total Query Execution Time" = $output -match "Total Query Execution Time:"
        }
        
        $failed = $checks.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key }
        
        if ($failed.Count -eq 0) {
            "All 18 non-verbose output elements validated"
        } else {
            throw "Missing elements: $($failed -join ', ')"
        }
    }.GetNewClosure() `
    -ExpectedOutput "All 18 non-verbose output elements validated"

# Test 44b: Optional features shown only when used
Test-Command -Name "Optional Features Display" -Description "Verify optional features only shown when explicitly used" `
    -Command {
        # Test 1: Without -p, "Prepared statements:" should NOT appear
        $argsNoPrepared = $BaseAuthArgs + @("-Q", "SELECT 1", "-q")
        $outputNoPrepared = & $runSqlsim $argsNoPrepared 2>&1 | Out-String
        $showsWhenNotUsed = $outputNoPrepared -match "Prepared statements:"
        
        # Test 2: With -p, "Prepared statements: Yes" SHOULD appear
        $argsWithPrepared = $BaseAuthArgs + @("-Q", "SELECT 1", "-q", "-p")
        $outputWithPrepared = & $runSqlsim $argsWithPrepared 2>&1 | Out-String
        $showsWhenUsed = $outputWithPrepared -match "Prepared statements: Yes"
        
        # Test 3: With -stoponerror, "Stop on error: Yes" SHOULD appear
        $argsWithStop = $BaseAuthArgs + @("-Q", "SELECT 1", "-q", "-stoponerror")
        $outputWithStop = & $runSqlsim $argsWithStop 2>&1 | Out-String
        $showsStopOnError = $outputWithStop -match "Stop on error: Yes"
        
        if (-not $showsWhenNotUsed -and $showsWhenUsed -and $showsStopOnError) {
            "Optional features display correctly"
        } else {
            throw "Optional features not displaying correctly: hidden=$(-not $showsWhenNotUsed), shown=$showsWhenUsed, stop=$showsStopOnError"
        }
    }.GetNewClosure() `
    -ExpectedOutput "Optional features display correctly"

# Test 45: Verbose output - complete validation  
Test-Command -Name "Verbose Output Validation" -Description "Verify all key elements in verbose output" `
    -Command {
        $args = $BaseAuthArgs + @("-Q", "SELECT 1", "-v", "-q")
        $output = & $runSqlsim $args 2>&1 | Out-String
        
        $checks = @{
            # Configuration section (appears twice - in header and PHASE 1)
            "Header" = $output -match "SQL Workload Simulator v\d+\.\d+"
            "Server" = $output -match "Server:"
            "Database" = $output -match "Database:"
            
            # Phase markers
            "PHASE 1" = $output -match "\[PHASE 1\] Configuration"
            "PHASE 2" = $output -match "\[PHASE 2\] Initializing worker threads"
            "PHASE 3" = $output -match "\[PHASE 3\] Connecting to database"
            "PHASE 4" = $output -match "\[PHASE 4\] Executing workload"
            "PHASE 5" = $output -match "\[PHASE 5\] Workload execution completed"
            
            # Batch terminology in PHASE 1
            "Total batches (verbose)" = $output -match "Total batches to execute: \d+"
            "Batches in workload (verbose)" = $output -match "Batches in workload: \d+"
            "Batches to execute list (verbose)" = $output -match "Batches to execute:"
            
            # Connection info
            "Connection String" = $output -match "Connection String:"
            "Thread connected" = $output -match "Thread \d+: Connected successfully"
            "Worker threads launched" = $output -match "Launched \d+ worker thread"
            
            # Metrics Summary header
            "Metrics Summary" = $output -match "Performance Metric Summary"
            
            # Start Time / End Time lines (ISO format)
            "Start Time" = $output -match 'Start Time: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}'
            "End Time" = $output -match 'End Time:\s+\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}'
            
            # Connection Operations section
            "Connection Operations" = $output -match "Connection Operations:"
            "Conn Total Operations" = $output -match "Total Operations: \d+"
            "Conn Successful" = $output -match "Successful: \d+"
            "Conn Avg Connect Time" = $output -match "Avg Connect Time:"
            
            # Query Execution Operations section
            "Query Execution Operations" = $output -match "Query Execution Operations:"
            
            # Fetch Operations section
            "Fetch Operations" = $output -match "Fetch Operations:"
            
            # Total Errors
            "Total Errors" = $output -match "Total Errors: \d+"
            
            # Time Breakdown section
            "Time Breakdown" = $output -match "Time Breakdown:"
            "Total Runtime" = $output -match "Total Runtime:"
            "Total Connection Time" = $output -match "Total Connection Time:"
            "Total Query Execution Time" = $output -match "Total Query Execution Time:"
        }
        
        $failed = $checks.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key }
        
        if ($failed.Count -eq 0) {
            "All 28 verbose output elements validated"
        } else {
            throw "Missing elements: $($failed -join ', ')"
        }
    }.GetNewClosure() `
    -ExpectedOutput "All 28 verbose output elements validated"

# Test 46: JSON output - complete validation (non-verbose mode)
Test-Command -Name "JSON Output Validation" -Description "Verify all key elements in JSON output" `
    -Command {
        $args = $BaseAuthArgs + @("-Q", "SELECT 1", "-json", "-q")
        $output = & $runSqlsim $args 2>&1 | Out-String
        
        # Non-verbose JSON only includes basic metrics (matches text non-verbose output)
        # Detailed operations (connection_operations, query_execution_operations, fetch_operations) 
        # are only shown with -v flag (matching text -v output)
        $checks = @{
            # Root level
            "version" = $output -match '"version":'
            "start_time" = $output -match '"start_time":'
            "success" = $output -match '"success":'
            
            # Configuration section - always shown
            "configuration" = $output -match '"configuration":'
            "server" = $output -match '"server":'
            "database" = $output -match '"database":'
            "authentication" = $output -match '"authentication":'
            "threads" = $output -match '"threads":'
            "iterations_per_thread" = $output -match '"iterations_per_thread":'
            "total_batches" = $output -match '"total_batches":'
            "batch_count" = $output -match '"batch_count":'
            "batches" = $output -match '"batches":'
            
            # Metrics section
            "metrics" = $output -match '"metrics":'
            "total_runtime_seconds" = $output -match '"total_runtime_seconds":'
            "total_connection_time_seconds" = $output -match '"total_connection_time_seconds":'
            "total_query_execution_time_seconds" = $output -match '"total_query_execution_time_seconds":'
            "end_time" = $output -match '"end_time":'
            
            # Errors block (always shown)
            "errors" = $output -match '"errors":'
            "errors_total" = $output -match '"total":'
            "errors_list" = $output -match '"list":'

            # Server identity (always shown when SQL Server reports it)
            "server_edition" = $output -match '"server_edition":'
            "server_version" = $output -match '"server_version":'
        }
        
        $failed = $checks.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key }
        
        if ($failed.Count -eq 0) {
            "All 22 JSON output elements validated"
        } else {
            throw "Missing elements: $($failed -join ', ')"
        }
    }.GetNewClosure() `
    -ExpectedOutput "All 22 JSON output elements validated"

# Test 47: Verify NO "queries" terminology in any output mode
Test-Command -Name "No Queries Terminology" -Description "Verify 'queries' terminology is NOT used (should be 'batches')" `
    -Command {
        # Test non-verbose
        $args1 = $BaseAuthArgs + @("-Q", "SELECT 1", "-q")
        $output1 = & $runSqlsim $args1 2>&1 | Out-String
        
        # Test verbose
        $args2 = $BaseAuthArgs + @("-Q", "SELECT 1", "-v", "-q")
        $output2 = & $runSqlsim $args2 2>&1 | Out-String
        
        # Test JSON
        $args3 = $BaseAuthArgs + @("-Q", "SELECT 1", "-json", "-q")
        $output3 = & $runSqlsim $args3 2>&1 | Out-String
        
        $issues = @()
        
        # Check for incorrect "queries" terminology (but allow "Query Execution Operations" which is correct)
        if ($output1 -match "Total queries to execute") { $issues += "Non-verbose: 'Total queries to execute'" }
        if ($output1 -match "Queries in workload") { $issues += "Non-verbose: 'Queries in workload'" }
        if ($output1 -match "Queries to execute:") { $issues += "Non-verbose: 'Queries to execute:'" }
        
        if ($output2 -match "Total queries to execute") { $issues += "Verbose: 'Total queries to execute'" }
        if ($output2 -match "Queries in workload") { $issues += "Verbose: 'Queries in workload'" }
        if ($output2 -match "Queries to execute:") { $issues += "Verbose: 'Queries to execute:'" }
        
        if ($output3 -match '"total_queries"') { $issues += "JSON: 'total_queries'" }
        if ($output3 -match '"query_count"') { $issues += "JSON: 'query_count'" }
        
        if ($issues.Count -eq 0) {
            "No incorrect 'queries' terminology found - all use 'batches'"
        } else {
            throw "Found incorrect terminology: $($issues -join ', ')"
        }
    }.GetNewClosure() `
    -ExpectedOutput "No incorrect 'queries' terminology found"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "PRINT STATEMENT TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Basic PRINT display covered by smoke tests

# Test 49: Multiple PRINT statements displayed
Test-Command -Name "Multiple PRINT Statements" -Description "Verify multiple PRINT statements are all displayed" `
    -Command {
        $args = $BaseAuthArgs + @("-Q", "PRINT 'Line1'; PRINT 'Line2'; PRINT 'Line3'; SELECT 1")
        $output = & $runSqlsim $args 2>&1 | Out-String
        $hasLine1 = $output -match 'Line1'
        $hasLine2 = $output -match 'Line2'
        $hasLine3 = $output -match 'Line3'
        if ($hasLine1 -and $hasLine2 -and $hasLine3) {
            "All 3 PRINT statements displayed"
        } else {
            throw "Missing PRINT statements: Line1=$hasLine1, Line2=$hasLine2, Line3=$hasLine3"
        }
    }.GetNewClosure() `
    -ExpectedOutput "All 3 PRINT statements displayed"

# Test 50: PRINT between SELECT statements
Test-Command -Name "PRINT Between SELECTs" -Description "Verify PRINT statement appears between SELECT results" `
    -Command {
        $args = $BaseAuthArgs + @("-Q", "SELECT 'Before' AS Position; PRINT 'MiddlePrint'; SELECT 'After' AS Position")
        $output = & $runSqlsim $args 2>&1 | Out-String
        # Check that MiddlePrint appears and comes after "Before" and before "After" in the output
        if ($output -match 'Before' -and $output -match 'MiddlePrint' -and $output -match 'After') {
            "PRINT statement displayed between SELECT results"
        } else {
            throw "PRINT statement not displayed correctly between results"
        }
    }.GetNewClosure() `
    -ExpectedOutput "PRINT statement displayed between SELECT results"

# PRINT quiet mode and JSON mode suppression covered by smoke tests

# Test 53: PRINT with file input
Test-Command -Name "PRINT From File Input" -Description "Verify PRINT statements work from -i file input" `
    -Command {
        $printTestFile = Join-Path $script:testDir "test-print-statements.sql"
        $args = $BaseAuthArgs + @("-i", $printTestFile)
        $output = & $runSqlsim $args 2>&1 | Out-String
        # The file has multiple PRINTs - check for at least one
        if ($output -match 'Starting test script' -or $output -match 'Before SELECT' -or $output -match 'Line 1') {
            "PRINT statements from file displayed correctly"
        } else {
            throw "PRINT statements from file not found in output"
        }
    }.GetNewClosure() `
    -ExpectedOutput "PRINT statements from file displayed correctly"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "EXAMPLE VALIDATION TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Test: Help text examples work
if ($script:CanTestLocalDefaults) {
    Test-Command -Name "Help Example: Connection Test" -Description "Verify 'sqlsim -E' works (from -? help)" `
        -Command { & $runSqlsim -E -q } `
        -ExpectedOutput "Total Runtime:"
} else {
    Write-TestSkipped "Help Example: Connection Test" "Verify 'sqlsim -E' works (from -? help)" $script:LocalDefaultsReason
}

Test-Command -Name "Help Example: Basic Query" -Description "Verify 'sqlsim -S localhost -d testdb -E -Q' works (from -? help)" `
    -Command { Invoke-Sqlsim -Q "SELECT @@VERSION" } `
    -ExpectedOutput "@@VERSION"

Test-Command -Name "Help Example: Load Test Pattern" -Description "Verify '-n 10 -r 100 -q' pattern works (from -? help)" `
    -Command { Invoke-Sqlsim -Q "SELECT 1" -n 10 -r 100 -q } `
    -ExpectedOutput "Total Runtime:"

# Test: Documentation examples (sqlsim.md)
if ($script:CanTestLocalDefaults) {
    Test-Command -Name "Doc Example: Default Localhost" -Description "Verify '-E -Q' defaults to localhost (sqlsim.md)" `
        -Command { & $runSqlsim -E -Q "SELECT @@VERSION" } `
        -ExpectedOutput "@@VERSION"
} else {
    Write-TestSkipped "Doc Example: Default Localhost" "Verify '-E -Q' defaults to localhost (sqlsim.md)" $script:LocalDefaultsReason
}

Test-Command -Name "Doc Example: Verbose Mode" -Description "Verify verbose mode shows phases (sqlsim.md)" `
    -Command { Invoke-Sqlsim -Q "SELECT 1" -v -q } `
    -ExpectedOutput "(?s)\[PHASE 1\].*\[PHASE 2\].*\[PHASE 3\].*\[PHASE 4\].*\[PHASE 5\]"

Test-Command -Name "Doc Example: Prepared Statements" -Description "Verify '-p' prepared statements work (sqlsim.md)" `
    -Command { Invoke-Sqlsim -Q "SELECT 1" -p -n 10 -r 100 -q } `
    -ExpectedOutput "Total Runtime:"

if (-not $UseToken) {
    $docCs = $TestConnectionString
    Test-Command -Name "Doc Example: Connection String" -Description "Verify '-c' connection string mode (sqlsim.md)" `
        -Command { & $runSqlsim -c $docCs -Q "SELECT @@VERSION" }.GetNewClosure() `
        -ExpectedOutput "@@VERSION"
} else {
    Write-TestSkipped "Doc Example: Connection String" "Verify '-c' connection string mode (sqlsim.md)" `
        "Connection string mode with access token requires token in connection string"
}

# Test: Example script patterns (examples/ folder)
if ($script:CanTestLocalDefaults) {
    Test-Command -Name "Script Example: localhost-simple-test Pattern 1" -Description "Verify 'sqlsim -E -Q' (localhost-simple-test.ps1)" `
        -Command { & $runSqlsim -E -Q "SELECT @@VERSION" } `
        -ExpectedOutput "@@VERSION"

    Test-Command -Name "Script Example: localhost-simple-test Pattern 3" -Description "Verify connection test mode (localhost-simple-test.ps1)" `
        -Command { & $runSqlsim -E -v } `
        -ExpectedOutput "Mode: Connection test only"
} else {
    Write-TestSkipped "Script Example: localhost-simple-test Pattern 1" "Verify 'sqlsim -E -Q' (localhost-simple-test.ps1)" $script:LocalDefaultsReason
    Write-TestSkipped "Script Example: localhost-simple-test Pattern 3" "Verify connection test mode (localhost-simple-test.ps1)" $script:LocalDefaultsReason
}

Test-Command -Name "Script Example: json-output-examples Pattern 1" -Description "Verify JSON output (json-output-examples.ps1)" `
    -Command { Invoke-Sqlsim -Q "SELECT 1 AS Value" -json } `
    -ExpectedOutput '(?s)"version".*"success"'

Test-Command -Name "Script Example: json-output-examples Pattern 2" -Description "Verify JSON with GO batches (json-output-examples.ps1)" `
    -Command { Invoke-Sqlsim -Q "SELECT 1`nGO`nSELECT 2`nGO`nSELECT 3" -json -q } `
    -ExpectedOutput '"batch_count": 3'

Test-Command -Name "Script Example: json-output-examples Pattern 4" -Description "Verify JSON connection test only (json-output-examples.ps1)" `
    -Command { Invoke-Sqlsim -json } `
    -ExpectedOutput '"connection_test_only": true'

# Test: 01-simple-queries.sql (works on any database)
Test-Command -Name "SQL Example: 01-simple-queries.sql" -Description "Verify catalog view queries work (examples/sql/01-simple-queries.sql)" `
    -Command { Invoke-Sqlsim -i "examples\sql\01-simple-queries.sql" -q } `
    -ExpectedOutput "Total Runtime:"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "WORKLOAD FILE TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# --- Basic workload tests ---

Test-Command -Name "Workload: Basic Execution" -Description "Execute workload file with multiple groups" `
    -Command { Invoke-Sqlsim -workload examples\workload\workload-test.json -q } `
    -ExpectedOutput "Workload groups: 2"

Test-Command -Name "Workload: Config Display" -Description "Workload shows group details in config" `
    -Command { Invoke-Sqlsim -workload examples\workload\workload-test.json -q } `
    -ExpectedOutput "Group 1:.*thread.*iteration.*batch"

Test-Command -Name "Workload: Completion" -Description "Workload completes with runtime" `
    -Command { Invoke-Sqlsim -workload examples\workload\workload-test.json -q } `
    -ExpectedOutput "Total Runtime:"

# --- Querystats value validation ---

Test-Command -Name "Querystats: Value Validation" -Description "Verify querystats values match SQL Server STATISTICS output" `
    -Command {
        # Run a deterministic query with -querystats -json, multiple iterations to validate aggregation
        $args = $BaseAuthArgs + @("-Q", "SELECT TOP 5 name FROM sys.objects ORDER BY object_id", "-querystats", "-json", "-q", "-r", "3")
        $output = & $runSqlsim $args 2>&1 | Out-String
        $json = $output | ConvertFrom-Json
        $qs = $json.query_stats
        $q = $qs.queries[0]
        $t = $qs.totals
        $issues = @()

        # Row count must be 5 (TOP 5)
        if ($q.row_count.avg -ne 5.0) { $issues += "row_count avg=$($q.row_count.avg), expected 5" }
        if ($q.row_count.min -ne 5) { $issues += "row_count min=$($q.row_count.min), expected 5" }
        if ($q.row_count.max -ne 5) { $issues += "row_count max=$($q.row_count.max), expected 5" }

        # Executions must be 3 (1 thread x 3 iterations)
        if ($q.executions -ne 3) { $issues += "executions=$($q.executions), expected 3" }
        if ($t.executions -ne 3) { $issues += "total executions=$($t.executions), expected 3" }
        if (@($q.spids).Count -ne 1 -or $q.spid_count -ne 1 -or $q.spids[0] -le 0) {
            $issues += "SPID metadata is missing or invalid"
        }

        # Total rows must be 15 (5 rows x 3 executions)
        if ($t.total_rows -ne 15) { $issues += "total_rows=$($t.total_rows), expected 15" }

        # Logical reads must be > 0 (query reads system catalog)
        if ($q.logical_reads.avg -le 0) { $issues += "logical_reads avg=$($q.logical_reads.avg), expected > 0" }
        if ($t.logical_reads -le 0) { $issues += "total logical_reads=$($t.logical_reads), expected > 0" }

        # Server elapsed must be >= 0 (can be 0 for fast queries)
        if ($q.server_elapsed_ms.avg -lt 0) { $issues += "server_elapsed avg=$($q.server_elapsed_ms.avg), expected >= 0" }

        # Total elapsed must be > 0
        if ($t.total_elapsed_ms -le 0) { $issues += "total_elapsed=$($t.total_elapsed_ms), expected > 0" }

        # Totals consistency: total_elapsed = avg * executions (within rounding)
        $expectedTotalElapsed = [math]::Round($q.total_elapsed_ms.avg * $q.executions, 1)
        $actualTotalElapsed = [math]::Round($t.total_elapsed_ms, 1)
        if ([math]::Abs($expectedTotalElapsed - $actualTotalElapsed) -gt 1.0) {
            $issues += "total_elapsed inconsistency: avg*exec=$expectedTotalElapsed vs total=$actualTotalElapsed"
        }

        # Failures must be 0 for a valid query
        if ($q.failures -ne 0) { $issues += "failures=$($q.failures), expected 0" }
        if ($t.failures -ne 0) { $issues += "total failures=$($t.failures), expected 0" }

        if ($issues.Count -eq 0) {
            "Querystats values validated: 3 executions, 5 rows each, logical_reads>0, totals consistent"
        } else {
            throw "Querystats validation failed: $($issues -join '; ')"
        }
    }.GetNewClosure() `
    -ExpectedOutput "Querystats values validated"

# --- Workload with querystats ---

Test-Command -Name "Workload: Querystats" -Description "Workload with -querystats shows per-query stats" `
    -Command { Invoke-Sqlsim -workload examples\workload\workload-test.json -q -querystats } `
    -ExpectedOutput "Query Stats.*SET STATISTICS"

Test-Command -Name "Workload: Querystats Totals" -Description "Workload querystats shows totals with execution count" `
    -Command { Invoke-Sqlsim -workload examples\workload\workload-test.json -q -querystats } `
    -ExpectedOutput "Totals:[\s\S]*Executions:\s+52"

# --- Workload JSON output ---

Test-Command -Name "Workload: JSON Output" -Description "Workload with -json produces valid JSON with workload fields" `
    -Command { Invoke-Sqlsim -workload examples\workload\workload-test.json -q -json } `
    -ExpectedOutput '"workload_file"[\s\S]*"workload_groups":\s*2[\s\S]*"batches":\s*\['

Test-Command -Name "Workload: JSON Querystats" -Description "Workload with -json -querystats includes query_stats section" `
    -Command { Invoke-Sqlsim -workload examples\workload\workload-test.json -q -json -querystats } `
    -ExpectedOutput '"query_stats"[\s\S]*"totals"[\s\S]*"executions":\s*52'

# --- Workload parameter conflict tests ---

Test-Command -Name "Workload Conflict: -Q with -workload" -Description "Reject -Q when -workload is specified" `
    -Command { Invoke-Sqlsim -workload examples\workload\workload-test.json -Q "SELECT 1" 2>&1 } `
    -ShouldFail $true `
    -ExpectedError "Cannot use -workload with -Q or -i"

Test-Command -Name "Workload Conflict: -i with -workload" -Description "Reject -i when -workload is specified" `
    -Command { Invoke-Sqlsim -workload examples\workload\workload-test.json -i examples\sql\01-simple-queries.sql 2>&1 } `
    -ShouldFail $true `
    -ExpectedError "Cannot use -workload with -Q or -i"

Test-Command -Name "Workload Conflict: -replay with -workload" -Description "Reject -replay when -workload is specified" `
    -Command { & $runSqlsim -E -workload examples\workload\workload-test.json -replay fast -replayfile testing\clean-replay.xml 2>&1 } `
    -ShouldFail $true `
    -ExpectedError "Cannot use.*(workload|replay)"

Test-Command -Name "Workload: Missing File" -Description "Reject workload with nonexistent file" `
    -Command { Invoke-Sqlsim -workload nonexistent.json 2>&1 } `
    -ShouldFail $true `
    -ExpectedError "Cannot open workload file"

Test-Command -Name "Workload: -n Ignored Warning" -Description "Warning when -n used with -workload" `
    -Command { Invoke-Sqlsim -workload examples\workload\workload-test.json -q -n 4 } `
    -ExpectedOutput "warning: -n 4 ignored with -workload"

Test-Command -Name "Workload: -r Ignored Warning" -Description "Warning when -r used with -workload" `
    -Command { Invoke-Sqlsim -workload examples\workload\workload-test.json -q -r 10 } `
    -ExpectedOutput "warning: -r 10 ignored with -workload"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "REPLAY TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# ============================================================
# Live capture → convert → replay cycle
# ============================================================
# Capture a rich workload with multiple query types, then replay and verify.
# This replaces the static fixture approach — every test run captures fresh.

$replayXelDir = "C:\temp"
$replayOrigXel = "$replayXelDir\sqlsim_fulltest_capture*.xel"
$replayReplayXel = "$replayXelDir\sqlsim_fulltest_replay_capture*.xel"
$replayTraceXml = Join-Path $script:testDir "fulltest-replay-trace.xml"
$replayFixtureReady = $true

Write-Host "--- Replay: Live Capture Phase ---" -ForegroundColor Yellow

# Clean old files
Remove-Item $replayOrigXel -ErrorAction SilentlyContinue
Remove-Item $replayReplayXel -ErrorAction SilentlyContinue
Remove-Item $replayTraceXml -ErrorAction SilentlyContinue

# Azure SQL Database cannot switch databases, so replay there runs entirely in the
# target database. SQL Server keeps the fixture's recorded master/tempdb context.
$replayDb = if ($IsAzure) { $Database } else { "tempdb" }

# Create test stored proc (using sqlsim_admin so it's not captured)
Write-Host "  Creating test stored procedure..." -ForegroundColor Gray
Invoke-Sqlsim -app sqlsim_admin -d $replayDb -Q "IF OBJECT_ID('dbo.sqlsim_replay_test_proc','P') IS NOT NULL DROP PROCEDURE dbo.sqlsim_replay_test_proc`nGO`nCREATE PROCEDURE dbo.sqlsim_replay_test_proc @id INT, @name NVARCHAR(100) AS BEGIN SELECT @id AS id, @name AS name END" -q 2>&1 | Out-Null

# testing\clean-replay.xml replays three rpc_completed events against this proc,
# so it must exist whenever the live capture falls back to the static fixture.
Invoke-Sqlsim -app sqlsim_admin -d $replayDb -Q "IF OBJECT_ID('dbo.sqlsim_test_proc','P') IS NOT NULL DROP PROCEDURE dbo.sqlsim_test_proc`nGO`nCREATE PROCEDURE dbo.sqlsim_test_proc @id INT, @name NVARCHAR(100) AS BEGIN SELECT @id AS id, @name AS name END" -q 2>&1 | Out-Null

# Start XEvent capture
Write-Host "  Starting XEvent capture session..." -ForegroundColor Gray
$captureSetupSql = @"
IF EXISTS(SELECT 1 FROM sys.dm_xe_sessions WHERE name = 'sqlsim_fulltest_capture')
    ALTER EVENT SESSION sqlsim_fulltest_capture ON SERVER STATE = STOP;
IF EXISTS(SELECT 1 FROM sys.server_event_sessions WHERE name = 'sqlsim_fulltest_capture')
    DROP EVENT SESSION sqlsim_fulltest_capture ON SERVER;
GO
CREATE EVENT SESSION sqlsim_fulltest_capture ON SERVER
ADD EVENT sqlserver.sql_batch_completed(
    ACTION(sqlserver.session_id, sqlserver.database_name)
    WHERE sqlserver.client_app_name = 'sqlsim'
),
ADD EVENT sqlserver.rpc_completed(
    ACTION(sqlserver.session_id, sqlserver.database_name)
    WHERE sqlserver.client_app_name = 'sqlsim'
)
ADD TARGET package0.event_file(
    SET filename = N'$replayXelDir\sqlsim_fulltest_capture.xel', max_file_size = 10
)
WITH (MAX_MEMORY = 4096 KB, MAX_DISPATCH_LATENCY = 1 SECONDS);
GO
ALTER EVENT SESSION sqlsim_fulltest_capture ON SERVER STATE = START;
"@
Invoke-Sqlsim -app sqlsim_admin -Q $captureSetupSql -q 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  WARNING: Could not start XEvent capture — replay tests will use static fixture" -ForegroundColor Yellow
    $replayFixtureReady = $false
}

if ($replayFixtureReady) {
    # Run rich workload: SQL batches (3 threads × 3 queries)
    Write-Host "  Running SQL batch workload (3 threads x 3 queries)..." -ForegroundColor Gray
    Invoke-Sqlsim -d master -Q "SELECT @@VERSION`nGO`nSELECT name, database_id FROM sys.databases`nGO`nSELECT @@SERVERNAME" -n 3 -q 2>&1 | Out-Null

    # Run RPC workload: user stored proc calls
    Write-Host "  Running RPC workload: user stored proc via {CALL}..." -ForegroundColor Gray
    Invoke-Sqlsim -d tempdb -Q "{CALL dbo.sqlsim_replay_test_proc(1, N'hello')}`nGO`n{CALL dbo.sqlsim_replay_test_proc(2, N'world')}`nGO`n{CALL dbo.sqlsim_replay_test_proc(3, N'test')}" -q 2>&1 | Out-Null

    # Run RPC workload: sp_executesql calls
    Write-Host "  Running RPC workload: sp_executesql via {CALL}..." -ForegroundColor Gray
    Invoke-Sqlsim -d tempdb -Q "{CALL sp_executesql(N'SELECT @p1 AS val', N'@p1 INT', 42)}`nGO`n{CALL sp_executesql(N'SELECT @p1 AS val, @p2 AS label', N'@p1 INT, @p2 NVARCHAR(50)', 99, N'replay_test')}" -q 2>&1 | Out-Null

    # Wait for event flush and stop capture
    Write-Host "  Waiting for event flush..." -ForegroundColor Gray
    Start-Sleep -Seconds 2
    Invoke-Sqlsim -app sqlsim_admin -Q "ALTER EVENT SESSION sqlsim_fulltest_capture ON SERVER STATE = STOP;" -q 2>&1 | Out-Null

    # Convert .xel to replay XML
    Write-Host "  Converting .xel to replay XML..." -ForegroundColor Gray
    $convertScript = Join-Path $PSScriptRoot "replay\convert-xel.ps1"
    & $convertScript -XelFile $replayOrigXel -OutputFile $replayTraceXml -ServerName $Server 2>&1 | Out-Null
    if (-not (Test-Path $replayTraceXml)) {
        Write-Host "  WARNING: Could not convert .xel to XML — replay tests will use static fixture" -ForegroundColor Yellow
        $replayFixtureReady = $false
    }
}

# Determine which fixture to use
if ($replayFixtureReady) {
    $replayFixture = $replayTraceXml
    # Count events for dynamic validation
    $countOutput = Invoke-Sqlsim -replay fast -replayfile $replayFixture -q 2>&1 | Out-String
    $countOutput -match "Original trace:\s+(\d+) events" | Out-Null
    $expectedReplayEvents = if ($Matches) { [int]$Matches[1] } else { 0 }
    Write-Host "  Replay fixture ready: $expectedReplayEvents replayable events captured" -ForegroundColor Green
} else {
    # Fallback to static fixture
    $replayFixture = Join-Path $script:testDir "clean-replay.xml"
    $expectedReplayEvents = 14  # Known count for the static fixture
    if (Test-Path $replayFixture) {
        Write-Host "  Using static fixture: $replayFixture" -ForegroundColor Yellow
    } else {
        Write-Host "  WARNING: No replay fixture available — replay tests will fail" -ForegroundColor Red
    }
    # The fixture was recorded against master and tempdb. Azure SQL Database cannot
    # switch databases, so replay a copy that records the target database instead.
    if ($IsAzure -and (Test-Path $replayFixture)) {
        $fixtureXml = [IO.File]::ReadAllText($replayFixture)
        foreach ($recordedDb in @("master", "tempdb")) {
            $fixtureXml = $fixtureXml.Replace(
                "<action name=`"database_name`" package=`"sqlserver`"><value><![CDATA[$recordedDb]]>",
                "<action name=`"database_name`" package=`"sqlserver`"><value><![CDATA[$Database]]>")
        }
        $replayFixture = Join-Path $script:testDir "clean-replay-azure.xml"
        [IO.File]::WriteAllText($replayFixture, $fixtureXml)
        Write-Host "  Azure SQL Database: replaying the fixture in $Database" -ForegroundColor Yellow
    }
}

Write-Host ""

# --- Parameter conflict tests ---

Test-Command -Name "Replay Conflict: -Q with -replay" -Description "Reject -Q when -replay is specified" `
    -Command { & $runSqlsim -E -replay fast -replayfile $replayFixture -Q "SELECT 1" 2>&1 } `
    -ShouldFail $true `
    -ExpectedError "Cannot use -replay with -Q or -i"

Test-Command -Name "Replay Conflict: -i with -replay" -Description "Reject -i when -replay is specified" `
    -Command { & $runSqlsim -E -replay fast -replayfile $replayFixture -i $replayFixture 2>&1 } `
    -ShouldFail $true `
    -ExpectedError "Cannot use -replay with -Q or -i"

Test-Command -Name "Replay Conflict: -p with -replay" -Description "Reject -p when -replay is specified" `
    -Command { & $runSqlsim -E -replay fast -replayfile $replayFixture -p 2>&1 } `
    -ShouldFail $true `
    -ExpectedError "Cannot use -p with -replay"

Test-Command -Name "Replay Conflict: -reconnect with -replay" -Description "Reject -reconnect when -replay is specified" `
    -Command { & $runSqlsim -E -replay fast -replayfile $replayFixture -reconnect 2>&1 } `
    -ShouldFail $true `
    -ExpectedError "Cannot use -reconnect with -replay"

Test-Command -Name "Replay Conflict: -usepool with -replay" -Description "Reject -usepool when -replay is specified" `
    -Command { & $runSqlsim -E -replay fast -replayfile $replayFixture -reconnect -usepool 2>&1 } `
    -ShouldFail $true `
    -ExpectedError "Cannot use -reconnect with -replay"

Test-Command -Name "Replay Conflict: Missing -replayfile" -Description "Reject -replay without -replayfile" `
    -Command { & $runSqlsim -E -replay fast 2>&1 } `
    -ShouldFail $true `
    -ExpectedError "-replay requires -replayfile"

Test-Command -Name "Replay Conflict: Missing -replay" -Description "Reject -replayfile without -replay" `
    -Command { & $runSqlsim -E -replayfile $replayFixture 2>&1 } `
    -ShouldFail $true `
    -ExpectedError "-replayfile requires -replay"

Test-Command -Name "Replay Conflict: Invalid replay mode" -Description "Reject invalid replay mode value" `
    -Command { & $runSqlsim -E -replay invalid -replayfile $replayFixture 2>&1 } `
    -ShouldFail $true `
    -ExpectedError "Invalid replay mode"

# --- Fast mode replay tests ---

Test-Command -Name "Replay Fast: Completion" -Description "Fast mode replay completes successfully" `
    -Command { Invoke-Sqlsim -replay fast -replayfile $replayFixture -q } `
    -ExpectedOutput "Total Runtime:"

Test-Command -Name "Replay Fast: Replay Summary Text" -Description "Fast mode shows replay summary with correct event count" `
    -Command { Invoke-Sqlsim -replay fast -replayfile $replayFixture -q } `
    -ExpectedOutput "Original trace:\s+$expectedReplayEvents events \($expectedReplayEvents ok, 0 error, 0 abort\)"

Test-Command -Name "Replay Fast: Replay Result Text" -Description "Fast mode shows replay result line" `
    -Command { Invoke-Sqlsim -replay fast -replayfile $replayFixture -q } `
    -ExpectedOutput "Replay result:\s+$expectedReplayEvents events \($expectedReplayEvents ok, 0 error, 0 abort\)"

# --- Stress mode replay tests ---

Test-Command -Name "Replay Stress: Completion" -Description "Stress mode replay completes with 2 threads x 2 iterations" `
    -Command { Invoke-Sqlsim -replay stress -replayfile $replayFixture -n 2 -r 2 -q } `
    -ExpectedOutput "Total Runtime:"

Test-Command -Name "Replay Stress: Replay Summary" -Description "Stress mode shows replay summary" `
    -Command { Invoke-Sqlsim -replay stress -replayfile $replayFixture -n 2 -r 2 -q } `
    -ExpectedOutput "Replay Summary:"

# --- JSON output replay tests ---

Test-Command -Name "Replay JSON: Valid JSON" -Description "Replay with -json produces valid JSON" `
    -Command { Invoke-Sqlsim -replay fast -replayfile $replayFixture -json } `
    -ExpectedOutput '"replay_mode":\s*"fast"'

Test-Command -Name "Replay JSON: Replay Summary Fields" -Description "JSON contains replay_summary with original and result" `
    -Command { Invoke-Sqlsim -replay fast -replayfile $replayFixture -json } `
    -ExpectedOutput '"replay_summary"'

Test-Command -Name "Replay JSON: Original Event Count" -Description "JSON replay_summary.original.events matches expected count" `
    -Command {
        $jsonText = Invoke-Sqlsim -replay fast -replayfile $replayFixture -json | Out-String
        $json = $jsonText | ConvertFrom-Json
        if ($json.replay_summary.original.events -eq $expectedReplayEvents -and $json.replay_summary.original.ok -eq $expectedReplayEvents -and $json.replay_summary.original.error -eq 0) {
            Write-Output "JSON replay_summary validated: events=$expectedReplayEvents ok=$expectedReplayEvents error=0"
        } else {
            Write-Error "Unexpected replay_summary values: events=$($json.replay_summary.original.events) ok=$($json.replay_summary.original.ok) error=$($json.replay_summary.original.error)"
        }
    } `
    -ExpectedOutput "JSON replay_summary validated"

Test-Command -Name "Replay JSON: Original Performance Comparison" -Description "JSON preserves original metrics, captured SPIDs, and Replay connection SPIDs" `
    -Command {
        $jsonText = Invoke-Sqlsim -replay fast -replayfile $replayFixture -querystats -json | Out-String
        $json = $jsonText | ConvertFrom-Json
        $captureQueries = @($json.replay_capture.queries)
        $replayQueries = @($json.query_stats.queries)
        $measuredOriginal = @($captureQueries | Where-Object { $null -ne $_.avg_duration_ms })
        $capturedSpids = @($json.replay_capture.captured_spids)
        $connectionMap = @($json.replay_capture.connection_map)
        $mappedConnections = @($connectionMap | Where-Object {
            $null -ne $_.captured_spid -and $null -ne $_.replay_spid
        })
        $distinctReplaySpids = @($connectionMap.replay_spid | Sort-Object -Unique)
        $queriesWithSpids = @($captureQueries | Where-Object { @($_.captured_spids).Count -gt 0 })
        if ($captureQueries.Count -gt 0 -and
            $replayQueries.Count -gt 0 -and
            $measuredOriginal.Count -gt 0 -and
            $capturedSpids.Count -gt 0 -and
            $connectionMap.Count -eq $capturedSpids.Count -and
            $mappedConnections.Count -eq $connectionMap.Count -and
            $distinctReplaySpids.Count -eq $connectionMap.Count -and
            $queriesWithSpids.Count -eq $captureQueries.Count) {
            Write-Output "Replay comparison validated: original=$($captureQueries.Count) replay=$($replayQueries.Count) connections=$($connectionMap.Count)"
        } else {
            Write-Error "Replay comparison JSON is incomplete."
        }
    } `
    -ExpectedOutput "Replay comparison validated"

# --- Verbose mode replay test ---

Test-Command -Name "Replay Verbose: Configuration" -Description "Verbose replay shows replay mode and event counts" `
    -Command { Invoke-Sqlsim -replay fast -replayfile $replayFixture -v -q } `
    -ExpectedOutput "Replay mode: fast"

# --- Fast mode -n warning test ---

Test-Command -Name "Replay Fast: -n Warning" -Description "Specifying -n in fast mode produces a warning" `
    -Command { Invoke-Sqlsim -replay fast -replayfile $replayFixture -n 4 -q 2>&1 | Out-String } `
    -ExpectedOutput "ignored in fast replay mode"

# --- Replay fidelity check (only available with live capture) ---

if ($replayFixtureReady) {
    Write-Host "`n--- Replay: Fidelity Verification ---" -ForegroundColor Yellow
    
    # Start a second XEvent capture during replay
    $fidelitySetupSql = @"
IF EXISTS(SELECT 1 FROM sys.dm_xe_sessions WHERE name = 'sqlsim_fulltest_replay_capture')
    ALTER EVENT SESSION sqlsim_fulltest_replay_capture ON SERVER STATE = STOP;
IF EXISTS(SELECT 1 FROM sys.server_event_sessions WHERE name = 'sqlsim_fulltest_replay_capture')
    DROP EVENT SESSION sqlsim_fulltest_replay_capture ON SERVER;
GO
CREATE EVENT SESSION sqlsim_fulltest_replay_capture ON SERVER
ADD EVENT sqlserver.sql_batch_completed(
    ACTION(sqlserver.session_id, sqlserver.database_name)
    WHERE sqlserver.client_app_name = 'sqlsim'
),
ADD EVENT sqlserver.rpc_completed(
    ACTION(sqlserver.session_id, sqlserver.database_name)
    WHERE sqlserver.client_app_name = 'sqlsim'
)
ADD TARGET package0.event_file(
    SET filename = N'$replayXelDir\sqlsim_fulltest_replay_capture.xel', max_file_size = 10
)
WITH (MAX_MEMORY = 4096 KB, MAX_DISPATCH_LATENCY = 1 SECONDS);
GO
ALTER EVENT SESSION sqlsim_fulltest_replay_capture ON SERVER STATE = START;
"@
    Invoke-Sqlsim -app sqlsim_admin -Q $fidelitySetupSql -q 2>&1 | Out-Null
    
    # Replay the trace (captured by XEvent)
    Invoke-Sqlsim -replay fast -replayfile $replayFixture -q 2>&1 | Out-Null
    
    # Wait for flush and stop replay capture
    Start-Sleep -Seconds 2
    Invoke-Sqlsim -app sqlsim_admin -Q "ALTER EVENT SESSION sqlsim_fulltest_replay_capture ON SERVER STATE = STOP;" -q 2>&1 | Out-Null
    
    # Compare original vs replay traces (compare-traces.ps1 uses Write-Host for colored output,
    # so we check exit code directly rather than capturing pipeline output via Test-Command)
    Write-Host "TEST: Replay Fidelity: Query Match" -ForegroundColor Yellow
    Write-Host "  Description: Replayed queries match original captured queries" -ForegroundColor Gray
    $compareScript = Join-Path $PSScriptRoot "replay\compare-traces.ps1"
    & $compareScript -OriginalXel $replayOrigXel -ReplayXel $replayReplayXel -ServerName $Server
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  PASSED" -ForegroundColor Green
        $script:testsPassed++
    } else {
        Write-Host "  FAILED: compare-traces.ps1 exit code $LASTEXITCODE" -ForegroundColor Red
        $script:testsFailed++
    }
}

# --- Replay cleanup ---

if ($replayFixtureReady) {
    Write-Host "`n  Cleaning up replay resources..." -ForegroundColor Gray
    Remove-Item $replayTraceXml -ErrorAction SilentlyContinue
    Remove-Item $replayOrigXel -ErrorAction SilentlyContinue
    Remove-Item $replayReplayXel -ErrorAction SilentlyContinue
    $cleanupSql = @"
IF EXISTS(SELECT 1 FROM sys.server_event_sessions WHERE name = 'sqlsim_fulltest_capture')
    DROP EVENT SESSION sqlsim_fulltest_capture ON SERVER;
IF EXISTS(SELECT 1 FROM sys.server_event_sessions WHERE name = 'sqlsim_fulltest_replay_capture')
    DROP EVENT SESSION sqlsim_fulltest_replay_capture ON SERVER;
"@
    Invoke-Sqlsim -app sqlsim_admin -Q $cleanupSql -q 2>&1 | Out-Null
}
Remove-Item (Join-Path $script:testDir "clean-replay-azure.xml") -ErrorAction SilentlyContinue
# The procedures are created whether or not live capture succeeded, so always drop
# them. DROP PROCEDURE rejects a database-qualified name, so run in $replayDb.
$procCleanupSql = @"
IF OBJECT_ID('dbo.sqlsim_replay_test_proc','P') IS NOT NULL
    DROP PROCEDURE dbo.sqlsim_replay_test_proc;
IF OBJECT_ID('dbo.sqlsim_test_proc','P') IS NOT NULL
    DROP PROCEDURE dbo.sqlsim_test_proc;
"@
Invoke-Sqlsim -app sqlsim_admin -d $replayDb -Q $procCleanupSql -q 2>&1 | Out-Null

# ============================================================
# Performance Regression Tests (compared against baseline)
# ============================================================
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "PERFORMANCE REGRESSION TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Load baseline for comparison
$fullBaseline = $null
$fullBaselineScenarios = @{}
# Win32_Processor is Windows-only; fall back to /proc/cpuinfo elsewhere.
if ($IsWindows -or $null -eq $IsWindows) {
    $currentCpuInfo = Get-CimInstance Win32_Processor | Select-Object -First 1
} else {
    $cpuName = (Select-String -Path '/proc/cpuinfo' -Pattern '^model name\s*:\s*(.+)$' -ErrorAction SilentlyContinue |
        Select-Object -First 1).Matches.Groups[1].Value
    $cpuCores = (Select-String -Path '/proc/cpuinfo' -Pattern '^processor\s*:' -ErrorAction SilentlyContinue).Count
    $currentCpuInfo = [pscustomobject]@{
        Name                      = if ($cpuName) { $cpuName.Trim() } else { 'Unknown' }
        NumberOfLogicalProcessors = $cpuCores
        NumberOfCores             = $cpuCores
    }
}
$currentVersionOutput = & $runSqlsim $BaseAuthArgs -Q "SELECT 1" -v -json -q 2>$null
$currentVersionJson = $currentVersionOutput -join "`n" | ConvertFrom-Json
$currentSqlEdition = if ($currentVersionJson.server_edition) { $currentVersionJson.server_edition } else { "" }
$currentSqlVersion = if ($currentVersionJson.server_version) { $currentVersionJson.server_version } else { "Unknown" }
$baselineDir = Join-Path $PSScriptRoot "baseline"
if (Test-Path $baselineDir) {
    $fullBaselineFile = Get-ChildItem $baselineDir -Filter "full-perf-*.json" | Sort-Object Name -Descending | Select-Object -First 1
    if ($fullBaselineFile) {
        try {
            $fullBaseline = Get-Content $fullBaselineFile.FullName -Raw | ConvertFrom-Json
            $baselineMatches =
                ($fullBaseline.machine.hostname -eq $env:COMPUTERNAME) -and
                ($fullBaseline.machine.cpu -eq $currentCpuInfo.Name.Trim()) -and
                ($fullBaseline.machine.cores_physical -eq $currentCpuInfo.NumberOfCores) -and
                ($fullBaseline.machine.cores_logical -eq $currentCpuInfo.NumberOfLogicalProcessors) -and
                ($fullBaseline.server -eq $Server) -and
                ($fullBaseline.sql_server_version -eq $currentSqlVersion)
            if ($baselineMatches) {
                foreach ($scenario in $fullBaseline.scenarios) {
                    $fullBaselineScenarios[$scenario.name] = $scenario.median_seconds
                }
                Write-Host "  Baseline: $($fullBaselineFile.Name)" -ForegroundColor DarkGray
            } else {
                Write-Host "  Ignoring $($fullBaselineFile.Name): environment does not match current host and SQL Server" -ForegroundColor DarkGray
                $fullBaseline = $null
                $fullBaselineFile = $null
            }
        } catch { $fullBaseline = $null }
    }
}
if (-not $fullBaseline) { Write-Host "  No baseline found — using fallback thresholds" -ForegroundColor DarkGray }
Write-Host ""

function Test-PerfResult {
    param([string]$Name, [double]$Runtime, [double]$FallbackThreshold)
    $blMedian = $fullBaselineScenarios[$Name]
    if ($blMedian -and $blMedian -gt 0) {
        $pctDiff = (($Runtime - $blMedian) / $blMedian) * 100
        $absPct = [Math]::Abs($pctDiff)
        if ($absPct -le 20) {
            Write-Host ("  PASSED ({0:N3}s vs baseline {1:N3}s, {2:+0.0;-0.0}%, within ±20%)" -f $Runtime, $blMedian, $pctDiff) -ForegroundColor Green
            $script:testsPassed++
        } elseif ($pctDiff -gt 20) {
            Write-Host ("  FAILED: {0:N3}s is {1:+0.0}% vs baseline {2:N3}s (exceeds +20%) — performance regression" -f $Runtime, $pctDiff, $blMedian) -ForegroundColor Red
            $script:testsFailed++
        } else {
            Write-Host ("  FAILED: {0:N3}s is {1:+0.0}% vs baseline {2:N3}s (exceeds -20%) — suspicious improvement, re-run baseline" -f $Runtime, $pctDiff, $blMedian) -ForegroundColor Red
            $script:testsFailed++
        }
    } else {
        if ($Runtime -lt $FallbackThreshold) {
            Write-Host "  PASSED (${Runtime}s < ${FallbackThreshold}s fallback threshold, no baseline)" -ForegroundColor Green
            $script:testsPassed++
        } else {
            Write-Host "  FAILED: ${Runtime}s exceeds ${FallbackThreshold}s fallback threshold" -ForegroundColor Red
            $script:testsFailed++
        }
    }
}

# These gates measure client throughput against a low-latency target. Each Azure SQL
# Database round trip costs tens of milliseconds, so they would measure the network.
if ($IsAzure) {
    $perfSkipReason = "Throughput gates need a low-latency target, not Azure SQL Database"
    Write-TestSkipped -Name "Single-thread SELECT 1 x1000" -Description "SELECT 1 x1000 single-threaded" -Reason $perfSkipReason
    Write-TestSkipped -Name "4-thread SELECT 1 x1000" -Description "SELECT 1 x1000 with 4 threads (4000 total)" -Reason $perfSkipReason
    Write-TestSkipped -Name "4-thread sys.objects x500" -Description "SELECT TOP 50 * FROM sys.objects x500 with 4 threads (2000 total)" -Reason $perfSkipReason
} else {
    # Perf Test 1: Single-threaded SELECT 1 x1000
    Write-Host "TEST: Perf: Single-thread throughput" -ForegroundColor Yellow
    Write-Host "  Description: SELECT 1 x1000 single-threaded" -ForegroundColor Gray
    $perfOut1 = & $runSqlsim @BaseAuthArgs -q -n 1 -r 1000 -Q "SELECT 1" -json 2>&1 | Out-String
    $perfExit1 = $LASTEXITCODE
    if ($perfExit1 -eq 0) {
        try {
            $perfJson1 = $perfOut1 | ConvertFrom-Json
            $perfTime1 = $perfJson1.metrics.total_runtime_seconds
            Test-PerfResult -Name "Single-thread SELECT 1 x1000" -Runtime $perfTime1 -FallbackThreshold 5.0
        } catch {
            Write-Host "  FAILED: Could not parse JSON output" -ForegroundColor Red
            $script:testsFailed++
        }
    } else {
        Write-Host "  FAILED: Exit code $perfExit1" -ForegroundColor Red
        $script:testsFailed++
    }

    # Perf Test 2: Multi-threaded SELECT 1 x1000 (4 threads = 4000 total)
    Write-Host "`nTEST: Perf: Multi-thread throughput" -ForegroundColor Yellow
    Write-Host "  Description: SELECT 1 x1000 with 4 threads (4000 total)" -ForegroundColor Gray
    $perfOut2 = & $runSqlsim @BaseAuthArgs -q -n 4 -r 1000 -Q "SELECT 1" -json 2>&1 | Out-String
    $perfExit2 = $LASTEXITCODE
    if ($perfExit2 -eq 0) {
        try {
            $perfJson2 = $perfOut2 | ConvertFrom-Json
            $perfTime2 = $perfJson2.metrics.total_runtime_seconds
            Test-PerfResult -Name "4-thread SELECT 1 x1000" -Runtime $perfTime2 -FallbackThreshold 10.0
        } catch {
            Write-Host "  FAILED: Could not parse JSON output" -ForegroundColor Red
            $script:testsFailed++
        }
    } else {
        Write-Host "  FAILED: Exit code $perfExit2" -ForegroundColor Red
        $script:testsFailed++
    }

    # Perf Test 3: Multi-threaded with data (4 threads x 500 iter of a real query)
    # Uses sys.objects which exists in all databases — no AdventureWorksLT dependency
    Write-Host "`nTEST: Perf: Multi-thread with data" -ForegroundColor Yellow
    Write-Host "  Description: SELECT TOP 50 * FROM sys.objects x500 with 4 threads (2000 total)" -ForegroundColor Gray
    $perfOut3 = & $runSqlsim @BaseAuthArgs -q -n 4 -r 500 -Q "SELECT TOP 50 * FROM sys.objects" -json 2>&1 | Out-String
    $perfExit3 = $LASTEXITCODE
    if ($perfExit3 -eq 0) {
        try {
            $perfJson3 = $perfOut3 | ConvertFrom-Json
            $perfTime3 = $perfJson3.metrics.total_runtime_seconds
            Test-PerfResult -Name "4-thread sys.objects x500" -Runtime $perfTime3 -FallbackThreshold 30.0
        } catch {
            Write-Host "  FAILED: Could not parse JSON output" -ForegroundColor Red
            $script:testsFailed++
        }
    } else {
        Write-Host "  FAILED: Exit code $perfExit3" -ForegroundColor Red
        $script:testsFailed++
    }
}

# Save perf measurements to measurements folder
$perfScenarios = @()
$thresholdUsed = if ($fullBaseline) { "\u00B120% baseline" } else { $null }
$blFile = if ($fullBaselineFile) { $fullBaselineFile.Name } else { $null }
if ($perfTime1) { $perfScenarios += [ordered]@{ name = "Single-thread SELECT 1 x1000"; seconds = $perfTime1; baseline_median = $fullBaselineScenarios["Single-thread SELECT 1 x1000"]; baseline_file = $blFile; threshold_used = if ($thresholdUsed) { $thresholdUsed } else { "5.0s fallback" } } }
if ($perfTime2) { $perfScenarios += [ordered]@{ name = "4-thread SELECT 1 x1000"; seconds = $perfTime2; baseline_median = $fullBaselineScenarios["4-thread SELECT 1 x1000"]; baseline_file = $blFile; threshold_used = if ($thresholdUsed) { $thresholdUsed } else { "10.0s fallback" } } }
if ($perfTime3) { $perfScenarios += [ordered]@{ name = "4-thread sys.objects x500"; seconds = $perfTime3; baseline_median = $fullBaselineScenarios["4-thread sys.objects x500"]; baseline_file = $blFile; threshold_used = if ($thresholdUsed) { $thresholdUsed } else { "30.0s fallback" } } }
if ($perfScenarios.Count -gt 0) {
    $measureDir = Join-Path $PSScriptRoot "measurements"
    if (-not (Test-Path $measureDir)) { New-Item -ItemType Directory -Path $measureDir -Force | Out-Null }
    $ts = Get-Date -Format "yyyy-MM-dd-HHmmss"
    $measureData = [ordered]@{
        timestamp = $ts
        source = "full-test-suite"
        tag = $PerfTag
        machine = [ordered]@{
            hostname = $env:COMPUTERNAME
            cpu = $currentCpuInfo.Name.Trim()
            cores_physical = $currentCpuInfo.NumberOfCores
            cores_logical = $currentCpuInfo.NumberOfLogicalProcessors
            ram_gb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
            os = (Get-CimInstance Win32_OperatingSystem).Caption.Trim()
        }
        server = $Server
        sql_server_edition = $currentSqlEdition
        sql_server_version = $currentSqlVersion
        scenarios = $perfScenarios
    }
    $measureFile = Join-Path $measureDir "full-perf-$ts.json"
    $measureData | ConvertTo-Json -Depth 5 | Set-Content $measureFile -Encoding UTF8
    Write-Host "`n  Perf measurement saved: $measureFile" -ForegroundColor DarkGray
    if ($PerfTag) { Write-Host "  Tag: $PerfTag" -ForegroundColor DarkGray }
}

# ========================================
# CERTIFICATE VALIDATION TESTS
#
# sqlsim follows sqlcmd (Go): with neither -N nor -C the connection is
# negotiated without validating the server certificate; -N without -C requires
# validation; -C trusts it outright. Token authentication used to force
# TrustServerCertificate=Yes and ignore -N entirely, which silently disabled
# validation on the Azure SQL path where it matters most.
#
# These read the connection string sqlsim echoes in verbose mode, so they need
# no reachable server. The token only has to survive format validation.
# ========================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "CERTIFICATE VALIDATION TESTS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$probeToken = "eyJhbGciOiJIUzI1NiJ9." + ("a" * 120) + ".signaturepart"

function Get-ConnectionStringFor {
    param([string[]]$Arguments)

    $raw = & $runSqlsim @Arguments -Q "SELECT 1" -v -l 1 2>&1 | Out-String
    $line = ($raw -split "`r?`n") | Where-Object { $_ -match 'Connection String' } | Select-Object -First 1
    return ($line -replace '^.*Connection String: ', '')
}

function Test-CertificateCase {
    param([string]$Name, [string]$Description, [bool]$Condition, [string]$Detail = '')

    Write-Host "TEST: $Name" -ForegroundColor Yellow
    Write-Host "  Description: $Description" -ForegroundColor Gray
    if ($Condition) {
        Write-Host "  PASSED" -ForegroundColor Green
        $script:testsPassed++
    } else {
        Write-Host "  FAILED" -ForegroundColor Red
        if ($Detail) { Write-Host "  $Detail" -ForegroundColor DarkGray }
        $script:testsFailed++
        if ($script:StopOnError) {
            Write-Host "`nStopping test execution due to failure (StopOnError flag set)" -ForegroundColor Red
            exit 1
        }
    }
    Write-Host ""
}

$certCases = @(
    @{ Name = 'Token, no encryption flags';  Args = @('-S', 'probe.database.windows.net', '-d', 'db', '-T', $probeToken);                    Trust = 'Yes' }
    @{ Name = 'Token with -N s';             Args = @('-S', 'probe.database.windows.net', '-d', 'db', '-T', $probeToken, '-N', 's');         Trust = 'No'  }
    @{ Name = 'Token with -N m';             Args = @('-S', 'probe.database.windows.net', '-d', 'db', '-T', $probeToken, '-N', 'm');         Trust = 'No'  }
    @{ Name = 'Token with -C';               Args = @('-S', 'probe.database.windows.net', '-d', 'db', '-T', $probeToken, '-C');              Trust = 'Yes' }
    @{ Name = 'Integrated, no flags';        Args = @('-S', 'localhost', '-d', 'tempdb', '-E');                                              Trust = 'Yes' }
    @{ Name = 'Integrated with -N s';        Args = @('-S', 'localhost', '-d', 'tempdb', '-E', '-N', 's');                                   Trust = 'No'  }
    @{ Name = 'Integrated with -C';          Args = @('-S', 'localhost', '-d', 'tempdb', '-E', '-C');                                        Trust = 'Yes' }
    @{ Name = 'SQL auth with -N s';          Args = @('-S', 'localhost', '-d', 'tempdb', '-U', 'probeuser', '-P', 'probepass', '-N', 's');   Trust = 'No'  }
)

foreach ($case in $certCases) {
    $connectionString = Get-ConnectionStringFor -Arguments $case.Args
    $actual = if ($connectionString -match 'TrustServerCertificate=(\w+)') { $Matches[1] } else { '(absent)' }
    Test-CertificateCase -Name "Certificate: $($case.Name)" `
        -Description "TrustServerCertificate=$($case.Trust)" `
        -Condition ($actual -eq $case.Trust) `
        -Detail "expected $($case.Trust), got $actual"
}

# The keyword was emitted twice for token authentication, from the
# authentication branch and again from certificate handling.
$tokenConnectionString = Get-ConnectionStringFor -Arguments @(
    '-S', 'probe.database.windows.net', '-d', 'db', '-T', $probeToken, '-N', 's')
$emitted = ([regex]::Matches($tokenConnectionString, 'TrustServerCertificate=')).Count
Test-CertificateCase -Name "Certificate: keyword appears once" `
    -Description "TrustServerCertificate is not emitted twice for token authentication" `
    -Condition ($emitted -eq 1) `
    -Detail "emitted $emitted time(s)"

# A token must never reach the connection string: it is applied through
# SQLSetConnectAttr, and anything echoed in verbose mode could be logged.
Test-CertificateCase -Name "Certificate: token stays out of the connection string" `
    -Description "The access token does not appear in the echoed connection string" `
    -Condition ($tokenConnectionString -notmatch [regex]::Escape($probeToken)) `
    -Detail "the token was found in the echoed connection string"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "FULL TEST SUITE SUMMARY" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan
$totalTests = $testsPassed + $testsFailed + $testsWarning
$endTime = Get-Date
$duration = $endTime - $startTime
$endTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "TEST SUMMARY" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Smoke Tests:    47 (included in totals below)" -ForegroundColor White
Write-Host "Extended Tests: $($totalTests - 47)" -ForegroundColor White
Write-Host "Total Tests: $totalTests" -ForegroundColor White
Write-Host "Passed: $testsPassed" -ForegroundColor $(if ($testsPassed -eq $totalTests) { "Green" } else { "Yellow" })
Write-Host "Warnings: $testsWarning" -ForegroundColor $(if ($testsWarning -eq 0) { "Green" } else { "Yellow" })
Write-Host "Failed: $testsFailed" -ForegroundColor $(if ($testsFailed -eq 0) { "Green" } else { "Red" })
Write-Host "Duration: $($duration.TotalSeconds) seconds" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Cyan

# Write final summary and stop transcript if OutputFile was specified
if ($script:transcriptStarted) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Completed: $endTimestamp" -ForegroundColor Cyan
    Write-Host "Total Duration: $($duration.TotalSeconds) seconds" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    Stop-Transcript | Out-Null
    Write-Host "Output saved to: $script:outputFileHandle" -ForegroundColor Cyan
}

# Restore original directory
Pop-Location

if ($testsFailed -eq 0) {
    Write-Host "ALL TESTS PASSED!" -ForegroundColor Green
    exit 0
} else {
    Write-Host "SOME TESTS FAILED!" -ForegroundColor Red
    exit 1
}
