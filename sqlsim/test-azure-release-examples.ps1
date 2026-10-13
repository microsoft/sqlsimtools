#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Test Azure SQL Database example scripts from the release directory structure
.DESCRIPTION
    Runs all Azure SQL Database example scripts from the release directory
    to validate they work correctly in the published structure.
    Requires Azure CLI (az) and an Azure SQL Database with AdventureWorksLT.
.PARAMETER ReleaseDir
    Path to the installation root (default: <repo-root>\release\sqlsimtools\1.0, resolved via $PSScriptRoot)
.PARAMETER ServerName
    Azure SQL Server name (e.g., myserver.database.windows.net)
.PARAMETER DatabaseName
    Azure SQL Database name (default: AdventureWorksLT)
.PARAMETER SkipInteractive
    Skip the interactive authentication test (azure-simple-interactive.ps1)
#>

param(
    [string]$ReleaseDir = (Join-Path $PSScriptRoot '..\release\sqlsimtools\1.0'),
    [Parameter(Mandatory=$true)]
    [string]$ServerName,
    [string]$DatabaseName = "AdventureWorksLT",
    [switch]$SkipInteractive
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "TESTING AZURE RELEASE EXAMPLES" -ForegroundColor Cyan
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

# Verify Azure CLI is available
try {
    $null = az --version 2>&1
} catch {
    Write-Host "ERROR: Azure CLI (az) not found. Please install Azure CLI." -ForegroundColor Red
    exit 1
}

# Get access token for Azure SQL Database
Write-Host "Getting Azure SQL Database access token..." -ForegroundColor Cyan
try {
    $token = (az account get-access-token --resource https://database.windows.net --query accessToken -o tsv)
    if (-not $token) {
        Write-Host "ERROR: Failed to get access token. Please run 'az login' first." -ForegroundColor Red
        exit 1
    }
    Write-Host "✓ Access token obtained" -ForegroundColor Green
    Write-Host ""
} catch {
    Write-Host "ERROR: Failed to get access token: $_" -ForegroundColor Red
    Write-Host "Please run 'az login' first" -ForegroundColor Yellow
    exit 1
}

# Change to release examples directory
Push-Location $examplesDir

try {
    # Test counters
    $passed = 0
    $failed = 0
    $skipped = 0
    $failedScripts = @()

    # Helper function to run a script test
    function Test-AzureScript {
        param(
            [string]$ScriptName,
            [string]$Server,
            [string]$Database
        )
        
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "Testing: $ScriptName" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        
        # Read the script content
        $scriptContent = Get-Content $ScriptName -Raw
        
        # Replace placeholder server name with actual server (use literal string replacement)
        $scriptContent = $scriptContent.Replace('myserver.database.windows.net', $Server)
        
        # Replace database name if not AdventureWorksLT (use literal string replacement)
        if ($Database -ne "AdventureWorksLT") {
            $scriptContent = $scriptContent.Replace('AdventureWorksLT', $Database)
        }
        
        # The examples get their own token from az and pipe it to sqlsim on stdin,
        # so no secret is written into the copy. The copy sits beside the original
        # so $PSScriptRoot still resolves the package's sqlsim.exe and sql folder.
        $tempScript = Join-Path (Split-Path $ScriptName -Parent) ".$([System.IO.Path]::GetFileNameWithoutExtension($ScriptName)).test-$PID.ps1"
        $scriptContent | Out-File -FilePath $tempScript -Encoding UTF8
        
        try {
            # Execute the script
            & $tempScript
            $exitCode = $LASTEXITCODE
            
            if ($exitCode -eq 0 -or $null -eq $exitCode) {
                Write-Host "✓ PASSED: $ScriptName" -ForegroundColor Green
                return $true
            } else {
                Write-Host "✗ FAILED: $ScriptName" -ForegroundColor Red
                Write-Host "Exit code: $exitCode" -ForegroundColor Red
                return $false
            }
        } catch {
            Write-Host "✗ FAILED: $ScriptName" -ForegroundColor Red
            Write-Host "Error: $_" -ForegroundColor Red
            return $false
        } finally {
            # Clean up temp script
            if (Test-Path $tempScript) {
                Remove-Item $tempScript -Force
            }
        }
    }

    # Test azure-simple-interactive.ps1 (uses -A flag)
    if (-not $SkipInteractive) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "Testing: azure-simple-interactive.ps1" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "NOTE: This script uses interactive authentication (-A)" -ForegroundColor Yellow
        Write-Host "It may prompt for authentication in your browser." -ForegroundColor Yellow
        Write-Host ""
        
        try {
            # Run the interactive auth commands directly (script has path issues)
            ..\sqlsim.exe -S $ServerName -d $DatabaseName -A -Q "SELECT @@VERSION" | Out-Null
            $exitCode1 = $LASTEXITCODE
            
            ..\sqlsim.exe -S $ServerName -d $DatabaseName -A -i sql\01-simple-queries.sql | Out-Null
            $exitCode2 = $LASTEXITCODE
            
            if (($exitCode1 -eq 0 -or $null -eq $exitCode1) -and ($exitCode2 -eq 0 -or $null -eq $exitCode2)) {
                Write-Host "✓ PASSED: azure-simple-interactive.ps1" -ForegroundColor Green
                $passed++
            } else {
                Write-Host "✗ FAILED: azure-simple-interactive.ps1" -ForegroundColor Red
                Write-Host "Exit codes: $exitCode1, $exitCode2" -ForegroundColor Red
                $failed++
                $failedScripts += "azure-simple-interactive.ps1"
            }
        } catch {
            Write-Host "✗ FAILED: azure-simple-interactive.ps1" -ForegroundColor Red
            Write-Host "Error: $_" -ForegroundColor Red
            $failed++
            $failedScripts += "azure-simple-interactive.ps1"
        }
    } else {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Yellow
        Write-Host "SKIPPING: azure-simple-interactive.ps1" -ForegroundColor Yellow
        Write-Host "========================================" -ForegroundColor Yellow
        $skipped++
    }

    # Test run-basic-tests-azure-adventureworkslt.ps1
    if (Test-AzureScript -ScriptName "powershell\run-basic-tests-azure-adventureworkslt.ps1" -Server $ServerName -Database $DatabaseName) {
        $passed++
    } else {
        $failed++
        $failedScripts += "run-basic-tests-azure-adventureworkslt.ps1"
    }

    # Test run-all-tests-azure-adventureworkslt.ps1
    if (Test-AzureScript -ScriptName "powershell\run-all-tests-azure-adventureworkslt.ps1" -Server $ServerName -Database $DatabaseName) {
        $passed++
    } else {
        $failed++
        $failedScripts += "run-all-tests-azure-adventureworkslt.ps1"
    }

    # Test run-load-test-azure-adventureworkslt.ps1
    if (Test-AzureScript -ScriptName "powershell\run-load-test-azure-adventureworkslt.ps1" -Server $ServerName -Database $DatabaseName) {
        $passed++
    } else {
        $failed++
        $failedScripts += "run-load-test-azure-adventureworkslt.ps1"
    }

    # Test basic-perf-benchmark-adventureworkslt.ps1
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Testing: basic-perf-benchmark-adventureworkslt.ps1" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    try {
        # Run benchmark with Azure token
        ..\sqlsim.exe --version 2>&1 | Out-Null
        .\powershell\basic-perf-benchmark-adventureworkslt.ps1 -ServerName $ServerName -DatabaseName $DatabaseName -UseToken $token
        $exitCode = $LASTEXITCODE
        
        if ($exitCode -eq 0 -or $null -eq $exitCode) {
            Write-Host "✓ PASSED: basic-perf-benchmark-adventureworkslt.ps1" -ForegroundColor Green
            $passed++
        } else {
            Write-Host "✗ FAILED: basic-perf-benchmark-adventureworkslt.ps1" -ForegroundColor Red
            Write-Host "Exit code: $exitCode" -ForegroundColor Red
            $failed++
            $failedScripts += "basic-perf-benchmark-adventureworkslt.ps1"
        }
    } catch {
        Write-Host "✗ FAILED: basic-perf-benchmark-adventureworkslt.ps1" -ForegroundColor Red
        Write-Host "Error: $_" -ForegroundColor Red
        $failed++
        $failedScripts += "basic-perf-benchmark-adventureworkslt.ps1"
    }

    # Print summary
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "TEST SUMMARY" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Passed:  $passed" -ForegroundColor Green
    Write-Host "Failed:  $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })
    Write-Host "Skipped: $skipped" -ForegroundColor Yellow
    
    if ($failed -gt 0) {
        Write-Host ""
        Write-Host "Failed scripts:" -ForegroundColor Red
        $failedScripts | ForEach-Object {
            Write-Host "  - $_" -ForegroundColor Red
        }
    }
    
    Write-Host ""
    
    # Exit with appropriate code
    if ($failed -gt 0) {
        exit 1
    }
    
} finally {
    # Return to original directory
    Pop-Location
}
