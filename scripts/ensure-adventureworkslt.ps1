#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Ensure that a valid AdventureWorksLT test database is available.

.DESCRIPTION
    Validates the AdventureWorksLT fixture used by cross-engine and realistic
    workload tests. If the database is absent on a local SQL Server, downloads
    Microsoft's AdventureWorksLT2019 backup and restores it into the instance's
    default data and log directories.

    Remote SQL Server and Azure SQL targets are validated but never modified.
    Provision those targets separately, then rerun this script.

.EXAMPLE
    ./scripts/ensure-adventureworkslt.ps1

.EXAMPLE
    ./scripts/ensure-adventureworkslt.ps1 -Server localhost -Username sa -Password $password

.EXAMPLE
    ./scripts/ensure-adventureworkslt.ps1 -Server myserver -ValidateOnly
#>

[CmdletBinding()]
param(
    [string]$Server = 'localhost',
    [string]$Database = 'AdventureWorksLT',
    [string]$Username = '',
    [string]$Password = '',
    [switch]$ValidateOnly,
    [string]$BackupUrl = 'https://github.com/Microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorksLT2019.bak'
)

$ErrorActionPreference = 'Stop'

if (($Username -and -not $Password) -or ($Password -and -not $Username)) {
    throw 'Username and Password must be supplied together.'
}

function ConvertTo-SqlString {
    param([string]$Value)
    return $Value.Replace("'", "''")
}

function ConvertTo-SqlIdentifier {
    param([string]$Value)
    return '[' + $Value.Replace(']', ']]') + ']'
}

function New-SqlConnection {
    param([string]$InitialCatalog)

    $builder = [System.Data.Odbc.OdbcConnectionStringBuilder]::new()
    $builder.Driver = 'ODBC Driver 18 for SQL Server'
    $builder['Server'] = $Server
    $builder['Database'] = $InitialCatalog
    $builder['Encrypt'] = 'yes'
    $builder['TrustServerCertificate'] = 'yes'
    $builder['Connection Timeout'] = 15

    if ($Username) {
        $builder['UID'] = $Username
        $builder['PWD'] = $Password
    }
    else {
        $builder['Trusted_Connection'] = 'yes'
    }

    $connection = [System.Data.Odbc.OdbcConnection]::new($builder.ConnectionString)
    $connection.Open()
    return $connection
}

function Invoke-SqlScalar {
    param(
        [System.Data.Odbc.OdbcConnection]$Connection,
        [string]$Query,
        [int]$CommandTimeout = 30
    )

    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = $Query
        $command.CommandTimeout = $CommandTimeout
        return $command.ExecuteScalar()
    }
    finally {
        $command.Dispose()
    }
}

function Invoke-SqlTable {
    param(
        [System.Data.Odbc.OdbcConnection]$Connection,
        [string]$Query,
        [int]$CommandTimeout = 30
    )

    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = $Query
        $command.CommandTimeout = $CommandTimeout
        $reader = $command.ExecuteReader()
        try {
            $table = [System.Data.DataTable]::new()
            $table.Load($reader)
            return ,$table
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $command.Dispose()
    }
}

function Invoke-SqlNonQuery {
    param(
        [System.Data.Odbc.OdbcConnection]$Connection,
        [string]$Query,
        [int]$CommandTimeout = 30
    )

    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = $Query
        $command.CommandTimeout = $CommandTimeout
        $null = $command.ExecuteNonQuery()
    }
    finally {
        $command.Dispose()
    }
}

function Test-LocalServerName {
    $hostName = ($Server -replace '^(?i:tcp:)', '').Split('\')[0].Split(',')[0]
    return $hostName -in @('.', '(local)', 'localhost', '127.0.0.1', '::1', $env:COMPUTERNAME)
}

function Assert-AdventureWorksLt {
    $connection = New-SqlConnection -InitialCatalog $Database
    try {
        $counts = Invoke-SqlTable -Connection $connection -Query @'
IF OBJECT_ID(N'SalesLT.Product', N'U') IS NULL
    THROW 50000, 'AdventureWorksLT is missing SalesLT.Product.', 1;
IF OBJECT_ID(N'SalesLT.Customer', N'U') IS NULL
    THROW 50000, 'AdventureWorksLT is missing SalesLT.Customer.', 1;

SELECT
    (SELECT COUNT_BIG(*) FROM SalesLT.Product) AS ProductCount,
    (SELECT COUNT_BIG(*) FROM SalesLT.Customer) AS CustomerCount;
'@
        $productCount = [long]$counts.Rows[0].ProductCount
        $customerCount = [long]$counts.Rows[0].CustomerCount
        if ($productCount -ne 295 -or $customerCount -ne 847) {
            throw "Database $Database is not the expected AdventureWorksLT fixture: Product=$productCount (expected 295), Customer=$customerCount (expected 847)."
        }

        Write-Host "AdventureWorksLT ready: $Server/$Database (295 products, 847 customers)." -ForegroundColor Green
    }
    finally {
        $connection.Dispose()
    }
}

Write-Host "Checking AdventureWorksLT fixture on $Server/$Database..." -ForegroundColor Cyan

$masterConnection = New-SqlConnection -InitialCatalog 'master'
try {
    $databaseLiteral = ConvertTo-SqlString -Value $Database
    $databaseExists = [int](Invoke-SqlScalar -Connection $masterConnection -Query "SELECT CASE WHEN DB_ID(N'$databaseLiteral') IS NULL THEN 0 ELSE 1 END;")
    if ($databaseExists -eq 1) {
        Assert-AdventureWorksLt
        exit 0
    }

    if ($ValidateOnly) {
        throw "Database $Database does not exist on $Server. Rerun without -ValidateOnly to provision a local SQL Server."
    }

    $engineEdition = [int](Invoke-SqlScalar -Connection $masterConnection -Query "SELECT CONVERT(int, SERVERPROPERTY('EngineEdition'));")
    if ($engineEdition -in @(5, 6, 8)) {
        throw "Database $Database does not exist on $Server. Automatic .bak restore is not supported for this Azure SQL target; create or import AdventureWorksLT there first."
    }
    if (-not (Test-LocalServerName)) {
        throw "Database $Database does not exist on remote server $Server. Run this script on the SQL Server host or restore AdventureWorksLT there, then rerun with -ValidateOnly."
    }

    $backupDirectory = [string](Invoke-SqlScalar -Connection $masterConnection -Query "SELECT CONVERT(nvarchar(4000), SERVERPROPERTY('InstanceDefaultBackupPath'));")
    $dataDirectory = [string](Invoke-SqlScalar -Connection $masterConnection -Query "SELECT CONVERT(nvarchar(4000), SERVERPROPERTY('InstanceDefaultDataPath'));")
    $logDirectory = [string](Invoke-SqlScalar -Connection $masterConnection -Query "SELECT CONVERT(nvarchar(4000), SERVERPROPERTY('InstanceDefaultLogPath'));")
    if (-not $backupDirectory -or -not $dataDirectory -or -not $logDirectory) {
        throw 'SQL Server did not report its default backup, data, and log paths.'
    }

    $backupPath = Join-Path $backupDirectory 'AdventureWorksLT2019.bak'
    if (-not (Test-Path -LiteralPath $backupPath)) {
        Write-Host "Downloading Microsoft's AdventureWorksLT2019 backup..." -ForegroundColor Cyan
        try {
            Invoke-WebRequest -Uri $BackupUrl -OutFile $backupPath
        }
        catch {
            throw "Could not download the backup to SQL Server's backup directory '$backupDirectory'. Run from an elevated shell or grant write access, then retry. $($_.Exception.Message)"
        }
    }
    else {
        Write-Host "Using cached backup: $backupPath" -ForegroundColor DarkGray
    }

    $backupLiteral = ConvertTo-SqlString -Value $backupPath
    $files = Invoke-SqlTable -Connection $masterConnection -Query "RESTORE FILELISTONLY FROM DISK = N'$backupLiteral';"
    if ($files.Rows.Count -eq 0) {
        throw "The backup contains no database files: $backupPath"
    }

    $safeFileStem = $Database -replace '[^A-Za-z0-9_.-]', '_'
    $dataIndex = 0
    $logIndex = 0
    $moveClauses = foreach ($file in $files.Rows) {
        $logicalName = ConvertTo-SqlString -Value ([string]$file['LogicalName'])
        if ([string]$file['Type'] -eq 'L') {
            $logIndex++
            $suffix = if ($logIndex -eq 1) { '.ldf' } else { "_log$logIndex.ldf" }
            $physicalPath = Join-Path $logDirectory "$safeFileStem$suffix"
        }
        else {
            $dataIndex++
            $suffix = if ($dataIndex -eq 1) { '.mdf' } else { "_data$dataIndex.ndf" }
            $physicalPath = Join-Path $dataDirectory "$safeFileStem$suffix"
        }
        $physicalLiteral = ConvertTo-SqlString -Value $physicalPath
        "MOVE N'$logicalName' TO N'$physicalLiteral'"
    }

    $databaseIdentifier = ConvertTo-SqlIdentifier -Value $Database
    $restoreQuery = "RESTORE DATABASE $databaseIdentifier FROM DISK = N'$backupLiteral' WITH $($moveClauses -join ', '), RECOVERY, STATS = 5;"
    Write-Host "Restoring $Database..." -ForegroundColor Cyan
    Invoke-SqlNonQuery -Connection $masterConnection -Query $restoreQuery -CommandTimeout 0
}
finally {
    $masterConnection.Dispose()
}

Assert-AdventureWorksLt
