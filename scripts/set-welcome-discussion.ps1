<#
.SYNOPSIS
    Repoint the welcome-discussion links after the public repository is created.

.DESCRIPTION
    GitHub numbers discussions from the same sequence as issues and pull
    requests, so the welcome discussion gets a different number in a new
    repository. This script rewrites every hard-coded discussion link to the
    number the welcome discussion actually received.

    Run it after creating the welcome discussion in the public repository and
    before pushing the public snapshot.

.EXAMPLE
    ./scripts/set-welcome-discussion.ps1 -Number 1 -WhatIf
    ./scripts/set-welcome-discussion.ps1 -Number 1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateRange(1, 100000)]
    [int]$Number,

    [string]$Owner = 'microsoft',

    [string]$Repo = 'sqlsimtools'
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
try {
    $pattern = "https://github\.com/$([regex]::Escape($Owner))/$([regex]::Escape($Repo))/discussions/(\d+)"
    $target  = "https://github.com/$Owner/$Repo/discussions/$Number"

    $files = git ls-files --cached --others --exclude-standard | Where-Object { $_ -match '\.(md|yml|yaml|html)$' }
    if (-not $files) { throw 'No tracked files found. Run from inside the repository.' }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $totalHits = 0
    $changed = @()

    foreach ($file in $files) {
        $full = Join-Path $repoRoot $file
        $text = [IO.File]::ReadAllText($full, [Text.Encoding]::UTF8)

        $hits = [regex]::Matches($text, $pattern)
        if ($hits.Count -eq 0) { continue }

        $stale = @($hits | Where-Object { $_.Groups[1].Value -ne "$Number" })
        $totalHits += $hits.Count
        if ($stale.Count -eq 0) {
            Write-Host ("  ok      {0}  ({1} link(s) already #{2})" -f $file, $hits.Count, $Number)
            continue
        }

        if ($PSCmdlet.ShouldProcess($file, "rewrite $($stale.Count) discussion link(s) to #$Number")) {
            [IO.File]::WriteAllText($full, [regex]::Replace($text, $pattern, $target), $utf8NoBom)
        }
        $changed += $file
        Write-Host ("  updated {0}  ({1} link(s) -> #{2})" -f $file, $stale.Count, $Number) -ForegroundColor Green
    }

    Write-Host ''
    Write-Host ("Scanned {0} tracked files. Found {1} discussion link(s) in {2} file(s) needing change." -f $files.Count, $totalHits, $changed.Count)
    if ($totalHits -eq 0) {
        Write-Warning 'No discussion links matched. Check the -Owner and -Repo values.'
    }
}
finally {
    Pop-Location
}