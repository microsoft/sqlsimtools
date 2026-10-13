#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Compare sqlsim and sqlpysim behaviour on identical commands.

.DESCRIPTION
    sqlpysim claims to share sqlsim's core workflow. Each tool's own suite
    verifies it against itself, so a difference between them is invisible to
    both. This runs the same arguments through each engine and compares what
    they produce.

    It deliberately does not diff raw text. Timestamps, durations, driver names
    and summary wording legitimately differ. It compares structure: how many
    result sets appeared, how many rows, how many error messages, what exit
    code, and what the configuration block reported.

    Differences already known and documented in RELEASE-NOTES.md are declared
    per scenario through -ExpectedDifference. A declared difference is reported
    as Known. An undeclared one fails the run, which is the point: it surfaces
    behaviour that nobody has decided about yet.

    Two such differences were found by hand in September 2026, both in -Q, an
    option sqlpysim fully supports: only the first thread's first iteration
    printed a result set, and only the first thread's errors were printed. The
    counts were right, so the JSON looked correct while the text hid what a
    load test is run to observe.

.PARAMETER Server
    SQL Server to run against. Defaults to localhost.

.PARAMETER Database
    Database to run against. Defaults to AdventureWorksLT, because several
    scenarios read SalesLT tables.

.PARAMETER UseToken
    Access token for Azure SQL authentication.

.PARAMETER Username
    SQL authentication user name. Password must also be supplied.

.PARAMETER Password
    SQL authentication password. Username must also be supplied.

.PARAMETER SkipDatabaseProvisioning
    Validate AdventureWorksLT without attempting to restore it when absent.

.PARAMETER Detailed
    Print the extracted facts for every scenario, not only the differing ones.

.EXAMPLE
    ./scripts/check-engine-parity.ps1

.EXAMPLE
    ./scripts/check-engine-parity.ps1 -Server localhost -Database AdventureWorksLT -Detailed
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Detailed',
    Justification = 'Read inside Test-Scenario through script scope, which the analyzer does not follow.')]
param(
    [string]$Server = 'localhost',
    [string]$Database = 'AdventureWorksLT',
    [string]$UseToken = '',
    [string]$Username = '',
    [string]$Password = '',
    [switch]$SkipDatabaseProvisioning,
    [switch]$Detailed
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$sqlsimExe = Join-Path $repoRoot 'sqlsim\build\x64\Release\sqlsim.exe'
$sqlpysimScript = Join-Path $repoRoot 'sqlpysim\sqlpysim.py'
$testPreflight = Join-Path $PSScriptRoot 'check-test-prerequisites.ps1'

foreach ($required in @($sqlsimExe, $sqlpysimScript, $testPreflight)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Not found: $required. Build sqlsim and check out sqlpysim before running this."
    }
}

$isAzure = $Server -match 'database\.windows\.net|database\.fabric\.microsoft\.com'
# Secrets travel on stdin (-T - or -P -) so they never appear in a process list.
$script:stdinSecret = $null
if ($UseToken) {
    $script:connectionArgs = @('-T', '-')
    $script:stdinSecret = $UseToken
}
elseif ($Username -and $Password) {
    $script:connectionArgs = @('-U', $Username, '-P', '-')
    $script:stdinSecret = $Password
    if (-not $isAzure) { $script:connectionArgs += '-C' }
}
elseif ($Username -or $Password) {
    throw 'Username and Password must be supplied together.'
}
else {
    $script:connectionArgs = @('-E')
    if (-not $isAzure) { $script:connectionArgs += '-C' }
}

$preflightArguments = @{
    Server = $Server
    Database = $Database
}
if ($Username) {
    $preflightArguments.Username = $Username
    $preflightArguments.Password = $Password
}
if ($UseToken) {
    $preflightArguments.UseToken = $UseToken
}
if ($SkipDatabaseProvisioning) {
    $preflightArguments.SkipDatabaseProvisioning = $true
}
& $testPreflight @preflightArguments
if ($LASTEXITCODE -ne 0) {
    throw "Test prerequisite preflight failed for $Server/$Database."
}

$script:differences = 0
$script:known = 0
$script:matched = 0

function Read-EngineOutput {
    param([string]$Output, [int]$ExitCode)

    # Strip the leading "timestamp | " both tools prefix to every line.
    $lines = ($Output -split "`r?`n") | ForEach-Object { $_ -replace '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \| ', '' }

    $configuredBatches = $null
    foreach ($line in $lines) {
        if ($line -match '^Total batches to execute:\s*(\d+)') { $configuredBatches = [int]$Matches[1]; break }
    }

    [pscustomobject]@{
        ExitCode          = $ExitCode
        ResultSets        = @($lines | Where-Object { $_ -match '^\(\d+ row\(s\) affected\)$' }).Count
        RowsReported      = (@($lines | Where-Object { $_ -match '^\((\d+) row\(s\) affected\)$' } |
                                ForEach-Object { [int]([regex]::Match($_, '^\((\d+)').Groups[1].Value) }) |
                                Measure-Object -Sum).Sum
        ErrorMessages     = @($lines | Where-Object { $_ -match 'Invalid object name|Incorrect syntax' }).Count
        ConfiguredBatches = $configuredBatches
        PrintMessages     = @($lines | Where-Object { $_ -match '^ManualPrintProbe' }).Count
    }
}

# Runs one engine with stderr merged, piping the credential when there is one.
function Invoke-EngineProcess {
    param([string]$Engine, [string[]]$Arguments)

    if ($Engine -eq 'sqlsim') {
        if ($script:stdinSecret) { $script:stdinSecret | & $sqlsimExe @Arguments 2>&1 } else { & $sqlsimExe @Arguments 2>&1 }
    } else {
        if ($script:stdinSecret) { $script:stdinSecret | & python $sqlpysimScript @Arguments 2>&1 } else { & python $sqlpysimScript @Arguments 2>&1 }
    }
}

function Invoke-Engine {
    param([string]$Engine, [string[]]$Arguments)

    $output = Invoke-EngineProcess -Engine $Engine -Arguments $Arguments | Out-String
    return Read-EngineOutput -Output $output -ExitCode $LASTEXITCODE
}

function Test-Scenario {
    param(
        [string]$Name,
        [string[]]$Arguments,
        # Field names whose difference is already known and documented.
        [string[]]$ExpectedDifference = @(),
        [string]$Because = ''
    )

    $shared = @('-S', $Server, '-d', $Database) + $script:connectionArgs + $Arguments
    $a = Invoke-Engine -Engine 'sqlsim' -Arguments $shared
    $b = Invoke-Engine -Engine 'sqlpysim' -Arguments $shared

    $fields = 'ExitCode', 'ResultSets', 'RowsReported', 'ErrorMessages', 'ConfiguredBatches', 'PrintMessages'
    $unexpected = @()
    $declared = @()

    foreach ($field in $fields) {
        if ($a.$field -ne $b.$field) {
            if ($ExpectedDifference -contains $field) {
                $declared += "$field (sqlsim=$($a.$field), sqlpysim=$($b.$field))"
            } else {
                $unexpected += "${field}: sqlsim=$($a.$field), sqlpysim=$($b.$field)"
            }
        }
    }

    if ($unexpected.Count -gt 0) {
        Write-Host "  DIFFERS  $Name" -ForegroundColor Red
        foreach ($line in $unexpected) { Write-Host "           $line" -ForegroundColor Red }
        $script:differences++
    } elseif ($declared.Count -gt 0) {
        Write-Host "  known    $Name" -ForegroundColor Yellow
        foreach ($line in $declared) { Write-Host "           $line" -ForegroundColor DarkYellow }
        if ($Because) { Write-Host "           $Because" -ForegroundColor DarkGray }
        $script:known++
    } else {
        Write-Host "  match    $Name" -ForegroundColor Green
        $script:matched++
    }

    if ($script:Detailed) {
        Write-Host "           sqlsim  : $($a | ConvertTo-Json -Compress)" -ForegroundColor DarkGray
        Write-Host "           sqlpysim: $($b | ConvertTo-Json -Compress)" -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host 'ENGINE PARITY: sqlsim vs sqlpysim' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host "Target: $Server/$Database" -ForegroundColor White
Write-Host ''

Write-Host 'Single execution' -ForegroundColor Cyan
Test-Scenario -Name 'simple query' -Arguments @('-Q', 'SELECT 1 AS One')
Test-Scenario -Name 'multi-row query' -Arguments @('-Q', 'SELECT TOP 10 ProductID, Name FROM SalesLT.Product ORDER BY ProductID')
Test-Scenario -Name 'empty result set' -Arguments @('-Q', 'SELECT ProductID FROM SalesLT.Product WHERE 1 = 0')
Test-Scenario -Name 'null and unicode values' -Arguments @('-Q', "SELECT NULL AS Nothing, NCHAR(233) AS Accented")
Test-Scenario -Name 'multiple result sets in one batch' -Arguments @('-Q', 'SELECT 1 AS First; SELECT 2 AS Second;')

Write-Host ''
Write-Host 'Concurrency' -ForegroundColor Cyan
Test-Scenario -Name '4 connections x 1 iteration' -Arguments @('-Q', 'SELECT 1 AS One', '-n', '4', '-r', '1')
Test-Scenario -Name '4 connections x 2 iterations' -Arguments @('-Q', 'SELECT 1 AS One', '-n', '4', '-r', '2')
Test-Scenario -Name '8 connections x 3 iterations, multi-row' -Arguments @('-Q', 'SELECT TOP 3 ProductID FROM SalesLT.Product ORDER BY ProductID', '-n', '8', '-r', '3')

Write-Host ''
Write-Host 'Batches' -ForegroundColor Cyan
Test-Scenario -Name 'GO-separated batches' -Arguments @('-Q', "SELECT 1 AS A`nGO`nSELECT 2 AS B`nGO`nSELECT 3 AS C")
Test-Scenario -Name 'GO batches under concurrency' -Arguments @('-Q', "SELECT 1 AS A`nGO`nSELECT 2 AS B", '-n', '3', '-r', '2')

Write-Host ''
Write-Host 'Failures' -ForegroundColor Cyan
Test-Scenario -Name 'missing object, single' -Arguments @('-Q', 'SELECT * FROM dbo.NoSuchTableParity')
Test-Scenario -Name 'missing object, 4 connections' -Arguments @('-Q', 'SELECT * FROM dbo.NoSuchTableParity', '-n', '4', '-r', '1')
Test-Scenario -Name 'syntax error' -Arguments @('-Q', 'SELEKT 1')
Test-Scenario -Name 'stop on first error' -Arguments @('-Q', 'SELECT * FROM dbo.NoSuchTableParity', '-n', '4', '-r', '2', '-stoponerror') `
    -ExpectedDifference 'ErrorMessages' `
    -Because 'How many in-flight executions finish before the stop takes effect is a race in both tools. Measured over five runs, sqlsim reported 4 every time and sqlpysim 2 four times and 4 once. Both stop early rather than running all 8, which is what the option promises.'

Write-Host ''
Write-Host 'Output modes' -ForegroundColor Cyan
Test-Scenario -Name 'quiet suppresses rows' -Arguments @('-Q', 'SELECT TOP 5 ProductID FROM SalesLT.Product', '-n', '2', '-r', '2', '-q')
Test-Scenario -Name 'PRINT messages' -Arguments @('-Q', "PRINT 'ManualPrintProbe'; SELECT 1 AS After")
Test-Scenario -Name 'connection test only' -Arguments @()

Write-Host ''
Write-Host 'Workload files' -ForegroundColor Cyan

# Written per scenario so the harness needs no fixtures on disk, and so the
# shapes under test are visible here rather than in another file.
$workloadDirectory = Join-Path ([IO.Path]::GetTempPath()) ("sqlsimtools-parity-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workloadDirectory -Force | Out-Null
try {
    $singleGroup = Join-Path $workloadDirectory 'single-group.json'
    @'
{
    "workloads": [
        { "queries": ["SELECT 1 AS OnlyGroup"], "threads": 2, "iterations": 3 }
    ]
}
'@ | Set-Content -LiteralPath $singleGroup -Encoding UTF8

    $mixedGroups = Join-Path $workloadDirectory 'mixed-groups.json'
    @'
{
    // Three groups at different shapes, one with two batches, so the total
    // depends on every group being expanded correctly. The comment is also
    // part of the test: the format allows them and strict JSON does not.
    "workloads": [
        { "queries": ["SELECT 1 AS GroupOne"], "threads": 3, "iterations": 2 },
        { "queries": ["SELECT 2 AS GroupTwoFirst", "SELECT 3 AS GroupTwoSecond"], "threads": 2, "iterations": 2 },
        { "queries": ["SELECT 4 AS GroupThree"], "threads": 1, "iterations": 5, "think_time_ms": 5 }
    ]
}
'@ | Set-Content -LiteralPath $mixedGroups -Encoding UTF8

    $failingGroup = Join-Path $workloadDirectory 'failing-group.json'
    @'
{
    "workloads": [
        { "queries": ["SELECT * FROM dbo.NoSuchTableParity"], "threads": 2, "iterations": 2 }
    ]
}
'@ | Set-Content -LiteralPath $failingGroup -Encoding UTF8

    $durationMode = Join-Path $workloadDirectory 'duration-mode.json'
    @'
{
    "duration_seconds": 3,
    "workloads": [
        { "queries": ["SELECT 1 AS DurationGroup"], "threads": 2 }
    ]
}
'@ | Set-Content -LiteralPath $durationMode -Encoding UTF8

    Test-Scenario -Name 'single group' -Arguments @('-workload', $singleGroup, '-q')
    Test-Scenario -Name 'mixed groups, differing shapes' -Arguments @('-workload', $mixedGroups, '-q')
    Test-Scenario -Name 'workload group that fails' -Arguments @('-workload', $failingGroup, '-q')
    Test-Scenario -Name 'duration mode' -Arguments @('-workload', $durationMode, '-q') `
        -ExpectedDifference 'ResultSets', 'RowsReported' `
        -Because 'Duration mode runs until a deadline, so how many executions complete depends on per-iteration overhead and cannot match between two different runtimes.'

    # Validation is part of the contract. A bad file should be refused the same
    # way by both tools rather than half-running.
    $noWorkloads = Join-Path $workloadDirectory 'no-workloads.json'
    '{ "duration_seconds": 3 }' | Set-Content -LiteralPath $noWorkloads -Encoding UTF8
    Test-Scenario -Name 'rejects a file with no workloads key' -Arguments @('-workload', $noWorkloads, '-q')

    $bothSources = Join-Path $workloadDirectory 'both-sources.json'
    '{ "workloads": [ { "file": "x.sql", "queries": ["SELECT 1"], "threads": 1, "iterations": 1 } ] }' |
        Set-Content -LiteralPath $bothSources -Encoding UTF8
    Test-Scenario -Name 'rejects a group with both file and queries' -Arguments @('-workload', $bothSources, '-q')

    $zeroThreads = Join-Path $workloadDirectory 'zero-threads.json'
    '{ "workloads": [ { "queries": ["SELECT 1"], "threads": 0, "iterations": 1 } ] }' |
        Set-Content -LiteralPath $zeroThreads -Encoding UTF8
    Test-Scenario -Name 'rejects a group with zero threads' -Arguments @('-workload', $zeroThreads, '-q')

    Test-Scenario -Name 'rejects -Q combined with -workload' -Arguments @('-workload', $singleGroup, '-Q', 'SELECT 1', '-q')
}
finally {
    Remove-Item -LiteralPath $workloadDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

# Live telemetry is a contract with a supervising process rather than a human
# reader, so it is compared on event shape and ordering rather than on text.
function Test-StreamScenario {
    param(
        [string]$Name,
        [string[]]$Arguments,
        [int]$MinimumProgressEvents = 0
    )

    $shared = @('-S', $Server, '-d', $Database) + $script:connectionArgs + $Arguments

    function Read-Stream {
        param([string]$Engine)

        $raw = Invoke-EngineProcess -Engine $Engine -Arguments $shared | Out-String
        $exit = $LASTEXITCODE
        $lines = ($raw -split "`r?`n") | Where-Object { $_.Trim() -ne '' }
        $events = @()
        $unparsed = 0
        foreach ($line in $lines) {
            try { $events += ($line | ConvertFrom-Json) } catch { $unparsed++ }
        }
        $progress = @($events | Where-Object { $_.type -eq 'progress' })
        $completed = @($events | Where-Object { $_.type -eq 'completed' })

        [pscustomobject]@{
            ExitCode       = $exit
            UnparsedLines  = $unparsed
            StartedCount   = @($events | Where-Object { $_.type -eq 'started' }).Count
            CompletedCount = $completed.Count
            FirstType      = if ($events.Count) { $events[0].type } else { '<none>' }
            LastType       = if ($events.Count) { $events[-1].type } else { '<none>' }
            StartedKeys    = (@($events | Where-Object { $_.type -eq 'started' } |
                                ForEach-Object { $_.PSObject.Properties.Name }) -join ',')
            CompletedKeys  = (@($completed | ForEach-Object { $_.PSObject.Properties.Name }) -join ',')
            ProgressKeys   = (@($progress | Select-Object -First 1 |
                                ForEach-Object { $_.PSObject.Properties.Name }) -join ',')
            Status         = if ($completed.Count) { $completed[0].status } else { '<none>' }
            SuccessfulRuns = if ($completed.Count) { $completed[0].successful_executions } else { -1 }
            FailedRuns     = if ($completed.Count) { $completed[0].failed_executions } else { -1 }
            Errors         = if ($completed.Count) { $completed[0].errors } else { -1 }
            EnoughProgress = $progress.Count -ge $MinimumProgressEvents
        }
    }

    $a = Read-Stream -Engine 'sqlsim'
    $b = Read-Stream -Engine 'sqlpysim'

    $fields = 'ExitCode', 'UnparsedLines', 'StartedCount', 'CompletedCount', 'FirstType', 'LastType',
              'StartedKeys', 'CompletedKeys', 'Status', 'SuccessfulRuns', 'FailedRuns',
              'Errors', 'EnoughProgress'
    # Whether a run shorter than the one-second tick emits a progress event at
    # all is a race against the timer, and the two engines lose that race on
    # different runs. Only compare the progress shape where progress is
    # actually expected; the long-running scenario covers it.
    if ($MinimumProgressEvents -gt 0) { $fields += 'ProgressKeys' }
    $unexpected = @()
    foreach ($field in $fields) {
        if ($a.$field -ne $b.$field) {
            $unexpected += "${field}: sqlsim=$($a.$field), sqlpysim=$($b.$field)"
        }
    }

    if ($unexpected.Count -gt 0) {
        Write-Host "  DIFFERS  $Name" -ForegroundColor Red
        foreach ($line in $unexpected) { Write-Host "           $line" -ForegroundColor Red }
        $script:differences++
    } else {
        Write-Host "  match    $Name" -ForegroundColor Green
        $script:matched++
    }

    if ($script:Detailed) {
        Write-Host "           sqlsim  : $($a | ConvertTo-Json -Compress)" -ForegroundColor DarkGray
        Write-Host "           sqlpysim: $($b | ConvertTo-Json -Compress)" -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host 'Live telemetry (-stream-json)' -ForegroundColor Cyan
Test-StreamScenario -Name 'short run emits started and completed' `
    -Arguments @('-Q', 'SELECT 1 AS One', '-stream-json', '-q')
Test-StreamScenario -Name 'a run longer than the tick emits progress' `
    -Arguments @('-Q', "WAITFOR DELAY '00:00:03'; SELECT 1 AS One", '-stream-json', '-q') `
    -MinimumProgressEvents 2
Test-StreamScenario -Name 'a failing run reports error status' `
    -Arguments @('-Q', 'SELECT * FROM dbo.NoSuchTable_ParityProbe', '-n', '1', '-r', '3', '-stream-json', '-q')
Test-StreamScenario -Name 'counters total the work across threads' `
    -Arguments @('-Q', 'SELECT TOP 5 name FROM sys.objects', '-n', '4', '-r', '10', '-stream-json', '-q')
Test-StreamScenario -Name 'rejects -json combined with -stream-json' `
    -Arguments @('-Q', 'SELECT 1', '-json', '-stream-json', '-q')

Write-Host ''
Write-Host 'Periodic query statistics (-querystats-interval)' -ForegroundColor Cyan

# The snapshot is read by a supervising process while the run is in flight, so
# it is compared on structure and status rather than on the numbers, which are
# timing dependent.
function Test-SnapshotScenario {
    param(
        [string]$Name,
        [string[]]$Arguments,
        [int]$ExpectedExecutions = -1
    )

    function Read-Snapshot {
        param([string]$Engine)

        $file = Join-Path ([IO.Path]::GetTempPath()) "parity-snapshot-$Engine.json"
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        $shared = @('-S', $Server, '-d', $Database) + $script:connectionArgs + $Arguments +
                  @('-querystats-file', $file)
        Invoke-EngineProcess -Engine $Engine -Arguments $shared | Out-Null
        $exit = $LASTEXITCODE

        if (-not (Test-Path -LiteralPath $file)) {
            return [pscustomobject]@{ ExitCode = $exit; Exists = $false }
        }
        $snapshot = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue

        $sortedKeys = { param($o) if ($null -eq $o) { '' } else { ($o.PSObject.Properties.Name | Sort-Object) -join ',' } }
        [pscustomobject]@{
            ExitCode        = $exit
            Exists          = $true
            RootKeys        = & $sortedKeys $snapshot
            ConfigKeys      = & $sortedKeys $snapshot.config
            ConnectionKeys  = & $sortedKeys $snapshot.connection_stats
            QueryStatsKeys  = & $sortedKeys $snapshot.query_stats
            QueryKeys       = & $sortedKeys $snapshot.query_stats.queries[0]
            TotalsKeys      = & $sortedKeys $snapshot.query_stats.totals
            MetricKeys      = & $sortedKeys $snapshot.query_stats.queries[0].total_elapsed_ms
            Status          = $snapshot.status
            Threads         = $snapshot.config.threads
            TotalBatches    = $snapshot.config.total_batches
            WorkloadMode    = [bool]$snapshot.config.workload_mode
            Executions      = $snapshot.query_stats.totals.executions
            Failures        = $snapshot.query_stats.totals.failures
            ConnectionCount = $snapshot.connection_stats.count
            ErrorCount      = $snapshot.total_errors
        }
    }

    $a = Read-Snapshot -Engine 'sqlsim'
    $b = Read-Snapshot -Engine 'sqlpysim'

    $fields = 'ExitCode', 'Exists', 'RootKeys', 'ConfigKeys', 'ConnectionKeys', 'QueryStatsKeys',
              'QueryKeys', 'TotalsKeys', 'MetricKeys', 'Status', 'Threads', 'TotalBatches',
              'WorkloadMode', 'Executions', 'Failures', 'ConnectionCount', 'ErrorCount'
    $unexpected = @()
    foreach ($field in $fields) {
        if ($a.$field -ne $b.$field) {
            $unexpected += "${field}: sqlsim=$($a.$field), sqlpysim=$($b.$field)"
        }
    }
    if ($ExpectedExecutions -ge 0 -and $b.Executions -ne $ExpectedExecutions) {
        $unexpected += "Executions: expected $ExpectedExecutions, sqlpysim reported $($b.Executions)"
    }

    if ($unexpected.Count -gt 0) {
        Write-Host "  DIFFERS  $Name" -ForegroundColor Red
        foreach ($line in $unexpected) { Write-Host "           $line" -ForegroundColor Red }
        $script:differences++
    } else {
        Write-Host "  match    $Name" -ForegroundColor Green
        $script:matched++
    }

    if ($script:Detailed) {
        Write-Host "           sqlsim  : $($a | ConvertTo-Json -Compress)" -ForegroundColor DarkGray
        Write-Host "           sqlpysim: $($b | ConvertTo-Json -Compress)" -ForegroundColor DarkGray
    }
}

Test-SnapshotScenario -Name 'snapshot shape and final totals' `
    -Arguments @('-Q', 'SELECT TOP 20 ProductID FROM SalesLT.Product', '-n', '2', '-r', '10',
                 '-querystats-interval', '1', '-q') `
    -ExpectedExecutions 20
Test-SnapshotScenario -Name 'snapshot records failures' `
    -Arguments @('-Q', 'SELECT * FROM dbo.NoSuchTable_SnapshotProbe', '-n', '1', '-r', '3',
                 '-querystats-interval', '1', '-q')
Test-SnapshotScenario -Name 'snapshot alongside a live stream' `
    -Arguments @('-Q', 'SELECT TOP 20 ProductID FROM SalesLT.Product', '-n', '2', '-r', '10',
                 '-querystats-interval', '1', '-stream-json', '-q') `
    -ExpectedExecutions 20

# The failure path is where the two engines drifted apart once already, because
# nothing here exercised it. An unwritable path must behave identically: the
# run survives, the warning appears once, and machine-readable output stays
# clean.
function Test-SnapshotFailureScenario {
    param(
        [string]$Name,
        [string[]]$Arguments
    )

    $unwritable = Join-Path ([IO.Path]::GetTempPath()) 'parity-no-such-directory\snapshot.json'

    function Read-Failure {
        param([string]$Engine)

        $shared = @('-S', $Server, '-d', $Database) + $script:connectionArgs + $Arguments +
                  @('-querystats-file', $unwritable)
        $raw = Invoke-EngineProcess -Engine $Engine -Arguments $shared | Out-String
        $exit = $LASTEXITCODE
        $lines = @(($raw -split "`r?`n") | Where-Object { $_.Trim() -ne '' })

        [pscustomobject]@{
            ExitCode      = $exit
            Warnings      = @($lines | Where-Object { $_ -match 'could not write the query statistics snapshot' }).Count
            FileCreated   = Test-Path -LiteralPath $unwritable
            # A stream run must stay parseable even while snapshots are failing.
            NonEventLines = if ($Arguments -contains '-stream-json') {
                                @($lines | Where-Object { $_ -notmatch '^\{"type"' }).Count
                            } else { 0 }
        }
    }

    $a = Read-Failure -Engine 'sqlsim'
    $b = Read-Failure -Engine 'sqlpysim'

    $unexpected = @()
    foreach ($field in 'ExitCode', 'Warnings', 'FileCreated', 'NonEventLines') {
        if ($a.$field -ne $b.$field) {
            $unexpected += "${field}: sqlsim=$($a.$field), sqlpysim=$($b.$field)"
        }
    }

    if ($unexpected.Count -gt 0) {
        Write-Host "  DIFFERS  $Name" -ForegroundColor Red
        foreach ($line in $unexpected) { Write-Host "           $line" -ForegroundColor Red }
        $script:differences++
    } else {
        Write-Host "  match    $Name" -ForegroundColor Green
        $script:matched++
    }

    if ($script:Detailed) {
        Write-Host "           sqlsim  : $($a | ConvertTo-Json -Compress)" -ForegroundColor DarkGray
        Write-Host "           sqlpysim: $($b | ConvertTo-Json -Compress)" -ForegroundColor DarkGray
    }
}

Test-SnapshotFailureScenario -Name 'an unwritable path warns once and the run survives' `
    -Arguments @('-Q', 'SELECT 1 AS SnapshotFailureProbe', '-n', '1', '-r', '2',
                 '-querystats-interval', '1', '-q')
Test-SnapshotFailureScenario -Name 'an unwritable path leaves a stream parseable' `
    -Arguments @('-Q', 'SELECT 1 AS SnapshotFailureStream', '-n', '1', '-r', '2',
                 '-querystats-interval', '1', '-stream-json', '-q')

Test-Scenario -Name 'rejects a zero interval' `
    -Arguments @('-Q', 'SELECT 1', '-querystats-interval', '0', '-q')
Test-Scenario -Name 'rejects a non-numeric interval' `
    -Arguments @('-Q', 'SELECT 1', '-querystats-interval', 'soon', '-q')

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host "Matched:    $script:matched" -ForegroundColor Green
Write-Host "Known:      $script:known" -ForegroundColor Yellow
Write-Host "Differing:  $script:differences" -ForegroundColor $(if ($script:differences -eq 0) { 'Green' } else { 'Red' })
Write-Host '========================================' -ForegroundColor Cyan

if ($script:differences -gt 0) {
    Write-Host ''
    Write-Host 'Undeclared differences found. Either fix the engine, or record the' -ForegroundColor Red
    Write-Host 'difference in RELEASE-NOTES.md and declare it here with' -ForegroundColor Red
    Write-Host '-ExpectedDifference so it is a decision rather than a surprise.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'No undeclared differences.' -ForegroundColor Green
exit 0
