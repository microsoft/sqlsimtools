#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Builds sqlsim from this checkout and installs sqlsim and sqlpysim into a project.

.DESCRIPTION
    The single supported source-to-project path on Windows. It:
      1. checks build prerequisites (sqlsim) and Python (sqlpysim);
      2. builds sqlsim when -Build is given;
      3. previews every tool's overlay and stops before writing anything if a
         project file would be replaced and -Force was not given;
      4. publishes each tool into the project;
      5. validates the installed overlay offline, without a database;
      6. prints an install receipt.

    Project files are never deleted. Files you added under sqlsim\examples or
    sqlpysim\examples are kept.

.PARAMETER Workspace
    Root of the project to install into. Created if it does not exist.

.PARAMETER Tool
    Tools to install: sqlsim, sqlpysim, or both. Defaults to sqlsim.

.PARAMETER Build
    Build sqlsim before installing. Without it, the existing build is used.

.PARAMETER Clean
    With -Build, delete previous build output first.

.PARAMETER Architecture
    sqlsim architecture: x64 or ARM64. Defaults to this machine's architecture.

.PARAMETER Force
    Replace existing project files that differ from this release.

.PARAMETER Preview
    Show what would be created and replaced, then stop without writing.

.PARAMETER SkipPrerequisites
    Skip the build prerequisite and Python checks.

.EXAMPLE
    .\scripts\install-local.ps1 -Workspace C:\myproject -Build

.EXAMPLE
    .\scripts\install-local.ps1 -Workspace C:\myproject -Tool sqlsim, sqlpysim -Preview
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Workspace,

    [ValidateSet('sqlsim', 'sqlpysim')]
    [string[]]$Tool = @('sqlsim'),

    [switch]$Build,
    [switch]$Clean,

    [ValidateSet('x64', 'ARM64')]
    [string]$Architecture = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'ARM64' } else { 'x64' }),

    [switch]$Force,
    [switch]$Preview,
    [switch]$SkipPrerequisites
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$sqlsimDir = Join-Path $repositoryRoot 'sqlsim'
$validator = Join-Path $repositoryRoot 'release\validate-package-layout.ps1'
$installSqlsim = $Tool -contains 'sqlsim'
$installSqlpysim = $Tool -contains 'sqlpysim'

if (-not $IsWindows) {
    Write-Host 'install-local.ps1 builds the Windows sqlsim binary. On Linux, build with' -ForegroundColor Yellow
    Write-Host '  bash sqlsim/build-linux.sh, then install with bash sqlsim/publish-linux.sh --skip-build --release-dir <project>' -ForegroundColor Yellow
    exit 2
}

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "== $Text" -ForegroundColor Cyan
}

function Stop-Install([string]$Message) {
    Write-Host ''
    Write-Host "INSTALL STOPPED: $Message" -ForegroundColor Red
    exit 1
}

# Publish scripts print their own progress; show it only when something fails.
function Invoke-Publisher {
    param([string]$Name, [hashtable]$Arguments)
    $script = Join-Path $repositoryRoot "$Name\publish.ps1"
    $output = & $script @Arguments *>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

function Get-PublishArguments {
    param([string]$Name, [string]$ReportPath)
    $arguments = @{ ReleaseDir = $workspacePath; ReportPath = $ReportPath }
    if ($Name -eq 'sqlsim') {
        $arguments.SkipBuild = $true
        $arguments.Architecture = $Architecture
    }
    return $arguments
}

$workspacePath = [IO.Path]::GetFullPath($Workspace)
$repositoryPrefix = $repositoryRoot.TrimEnd('\') + '\'
if ($workspacePath.TrimEnd('\') -eq $repositoryRoot.TrimEnd('\') -or $workspacePath.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    Stop-Install "The workspace must be a project outside this repository: $workspacePath"
}
$receiptDirectory = Join-Path ([IO.Path]::GetTempPath()) ("sqlsimtools-install-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $receiptDirectory -Force | Out-Null
$pythonReady = $false

try {
    Write-Host "Installing $($Tool -join ' and ') into $workspacePath" -ForegroundColor Cyan

    # 1. Prerequisites
    if (-not $SkipPrerequisites) {
        if ($installSqlsim -and $Build) {
            Write-Step 'Checking sqlsim build prerequisites'
            & (Join-Path $sqlsimDir 'check-prerequisites.ps1') | Out-Host
            if ($LASTEXITCODE -ne 0) { Stop-Install 'sqlsim build prerequisites are missing. Fix the items above, or install a release archive instead (INSTALL.md).' }
        }
        if ($installSqlpysim) {
            Write-Step 'Checking Python'
            $python = Get-Command python -ErrorAction SilentlyContinue
            if (-not $python) { Stop-Install 'Python 3.10 or later is required for sqlpysim and was not found on PATH.' }
            $pythonVersion = (& python -c "import sys; print('%d.%d' % sys.version_info[:2])" | Out-String).Trim()
            if ([version]$pythonVersion -lt [version]'3.10') { Stop-Install "sqlpysim requires Python 3.10 or later; found $pythonVersion." }
            Write-Host "  Python $pythonVersion" -ForegroundColor Gray
        }
    }
    # Decides the receipt's next step, so it runs even with -SkipPrerequisites.
    if ($installSqlpysim -and (Get-Command python -ErrorAction SilentlyContinue)) {
        & python -c 'import mssql_python' 2>$null
        $pythonReady = $LASTEXITCODE -eq 0
        Write-Host "  mssql-python $(if ($pythonReady) { 'installed' } else { 'not installed yet' })" -ForegroundColor Gray
    }

    # 2. Build
    $sqlsimBinary = Join-Path $sqlsimDir "build\$Architecture\Release\sqlsim.exe"
    if ($installSqlsim) {
        if ($Build -and -not $Preview) {
            Write-Step "Building sqlsim ($Architecture)"
            $buildArguments = @{ Architecture = $Architecture }
            if ($Clean) { $buildArguments.Clean = $true }
            Push-Location $sqlsimDir
            try { & (Join-Path $sqlsimDir 'build.ps1') @buildArguments | Out-Host } finally { Pop-Location }
            if ($LASTEXITCODE -ne 0) { Stop-Install 'The sqlsim build failed. See the build output above.' }
        }
        if (-not (Test-Path -LiteralPath $sqlsimBinary)) {
            Stop-Install "No $Architecture sqlsim build was found at $sqlsimBinary. Re-run with -Build."
        }
    }

    # 3. Preview every tool before writing anything, so a refusal leaves the
    #    project exactly as it was.
    Write-Step 'Checking the project for files that would change'
    $replacements = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $Tool) {
        $previewReport = Join-Path $receiptDirectory "$name-preview.json"
        $arguments = (Get-PublishArguments $name $previewReport) + @{ Preview = $true }
        $result = Invoke-Publisher $name $arguments
        if ($result.ExitCode -ne 0) { Write-Host $result.Output; Stop-Install "$name could not be planned." }
        $report = Get-Content -LiteralPath $previewReport -Raw | ConvertFrom-Json
        Write-Host ("  {0}: {1} to create, {2} to replace, {3} other file(s) kept" -f $name, @($report.wouldCreate).Count, @($report.wouldReplace).Count, @($report.kept).Count)
        foreach ($path in @($report.wouldReplace)) {
            if (-not $replacements.Contains($path)) { $replacements.Add($path) }
        }
    }
    if ($replacements.Count -gt 0) {
        Write-Host '  These project files differ from this release:' -ForegroundColor Yellow
        $replacements | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    }
    if ($Preview) {
        Write-Host ''
        Write-Host 'PREVIEW COMPLETE: nothing was written.' -ForegroundColor Cyan
        if ($replacements.Count -gt 0 -and -not $Force) { Write-Host 'Installing will require -Force to replace the files listed above.' -ForegroundColor Yellow }
        exit 0
    }
    if ($replacements.Count -gt 0 -and -not $Force) {
        Stop-Install 'Nothing was written. Review the files above, then re-run with -Force to replace them.'
    }

    # 4. Publish
    Write-Step 'Installing'
    $created = [System.Collections.Generic.List[string]]::new()
    $replaced = [System.Collections.Generic.List[string]]::new()
    $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $Tool) {
        $reportPath = Join-Path $receiptDirectory "$name.json"
        $arguments = Get-PublishArguments $name $reportPath
        if ($Force) { $arguments.Force = $true }
        $result = Invoke-Publisher $name $arguments
        if ($result.ExitCode -ne 0) { Write-Host $result.Output; Stop-Install "$name could not be installed." }
        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        foreach ($path in @($report.created)) { if (-not $created.Contains($path)) { $created.Add($path) } }
        foreach ($path in @($report.replaced)) { if (-not $replaced.Contains($path)) { $replaced.Add($path) } }
        foreach ($path in @($report.kept)) { if (-not $kept.Contains($path)) { $kept.Add($path) } }
        Write-Host "  $name installed" -ForegroundColor Green
    }

    # 5. Validate offline. An ARM64 binary cannot run on an x64 machine, so its
    #    structure and architecture are checked without executing it.
    Write-Step 'Validating the installed overlay (no database needed)'
    $validatorArguments = @{ InstallRoot = $workspacePath; Tool = $Tool }
    if ($installSqlsim) {
        $validatorArguments.SqlsimExecutable = "sqlsim/$Architecture/sqlsim.exe"
        if ($Architecture -eq 'ARM64' -and $env:PROCESSOR_ARCHITECTURE -ne 'ARM64') { $validatorArguments.SkipExecution = $true }
    }
    & $validator @validatorArguments | Out-Host
    $validated = $LASTEXITCODE -eq 0
    if (-not $validated) { Stop-Install 'The installed overlay failed validation. See the errors above.' }

    # 6. Receipt
    $installedSqlsim = Join-Path $workspacePath "sqlsim\$Architecture\sqlsim.exe"
    Write-Host ''
    Write-Host '========================================' -ForegroundColor Green
    Write-Host 'INSTALL COMPLETE' -ForegroundColor Green
    Write-Host '========================================' -ForegroundColor Green
    Write-Host "Project:      $workspacePath"
    if ($installSqlsim) {
        $version = if ($validatorArguments.SkipExecution) { 'not run on this machine' } else { (& $installedSqlsim --version | Out-String).Trim() }
        Write-Host "sqlsim:       $version ($Architecture)"
        Write-Host "  executable  $installedSqlsim"
        Write-Host "  manual      $(Join-Path $workspacePath 'sqlsim\sqlsim.md')"
        Write-Host "  skill       $(Join-Path $workspacePath '.github\skills\sqlsim\SKILL.md')"
    }
    if ($installSqlpysim) {
        Write-Host "sqlpysim:     $(Join-Path $workspacePath 'sqlpysim\sqlpysim.py')"
        Write-Host "  manual      $(Join-Path $workspacePath 'sqlpysim\sqlpysim.md')"
        Write-Host "  skill       $(Join-Path $workspacePath '.github\skills\sqlpysim\SKILL.md')"
    }
    Write-Host "Agent:        $(Join-Path $workspacePath '.github\agents\sqlsimtools-workload-builder.agent.md')"
    Write-Host "Files:        $($created.Count) created, $($replaced.Count) replaced, $($kept.Count) of your own kept"
    $replaced | ForEach-Object { Write-Host "  replaced    $_" -ForegroundColor Yellow }
    $checks = if ($installSqlsim) { 'layout, frontmatter, architecture, help, documented options' } else { 'layout, frontmatter, help, documented options' }
    if ($validatorArguments.SkipExecution) { $checks = 'layout, frontmatter, architecture; not run on this machine' }
    Write-Host "Validation:   passed ($checks)"
    Write-Host ''
    Write-Host 'Next steps:' -ForegroundColor Cyan
    if ($installSqlpysim -and -not $pythonReady) {
        Write-Host "  - Install sqlpysim's Python dependencies: python -m pip install -r `"$(Join-Path $workspacePath 'sqlpysim\requirements.txt')`""
    }
    Write-Host '  - Open the project in VS Code. If the skill or the sqlsimtools Workload Builder'
    Write-Host '    does not appear in chat, run "Developer: Reload Window".'
    Write-Host '  - Run a first workload against a test database, for example:'
    Write-Host "      .\sqlsim\$Architecture\sqlsim.exe -S localhost -E -Q `"SELECT @@VERSION`""
} finally {
    Remove-Item -LiteralPath $receiptDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
