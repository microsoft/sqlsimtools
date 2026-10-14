<#
.SYNOPSIS
    Stage the five public release assets.

.DESCRIPTION
    Copies the five public packages, each named with its version, from the
    downloaded workflow artifacts. The README links to the latest release page,
    https://github.com/<owner>/<repo>/releases/latest, so no version-free copies
    are attached.

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
    "sqlsim-$Version-win-x64.zip"
    "sqlsim-$Version-win-arm64.zip"
    "sqlsim-$Version-linux-x64.tar.gz"
    "sqlpysim-$Version-src.zip"
    "sqlsimtools-$Version-win-x64.zip"
)

$missing = @()
foreach ($package in $packages) {
    $source = Get-ChildItem -LiteralPath $ArtifactDirectory -Recurse -File -Filter $package |
        Select-Object -First 1
    if (-not $source) {
        $missing += $package
        continue
    }
    Copy-Item -LiteralPath $source.FullName -Destination (Join-Path $OutputDirectory $package) -Force
}
if ($missing) {
    throw "Release assets missing from the workflow artifacts: $($missing -join ', ')"
}

Write-Output 'sqlsim Studio Linux remains an Actions artifact for Private Preview validation and is not attached to the public Release.'
Get-ChildItem -LiteralPath $OutputDirectory -File | Sort-Object Name | ForEach-Object {
    '{0,-40} {1,12:N0} bytes' -f $_.Name, $_.Length
}
