-- LIGHT tier -- runs on any SQL Server or Azure SQL database
--
-- Reads the system catalog, which exists in every database, so this needs no
-- user schema and no sample data. Use it to prove a connection works and to
-- give the live monitor a steady, low-cost execution rate.
SELECT TOP 100
    o.name AS ObjectName,
    o.type_desc AS ObjectType,
    o.create_date AS CreatedUtc
FROM sys.objects AS o
ORDER BY o.name;
