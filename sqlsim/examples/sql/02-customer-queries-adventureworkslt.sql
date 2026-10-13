-- Customer-focused queries
-- AdventureWorksLT Database

-- Get customers with email addresses
SELECT TOP 20
    CustomerID,
    FirstName,
    LastName,
    EmailAddress,
    Phone
FROM SalesLT.Customer
WHERE EmailAddress IS NOT NULL
ORDER BY LastName, FirstName
GO

-- Find customers by company name pattern
SELECT 
    CustomerID,
    FirstName,
    LastName,
    CompanyName
FROM SalesLT.Customer
WHERE CompanyName LIKE '%Bike%'
ORDER BY CompanyName
GO

-- Get customer count by title
SELECT 
    Title,
    COUNT(*) AS CustomerCount
FROM SalesLT.Customer
WHERE Title IS NOT NULL
GROUP BY Title
ORDER BY CustomerCount DESC
GO

-- Get customers with addresses
SELECT TOP 25
    c.CustomerID,
    c.FirstName,
    c.LastName,
    a.AddressLine1,
    a.City,
    a.StateProvince,
    a.CountryRegion
FROM SalesLT.Customer c
INNER JOIN SalesLT.CustomerAddress ca ON c.CustomerID = ca.CustomerID
INNER JOIN SalesLT.Address a ON ca.AddressID = a.AddressID
ORDER BY c.LastName, c.FirstName
GO

-- Customer distribution by state/province
SELECT 
    a.StateProvince,
    COUNT(DISTINCT c.CustomerID) AS CustomerCount
FROM SalesLT.Customer c
INNER JOIN SalesLT.CustomerAddress ca ON c.CustomerID = ca.CustomerID
INNER JOIN SalesLT.Address a ON ca.AddressID = a.AddressID
GROUP BY a.StateProvince
ORDER BY CustomerCount DESC
GO
