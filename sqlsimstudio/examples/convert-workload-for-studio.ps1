<#
.SYNOPSIS
    Convert a sqlsim workload file into one sqlsim Studio can import.

.DESCRIPTION
    sqlsim reads a workload group's SQL from a file path:

        { "file": "reads.sql", "threads": 8, "iterations": 100 }

    Studio imports workload files in the browser, which has no filesystem
    access, so it can only use groups that carry their SQL inline:

        { "queries": ["SELECT ..."], "threads": 8, "iterations": 100 }

    This reads each referenced file, splits it on GO, and writes an equivalent
    workload file with the SQL inline. Groups that already have inline queries
    are copied unchanged. The original file is not modified.

.PARAMETER Path
    The sqlsim workload JSON to convert.

.PARAMETER OutputPath
    Where to write the Studio-importable file. Defaults to the input name with
    "-studio" appended.

.PARAMETER Iterations
    Iterations to apply to any group that has none. sqlsim can run a workload
    for a wall-clock duration ("duration_seconds"), but Studio always runs a
    fixed iteration count and defaults a missing one to 1 -- so a duration-mode
    file imported unchanged runs every thread exactly once and finishes in
    seconds. Supply this to convert a duration into comparable work.

.EXAMPLE
    .\convert-workload-for-studio.ps1 -Path .\hyperscale-workload.json

.EXAMPLE
    .\convert-workload-for-studio.ps1 -Path .\scale-workload-baseline.json -Iterations 500
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [string]$OutputPath,
    [int]$Iterations
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path)) { throw "Workload file not found: $Path" }
$source = Get-Item -LiteralPath $Path
if (-not $OutputPath) {
    $OutputPath = Join-Path $source.DirectoryName ($source.BaseName + '-studio' + $source.Extension)
}

# sqlsim allows // comments in workload files; JSON does not. Strip them
# outside of string literals, exactly as Studio's own importer does.
$raw = Get-Content -LiteralPath $Path -Raw
$stripped = [regex]::Replace($raw, '"(?:\\.|[^"\\])*"|/\*[\s\S]*?\*/|//[^\n\r]*', {
    param($match)
    if ($match.Value.StartsWith('"')) { $match.Value } else { ' ' }
})

$definition = $stripped | ConvertFrom-Json
if (-not $definition.workloads) { throw 'The workload file has no "workloads" array.' }

$groups = @($definition.workloads)
if ($groups.Count -gt 20) {
    Write-Warning "Studio supports at most 20 groups; this file has $($groups.Count). The extras will be refused on import."
}

$converted = [System.Collections.Generic.List[object]]::new()
$missingIterations = [System.Collections.Generic.List[string]]::new()
$index = 0
foreach ($group in $groups) {
    $index++
    $label = "Group $index"

    $inline = @($group.PSObject.Properties.Name) -contains 'queries' -and @($group.queries).Count -gt 0
    if ($inline) {
        Write-Host "  $label already inline, copied unchanged" -ForegroundColor DarkGray
        $queries = @($group.queries)
    } else {
        if (-not $group.file) { throw "$label has neither 'file' nor 'queries'." }

        # Resolve relative to the workload file, which is how sqlsim reads it.
        $scriptPath = if ([System.IO.Path]::IsPathRooted($group.file)) {
            $group.file
        } else {
            Join-Path $source.DirectoryName $group.file
        }
        if (-not (Test-Path -LiteralPath $scriptPath)) {
            throw "$label references '$($group.file)', which was not found at $scriptPath"
        }

        $sql = Get-Content -LiteralPath $scriptPath -Raw
        # Split on GO exactly as sqlsim and Studio do: the word alone on a line.
        $batches = [regex]::Split($sql, '(?im)^\s*GO\s*(?:--.*)?$') |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne '' }
        if ($batches.Count -eq 0) { throw "$label references '$($group.file)', which contains no SQL." }

        $queries = @($batches)
        Write-Host "  $label inlined $($group.file) as $($queries.Count) batch(es)" -ForegroundColor Green
    }

    $entry = [ordered]@{ queries = $queries }
    foreach ($name in 'threads', 'iterations', 'think_time_ms') {
        if (@($group.PSObject.Properties.Name) -contains $name) { $entry[$name] = $group.$name }
    }
    # Studio defaults a missing iteration count to 1, so a duration-mode group
    # would run once and stop. Fill it in rather than let the import quietly
    # produce a workload that does almost nothing.
    if (-not $entry.Contains('iterations')) {
        if ($Iterations -gt 0) {
            $entry['iterations'] = $Iterations
        } else {
            $missingIterations.Add($label)
        }
    }
    $converted.Add([pscustomobject]$entry)
}

$output = [ordered]@{}
# duration_seconds is preserved so the file still runs correctly on the sqlsim
# CLI. Studio ignores it and says so when importing.
if (@($definition.PSObject.Properties.Name) -contains 'duration_seconds') {
    $output['duration_seconds'] = $definition.duration_seconds
}
# Studio has no ramp-up control, so these are kept for the CLI but will not
# take effect on an imported run.
foreach ($name in 'ramp_batch_size', 'ramp_delay_ms') {
    if (@($definition.PSObject.Properties.Name) -contains $name) { $output[$name] = $definition.$name }
}
$output['workloads'] = $converted

$json = [pscustomobject]$output | ConvertTo-Json -Depth 10
Set-Content -LiteralPath $OutputPath -Value $json -Encoding UTF8

$totalConnections = ($converted | ForEach-Object { if ($_.threads) { $_.threads } else { 1 } } | Measure-Object -Sum).Sum

Write-Host ''
Write-Host "Wrote $OutputPath" -ForegroundColor Cyan
Write-Host "  $($converted.Count) group(s), $totalConnections connection(s)" -ForegroundColor Cyan

# Report what Studio will do differently, so none of it is discovered mid-demo.
$studioDiffers = @()
if (@($definition.PSObject.Properties.Name) -contains 'duration_seconds') {
    $studioDiffers += "duration_seconds ($($definition.duration_seconds)s) is ignored by Studio, which runs a fixed iteration count instead."
}
if (@($definition.PSObject.Properties.Name) -contains 'ramp_batch_size') {
    $studioDiffers += "ramp_batch_size ($($definition.ramp_batch_size)) and ramp_delay_ms are dropped by Studio: all $totalConnections connections open at once rather than in batches."
}
if ($studioDiffers.Count -gt 0) {
    Write-Host ''
    Write-Host 'Studio will run this differently from the sqlsim CLI:' -ForegroundColor Yellow
    foreach ($line in $studioDiffers) { Write-Host "  - $line" -ForegroundColor Yellow }
}

if ($missingIterations.Count -gt 0) {
    Write-Host ''
    Write-Host "$($missingIterations.Count) group(s) have no iteration count, so Studio will run each thread ONCE" -ForegroundColor Red
    Write-Host 'and the run will finish in seconds. Re-run with -Iterations <n> to set one.' -ForegroundColor Red
    Write-Host 'Calibrate it: a group of threads doing i iterations of a query taking q ms,' -ForegroundColor DarkGray
    Write-Host 'plus think time t, occupies roughly i x (q + t) ms. For a 120 second run with' -ForegroundColor DarkGray
    Write-Host 'a 50 ms query and 15 ms think time, that is about 1850 iterations.' -ForegroundColor DarkGray
} else {
    Write-Host '  Import this file in Studio with the Import JSON button.' -ForegroundColor Cyan
}
