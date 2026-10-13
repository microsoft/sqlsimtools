# Shared by sqlsim/publish.ps1 and sqlpysim/publish.ps1 to install a release
# overlay into a project without silently overwriting or deleting its files.
#
# A plan lists every file the overlay installs. Before anything is written,
# each destination is classified as Create, Replace (contents differ), or
# Unchanged. Replacing requires -Force, except in the repository's disposable
# release staging directory. Files a user added under an overlay directory are
# reported and kept; nothing outside the plan is ever deleted.

Set-StrictMode -Version Latest

function New-OverlayPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $resolvedRoot = [IO.Path]::GetFullPath($Root)
    return [pscustomobject]@{
        Root        = $resolvedRoot
        Files       = [System.Collections.Generic.List[object]]::new()
        Directories = [System.Collections.Generic.List[string]]::new()
    }
}

function Add-OverlayFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$RelativePath
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Overlay source file not found: $Source"
    }
    $relative = $RelativePath.Replace('\', '/').TrimStart('/')
    $Plan.Files.Add([pscustomobject]@{
        Source       = (Resolve-Path -LiteralPath $Source).Path
        RelativePath = $relative
        Destination  = [IO.Path]::GetFullPath((Join-Path $Plan.Root $relative))
        Status       = $null
    })
}

# Adds every file under a source directory. The directory is also recorded so
# files present at the destination but absent from the source are reported.
function Add-OverlayDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$RelativePath
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Overlay source directory not found: $Source"
    }
    $sourceRoot = (Resolve-Path -LiteralPath $Source).Path.TrimEnd('\', '/')
    $relativeRoot = $RelativePath.Replace('\', '/').Trim('/')
    $Plan.Directories.Add($relativeRoot)
    Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
        $inner = $_.FullName.Substring($sourceRoot.Length + 1).Replace('\', '/')
        Add-OverlayFile -Plan $Plan -Source $_.FullName -RelativePath "$relativeRoot/$inner"
    }
}

function Get-OverlayFileHash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

# Classifies every planned file and finds extra files under overlay
# directories. Writes nothing.
function Get-OverlayChanges {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)

    foreach ($file in $Plan.Files) {
        if (-not (Test-Path -LiteralPath $file.Destination -PathType Leaf)) {
            $file.Status = 'Create'
        } elseif ((Get-OverlayFileHash $file.Source) -eq (Get-OverlayFileHash $file.Destination)) {
            $file.Status = 'Unchanged'
        } else {
            $file.Status = 'Replace'
        }
    }

    $planned = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $Plan.Files) { $null = $planned.Add($file.Destination) }

    $extra = [System.Collections.Generic.List[string]]::new()
    foreach ($directory in $Plan.Directories) {
        $destinationDirectory = Join-Path $Plan.Root $directory
        if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) { continue }
        Get-ChildItem -LiteralPath $destinationDirectory -Recurse -File -Force | ForEach-Object {
            if (-not $planned.Contains($_.FullName)) {
                $extra.Add($_.FullName.Substring($Plan.Root.Length).TrimStart('\', '/').Replace('\', '/'))
            }
        }
    }

    return [pscustomobject]@{
        Create    = @($Plan.Files | Where-Object Status -eq 'Create' | ForEach-Object RelativePath)
        Replace   = @($Plan.Files | Where-Object Status -eq 'Replace' | ForEach-Object RelativePath)
        Unchanged = @($Plan.Files | Where-Object Status -eq 'Unchanged' | ForEach-Object RelativePath)
        Extra     = @($extra | Sort-Object)
    }
}

function Write-OverlayList {
    param([string]$Label, [string[]]$Paths, [ConsoleColor]$Color)
    if ($Paths.Count -eq 0) { return }
    Write-Host "  ${Label}:" -ForegroundColor $Color
    foreach ($path in $Paths) { Write-Host "    $path" -ForegroundColor $Color }
}

# Applies the plan. Returns the change report, or throws when replacements
# need -Force. With -Preview, prints the report and writes nothing.
# -Disposable marks a staging directory owned by this repository: it replaces
# without -Force and removes files no longer in the overlay.
function Invoke-OverlayInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [switch]$Force,
        [switch]$Preview,
        [switch]$Disposable,
        [string]$ReportPath
    )

    $changes = Get-OverlayChanges -Plan $Plan
    $mode = if ($Preview) { 'Preview: no files will be written' } elseif ($Disposable) { 'Staging directory' } else { 'Project install' }
    Write-Host ''
    Write-Host "Overlay target: $($Plan.Root)" -ForegroundColor Cyan
    Write-Host "Mode: $mode" -ForegroundColor Cyan
    Write-Host ("  {0} to create, {1} to replace, {2} unchanged, {3} other file(s) in overlay folders" -f `
        $changes.Create.Count, $changes.Replace.Count, $changes.Unchanged.Count, $changes.Extra.Count) -ForegroundColor Gray
    Write-OverlayList 'Replace' $changes.Replace Yellow
    if ($changes.Extra.Count -gt 0) {
        $extraLabel = if ($Disposable) { 'Remove (no longer in the overlay)' } else { 'Keep (not part of the overlay)' }
        Write-OverlayList $extraLabel $changes.Extra DarkGray
    }

    $report = [ordered]@{
        target    = $Plan.Root
        preview   = [bool]$Preview
        created   = $changes.Create
        replaced  = $changes.Replace
        unchanged = $changes.Unchanged
        kept      = @(if (-not $Disposable) { $changes.Extra })
        removed   = @(if ($Disposable -and -not $Preview) { $changes.Extra })
    }

    if ($Preview) {
        if ($changes.Replace.Count -gt 0 -and -not $Force -and -not $Disposable) {
            Write-Host '  Installing would require -Force to replace the files above.' -ForegroundColor Yellow
        }
        $report.created = @()
        $report.replaced = @()
        $report.unchanged = @()
        $report['wouldCreate'] = $changes.Create
        $report['wouldReplace'] = $changes.Replace
    } else {
        if ($changes.Replace.Count -gt 0 -and -not $Force -and -not $Disposable) {
            throw ("{0} existing file(s) in {1} differ from this release and were not changed. " +
                "Review the list above, then re-run with -Force to replace them, or with -Preview to list changes without writing.") -f `
                $changes.Replace.Count, $Plan.Root
        }

        foreach ($file in $Plan.Files) {
            if ($file.Status -eq 'Unchanged') { continue }
            $directory = Split-Path -Parent $file.Destination
            if (-not (Test-Path -LiteralPath $directory)) {
                New-Item -ItemType Directory -Path $directory -Force | Out-Null
            }
            Copy-Item -LiteralPath $file.Source -Destination $file.Destination -Force
        }
        if ($Disposable) {
            foreach ($relative in $changes.Extra) {
                Remove-Item -LiteralPath (Join-Path $Plan.Root $relative) -Force
            }
        }
        Write-Host ("  Created {0}, replaced {1}, unchanged {2}." -f `
            $changes.Create.Count, $changes.Replace.Count, $changes.Unchanged.Count) -ForegroundColor Green
    }

    if ($ReportPath) {
        $reportDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($ReportPath))
        if (-not (Test-Path -LiteralPath $reportDirectory)) {
            New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
        }
        $report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ReportPath -Encoding utf8
    }
    return [pscustomobject]$report
}

# True when the target is the repository's ignored release staging tree, which
# publish scripts own and may freely overwrite.
function Test-OverlayStagingDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$RepositoryRoot
    )

    $staging = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'release\sqlsimtools')).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath($Target).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    return $full.StartsWith($staging, [StringComparison]::OrdinalIgnoreCase)
}

Export-ModuleMember -Function New-OverlayPlan, Add-OverlayFile, Add-OverlayDirectory, Get-OverlayChanges, Invoke-OverlayInstall, Test-OverlayStagingDirectory
