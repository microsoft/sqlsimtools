#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [string]$BaselinePath = (Join-Path $PSScriptRoot '..\.github\driver-versions.json'),
    [string]$ReportPath = ''
)

$ErrorActionPreference = 'Stop'

function Get-HighestVersion {
    param([string[]]$Versions)

    return $Versions |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object { [version]$_ } -Descending |
        Select-Object -First 1
}

function Get-WindowsOdbcVersion {
    $output = winget show `
        --id Microsoft.msodbcsql.18 `
        --exact `
        --accept-source-agreements `
        --disable-interactivity
    if ($LASTEXITCODE -ne 0) {
        throw "winget could not query Microsoft.msodbcsql.18 (exit $LASTEXITCODE)"
    }

    $versionLine = $output | Where-Object { $_ -match '^Version:\s*(\S+)' } | Select-Object -First 1
    if (-not $versionLine -or $versionLine -notmatch '^Version:\s*(\S+)') {
        throw 'Could not parse the Windows ODBC Driver 18 version from winget output.'
    }
    return $Matches[1]
}

function Get-UbuntuOdbcVersion {
    $index = (Invoke-WebRequest 'https://packages.microsoft.com/ubuntu/24.04/prod/pool/main/m/msodbcsql18/').Content
    $matches = [regex]::Matches($index, 'msodbcsql18_([0-9]+(?:\.[0-9]+){3})-1_amd64\.deb')
    $versions = @($matches | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    if ($versions.Count -eq 0) {
        throw 'Could not parse the Ubuntu ODBC Driver 18 package index.'
    }
    return Get-HighestVersion $versions
}

function Get-MacosOdbcVersion {
    $formula = (Invoke-WebRequest 'https://raw.githubusercontent.com/microsoft/homebrew-mssql-release/master/Formula/msodbcsql18.rb').Content
    if ($formula -notmatch 'version\s+"([0-9]+(?:\.[0-9]+){3})"') {
        throw 'Could not parse the macOS ODBC Driver 18 Homebrew formula.'
    }
    return $Matches[1]
}

function Get-MssqlPythonVersion {
    return (Invoke-RestMethod 'https://pypi.org/pypi/mssql-python/json').info.version
}

$baseline = Get-Content -LiteralPath $BaselinePath -Raw | ConvertFrom-Json
$latest = [ordered]@{
    odbcDriver18 = [ordered]@{
        windows = Get-WindowsOdbcVersion
        ubuntu = Get-UbuntuOdbcVersion
        macos = Get-MacosOdbcVersion
    }
    mssqlPython = Get-MssqlPythonVersion
}

$changed = [ordered]@{
    windows = $latest.odbcDriver18.windows -ne $baseline.odbcDriver18.windows
    ubuntu = $latest.odbcDriver18.ubuntu -ne $baseline.odbcDriver18.ubuntu
    macos = $latest.odbcDriver18.macos -ne $baseline.odbcDriver18.macos
    mssqlPython = $latest.mssqlPython -ne $baseline.mssqlPython
}
$anyChanged = $changed.windows -or $changed.ubuntu -or $changed.macos -or $changed.mssqlPython

$report = [ordered]@{
    checkedAtUtc = [DateTime]::UtcNow.ToString('o')
    baseline = $baseline
    latest = $latest
    changed = $changed
    anyChanged = $anyChanged
}
$reportJson = $report | ConvertTo-Json -Depth 6

if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
    $reportJson | Set-Content -LiteralPath $ReportPath -Encoding utf8
}

if ($env:GITHUB_OUTPUT) {
    @(
        "any_changed=$($anyChanged.ToString().ToLowerInvariant())"
        "windows_changed=$($changed.windows.ToString().ToLowerInvariant())"
        "ubuntu_changed=$($changed.ubuntu.ToString().ToLowerInvariant())"
        "macos_changed=$($changed.macos.ToString().ToLowerInvariant())"
        "mssql_python_changed=$($changed.mssqlPython.ToString().ToLowerInvariant())"
        "windows_latest=$($latest.odbcDriver18.windows)"
        "ubuntu_latest=$($latest.odbcDriver18.ubuntu)"
        "macos_latest=$($latest.odbcDriver18.macos)"
        "mssql_python_latest=$($latest.mssqlPython)"
    ) | Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding utf8
}

$reportJson
