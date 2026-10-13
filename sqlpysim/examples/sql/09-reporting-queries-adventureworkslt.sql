-- Analytical/reporting queries simulating business intelligence workload
-- AdventureWorksLT Database
-- These queries are more resource-intensive for load testing

-- Sales performance dashboard
SELECT 
    'Sales Summary' AS ReportSection,
    COUNT(DISTINCT soh.SalesOrderID) AS TotalOrders,
    COUNT(DISTINCT soh.CustomerID) AS UniqueCustomers,
    COUNT(DISTINCT sod.ProductID) AS ProductsSold,
    SUM(sod.OrderQty) AS TotalUnitsSold,
    SUM(soh.SubTotal) AS TotalSubTotal,
    SUM(soh.TaxAmt) AS TotalTax,
    SUM(soh.Freight) AS TotalFreight,
    SUM(soh.SubTotal + soh.TaxAmt + soh.Freight) AS TotalRevenue,
    AVG(soh.SubTotal + soh.TaxAmt + soh.Freight) AS AvgOrderValue
FROM SalesLT.SalesOrderHeader soh
INNER JOIN SalesLT.SalesOrderDetail sod ON soh.SalesOrderID = sod.SalesOrderID
GO

-- Monthly sales trend analysis
SELECT 
    YEAR(OrderDate) AS SalesYear,
    MONTH(OrderDate) AS SalesMonth,
    DATENAME(MONTH, OrderDate) AS MonthName,
    COUNT(DISTINCT SalesOrderID) AS OrderCount,
    COUNT(DISTINCT CustomerID) AS UniqueCustomers,
    SUM(SubTotal) AS SubTotal,
    SUM(TaxAmt) AS Tax,
    SUM(Freight) AS Freight,
    SUM(SubTotal + TaxAmt + Freight) AS TotalRevenue,
    AVG(SubTotal + TaxAmt + Freight) AS AvgOrderValue,
    MIN(SubTotal + TaxAmt + Freight) AS MinOrderValue,
    MAX(SubTotal + TaxAmt + Freight) AS MaxOrderValue
FROM SalesLT.SalesOrderHeader
GROUP BY YEAR(OrderDate), MONTH(OrderDate), DATENAME(MONTH, OrderDate)
ORDER BY SalesYear, SalesMonth
GO

-- Top customers by revenue
SELECT TOP 20
    c.CustomerID,
    c.FirstName + ' ' + c.LastName AS CustomerName,
    c.CompanyName,
    c.EmailAddress,
    COUNT(DISTINCT soh.SalesOrderID) AS TotalOrders,
    SUM(soh.SubTotal + soh.TaxAmt + soh.Freight) AS TotalRevenue,
    AVG(soh.SubTotal + soh.TaxAmt + soh.Freight) AS AvgOrderValue,
    MIN(soh.OrderDate) AS FirstOrderDate,
    MAX(soh.OrderDate) AS LastOrderDate,
    DATEDIFF(DAY, MIN(soh.OrderDate), MAX(soh.OrderDate)) AS CustomerLifespanDays
FROM SalesLT.Customer c
INNER JOIN SalesLT.SalesOrderHeader soh ON c.CustomerID = soh.CustomerID
GROUP BY c.CustomerID, c.FirstName, c.LastName, c.CompanyName, c.EmailAddress
ORDER BY TotalRevenue DESC
GO

-- Product category performance analysis
SELECT 
    pc.Name AS CategoryName,
    COUNT(DISTINCT p.ProductID) AS ProductCount,
    COUNT(DISTINCT sod.SalesOrderID) AS OrderCount,
    SUM(sod.OrderQty) AS TotalUnitsSold,
    SUM(sod.OrderQty * sod.UnitPrice * (1 - sod.UnitPriceDiscount)) AS TotalRevenue,
    AVG(sod.UnitPrice) AS AvgSellingPrice,
    AVG(p.ListPrice) AS AvgListPrice,
    AVG(p.StandardCost) AS AvgCost,
    SUM(sod.OrderQty * sod.UnitPrice * (1 - sod.UnitPriceDiscount)) - SUM(sod.OrderQty * p.StandardCost) AS EstimatedProfit,
    (SUM(sod.OrderQty * sod.UnitPrice * (1 - sod.UnitPriceDiscount)) - SUM(sod.OrderQty * p.StandardCost)) / NULLIF(SUM(sod.OrderQty * sod.UnitPrice * (1 - sod.UnitPriceDiscount)), 0) * 100 AS ProfitMarginPct
FROM SalesLT.ProductCategory pc
LEFT JOIN SalesLT.Product p ON pc.ProductCategoryID = p.ProductCategoryID
LEFT JOIN SalesLT.SalesOrderDetail sod ON p.ProductID = sod.ProductID
GROUP BY pc.Name
ORDER BY TotalRevenue DESC
GO

-- Geographic sales analysis
SELECT 
    a.CountryRegion,
    a.StateProvince,
    COUNT(DISTINCT c.CustomerID) AS CustomerCount,
    COUNT(DISTINCT soh.SalesOrderID) AS OrderCount,
    SUM(soh.SubTotal + soh.TaxAmt + soh.Freight) AS TotalRevenue,
    AVG(soh.SubTotal + soh.TaxAmt + soh.Freight) AS AvgOrderValue,
    SUM(soh.SubTotal + soh.TaxAmt + soh.Freight) / NULLIF(COUNT(DISTINCT c.CustomerID), 0) AS RevenuePerCustomer
FROM SalesLT.Address a
INNER JOIN SalesLT.SalesOrderHeader soh ON a.AddressID = soh.ShipToAddressID
INNER JOIN SalesLT.Customer c ON soh.CustomerID = c.CustomerID
GROUP BY a.CountryRegion, a.StateProvince
ORDER BY TotalRevenue DESC
GO

-- Product profitability analysis
SELECT TOP 30
    p.ProductID,
    p.Name AS ProductName,
    pc.Name AS CategoryName,
    p.ListPrice,
    p.StandardCost,
    p.ListPrice - p.StandardCost AS GrossMargin,
    CASE 
        WHEN p.StandardCost > 0 THEN ((p.ListPrice - p.StandardCost) / p.StandardCost * 100)
        ELSE 0 
    END AS MarginPercentage,
    COUNT(DISTINCT sod.SalesOrderID) AS OrderCount,
    SUM(sod.OrderQty) AS UnitsSold,
    SUM(sod.OrderQty * sod.UnitPrice * (1 - sod.UnitPriceDiscount)) AS TotalRevenue,
    SUM(sod.OrderQty * sod.UnitPrice * (1 - sod.UnitPriceDiscount)) - (SUM(sod.OrderQty) * p.StandardCost) AS ActualProfit
FROM SalesLT.Product p
LEFT JOIN SalesLT.ProductCategory pc ON p.ProductCategoryID = pc.ProductCategoryID
LEFT JOIN SalesLT.SalesOrderDetail sod ON p.ProductID = sod.ProductID
GROUP BY 
    p.ProductID, p.Name, pc.Name, p.ListPrice, p.StandardCost
ORDER BY ActualProfit DESC
GO

-- Customer lifetime value analysis
SELECT 
    CustomerSegment,
    COUNT(*) AS CustomerCount,
    AVG(TotalOrders) AS AvgOrders,
    AVG(TotalRevenue) AS AvgLifetimeValue,
    SUM(TotalRevenue) AS TotalSegmentRevenue,
    AVG(AvgOrderValue) AS AvgOrderValue,
    AVG(DaysSinceFirstOrder) AS AvgCustomerAge
FROM (
    SELECT 
        c.CustomerID,
        CASE 
            WHEN COUNT(soh.SalesOrderID) = 0 THEN 'No Orders'
            WHEN COUNT(soh.SalesOrderID) = 1 THEN 'One-Time'
            WHEN COUNT(soh.SalesOrderID) BETWEEN 2 AND 3 THEN 'Occasional'
            WHEN COUNT(soh.SalesOrderID) BETWEEN 4 AND 6 THEN 'Regular'
            ELSE 'Loyal'
        END AS CustomerSegment,
        COUNT(soh.SalesOrderID) AS TotalOrders,
        ISNULL(SUM(soh.SubTotal + soh.TaxAmt + soh.Freight), 0) AS TotalRevenue,
        ISNULL(AVG(soh.SubTotal + soh.TaxAmt + soh.Freight), 0) AS AvgOrderValue,
        DATEDIFF(DAY, MIN(soh.OrderDate), GETDATE()) AS DaysSinceFirstOrder
    FROM SalesLT.Customer c
    LEFT JOIN SalesLT.SalesOrderHeader soh ON c.CustomerID = soh.CustomerID
    GROUP BY c.CustomerID
) CustomerMetrics
GROUP BY CustomerSegment
ORDER BY TotalSegmentRevenue DESC
GO
