-- Mixed read workload simulating OLTP operations
-- AdventureWorksLT Database
-- Designed to produce meaningful query stats across all metrics
-- Each query does enough work for non-zero CPU, reads, and elapsed time

-- Full customer scan with string computation
SELECT 
    CustomerID,
    UPPER(FirstName) + ' ' + REVERSE(LastName) AS NameHash,
    LEN(ISNULL(CompanyName, '')) + LEN(ISNULL(EmailAddress, '')) AS ContactLength,
    CHECKSUM(FirstName, LastName, EmailAddress) AS CustHash
FROM SalesLT.Customer
ORDER BY NEWID()
GO

-- Product cross-aggregation with category joins
SELECT 
    pc.Name AS Category,
    COUNT(p.ProductID) AS ProductCount,
    AVG(p.ListPrice) AS AvgPrice,
    STDEV(p.ListPrice) AS PriceStdDev,
    SUM(CASE WHEN p.ListPrice > p.StandardCost * 2 THEN 1 ELSE 0 END) AS HighMarginCount,
    MAX(p.ListPrice) - MIN(p.ListPrice) AS PriceRange
FROM SalesLT.Product p
INNER JOIN SalesLT.ProductCategory pc ON p.ProductCategoryID = pc.ProductCategoryID
GROUP BY pc.Name
ORDER BY COUNT(p.ProductID) DESC
GO

-- Full order detail scan with running computations
SELECT 
    sod.SalesOrderID,
    sod.ProductID,
    p.Name AS ProductName,
    sod.OrderQty,
    sod.UnitPrice,
    sod.OrderQty * sod.UnitPrice AS GrossAmount,
    sod.OrderQty * sod.UnitPrice * (1 - sod.UnitPriceDiscount) AS NetAmount,
    POWER(CAST(sod.UnitPrice AS float), 1.1) AS AdjustedPrice,
    CHECKSUM(p.Name, sod.SalesOrderID) AS ItemHash
FROM SalesLT.SalesOrderDetail sod
INNER JOIN SalesLT.Product p ON sod.ProductID = p.ProductID
ORDER BY NEWID()
GO

-- Customer-address-order three-way join with aggregation
SELECT 
    c.CustomerID,
    c.FirstName + ' ' + c.LastName AS CustomerName,
    a.City + ', ' + a.StateProvince AS Location,
    COUNT(DISTINCT soh.SalesOrderID) AS OrderCount,
    ISNULL(SUM(soh.SubTotal + soh.TaxAmt + soh.Freight), 0) AS TotalSpend,
    ISNULL(AVG(soh.SubTotal + soh.TaxAmt + soh.Freight), 0) AS AvgOrder
FROM SalesLT.Customer c
INNER JOIN SalesLT.CustomerAddress ca ON c.CustomerID = ca.CustomerID
INNER JOIN SalesLT.Address a ON ca.AddressID = a.AddressID
LEFT JOIN SalesLT.SalesOrderHeader soh ON c.CustomerID = soh.CustomerID
GROUP BY c.CustomerID, c.FirstName, c.LastName, a.City, a.StateProvince
ORDER BY ISNULL(SUM(soh.SubTotal + soh.TaxAmt + soh.Freight), 0) DESC
GO

-- Product self-comparison with correlated subquery
SELECT 
    p1.ProductID,
    p1.Name,
    p1.ListPrice,
    (SELECT COUNT(*) FROM SalesLT.Product p2 WHERE p2.ListPrice > p1.ListPrice) AS CheaperRank,
    (SELECT AVG(p3.ListPrice) FROM SalesLT.Product p3 WHERE p3.ProductCategoryID = p1.ProductCategoryID) AS CategoryAvg,
    p1.ListPrice - (SELECT AVG(p4.ListPrice) FROM SalesLT.Product p4 WHERE p4.ProductCategoryID = p1.ProductCategoryID) AS VsAvg
FROM SalesLT.Product p1
WHERE p1.ListPrice > 0
ORDER BY p1.ListPrice DESC
GO

-- Full address scan with string concatenation and hashing
SELECT 
    a.AddressID,
    a.AddressLine1 + ISNULL(', ' + a.AddressLine2, '') + ', ' + a.City + ', ' + a.StateProvince + ' ' + a.PostalCode AS FullAddress,
    LEN(a.AddressLine1) + LEN(a.City) + LEN(a.StateProvince) AS AddressLength,
    HASHBYTES('MD5', a.AddressLine1 + a.City + a.StateProvince) AS AddressHash,
    (SELECT COUNT(*) FROM SalesLT.CustomerAddress ca WHERE ca.AddressID = a.AddressID) AS CustomerCount
FROM SalesLT.Address a
ORDER BY a.City, a.StateProvince
GO

-- Product category hierarchy with deep aggregation
SELECT 
    pc.ProductCategoryID,
    pc.Name AS CategoryName,
    ISNULL(parent.Name, 'Top Level') AS ParentCategory,
    (SELECT COUNT(*) FROM SalesLT.Product p WHERE p.ProductCategoryID = pc.ProductCategoryID) AS DirectProducts,
    (SELECT ISNULL(SUM(sod.OrderQty), 0) 
     FROM SalesLT.SalesOrderDetail sod 
     INNER JOIN SalesLT.Product p ON sod.ProductID = p.ProductID 
     WHERE p.ProductCategoryID = pc.ProductCategoryID) AS TotalQtySold,
    (SELECT ISNULL(SUM(sod.OrderQty * sod.UnitPrice), 0)
     FROM SalesLT.SalesOrderDetail sod
     INNER JOIN SalesLT.Product p ON sod.ProductID = p.ProductID
     WHERE p.ProductCategoryID = pc.ProductCategoryID) AS TotalRevenue
FROM SalesLT.ProductCategory pc
LEFT JOIN SalesLT.ProductCategory parent ON pc.ParentProductCategoryID = parent.ProductCategoryID
ORDER BY pc.Name
GO

-- Sales analysis with window functions
SELECT 
    soh.SalesOrderID,
    soh.OrderDate,
    soh.CustomerID,
    (soh.SubTotal + soh.TaxAmt + soh.Freight) AS OrderTotal,
    SUM(soh.SubTotal + soh.TaxAmt + soh.Freight) OVER () AS GrandTotal,
    CAST((soh.SubTotal + soh.TaxAmt + soh.Freight) * 100.0 / SUM(soh.SubTotal + soh.TaxAmt + soh.Freight) OVER () AS decimal(5,2)) AS PctOfTotal,
    ROW_NUMBER() OVER (ORDER BY soh.SubTotal + soh.TaxAmt + soh.Freight DESC) AS RevenueRank,
    COUNT(*) OVER (PARTITION BY soh.CustomerID) AS CustOrderCount
FROM SalesLT.SalesOrderHeader soh
ORDER BY soh.SubTotal + soh.TaxAmt + soh.Freight DESC
GO

-- Cross-join derived product price matrix (CPU-intensive)
SELECT TOP 100
    p1.Name AS Product1,
    p2.Name AS Product2,
    p1.ListPrice + p2.ListPrice AS BundlePrice,
    ABS(p1.ListPrice - p2.ListPrice) AS PriceDiff,
    SQRT(POWER(p1.ListPrice, 2) + POWER(p2.ListPrice, 2)) AS PriceDistance
FROM SalesLT.Product p1
CROSS JOIN SalesLT.Product p2
WHERE p1.ProductID < p2.ProductID
    AND p1.ListPrice > 0 AND p2.ListPrice > 0
ORDER BY NEWID()
GO

-- Complete order-to-product revenue pipeline
SELECT 
    c.CompanyName,
    COUNT(DISTINCT a.City) AS CityCount,
    COUNT(DISTINCT soh.SalesOrderID) AS Orders,
    COUNT(sod.SalesOrderDetailID) AS LineItems,
    SUM(sod.OrderQty) AS TotalQty,
    SUM(sod.OrderQty * sod.UnitPrice * (1 - sod.UnitPriceDiscount)) AS NetRevenue,
    AVG(sod.OrderQty * sod.UnitPrice) AS AvgLineValue,
    MAX(sod.OrderQty * sod.UnitPrice) AS MaxLineValue
FROM SalesLT.Customer c
INNER JOIN SalesLT.CustomerAddress ca ON c.CustomerID = ca.CustomerID
INNER JOIN SalesLT.Address a ON ca.AddressID = a.AddressID
INNER JOIN SalesLT.SalesOrderHeader soh ON c.CustomerID = soh.CustomerID
INNER JOIN SalesLT.SalesOrderDetail sod ON soh.SalesOrderID = sod.SalesOrderID
GROUP BY c.CompanyName
HAVING COUNT(DISTINCT soh.SalesOrderID) > 0
ORDER BY SUM(sod.OrderQty * sod.UnitPrice * (1 - sod.UnitPriceDiscount)) DESC
GO
