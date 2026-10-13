-- MEDIUM tier -- runs on any SQL Server or Azure SQL database
--
-- A tally CTE generates rows in memory rather than reading a table, so the
-- cost is real server CPU with no dependency on any schema or data volume.
-- That makes the duration comparable between an empty database and a loaded
-- one, which a catalog query cannot offer.
--
-- MAXDOP 1 holds the duration steady regardless of how many cores the service
-- objective provides. Without it, a higher tier absorbs the work and the query
-- returns too quickly for the one-second progress interval to show anything.
--
-- The source supplies up to a billion rows, so TOP is what actually sets the
-- cost: TOP 4000000 is roughly twice the work of TOP 2000000. Confirm any
-- change by reading RowsEvaluated in the result, which reports the rows the
-- query really processed.
WITH Tens(n) AS (
    SELECT 1 UNION ALL SELECT 1 UNION ALL SELECT 1 UNION ALL SELECT 1 UNION ALL
    SELECT 1 UNION ALL SELECT 1 UNION ALL SELECT 1 UNION ALL SELECT 1 UNION ALL
    SELECT 1 UNION ALL SELECT 1
),
Thousands(n) AS (SELECT 1 FROM Tens a CROSS JOIN Tens b CROSS JOIN Tens c),
Billions(n) AS (SELECT 1 FROM Thousands a CROSS JOIN Thousands b CROSS JOIN Thousands c),
Numbered AS (
    SELECT TOP 2000000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS Value
    FROM Billions
)
SELECT
    COUNT_BIG(*) AS RowsEvaluated,
    SUM(SQRT(ABS(CAST(Value AS float)) + 1)) AS Checksum
FROM Numbered
WHERE SQRT(ABS(CAST(Value AS float)) + 1) > 0.5
OPTION (MAXDOP 1);
