<#
.SYNOPSIS
    Stage the public release assets, adding a version-free copy of each.

.DESCRIPTION
    Copies the five public packages from the downloaded workflow artifacts and
    adds a copy of each without the version in its name, for example
    sqlsimtools-win-x64.zip. GitHub serves those at a fixed URL,
    https://github.com/<owner>/<repo>/releases/latest/download/<name>, so the
    README can link straight to the newest download. The versioned files stay
    for anyone who needs a specific release.

    Fails if any expected package is missing. The Private Preview Studio Linux
    archive is never staged.

.PARAMETER ArtifactDirectory
    Directory containing the downloaded workflow artifacts.

.PARAMETER OutputDirectory
    Directory that receives the release assets.

.PARAMETER Version
    Release version without a v prefix, for example 1.0.0.
#>
param(
    [Parameter(Mandatory)] [string]$ArtifactDirectory,
    [Parameter(Mandatory)] [string]$OutputDirectory,
    [Parameter(Mandatory)] [string]$Version
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$packages = @(
    @{ Versioned = "sqlsim-$Version-win-x64.zip"; Stable = 'sqlsim-win-x64.zip' }
    @{ Versioned = "sqlsim-$Version-win-arm64.zip"; Stable = 'sqlsim-win-arm64.zip' }
    @{ Versioned = "sqlsim-$Version-linux-x64.tar.gz"; Stable = 'sqlsim-linux-x64.tar.gz' }
    @{ Versioned = "sqlpysim-$Version-src.zip"; Stable = 'sqlpysim-src.zip' }
    @{ Versioned = "sqlsimtools-$Version-win-x64.zip"; Stable = 'sqlsimtools-win-x64.zip' }
)

$missing = @()
foreach ($package in $packages) {
    $source = Get-ChildItem -LiteralPath $ArtifactDirectory -Recurse -File -Filter $package.Versioned |
        Select-Object -First 1
    if (-not $source) {
        $missing += $package.Versioned
        continue
    }
    Copy-Item -LiteralPath $source.FullName -Destination (Join-Path $OutputDirectory $package.Versioned) -Force
    Copy-Item -LiteralPath $source.FullName -Destination (Join-Path $OutputDirectory $package.Stable) -Force
}
if ($missing) {
    throw "Release assets missing from the workflow artifacts: $($missing -join ', ')"
}

Write-Output 'sqlsim Studio Linux remains an Actions artifact for Private Preview validation and is not attached to the public Release.'
Get-ChildItem -LiteralPath $OutputDirectory -File | Sort-Object Name | ForEach-Object {
    '{0,-40} {1,12:N0} bytes' -f $_.Name, $_.Length
}
