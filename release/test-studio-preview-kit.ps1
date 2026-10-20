#!/usr/bin/env pwsh

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$KitRoot,
    [Parameter(Mandatory)][string]$ValidationDirectory
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $KitRoot).Path
if (Test-Path -LiteralPath $ValidationDirectory) { throw 'ValidationDirectory must be new.' }
New-Item -ItemType Directory -Path $ValidationDirectory -Force | Out-Null
$receipt = Get-Content -LiteralPath (Join-Path $root 'BUILD-INFO.json') -Raw | ConvertFrom-Json
if ($receipt.releaseStage -ne 'Private Preview' -or $receipt.runtime -notin 'win-arm64', 'linux-x64' -or
    $receipt.commit -notmatch '^[a-f0-9]{40}$' -or -not $receipt.buildUrl) { throw 'Invalid Private Preview receipt.' }
$extension = if ($receipt.runtime -eq 'win-arm64') { '.exe' } else { '' }
foreach ($relative in @('README.md', 'LICENSE', 'run-tests.ps1', 'sqlsim/testing/replay-test-data.xml',
    'sqlsimstudio/LICENSE', 'sqlsimstudio/THIRD-PARTY-NOTICES.md', 'sqlsimstudio/sqlsimstudio.md',
    'sqlsimstudio/sqlsimstudio.html', 'sqlsimstudio/CONFIGURATION.md', 'sqlsimstudio/examples/README.md',
    'sqlsimstudio/.github/skills/sqlsimstudio/SKILL.md', 'sqlsimstudio/sqlpysim/sqlpysim.py',
    'sqlsimstudio/sqlpysim/requirements.txt', 'sqlsimstudio/smoke-test.ps1', 'sqlsimstudio/full-test-suite.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $relative))) { throw "Kit is missing $relative" }
}
foreach ($relative in @("sqlsimstudio/sqlsimstudio$extension", "sqlsimstudio/sqlsim/sqlsim$extension")) {
    $path = Join-Path $root $relative
    if ($receipt.runtime -eq 'win-arm64') {
        $stream = [IO.File]::OpenRead($path)
        try {
            $pe = [Reflection.PortableExecutable.PEReader]::new($stream)
            try {
                if ($pe.PEHeaders.CoffHeader.Machine.ToString() -ne 'Arm64') { throw "$relative is not ARM64." }
            } finally { $pe.Dispose() }
        } finally { $stream.Dispose() }
    } else {
        $header = & file $path | Out-String
        if ($LASTEXITCODE -ne 0 -or $header -notmatch 'ELF 64-bit.*x86-64') { throw "$relative is not Linux x64: $header" }
    }
}
$pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$runner = Join-Path $root 'run-tests.ps1'
$dummy = Join-Path $ValidationDirectory 'synthetic-token.txt'
$empty = Join-Path $ValidationDirectory 'empty-token.txt'
Set-Content -LiteralPath $dummy -Value 'synthetic-noncredential'
Set-Content -LiteralPath $empty -Value '' -NoNewline

function Assert-Rejected {
    param([string]$Name, [string[]]$Arguments, [string]$Expected)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $pwsh
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in (@('-NoProfile', '-File', $runner) + $Arguments)) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) {
            $process.Kill($true); $process.WaitForExit()
            throw "$Name did not reject input promptly."
        }
        $text = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -eq 0 -or $text -notmatch $Expected -or $text -match 'Running .+\.\.\.') {
            throw "$Name did not refuse input before running suites: $text"
        }
        Write-Host "PASS: $Name"
    } finally {
        if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
}

Assert-Rejected 'offline cannot become live' @('-Tier', 'Offline', '-Server', 'test.invalid') 'Offline tests do not accept'
Assert-Rejected 'live consent required' @('-Tier', 'Smoke', '-Server', 'test.invalid', '-Database', 'test') 'AllowLiveTests'
Assert-Rejected 'live target required' @('-Tier', 'Smoke', '-AllowLiveTests') 'Server, and Database'
Assert-Rejected 'ambiguous credentials rejected' @('-Tier', 'Smoke', '-Server', 'test.invalid', '-Database', 'test',
    '-AllowLiveTests', '-TokenFile', $dummy, '-PasswordFile', $dummy, '-Username', 'test') 'Choose exactly one'
Assert-Rejected 'SQL username required' @('-Tier', 'Smoke', '-Server', 'test.invalid', '-Database', 'test',
    '-AllowLiveTests', '-PasswordFile', $dummy) 'Choose exactly one'
Assert-Rejected 'empty credential rejected' @('-Tier', 'Smoke', '-Server', 'test.invalid', '-Database', 'test',
    '-AllowLiveTests', '-TokenFile', $empty) 'non-empty first line'
Assert-Rejected 'load consent required' @('-Tier', 'Full', '-Server', 'test.invalid', '-Database', 'test',
    '-AllowLiveTests', '-TokenFile', $dummy) 'Full suites require AllowLoadTests'

$failedReports = Join-Path $ValidationDirectory 'expected-failure-results'
& $pwsh -NoProfile -File $runner -Tier Offline -Python 'missing-preview-python-executable' -ReportDirectory $failedReports
if ($LASTEXITCODE -eq 0) { throw 'A missing Python executable was reported as success.' }
$failed = Get-Content -LiteralPath (Join-Path $failedReports 'results.json') -Raw | ConvertFrom-Json
if ($failed.status -ne 'failed' -or -not $failed.error) { throw 'A failed prerequisite did not produce a failure report.' }
$reports = Join-Path $ValidationDirectory 'offline-results'
& $pwsh -NoProfile -File $runner -Tier Offline -ReportDirectory $reports
if ($LASTEXITCODE -ne 0) { throw 'Extracted Studio tester kit offline tests failed.' }
$report = Get-Content -LiteralPath (Join-Path $reports 'results.json') -Raw | ConvertFrom-Json
$expected = @('python-prerequisites', 'sqlsim-help', 'sqlsim-version', 'sqlpysim-help', 'sqlpysim-version',
    'studio-startup', 'studio-offline-full')
if ($report.status -ne 'passed' -or $report.tier -ne 'Offline' -or $report.build.commit -ne $receipt.commit -or
    $report.checks.Count -ne $expected.Count -or
    @($report.checks | Where-Object { $_.status -ne 'passed' -or $_.exitCode -ne 0 -or $_.timedOut }).Count -ne 0 -or
    @(Compare-Object ($expected | Sort-Object) ($report.checks.name | Sort-Object)).Count -ne 0) {
    throw 'Offline report must contain exactly the seven required passing checks.'
}
foreach ($check in $report.checks) {
    foreach ($log in @($check.stdout, $check.stderr)) {
        if (-not (Test-Path -LiteralPath (Join-Path $reports $log))) { throw "Missing check log: $log" }
    }
}
Write-Host 'Extracted Studio Private Preview kit validation passed.'
