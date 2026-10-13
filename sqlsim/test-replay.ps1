#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Tests for the XEL replay feature of sqlsim.

.DESCRIPTION
    Validates replay CLI parsing, XML parsing, error handling, and (optionally) 
    live replay execution against a SQL Server.
    
    Tests are divided into two groups:
      - Offline tests: CLI validation, XML parsing, error messages (no SQL Server needed)
      - Online tests: Live replay execution against a server (requires -Server)

    Expected duration: ~2-3 seconds (offline), ~5-10 seconds (with online tests)

.PARAMETER Server
    SQL Server instance for live replay tests (default: localhost).
    If omitted, online tests run against localhost with Windows Auth.

.PARAMETER Database
    Database name for live tests (default: master).

.PARAMETER UseToken
    Access token for Azure SQL Database authentication (optional).

.PARAMETER SkipOnline
    Skip online tests that require a SQL Server connection.

.EXAMPLE
    .\test-replay.ps1
    .\test-replay.ps1 -SkipOnline
    .\test-replay.ps1 -Server myserver -Database testdb
#>

param(
    [string]$Server = "localhost",
    [string]$Database = "master",
    [string]$UseToken = "",
    [string]$Username = "",
    [string]$Password = "",
    [switch]$SkipOnline
)

$ErrorActionPreference = "Continue"

Push-Location $PSScriptRoot

$exe = ".\build\x64\Release\sqlsim.exe"
if (-not (Test-Path $exe)) {
    Write-Host "ERROR: sqlsim.exe not found at $exe" -ForegroundColor Red
    Write-Host "Run build.ps1 first" -ForegroundColor Yellow
    Pop-Location
    exit 1
}

# Determine auth args for online tests. Secrets go to sqlsim on stdin (-T - / -P -)
# so they never appear in a process command line.
$authSecret = $null
if ($UseToken) {
    $authArgs = @("-T", "-")
    $authSecret = $UseToken
} elseif ($Username -and $Password) {
    $authArgs = @("-U", $Username, "-P", "-")
    $authSecret = $Password
} else {
    $authArgs = @("-E")
}

function Invoke-Sqlsim {
    param([string[]]$Arguments)
    $readsSecret = $false
    for ($i = 0; $i -lt $Arguments.Count - 1; $i++) {
        if ($Arguments[$i] -cin '-T', '-P' -and $Arguments[$i + 1] -eq '-') { $readsSecret = $true }
    }
    if ($readsSecret -and $null -ne $authSecret) { $authSecret | & $exe @Arguments 2>&1 | Out-String }
    else { & $exe @Arguments 2>&1 | Out-String }
}

$testsPassed = 0
$testsFailed = 0
$startTime = Get-Date

$replayXml = "testing\replay-test-data.xml"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "SQLSIM REPLAY TEST SUITE" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Server  : $Server" -ForegroundColor White
Write-Host "Database: $Database" -ForegroundColor White
Write-Host "Online  : $(if ($SkipOnline) { 'Skipped' } else { 'Enabled' })" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan

function Test-Replay {
    param(
        [string]$TestName,
        [string[]]$Arguments,
        [switch]$ShouldFail,
        [switch]$IgnoreExitCode,
        [string]$ExpectedOutput,
        [string]$NotExpectedOutput,
        [string[]]$ExpectedOutputAll  # ALL of these must be present
    )
    
    Write-Host "Testing: $TestName" -ForegroundColor Yellow
    
    $output = Invoke-Sqlsim -Arguments $Arguments
    $exitCode = $LASTEXITCODE
    
    $passed = $false
    
    if ($IgnoreExitCode) {
        $passed = $true
    } elseif ($ShouldFail) {
        $passed = ($exitCode -ne 0)
        if (-not $passed) {
            Write-Host "  Expected failure but got exit code 0" -ForegroundColor Gray
        }
    } else {
        $passed = ($exitCode -eq 0)
        if (-not $passed) {
            Write-Host "  Expected success but got exit code $exitCode" -ForegroundColor Gray
        }
    }
    
    if ($passed -and $ExpectedOutput) {
        if ($output -notmatch [regex]::Escape($ExpectedOutput)) {
            $passed = $false
            Write-Host "  Missing expected output: $ExpectedOutput" -ForegroundColor Gray
        }
    }
    
    if ($passed -and $NotExpectedOutput) {
        if ($output -match [regex]::Escape($NotExpectedOutput)) {
            $passed = $false
            Write-Host "  Found unexpected output: $NotExpectedOutput" -ForegroundColor Gray
        }
    }
    
    if ($passed -and $ExpectedOutputAll) {
        foreach ($expected in $ExpectedOutputAll) {
            if ($output -notmatch [regex]::Escape($expected)) {
                $passed = $false
                Write-Host "  Missing expected output: $expected" -ForegroundColor Gray
                break
            }
        }
    }
    
    if ($passed) {
        Write-Host "  PASSED" -ForegroundColor Green
        $script:testsPassed++
    } else {
        Write-Host "  FAILED" -ForegroundColor Red
        if ($output.Length -lt 800) {
            Write-Host "    Output: $($output.Trim())" -ForegroundColor Gray
        } else {
            Write-Host "    Output (first 800 chars): $($output.Substring(0, 800).Trim())" -ForegroundColor Gray
        }
        $script:testsFailed++
    }
    Write-Host ""
}

# ============================================================
# SECTION 1: OFFLINE TESTS (No SQL Server needed)
# ============================================================

Write-Host "--- CLI Validation Tests ---" -ForegroundColor Magenta
Write-Host ""

# Test 1: -replay without -replayfile
Test-Replay -TestName "Replay mode requires -replayfile" `
    -Arguments @("-S", "localhost", "-E", "-replay", "fast") `
    -ShouldFail `
    -ExpectedOutput "-replay requires -replayfile"

# Test 2: -replayfile without -replay
Test-Replay -TestName "Replayfile requires -replay mode" `
    -Arguments @("-S", "localhost", "-E", "-replayfile", $replayXml) `
    -ShouldFail `
    -ExpectedOutput "-replayfile requires -replay"

# Test 3: Invalid replay mode
Test-Replay -TestName "Invalid replay mode rejected" `
    -Arguments @("-S", "localhost", "-E", "-replay", "bogus", "-replayfile", $replayXml) `
    -ShouldFail `
    -ExpectedOutput "Invalid replay mode"

# Test 4: Mutual exclusion with -Q
Test-Replay -TestName "Replay mutually exclusive with -Q" `
    -Arguments @("-S", "localhost", "-E", "-replay", "fast", "-replayfile", $replayXml, "-Q", "SELECT 1") `
    -ShouldFail `
    -ExpectedOutput "Cannot use -replay with -Q or -i"

# Test 5: Missing replay file
Test-Replay -TestName "Missing replay file reports error" `
    -Arguments @("-S", "localhost", "-E", "-replay", "fast", "-replayfile", "nonexistent.xml") `
    -ShouldFail `
    -ExpectedOutput "Cannot open replay file"

# Test 6: Help text shows replay options
Test-Replay -TestName "Help text includes replay options" `
    -Arguments @("-h") `
    -ExpectedOutputAll @("Replay Options:", "-replay <mode>", "-replayfile <xmlfile>")

Write-Host "--- XML Parsing Tests ---" -ForegroundColor Magenta
Write-Host ""

# Test 7: Fast mode parses successfully - validates event counts
Test-Replay -TestName "Fast mode parses test XML with correct counts" `
    -Arguments @("-S", "localhost", "-E", "-replay", "fast", "-replayfile", $replayXml) `
    -IgnoreExitCode `
    -ExpectedOutputAll @("Replay mode: fast", "Replay file:", "7 replayable", "1 skipped", "8 total", "Replay sessions: 3")

# Test 8: Stress mode parses successfully
Test-Replay -TestName "Stress mode parses test XML" `
    -Arguments @("-S", "localhost", "-E", "-replay", "stress", "-replayfile", $replayXml) `
    -IgnoreExitCode `
    -ExpectedOutputAll @("Replay mode: stress", "Replay file:")

# Test 9: JSON output includes replay fields  
Test-Replay -TestName "JSON output includes replay configuration" `
    -Arguments @("-S", "localhost", "-E", "-replay", "fast", "-replayfile", $replayXml, "-json") `
    -IgnoreExitCode `
    -ExpectedOutputAll @('"replay_mode": "fast"', '"replay_file":', '"replay_replayable_events":', '"replay_sessions":')

# Test 10: Empty replay file
$emptyFile = "testing\empty-replay.xml"
"" | Out-File -FilePath $emptyFile -Encoding UTF8 -NoNewline
Test-Replay -TestName "Empty replay file reports error" `
    -Arguments @("-S", "localhost", "-E", "-replay", "fast", "-replayfile", $emptyFile) `
    -ShouldFail `
    -ExpectedOutput "Failed to parse replay file"
Remove-Item $emptyFile -ErrorAction SilentlyContinue

# Test 11: Invalid XML content
$badXml = "testing\bad-replay.xml"
"<notreplay><junk/></notreplay>" | Out-File -FilePath $badXml -Encoding UTF8
Test-Replay -TestName "Invalid XML root element reports error" `
    -Arguments @("-S", "localhost", "-E", "-replay", "fast", "-replayfile", $badXml) `
    -ShouldFail `
    -ExpectedOutput "Expected root element"
Remove-Item $badXml -ErrorAction SilentlyContinue

# Test 12: Replay XML with no replayable events
$noEventsXml = "testing\no-events-replay.xml"
@"
<?xml version="1.0" encoding="utf-8"?>
<replay>
  <event name="rpc_completed" timestamp="2026-01-15T10:00:01.000Z">
    <data name="object_name"><value>sp_cursoropen</value></data>
    <data name="statement"><value>SELECT 1</value></data>
    <action name="session_id"><value>52</value></action>
    <action name="database_name"><value>master</value></action>
  </event>
</replay>
"@ | Out-File -FilePath $noEventsXml -Encoding UTF8
Test-Replay -TestName "No replayable events reports error" `
    -Arguments @("-S", "localhost", "-E", "-replay", "fast", "-replayfile", $noEventsXml) `
    -ShouldFail `
    -ExpectedOutput "No replayable events"
Remove-Item $noEventsXml -ErrorAction SilentlyContinue

# Test 13: Excessive XML nesting is rejected before connection
$deepXml = "testing\deep-replay.xml"
('<replay>' + ('<x>' * 65) + ('</x>' * 65) + '</replay>') | Out-File -FilePath $deepXml -Encoding utf8 -NoNewline
Test-Replay -TestName "Excessive replay XML nesting is rejected" `
    -Arguments @("-S", "localhost", "-E", "-replay", "fast", "-replayfile", $deepXml) `
    -ShouldFail `
    -ExpectedOutput "maximum nesting depth of 64"
Remove-Item $deepXml -ErrorAction SilentlyContinue

# Test 14: Excessive event count is rejected before connection
$manyEventsXml = "testing\many-events-replay.xml"
('<replay>' + ('<event/>' * 100001) + '</replay>') | Out-File -FilePath $manyEventsXml -Encoding utf8 -NoNewline
Test-Replay -TestName "Excessive replay event count is rejected" `
    -Arguments @("-S", "localhost", "-E", "-replay", "fast", "-replayfile", $manyEventsXml) `
    -ShouldFail `
    -ExpectedOutput "maximum event count of 100000"
Remove-Item $manyEventsXml -ErrorAction SilentlyContinue

# Test 15: Verbose mode shows replay details
Test-Replay -TestName "Verbose mode shows replay configuration" `
    -Arguments @("-S", "localhost", "-E", "-replay", "fast", "-replayfile", $replayXml, "-v") `
    -IgnoreExitCode `
    -ExpectedOutputAll @("Replay mode: fast", "Replay sessions: 3")

# ============================================================
# SECTION 2: ONLINE TESTS (Require SQL Server)
# ============================================================

if (-not $SkipOnline) {
        $entitiesXml = "testing\entities-replay.xml"
        @"
<?xml version="1.0" encoding="utf-8"?>
<replay>
    <event name="sql_batch_completed" timestamp="2026-01-15T10:00:01.000Z">
        <data name="batch_text"><value>IF DATALENGTH(N&apos;&#x1F600;&apos;) &lt;&gt; 4 OR DATALENGTH(N&apos;&#128512;&apos;) &lt;&gt; 4 THROW 50000, &apos;ENTITY_BAD&apos;, 1; SELECT 1</value></data>
        <action name="session_id"><value>52</value></action>
        <action name="database_name"><value>master</value></action>
    </event>
</replay>
"@ | Out-File -FilePath $entitiesXml -Encoding UTF8
        Test-Replay -TestName "Supplementary Unicode XML entities execute correctly" `
            -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-replay", "fast", "-replayfile", $entitiesXml))
        Remove-Item $entitiesXml -ErrorAction SilentlyContinue

    Write-Host "--- Live Replay Execution Tests ---" -ForegroundColor Magenta
    Write-Host ""

    # Test 15: Fast mode replay executes successfully
    Test-Replay -TestName "Fast mode replay executes against server" `
        -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-replay", "fast", "-replayfile", $replayXml, "-q")) `
        -ExpectedOutput "Total Runtime:"

    # Test 16: Stress mode replay with 2 threads
    Test-Replay -TestName "Stress mode replay with 2 threads" `
        -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-replay", "stress", "-replayfile", $replayXml, "-n", "2", "-q")) `
        -ExpectedOutput "Total Runtime:"

    # Test 17: Fast mode replay with iterations
    Test-Replay -TestName "Fast mode replay with 3 iterations" `
        -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-replay", "fast", "-replayfile", $replayXml, "-r", "3", "-q")) `
        -ExpectedOutput "Total Runtime:"

    # Test 18: Stress mode replay with iterations
    Test-Replay -TestName "Stress mode replay with 2 threads x 2 iterations" `
        -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-replay", "stress", "-replayfile", $replayXml, "-n", "2", "-r", "2", "-q")) `
        -ExpectedOutput "Total Runtime:"

    # Test 19: Fast mode replay with verbose output
    Test-Replay -TestName "Fast mode replay verbose output" `
        -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-replay", "fast", "-replayfile", $replayXml, "-v", "-q")) `
        -ExpectedOutputAll @("Total Runtime:", "Replay mode: fast")

    # Test 20: Fast mode JSON output has metrics
    Test-Replay -TestName "Fast mode JSON output with metrics" `
        -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-replay", "fast", "-replayfile", $replayXml, "-json")) `
        -ExpectedOutputAll @('"replay_mode": "fast"', '"metrics":', '"replay_summary":', '"original":', '"result":')

    # Test 21: Stress mode JSON output has metrics
    Test-Replay -TestName "Stress mode JSON output with metrics" `
        -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-replay", "stress", "-replayfile", $replayXml, "-json")) `
        -ExpectedOutputAll @('"replay_mode": "stress"', '"metrics":', '"replay_summary":', '"original":', '"result":')

    # Test 22: comparison-report.ps1 with two JSON outputs
    Write-Host "Testing: comparison-report with two JSON outputs" -ForegroundColor Yellow
    $jsonA = "testing\replay-result-a.json"
    $jsonB = "testing\replay-result-b.json"
    $compareReport = "testing\test-compare-report.html"

    # Generate two JSON outputs
    $outA = Invoke-Sqlsim -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-replay", "fast", "-replayfile", $replayXml, "-json"))
    $outA | Out-File -FilePath $jsonA -Encoding UTF8
    $outB = Invoke-Sqlsim -Arguments (@("-S", $Server, "-d", $Database) + $authArgs + @("-replay", "stress", "-replayfile", $replayXml, "-json"))
    $outB | Out-File -FilePath $jsonB -Encoding UTF8

    $compareOutput = & pwsh -File "examples\reports\comparison-report.ps1" `
        -BaselineFile $jsonA -CandidateFile $jsonB -OutputFile $compareReport -NoOpen 2>&1 | Out-String

    # An all-zero report means the script is reading a stale JSON schema, so assert real values.
    $reportHtml = if (Test-Path $compareReport) { Get-Content $compareReport -Raw } else { '' }
    $hasRuntime = $reportHtml -match '<td class="num">[1-9][\d.,]*\s*<span'
    $flagsReplayMode = $reportHtml -match 'Replay \(fast\)' -and $reportHtml -match 'Replay \(stress\)'
    $comparePassed = (Test-Path $compareReport) -and $hasRuntime -and $flagsReplayMode

    if ($comparePassed) {
        Write-Host "  PASSED" -ForegroundColor Green
        $testsPassed++
    } else {
        Write-Host "  FAILED" -ForegroundColor Red
        if (-not $hasRuntime) { Write-Host "    Report contains no non-zero metrics (stale JSON schema?)" -ForegroundColor Gray }
        if (-not $flagsReplayMode) { Write-Host "    Report did not record both replay modes" -ForegroundColor Gray }
        Write-Host "    Output: $($compareOutput.Trim())" -ForegroundColor Gray
        $testsFailed++
    }
    Write-Host ""
    
    # Cleanup online test artifacts
    Remove-Item $jsonA, $jsonB, $compareReport -ErrorAction SilentlyContinue

} else {
    Write-Host "--- Online tests SKIPPED (use -Server or remove -SkipOnline) ---" -ForegroundColor DarkGray
    Write-Host ""
}

# ============================================================
# SUMMARY
# ============================================================

$endTime = Get-Date
$duration = $endTime - $startTime
$totalTests = $testsPassed + $testsFailed

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "REPLAY TEST SUMMARY" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Total Tests: $totalTests" -ForegroundColor White
Write-Host "Passed: $testsPassed" -ForegroundColor $(if ($testsPassed -eq $totalTests) { "Green" } else { "Yellow" })
Write-Host "Failed: $testsFailed" -ForegroundColor $(if ($testsFailed -eq 0) { "Green" } else { "Red" })
Write-Host "Duration: $([math]::Round($duration.TotalSeconds, 1)) seconds" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Cyan

Pop-Location

if ($testsFailed -eq 0) {
    Write-Host "`nALL REPLAY TESTS PASSED!" -ForegroundColor Green
    exit 0
} else {
    Write-Host "`nSOME REPLAY TESTS FAILED!" -ForegroundColor Red
    exit 1
}
