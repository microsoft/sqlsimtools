#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Master local-publish orchestrator for sqlsimtools.

.DESCRIPTION
    Runs each tool's own publish.ps1 in sequence. Per-tool publish scripts
    stage both tools into one canonical project-root installation tree.

    The authoritative release pipeline is .github/workflows/release.yml.
    Pushing a `v*.*.*` tag creates a draft GitHub Release; workflow_dispatch
    builds RC validation artifacts only. This script exists so you can produce
    equivalent local builds for ad-hoc distribution without going through CI.

    Each tool publishes its own asset. The sqlsimtools bundle (Studio plus the sqlsim x64 and sqlpysim packages) is assembled by release/build-sqlsimtools-bundle.ps1.

.PARAMETER PublishAll
    Run all tool publish scripts. (Kept as an explicit switch for
    parity with the previous interface; without it, this script does
    nothing useful.)

.PARAMETER SkipBuild
    Forwarded to each tool's publish.ps1 — skip native rebuild and
    reuse existing binaries.

.EXAMPLE
    .\publish.ps1 -PublishAll

.EXAMPLE
    .\publish.ps1 -PublishAll -SkipBuild
#>

param(
    [switch]$PublishAll,
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"

if (-not $PublishAll) {
    Write-Host "Nothing to do. Use -PublishAll to run every tool's publish.ps1." -ForegroundColor Yellow
    Write-Host "Or run a tool's publish.ps1 directly (e.g. ..\sqlsim\publish.ps1)." -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Magenta
Write-Host "PUBLISHING ALL TOOLS" -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta

$tools = @('sqlsim', 'sqlpysim')

foreach ($tool in $tools) {
    $publishScript = Join-Path $PSScriptRoot "..\$tool\publish.ps1"
    if (-not (Test-Path $publishScript)) {
        Write-Host "WARNING: $tool publish.ps1 not found at $publishScript" -ForegroundColor Yellow
        continue
    }

    Write-Host ""
    Write-Host "Running $tool publish..." -ForegroundColor Yellow
    if ($SkipBuild -and $tool -eq 'sqlsim') {
        & $publishScript -SkipBuild
    } else {
        & $publishScript
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: $tool publish failed" -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "PUBLISH COMPLETE" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Tools are staged under release\sqlsimtools\1.0 with skills at project-root paths." -ForegroundColor Gray
Write-Host "For the authoritative release pipeline, push a v*.*.* tag." -ForegroundColor Gray

# Callers read $LASTEXITCODE; without this it can still hold an earlier native tool's code.
exit 0
