<#
.SYNOPSIS
    Generates an HTML A/B comparison report from two sqlsim JSON result files.

.DESCRIPTION
    Compares a baseline run against a candidate run and reports the measured
    change in throughput, runtime, execution time, connection time, and errors.

    Accepts either two sqlsim or sqlpysim result files produced by -json, or a
    single comparison bundle exported from the sqlsim Studio Compare view.

    The report includes a configuration guardrail. A performance delta between
    two runs that used different targets, engines, workloads, load shapes, telemetry,
    query-statistics settings, or execution options is not a result, and the
    report says so rather than presenting a misleading number. ODBC driver and
    SQL Server version differences are shown but do not block the comparison,
    because they are often the change under test.

    Metrics match sqlsim Studio Compare: throughput uses execution elapsed time,
    average execution uses total query time divided by executions, and Replay
    uses the number of replayed events.

.PARAMETER BaselineFile
    Path to the baseline sqlsim JSON result file (the "A" run).

.PARAMETER CandidateFile
    Path to the candidate sqlsim JSON result file (the "B" run).

.PARAMETER ComparisonFile
    Path to a comparison bundle exported by sqlsim Studio. Mutually exclusive
    with -BaselineFile and -CandidateFile.

.PARAMETER LabelA
    Display label for the baseline run. Defaults to the file name.

.PARAMETER LabelB
    Display label for the candidate run. Defaults to the file name.

.PARAMETER Threshold
    Percentage change treated as noise rather than a real difference.
    Defaults to 2.0.

.PARAMETER OutputFile
    Destination HTML file. Defaults to comparison-report.html.

.PARAMETER Csv
    Optional path for a CSV of the same metrics, for spreadsheets or CI.

.PARAMETER NoOpen
    Do not open the report in the default browser.

.EXAMPLE
    .\comparison-report.ps1 -BaselineFile before.json -CandidateFile after.json

.EXAMPLE
    .\comparison-report.ps1 -ComparisonFile sqlsim-comparison-20260925.json

.EXAMPLE
    .\comparison-report.ps1 -BaselineFile sql2022.json -CandidateFile sql2025.json `
        -LabelA "SQL 2022" -LabelB "SQL 2025" -Csv upgrade.csv
#>

param(
    [Alias('ResultA')]
    [string]$BaselineFile,

    [Alias('ResultB')]
    [string]$CandidateFile,

    [string]$ComparisonFile,
    [string]$LabelA,
    [string]$LabelB,
    [double]$Threshold = 2.0,
    [Alias('Report')]
    [string]$OutputFile = "comparison-report.html",
    [string]$Csv = "",
    [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'

function ConvertTo-HtmlText {
    param($Value)
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function ConvertTo-ReportNumber {
    param($Value)
    $number = 0.0
    $parsed = [double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$number)
    if ($parsed -and -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number)) { return $number }
    return 0.0
}

Write-Host "sqlsim Comparison Report Generator" -ForegroundColor Cyan
Write-Host ""

# --- Resolve input ---

function Read-JsonFile {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "Error: $Label not found: $Path" -ForegroundColor Red
        exit 1
    }
    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        Write-Host "Error: Failed to parse $Label as JSON" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor DarkRed
        exit 1
    }
}

if ($ComparisonFile) {
    if ($BaselineFile -or $CandidateFile) {
        Write-Host "Error: -ComparisonFile cannot be combined with -BaselineFile or -CandidateFile." -ForegroundColor Red
        exit 1
    }
    Write-Host "Reading comparison bundle: $ComparisonFile"
    $bundle = Read-JsonFile -Path $ComparisonFile -Label 'Comparison bundle'
    if (-not $bundle.baseline.result -or -not $bundle.candidate.result) {
        Write-Host "Error: Bundle does not contain baseline.result and candidate.result." -ForegroundColor Red
        exit 1
    }
    $baseline = $bundle.baseline.result
    $candidate = $bundle.candidate.result
    $baselineLabel = if ($LabelA) { $LabelA } elseif ($bundle.baseline.label) { $bundle.baseline.label } else { 'Baseline' }
    $candidateLabel = if ($LabelB) { $LabelB } elseif ($bundle.candidate.label) { $bundle.candidate.label } else { 'Candidate' }
} elseif ($BaselineFile -and $CandidateFile) {
    Write-Host "Reading baseline:  $BaselineFile"
    $baseline = Read-JsonFile -Path $BaselineFile -Label 'Baseline file'
    Write-Host "Reading candidate: $CandidateFile"
    $candidate = Read-JsonFile -Path $CandidateFile -Label 'Candidate file'
    $baselineLabel = if ($LabelA) { $LabelA } else { Split-Path $BaselineFile -Leaf }
    $candidateLabel = if ($LabelB) { $LabelB } else { Split-Path $CandidateFile -Leaf }
} else {
    Write-Host "Usage: Provide -BaselineFile and -CandidateFile, or -ComparisonFile."
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  .\comparison-report.ps1 -BaselineFile before.json -CandidateFile after.json"
    Write-Host "  .\comparison-report.ps1 -ComparisonFile sqlsim-comparison-20260925.json"
    exit 1
}

# --- Extract comparable metrics ---

# Metric and guardrail definitions match sqlsim Studio Compare.
function Get-WorkloadIdentity {
    param($Data)
    $config = $Data.configuration
    if ($config.replay_mode) {
        $capture = if ($Data.replay_capture -and $Data.replay_capture.queries) {
            @($Data.replay_capture.queries | ForEach-Object {
                [ordered]@{
                    eventType = $_.event_type; query = $_.query; executions = $_.executions
                    sessions = $_.sessions; capturedSpids = @($_.captured_spids); databases = @($_.databases)
                }
            })
        } else { $null }
        return [ordered]@{
            replayMode = $config.replay_mode; totalEvents = $config.replay_total_events
            replayableEvents = $config.replay_replayable_events; skippedEvents = $config.replay_skipped_events
            sessions = $config.replay_sessions; capture = $capture
        }
    }
    if ($config.workloads) {
        return @($config.workloads | ForEach-Object {
            [ordered]@{
                threads = $_.threads; iterations = $_.iterations; durationSeconds = $_.duration_seconds
                thinkTimeMs = $(if ($_.think_time_ms) { $_.think_time_ms } else { 0 }); batches = @($_.batches)
            }
        })
    }
    return [ordered]@{ batches = @($config.batches) }
}

function Get-ExecutionOptions {
    param($Config)
    $option = { param($Name, $Default) if ($null -ne $Config.$Name) { $Config.$Name } else { $Default } }
    return [ordered]@{
        authentication = & $option 'authentication' $null
        applicationName = & $option 'application_name' $null
        preparedStatements = & $option 'prepared_statements' $false
        reconnectPerIteration = & $option 'reconnect_per_iteration' $false
        connectionPooling = & $option 'connection_pooling' $false
        rampBatchSize = & $option 'ramp_batch_size' 0
        rampDelayMs = & $option 'ramp_delay_ms' 0
        stopOnError = & $option 'stop_on_error' $false
        loginTimeout = & $option 'login_timeout' 0
        queryTimeout = & $option 'query_timeout' 0
        retryCount = & $option 'retry_count' 1
        retryDelay = & $option 'retry_delay' 10
        encryption = & $option 'encryption' $null
        trustServerCertificate = & $option 'trust_server_certificate' $false
        certificateHostname = & $option 'certificate_hostname' $null
        readOnlyIntent = & $option 'read_only_intent' $false
        multiSubnetFailover = & $option 'multi_subnet_failover' $false
        quiet = & $option 'quiet_mode' $false
    }
}

function Get-Fingerprint {
    param($Value)
    $json = $Value | ConvertTo-Json -Depth 10 -Compress
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($json))
    return ([BitConverter]::ToString($hash) -replace '-', '').Substring(0, 12).ToLowerInvariant()
}

function Get-RunSummary {
    param($Data, [string]$StatisticsSource, [string]$Telemetry)

    $config = $Data.configuration
    $metrics = $Data.metrics
    $executions = if ($config.replay_mode) {
        if ($Data.replay_summary -and $Data.replay_summary.result) { ConvertTo-ReportNumber $Data.replay_summary.result.events } else { 0.0 }
    } else { ConvertTo-ReportNumber $config.total_batches }
    $runtime = ConvertTo-ReportNumber $metrics.total_runtime_seconds

    # Matches execution-report.ps1 so both reports agree on throughput.
    $elapsed = if ($Data.execution_elapsed_seconds) {
        ConvertTo-ReportNumber $Data.execution_elapsed_seconds
    } else {
        $runtime
    }

    $avgConnect = if ($metrics.connection_operations -and $metrics.connection_operations.avg_connect_time_ms) {
        ConvertTo-ReportNumber $metrics.connection_operations.avg_connect_time_ms
    } elseif ($Data.connection_stats -and (ConvertTo-ReportNumber $Data.connection_stats.count) -gt 0) {
        ConvertTo-ReportNumber $Data.connection_stats.avg_ms
    } else { 0.0 }

    $avgElapsed = if ($executions -gt 0 -and $null -ne $metrics.total_query_execution_time_seconds) {
        (ConvertTo-ReportNumber $metrics.total_query_execution_time_seconds) * 1000 / $executions
    } elseif ($metrics.query_execution_operations -and $metrics.query_execution_operations.avg_elapsed_ms) {
        ConvertTo-ReportNumber $metrics.query_execution_operations.avg_elapsed_ms
    } else { 0.0 }

    $isWorkload = $null -ne $config.workloads -or $null -ne $config.workload_file
    $mode = if ($config.replay_mode) { "Replay ($($config.replay_mode))" } elseif ($isWorkload) { 'Mixed workload' } elseif ($config.input_file) { 'SQL file' } else { 'Query' }
    $statistics = if ($StatisticsSource) { $StatisticsSource } elseif ($config.query_stats) { 'runtime' } else { 'none' }
    $telemetryMode = if ($Telemetry -in @('live', 'final')) { $Telemetry } elseif ($config.stream_json -eq $true) { 'live' } else { 'final' }

    return [pscustomobject]@{
        Server        = $config.server
        Database      = $config.database
        Engine        = if ($config.odbc_driver -eq 'mssql-python') { 'sqlpysim' } else { 'sqlsim' }
        Threads       = [string]$config.threads
        Iterations    = if ($null -ne $config.iterations_per_thread) { [string]$config.iterations_per_thread } else { 'per group' }
        Executions    = $executions
        WorkloadMode  = $mode
        Workload      = Get-Fingerprint (Get-WorkloadIdentity -Data $Data)
        Options       = Get-Fingerprint (Get-ExecutionOptions -Config $config)
        Statistics    = $statistics
        Telemetry     = if ($telemetryMode -eq 'live') { 'Live progress' } else { 'Final results only' }
        Runtime       = $runtime
        Elapsed       = $elapsed
        Throughput    = if ($elapsed -gt 0 -and $executions -gt 0) { $executions / $elapsed } else { 0.0 }
        AvgElapsedMs  = $avgElapsed
        AvgConnectMs  = $avgConnect
        Errors        = $(if ($metrics.errors) { ConvertTo-ReportNumber $metrics.errors.total } else { 0.0 })
        Warnings      = $(if ($metrics.warnings) { ConvertTo-ReportNumber $metrics.warnings.total } else { 0.0 })
        ServerVersion = if ($Data.server_version) { $Data.server_version } else { 'Not recorded' }
        Edition       = if ($Data.server_edition) { $Data.server_edition } else { 'Not recorded' }
        EngineVersion = if ($Data.version) { $Data.version } else { 'Not recorded' }
        Reconnect     = $config.reconnect_per_iteration -eq $true
        OdbcDriver    = if ($metrics.odbc_driver_version) { $metrics.odbc_driver_version } elseif ($config.odbc_driver) { $config.odbc_driver } else { 'Not recorded' }
        StartTime     = $Data.start_time
        Success       = $Data.success
        QueryStats    = $null -ne $Data.query_stats
    }
}

$baselineStatistics = if ($bundle) { $bundle.baseline.statisticsSource } else { $null }
$candidateStatistics = if ($bundle) { $bundle.candidate.statisticsSource } else { $null }
$baselineTelemetry = if ($bundle) { $bundle.baseline.telemetry } else { $null }
$candidateTelemetry = if ($bundle) { $bundle.candidate.telemetry } else { $null }
$a = Get-RunSummary -Data $baseline -StatisticsSource $baselineStatistics -Telemetry $baselineTelemetry
$b = Get-RunSummary -Data $candidate -StatisticsSource $candidateStatistics -Telemetry $candidateTelemetry

# --- Compute deltas ---

function New-Delta {
    param(
        [string]$Name,
        [double]$BaselineValue,
        [double]$CandidateValue,
        [ValidateSet('higher', 'lower')][string]$Better,
        [string]$Unit,
        [int]$Decimals = 2
    )

    $change = if ($BaselineValue -ne 0) {
        (($CandidateValue - $BaselineValue) / [Math]::Abs($BaselineValue)) * 100
    } elseif ($CandidateValue -eq 0) { 0.0 } else { [double]::PositiveInfinity }

    $verdict = if ([double]::IsInfinity($change)) {
        if ($Better -eq 'lower') { 'regressed' } else { 'improved' }
    } elseif ([Math]::Abs($change) -lt $Threshold) {
        'unchanged'
    } elseif (($Better -eq 'higher' -and $change -gt 0) -or ($Better -eq 'lower' -and $change -lt 0)) {
        'improved'
    } else {
        'regressed'
    }

    return [pscustomobject]@{
        Name      = $Name
        Baseline  = $BaselineValue
        Candidate = $CandidateValue
        Change    = $change
        Verdict   = $verdict
        Better    = $Better
        Unit      = $Unit
        Decimals  = $Decimals
    }
}

$deltas = @(
    New-Delta -Name 'Throughput'      -BaselineValue $a.Throughput   -CandidateValue $b.Throughput   -Better higher -Unit 'exec/sec' -Decimals 1
    New-Delta -Name 'Total duration'  -BaselineValue $a.Runtime      -CandidateValue $b.Runtime      -Better lower  -Unit 'sec'      -Decimals 3
    New-Delta -Name 'Avg execution'   -BaselineValue $a.AvgElapsedMs -CandidateValue $b.AvgElapsedMs -Better lower  -Unit 'ms'       -Decimals 3
    New-Delta -Name 'Avg connection'  -BaselineValue $a.AvgConnectMs -CandidateValue $b.AvgConnectMs -Better lower  -Unit 'ms'       -Decimals 2
    New-Delta -Name 'Errors'          -BaselineValue $a.Errors       -CandidateValue $b.Errors       -Better lower  -Unit ''         -Decimals 0
)

# Without -reconnect, connection time is one-time setup cost and only adds noise.
if (-not ($a.Reconnect -and $b.Reconnect)) {
    ($deltas | Where-Object { $_.Name -eq 'Avg connection' }).Verdict = 'not in verdict'
}

$improved = @($deltas | Where-Object { $_.Verdict -eq 'improved' }).Count
$unchanged = @($deltas | Where-Object { $_.Verdict -eq 'unchanged' }).Count
$regressed = @($deltas | Where-Object { $_.Verdict -eq 'regressed' }).Count

# --- Configuration guardrail ---

$guardrails = @(
    [pscustomobject]@{ Setting = 'Server';            A = $a.Server;       B = $b.Server;       Informational = $false }
    [pscustomobject]@{ Setting = 'Database';          A = $a.Database;     B = $b.Database;     Informational = $false }
    [pscustomobject]@{ Setting = 'Engine';            A = $a.Engine;       B = $b.Engine;       Informational = $false }
    [pscustomobject]@{ Setting = 'Workload mode';     A = $a.WorkloadMode; B = $b.WorkloadMode; Informational = $false }
    [pscustomobject]@{ Setting = 'Workload checksum'; A = $a.Workload;     B = $b.Workload;     Informational = $false }
    [pscustomobject]@{ Setting = 'Connections';       A = $a.Threads;      B = $b.Threads;      Informational = $false }
    [pscustomobject]@{ Setting = 'Iterations';        A = $a.Iterations;   B = $b.Iterations;   Informational = $false }
    [pscustomobject]@{ Setting = 'Total executions';  A = "{0:N0}" -f $a.Executions; B = "{0:N0}" -f $b.Executions; Informational = $false }
    [pscustomobject]@{ Setting = 'Query statistics';  A = $a.Statistics;   B = $b.Statistics;   Informational = $false }
    [pscustomobject]@{ Setting = 'Telemetry';         A = $a.Telemetry;    B = $b.Telemetry;    Informational = $false }
    [pscustomobject]@{ Setting = 'Execution options'; A = $a.Options;      B = $b.Options;      Informational = $false }
    [pscustomobject]@{ Setting = 'Engine version';    A = $a.EngineVersion; B = $b.EngineVersion; Informational = $true }
    [pscustomobject]@{ Setting = 'ODBC driver';       A = $a.OdbcDriver;   B = $b.OdbcDriver;   Informational = $true }
    [pscustomobject]@{ Setting = 'SQL Server version'; A = $a.ServerVersion; B = $b.ServerVersion; Informational = $true }
    [pscustomobject]@{ Setting = 'SQL Server edition'; A = $a.Edition;     B = $b.Edition;      Informational = $true }
)
$mismatches = @($guardrails | Where-Object { -not $_.Informational -and [string]$_.A -ne [string]$_.B })
$informationalDifferences = @($guardrails | Where-Object { $_.Informational -and [string]$_.A -ne [string]$_.B })
$comparable = $mismatches.Count -eq 0

# --- Build HTML fragments ---

function Format-Value {
    param([double]$Value, [int]$Decimals, [string]$Unit)
    $number = if ([double]::IsInfinity($Value)) { '--' } else { "{0:N$Decimals}" -f $Value }
    if ($Unit) { "$number <span class='unit'>$Unit</span>" } else { $number }
}

function Format-Change {
    param($Delta)
    if ([double]::IsInfinity($Delta.Change)) { return 'n/a' }
    $sign = if ($Delta.Change -gt 0) { '+' } else { '' }
    return "$sign{0:N1}%" -f $Delta.Change
}

$deltaCards = ($deltas | ForEach-Object {
    $cls = switch ($_.Verdict) {
        'improved'  { 'verdict-improved' }
        'regressed' { 'verdict-regressed' }
        default     { 'verdict-unchanged' }
    }
    $hint = if ($_.Verdict -eq 'not in verdict') { 'not in verdict' } elseif ($_.Better -eq 'higher') { 'higher is better' } else { 'lower is better' }
    @"
        <div class="delta-card $cls">
            <div class="delta-name">$($_.Name)</div>
            <div class="delta-change">$(Format-Change -Delta $_)</div>
            <div class="delta-hint">$hint</div>
            <div class="delta-values">
                <span>$(Format-Value -Value $_.Baseline -Decimals $_.Decimals -Unit $_.Unit)</span>
                <span class="arrow">&rarr;</span>
                <span>$(Format-Value -Value $_.Candidate -Decimals $_.Decimals -Unit $_.Unit)</span>
            </div>
        </div>
"@
}) -join "`n"

$metricRows = ($deltas | ForEach-Object {
    $cls = switch ($_.Verdict) {
        'improved'  { 'cell-improved' }
        'regressed' { 'cell-regressed' }
        default     { 'cell-unchanged' }
    }
    @"
            <tr>
                <td>$($_.Name)</td>
                <td class="num">$(Format-Value -Value $_.Baseline -Decimals $_.Decimals -Unit $_.Unit)</td>
                <td class="num">$(Format-Value -Value $_.Candidate -Decimals $_.Decimals -Unit $_.Unit)</td>
                <td class="num $cls">$(Format-Change -Delta $_)</td>
                <td class="$cls">$($_.Verdict)</td>
            </tr>
"@
}) -join "`n"

$guardrailRows = ($guardrails | ForEach-Object {
    $match = [string]$_.A -eq [string]$_.B
    $cls = if ($match) { 'cell-unchanged' } elseif ($_.Informational) { 'cell-info' } else { 'cell-regressed' }
    $status = if ($match) { 'Match' } elseif ($_.Informational) { 'Differs (informational)' } else { 'Differs' }
    @"
            <tr>
                <td>$($_.Setting)</td>
                <td class="mono">$(ConvertTo-HtmlText $_.A)</td>
                <td class="mono">$(ConvertTo-HtmlText $_.B)</td>
                <td class="$cls">$status</td>
            </tr>
"@
}) -join "`n"

if ($comparable) {
    $informationalNote = if ($informationalDifferences.Count -gt 0) {
        " $((($informationalDifferences | ForEach-Object { $_.Setting }) -join ' and ')) differ; that may be the change under test."
    } else { '' }
    $guardBanner = @"
        <div class="alert alert-ok">
            <strong>Configurations match.</strong>
            Both runs used the same target, engine, workload, load shape, query statistics, telemetry, and execution options, so the measured differences are attributable to the change under test.$informationalNote
        </div>
"@
} else {
    $mismatchNames = ($mismatches | ForEach-Object { $_.Setting }) -join ', '
    $guardBanner = @"
        <div class="alert alert-warn">
            <strong>Configurations differ: $mismatchNames.</strong>
            These runs are not directly comparable. A throughput or timing difference here may reflect the configuration change rather than the change under test. Review the configuration table before drawing a conclusion.
        </div>
"@
}

$verdictText = if (-not $comparable) {
    'Not comparable'
} elseif ($regressed -gt 0 -and $improved -eq 0) {
    'Candidate regressed'
} elseif ($improved -gt 0 -and $regressed -eq 0) {
    'Candidate improved'
} elseif ($improved -gt 0 -and $regressed -gt 0) {
    'Mixed result'
} else {
    'No measurable change'
}

$generated = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

# --- Per-query comparison ---

function Get-QueryIndex {
    param($Data)
    # Ordinal keys match Studio, which treats SQL text case-sensitively.
    $index = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
    if ($Data.query_stats -and $Data.query_stats.queries) {
        foreach ($query in @($Data.query_stats.queries)) {
            $key = (([string]$query.query) -replace '\s+', ' ').Trim()
            if ($key -and -not $index.Contains($key)) { $index[$key] = $query }
        }
    }
    return $index
}

function Format-QueryDelta {
    param($BaselineValue, $CandidateValue, [int]$Decimals, [string]$Unit, [switch]$Informational)
    $format = {
        param($Value)
        if ($null -eq $Value) { return '&mdash;' }
        $text = "{0:N$Decimals}" -f $Value
        if ($Unit) { "$text $Unit" } else { $text }
    }
    $values = "$(& $format $BaselineValue) &rarr; $(& $format $CandidateValue)"
    if ($null -eq $BaselineValue -or $null -eq $CandidateValue) {
        $label = if ($null -eq $BaselineValue) { 'Only in B' } else { 'Only in A' }
        return "<td class=`"num`">$values<div class=`"cell-unchanged`">$label</div></td>"
    }
    $delta = New-Delta -Name 'Query' -BaselineValue $BaselineValue -CandidateValue $CandidateValue -Better lower -Unit $Unit -Decimals $Decimals
    $cls = if ($Informational) { 'cell-unchanged' } else {
        switch ($delta.Verdict) { 'improved' { 'cell-improved' } 'regressed' { 'cell-regressed' } default { 'cell-unchanged' } }
    }
    return "<td class=`"num`">$values<div class=`"$cls`">$(Format-Change -Delta $delta)</div></td>"
}

$baselineQueries = Get-QueryIndex -Data $baseline
$candidateQueries = Get-QueryIndex -Data $candidate
if ($baselineQueries.Count -gt 0 -and $candidateQueries.Count -gt 0) {
    $queryWeight = { param($Query) if ($null -eq $Query) { 0.0 } else { (ConvertTo-ReportNumber $Query.total_elapsed_ms.avg) * (ConvertTo-ReportNumber $Query.executions) } }
    $queryKeys = New-Object System.Collections.Generic.List[string]
    foreach ($key in @($baselineQueries.Keys) + @($candidateQueries.Keys)) { if (-not $queryKeys.Contains($key)) { $queryKeys.Add($key) } }
    $sortedKeys = $queryKeys | Sort-Object -Descending -Property @{ Expression = {
        [Math]::Max((& $queryWeight $baselineQueries[$_]), (& $queryWeight $candidateQueries[$_]))
    } }
    $queryNumber = 0
    $queryRows = ($sortedKeys | ForEach-Object {
        $queryNumber++
        $queryA = $baselineQueries[$_]
        $queryB = $candidateQueries[$_]
        $read = { param($Query, $Value) if ($null -eq $Query) { $null } else { ConvertTo-ReportNumber (& $Value $Query) } }
        $encodedQuery = ConvertTo-HtmlText $_
        @"
            <tr>
                <td><strong>Query $queryNumber</strong><div class="query-text" title="$encodedQuery">$encodedQuery</div></td>
                $(Format-QueryDelta (& $read $queryA { param($q) $q.executions }) (& $read $queryB { param($q) $q.executions }) -Decimals 0 -Informational)
                $(Format-QueryDelta (& $read $queryA { param($q) $q.total_elapsed_ms.avg }) (& $read $queryB { param($q) $q.total_elapsed_ms.avg }) -Decimals 3 -Unit 'ms')
                $(Format-QueryDelta (& $read $queryA { param($q) $q.server_cpu_ms.avg }) (& $read $queryB { param($q) $q.server_cpu_ms.avg }) -Decimals 3 -Unit 'ms')
                $(Format-QueryDelta (& $read $queryA { param($q) $q.logical_reads.avg }) (& $read $queryB { param($q) $q.logical_reads.avg }) -Decimals 1)
                $(Format-QueryDelta (& $read $queryA { param($q) $q.failures }) (& $read $queryB { param($q) $q.failures }) -Decimals 0)
            </tr>
"@
    }) -join "`n"
    $queryComparisonHtml = @"
    <div class="section">
        <h3>Per-query comparison</h3>
        <p class="section-note">Queries matched by SQL text. Changes within &plusmn;$Threshold% are treated as unchanged.</p>
        <table class="query-table">
            <thead><tr><th>Query</th><th class="num">Executions</th><th class="num">Avg elapsed</th><th class="num">Avg CPU</th><th class="num">Logical reads</th><th class="num">Failures</th></tr></thead>
            <tbody>
$queryRows
            </tbody>
        </table>
    </div>
"@
} else {
    $queryComparisonHtml = @"
    <div class="section">
        <h3>Per-query comparison</h3>
        <p class="section-note">Collect per-query statistics with -querystats in both runs to compare individual queries.</p>
    </div>
"@
}

# Naming only the baseline target would misrepresent a pair that ran against different targets.
$targetLabel = if ($a.Server -eq $b.Server -and $a.Database -eq $b.Database) {
    "$(ConvertTo-HtmlText $a.Database) on $(ConvertTo-HtmlText $a.Server)"
} else {
    "$(ConvertTo-HtmlText $a.Database) on $(ConvertTo-HtmlText $a.Server) &rarr; $(ConvertTo-HtmlText $b.Database) on $(ConvertTo-HtmlText $b.Server)"
}
$errorNote = if ($a.Errors -gt 0 -or $b.Errors -gt 0) {
    "<div class=`"alert alert-warn`"><strong>Errors present.</strong> Baseline recorded $([int]$a.Errors) error(s); candidate recorded $([int]$b.Errors). Timing from a run with errors may not represent a complete workload.</div>"
} else { '' }

# --- Generate HTML ---

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>sqlsim Comparison Report</title>
<style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, sans-serif; background: #f6f8fa; color: #1f2328; padding: 16px; line-height: 1.4; }
    .container { max-width: 1200px; margin: 0 auto; }
    .header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px; padding-bottom: 8px; border-bottom: 1px solid #d0d7de; }
    .header h1 { font-size: 16px; font-weight: 600; color: #0969da; }
    .header h1 span { color: #656d76; font-weight: 400; font-size: 13px; }
    .badge { display: inline-block; padding: 3px 12px; border-radius: 20px; font-size: 12px; font-weight: 600; }
    .badge-improved { background: #1a7f37; color: #fff; }
    .badge-regressed { background: #cf222e; color: #fff; }
    .badge-mixed { background: #d4a017; color: #fff; }
    .badge-neutral { background: #656d76; color: #fff; }
    .runs { display: flex; gap: 8px; margin-bottom: 10px; font-size: 11px; color: #656d76; }
    .runs div { flex: 1; background: #fff; border: 1px solid #d0d7de; border-radius: 6px; padding: 8px 12px; }
    .runs .tag { font-weight: 700; color: #0969da; text-transform: uppercase; font-size: 10px; letter-spacing: .4px; }
    .runs .name { color: #1f2328; font-size: 12px; word-break: break-all; }
    .alert { border-radius: 6px; padding: 10px 14px; margin-bottom: 10px; font-size: 12px; }
    .alert-ok { background: #eaf6ec; border: 1px solid #a3d3af; color: #1a5c2a; }
    .alert-warn { background: #fefce8; border: 1px solid #fde68a; color: #854d0e; }
    .delta-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(165px, 1fr)); gap: 8px; margin-bottom: 10px; }
    .delta-card { background: #fff; border: 1px solid #d0d7de; border-top-width: 3px; border-radius: 6px; padding: 8px 12px; }
    .verdict-improved { border-top-color: #1a7f37; }
    .verdict-regressed { border-top-color: #cf222e; }
    .verdict-unchanged { border-top-color: #8b949e; }
    .delta-name { font-size: 10px; color: #656d76; text-transform: uppercase; letter-spacing: .5px; }
    .delta-change { font-size: 20px; font-weight: 700; font-variant-numeric: tabular-nums; }
    .verdict-improved .delta-change { color: #1a7f37; }
    .verdict-regressed .delta-change { color: #cf222e; }
    .verdict-unchanged .delta-change { color: #656d76; }
    .delta-hint { font-size: 10px; color: #8b949e; }
    .delta-values { font-size: 11px; color: #656d76; margin-top: 4px; font-variant-numeric: tabular-nums; }
    .delta-values .arrow { margin: 0 4px; color: #8b949e; }
    .delta-values .unit { font-size: 10px; }
    .section { background: #fff; border: 1px solid #d0d7de; border-radius: 6px; padding: 14px; margin-bottom: 10px; }
    .section h3 { font-size: 14px; font-weight: 600; margin-bottom: 10px; }
    table { width: 100%; border-collapse: collapse; font-size: 12px; }
    th { text-align: left; font-size: 10px; text-transform: uppercase; letter-spacing: .5px; color: #656d76; padding: 6px 8px; border-bottom: 2px solid #d0d7de; }
    td { padding: 6px 8px; border-bottom: 1px solid #eaeef2; }
    .num { text-align: right; font-variant-numeric: tabular-nums; font-family: "Cascadia Code","Consolas",monospace; }
    .mono { font-family: "Cascadia Code","Consolas",monospace; font-size: 11px; }
    .unit { color: #8b949e; }
    .cell-improved { color: #1a7f37; font-weight: 600; }
    .cell-regressed { color: #cf222e; font-weight: 600; }
    .cell-unchanged { color: #656d76; }
    .cell-info { color: #9a6700; font-weight: 600; }
    .section-note { margin: -4px 0 10px; color: #656d76; font-size: 11px; }
    .query-table td { vertical-align: top; }
    .query-text { max-width: 420px; overflow: hidden; color: #656d76; font-family: "Cascadia Code","Consolas",monospace; font-size: 11px; text-overflow: ellipsis; white-space: nowrap; }
    .tally { display: flex; gap: 16px; font-size: 12px; margin-top: 8px; }
    .tally b { font-variant-numeric: tabular-nums; }
    footer { color: #8b949e; font-size: 11px; margin-top: 12px; }
</style>
</head>
<body>
<div class="container">
    <div class="header">
        <h1>sqlsim A/B Comparison <span>&middot; $targetLabel</span></h1>
        <span class="badge $(switch ($verdictText) {
            'Candidate improved' { 'badge-improved' }
            'Candidate regressed' { 'badge-regressed' }
            'Mixed result' { 'badge-mixed' }
            default { 'badge-neutral' }
        })">$verdictText</span>
    </div>

    <div class="runs">
        <div><span class="tag">A &middot; Baseline</span><div class="name">$(ConvertTo-HtmlText $baselineLabel)</div><div>Started $(ConvertTo-HtmlText $a.StartTime)</div></div>
        <div><span class="tag">B &middot; Candidate</span><div class="name">$(ConvertTo-HtmlText $candidateLabel)</div><div>Started $(ConvertTo-HtmlText $b.StartTime)</div></div>
    </div>

$guardBanner
$errorNote

    <div class="delta-grid">
$deltaCards
    </div>

    <div class="section">
        <h3>Metric detail</h3>
        <table>
            <thead><tr><th>Metric</th><th class="num">A &middot; Baseline</th><th class="num">B &middot; Candidate</th><th class="num">Change</th><th>Verdict</th></tr></thead>
            <tbody>
$metricRows
            </tbody>
        </table>
        <div class="tally">
            <span class="cell-improved"><b>$improved</b> improved</span>
            <span class="cell-unchanged"><b>$unchanged</b> unchanged</span>
            <span class="cell-regressed"><b>$regressed</b> regressed</span>
            <span class="cell-unchanged">Noise threshold &plusmn;$Threshold%</span>
        </div>
    </div>

    <div class="section">
        <h3>Configuration comparison</h3>
        <table>
            <thead><tr><th>Setting</th><th>A &middot; Baseline</th><th>B &middot; Candidate</th><th>Status</th></tr></thead>
            <tbody>
$guardrailRows
            </tbody>
        </table>
    </div>

$queryComparisonHtml

    <footer>Generated by sqlsim comparison-report.ps1 on $generated. Credentials are masked by the engine before they reach this report.</footer>
</div>
</body>
</html>
"@

# --- Write output ---

$html | Set-Content -LiteralPath $OutputFile -Encoding UTF8
$resolved = (Resolve-Path -LiteralPath $OutputFile).Path
Write-Host ""
Write-Host "Report generated: $resolved" -ForegroundColor Green

if ($Csv) {
    $deltas | ForEach-Object {
        [pscustomobject]@{
            Metric        = $_.Name
            Unit          = $_.Unit
            Baseline      = $_.Baseline
            Candidate     = $_.Candidate
            PercentChange = if ([double]::IsInfinity($_.Change)) { '' } else { [Math]::Round($_.Change, 3) }
            Verdict       = $_.Verdict
            BetterWhen    = $_.Better
            Comparable    = $comparable
        }
    } | Export-Csv -LiteralPath $Csv -NoTypeInformation -Encoding UTF8
    Write-Host "CSV written: $((Resolve-Path -LiteralPath $Csv).Path)" -ForegroundColor Green
}

Write-Host "Verdict: $verdictText  ($improved improved, $unchanged unchanged, $regressed regressed)" -ForegroundColor Cyan
if (-not $comparable) {
    Write-Host "Warning: configurations differ ($(($mismatches | ForEach-Object { $_.Setting }) -join ', ')); runs are not directly comparable." -ForegroundColor Yellow
}

if (-not $NoOpen) {
    Write-Host "Opening in browser..."
    Start-Process $resolved
}
