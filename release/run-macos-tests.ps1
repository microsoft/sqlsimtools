#!/usr/bin/env pwsh

[CmdletBinding()]
param(
    [ValidateSet('sqlsim', 'sqlpysim', 'sqlsimstudio')]
    [string[]]$Tool = @('sqlsim', 'sqlpysim', 'sqlsimstudio'),
    [ValidateSet('Offline', 'Smoke', 'Full')]
    [string]$Tier = 'Offline',
    [string]$Server,
    [string]$Database,
    [string]$Username,
    [string]$PasswordFile,
    [string]$TokenFile,
    [string]$Python = 'python3',
    [string]$ReportDirectory,
    [switch]$AllowLiveTests,
    [switch]$AllowLoadTests,
    [switch]$IncludeScale
)

$ErrorActionPreference = 'Stop'
if (-not $IsMacOS -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'Arm64') {
    throw 'This tester kit requires macOS on Apple Silicon.'
}
if ($Tool.Count -eq 0) { throw 'Select at least one tool.' }
if ($Tier -eq 'Offline') {
    if ($Server -or $Database -or $Username -or $PasswordFile -or $TokenFile -or $AllowLiveTests -or $AllowLoadTests -or $IncludeScale) {
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
if ($IncludeScale -and ($Tier -ne 'Full' -or $Tool -notcontains 'sqlsim')) {
    throw 'IncludeScale applies only to the sqlsim Full suite.'
}

$root = $PSScriptRoot
$bash = (Get-Command bash -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$pythonPath = $null
if ($Tool -contains 'sqlpysim' -or $Tool -contains 'sqlsimstudio') {
    $pythonPath = (Get-Command $Python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
}
if (-not $ReportDirectory) {
    $ReportDirectory = Join-Path $root ('results/{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N'))
}
$reportRoot = [IO.Path]::GetFullPath($ReportDirectory)
if (Test-Path -LiteralPath $reportRoot) { throw "ReportDirectory must be a new directory: $reportRoot" }
New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null
$results = [Collections.Generic.List[object]]::new()
$started = [DateTime]::UtcNow
$failure = $null

function Invoke-KitCheck {
    param([string]$Name, [string]$Executable, [string[]]$Arguments, [string]$WorkingDirectory)

    Write-Host "Running $Name..."
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    foreach ($variable in @('SQLSIM_SERVER', 'SQLSIM_DATABASE', 'SQLSIM_USERNAME', 'SQLSIM_PASSWORD', 'SQLSIM_ACCESS_TOKEN',
        'SQLSIM_STUDIO_SQLSIM_PATH', 'SQLSIM_STUDIO_PYTHON_PATH')) {
        $start.Environment.Remove($variable) | Out-Null
    }
    if ($pythonPath) { $start.Environment['SQLSIM_STUDIO_PYTHON_PATH'] = $pythonPath }
    $stdoutPath = Join-Path $reportRoot "$Name.stdout.log"
    $stderrPath = Join-Path $reportRoot "$Name.stderr.log"
    $stdout = [IO.File]::Create($stdoutPath)
    $stderr = [IO.File]::Create($stderrPath)
    $process = $null
    try {
        $process = [Diagnostics.Process]::Start($start)
        $outTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
        $errTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
        $process.WaitForExit()
        $outTask.GetAwaiter().GetResult()
        $errTask.GetAwaiter().GetResult()
        $results.Add([pscustomobject]@{
            name = $Name
            status = if ($process.ExitCode -eq 0) { 'passed' } else { 'failed' }
            exitCode = $process.ExitCode
            stdout = [IO.Path]::GetFileName($stdoutPath)
            stderr = [IO.Path]::GetFileName($stderrPath)
        })
        if ($process.ExitCode -ne 0) {
            throw "$Name failed with exit code $($process.ExitCode). See $stdoutPath and $stderrPath"
        }
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
    if ($pythonPath) {
        Invoke-KitCheck 'python-prerequisites' $pythonPath @('-c', 'import sys; assert sys.version_info >= (3, 11), "Python 3.11+ required"; import mssql_python') $root
    }
    $auth = @()
    if ($Tier -ne 'Offline') {
        $auth = @('--server', $Server, '--database', $Database)
        if ($TokenFile) { $auth += @('--token-file', $secretPath) }
        else { $auth += @('--username', $Username, '--password-file', $secretPath) }
    }
    if ($Tool -contains 'sqlsim') {
        $directory = Join-Path $root 'sqlsim'
        $binary = Join-Path $directory 'arm64/sqlsim'
        if ($Tier -eq 'Offline') {
            Invoke-KitCheck 'sqlsim-offline' $bash @('smoke-test-macos.sh', '--skip-build', '--sqlsim', $binary) $directory
        } elseif ($Tier -eq 'Smoke') {
            Invoke-KitCheck 'sqlsim-smoke' $bash (@('smoke-test-linux.sh', '--skip-build', '--sqlsim', $binary) + $auth) $directory
        } else {
            $arguments = @('full-test-suite-linux.sh', '--sqlsim', $binary) + $auth
            if (-not $IncludeScale) { $arguments += '--skip-scale' }
            Invoke-KitCheck 'sqlsim-full' $bash $arguments $directory
        }
    }
    if ($Tool -contains 'sqlpysim') {
        $directory = Join-Path $root 'sqlpysim'
        if ($Tier -eq 'Offline') {
            Invoke-KitCheck 'sqlpysim-help' $pythonPath @('sqlpysim.py', '--help') $directory
            Invoke-KitCheck 'sqlpysim-version' $pythonPath @('sqlpysim.py', '--version') $directory
            Invoke-KitCheck 'sqlpysim-unit-tests' $pythonPath @('-m', 'unittest', 'discover', '-s', 'tests', '-p', 'test_*.py', '-v') $directory
        } else {
            $suite = if ($Tier -eq 'Smoke') { 'smoke-test-linux.sh' } else { 'full-test-suite-linux.sh' }
            Invoke-KitCheck "sqlpysim-$($Tier.ToLowerInvariant())" $bash (@($suite, '--python', $pythonPath) + $auth) $directory
        }
    }
    if ($Tool -contains 'sqlsimstudio') {
        $directory = Join-Path $root 'sqlsimstudio'
        $executable = Join-Path $directory 'sqlsimstudio'
        $arguments = @('-NoProfile', '-File', (Join-Path $directory 'smoke-test.ps1'),
            '-SkipBuild', '-StudioExecutable', $executable)
        if ($Tier -eq 'Offline') {
            Invoke-KitCheck 'studio-startup' $pwsh ($arguments + '-StartupOnly') $directory
            Invoke-KitCheck 'studio-offline-full' $pwsh @('-NoProfile', '-File', (Join-Path $directory 'full-test-suite.ps1'),
                '-SkipBuild', '-StudioExecutable', $executable, '-OfflineOnly') $directory
        } else {
            $studioAuth = @('-Server', $Server, '-Database', $Database, '-SecretFile', $secretPath)
            if ($TokenFile) { $studioAuth += @('-Authentication', 'token') }
            else { $studioAuth += @('-Authentication', 'sql', '-Username', $Username) }
            Invoke-KitCheck 'studio-smoke' $pwsh ($arguments + $studioAuth) $directory
            if ($Tier -eq 'Full') {
                Invoke-KitCheck 'studio-full' $pwsh (@('-NoProfile', '-File', (Join-Path $directory 'full-test-suite.ps1'),
                    '-SkipBuild', '-StudioExecutable', $executable) + $studioAuth) $directory
            }
        }
    }
} catch {
    $failure = $_
    Write-Warning $_.Exception.Message
} finally {
    $report = [ordered]@{
        schemaVersion = 1
        tier = $Tier
        tools = $Tool
        startedUtc = $started.ToString('o')
        completedUtc = [DateTime]::UtcNow.ToString('o')
        os = [Runtime.InteropServices.RuntimeInformation]::OSDescription
        architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        build = @(Get-Content -LiteralPath (Join-Path $root 'BUILD-INFO.txt'))
        status = if ($failure) { 'failed' } else { 'passed' }
        error = if ($failure) { $failure.Exception.Message } else { $null }
        checks = @($results.ToArray())
    }
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $reportRoot 'results.json') -Encoding utf8
    Write-Host "Report: $reportRoot"
    Write-Host 'Review logs for sensitive data before sharing. No results are uploaded automatically.'
}
if ($failure) { throw $failure }
