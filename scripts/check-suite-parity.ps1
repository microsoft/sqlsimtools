#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Verify the PowerShell and bash test suites cover the same tests.

.DESCRIPTION
    The repository ships separate PowerShell and bash suites so Linux users never
    need PowerShell. Two implementations drift, so this compares each pair's test
    inventory and fails when they diverge.

    The bash suite reports its inventory via --list-tests. The PowerShell suite is
    parsed for its test names.

.EXAMPLE
    ./scripts/check-suite-parity.ps1
#>

param(
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

# Dynamic suffixes, e.g. "Authentication (SQL Authentication)", are compared on the stem.
function Get-TestStem {
    param([string]$Name)
    ($Name -replace '\s*\(.*$', '').Trim()
}

function Get-BashInventory {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    # Read the declared TEST_NAMES array directly; invoking bash would need a
    # shell that understands the host's path format.
    $text = Get-Content $Path -Raw
    $match = [regex]::Match($text, '(?ms)^TEST_NAMES=\((.*?)^\)')
    if (-not $match.Success) { return @() }
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($match.Groups[1].Value, '"([^"]+)"')) {
        $names.Add($m.Groups[1].Value)
    }
    return @($names)
}

function Get-PowerShellInventory {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $text = Get-Content $Path -Raw
    # Drop commented-out lines; the suites keep disabled tests in comments.
    $text = ($text -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($pattern in @(
        '-TestName\s+"([^"]+)"',
        '-Name\s+"([^"]+)"',
        'Testing:\s+([^"]+?)"',
        # sqlsim's smoke suite announces some tests as: Write-Host "Test 35: Name"
        'Write-Host\s+"Test\s+\d+:\s*([^"]+?)"'
    )) {
        foreach ($m in [regex]::Matches($text, $pattern)) {
            $value = $m.Groups[1].Value.Trim()
            # Skip interpolated placeholders such as "Testing: $TestName".
            if ($value -match '^\$') { continue }
            if ($value -and -not $names.Contains($value)) { $names.Add($value) }
        }
    }
    return @($names)
}

$pairs = @(
    @{ Tool = 'sqlpysim'; Ps1 = 'sqlpysim/smoke-test.ps1';      Sh = 'sqlpysim/smoke-test-linux.sh' }
    @{ Tool = 'sqlpysim'; Ps1 = 'sqlpysim/full-test-suite.ps1'; Sh = 'sqlpysim/full-test-suite-linux.sh' }
    @{ Tool = 'sqlsim';   Ps1 = 'sqlsim/smoke-test.ps1';        Sh = 'sqlsim/smoke-test-linux.sh' }
    @{ Tool = 'sqlsim';   Ps1 = 'sqlsim/full-test-suite.ps1';   Sh = 'sqlsim/full-test-suite-linux.sh' }
)

$exitCode = 0

foreach ($pair in $pairs) {
    $ps1Path = Join-Path $repoRoot $pair.Ps1
    $shPath = Join-Path $repoRoot $pair.Sh

    if (-not (Test-Path $shPath)) {
        if (-not $Quiet) {
            Write-Host ("SKIP  {0} -> no bash port yet" -f $pair.Sh) -ForegroundColor DarkGray
        }
        continue
    }

    $psNames = Get-PowerShellInventory -Path $ps1Path
    $shNames = Get-BashInventory -Path $shPath
    if ($null -eq $psNames) {
        Write-Host ("FAIL  {0} missing" -f $pair.Ps1) -ForegroundColor Red
        $exitCode = 1
        continue
    }
    if ($shNames.Count -eq 0) {
        Write-Host ("TODO  {0} has no TEST_NAMES inventory yet" -f $pair.Sh) -ForegroundColor DarkYellow
        continue
    }

    $psStems = @($psNames | ForEach-Object { Get-TestStem $_ } | Sort-Object -Unique)
    $shStems = @($shNames | ForEach-Object { Get-TestStem $_ } | Sort-Object -Unique)

    $onlyPs = @($psStems | Where-Object { $shStems -notcontains $_ })
    $onlySh = @($shStems | Where-Object { $psStems -notcontains $_ })

    # Bash suites may add platform-specific tests (signals, Kerberos rejection)
    # that Windows cannot run. Missing coverage is a failure; extras are not.
    if ($onlyPs.Count -eq 0) {
        $suffix = if ($onlySh.Count -gt 0) { " (+{0} Linux-only)" -f $onlySh.Count } else { "" }
        Write-Host ("OK    {0} <-> {1}  ({2} shared tests){3}" -f $pair.Ps1, $pair.Sh, $psStems.Count, $suffix) -ForegroundColor Green
        if (-not $Quiet) {
            foreach ($n in $onlySh) { Write-Host ("        Linux-only: {0}" -f $n) -ForegroundColor DarkGray }
        }
        continue
    }

    Write-Host ("DRIFT {0} <-> {1}" -f $pair.Ps1, $pair.Sh) -ForegroundColor Red
    foreach ($n in $onlyPs) { Write-Host ("        missing from bash: {0}" -f $n) -ForegroundColor Yellow }
    $exitCode = 1
}

exit $exitCode
