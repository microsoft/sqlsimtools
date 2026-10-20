#!/usr/bin/env pwsh

[CmdletBinding()]
param(
    [ValidateSet('Offline', 'Smoke', 'Full')][string]$Tier = 'Offline',
    [string]$Python = 'python',
    [string]$Server,
    [string]$Database,
    [string]$Username,
    [string]$PasswordFile,
    [string]$TokenFile,
    [string]$ReportDirectory,
    [switch]$AllowLiveTests,
    [switch]$AllowLoadTests
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$receipt = Get-Content -LiteralPath (Join-Path $root 'BUILD-INFO.json') -Raw | ConvertFrom-Json
$architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture
if (($receipt.runtime -eq 'win-arm64' -and (-not $IsWindows -or $architecture -ne 'Arm64')) -or
    ($receipt.runtime -eq 'linux-x64' -and (-not $IsLinux -or $architecture -ne 'X64')) -or
    $receipt.runtime -notin 'win-arm64', 'linux-x64') {
    throw "This kit requires its native target platform: $($receipt.runtime)."
}
if ($Tier -eq 'Offline') {
    if ($Server -or $Database -or $Username -or $PasswordFile -or $TokenFile -or $AllowLiveTests -or $AllowLoadTests) {
        throw 'Offline tests do not accept live target, credential, or load-testing options.'
    }
} else {
    if (-not $AllowLiveTests -or -not $Server -or -not $Database) {
        throw 'Live tests require AllowLiveTests, Server, and Database. Use a dedicated test database.'
    }
    if ([bool]$TokenFile -eq [bool]$PasswordFile -or ($PasswordFile -and -not $Username) -or ($TokenFile -and $Username)) {
        throw 'Choose exactly one: TokenFile, or Username with PasswordFile.'
    }
    $secretPath = (Resolve-Path -LiteralPath $(if ($TokenFile) { $TokenFile } else { $PasswordFile })).Path
    if (-not (Get-Content -LiteralPath $secretPath -TotalCount 1)) {
        throw 'The credential file must contain a non-empty first line.'
    }
    if ($Tier -eq 'Full' -and -not $AllowLoadTests) {
        throw 'Full suites require AllowLoadTests as well as AllowLiveTests; they generate substantial load and create test objects.'
    }
}
if (-not $ReportDirectory) {
    $ReportDirectory = Join-Path $root ('results/{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N'))
}
$reports = [IO.Path]::GetFullPath($ReportDirectory)
if (Test-Path -LiteralPath $reports) { throw 'ReportDirectory must be a new directory.' }
New-Item -ItemType Directory -Path $reports -Force | Out-Null
$started = [DateTime]::UtcNow
$checks = [Collections.Generic.List[object]]::new()
$failure = $null
$studio = Join-Path $root 'sqlsimstudio'

function Invoke-PreviewCheck {
    param([string]$Name, [string]$Executable, [string[]]$Arguments)

    Write-Host "Running $Name..."
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.WorkingDirectory = $studio
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    foreach ($variable in @('SQLSIM_SERVER', 'SQLSIM_DATABASE', 'SQLSIM_USERNAME', 'SQLSIM_PASSWORD', 'SQLSIM_ACCESS_TOKEN',
        'SQLSIM_STUDIO_SQLSIM_PATH', 'SQLSIM_STUDIO_PYTHON_PATH')) {
        $null = $start.Environment.Remove($variable)
    }
    $start.Environment['SQLSIM_STUDIO_PYTHON_PATH'] = $pythonPath
    $stdout = [IO.FileStream]::new((Join-Path $reports "$Name.stdout.log"), [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read, 1)
    $stderr = [IO.FileStream]::new((Join-Path $reports "$Name.stderr.log"), [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read, 1)
    $process = $null
    try {
        $process = [Diagnostics.Process]::Start($start)
        $outTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
        $errTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
        $timedOut = $false
        if ($Tier -eq 'Offline') {
            $timedOut = -not $process.WaitForExit(300000)
            if ($timedOut -and -not $process.HasExited) { $process.Kill($true) }
        }
        $process.WaitForExit()
        $outTask.GetAwaiter().GetResult()
        $errTask.GetAwaiter().GetResult()
        $checks.Add([pscustomobject]@{
            name = $Name
            status = if ($process.ExitCode -eq 0 -and -not $timedOut) { 'passed' } else { 'failed' }
            exitCode = $process.ExitCode
            timedOut = $timedOut
            stdout = "$Name.stdout.log"
            stderr = "$Name.stderr.log"
        })
        if ($timedOut) { throw "$Name exceeded the five-minute offline check limit. See $reports" }
        if ($process.ExitCode -ne 0) { throw "$Name failed with exit code $($process.ExitCode). See $reports" }
        Write-Host "PASS: $Name"
    } finally {
        if ($process) {
            if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
            $process.Dispose()
        }
        $stdout.Dispose()
        $stderr.Dispose()
    }
}

try {
    $pythonPath = (Get-Command $Python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $extension = if ($IsWindows) { '.exe' } else { '' }
    $executable = Join-Path $studio "sqlsimstudio$extension"
    $pythonPlatform = if ($IsWindows) { 'win-arm64' } else { 'linux-x86_64' }
    Invoke-PreviewCheck 'python-prerequisites' $pythonPath @('-c',
        "import sys, sysconfig; assert sys.version_info >= (3, 11), 'Python 3.11+ required'; assert sysconfig.get_platform() == '$pythonPlatform', 'Native target Python required'; import mssql_python")
    if ($Tier -eq 'Offline') {
        Invoke-PreviewCheck 'sqlsim-help' (Join-Path $studio "sqlsim/sqlsim$extension") @('--help')
        Invoke-PreviewCheck 'sqlsim-version' (Join-Path $studio "sqlsim/sqlsim$extension") @('--version')
        Invoke-PreviewCheck 'sqlpysim-help' $pythonPath @('sqlpysim/sqlpysim.py', '--help')
        Invoke-PreviewCheck 'sqlpysim-version' $pythonPath @('sqlpysim/sqlpysim.py', '--version')
    }
    $arguments = @('-NoProfile', '-File', (Join-Path $studio 'smoke-test.ps1'), '-SkipBuild', '-StudioExecutable', $executable)
    if ($Tier -eq 'Offline') {
        Invoke-PreviewCheck 'studio-startup' $pwsh ($arguments + '-StartupOnly')
        Invoke-PreviewCheck 'studio-offline-full' $pwsh @('-NoProfile', '-File', (Join-Path $studio 'full-test-suite.ps1'),
            '-SkipBuild', '-StudioExecutable', $executable, '-OfflineOnly')
    } else {
        $auth = @('-Server', $Server, '-Database', $Database, '-SecretFile', $secretPath)
        if ($TokenFile) { $auth += @('-Authentication', 'token') }
        else { $auth += @('-Authentication', 'sql', '-Username', $Username) }
        Invoke-PreviewCheck 'studio-smoke' $pwsh ($arguments + $auth)
        if ($Tier -eq 'Full') {
            Invoke-PreviewCheck 'studio-full' $pwsh (@('-NoProfile', '-File', (Join-Path $studio 'full-test-suite.ps1'),
                '-SkipBuild', '-StudioExecutable', $executable) + $auth)
        }
    }
} catch {
    $failure = $_
    Write-Warning $_.Exception.Message
} finally {
    [ordered]@{
        schemaVersion = 1
        tier = $Tier
        build = $receipt
        startedUtc = $started.ToString('o')
        completedUtc = [DateTime]::UtcNow.ToString('o')
        os = [Runtime.InteropServices.RuntimeInformation]::OSDescription
        architecture = $architecture.ToString()
        status = if ($failure) { 'failed' } else { 'passed' }
        error = if ($failure) { $failure.Exception.Message } else { $null }
        checks = @($checks.ToArray())
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $reports 'results.json') -Encoding utf8
    Write-Host "Report: $reports"
    Write-Host 'Review logs for sensitive data before sharing. No results are uploaded automatically.'
}
if ($failure) { throw $failure }
