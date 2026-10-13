-- Complex multi-table joins simulating real workloads
-- AdventureWorksLT Database

-- Complete product catalog with all relationships
SELECT TOP 30
    p.ProductID,
    p.Name AS ProductName,
    p.ProductNumber,
    p.Color,
    p.Size,
    p.Weight,
    p.ListPrice,
    pc.Name AS CategoryName,
    pm.Name AS ModelName,
    pmd.Description AS ModelDescription
FROM SalesLT.Product p
LEFT JOIN SalesLT.ProductCategory pc ON p.ProductCategoryID = pc.ProductCategoryID
LEFT JOIN SalesLT.ProductModel pm ON p.ProductModelID = pm.ProductModelID
LEFT JOIN SalesLT.ProductModelProductDescription pmpd ON pm.ProductModelID = pmpd.ProductModelID AND pmpd.Culture = 'en'
LEFT JOIN SalesLT.ProductDescription pmd ON pmpd.ProductDescriptionID = pmd.ProductDescriptionID
ORDER BY p.Name
GO

-- Complete customer profile with addresses and orders
SELECT TOP 20
    c.CustomerID,
    c.FirstName + ' ' + c.LastName AS CustomerName,
    c.CompanyName,
    c.EmailAddress,
    c.Phone,
    a.AddressLine1,
    a.City,
    a.StateProvince,
    a.CountryRegion,
    a.PostalCode,
    COUNT(DISTINCT soh.SalesOrderID) AS OrderCount,
    ISNULL(SUM(soh.SubTotal + soh.TaxAmt + soh.Freight), 0) AS TotalSpent,
    MAX(soh.OrderDate) AS LastOrderDate
FROM SalesLT.Customer c
LEFT JOIN SalesLT.CustomerAddress ca ON c.CustomerID = ca.CustomerID
LEFT JOIN SalesLT.Address a ON ca.AddressID = a.AddressID
LEFT JOIN SalesLT.SalesOrderHeader soh ON c.CustomerID = soh.CustomerID
GROUP BY 
    c.CustomerID, c.FirstName, c.LastName, c.CompanyName, c.EmailAddress, c.Phone,
    a.AddressLine1, a.City, a.StateProvince, a.CountryRegion, a.PostalCode
ORDER BY TotalSpent DESC
GO

-- Detailed order analysis with all related information
SELECT TOP 25
    soh.SalesOrderID,
    soh.OrderDate,
    soh.Status,
    c.FirstName + ' ' + c.LastName AS CustomerName,
    c.CompanyName,
    c.EmailAddress,
    ba.City AS BillToCity,
    ba.StateProvince AS BillToState,
    sa.City AS ShipToCity,
    sa.StateProvince AS ShipToState,
    soh.SubTotal,
    soh.TaxAmt,
    soh.Freight,
    (soh.SubTotal + soh.TaxAmt + soh.Freight) AS TotalDue,
    COUNT(sod.SalesOrderDetailID) AS LineItemCount,
    SUM(sod.OrderQty) AS TotalItems
FROM SalesLT.SalesOrderHeader soh
INNER JOIN SalesLT.Customer c ON soh.CustomerID = c.CustomerID
LEFT JOIN SalesLT.Address ba ON soh.BillToAddressID = ba.AddressID
LEFT JOIN SalesLT.Address sa ON soh.ShipToAddressID = sa.AddressID
LEFT JOIN SalesLT.SalesOrderDetail sod ON soh.SalesOrderID = sod.SalesOrderID
GROUP BY 
    soh.SalesOrderID, soh.OrderDate, soh.Status, c.FirstName, c.LastName,
    c.CompanyName, c.EmailAddress, ba.City, ba.StateProvince, sa.City, sa.StateProvince,
    soh.SubTotal, soh.TaxAmt, soh.Freight
ORDER BY soh.OrderDate DESC
GO

-- Product sales performance with customer insights
SELECT TOP 20
    p.ProductID,
    p.Name AS ProductName,
    pc.Name AS CategoryName,
    COUNT(DISTINCT sod.SalesOrderID) AS OrderCount,
    COUNT(DISTINCT soh.CustomerID) AS UniqueCustomers,
    SUM(sod.OrderQty) AS TotalQuantitySold,
    SUM(sod.OrderQty * sod.UnitPrice * (1 - sod.UnitPriceDiscount)) AS TotalRevenue,
    AVG(sod.UnitPrice) AS AvgSellingPrice,
    p.ListPrice,
    p.StandardCost,
    (SUM(sod.OrderQty * sod.UnitPrice * (1 - sod.UnitPriceDiscount)) - (SUM(sod.OrderQty) * p.StandardCost)) AS TotalProfit
FROM SalesLT.Product p
INNER JOIN SalesLT.ProductCategory pc ON p.ProductCategoryID = pc.ProductCategoryID
INNER JOIN SalesLT.SalesOrderDetail sod ON p.ProductID = sod.ProductID
INNER JOIN SalesLT.SalesOrderHeader soh ON sod.SalesOrderID = soh.SalesOrderID
GROUP BY 
    p.ProductID, p.Name, pc.Name, p.ListPrice, p.StandardCost
ORDER BY TotalRevenue DESC
GO

-- Sales order line items with full product and order details
SELECT TOP 50
    sod.SalesOrderID,
    sod.SalesOrderDetailID,
    soh.OrderDate,
    c.FirstName + ' ' + c.LastName AS CustomerName,
    p.Name AS ProductName,
    pc.Name AS CategoryName,
    sod.OrderQty,
    sod.UnitPrice,
    sod.UnitPriceDiscount,
    (sod.OrderQty * sod.UnitPrice * (1 - sod.UnitPriceDiscount)) AS LineTotal,
    p.StandardCost,
    ((sod.OrderQty * sod.UnitPrice * (1 - sod.UnitPriceDiscount)) - (sod.OrderQty * p.StandardCost)) AS LineProfit,
    a.City AS ShipToCity,
    a.StateProvince AS ShipToState
FROM SalesLT.SalesOrderDetail sod
INNER JOIN SalesLT.SalesOrderHeader soh ON sod.SalesOrderID = soh.SalesOrderID
INNER JOIN SalesLT.Customer c ON soh.CustomerID = c.CustomerID
INNER JOIN SalesLT.Product p ON sod.ProductID = p.ProductID
INNER JOIN SalesLT.ProductCategory pc ON p.ProductCategoryID = pc.ProductCategoryID
LEFT JOIN SalesLT.Address a ON soh.ShipToAddressID = a.AddressID
ORDER BY soh.OrderDate DESC, sod.SalesOrderID, sod.SalesOrderDetailID
GO
