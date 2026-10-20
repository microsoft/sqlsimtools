#!/usr/bin/env pwsh

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$KitRoot,
    [Parameter(Mandatory)][string]$ValidationDirectory
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $KitRoot).Path
if (Test-Path -LiteralPath $ValidationDirectory) { throw 'ValidationDirectory must be a new directory.' }
New-Item -ItemType Directory -Path $ValidationDirectory -Force | Out-Null
$runner = Join-Path $root 'run-tests.ps1'
$pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$bash = (Get-Command bash -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$dummySecret = Join-Path $ValidationDirectory 'synthetic-token.txt'
$emptySecret = Join-Path $ValidationDirectory 'empty-token.txt'
Set-Content -LiteralPath $dummySecret -Value 'synthetic-noncredential'
Set-Content -LiteralPath $emptySecret -Value '' -NoNewline

function Assert-Rejected {
    param([string]$Name, [string[]]$Arguments, [string]$Expected)

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $pwsh
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in (@('-NoProfile', '-File', $runner) + $Arguments)) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "$Name did not reject input promptly."
        }
        $text = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -eq 0 -or $text -notmatch $Expected -or $text -match 'Running .+\.\.\.') {
            throw "$Name did not reject input before running suites: $text"
        }
        Write-Host "PASS: $Name"
    } finally {
        if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
}

Assert-Rejected 'live consent required' @('-Tier', 'Smoke', '-Server', 'test.invalid', '-Database', 'test') 'AllowLiveTests'
Assert-Rejected 'explicit live target required' @('-Tier', 'Smoke', '-AllowLiveTests') 'Server, and Database'
Assert-Rejected 'offline cannot become live' @('-Tier', 'Offline', '-Server', 'test.invalid') 'Offline tests do not accept'
Assert-Rejected 'ambiguous credentials rejected' @('-Tier', 'Smoke', '-AllowLiveTests', '-Server', 'test.invalid',
    '-Database', 'test', '-Username', 'test', '-PasswordFile', $dummySecret, '-TokenFile', $dummySecret) 'Choose exactly one'
Assert-Rejected 'SQL username required' @('-Tier', 'Smoke', '-AllowLiveTests', '-Server', 'test.invalid',
    '-Database', 'test', '-PasswordFile', $dummySecret) 'Choose exactly one'
Assert-Rejected 'empty credential rejected' @('-Tier', 'Smoke', '-AllowLiveTests', '-Server', 'test.invalid',
    '-Database', 'test', '-TokenFile', $emptySecret) 'non-empty first line'
Assert-Rejected 'full load consent required' @('-Tier', 'Full', '-AllowLiveTests', '-Server', 'test.invalid',
    '-Database', 'test', '-TokenFile', $dummySecret) 'Full suites require AllowLoadTests'
Assert-Rejected 'scale cannot bypass full tier' @('-Tier', 'Smoke', '-AllowLiveTests', '-Server', 'test.invalid',
    '-Database', 'test', '-TokenFile', $dummySecret, '-IncludeScale') 'IncludeScale applies only'

$failureReports = Join-Path $ValidationDirectory 'expected-failure-results'
$falseExecutable = (Get-Command false -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
& $pwsh -NoProfile -File $runner -Tier Offline -Tool sqlpysim -Python $falseExecutable -ReportDirectory $failureReports
if ($LASTEXITCODE -eq 0) { throw 'A failed prerequisite was reported as success.' }
$failureReport = Get-Content -LiteralPath (Join-Path $failureReports 'results.json') -Raw | ConvertFrom-Json
if ($failureReport.status -ne 'failed' -or -not $failureReport.error -or $failureReport.checks.Count -ne 1 -or
    $failureReport.checks[0].name -ne 'python-prerequisites' -or $failureReport.checks[0].exitCode -eq 0) {
    throw 'A failed check did not produce the required failure report.'
}
Write-Host 'PASS: failed prerequisites produce a nonzero exit and a JSON failure report'

foreach ($relative in @('sqlsim/smoke-test-macos.sh', 'sqlsim/smoke-test-linux.sh', 'sqlsim/full-test-suite-linux.sh',
    'sqlpysim/smoke-test-linux.sh', 'sqlpysim/full-test-suite-linux.sh')) {
    $path = Join-Path $root $relative
    & $bash -n $path
    if ($LASTEXITCODE -ne 0) { throw "Shell syntax validation failed: $relative" }
    $help = & $bash $path --help | Out-String
    if ($LASTEXITCODE -ne 0 -or $help -notmatch 'Usage:') { throw "Suite help failed: $relative" }
    if ($relative -notmatch 'smoke-test-macos') {
        $inventory = @(& $bash $path --list-tests)
        if ($LASTEXITCODE -ne 0 -or $inventory.Count -lt 10) { throw "Missing test inventory: $relative" }
        $fileParsing = @(& $bash $path --token-file $dummySecret --list-tests)
        if ($LASTEXITCODE -ne 0 -or $fileParsing.Count -ne $inventory.Count) {
            throw "Credential-file parsing changed the test inventory: $relative"
        }
    }
}

$reports = Join-Path $ValidationDirectory 'offline-results'
& $pwsh -NoProfile -File $runner -Tier Offline -ReportDirectory $reports
if ($LASTEXITCODE -ne 0) { throw 'Extracted tester kit offline run failed.' }
$report = Get-Content -LiteralPath (Join-Path $reports 'results.json') -Raw | ConvertFrom-Json
$expectedChecks = @('python-prerequisites', 'sqlsim-offline', 'sqlpysim-help', 'sqlpysim-version',
    'sqlpysim-unit-tests', 'studio-startup', 'studio-offline-full')
if ($report.status -ne 'passed' -or $report.tier -ne 'Offline' -or
    $report.tools.Count -ne 3 -or $report.checks.Count -ne $expectedChecks.Count -or
    @($report.checks | Where-Object { $_.status -ne 'passed' -or $_.exitCode -ne 0 }).Count -ne 0 -or
    @(Compare-Object ($expectedChecks | Sort-Object) ($report.checks.name | Sort-Object)).Count -ne 0) {
    throw 'Offline report does not contain exactly the seven required passing checks.'
}
foreach ($check in $report.checks) {
    foreach ($log in @($check.stdout, $check.stderr)) {
        if (-not (Test-Path -LiteralPath (Join-Path $reports $log))) { throw "Missing report log: $log" }
    }
}
Write-Host 'Extracted macOS tester kit validation passed.'
