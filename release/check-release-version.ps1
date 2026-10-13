<#
.SYNOPSIS
    Fail when a release version does not match the versions built into the tools.

.DESCRIPTION
    The release workflow names archives from the tag, but each tool reports the
    version compiled from its own source. This check compares the two so a tag
    such as v1.0.1 cannot ship binaries that still report 1.0.0.

    A leading "v" and any pre-release or build suffix are ignored, so the
    release-candidate label 1.0.0-rc4 is checked as 1.0.0.

.PARAMETER Version
    The tag or release label, for example v1.0.1, 1.0.1, or 1.0.1-rc1.

.EXAMPLE
    ./release/check-release-version.ps1 -Version v1.0.0
#>
param(
    [Parameter(Mandatory)]
    [string]$Version
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

$expected = $Version.Trim() -replace '^v', '' -replace '[-+].*$', ''
if ($expected -notmatch '^\d+\.\d+\.\d+$') {
    Write-Error "Release version '$Version' is not <major>.<minor>.<patch> with an optional v prefix and -suffix."
    exit 1
}

$sources = @(
    @{ File = 'sqlsim/include/version.h'; Pattern = '#define\s+SQLSIM_VERSION\s+"([^"]+)"' }
    @{ File = 'sqlsim/CMakeLists.txt'; Pattern = 'project\s*\(\s*sqlsim\s+VERSION\s+([0-9.]+)' }
    @{ File = 'sqlpysim/sqlpysim.py'; Pattern = '(?m)^__version__\s*=\s*"([^"]+)"' }
    @{ File = 'sqlpysim/setup.py'; Pattern = 'version\s*=\s*"([^"]+)"' }
    @{ File = 'sqlsimstudio/server/SqlsimStudio.csproj'; Pattern = '<Version>([^<]+)</Version>' }
)

$problems = @()
foreach ($source in $sources) {
    $path = Join-Path $repoRoot $source.File
    if (-not (Test-Path -LiteralPath $path)) {
        $problems += "$($source.File): file not found"
        continue
    }
    $match = [regex]::Match((Get-Content -LiteralPath $path -Raw), $source.Pattern)
    if (-not $match.Success) {
        $problems += "$($source.File): version not found"
    } elseif ($match.Groups[1].Value -ne $expected) {
        $problems += "$($source.File): $($match.Groups[1].Value)"
    } else {
        Write-Output "  ok  $($source.File): $expected"
    }
}

if ($problems) {
    Write-Output ""
    Write-Output "Release version $expected (from '$Version') does not match:"
    $problems | ForEach-Object { Write-Output "  $_" }
    Write-Output ""
    Write-Output "Update every listed file to $expected before tagging."
    exit 1
}

Write-Output "All tool versions match $expected."
exit 0
