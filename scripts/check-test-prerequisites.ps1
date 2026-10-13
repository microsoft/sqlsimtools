#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Check shared prerequisites for sqlsimtools source testing.

.DESCRIPTION
    Verifies that the native sqlsim binary, Python 3.10 or later,
    mssql-python, ODBC connectivity, and the AdventureWorksLT fixture are
    ready. A missing AdventureWorksLT database is restored automatically on a
    local SQL Server unless -SkipDatabaseProvisioning is specified.

    Use -IncludeLinux before building or running the Bash suites. It invokes
    sqlsim's authoritative Ubuntu prerequisite checker inside WSL and requires
    the Linux ODBC Driver 18 registration.

.EXAMPLE
    ./scripts/check-test-prerequisites.ps1

.EXAMPLE
    ./scripts/check-test-prerequisites.ps1 -Server localhost -Username sa -Password $password

.EXAMPLE
    ./scripts/check-test-prerequisites.ps1 -IncludeLinux
#>

[CmdletBinding()]
param(
    [string]$Server = 'localhost',
    [string]$Database = 'AdventureWorksLT',
    [string]$UseToken = '',
    [string]$Username = '',
    [string]$Password = '',
    [switch]$SkipDatabaseProvisioning,
    [switch]$IncludeLinux
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$sqlsimExe = Join-Path $repoRoot 'sqlsim\build\x64\Release\sqlsim.exe'
$sqlpysimScript = Join-Path $repoRoot 'sqlpysim\sqlpysim.py'
$databasePreflight = Join-Path $PSScriptRoot 'ensure-adventureworkslt.ps1'

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host 'SQLSIMTOOLS TEST PREREQUISITES' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan

foreach ($required in @($sqlsimExe, $sqlpysimScript, $databasePreflight)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required test input not found: $required"
    }
}
Write-Host 'Native sqlsim binary: ready' -ForegroundColor Green

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    throw 'Python was not found on PATH. Install Python 3.10 or later.'
}

$pythonVersionText = & python -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")'
if ($LASTEXITCODE -ne 0) {
    throw 'Could not determine the Python version.'
}
$pythonVersion = [version]$pythonVersionText
if ($pythonVersion -lt [version]'3.10') {
    throw "Python 3.10 or later is required; found $pythonVersion."
}
Write-Host "Python $pythonVersion`: ready" -ForegroundColor Green

& python -c 'import mssql_python'
if ($LASTEXITCODE -ne 0) {
    throw 'mssql-python is not installed. Run: python -m pip install -r .\sqlpysim\requirements.txt'
}
Write-Host 'mssql-python: ready' -ForegroundColor Green

if ($IncludeLinux) {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wsl) {
        throw 'WSL was not found. Install WSL with a supported Ubuntu 24.04 or 26.04 distribution.'
    }

    Write-Host 'Checking WSL Ubuntu build and ODBC prerequisites...' -ForegroundColor Cyan
    & $wsl.Source --cd $repoRoot bash -lc 'cd sqlsim && bash ./check-prerequisites-linux.sh --require-driver'
    if ($LASTEXITCODE -ne 0) {
        throw 'WSL sqlsim prerequisites are not ready. Follow the installation command reported above.'
    }
    Write-Host 'WSL sqlsim prerequisites: ready' -ForegroundColor Green
}

if (($Username -and -not $Password) -or ($Password -and -not $Username)) {
    throw 'Username and Password must be supplied together.'
}

if ($UseToken) {
    if ($Username -or $Password) {
        throw 'UseToken cannot be combined with Username or Password.'
    }

    $validationQuery = "IF OBJECT_ID(N'SalesLT.Product', N'U') IS NULL OR (SELECT COUNT_BIG(*) FROM SalesLT.Product) <> 295 OR OBJECT_ID(N'SalesLT.Customer', N'U') IS NULL OR (SELECT COUNT_BIG(*) FROM SalesLT.Customer) <> 847 THROW 50000, 'The target is not the expected AdventureWorksLT fixture.', 1;"
    # -T - reads the token from stdin so it never appears in a process list.
    $UseToken | & $sqlsimExe -S $Server -d $Database -T - -Q $validationQuery -q
    if ($LASTEXITCODE -ne 0) {
        throw "AdventureWorksLT validation failed for token-authenticated target $Server/$Database. Provision the sample database before running tests."
    }
    Write-Host "AdventureWorksLT ready: $Server/$Database." -ForegroundColor Green
}
else {
    $preflightArguments = @{
        Server = $Server
        Database = $Database
    }
    if ($Username) {
        $preflightArguments.Username = $Username
        $preflightArguments.Password = $Password
    }
    if ($SkipDatabaseProvisioning) {
        $preflightArguments.ValidateOnly = $true
    }
    & $databasePreflight @preflightArguments
    if ($LASTEXITCODE -ne 0) {
        throw "AdventureWorksLT preflight failed for $Server/$Database."
    }
}

Write-Host 'All shared test prerequisites are ready.' -ForegroundColor Green
