<#
.SYNOPSIS
    Assemble the sqlsimtools Windows x64 bundle: sqlsim Studio plus the complete
    sqlsim and sqlpysim packages.

.DESCRIPTION
    The bundle is the released sqlsim x64 and sqlpysim packages, unchanged, with
    sqlsim Studio added under sqlsimstudio/. Studio's own engine copies are left
    out: in the bundle it runs sqlsim from sqlsim/x64 and sqlpysim from sqlpysim,
    so there is one binary and one script. Studio's agent skill joins the other
    skills under .github/skills.

    Overlapping package files must be identical, so neither package can silently
    replace the other's content.

.PARAMETER SqlsimPackage
    The sqlsim Windows x64 release ZIP, or a directory with the same layout.

.PARAMETER SqlpysimPackage
    The sqlpysim release ZIP, or a directory with the same layout.

.PARAMETER StudioBuild
    The Studio win-x64 build output from sqlsimstudio/build.ps1.

.PARAMETER Version
    Version used in the archive name and the bundle README.

.PARAMETER OutputDirectory
    Directory that receives sqlsimtools-<Version>-win-x64.zip.

.EXAMPLE
    ./release/build-sqlsimtools-bundle.ps1 -SqlsimPackage sqlsim-1.0.0-win-x64.zip `
        -SqlpysimPackage sqlpysim-1.0.0-src.zip -StudioBuild sqlsimstudio/build/win-x64 `
        -Version 1.0.0 -OutputDirectory artifacts
#>
param(
    [Parameter(Mandatory)] [string]$SqlsimPackage,
    [Parameter(Mandatory)] [string]$SqlpysimPackage,
    [Parameter(Mandatory)] [string]$StudioBuild,
    [Parameter(Mandatory)] [string]$Version,
    [Parameter(Mandatory)] [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$work = Join-Path ([IO.Path]::GetTempPath()) ("sqlsimtools-bundle-" + [guid]::NewGuid().ToString('N'))
$stage = Join-Path $work 'stage'
New-Item -ItemType Directory -Path $stage -Force | Out-Null

function Resolve-PackageRoot {
    param([string]$Package, [string]$Name)
    $item = Get-Item -LiteralPath $Package
    if ($item.PSIsContainer) { return $item.FullName }
    $extracted = Join-Path $work $Name
    Expand-Archive -LiteralPath $item.FullName -DestinationPath $extracted -Force
    return $extracted
}

function Add-Tree {
    param([string]$Source, [string]$Destination, [string[]]$ExcludeTopLevel = @())
    $sourceRoot = (Resolve-Path -LiteralPath $Source).Path.TrimEnd('\', '/')
    foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force) {
        $relative = $file.FullName.Substring($sourceRoot.Length + 1)
        if ($ExcludeTopLevel -contains ($relative -split '[\\/]')[0]) { continue }
        $target = Join-Path $Destination $relative
        if (Test-Path -LiteralPath $target) {
            if ((Get-FileHash -LiteralPath $target).Hash -ne (Get-FileHash -LiteralPath $file.FullName).Hash) {
                throw "Bundle conflict: $relative differs between packages."
            }
            continue
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target
    }
}

try {
    $sqlsimRoot = Resolve-PackageRoot -Package $SqlsimPackage -Name 'sqlsim'
    $sqlpysimRoot = Resolve-PackageRoot -Package $SqlpysimPackage -Name 'sqlpysim'
    $studioRoot = (Resolve-Path -LiteralPath $StudioBuild).Path

    if (-not (Test-Path -LiteralPath (Join-Path $sqlsimRoot 'sqlsim/x64/sqlsim.exe'))) {
        throw "SqlsimPackage is not a Windows x64 sqlsim package: sqlsim/x64/sqlsim.exe is missing."
    }
    if (Test-Path -LiteralPath (Join-Path $sqlsimRoot 'sqlsim/ARM64')) {
        throw 'SqlsimPackage contains sqlsim/ARM64; use the x64 package.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $sqlpysimRoot 'sqlpysim/sqlpysim.py'))) {
        throw 'SqlpysimPackage does not contain sqlpysim/sqlpysim.py.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $studioRoot 'sqlsimstudio.exe'))) {
        throw 'StudioBuild does not contain sqlsimstudio.exe.'
    }

    Add-Tree -Source $sqlsimRoot -Destination $stage
    Add-Tree -Source $sqlpysimRoot -Destination $stage

    # Studio's private engine copies and skill folder are replaced by the bundle's.
    Add-Tree -Source $studioRoot -Destination (Join-Path $stage 'sqlsimstudio') -ExcludeTopLevel @('sqlsim', 'sqlpysim', '.github')
    Add-Tree -Source (Join-Path $studioRoot '.github') -Destination (Join-Path $stage '.github')

    $readme = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'sqlsimtools-bundle-README.md') -Raw
    Set-Content -LiteralPath (Join-Path $stage 'README.md') -Value ($readme -replace '\{\{VERSION\}\}', $Version) -Encoding utf8NoBOM -NoNewline

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $zip = Join-Path (Resolve-Path -LiteralPath $OutputDirectory).Path "sqlsimtools-$Version-win-x64.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
    Write-Output $zip
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
