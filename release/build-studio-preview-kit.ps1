#!/usr/bin/env pwsh

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StudioRoot,
    [Parameter(Mandatory)][ValidateSet('linux-x64', 'win-arm64')][string]$Runtime,
    [Parameter(Mandatory)][string]$Commit,
    [Parameter(Mandatory)][string]$BuildUrl,
    [Parameter(Mandatory)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Tester kit output must be a new directory.' }
$source = (Resolve-Path -LiteralPath $StudioRoot).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
$extension = if ($Runtime -eq 'win-arm64') { '.exe' } else { '' }
foreach ($relative in @("sqlsimstudio$extension", "sqlsim/sqlsim$extension", 'sqlpysim/sqlpysim.py',
    'sqlpysim/requirements.txt', 'LICENSE', 'THIRD-PARTY-NOTICES.md', 'sqlsimstudio.md',
    'sqlsimstudio.html', 'CONFIGURATION.md', 'examples/README.md', '.github/skills/sqlsimstudio/SKILL.md')) {
    if (-not (Test-Path -LiteralPath (Join-Path $source $relative))) {
        throw "Studio build is missing $relative"
    }
}
New-Item -ItemType Directory -Path $output | Out-Null
$studio = Join-Path $output 'sqlsimstudio'
Copy-Item -LiteralPath $source -Destination $studio -Recurse -Force
foreach ($suite in @('smoke-test.ps1', 'full-test-suite.ps1')) {
    Copy-Item -LiteralPath (Join-Path $repository "sqlsimstudio/$suite") -Destination (Join-Path $studio $suite)
}
$fixtures = Join-Path $output 'sqlsim/testing'
New-Item -ItemType Directory -Path $fixtures -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $repository 'sqlsim/testing/replay-test-data.xml') -Destination $fixtures
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'run-studio-preview-tests.ps1') -Destination (Join-Path $output 'run-tests.ps1')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'studio-preview-tester-README.md') -Destination (Join-Path $output 'README.md')
Copy-Item -LiteralPath (Join-Path $repository 'LICENSE') -Destination $output
[ordered]@{
    schemaVersion = 1
    runtime = $Runtime
    releaseStage = 'Private Preview'
    commit = $Commit
    buildUrl = $BuildUrl
    validation = 'Offline only; live SQL and real-machine browser testing remain required.'
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'BUILD-INFO.json') -Encoding utf8
Write-Host "Private Preview tester kit staged: $output"
