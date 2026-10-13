#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Test non-Azure example scripts from the release directory structure
.DESCRIPTION
    Runs all localhost/SQL Server example scripts from the release directory
    to validate they work correctly in the published structure
.PARAMETER ReleaseDir
    Path to the installation root (default: <repo-root>\release\sqlsimtools\1.0, resolved via $PSScriptRoot)
.PARAMETER SqlUser
    SQL Server authentication username (optional). When set, sql-auth-simple.ps1
    is also tested.
.PARAMETER SqlPassword
    Password for SqlUser as a SecureString. If omitted with SqlUser, the script
    prompts for it, so the password never appears on the command line.
.EXAMPLE
    .\test-nonazure-release-examples.ps1 -SqlUser myuser
#>

param(
    [string]$ReleaseDir = (Join-Path $PSScriptRoot '..\release\sqlsimtools\1.0'),
    [string]$SqlUser = "",
    [securestring]$SqlPassword
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "TESTING RELEASE EXAMPLES (Non-Azure)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Verify release directory exists
if (-not (Test-Path $ReleaseDir)) {
    Write-Host "ERROR: Release directory not found at $ReleaseDir" -ForegroundColor Red
    Write-Host "Run .\publish.ps1 first to create the release package" -ForegroundColor Yellow
    exit 1
}

# Verify examples folder exists
$examplesDir = Join-Path $ReleaseDir "sqlsim\examples"
if (-not (Test-Path $examplesDir)) {
    Write-Host "ERROR: examples folder not found at $examplesDir" -ForegroundColor Red
    exit 1
}

# Change to release examples directory
Push-Location $examplesDir

try {
    # List of non-Azure scripts to test (now in powershell/ subfolder)
    $nonAzureScripts = @(
        "powershell\localhost-simple-test.ps1",
        "powershell\run-basic-tests-adventureworkslt.ps1",
        "powershell\run-basic-tests-verbose-adventureworkslt.ps1",
        "powershell\run-all-tests-adventureworkslt.ps1",
        "powershell\run-load-test-adventureworkslt.ps1",
        "powershell\basic-perf-benchmark-adventureworkslt.ps1"
    )
    
    # Add sql-auth-simple.ps1 only when a SQL login is supplied
    if ($SqlUser) {
        if (-not $SqlPassword) { $SqlPassword = Read-Host "SQL password for $SqlUser" -AsSecureString }
        $nonAzureScripts += "powershell\sql-auth-simple.ps1"
    }

    $successCount = 0
    $failCount = 0
    $skippedCount = 0

    foreach ($script in $nonAzureScripts) {
        $scriptPath = Join-Path $examplesDir $script
        
        if (-not (Test-Path $scriptPath)) {
            Write-Host "⚠ SKIPPED: $script (not found)" -ForegroundColor Yellow
            $skippedCount++
            continue
        }

        Write-Host ""
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "Testing: $script" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        
        try {
            # sql-auth-simple.ps1 takes the login as parameters; the SecureString
            # is passed through and the example sends it to sqlsim on stdin.
            if ($script -like "*sql-auth-simple.ps1") {
                & $scriptPath -Username $SqlUser -Password $SqlPassword
                $exitCode = $LASTEXITCODE
            }
            else {
                & $scriptPath
                $exitCode = $LASTEXITCODE
            }
            
            if ($exitCode -eq 0 -or $null -eq $exitCode) {
                Write-Host "✓ PASSED: $script" -ForegroundColor Green
                $successCount++
            } else {
                Write-Host "✗ FAILED: $script (exit code: $exitCode)" -ForegroundColor Red
                $failCount++
            }
        }
        catch {
            Write-Host "✗ FAILED: $script" -ForegroundColor Red
            Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
            $failCount++
        }
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "TEST SUMMARY" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Passed:  $successCount" -ForegroundColor Green
    Write-Host "Failed:  $failCount" -ForegroundColor Red
    Write-Host "Skipped: $skippedCount" -ForegroundColor Yellow
    
    if ($SqlUser) {
        Write-Host ""
        Write-Host "Note: SQL authentication test was included for $SqlUser" -ForegroundColor Cyan
    }
    else {
        Write-Host ""
        Write-Host "Note: SQL authentication test was skipped (use -SqlUser to test it)" -ForegroundColor Yellow
    }
    
    Write-Host ""

    if ($failCount -gt 0) {
        exit 1
    }
}
finally {
    Pop-Location
}
