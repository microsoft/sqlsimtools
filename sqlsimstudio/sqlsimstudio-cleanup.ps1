<#
.SYNOPSIS
    Collect what sqlsim Studio leaves behind when it is killed rather than shut
    down.

.DESCRIPTION
    Shutting down from the interface stops any workload, removes the session's
    temporary files, and exits cleanly. Killing the process instead -- from
    Task Manager, or a signal -- skips all of that, and two things survive:

      * the sqlsim or sqlpysim child process, which keeps executing the
        workload against the target database with nothing supervising it;
      * the private run directory, holding the input script, the results file,
        and any query-statistics snapshots.

    The orphaned engine matters most. A load test that outlives its supervisor
    carries on consuming the database it was pointed at.

    This reports what it finds and, unless -WhatIf is used, stops the orphans
    and removes the directories.

.PARAMETER IncludeRunning
    Also stop a Studio process that is still responding. By default a live
    Studio is left alone and reported, because shutting it down from the
    interface is cleaner and stops its workload in the proper order.

.EXAMPLE
    .\sqlsimstudio-cleanup.ps1 -WhatIf
    Show what would be cleaned up without changing anything.

.EXAMPLE
    .\sqlsimstudio-cleanup.ps1
    Stop orphaned engine processes and remove stale run directories.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$IncludeRunning
)

$ErrorActionPreference = 'Stop'

function Write-Finding {
    param([string]$Text, [string]$Colour = 'White')
    Write-Host "  $Text" -ForegroundColor $Colour
}

Write-Host ''
Write-Host 'sqlsim Studio cleanup' -ForegroundColor Cyan
Write-Host '=====================' -ForegroundColor Cyan

# ---------------------------------------------------------------- Studio
Write-Host ''
Write-Host 'Studio processes' -ForegroundColor Cyan
$studio = @(Get-Process -Name 'sqlsimstudio' -ErrorAction SilentlyContinue)
if ($studio.Count -eq 0) {
    Write-Finding 'none running' 'DarkGray'
} else {
    foreach ($process in $studio) {
        $age = [math]::Round(((Get-Date) - $process.StartTime).TotalMinutes)
        if ($IncludeRunning) {
            if ($PSCmdlet.ShouldProcess("sqlsimstudio (PID $($process.Id))", 'Stop')) {
                $process.Kill($true)
                $null = $process.WaitForExit(10000)
                Write-Finding "stopped PID $($process.Id), running $age min" 'Yellow'
            }
        } else {
            Write-Finding "PID $($process.Id), running $age min -- left alone" 'Yellow'
            Write-Finding 'Shut it down from the interface, or re-run with -IncludeRunning.' 'DarkGray'
        }
    }
}

# ------------------------------------------------------------ engine orphans
# A sqlsim or sqlpysim process whose parent is gone is still executing a
# workload. Studio always starts these as children, so an orphan is a reliable
# sign that Studio was killed rather than shut down.
Write-Host ''
Write-Host 'Workload engine processes' -ForegroundColor Cyan
$studioIds = @($studio | ForEach-Object { $_.Id })
$engines = @(Get-CimInstance Win32_Process -Filter "Name = 'sqlsim.exe'" -ErrorAction SilentlyContinue)
$engines += @(Get-CimInstance Win32_Process -Filter "Name = 'python.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'sqlpysim\.py' })

$orphans = @($engines | Where-Object {
    $parent = Get-Process -Id $_.ParentProcessId -ErrorAction SilentlyContinue
    # Orphaned if the parent is gone, or if the parent is a Studio this script
    # has just been asked to stop.
    (-not $parent) -or ($parent.ProcessName -eq 'sqlsimstudio' -and $IncludeRunning -and $studioIds -contains $parent.Id)
})

if ($engines.Count -eq 0) {
    Write-Finding 'none running' 'DarkGray'
} elseif ($orphans.Count -eq 0) {
    Write-Finding "$($engines.Count) running, all still owned by a live Studio -- left alone" 'DarkGray'
} else {
    foreach ($orphan in $orphans) {
        $target = if ($orphan.CommandLine -match '-S\s+"?([^\s"]+)') { $Matches[1] } else { 'unknown target' }
        if ($PSCmdlet.ShouldProcess("$($orphan.Name) (PID $($orphan.ProcessId)) against $target", 'Stop')) {
            try {
                Stop-Process -Id $orphan.ProcessId -Force -ErrorAction Stop
                Write-Finding "stopped PID $($orphan.ProcessId), was running against $target" 'Yellow'
            } catch {
                Write-Finding "could not stop PID $($orphan.ProcessId): $($_.Exception.Message)" 'Red'
            }
        }
    }
}

# --------------------------------------------------------- run directories
Write-Host ''
Write-Host 'Temporary run directories' -ForegroundColor Cyan
$runRoot = Join-Path ([IO.Path]::GetTempPath()) 'sqlsimstudio'
if (-not (Test-Path -LiteralPath $runRoot)) {
    Write-Finding 'none found' 'DarkGray'
} else {
    $directories = @(Get-ChildItem -LiteralPath $runRoot -Directory -ErrorAction SilentlyContinue)
    if ($directories.Count -eq 0) {
        Write-Finding 'none found' 'DarkGray'
    }
    foreach ($directory in $directories) {
        $size = [math]::Round((@(Get-ChildItem -LiteralPath $directory.FullName -Recurse -File -ErrorAction SilentlyContinue) |
            Measure-Object -Property Length -Sum).Sum / 1KB)
        if ($PSCmdlet.ShouldProcess($directory.FullName, 'Remove')) {
            try {
                Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction Stop
                Write-Finding "removed $($directory.Name) ($size KB)" 'Yellow'
            } catch {
                # A directory in use belongs to a run that is still going.
                Write-Finding "in use, kept: $($directory.Name)" 'DarkGray'
            }
        }
    }
}

# ------------------------------------------------------------ session file
Write-Host ''
Write-Host 'Session file' -ForegroundColor Cyan
$sessionFile = Join-Path ([IO.Path]::GetTempPath()) "sqlsimstudio-session-$env:USERNAME.url"
if (Test-Path -LiteralPath $sessionFile) {
    $stillRunning = @(Get-Process -Name 'sqlsimstudio' -ErrorAction SilentlyContinue).Count -gt 0
    if ($stillRunning -and -not $IncludeRunning) {
        Write-Finding 'kept: it reopens the Studio that is still running' 'DarkGray'
    } elseif ($PSCmdlet.ShouldProcess($sessionFile, 'Remove')) {
        Remove-Item -LiteralPath $sessionFile -Force -ErrorAction SilentlyContinue
        Write-Finding 'removed a session file pointing at a Studio that is gone' 'Yellow'
    }
} else {
    Write-Finding 'none found' 'DarkGray'
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Cyan
Write-Host ''
