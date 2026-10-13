-- HEAVY tier -- sqlsim Studio Query mode
-- Requires AdventureWorksLT. Runs on SQL Server 2019 and later, Azure SQL
-- Database, Azure SQL Managed Instance, and SQL database in Microsoft Fabric.

-- Suggested load: Connections (-n) 8, Iterations per connection (-r) 2
--
-- Measured roughly 9 to 25 seconds per execution on one connection, and longer
-- under concurrency. Use it to exercise cancellation, long-running progress
-- reporting, and the query timeout.
--
-- Raise the Query timeout above its 30 second default before running this tier.
-- Under eight connections a single execution can exceed 30 seconds and the run
-- will fail with a timeout, which is a valid test but not this one.
--
-- On Azure SQL Database, start at half these connections. On a small service
-- tier the heavy tier measures throttling rather than client behavior.
--
-- The cost dial is the TOP value in the tally CTE. See medium-query.sql for the
-- full explanation of the CTE, the float cast, MAXDOP 1, and why measured
-- durations vary on hybrid-core hosts.
WITH L0 AS (SELECT 1 AS c UNION ALL SELECT 1),
     L1 AS (SELECT a.c FROM L0 a CROSS JOIN L0 b),
     L2 AS (SELECT a.c FROM L1 a CROSS JOIN L1 b),
     L3 AS (SELECT a.c FROM L2 a CROSS JOIN L2 b),
     L4 AS (SELECT a.c FROM L3 a CROSS JOIN L3 b),
     L5 AS (SELECT a.c FROM L4 a CROSS JOIN L4 b),
     Tally AS (SELECT TOP (80000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM L5)
SELECT COUNT_BIG(*) AS EvaluatedRows
FROM SalesLT.Product p
CROSS JOIN Tally t
WHERE SQRT(ABS(CAST(p.ProductID AS float) * t.n) + 1) > 0.5
OPTION (MAXDOP 1);
