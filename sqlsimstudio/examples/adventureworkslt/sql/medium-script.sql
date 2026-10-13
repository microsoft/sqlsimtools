-- MEDIUM tier -- sqlsim Studio SQL file mode
-- Requires AdventureWorksLT. Runs on SQL Server 2019 and later, Azure SQL
-- Database, Azure SQL Managed Instance, and SQL database in Microsoft Fabric.

-- Suggested load: Connections (-n) 4, Iterations per connection (-r) 5
--
-- Three GO-separated batches that mix analytic shapes against the sample data,
-- plus one deliberately expensive batch so an iteration spans several progress
-- ticks. Expect roughly 1 to 4 seconds per iteration.

-- Batch 1: window functions over the order header.
SELECT
    soh.SalesOrderID,
    soh.CustomerID,
    soh.SubTotal,
    SUM(soh.SubTotal) OVER () AS GrandTotal,
    ROW_NUMBER() OVER (ORDER BY soh.SubTotal DESC) AS RevenueRank,
    COUNT(*) OVER (PARTITION BY soh.CustomerID) AS CustomerOrders
FROM SalesLT.SalesOrderHeader soh
ORDER BY soh.SubTotal DESC;
GO

-- Batch 2: four-table join aggregating every order line.
SELECT
    c.CompanyName,
    COUNT(DISTINCT soh.SalesOrderID) AS Orders,
    COUNT(sod.SalesOrderDetailID) AS LineItems,
    SUM(sod.OrderQty * sod.UnitPrice * (1 - sod.UnitPriceDiscount)) AS NetRevenue
FROM SalesLT.Customer c
INNER JOIN SalesLT.SalesOrderHeader soh ON c.CustomerID = soh.CustomerID
INNER JOIN SalesLT.SalesOrderDetail sod ON soh.SalesOrderID = sod.SalesOrderID
INNER JOIN SalesLT.Product p ON sod.ProductID = p.ProductID
GROUP BY c.CompanyName
ORDER BY NetRevenue DESC;
GO

-- Batch 3: the cost dial. See medium-query.sql for how the tally CTE works.
WITH L0 AS (SELECT 1 AS c UNION ALL SELECT 1),
     L1 AS (SELECT a.c FROM L0 a CROSS JOIN L0 b),
     L2 AS (SELECT a.c FROM L1 a CROSS JOIN L1 b),
     L3 AS (SELECT a.c FROM L2 a CROSS JOIN L2 b),
     L4 AS (SELECT a.c FROM L3 a CROSS JOIN L3 b),
     L5 AS (SELECT a.c FROM L4 a CROSS JOIN L4 b),
     Tally AS (SELECT TOP (8000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM L5)
SELECT COUNT_BIG(*) AS EvaluatedRows
FROM SalesLT.Product p
CROSS JOIN Tally t
WHERE SQRT(ABS(CAST(p.ProductID AS float) * t.n) + 1) > 0.5
OPTION (MAXDOP 1);
