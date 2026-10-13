-- Mixed read workload simulating OLTP operations
-- AdventureWorksLT Database
-- This is ideal for load testing with multiple threads

-- Quick customer lookup by ID
SELECT TOP 1
    CustomerID,
    FirstName,
    LastName,
    CompanyName,
    EmailAddress
FROM SalesLT.Customer
WHERE CustomerID = (SELECT TOP 1 CustomerID FROM SalesLT.Customer ORDER BY NEWID())
GO

-- Product search by name pattern
SELECT TOP 5
    ProductID,
    Name,
    ProductNumber,
    ListPrice
FROM SalesLT.Product
WHERE Name LIKE '%' + (SELECT TOP 1 LEFT(Name, 3) FROM SalesLT.Product ORDER BY NEWID()) + '%'
ORDER BY Name
GO

-- Get customer's recent orders
SELECT TOP 3
    soh.SalesOrderID,
    soh.OrderDate,
    (soh.SubTotal + soh.TaxAmt + soh.Freight) AS TotalDue,
    soh.Status
FROM SalesLT.SalesOrderHeader soh
WHERE soh.CustomerID = (SELECT TOP 1 CustomerID FROM SalesLT.Customer ORDER BY NEWID())
ORDER BY soh.OrderDate DESC
GO

-- Product inventory check (simulated)
SELECT TOP 10
    ProductID,
    Name,
    ListPrice,
    StandardCost,
    (ListPrice - StandardCost) AS Margin
FROM SalesLT.Product
WHERE ListPrice > 0
ORDER BY NEWID()
GO

-- Sales order detail lookup
SELECT TOP 10
    sod.SalesOrderID,
    sod.ProductID,
    p.Name AS ProductName,
    sod.OrderQty,
    sod.UnitPrice,
    (sod.OrderQty * sod.UnitPrice * (1 - sod.UnitPriceDiscount)) AS LineTotal
FROM SalesLT.SalesOrderDetail sod
INNER JOIN SalesLT.Product p ON sod.ProductID = p.ProductID
WHERE sod.SalesOrderID = (SELECT TOP 1 SalesOrderID FROM SalesLT.SalesOrderHeader ORDER BY NEWID())
GO

-- Customer address lookup
SELECT TOP 1
    c.CustomerID,
    c.FirstName + ' ' + c.LastName AS CustomerName,
    a.AddressLine1,
    a.City,
    a.StateProvince,
    a.PostalCode
FROM SalesLT.Customer c
INNER JOIN SalesLT.CustomerAddress ca ON c.CustomerID = ca.CustomerID
INNER JOIN SalesLT.Address a ON ca.AddressID = a.AddressID
WHERE c.CustomerID = (SELECT TOP 1 CustomerID FROM SalesLT.Customer ORDER BY NEWID())
GO

-- Product category listing
SELECT 
    ProductCategoryID,
    Name,
    (SELECT COUNT(*) FROM SalesLT.Product p WHERE p.ProductCategoryID = pc.ProductCategoryID) AS ProductCount
FROM SalesLT.ProductCategory pc
ORDER BY Name
GO

-- Quick sales summary
SELECT 
    COUNT(*) AS TodaysOrders,
    ISNULL(SUM(SubTotal + TaxAmt + Freight), 0) AS TodaysRevenue
FROM SalesLT.SalesOrderHeader
WHERE CAST(OrderDate AS DATE) = CAST(GETDATE() AS DATE)
GO

-- Top selling products (lightweight version)
SELECT TOP 5
    p.ProductID,
    p.Name,
    COUNT(sod.SalesOrderID) AS OrderCount
FROM SalesLT.Product p
INNER JOIN SalesLT.SalesOrderDetail sod ON p.ProductID = sod.ProductID
GROUP BY p.ProductID, p.Name
ORDER BY NEWID()
GO

-- Random customer order history
SELECT TOP 5
    soh.SalesOrderID,
    soh.OrderDate,
    COUNT(sod.SalesOrderDetailID) AS ItemCount,
    (soh.SubTotal + soh.TaxAmt + soh.Freight) AS TotalDue
FROM SalesLT.SalesOrderHeader soh
INNER JOIN SalesLT.SalesOrderDetail sod ON soh.SalesOrderID = sod.SalesOrderID
WHERE soh.CustomerID = (SELECT TOP 1 CustomerID FROM SalesLT.Customer ORDER BY NEWID())
GROUP BY soh.SalesOrderID, soh.OrderDate, soh.SubTotal, soh.TaxAmt, soh.Freight
ORDER BY soh.OrderDate DESC
GO
