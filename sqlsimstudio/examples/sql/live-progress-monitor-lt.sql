-- Exercises the sqlsim Studio live monitor with a deliberately slow query
-- Requires AdventureWorksLT at compatibility level 160 or higher

-- AdventureWorksLT is a small sample: its largest table holds 847 rows, and
-- every query in sqlsim\examples\sql completes in under half a second. None of
-- them keep a connection busy long enough for the live monitor to report
-- anything but a completed execution. This query manufactures the missing
-- work so the monitor can be exercised without the full AdventureWorks
-- database.
--
-- GENERATE_SERIES supplies the row count instead of a table cross join, which
-- makes the cost dial predictable: rows evaluated is exactly 295 (the row count
-- of SalesLT.Product) multiplied by the series bound. Cross-joining the sample
-- tables against each other instead produces plan changes that break the
-- relationship between the dial and the duration -- tripling the row count was
-- measured to raise the duration only 20 percent.
--
-- SQRT over a float cast is what costs the time. The cast is required: the
-- product of three integer key columns overflows int. The predicate is always
-- true, so the row count returned is deterministic and the optimizer still has
-- to evaluate the expression for every row.
--
-- MAXDOP 1 holds the duration steady regardless of host core count. With
-- parallelism the optimizer absorbs the work and the query returns fast enough
-- to land inside a single one-second progress interval.
--
-- Cost dial -- edit the GENERATE_SERIES bound below:
--
--   Bound     Rows evaluated   Duration
--   8000       2,360,000       under 1.5 s   brief, completes within a tick or two
--   30000      8,850,000       2 s to 6 s    default; several ticks per execution
--   190000    56,050,000       25 s to 40 s  long enough to exercise cancellation
--
-- Durations were measured on an Intel i7-1370P with a warm cache. Treat them as
-- relative, not absolute. That part is a hybrid design, and identical runs land
-- in two distinct clusters roughly 2.3x apart depending on whether the worker
-- is scheduled on a performance or an efficiency core. Take the median of
-- several runs before reading anything into a timing change, and re-measure the
-- dial on each new host rather than carrying these numbers forward. A cold
-- cache roughly doubles the first execution.
--
-- Pair with Studio server statistics set to "Runtime messages" to see measured
-- average duration alongside the execution rate.
SELECT COUNT_BIG(*) AS EvaluatedRows
FROM SalesLT.Product p
CROSS JOIN GENERATE_SERIES(1, 30000) g
WHERE SQRT(ABS(CAST(p.ProductID AS float) * g.value) + 1) > 0.5
OPTION (MAXDOP 1);
