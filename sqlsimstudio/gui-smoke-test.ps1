#!/usr/bin/env pwsh

param(
    [string]$Server = 'localhost',
    [string]$Database = 'tempdb',
    [string]$QueryStoreDatabase,
    [string]$ReplayFile,
    [ValidateSet('msedge', 'chrome')]
    [string]$BrowserChannel = 'msedge',
    [switch]$Headed,
    [switch]$CaptureScreenshots,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$studioRoot = $PSScriptRoot
$studioExecutable = Join-Path $studioRoot 'build\win-x64\SqlSimStudio.exe'
$sqlsimExecutable = Join-Path $studioRoot 'build\win-x64\sqlsim\sqlsim.exe'
$replayFile = $ReplayFile
if (-not $replayFile) {
    $replayFile = Join-Path $studioRoot '..\sqlsim\testing\replay-test-data.xml'
}
$replayFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($replayFile)
$playwright = Join-Path $studioRoot 'node_modules\.bin\playwright.cmd'

Push-Location $studioRoot
try {
    if (-not $SkipBuild) {
        & (Join-Path $studioRoot 'build.ps1') -Runtime win-x64
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    foreach ($requiredPath in @($studioExecutable, $sqlsimExecutable, $replayFile)) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "Required GUI smoke-test input is missing: $requiredPath"
        }
    }

    if (-not (Test-Path -LiteralPath $playwright)) {
        & npm install --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    Write-Host "Preflight: $Server/$Database with integrated authentication" -ForegroundColor Cyan
    & $sqlsimExecutable -S $Server -d $Database -E -Q 'SELECT 1 AS StudioGuiPreflight' -q
    if ($LASTEXITCODE -ne 0) {
        throw "GUI smoke-test database preflight failed for $Server/$Database."
    }

    if ($QueryStoreDatabase) {
        Write-Host "Preflight: Query Store on $Server/$QueryStoreDatabase" -ForegroundColor Cyan
        & $sqlsimExecutable -S $Server -d $QueryStoreDatabase -E -Q "IF NOT EXISTS (SELECT 1 FROM sys.database_query_store_options WHERE actual_state_desc = 'READ_WRITE') THROW 50000, 'Query Store must be READ_WRITE.', 1;" -q
        if ($LASTEXITCODE -ne 0) {
            throw "GUI smoke-test Query Store preflight failed for $Server/$QueryStoreDatabase."
        }
    }

    $env:SQLSIMSTUDIO_EXE = $studioExecutable
    $env:SQLSIMSTUDIO_SERVER = $Server
    $env:SQLSIMSTUDIO_DATABASE = $Database
    $env:SQLSIMSTUDIO_REPLAY_FILE = $replayFile
    $env:SQLSIMSTUDIO_LIVE_REPLAY_EXAMPLE = '1'
    $env:SQLSIMSTUDIO_BROWSER_CHANNEL = $BrowserChannel
    $env:SQLSIMSTUDIO_HEADED = $Headed.IsPresent ? '1' : '0'
    $env:SQLSIMSTUDIO_CAPTURE_SCREENSHOTS = $CaptureScreenshots.IsPresent ? '1' : '0'
    if ($QueryStoreDatabase) {
        $env:SQLSIMSTUDIO_QUERY_STORE_DATABASE = $QueryStoreDatabase
    } else {
        Remove-Item Env:SQLSIMSTUDIO_QUERY_STORE_DATABASE -ErrorAction SilentlyContinue
    }

    & $playwright test --config gui-tests/playwright.config.cjs
    exit $LASTEXITCODE
} finally {
    Pop-Location
}