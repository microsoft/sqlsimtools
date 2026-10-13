<#
.SYNOPSIS
    Converts SQL Server Extended Events (.xel) files to XML for sqlsim replay.

.DESCRIPTION
    Reads .xel files using sys.fn_xe_file_target_read_file() on a SQL Server instance
    and produces a <replay> XML file that sqlsim can replay.
    
    The event_data from sys.fn_xe_file_target_read_file() is already valid XML,
    so this script simply wraps the raw event_data strings in a <replay> root element.
    No XML parsing or re-serialization is needed — just straight pass-through.
    
    Cursor events (sp_cursor*) are filtered out via a simple string match.

.PARAMETER XelFile
    Path to the .xel file(s). Supports wildcards (e.g., "capture*.xel").

.PARAMETER OutputFile
    Path to the output XML file (default: replay.xml).

.PARAMETER ServerName
    SQL Server instance to use for reading .xel files (default: localhost).

.PARAMETER DatabaseName
    Initial catalog used only while SQL Server reads the .xel file. It does not
    select or embed a Replay target database. Studio users choose the target
    after loading the converted XML.

.PARAMETER UseWindowsAuth
    Use Windows Authentication (default: true).

.PARAMETER MaxEvents
    Maximum number of events to extract (default: unlimited).

.EXAMPLE
    .\convert-xel.ps1 -XelFile "C:\xedata\capture*.xel" -OutputFile trace.xml

.EXAMPLE
    .\convert-xel.ps1 -XelFile capture.xel -OutputFile trace.xml -ServerName "myserver\instance"

.EXAMPLE
    .\convert-xel.ps1 -XelFile capture.xel -OutputFile trace.xml -MaxEvents 10000
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$XelFile,
    
    [string]$OutputFile = "replay.xml",
    
    [string]$ServerName = "localhost",
    
    [string]$DatabaseName = "",
    
    [switch]$UseWindowsAuth = $true,
    
    [int]$MaxEvents = 0
)

$ErrorActionPreference = "Stop"

# Build connection string
$connStr = "Server=$ServerName;Driver={ODBC Driver 18 for SQL Server};TrustServerCertificate=Yes;"
if ($UseWindowsAuth) {
    $connStr += "Trusted_Connection=Yes;"
}
if ($DatabaseName) {
    $connStr += "Database=$DatabaseName;"
}

# Resolve XEL file path to full path
# If the path contains wildcards, resolve the directory but keep the wildcard pattern
# because sys.fn_xe_file_target_read_file() handles wildcards natively.
if ($XelFile -match '[*?]') {
    $xelDir = Split-Path $XelFile -Parent
    $xelPattern = Split-Path $XelFile -Leaf
    if ($xelDir) {
        $resolvedDir = (Resolve-Path $xelDir -ErrorAction SilentlyContinue)
        if (-not $resolvedDir) {
            Write-Error "Directory not found: $xelDir"
            exit 1
        }
        $xelPathStr = Join-Path $resolvedDir.Path $xelPattern
    } else {
        $xelPathStr = $XelFile
    }
} else {
    $xelFullPath = (Resolve-Path $XelFile -ErrorAction SilentlyContinue)
    if (-not $xelFullPath) {
        Write-Error "XEL file not found: $XelFile"
        exit 1
    }
    $xelPathStr = $xelFullPath.Path
}

Write-Host "=== convert-xel.ps1 - XEL to XML Converter ===" -ForegroundColor Cyan
Write-Host "XEL file: $xelPathStr"
Write-Host "Output: $OutputFile"
Write-Host "Server: $ServerName"
Write-Host ""

# Query to read XEL file - get raw event_data XML strings
$query = @"
SELECT 
    object_name,
    CAST(event_data AS NVARCHAR(MAX)) AS event_data
FROM sys.fn_xe_file_target_read_file(N'$xelPathStr', NULL, NULL, NULL)
WHERE object_name IN ('sql_batch_completed', 'rpc_completed', 'login', 'logout')
ORDER BY file_name, file_offset
"@

if ($MaxEvents -gt 0) {
    $query = @"
SELECT TOP ($MaxEvents)
    object_name,
    CAST(event_data AS NVARCHAR(MAX)) AS event_data
FROM sys.fn_xe_file_target_read_file(N'$xelPathStr', NULL, NULL, NULL)
WHERE object_name IN ('sql_batch_completed', 'rpc_completed', 'login', 'logout')
ORDER BY file_name, file_offset
"@
}

Write-Host "Reading XEL file via sys.fn_xe_file_target_read_file()..."

$conn = New-Object System.Data.Odbc.OdbcConnection($connStr)
try {
    $conn.Open()
    Write-Host "Connected to $ServerName" -ForegroundColor Green
    
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = $query
    $cmd.CommandTimeout = 300  # 5 minutes for large files
    
    $reader = $cmd.ExecuteReader()
    
    # Write output file directly — event_data is already valid XML,
    # so we just wrap the raw strings in a <replay> root element.
    $writer = [System.IO.StreamWriter]::new($OutputFile, $false, [System.Text.Encoding]::UTF8)
    $writer.WriteLine('<?xml version="1.0" encoding="utf-8"?>')
    $writer.WriteLine("<replay source=""$([System.Security.SecurityElement]::Escape($xelPathStr))"" server=""$([System.Security.SecurityElement]::Escape($ServerName))"" generated=""$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')"">")
    
    $eventCount = 0
    $skippedCount = 0
    
    while ($reader.Read()) {
        $objectName = $reader["object_name"].ToString()
        $eventDataXml = $reader["event_data"].ToString()
        
        # For rpc_completed, skip cursor events via simple string match
        if ($objectName -eq "rpc_completed" -and $eventDataXml -match "sp_cursor") {
            $skippedCount++
            continue
        }
        
        # Write the raw event_data XML directly — no parsing, no re-serialization
        $writer.WriteLine("  $eventDataXml")
        $eventCount++
        
        # Progress indicator every 1000 events
        if ($eventCount % 1000 -eq 0) {
            Write-Host "  Processed $eventCount events..." -ForegroundColor Gray
        }
    }
    
    $writer.WriteLine("</replay>")
    $writer.Close()
    $reader.Close()
    
    Write-Host ""
    Write-Host "Conversion complete:" -ForegroundColor Green
    Write-Host "  Events written: $eventCount"
    Write-Host "  Events skipped: $skippedCount (cursor events)"
    Write-Host "  Output file: $OutputFile"
    
    $fileSize = (Get-Item $OutputFile).Length
    if ($fileSize -gt 1MB) {
        Write-Host "  File size: $([math]::Round($fileSize / 1MB, 1)) MB"
    } else {
        Write-Host "  File size: $([math]::Round($fileSize / 1KB, 1)) KB"
    }
    
} catch {
    Write-Error "Error: $_"
    exit 1
} finally {
    if ($conn.State -eq "Open") {
        $conn.Close()
    }
}
