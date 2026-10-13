<#
.SYNOPSIS
    Tests Managed Identity (MSI) authentication with sqlsim.
    
.DESCRIPTION
    This script tests both forms of Managed Identity authentication:
    1. System-assigned Managed Identity
    2. User-assigned Managed Identity (requires ObjectId)
    
    IMPORTANT: This script must be run on an Azure resource with a Managed Identity:
    - Azure VM with System or User-assigned MSI
    - Azure App Service with MSI enabled
    - Azure Functions with MSI enabled
    - Azure Container Instance with MSI
    
    It will NOT work on a local laptop or non-Azure environment.

.PARAMETER ServerName
    Azure SQL server name (e.g., myserver.database.windows.net)

.PARAMETER DatabaseName
    Database name (default: master)

.PARAMETER ObjectId
    Object ID (Principal ID) for User-assigned Managed Identity (optional).
    Find this in Azure Portal under Managed Identity -> Overview -> Object (principal) ID.
    If not specified, only System-assigned MSI is tested.

.PARAMETER Query
    Query to execute (default: SELECT @@VERSION, SUSER_SNAME(), DB_NAME())

.EXAMPLE
    # Test System-assigned MSI only
    .\test-managed-identity.ps1 -ServerName myserver.database.windows.net

.EXAMPLE
    # Test both System and User-assigned MSI
    .\test-managed-identity.ps1 -ServerName myserver.database.windows.net -ObjectId "12345678-1234-1234-1234-123456789abc"

.EXAMPLE
    # Test with specific database
    .\test-managed-identity.ps1 -ServerName myserver.database.windows.net -DatabaseName adventureworkslt
#>

param(
    [Parameter(Mandatory=$true)]
    $ServerName,
    
    $DatabaseName = "master",
    
    [string]$ObjectId = "",
    
    [string]$Query = "SELECT @@VERSION AS [Version], SUSER_SNAME() AS [User], DB_NAME() AS [Database]"
)

# Handle server name with port (comma gets interpreted as array)
if ($ServerName -is [array]) {
    $ServerName = $ServerName -join ","
}
$ServerName = [string]$ServerName

# Handle database name if passed as array
if ($DatabaseName -is [array]) {
    $DatabaseName = $DatabaseName -join ","
}
$DatabaseName = [string]$DatabaseName

$ErrorActionPreference = "Stop"

# Find sqlsim: the installed release for this machine's architecture, then the
# x64 release (ARM64 Windows can run it), then a source build, then PATH.
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'ARM64' } else { 'x64' }
$sqlsimPaths = @(
    (Join-Path $PSScriptRoot "..\..\$arch\sqlsim.exe"),
    (Join-Path $PSScriptRoot "..\..\x64\sqlsim.exe"),
    (Join-Path $PSScriptRoot "..\..\build\$arch\Release\sqlsim.exe")
)

$sqlsim = $sqlsimPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $sqlsim) { $sqlsim = (Get-Command sqlsim -ErrorAction SilentlyContinue).Source }

if (-not $sqlsim) {
    Write-Host "ERROR: sqlsim.exe not found in the release folder, a source build, or PATH" -ForegroundColor Red
    exit 1
}

Write-Host "========================================"
Write-Host "MANAGED IDENTITY AUTHENTICATION TEST"
Write-Host "========================================"
Write-Host ""
Write-Host "Server:   $ServerName"
Write-Host "Database: $DatabaseName"
Write-Host "sqlsim:   $sqlsim"
Write-Host ""

$passedTests = 0
$failedTests = 0

# Test 1: System-assigned Managed Identity
Write-Host "========================================"
Write-Host "Test 1: System-assigned Managed Identity"
Write-Host "========================================"
Write-Host "Command: $sqlsim -S $ServerName -d $DatabaseName -A ActiveDirectoryMsi -Q ""$Query"""
Write-Host ""

$output = $null
$testPassed = $false
try {
    $output = & $sqlsim -S $ServerName -d $DatabaseName -A ActiveDirectoryMsi -Q $Query 2>&1
    $exitCode = $LASTEXITCODE
    
    if ($exitCode -eq 0) {
        $testPassed = $true
    }
}
catch {
    $output = $_.Exception.Message
}

if ($testPassed) {
    Write-Host "[PASSED] System-assigned MSI authentication" -ForegroundColor Green
    Write-Host ""
    Write-Host "Output:"
    Write-Host $output
    $passedTests = $passedTests + 1
}
else {
    Write-Host "[FAILED] System-assigned MSI authentication" -ForegroundColor Red
    Write-Host ""
    Write-Host "Output:"
    Write-Host $output
    $failedTests = $failedTests + 1
}

Write-Host ""

# Test 2: User-assigned Managed Identity (if ObjectId provided)
if ($ObjectId -ne "") {
    Write-Host "========================================"
    Write-Host "Test 2: User-assigned Managed Identity"
    Write-Host "========================================"
    Write-Host "Object ID: $ObjectId"
    Write-Host "Command: $sqlsim -S $ServerName -d $DatabaseName -A ActiveDirectoryMsi -U $ObjectId -Q ""$Query"""
    Write-Host ""
    
    $output = $null
    $testPassed = $false
    try {
        $output = & $sqlsim -S $ServerName -d $DatabaseName -A ActiveDirectoryMsi -U $ObjectId -Q $Query 2>&1
        $exitCode = $LASTEXITCODE
        
        if ($exitCode -eq 0) {
            $testPassed = $true
        }
    }
    catch {
        $output = $_.Exception.Message
    }

    if ($testPassed) {
        Write-Host "[PASSED] User-assigned MSI authentication" -ForegroundColor Green
        Write-Host ""
        Write-Host "Output:"
        Write-Host $output
        $passedTests = $passedTests + 1
    }
    else {
        Write-Host "[FAILED] User-assigned MSI authentication" -ForegroundColor Red
        Write-Host ""
        Write-Host "Output:"
        Write-Host $output
        $failedTests = $failedTests + 1
    }
}
else {
    Write-Host "========================================"
    Write-Host "Test 2: User-assigned Managed Identity"
    Write-Host "========================================"
    Write-Host "SKIPPED: No -ObjectId provided"
    Write-Host ""
    Write-Host "To test User-assigned MSI, run:"
    Write-Host "  .\test-managed-identity.ps1 -ServerName $ServerName -ObjectId <object-id>"
}

Write-Host ""
Write-Host "========================================"
Write-Host "TEST SUMMARY"
Write-Host "========================================"

if ($passedTests -gt 0) {
    Write-Host "Passed: $passedTests" -ForegroundColor Green
}
else {
    Write-Host "Passed: $passedTests"
}

if ($failedTests -gt 0) {
    Write-Host "Failed: $failedTests" -ForegroundColor Red
}
else {
    Write-Host "Failed: $failedTests"
}

if ($failedTests -gt 0) {
    Write-Host ""
    Write-Host "TROUBLESHOOTING:" -ForegroundColor Yellow
    Write-Host "1. Ensure this script is running on an Azure resource with MSI enabled"
    Write-Host "2. Verify the Managed Identity has access to the Azure SQL database"
    Write-Host "3. Check that the SQL server allows Azure AD authentication"
    Write-Host "4. For User-assigned MSI on VMs, use Object ID (not Client ID)"
    exit 1
}

exit 0
