-- INSERT operations test (creates and cleans up temporary data)
-- AdventureWorksLT Database
-- WARNING: This creates a temporary table and inserts test data

-- Create a temporary test table
IF OBJECT_ID('tempdb..#TestOrders') IS NOT NULL
    DROP TABLE #TestOrders
GO

CREATE TABLE #TestOrders (
    TestOrderID INT IDENTITY(1,1) PRIMARY KEY,
    CustomerID INT NOT NULL,
    OrderDate DATETIME NOT NULL,
    SubTotal MONEY NOT NULL,
    TaxAmt MONEY NOT NULL,
    TotalDue MONEY NOT NULL,
    CreatedDate DATETIME DEFAULT GETDATE()
)
GO

-- Insert test orders based on existing customer data
INSERT INTO #TestOrders (CustomerID, OrderDate, SubTotal, TaxAmt, TotalDue)
SELECT TOP 10
    CustomerID,
    GETDATE() AS OrderDate,
    RAND(CHECKSUM(NEWID())) * 1000 AS SubTotal,
    RAND(CHECKSUM(NEWID())) * 100 AS TaxAmt,
    RAND(CHECKSUM(NEWID())) * 1100 AS TotalDue
FROM SalesLT.Customer
ORDER BY NEWID()
GO

-- Verify the inserts
SELECT 
    COUNT(*) AS InsertedRecords,
    MIN(OrderDate) AS MinOrderDate,
    MAX(OrderDate) AS MaxOrderDate,
    SUM(TotalDue) AS TotalAmount
FROM #TestOrders
GO

-- Create another temp table for order details
IF OBJECT_ID('tempdb..#TestOrderDetails') IS NOT NULL
    DROP TABLE #TestOrderDetails
GO

CREATE TABLE #TestOrderDetails (
    TestOrderDetailID INT IDENTITY(1,1) PRIMARY KEY,
    TestOrderID INT NOT NULL,
    ProductID INT NOT NULL,
    OrderQty SMALLINT NOT NULL,
    UnitPrice MONEY NOT NULL,
    LineTotal MONEY NOT NULL
)
GO

-- Insert test order details
INSERT INTO #TestOrderDetails (TestOrderID, ProductID, OrderQty, UnitPrice, LineTotal)
SELECT TOP 50
    t.TestOrderID,
    p.ProductID,
    CAST(RAND(CHECKSUM(NEWID())) * 10 + 1 AS SMALLINT) AS OrderQty,
    p.ListPrice AS UnitPrice,
    (CAST(RAND(CHECKSUM(NEWID())) * 10 + 1 AS SMALLINT) * p.ListPrice) AS LineTotal
FROM #TestOrders t
CROSS APPLY (
    SELECT TOP 5 ProductID, ListPrice
    FROM SalesLT.Product
    WHERE ListPrice > 0
    ORDER BY NEWID()
) p
GO

-- Verify order details inserts
SELECT 
    COUNT(*) AS TotalLineItems,
    COUNT(DISTINCT TestOrderID) AS OrdersWithDetails,
    SUM(OrderQty) AS TotalQuantity,
    SUM(LineTotal) AS TotalLineAmount
FROM #TestOrderDetails
GO

-- Join test tables to simulate order processing query
SELECT TOP 20
    t.TestOrderID,
    t.CustomerID,
    t.OrderDate,
    c.FirstName + ' ' + c.LastName AS CustomerName,
    COUNT(d.TestOrderDetailID) AS LineItemCount,
    SUM(d.OrderQty) AS TotalItems,
    SUM(d.LineTotal) AS CalculatedTotal,
    t.TotalDue AS OrderTotal
FROM #TestOrders t
INNER JOIN SalesLT.Customer c ON t.CustomerID = c.CustomerID
LEFT JOIN #TestOrderDetails d ON t.TestOrderID = d.TestOrderID
GROUP BY 
    t.TestOrderID, t.CustomerID, t.OrderDate, 
    c.FirstName, c.LastName, t.TotalDue
ORDER BY t.TestOrderID
GO

-- Cleanup: Drop temporary tables
DROP TABLE IF EXISTS #TestOrderDetails
DROP TABLE IF EXISTS #TestOrders
GO

-- Verify cleanup
SELECT 'Test tables cleaned up successfully' AS Status
GO
