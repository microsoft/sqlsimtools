-- MEDIUM tier -- sqlsim Studio Query mode
-- Requires AdventureWorksLT. Runs on SQL Server 2019 and later, Azure SQL
-- Database, Azure SQL Managed Instance, and SQL database in Microsoft Fabric.

-- Suggested load: Connections (-n) 4, Iterations per connection (-r) 3
--
-- Measured roughly 1 to 3.5 seconds per execution on one connection, so each
-- execution spans several one-second progress ticks. This is the tier to use
-- when exercising live monitoring: the engine counts an execution only on
-- completion, so a faster query reports zero throughput for its whole duration.
--
-- The cost dial is the TOP value in the tally CTE below. Rows evaluated is that
-- value multiplied by 295, the row count of SalesLT.Product:
--
--   TOP       Rows evaluated   Duration
--   3000        885,000        under 1 s
--   10000     2,950,000        1 s to 3.5 s   this file
--   80000    23,600,000        9 s to 25 s    see heavy-query.sql
--
-- The tally CTE doubles a two-row seed twelve times to reach about 4 million
-- rows without touching a table, then TOP trims it to the requested count.
-- GENERATE_SERIES would be clearer but needs SQL Server 2022 or later, and
-- these files target 2019 as well.
--
-- SQRT over a float cast is what costs the time. The cast is required because
-- the product of two integer key columns overflows int. The predicate is always
-- true, so the returned count is deterministic while the optimizer still has to
-- evaluate the expression for every row.
--
-- MAXDOP 1 holds the duration steady regardless of host core count. With
-- parallelism the optimizer absorbs the work and the query can return inside a
-- single progress interval.
--
-- Durations were measured on an Intel i7-1370P against a warm cache. Treat them
-- as relative. On a hybrid-core host, identical runs land in two clusters more
-- than 2x apart depending on core scheduling, so take a median of several runs
-- before reading anything into a change.
WITH L0 AS (SELECT 1 AS c UNION ALL SELECT 1),
     L1 AS (SELECT a.c FROM L0 a CROSS JOIN L0 b),
     L2 AS (SELECT a.c FROM L1 a CROSS JOIN L1 b),
     L3 AS (SELECT a.c FROM L2 a CROSS JOIN L2 b),
     L4 AS (SELECT a.c FROM L3 a CROSS JOIN L3 b),
     L5 AS (SELECT a.c FROM L4 a CROSS JOIN L4 b),
     Tally AS (SELECT TOP (10000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM L5)
SELECT COUNT_BIG(*) AS EvaluatedRows
FROM SalesLT.Product p
CROSS JOIN Tally t
WHERE SQRT(ABS(CAST(p.ProductID AS float) * t.n) + 1) > 0.5
OPTION (MAXDOP 1);
