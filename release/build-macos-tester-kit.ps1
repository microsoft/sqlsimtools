#!/usr/bin/env pwsh

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SqlsimRoot,
    [Parameter(Mandatory)][string]$SqlpysimRoot,
    [Parameter(Mandatory)][string]$StudioRoot,
    [Parameter(Mandatory)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
if (Test-Path -LiteralPath $OutputDirectory) {
    throw "Tester kit output must be a new directory: $OutputDirectory"
}
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output | Out-Null

function Copy-KitTree {
    param([string]$Source, [string]$Destination)

    $sourceRoot = (Resolve-Path -LiteralPath $Source).Path
    foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force -File) {
        $relative = [IO.Path]::GetRelativePath($sourceRoot, $file.FullName)
        $target = Join-Path $Destination $relative
        if (Test-Path -LiteralPath $target) {
            if ((Get-FileHash -LiteralPath $file.FullName).Hash -ne (Get-FileHash -LiteralPath $target).Hash) {
                throw "Conflicting tester kit file: $relative"
            }
            continue
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target
    }
}

Copy-KitTree $SqlsimRoot $output
Copy-KitTree $SqlpysimRoot $output
Copy-KitTree $StudioRoot (Join-Path $output 'sqlsimstudio')

$sources = @(
    'sqlsim/smoke-test-macos.sh',
    'sqlsim/smoke-test-linux.sh',
    'sqlsim/full-test-suite-linux.sh',
    'sqlsim/testing/macOS/verify-macos-arm64.sh',
    'sqlsim/testing/test-print-statements.sql',
    'sqlsim/testing/replay-test-data.xml',
    'sqlsim/testing/clean-replay.xml',
    'sqlpysim/smoke-test-linux.sh',
    'sqlpysim/full-test-suite-linux.sh',
    'sqlsimstudio/smoke-test.ps1',
    'sqlsimstudio/full-test-suite.ps1'
)
foreach ($relative in $sources) {
    $target = Join-Path $output $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repository $relative) -Destination $target
}
Copy-KitTree (Join-Path $repository 'sqlpysim/tests') (Join-Path $output 'sqlpysim/tests')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'run-macos-tests.ps1') -Destination (Join-Path $output 'run-tests.ps1')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'macos-tester-README.md') -Destination (Join-Path $output 'README.md')
Copy-Item -LiteralPath (Join-Path $repository 'LICENSE') -Destination (Join-Path $output 'LICENSE')

Write-Host "Self-contained macOS tester kit staged: $output"
