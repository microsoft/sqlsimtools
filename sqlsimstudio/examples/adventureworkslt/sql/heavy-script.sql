-- HEAVY tier -- sqlsim Studio SQL file mode
-- Requires AdventureWorksLT. Runs on SQL Server 2019 and later, Azure SQL
-- Database, Azure SQL Managed Instance, and SQL database in Microsoft Fabric.

-- Suggested load: Connections (-n) 8, Iterations per connection (-r) 2
--
-- Three GO-separated batches, each deliberately expensive, so one iteration
-- runs for tens of seconds. Use it for cancellation, sustained progress
-- reporting, and connection-pressure checks.
--
-- Raise the Query timeout above its 30 second default before running this tier.
-- On Azure SQL Database, start at half these connections.

-- Batch 1: correlated subqueries evaluated per product row.
SELECT
    p1.ProductID,
    p1.Name,
    p1.ListPrice,
    (SELECT COUNT(*) FROM SalesLT.Product p2 WHERE p2.ListPrice > p1.ListPrice) AS CheaperRank,
    (SELECT AVG(p3.ListPrice) FROM SalesLT.Product p3 WHERE p3.ProductCategoryID = p1.ProductCategoryID) AS CategoryAvg
FROM SalesLT.Product p1
WHERE p1.ListPrice > 0
ORDER BY p1.ListPrice DESC;
GO

-- Batch 2: self cross join over the product catalog with per-row arithmetic.
SELECT COUNT_BIG(*) AS EvaluatedPairs
FROM SalesLT.Product a
CROSS JOIN SalesLT.Product b
CROSS JOIN SalesLT.ProductCategory c
WHERE SQRT(ABS(CAST(a.ProductID AS float) * b.ProductID * c.ProductCategoryID) + 1) > 0.5
OPTION (MAXDOP 1);
GO

-- Batch 3: the cost dial. See medium-query.sql for how the tally CTE works.
WITH L0 AS (SELECT 1 AS c UNION ALL SELECT 1),
     L1 AS (SELECT a.c FROM L0 a CROSS JOIN L0 b),
     L2 AS (SELECT a.c FROM L1 a CROSS JOIN L1 b),
     L3 AS (SELECT a.c FROM L2 a CROSS JOIN L2 b),
     L4 AS (SELECT a.c FROM L3 a CROSS JOIN L3 b),
     L5 AS (SELECT a.c FROM L4 a CROSS JOIN L4 b),
     Tally AS (SELECT TOP (60000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM L5)
SELECT COUNT_BIG(*) AS EvaluatedRows
FROM SalesLT.Product p
CROSS JOIN Tally t
WHERE SQRT(ABS(CAST(p.ProductID AS float) * t.n) + 1) > 0.5
OPTION (MAXDOP 1);
