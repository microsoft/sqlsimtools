<#
.SYNOPSIS
    Offline tests for sqlsim HTML report generators.

.DESCRIPTION
    Builds hostile result JSON, renders each static report, and verifies that
    values from the result never become markup or executable JavaScript. Also
    checks that comparison-report.ps1 uses the same metrics and guardrails as
    sqlsim Studio Compare.

.EXAMPLE
    .\test-reports.ps1
#>

$ErrorActionPreference = 'Stop'

$reports = Join-Path $PSScriptRoot 'examples\reports'
$examples = Join-Path $PSScriptRoot 'examples\results'
$powershell = (Get-Process -Id $PID).Path
$temporary = Join-Path ([IO.Path]::GetTempPath()) "sqlsim-report-tests-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $temporary | Out-Null
$passed = 0
$failed = 0

$markupPayload = '<img src=x onerror=alert(1)>'
$scriptPayload = '</script><script>alert(2)</script>'
$numberPayload = '0;alert(3)//'

function Test-Case {
    param([string]$Name, [scriptblock]$Check)
    try {
        & $Check
        Write-Host "  ok      $Name" -ForegroundColor Green
        $script:passed++
    } catch {
        Write-Host "  FAILED  $Name" -ForegroundColor Red
        Write-Host "          $($_.Exception.Message)" -ForegroundColor DarkRed
        $script:failed++
    }
}

function Invoke-Report {
    param([string]$Script, [string[]]$Arguments)
    $output = & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $reports $Script) @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "$Script exited $LASTEXITCODE`n$output" }
}

function Assert-SafeReport {
    param([string]$Path)
    $html = [IO.File]::ReadAllText($Path)
    if ($html.Contains($markupPayload)) { throw 'An HTML payload was written as markup.' }
    if ($html.Contains('</script><script>alert(2)')) { throw 'A script payload closed the report script element.' }
    if ($html.Contains($numberPayload)) { throw 'A non-numeric metric was written into the report.' }
    if (-not $html.Contains('&lt;img src=x onerror=alert(1)&gt;')) { throw 'The HTML payload was not displayed as encoded text.' }
    return $html
}

function New-HostileResult {
    param([double]$Runtime)
    return [ordered]@{
        version = '1.0.0'
        start_time = $markupPayload
        server_version = $markupPayload
        configuration = [ordered]@{
            odbc_driver = $markupPayload
            server = $markupPayload
            database = $markupPayload
            authentication = $markupPayload
            threads = $markupPayload
            iterations_per_thread = $markupPayload
            total_batches = 10
            batch_count = 1
            batches = @($scriptPayload)
            query_stats = $true
        }
        query_stats = [ordered]@{
            queries = @([ordered]@{
                query = $scriptPayload
                executions = $numberPayload
                failures = $numberPayload
                total_elapsed_ms = [ordered]@{ avg = $numberPayload; min = 1; max = 2 }
                server_elapsed_ms = [ordered]@{ avg = 1; min = 1; max = 1 }
                server_cpu_ms = [ordered]@{ avg = 1; min = 1; max = 1 }
                logical_reads = [ordered]@{ avg = 1; min = 1; max = 1 }
                physical_reads = [ordered]@{ avg = 0; min = 0; max = 0 }
                row_count = [ordered]@{ avg = 1; min = 1; max = 1 }
            })
            totals = [ordered]@{
                executions = $numberPayload
                total_elapsed_ms = $numberPayload
                server_elapsed_ms = 1
                server_cpu_ms = 1
                logical_reads = 1
                physical_reads = 0
            }
        }
        metrics = [ordered]@{
            odbc_driver_version = $markupPayload
            total_runtime_seconds = $Runtime
            total_connection_time_seconds = $numberPayload
            total_query_execution_time_seconds = $numberPayload
            end_time = $markupPayload
            errors = [ordered]@{
                total = 1
                list = @([ordered]@{ timestamp = $markupPayload; query = $scriptPayload; message = $markupPayload })
            }
            warnings = [ordered]@{ total = 0 }
        }
        success = $false
    }
}

try {
    $baseline = Join-Path $temporary 'hostile-baseline.json'
    $candidate = Join-Path $temporary 'hostile-candidate.json'
    New-HostileResult -Runtime 2 | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $baseline -Encoding UTF8
    New-HostileResult -Runtime 1 | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $candidate -Encoding UTF8

    Write-Host 'Report tests' -ForegroundColor Cyan

    Test-Case 'comparison report encodes labels and configuration' {
        $output = Join-Path $temporary 'comparison.html'
        Invoke-Report 'comparison-report.ps1' @('-BaselineFile', $baseline, '-CandidateFile', $candidate,
            '-LabelA', $markupPayload, '-LabelB', $markupPayload, '-OutputFile', $output, '-NoOpen')
        $null = Assert-SafeReport $output
    }

    Test-Case 'execution report encodes text and writes numeric JavaScript values' {
        $output = Join-Path $temporary 'execution.html'
        Invoke-Report 'execution-report.ps1' @('-JsonFile', $baseline, '-OutputFile', $output, '-NoOpen')
        $html = Assert-SafeReport $output
        if ($html -notmatch 'const connTime = 0;' -or $html -notmatch 'const queryTime = 0;') {
            throw 'Non-numeric timing values were not converted to zero.'
        }
    }

    Test-Case 'execution report derives averages from -json output without -v' {
        # sqlsim Studio and the shipped examples write -json without -v, which
        # omits the per-operation blocks the report used to require.
        $output = Join-Path $temporary 'execution-plain.html'
        Invoke-Report 'execution-report.ps1' @('-JsonFile', (Join-Path $examples 'index-baseline.json'), '-OutputFile', $output, '-NoOpen')
        $html = [IO.File]::ReadAllText($output)
        if ($html -notmatch 'color-steel">0\.71<span class="unit"> ms') { throw 'Average execution time was not derived from total query time.' }
    }

    Test-Case 'query statistics chart keeps query text inside its script data' {
        $output = Join-Path $temporary 'querystats.html'
        Invoke-Report 'querystats-chart.ps1' @('-JsonFile', $baseline, '-OutputFile', $output, '-NoOpen')
        $html = Assert-SafeReport $output
        if (-not $html.Contains('\u003c/script\u003e')) { throw 'Query text in chart labels was not script-escaped.' }
    }

    Test-Case 'shipped index examples match Studio Compare metrics' {
        $output = Join-Path $temporary 'examples.html'
        $csv = Join-Path $temporary 'examples.csv'
        Invoke-Report 'comparison-report.ps1' @('-BaselineFile', (Join-Path $examples 'index-baseline.json'),
            '-CandidateFile', (Join-Path $examples 'index-candidate.json'), '-OutputFile', $output, '-Csv', $csv, '-NoOpen')
        $html = [IO.File]::ReadAllText($output)
        if (-not $html.Contains('Configurations match.')) { throw 'The examples were not comparable.' }
        if (-not $html.Contains('>Candidate improved<')) { throw 'The examples did not report an improvement.' }
        if (-not $html.Contains('Per-query comparison')) { throw 'The per-query comparison was missing.' }
        if (-not $html.Contains('36.0 &rarr; 2.0')) { throw 'The per-query logical reads were not compared.' }
        if (-not $html.Contains('-94.4%')) { throw 'The per-query logical-read change did not match Studio.' }
        $rows = @{}
        Import-Csv -LiteralPath $csv | ForEach-Object { $rows[$_.Metric] = $_ }
        $expected = @{ 'Throughput' = 102.381; 'Total duration' = -47.299; 'Avg execution' = -50.168; 'Avg connection' = 4.972; 'Errors' = 0 }
        foreach ($metric in $expected.Keys) {
            if ([Math]::Abs([double]$rows[$metric].PercentChange - $expected[$metric]) -gt 0.001) {
                throw "$metric changed by $($rows[$metric].PercentChange)%, expected $($expected[$metric])%."
            }
        }
        if ($rows['Avg connection'].Verdict -ne 'not in verdict') { throw 'Connection time counted without -reconnect.' }
        if (-not $html.Contains('<b>3</b> improved')) { throw 'The verdict tally did not match Studio.' }
    }

    Test-Case 'driver and SQL Server version differences are informational' {
        $data = Get-Content -LiteralPath (Join-Path $examples 'index-candidate.json') -Raw | ConvertFrom-Json
        $data.metrics.odbc_driver_version = '18.99.0001'
        $data | Add-Member -NotePropertyName server_version -NotePropertyValue '17.0.9999.1' -Force
        $changed = Join-Path $temporary 'version-candidate.json'
        $data | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $changed -Encoding UTF8
        $output = Join-Path $temporary 'version.html'
        Invoke-Report 'comparison-report.ps1' @('-BaselineFile', (Join-Path $examples 'index-baseline.json'),
            '-CandidateFile', $changed, '-OutputFile', $output, '-NoOpen')
        $html = [IO.File]::ReadAllText($output)
        if (-not $html.Contains('Configurations match.')) { throw 'A driver or version difference blocked the comparison.' }
        if (([regex]::Matches($html, 'Differs \(informational\)')).Count -ne 2) { throw 'The driver and version differences were not shown.' }
    }

    Test-Case 'different workload SQL is not comparable' {
        $data = Get-Content -LiteralPath (Join-Path $examples 'index-candidate.json') -Raw | ConvertFrom-Json
        $data.configuration.batches = @('SELECT 1;')
        $changed = Join-Path $temporary 'workload-candidate.json'
        $data | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $changed -Encoding UTF8
        $output = Join-Path $temporary 'workload.html'
        Invoke-Report 'comparison-report.ps1' @('-BaselineFile', (Join-Path $examples 'index-baseline.json'),
            '-CandidateFile', $changed, '-OutputFile', $output, '-NoOpen')
        $html = [IO.File]::ReadAllText($output)
        if (-not $html.Contains('Configurations differ: Workload checksum.')) { throw 'Different workload SQL was treated as comparable.' }
    }

    Test-Case 'Live progress and Final results runs are not comparable' {
        $data = Get-Content -LiteralPath (Join-Path $examples 'index-candidate.json') -Raw | ConvertFrom-Json
        $data.configuration | Add-Member -NotePropertyName stream_json -NotePropertyValue $true -Force
        $changed = Join-Path $temporary 'live-candidate.json'
        $data | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $changed -Encoding UTF8
        $output = Join-Path $temporary 'telemetry.html'
        Invoke-Report 'comparison-report.ps1' @('-BaselineFile', (Join-Path $examples 'index-baseline.json'),
            '-CandidateFile', $changed, '-OutputFile', $output, '-NoOpen')
        $html = [IO.File]::ReadAllText($output)
        if (-not $html.Contains('Configurations differ: Telemetry.')) { throw 'Live progress was compared with Final results.' }
    }
} finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Passed: $passed  Failed: $failed"
if ($failed -gt 0) { exit 1 }
