-- Simple queries using catalog views to verify connectivity and basic functionality
-- Works against any SQL Server database (no AdventureWorks required)

-- Get database version and name
SELECT @@VERSION AS SqlVersion, @@SERVERNAME AS ServerName, DB_NAME() AS DatabaseName
GO

-- Get current date and time
SELECT GETDATE() AS CurrentDateTime, CURRENT_USER AS CurrentUser
GO

-- List all databases (visible to current user)
SELECT name AS DatabaseName, database_id, create_date, compatibility_level
FROM sys.databases
ORDER BY name
GO

-- List tables in current database
SELECT 
    SCHEMA_NAME(schema_id) AS SchemaName,
    name AS TableName,
    create_date,
    modify_date
FROM sys.tables
ORDER BY SchemaName, TableName
GO

-- List views in current database
SELECT 
    SCHEMA_NAME(schema_id) AS SchemaName,
    name AS ViewName,
    create_date
FROM sys.views
ORDER BY SchemaName, ViewName
GO

-- Get database file information
SELECT 
    name AS FileName,
    physical_name AS FilePath,
    size * 8 / 1024 AS SizeMB,
    type_desc AS FileType
FROM sys.database_files
GO

-- Get table row counts (top 10 largest tables)
SELECT TOP 10
    SCHEMA_NAME(t.schema_id) AS SchemaName,
    t.name AS TableName,
    SUM(p.rows) AS TotalRows
FROM sys.tables t
INNER JOIN sys.partitions p ON t.object_id = p.object_id
WHERE p.index_id IN (0, 1)
GROUP BY t.schema_id, t.name
ORDER BY SUM(p.rows) DESC
GO
