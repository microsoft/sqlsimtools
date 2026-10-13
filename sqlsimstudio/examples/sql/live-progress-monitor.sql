-- Exercises the sqlsim Studio live monitor with a deliberately slow query
-- Requires AdventureWorks

-- Runs roughly 4.6 seconds on one connection, longer under concurrency, so the
-- monitor reports connected-and-running for several progress ticks before the
-- first result lands. The engine counts an execution only on completion.
--
-- MAXDOP 1 holds the duration steady regardless of host core count. With
-- parallelism the optimizer absorbs the work and the same query returns in
-- roughly 340 ms, well inside the one-second progress interval.
--
-- Pair with Studio server statistics set to "Runtime messages" to see measured
-- average duration alongside the execution rate.
SELECT COUNT_BIG(*) AS EvaluatedPairs
FROM Sales.SalesOrderDetail a
CROSS JOIN (
    SELECT TOP 200 p1.ProductID
    FROM Production.Product p1
    CROSS JOIN Production.Product p2
) b
WHERE SQRT(ABS(a.UnitPrice * b.ProductID) + 1) > 0.5
OPTION (MAXDOP 1);
