-- HEAVY tier -- runs on any SQL Server or Azure SQL database
--
-- The same tally shape as the medium query with roughly ten times the row
-- count, so a single execution spans many one-second progress ticks and the
-- live monitor reports connected-and-running before the first result lands.
--
-- MAXDOP 1 keeps the duration predictable across service objectives. Remove it
-- only if the point of the demo is to show parallelism absorbing the work.
--
-- On a busy shared instance this can exceed the default 30 second query
-- timeout. Raise Studio's Query timeout before running it at high concurrency.
WITH Tens(n) AS (
    SELECT 1 UNION ALL SELECT 1 UNION ALL SELECT 1 UNION ALL SELECT 1 UNION ALL
    SELECT 1 UNION ALL SELECT 1 UNION ALL SELECT 1 UNION ALL SELECT 1 UNION ALL
    SELECT 1 UNION ALL SELECT 1
),
Thousands(n) AS (SELECT 1 FROM Tens a CROSS JOIN Tens b CROSS JOIN Tens c),
Billions(n) AS (SELECT 1 FROM Thousands a CROSS JOIN Thousands b CROSS JOIN Thousands c),
Numbered AS (
    SELECT TOP 10000000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS Value
    FROM Billions
)
SELECT
    COUNT_BIG(*) AS RowsEvaluated,
    SUM(SQRT(ABS(CAST(Value AS float)) + 1)) AS Checksum
FROM Numbered
WHERE SQRT(ABS(CAST(Value AS float)) + 1) > 0.5
OPTION (MAXDOP 1);
