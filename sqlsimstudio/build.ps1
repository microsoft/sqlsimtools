#!/usr/bin/env pwsh

param(
    [ValidateSet('win-x64', 'win-arm64', 'linux-x64', 'linux-arm64', 'osx-arm64')]
    [string]$Runtime = 'win-x64',
    [switch]$FrameworkDependent
)

$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot 'server\SqlsimStudio.csproj'
$output = Join-Path $PSScriptRoot "build\$Runtime"

if (Test-Path -LiteralPath $output) {
    Remove-Item -LiteralPath $output -Recurse -Force
}

$arguments = @(
    'publish', $project,
    '-c', 'Release',
    '-r', $Runtime,
    '--self-contained', (-not $FrameworkDependent).ToString().ToLowerInvariant(),
    '-p:PublishSingleFile=true',
    '-p:DebugType=None',
    '-o', $output
)

& dotnet @arguments
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$iisModule = Join-Path $output 'aspnetcorev2_inprocess.dll'
if (Test-Path -LiteralPath $iisModule) {
    Remove-Item -LiteralPath $iisModule -Force
}

$sqlsimSource = switch ($Runtime) {
    'win-x64' { Join-Path $PSScriptRoot '..\sqlsim\build\x64\Release\sqlsim.exe' }
    'win-arm64' { Join-Path $PSScriptRoot '..\sqlsim\build\ARM64\Release\sqlsim.exe' }
    'linux-x64' { Join-Path $PSScriptRoot '..\sqlsim\build\linux-x64\sqlsim' }
    'linux-arm64' { Join-Path $PSScriptRoot '..\sqlsim\build\linux-arm64\sqlsim' }
    'osx-arm64' { Join-Path $PSScriptRoot '..\sqlsim\build\macos-arm64\sqlsim' }
}
if (-not (Test-Path -LiteralPath $sqlsimSource)) {
    throw "Matching sqlsim binary not found: $sqlsimSource"
}
$sqlsimDirectory = Join-Path $output 'sqlsim'
New-Item -ItemType Directory -Path $sqlsimDirectory -Force | Out-Null
Copy-Item -LiteralPath $sqlsimSource -Destination (Join-Path $sqlsimDirectory (Split-Path $sqlsimSource -Leaf)) -Force

$sqlpysimDirectory = Join-Path $output 'sqlpysim'
New-Item -ItemType Directory -Path $sqlpysimDirectory -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\sqlpysim\sqlpysim.py') -Destination $sqlpysimDirectory -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\sqlpysim\requirements.txt') -Destination $sqlpysimDirectory -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'THIRD-PARTY-NOTICES.md') -Destination $output -Force
$manualSource = Join-Path $PSScriptRoot 'sqlsimstudio.md'
Copy-Item -LiteralPath $manualSource -Destination $output -Force
$pandoc = Get-Command pandoc -ErrorAction SilentlyContinue
if ($pandoc) {
    $manualHtml = Join-Path $output 'sqlsimstudio.html'
    $manualCss = Join-Path $PSScriptRoot 'manual.css'
    & $pandoc.Source $manualSource -o $manualHtml `
        --standalone `
        --from=gfm `
        --css="$manualCss" `
        --resource-path="$PSScriptRoot" `
        --embed-resources `
        --metadata 'pagetitle=sqlsim Studio User Manual'
    if ($LASTEXITCODE -ne 0) {
        throw "pandoc failed with exit code $LASTEXITCODE"
    }
    Write-Host "sqlsim Studio HTML manual generated: $manualHtml" -ForegroundColor Green
} else {
    Write-Warning 'pandoc was not found; sqlsimstudio.html was not generated.'
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'CONFIGURATION.md') -Destination $output -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'examples') -Destination $output -Recurse -Force
$studioSkillDirectory = Join-Path $output '.github\skills\sqlsimstudio'
New-Item -ItemType Directory -Path $studioSkillDirectory -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\.github\skills\sqlsimstudio\SKILL.md') -Destination $studioSkillDirectory -Force
# Studio has no window and no usable Ctrl+C, so a user who kills the process
# instead of shutting it down leaves the engine running against their database.
# The script that collects that has to be in the package, not just the repo.
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'sqlsimstudio-cleanup.ps1') -Destination $output -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\LICENSE') -Destination $output -Force

Write-Host "sqlsim Studio published: $output" -ForegroundColor Green

# Callers read $LASTEXITCODE; without this it can still hold an earlier native tool's code.
exit 0
