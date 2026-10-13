-- LIGHT tier -- sqlsim Studio SQL file mode
-- Requires AdventureWorksLT. Runs on SQL Server 2019 and later, Azure SQL
-- Database, Azure SQL Managed Instance, and SQL database in Microsoft Fabric.

-- Suggested load: Connections (-n) 4, Iterations per connection (-r) 25
--
-- Four GO-separated batches, so Studio should report a batch count of 4 and
-- sqlsim executes all four per iteration. Every batch is a small read that
-- completes well under a second.

SELECT COUNT(*) AS CustomerCount FROM SalesLT.Customer;
GO

SELECT TOP 50 ProductID, Name, ListPrice
FROM SalesLT.Product
WHERE ListPrice > 0
ORDER BY ListPrice DESC;
GO

SELECT pc.Name AS Category, COUNT(p.ProductID) AS Products
FROM SalesLT.ProductCategory pc
LEFT JOIN SalesLT.Product p ON p.ProductCategoryID = pc.ProductCategoryID
GROUP BY pc.Name
ORDER BY pc.Name;
GO

SELECT TOP 25 SalesOrderID, OrderDate, CustomerID, SubTotal
FROM SalesLT.SalesOrderHeader
ORDER BY SubTotal DESC;
