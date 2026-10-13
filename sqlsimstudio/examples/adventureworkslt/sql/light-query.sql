-- LIGHT tier -- sqlsim Studio Query mode
-- Requires AdventureWorksLT. Runs on SQL Server 2019 and later, Azure SQL
-- Database, Azure SQL Managed Instance, and SQL database in Microsoft Fabric.

-- Suggested load: Connections (-n) 4, Iterations per connection (-r) 50
--
-- Reads a few hundred rows from the three largest SalesLT tables. Measured at
-- well under one second per execution, so the run is dominated by connection
-- and iteration overhead rather than server work. Use it to confirm a target is
-- reachable and to exercise Studio's Results page with a run that finishes
-- quickly.
SELECT TOP 100
    c.CustomerID,
    c.FirstName + ' ' + c.LastName AS CustomerName,
    c.CompanyName,
    a.City,
    a.StateProvince
FROM SalesLT.Customer c
INNER JOIN SalesLT.CustomerAddress ca ON c.CustomerID = ca.CustomerID
INNER JOIN SalesLT.Address a ON ca.AddressID = a.AddressID
ORDER BY c.CustomerID;
