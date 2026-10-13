<#
.SYNOPSIS
    Generates a workload that produces rpc_completed XEvent events for replay testing.

.DESCRIPTION
    Uses System.Data.SqlClient to execute parameterized queries, which generates
    sp_executesql and sp_prepare/sp_execute/sp_unprepare events in XEvent traces.
    Also calls a user stored proc to generate user_proc RPC events.
    
    Run this WHILE an XEvent capture session is active to produce a trace
    with diverse event types for replay testing.

.PARAMETER ServerName
    SQL Server instance (default: localhost).

.PARAMETER DatabaseName
    Database to use (default: tempdb).

.EXAMPLE
    .\generate-rpc-workload.ps1
#>

param(
    [string]$ServerName = "localhost",
    [string]$DatabaseName = "tempdb"
)

$ErrorActionPreference = "Stop"

Write-Host "=== generate-rpc-workload.ps1 - RPC Event Generator ===" -ForegroundColor Cyan
Write-Host "Server: $ServerName"
Write-Host "Database: $DatabaseName"
Write-Host ""

$connStr = "Server=$ServerName;Database=$DatabaseName;Trusted_Connection=Yes;TrustServerCertificate=Yes;Application Name=sqlsim;"

# --- Setup: Create a test stored proc ---
Write-Host "Setting up test objects..." -ForegroundColor Gray
$setupConn = New-Object System.Data.SqlClient.SqlConnection($connStr)
$setupConn.Open()

$setupCmd = $setupConn.CreateCommand()
$setupCmd.CommandText = @"
IF OBJECT_ID('dbo.sqlsim_test_proc', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sqlsim_test_proc;
"@
$setupCmd.ExecuteNonQuery() | Out-Null

$setupCmd.CommandText = @"
CREATE PROCEDURE dbo.sqlsim_test_proc
    @id INT,
    @name NVARCHAR(100)
AS
BEGIN
    SELECT @id AS id, @name AS name, GETDATE() AS queried_at;
END
"@
$setupCmd.ExecuteNonQuery() | Out-Null
$setupConn.Close()
Write-Host "  Created dbo.sqlsim_test_proc" -ForegroundColor Green

# --- Workload 1: Parameterized queries (generates sp_executesql) ---
Write-Host ""
Write-Host "Running parameterized queries (sp_executesql)..." -ForegroundColor Yellow

$conn1 = New-Object System.Data.SqlClient.SqlConnection($connStr)
$conn1.Open()

# Simple parameterized SELECT
for ($i = 1; $i -le 3; $i++) {
    $cmd = $conn1.CreateCommand()
    $cmd.CommandText = "SELECT @p1 AS val, @p2 AS label"
    $cmd.Parameters.AddWithValue("@p1", $i) | Out-Null
    $cmd.Parameters.AddWithValue("@p2", "test_$i") | Out-Null
    $reader = $cmd.ExecuteReader()
    while ($reader.Read()) { } # consume
    $reader.Close()
    $cmd.Dispose()
}
Write-Host "  3 parameterized SELECT queries" -ForegroundColor Green

# Parameterized with different types
$cmd2 = $conn1.CreateCommand()
$cmd2.CommandText = "SELECT @intval AS i, @floatval AS f, @strval AS s, @dateval AS d"
$cmd2.Parameters.AddWithValue("@intval", 42) | Out-Null
$cmd2.Parameters.AddWithValue("@floatval", 3.14) | Out-Null
$cmd2.Parameters.AddWithValue("@strval", "hello world") | Out-Null
$cmd2.Parameters.AddWithValue("@dateval", [DateTime]::Now) | Out-Null
$reader2 = $cmd2.ExecuteReader()
while ($reader2.Read()) { }
$reader2.Close()
$cmd2.Dispose()
Write-Host "  1 multi-type parameterized query" -ForegroundColor Green

$conn1.Close()

# --- Workload 2: Stored proc calls (generates rpc_completed with user proc) ---
Write-Host ""
Write-Host "Running stored procedure calls..." -ForegroundColor Yellow

$conn2 = New-Object System.Data.SqlClient.SqlConnection($connStr)
$conn2.Open()

for ($i = 1; $i -le 3; $i++) {
    $cmd = $conn2.CreateCommand()
    $cmd.CommandType = [System.Data.CommandType]::StoredProcedure
    $cmd.CommandText = "dbo.sqlsim_test_proc"
    $cmd.Parameters.AddWithValue("@id", $i) | Out-Null
    $cmd.Parameters.AddWithValue("@name", "user_$i") | Out-Null
    $reader = $cmd.ExecuteReader()
    while ($reader.Read()) { }
    $reader.Close()
    $cmd.Dispose()
}
Write-Host "  3 stored procedure calls" -ForegroundColor Green

$conn2.Close()

# --- Workload 3: Prepared statements (generates sp_prepare/sp_execute/sp_unprepare) ---
Write-Host ""
Write-Host "Running prepared statement pattern..." -ForegroundColor Yellow

# SqlClient with Prepare() forces the sp_prepare/sp_execute lifecycle
$conn3 = New-Object System.Data.SqlClient.SqlConnection($connStr)
$conn3.Open()

$cmd3 = $conn3.CreateCommand()
$cmd3.CommandText = "SELECT @val * 2 AS doubled"
$p = $cmd3.Parameters.Add("@val", [System.Data.SqlDbType]::Int)
$cmd3.Prepare()

for ($i = 1; $i -le 3; $i++) {
    $p.Value = $i * 10
    $reader = $cmd3.ExecuteReader()
    while ($reader.Read()) { }
    $reader.Close()
}
Write-Host "  1 prepared statement, executed 3 times" -ForegroundColor Green

$cmd3.Dispose()  # triggers sp_unprepare
$conn3.Close()

# --- Summary ---
Write-Host ""
Write-Host "Workload complete:" -ForegroundColor Green
Write-Host "  - 4 sp_executesql events (parameterized queries)"
Write-Host "  - 3 user stored proc events (dbo.sqlsim_test_proc)"
Write-Host "  - 1 sp_prepare + 3 sp_execute + 1 sp_unprepare events"
Write-Host "  Total: ~12 replayable RPC events + batch events from setup"
