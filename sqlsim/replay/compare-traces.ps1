<#
.SYNOPSIS
    Compares an original XEvent trace with a replay capture to verify replay fidelity.

.DESCRIPTION
    Reads two .xel files (original capture and replay capture) using 
    sys.fn_xe_file_target_read_file() and compares the sql_batch_completed
    and rpc_completed events to verify the replay matched the original.

    Checks:
    - Same set of distinct queries
    - Same count of each query
    - Same database context for each query
    - No extra or missing queries

.PARAMETER OriginalXel
    Path to the original .xel capture file(s). Supports wildcards.

.PARAMETER ReplayXel
    Path to the replay .xel capture file(s). Supports wildcards.

.PARAMETER ServerName
    SQL Server instance to use for reading .xel files (default: localhost).

.PARAMETER IgnoreLoginLogout
    Skip login/logout events in comparison (default: true).

.EXAMPLE
    .\compare-traces.ps1 -OriginalXel "C:\temp\sqlsim_test_capture*.xel" -ReplayXel "C:\temp\sqlsim_replay_capture*.xel"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$OriginalXel,

    [Parameter(Mandatory = $true)]
    [string]$ReplayXel,

    [string]$ServerName = "localhost",

    [switch]$IgnoreLoginLogout = $true
)

$ErrorActionPreference = "Stop"

# Resolve wildcard path for sys.fn_xe_file_target_read_file()
function Resolve-XelPath {
    param([string]$Path)
    if ($Path -match '[*?]') {
        $dir = Split-Path $Path -Parent
        $pattern = Split-Path $Path -Leaf
        if ($dir) {
            $resolvedDir = (Resolve-Path $dir -ErrorAction SilentlyContinue)
            if (-not $resolvedDir) {
                Write-Error "Directory not found: $dir"
                exit 1
            }
            return Join-Path $resolvedDir.Path $pattern
        }
        return $Path
    } else {
        $resolved = Resolve-Path $Path -ErrorAction SilentlyContinue
        if (-not $resolved) {
            Write-Error "File not found: $Path"
            exit 1
        }
        return $resolved.Path
    }
}

# Read events from a .xel file via SQL Server
function Read-XelEvents {
    param(
        [string]$XelPath,
        [string]$Server,
        [string]$Label
    )

    Write-Host "Reading $Label events from: $XelPath" -ForegroundColor Gray

    $connStr = "Server=$Server;Driver={ODBC Driver 18 for SQL Server};TrustServerCertificate=Yes;Trusted_Connection=Yes;"
    $conn = New-Object System.Data.Odbc.OdbcConnection($connStr)
    $conn.Open()

    # Get event_name and batch_text from the raw event_data XML
    $query = @"
SELECT 
    object_name,
    CAST(event_data AS XML) AS event_xml
FROM sys.fn_xe_file_target_read_file(N'$XelPath', NULL, NULL, NULL)
WHERE object_name IN ('sql_batch_completed', 'rpc_completed')
ORDER BY file_name, file_offset
"@

    $cmd = $conn.CreateCommand()
    $cmd.CommandText = $query
    $cmd.CommandTimeout = 300
    $reader = $cmd.ExecuteReader()

    $events = @()
    while ($reader.Read()) {
        $objectName = $reader["object_name"].ToString()
        $eventXml = [xml]$reader["event_xml"].ToString()

        # Extract batch_text, statement, object_name (RPC proc name), and database_name
        $sqlText = $null
        $dbName = $null
        $rpcObjectName = $null

        foreach ($data in $eventXml.event.data) {
            if ($data.name -eq "batch_text" -or $data.name -eq "statement") {
                $sqlText = $data.value
            }
            if ($data.name -eq "object_name") {
                $rpcObjectName = $data.value
            }
        }
        foreach ($action in $eventXml.event.action) {
            if ($action.name -eq "database_name") {
                $dbName = $action.value
            }
        }

        if ($sqlText) {
            # Normalize whitespace for comparison
            $normalized = ($sqlText -replace '\s+', ' ').Trim()
            
            # Build a normalized key for comparison that abstracts away ODBC driver wrapping.
            # The ODBC driver may wrap {CALL proc(...)} as sp_prepexecrpc, and parameterized
            # queries as sp_prepexec. We normalize to the underlying operation.
            $normalizedKey = $null
            
            if ($objectName -eq "sql_batch_completed") {
                # Skip USE statements — these are internal database context switches
                if ($normalized -match '^\s*USE\s+\[') {
                    continue
                }
                # sqlsim reads the server-assigned SPID once per Replay connection
                # so results can map captured sessions to their new connections.
                if ($normalized -match '(?i)^SELECT\s+CONVERT\s*\(\s*bigint\s*,\s*@@SPID\s*\)$') {
                    continue
                }
                $normalizedKey = "batch|$normalized"
            }
            elseif ($objectName -eq "rpc_completed") {
                $rpcLower = if ($rpcObjectName) { $rpcObjectName.ToLower() } else { "" }
                
                if ($rpcLower -eq "sp_executesql" -or $rpcLower -eq "sp_prepexec") {
                    # Both are parameterized query execution — extract the inner SQL
                    # sp_executesql format: exec sp_executesql N'inner_sql',N'param_defs',val1,val2
                    # sp_prepexec format:   exec sp_prepexec @p1 output,N'param_defs',N'inner_sql',val1 ... select @p1
                    $innerSql = $null
                    
                    if ($rpcLower -eq "sp_prepexec") {
                        # For sp_prepexec, inner SQL is the SECOND N'...' string
                        # Skip past the first N'...' (param defs) to find the second
                        $nquoteMatches = [regex]::Matches($normalized, "N'((?:[^']|'')*)'")
                        if ($nquoteMatches.Count -ge 2) {
                            $innerSql = $nquoteMatches[1].Groups[1].Value -replace "''", "'"
                        } elseif ($nquoteMatches.Count -eq 1) {
                            # Only one N'...' — could be SQL with no param defs
                            $innerSql = $nquoteMatches[0].Groups[1].Value -replace "''", "'"
                        }
                    } else {
                        # For sp_executesql, inner SQL is the FIRST N'...' string
                        if ($normalized -match "N'((?:[^']|'')+)'") {
                            $innerSql = $matches[1] -replace "''", "'"
                        }
                    }
                    
                    if ($innerSql) {
                        # Normalize parameter markers: @P1, @p1, @param1 -> @P
                        $innerSql = $innerSql -replace '@[Pp]\d+', '@P'
                        $normalizedKey = "parameterized_query|$innerSql"
                    } else {
                        $normalizedKey = "rpc|$rpcLower|$normalized"
                    }
                }
                elseif ($rpcLower -eq "sp_prepexecrpc") {
                    # ODBC driver wrapping of {CALL proc(?,?)} — extract proc name and params
                    # Format: declare @p1 int set @p1=NULL exec sp_prepexecrpc @p1 output,N'dbo.proc',param1,param2 ...
                    if ($normalized -match "sp_prepexecrpc\s+@\w+\s+output,N'([^']+)',(.+)$") {
                        $procName = $matches[1]
                        $paramsPart = $matches[2]
                        # Remove the trailing "select @p1" output capture
                        $paramsPart = $paramsPart -replace '\s+select\s+@\w+\s*$', ''
                        $normalizedKey = "user_proc|$procName|$paramsPart"
                    } else {
                        $normalizedKey = "rpc|$rpcLower|$normalized"
                    }
                }
                elseif ($rpcLower -match '^sp_cursor|^sp_reset_connection|^sp_prepare$|^sp_unprepare$') {
                    # Skip cursor, reset, and bare prepare/unprepare events
                    continue
                }
                else {
                    # User stored procedure — original capture
                    # Format: exec dbo.sqlsim_test_proc 1,N'hello'
                    if ($normalized -match '^\s*exec\s+(\S+)\s+(.+)$') {
                        $procName = $matches[1]
                        $paramsPart = $matches[2].Trim()
                        $normalizedKey = "user_proc|$procName|$paramsPart"
                    } else {
                        $normalizedKey = "rpc|$rpcLower|$normalized"
                    }
                }
            }

            if ($normalizedKey) {
                $events += [PSCustomObject]@{
                    EventType     = $objectName
                    SqlText       = $normalized
                    Database      = $dbName
                    RawSqlText    = $sqlText
                    RpcObjectName = $rpcObjectName
                    NormalizedKey = $normalizedKey
                }
            }
        }
    }

    $reader.Close()
    $conn.Close()

    Write-Host "  Found $($events.Count) query events" -ForegroundColor Gray
    return $events
}

Write-Host "=== compare-traces.ps1 - Replay Fidelity Check ===" -ForegroundColor Cyan
Write-Host ""

$originalPath = Resolve-XelPath $OriginalXel
$replayPath = Resolve-XelPath $ReplayXel

$originalEvents = Read-XelEvents -XelPath $originalPath -Server $ServerName -Label "original"
$replayEvents = Read-XelEvents -XelPath $replayPath -Server $ServerName -Label "replay"

Write-Host ""

# Build frequency maps: normalized SQL text -> count
function Build-QueryMap {
    param($events)
    $map = @{}
    foreach ($e in $events) {
        $key = $e.NormalizedKey
        if ($map.ContainsKey($key)) {
            $map[$key]++
        } else {
            $map[$key] = 1
        }
    }
    return $map
}

$originalMap = Build-QueryMap $originalEvents
$replayMap = Build-QueryMap $replayEvents

# Compare
$missingFromReplay = @()
$extraInReplay = @()
$countMismatches = @()
$matched = 0

foreach ($key in $originalMap.Keys) {
    if (-not $replayMap.ContainsKey($key)) {
        $missingFromReplay += [PSCustomObject]@{
            Key           = $key
            OriginalCount = $originalMap[$key]
        }
    } elseif ($replayMap[$key] -ne $originalMap[$key]) {
        $countMismatches += [PSCustomObject]@{
            Key           = $key
            OriginalCount = $originalMap[$key]
            ReplayCount   = $replayMap[$key]
        }
    } else {
        $matched++
    }
}

foreach ($key in $replayMap.Keys) {
    if (-not $originalMap.ContainsKey($key)) {
        $extraInReplay += [PSCustomObject]@{
            Key         = $key
            ReplayCount = $replayMap[$key]
        }
    }
}

# Also compare database context using NormalizedKey
$dbMismatches = @()
foreach ($origEvent in $originalEvents) {
    $key = $origEvent.NormalizedKey
    # Find matching replay events with different database
    $replayMatches = $replayEvents | Where-Object {
        $_.NormalizedKey -eq $key -and $_.Database -ne $origEvent.Database
    }
    if ($replayMatches) {
        $dbMismatches += [PSCustomObject]@{
            Key              = $key
            OriginalDatabase = $origEvent.Database
            ReplayDatabase   = ($replayMatches | Select-Object -First 1).Database
        }
    }
}
# Deduplicate database mismatches
$dbMismatches = $dbMismatches | Sort-Object Key, OriginalDatabase, ReplayDatabase -Unique

# Report
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "COMPARISON RESULTS" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Original: $($originalEvents.Count) query events ($($originalMap.Count) distinct)" 
Write-Host "Replay:   $($replayEvents.Count) query events ($($replayMap.Count) distinct)"
Write-Host ""

$pass = $true

# Matched queries
Write-Host "Matched queries: $matched / $($originalMap.Count)" -ForegroundColor $(if ($matched -eq $originalMap.Count) { "Green" } else { "Yellow" })

# Missing from replay
if ($missingFromReplay.Count -gt 0) {
    $pass = $false
    Write-Host ""
    Write-Host "MISSING from replay ($($missingFromReplay.Count)):" -ForegroundColor Red
    foreach ($m in $missingFromReplay) {
        $preview = $m.Key
        if ($preview.Length -gt 120) { $preview = $preview.Substring(0, 120) + "..." }
        Write-Host "  x$($m.OriginalCount): $preview" -ForegroundColor Red
    }
}

# Extra in replay
if ($extraInReplay.Count -gt 0) {
    $pass = $false
    Write-Host ""
    Write-Host "EXTRA in replay ($($extraInReplay.Count)):" -ForegroundColor Red
    foreach ($e in $extraInReplay) {
        $preview = $e.Key
        if ($preview.Length -gt 120) { $preview = $preview.Substring(0, 120) + "..." }
        Write-Host "  x$($e.ReplayCount): $preview" -ForegroundColor Red
    }
}

# Count mismatches
if ($countMismatches.Count -gt 0) {
    $pass = $false
    Write-Host ""
    Write-Host "COUNT mismatches ($($countMismatches.Count)):" -ForegroundColor Yellow
    foreach ($c in $countMismatches) {
        $preview = $c.Key
        if ($preview.Length -gt 120) { $preview = $preview.Substring(0, 120) + "..." }
        Write-Host "  original=$($c.OriginalCount) replay=$($c.ReplayCount): $preview" -ForegroundColor Yellow
    }
}

# Database mismatches
if ($dbMismatches.Count -gt 0) {
    Write-Host ""
    Write-Host "DATABASE context differences ($($dbMismatches.Count)):" -ForegroundColor Yellow
    foreach ($d in $dbMismatches) {
        $preview = $d.Key
        if ($preview.Length -gt 100) { $preview = $preview.Substring(0, 100) + "..." }
        Write-Host "  '$($d.OriginalDatabase)' -> '$($d.ReplayDatabase)': $preview" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
if ($pass -and $dbMismatches.Count -eq 0) {
    Write-Host "RESULT: PASS - Replay matches original exactly" -ForegroundColor Green
    exit 0
} elseif ($pass) {
    Write-Host "RESULT: PASS (with database context notes)" -ForegroundColor Yellow
    exit 0
} else {
    Write-Host "RESULT: FAIL - Differences found" -ForegroundColor Red
    exit 1
}
