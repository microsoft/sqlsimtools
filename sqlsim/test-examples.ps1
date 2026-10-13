#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Validates that all examples work correctly across help text, documentation, and example scripts.

.DESCRIPTION
    This script tests three categories of examples:
    1. Help text examples (from -? output)
    2. sqlsim.md documentation examples
    3. Example scripts in the examples/ folder
    
    Tests use Windows Authentication against localhost by default.
    Some tests are skipped when they require Azure SQL or AdventureWorksLT database.

.PARAMETER Server
    SQL Server instance (default: localhost)

.PARAMETER Database
    Database name for basic tests (default: master)

.PARAMETER AdventureWorksDB
    AdventureWorksLT database name (default: AdventureWorksLT). Set to empty string to skip AdventureWorks tests.

.PARAMETER SkipAdventureWorks
    Skip all tests that require AdventureWorksLT database

.PARAMETER ExePath
    Path to sqlsim.exe (default: .\build\x64\Release\sqlsim.exe)

.EXAMPLE
    .\test-examples.ps1
    Run all example validation tests against localhost

.EXAMPLE
    .\test-examples.ps1 -SkipAdventureWorks
    Run tests without AdventureWorksLT database requirements

.EXAMPLE
    .\test-examples.ps1 -Server "myserver" -Database "testdb"
    Run tests against a specific server

.EXAMPLE
    .\test-examples.ps1 -Server "myserver.database.windows.net" -Database "mydb" -UseEntraAuth
    Run tests against Azure SQL with Microsoft Entra interactive authentication

.EXAMPLE
    $token = (az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv)
    .\test-examples.ps1 -Server "myserver.database.windows.net" -Database "mydb" -UseTokenAuth -Token $token
    Run tests against Azure SQL with access token authentication
#>

param(
    [string]$Server = "localhost",
    [string]$Database = "master",
    [string]$AdventureWorksDB = "AdventureWorksLT",
    [switch]$SkipAdventureWorks,
    [switch]$UseEntraAuth,
    [switch]$UseTokenAuth,
    [string]$Token = "",
    [string]$ExePath = ".\build\x64\Release\sqlsim.exe"
)

$ErrorActionPreference = "Continue"

# Verify sqlsim.exe exists
if (-not (Test-Path $ExePath)) {
    Write-Host "ERROR: sqlsim.exe not found at $ExePath" -ForegroundColor Red
    Write-Host "Run build.ps1 first to build the project" -ForegroundColor Yellow
    exit 1
}

# Auto-acquire token for Azure auth modes
if ($UseEntraAuth -or $UseTokenAuth) {
    if ([string]::IsNullOrEmpty($Token)) {
        Write-Host "Acquiring token via Azure CLI..." -ForegroundColor Cyan
        try {
            $null = az --version 2>&1
            $Token = (az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv)
            if ([string]::IsNullOrEmpty($Token)) {
                Write-Host "ERROR: Failed to acquire token. Make sure you're logged in with 'az login'" -ForegroundColor Red
                exit 1
            }
            Write-Host "✓ Token acquired successfully" -ForegroundColor Green
        } catch {
            Write-Host "ERROR: Azure CLI (az) not found. Please install Azure CLI or provide -Token parameter" -ForegroundColor Red
            Write-Host "Install: winget install Microsoft.AzureCLI" -ForegroundColor Yellow
            Write-Host "Or get token manually: az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv" -ForegroundColor Yellow
            exit 1
        }
    }
}

$script:testsPassed = 0
$script:testsFailed = 0
$script:testsSkipped = 0

# Set authentication arguments based on mode
# Both -UseEntraAuth and -UseTokenAuth use token auth for non-interactive testing
if ($UseTokenAuth -or $UseEntraAuth) {
    $script:AuthArgs = @("-T", $Token)
    $script:AuthName = "Entra (token)"
} else {
    $script:AuthArgs = @("-E")
    $script:AuthName = "Windows"
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "SQLSIM EXAMPLE VALIDATION TESTS" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Server  : $Server" -ForegroundColor White
Write-Host "Database: $Database" -ForegroundColor White
Write-Host "Auth    : $AuthName" -ForegroundColor White
Write-Host "AdventureWorksLT: $(if ($SkipAdventureWorks) { 'SKIPPED' } else { $AdventureWorksDB })" -ForegroundColor White
Write-Host "Exe Path: $ExePath" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan

function Test-Example {
    param(
        [string]$Category,
        [string]$TestName,
        [string[]]$Arguments,
        [switch]$ShouldFail,
        [string]$ExpectedOutput,
        [switch]$Skip,
        [string]$SkipReason,
        [switch]$MultiLineMatch  # Use (?s) mode for patterns that cross newlines
    )
    
    Write-Host "[$Category] $TestName" -ForegroundColor Yellow
    
    if ($Skip) {
        Write-Host "  ⊘ SKIPPED: $SkipReason" -ForegroundColor DarkYellow
        $script:testsSkipped++
        Write-Host ""
        return
    }
    
    $output = & $ExePath @Arguments 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    
    $passed = $false
    
    if ($ShouldFail) {
        $passed = ($exitCode -ne 0)
    } else {
        $passed = ($exitCode -eq 0)
    }
    
    if ($passed -and $ExpectedOutput) {
        if ($MultiLineMatch) {
            # Use single-line mode (?s) so . matches newlines
            $passed = $output -match "(?s)$ExpectedOutput"
        } else {
            $passed = $output -match $ExpectedOutput
        }
    }
    
    if ($passed) {
        Write-Host "  ✓ PASSED" -ForegroundColor Green
        $script:testsPassed++
    } else {
        Write-Host "  ✗ FAILED" -ForegroundColor Red
        Write-Host "    Exit Code: $exitCode (expected: $(if ($ShouldFail) { 'non-zero' } else { '0' }))" -ForegroundColor Gray
        if ($ExpectedOutput -and $output -notmatch $ExpectedOutput) {
            Write-Host "    Expected output pattern: $ExpectedOutput" -ForegroundColor Gray
        }
        if ($output.Length -lt 500) {
            Write-Host "    Output: $($output.Trim())" -ForegroundColor Gray
        }
        $script:testsFailed++
    }
    Write-Host ""
}

# ============================================================
# SECTION 1: HELP TEXT EXAMPLES (-? / -h)
# These examples appear in the help text shown by sqlsim -h
# Source: src/main.cpp lines 168-180
# ============================================================

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "HELP TEXT EXAMPLES (from -?)" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Determine if we're testing against localhost or a remote server
$isLocalhost = ($Server -eq "localhost" -or $Server -eq "." -or $Server -match "^\(local\)")

# Example: Connection test (defaults to localhost)
# Note: Connection test mode shows help/usage but still succeeds if connection works
Test-Example -Category "Help" -TestName "Connection test: sqlsim -E" `
    -Arguments (@("-S", $Server) + $AuthArgs + @("-q")) `
    -ExpectedOutput "Total Runtime:"

# Example: Basic query execution
Test-Example -Category "Help" -TestName "Basic query: sqlsim -S $Server -d $Database -Q `"SELECT @@VERSION`"" `
    -Arguments (@("-S", $Server, "-d", $Database) + $AuthArgs + @("-Q", "SELECT @@VERSION")) `
    -ExpectedOutput "@@VERSION"

# Example: Load test (simplified - no file needed)
Test-Example -Category "Help" -TestName "Load test pattern: -n 10 -r 100 -q" `
    -Arguments (@("-S", $Server, "-d", $Database) + $AuthArgs + @("-Q", "SELECT 1", "-n", "10", "-r", "100", "-q")) `
    -ExpectedOutput "Total Runtime:"

# Example: SQL Authentication (will fail without valid credentials, but tests syntax)
Test-Example -Category "Help" -TestName "SQL Auth syntax: -U myuser -P mypass" `
    -Arguments @("-S", $Server, "-d", $Database, "-U", "testuser", "-P", "testpass", "-Q", "SELECT 1") `
    -ShouldFail `
    -ExpectedOutput "Login failed|password"

# ============================================================
# SECTION 2: SQLSIM.MD DOCUMENTATION EXAMPLES
# These examples appear in the documentation
# Source: sqlsim.md
# ============================================================

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "DOCUMENTATION EXAMPLES (sqlsim.md)" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Getting Started - Minimal Examples
# These test localhost-specific patterns - skip on remote servers
Test-Example -Category "Docs" -TestName "Connection test only (minimal): -S localhost -E" `
    -Arguments @("-S", "localhost", "-E", "-q") `
    -ExpectedOutput "Total Runtime:" `
    -Skip:(-not $isLocalhost) -SkipReason "Localhost-specific test"

Test-Example -Category "Docs" -TestName "Connection test with database: -S localhost -d master -E" `
    -Arguments @("-S", "localhost", "-d", "master", "-E", "-q") `
    -ExpectedOutput "Total Runtime:" `
    -Skip:(-not $isLocalhost) -SkipReason "Localhost-specific test"

Test-Example -Category "Docs" -TestName "Basic query without database: -S localhost -E -Q `"SELECT @@VERSION`"" `
    -Arguments @("-S", "localhost", "-E", "-Q", "SELECT @@VERSION") `
    -ExpectedOutput "@@VERSION" `
    -Skip:(-not $isLocalhost) -SkipReason "Localhost-specific test"

Test-Example -Category "Docs" -TestName "Recommended with database: -S localhost -d master -E -Q `"SELECT 1`"" `
    -Arguments @("-S", "localhost", "-d", "master", "-E", "-Q", "SELECT 1") `
    -ExpectedOutput "1" `
    -Skip:(-not $isLocalhost) -SkipReason "Localhost-specific test"

# TDS 8.0 encrypted connection
Test-Example -Category "Docs" -TestName "TDS 8.0 encrypted: -S localhost -E -N m -C -Q `"SELECT @@VERSION`"" `
    -Arguments @("-S", "localhost", "-E", "-N", "m", "-C", "-Q", "SELECT @@VERSION") `
    -ExpectedOutput "@@VERSION" `
    -Skip:(-not $isLocalhost) -SkipReason "Localhost-specific test"

# Basic Query Execution examples - these use default localhost, skip on remote
Test-Example -Category "Docs" -TestName "Default to localhost: -E -Q `"SELECT @@VERSION`"" `
    -Arguments @("-E", "-Q", "SELECT @@VERSION") `
    -ExpectedOutput "@@VERSION" `
    -Skip:(-not $isLocalhost) -SkipReason "Localhost-specific test"

Test-Example -Category "Docs" -TestName "With database: -d $Database -Q `"SELECT @@SERVERNAME`"" `
    -Arguments (@("-S", $Server, "-d", $Database) + $AuthArgs + @("-Q", "SELECT @@SERVERNAME")) `
    -ExpectedOutput "@@SERVERNAME"

# Verbose mode
Test-Example -Category "Docs" -TestName "Verbose mode: -v" `
    -Arguments (@("-S", $Server, "-d", $Database) + $AuthArgs + @("-Q", "SELECT 1", "-v", "-q")) `
    -ExpectedOutput "\[PHASE 1\]" `
    -MultiLineMatch

# Quiet mode
Test-Example -Category "Docs" -TestName "Quiet mode: -q" `
    -Arguments (@("-S", $Server, "-d", $Database) + $AuthArgs + @("-Q", "SELECT 1", "-q")) `
    -ExpectedOutput "Total Runtime:"

# JSON output
Test-Example -Category "Docs" -TestName "JSON output: -json" `
    -Arguments (@("-S", $Server, "-d", $Database) + $AuthArgs + @("-Q", "SELECT @@VERSION", "-json")) `
    -ExpectedOutput '"version"' `
    -MultiLineMatch

# Output file redirection - note: output goes to file, so check file exists after
$tempOutput = "testing\test-example-output.txt"
Test-Example -Category "Docs" -TestName "Output to file: -o output.txt" `
    -Arguments (@("-S", $Server, "-d", $Database) + $AuthArgs + @("-Q", "SELECT @@VERSION", "-o", $tempOutput, "-q"))
if (Test-Path $tempOutput) {
    $content = Get-Content $tempOutput -Raw
    if ($content -match "Total Runtime:") {
        Write-Host "  (Output file validated)" -ForegroundColor DarkGray
    }
}
Remove-Item $tempOutput -ErrorAction SilentlyContinue

# Prepared statements
Test-Example -Category "Docs" -TestName "Prepared statements: -p" `
    -Arguments (@("-S", $Server, "-d", $Database) + $AuthArgs + @("-Q", "SELECT 1", "-p", "-n", "10", "-r", "100")) `
    -ExpectedOutput "Total Runtime:"

# Stop on error
Test-Example -Category "Docs" -TestName "Stop on error: -stoponerror" `
    -Arguments (@("-S", $Server, "-d", $Database) + $AuthArgs + @("-Q", "SELECT 1/0", "-stoponerror")) `
    -ShouldFail `
    -ExpectedOutput "STOP: Stopping execution"

# Connection string mode - localhost specific
Test-Example -Category "Docs" -TestName "Connection string: -c" `
    -Arguments @("-c", "Driver={ODBC Driver 18 for SQL Server};Server=localhost;Database=master;Trusted_Connection=yes;TrustServerCertificate=Yes;", "-Q", "SELECT @@VERSION") `
    -ExpectedOutput "@@VERSION" `
    -Skip:(-not $isLocalhost) -SkipReason "Localhost-specific test"

# Multiple threads and iterations
Test-Example -Category "Docs" -TestName "Concurrency: -n 10 -r 50" `
    -Arguments (@("-S", $Server, "-d", $Database) + $AuthArgs + @("-Q", "SELECT 1", "-n", "10", "-r", "50", "-q")) `
    -ExpectedOutput "Threads: 10" `
    -MultiLineMatch

# Exit code usage (success case)
Test-Example -Category "Docs" -TestName "Exit code 0 on success" `
    -Arguments (@("-S", $Server) + $AuthArgs + @("-Q", "SELECT 1"))

# ============================================================
# SECTION 3: EXAMPLE SCRIPTS (examples/ folder)
# Tests that example .ps1 scripts work correctly
# ============================================================

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "EXAMPLE SCRIPTS (examples/ folder)" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Test localhost-simple-test.ps1 patterns (these are localhost-specific)
Test-Example -Category "Scripts" -TestName "localhost-simple-test: Example 1 - Basic localhost (no -S)" `
    -Arguments @("-E", "-Q", "SELECT @@VERSION") `
    -ExpectedOutput "@@VERSION" `
    -Skip:(-not $isLocalhost) -SkipReason "Localhost-specific test"

Test-Example -Category "Scripts" -TestName "localhost-simple-test: Example 2 - Specify database without server" `
    -Arguments @("-d", "master", "-E", "-Q", "SELECT @@SERVERNAME") `
    -ExpectedOutput "@@SERVERNAME" `
    -Skip:(-not $isLocalhost) -SkipReason "Localhost-specific test"

Test-Example -Category "Scripts" -TestName "localhost-simple-test: Example 3 - Connection test only" `
    -Arguments (@("-S", $Server) + $AuthArgs + @("-v", "-q")) `
    -ExpectedOutput "Mode: Connection test only"

Test-Example -Category "Scripts" -TestName "localhost-simple-test: Example 5 - Multiple iterations" `
    -Arguments (@("-S", $Server) + $AuthArgs + @("-Q", "SELECT GETDATE()", "-r", "5", "-q")) `
    -ExpectedOutput "Total Runtime:"

Test-Example -Category "Scripts" -TestName "localhost-simple-test: Example 6 - Multiple threads" `
    -Arguments (@("-S", $Server, "-d", $Database) + $AuthArgs + @("-Q", "SELECT 1", "-n", "4", "-r", "10", "-q")) `
    -ExpectedOutput "Total Runtime:"

# Test json-output-examples.ps1 patterns
Test-Example -Category "Scripts" -TestName "json-output-examples: Example 1 - Basic JSON" `
    -Arguments (@("-S", $Server) + $AuthArgs + @("-Q", "SELECT 1 AS Value", "-json")) `
    -ExpectedOutput '"version"' `
    -MultiLineMatch

Test-Example -Category "Scripts" -TestName "json-output-examples: Example 2 - Multiple batches with GO" `
    -Arguments (@("-S", $Server) + $AuthArgs + @("-Q", "SELECT 1`nGO`nSELECT 2`nGO`nSELECT 3", "-json", "-q")) `
    -ExpectedOutput '"batch_count": 3'

Test-Example -Category "Scripts" -TestName "json-output-examples: Example 3 - JSON with optional features" `
    -Arguments (@("-S", $Server) + $AuthArgs + @("-Q", "SELECT 1", "-json", "-l", "30", "-t", "60", "-app", "MyTestApp")) `
    -ExpectedOutput '"login_timeout": 30' `
    -MultiLineMatch

Test-Example -Category "Scripts" -TestName "json-output-examples: Example 4 - Connection test only" `
    -Arguments (@("-S", $Server) + $AuthArgs + @("-json", "-q")) `
    -ExpectedOutput '"connection_test_only": true'

Test-Example -Category "Scripts" -TestName "json-output-examples: Example 5 - JSON verbose mode" `
    -Arguments (@("-S", $Server) + $AuthArgs + @("-Q", "SELECT @@VERSION", "-json", "-v", "-n", "2", "-r", "3", "-q")) `
    -ExpectedOutput '"connection_string"' `
    -MultiLineMatch

# Test sql-auth-simple.ps1 pattern (just validates the syntax works, will fail on auth)
Test-Example -Category "Scripts" -TestName "sql-auth-simple: SQL Auth parameter syntax" `
    -Arguments @("-S", $Server, "-d", $Database, "-U", "testuser", "-P", "testpass", "-Q", "SELECT @@VERSION") `
    -ShouldFail `
    -ExpectedOutput "Login failed|password"

# Test 01-simple-queries.sql (catalog view queries that work on any database)
Test-Example -Category "Scripts" -TestName "01-simple-queries.sql: Catalog views (any database)" `
    -Arguments (@("-S", $Server, "-d", $Database) + $AuthArgs + @("-i", "examples\sql\01-simple-queries.sql")) `
    -ExpectedOutput "Total Runtime:"

# Tests requiring AdventureWorksLT database
$skipAW = $SkipAdventureWorks -or [string]::IsNullOrEmpty($AdventureWorksDB)

Test-Example -Category "Scripts" -TestName "02-customer-queries-adventureworkslt.sql: Customer queries" `
    -Arguments (@("-S", $Server, "-d", $AdventureWorksDB) + $AuthArgs + @("-i", "examples\sql\02-customer-queries-adventureworkslt.sql")) `
    -Skip:$skipAW -SkipReason "Requires AdventureWorksLT database"

Test-Example -Category "Scripts" -TestName "03-product-queries-adventureworkslt.sql: Product queries" `
    -Arguments (@("-S", $Server, "-d", $AdventureWorksDB) + $AuthArgs + @("-i", "examples\sql\03-product-queries-adventureworkslt.sql")) `
    -Skip:$skipAW -SkipReason "Requires AdventureWorksLT database"

Test-Example -Category "Scripts" -TestName "04-sales-queries-adventureworkslt.sql: Sales queries" `
    -Arguments (@("-S", $Server, "-d", $AdventureWorksDB) + $AuthArgs + @("-i", "examples\sql\04-sales-queries-adventureworkslt.sql")) `
    -Skip:$skipAW -SkipReason "Requires AdventureWorksLT database"

Test-Example -Category "Scripts" -TestName "05-aggregation-queries-adventureworkslt.sql: Aggregation queries" `
    -Arguments (@("-S", $Server, "-d", $AdventureWorksDB) + $AuthArgs + @("-i", "examples\sql\05-aggregation-queries-adventureworkslt.sql")) `
    -Skip:$skipAW -SkipReason "Requires AdventureWorksLT database"

Test-Example -Category "Scripts" -TestName "06-complex-joins-adventureworkslt.sql: Complex joins" `
    -Arguments (@("-S", $Server, "-d", $AdventureWorksDB) + $AuthArgs + @("-i", "examples\sql\06-complex-joins-adventureworkslt.sql")) `
    -Skip:$skipAW -SkipReason "Requires AdventureWorksLT database"

Test-Example -Category "Scripts" -TestName "08-mixed-workload-adventureworkslt.sql: Mixed workload" `
    -Arguments (@("-S", $Server, "-d", $AdventureWorksDB) + $AuthArgs + @("-i", "examples\sql\08-mixed-workload-adventureworkslt.sql")) `
    -Skip:$skipAW -SkipReason "Requires AdventureWorksLT database"

Test-Example -Category "Scripts" -TestName "09-reporting-queries-adventureworkslt.sql: Reporting queries" `
    -Arguments (@("-S", $Server, "-d", $AdventureWorksDB) + $AuthArgs + @("-i", "examples\sql\09-reporting-queries-adventureworkslt.sql")) `
    -Skip:$skipAW -SkipReason "Requires AdventureWorksLT database"

# ============================================================
# SECTION 4: AZURE EXAMPLES
# Run when using -UseEntraAuth or -UseTokenAuth with an Azure server
# ============================================================

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "AZURE EXAMPLES" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$skipAzure = -not ($UseEntraAuth -or $UseTokenAuth)

# Entra interactive tests (only with -UseEntraAuth)
Test-Example -Category "Azure" -TestName "Azure SQL with Entra: -A" `
    -Arguments @("-S", $Server, "-d", $Database, "-A", "-Q", "SELECT @@VERSION") `
    -ExpectedOutput "@@VERSION" `
    -Skip:(-not $UseEntraAuth) -SkipReason "Requires -UseEntraAuth flag"

# Token auth tests (only with -UseTokenAuth)
Test-Example -Category "Azure" -TestName "Azure SQL with Token: -T" `
    -Arguments @("-S", $Server, "-d", $Database, "-T", $Token, "-Q", "SELECT @@VERSION") `
    -ExpectedOutput "@@VERSION" `
    -Skip:(-not $UseTokenAuth) -SkipReason "Requires -UseTokenAuth flag"

Test-Example -Category "Azure" -TestName "Azure SQL connection test" `
    -Arguments (@("-S", $Server, "-d", $Database) + $AuthArgs + @("-q")) `
    -ExpectedOutput "Total Runtime:" `
    -Skip:$skipAzure -SkipReason "Requires -UseEntraAuth or -UseTokenAuth flag"

Test-Example -Category "Azure" -TestName "Azure SQL with JSON" `
    -Arguments (@("-S", $Server, "-d", $Database) + $AuthArgs + @("-Q", "SELECT 1 AS TestValue", "-json")) `
    -ExpectedOutput '"success": true' `
    -MultiLineMatch `
    -Skip:$skipAzure -SkipReason "Requires -UseEntraAuth or -UseTokenAuth flag"

Test-Example -Category "Azure" -TestName "Azure SQL multi-thread: -n 4 -r 10" `
    -Arguments (@("-S", $Server, "-d", $Database) + $AuthArgs + @("-Q", "SELECT 1", "-n", "4", "-r", "10", "-q")) `
    -ExpectedOutput "Total Runtime:" `
    -Skip:$skipAzure -SkipReason "Requires -UseEntraAuth or -UseTokenAuth flag"

Test-Example -Category "Azure" -TestName "Managed Identity: -A ActiveDirectoryMsi" `
    -Skip -SkipReason "Requires Azure environment with managed identity"

# ============================================================
# RESULTS SUMMARY
# ============================================================

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "EXAMPLE VALIDATION RESULTS" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Passed : $testsPassed" -ForegroundColor Green
Write-Host "Failed : $testsFailed" -ForegroundColor $(if ($testsFailed -eq 0) { "Green" } else { "Red" })
Write-Host "Skipped: $testsSkipped" -ForegroundColor Yellow
Write-Host "Total  : $($testsPassed + $testsFailed + $testsSkipped)" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan

if ($testsFailed -eq 0) {
    Write-Host "✓ All example validation tests passed!" -ForegroundColor Green
    Write-Host "  Help text examples: Working" -ForegroundColor Cyan
    Write-Host "  Documentation examples: Working" -ForegroundColor Cyan
    Write-Host "  Example scripts: Working" -ForegroundColor Cyan
    exit 0
} else {
    Write-Host "✗ Some example validation tests failed." -ForegroundColor Red
    Write-Host "  Review the failures above and update examples or code as needed." -ForegroundColor Yellow
    exit 1
}
