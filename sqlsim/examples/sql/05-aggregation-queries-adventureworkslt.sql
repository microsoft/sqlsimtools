-- Aggregation and GROUP BY operations for performance testing
-- AdventureWorksLT Database

-- Customer statistics
SELECT 
    COUNT(*) AS TotalCustomers,
    COUNT(DISTINCT CompanyName) AS UniqueCompanies,
    COUNT(DISTINCT EmailAddress) AS UniqueEmails
FROM SalesLT.Customer
GO

-- Product pricing statistics
SELECT 
    COUNT(*) AS TotalProducts,
    AVG(ListPrice) AS AvgListPrice,
    AVG(StandardCost) AS AvgStandardCost,
    MIN(ListPrice) AS MinPrice,
    MAX(ListPrice) AS MaxPrice,
    STDEV(ListPrice) AS StdDevPrice
FROM SalesLT.Product
WHERE ListPrice > 0
GO

-- Sales order statistics by year
SELECT 
    YEAR(OrderDate) AS OrderYear,
    COUNT(*) AS OrderCount,
    COUNT(DISTINCT CustomerID) AS UniqueCustomers,
    SUM(SubTotal) AS TotalSubTotal,
    SUM(TaxAmt) AS TotalTax,
    SUM(Freight) AS TotalFreight,
    SUM(SubTotal + TaxAmt + Freight) AS TotalRevenue,
    AVG(SubTotal + TaxAmt + Freight) AS AvgOrderValue,
    MIN(SubTotal + TaxAmt + Freight) AS MinOrderValue,
    MAX(SubTotal + TaxAmt + Freight) AS MaxOrderValue
FROM SalesLT.SalesOrderHeader
GROUP BY YEAR(OrderDate)
ORDER BY OrderYear
GO

-- Product sales by category with aggregations
SELECT 
    pc.Name AS CategoryName,
    COUNT(DISTINCT p.ProductID) AS ProductCount,
    COUNT(DISTINCT sod.SalesOrderID) AS OrderCount,
    SUM(sod.OrderQty) AS TotalUnitsSold,
    SUM(sod.OrderQty * sod.UnitPrice * (1 - sod.UnitPriceDiscount)) AS TotalRevenue,
    AVG(sod.UnitPrice) AS AvgUnitPrice,
    MAX(sod.OrderQty * sod.UnitPrice * (1 - sod.UnitPriceDiscount)) AS MaxLineTotal
FROM SalesLT.ProductCategory pc
LEFT JOIN SalesLT.Product p ON pc.ProductCategoryID = p.ProductCategoryID
LEFT JOIN SalesLT.SalesOrderDetail sod ON p.ProductID = sod.ProductID
GROUP BY pc.Name
ORDER BY TotalRevenue DESC
GO

-- Customer segmentation by order frequency
SELECT 
    CASE 
        WHEN OrderCount = 0 THEN 'No Orders'
        WHEN OrderCount = 1 THEN 'One-Time'
        WHEN OrderCount BETWEEN 2 AND 5 THEN 'Regular'
        ELSE 'Frequent'
    END AS CustomerSegment,
    COUNT(*) AS CustomerCount,
    AVG(TotalSpent) AS AvgTotalSpent,
    SUM(TotalSpent) AS TotalRevenue
FROM (
    SELECT 
        c.CustomerID,
        COUNT(soh.SalesOrderID) AS OrderCount,
        ISNULL(SUM(soh.SubTotal + soh.TaxAmt + soh.Freight), 0) AS TotalSpent
    FROM SalesLT.Customer c
    LEFT JOIN SalesLT.SalesOrderHeader soh ON c.CustomerID = soh.CustomerID
    GROUP BY c.CustomerID
) CustomerStats
GROUP BY 
    CASE 
        WHEN OrderCount = 0 THEN 'No Orders'
        WHEN OrderCount = 1 THEN 'One-Time'
        WHEN OrderCount BETWEEN 2 AND 5 THEN 'Regular'
        ELSE 'Frequent'
    END
ORDER BY CustomerCount DESC
GO

-- Geographic sales distribution
SELECT 
    a.CountryRegion,
    a.StateProvince,
    COUNT(DISTINCT soh.CustomerID) AS UniqueCustomers,
    COUNT(soh.SalesOrderID) AS OrderCount,
    SUM(soh.SubTotal + soh.TaxAmt + soh.Freight) AS TotalRevenue,
    AVG(soh.SubTotal + soh.TaxAmt + soh.Freight) AS AvgOrderValue
FROM SalesLT.SalesOrderHeader soh
INNER JOIN SalesLT.Address a ON soh.ShipToAddressID = a.AddressID
GROUP BY a.CountryRegion, a.StateProvince
ORDER BY TotalRevenue DESC
GO
