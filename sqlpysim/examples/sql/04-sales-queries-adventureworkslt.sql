-- Sales order queries with joins
-- AdventureWorksLT Database

-- Get recent sales orders
SELECT TOP 20
    SalesOrderID,
    OrderDate,
    CustomerID,
    SubTotal,
    TaxAmt,
    (SubTotal + TaxAmt + Freight) AS TotalDue,
    Status
FROM SalesLT.SalesOrderHeader
ORDER BY OrderDate DESC
GO

-- Get sales order details with product information
SELECT TOP 30
    soh.SalesOrderID,
    soh.OrderDate,
    sod.OrderQty,
    p.Name AS ProductName,
    sod.UnitPrice,
    (sod.OrderQty * sod.UnitPrice * (1 - sod.UnitPriceDiscount)) AS LineTotal
FROM SalesLT.SalesOrderHeader soh
INNER JOIN SalesLT.SalesOrderDetail sod ON soh.SalesOrderID = sod.SalesOrderID
INNER JOIN SalesLT.Product p ON sod.ProductID = p.ProductID
ORDER BY soh.OrderDate DESC, soh.SalesOrderID, sod.SalesOrderDetailID
GO

-- Get customer orders with totals
SELECT TOP 25
    c.CustomerID,
    c.FirstName,
    c.LastName,
    COUNT(soh.SalesOrderID) AS OrderCount,
    SUM(soh.SubTotal + soh.TaxAmt + soh.Freight) AS TotalSpent
FROM SalesLT.Customer c
INNER JOIN SalesLT.SalesOrderHeader soh ON c.CustomerID = soh.CustomerID
GROUP BY c.CustomerID, c.FirstName, c.LastName
ORDER BY TotalSpent DESC
GO

-- Get sales by product
SELECT TOP 20
    p.ProductID,
    p.Name AS ProductName,
    COUNT(DISTINCT sod.SalesOrderID) AS OrderCount,
    SUM(sod.OrderQty) AS TotalQuantitySold,
    SUM(sod.OrderQty * sod.UnitPrice * (1 - sod.UnitPriceDiscount)) AS TotalRevenue
FROM SalesLT.Product p
INNER JOIN SalesLT.SalesOrderDetail sod ON p.ProductID = sod.ProductID
GROUP BY p.ProductID, p.Name
ORDER BY TotalRevenue DESC
GO

-- Monthly sales summary
SELECT 
    YEAR(OrderDate) AS OrderYear,
    MONTH(OrderDate) AS OrderMonth,
    COUNT(SalesOrderID) AS OrderCount,
    SUM(SubTotal) AS TotalSubTotal,
    SUM(TaxAmt) AS TotalTax,
    SUM(SubTotal + TaxAmt + Freight) AS TotalRevenue
FROM SalesLT.SalesOrderHeader
GROUP BY YEAR(OrderDate), MONTH(OrderDate)
ORDER BY OrderYear, OrderMonth
GO

-- Get complete order information (customer, order, products)
SELECT TOP 15
    soh.SalesOrderID,
    soh.OrderDate,
    c.FirstName + ' ' + c.LastName AS CustomerName,
    c.CompanyName,
    a.City,
    a.StateProvince,
    soh.SubTotal,
    soh.TaxAmt,
    soh.Freight,
    (soh.SubTotal + soh.TaxAmt + soh.Freight) AS TotalDue
FROM SalesLT.SalesOrderHeader soh
INNER JOIN SalesLT.Customer c ON soh.CustomerID = c.CustomerID
LEFT JOIN SalesLT.Address a ON soh.ShipToAddressID = a.AddressID
ORDER BY soh.OrderDate DESC
GO
