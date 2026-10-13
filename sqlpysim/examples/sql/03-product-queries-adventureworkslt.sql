-- Product catalog queries
-- AdventureWorksLT Database

-- Get all product categories
SELECT 
    ProductCategoryID,
    Name AS CategoryName,
    ModifiedDate
FROM SalesLT.ProductCategory
ORDER BY Name
GO

-- Get products with their categories
SELECT TOP 30
    p.ProductID,
    p.Name AS ProductName,
    p.ProductNumber,
    pc.Name AS CategoryName,
    p.StandardCost,
    p.ListPrice,
    p.ListPrice - p.StandardCost AS ProfitMargin
FROM SalesLT.Product p
LEFT JOIN SalesLT.ProductCategory pc ON p.ProductCategoryID = pc.ProductCategoryID
ORDER BY p.Name
GO

-- Get products by price range
SELECT 
    ProductID,
    Name,
    ListPrice,
    CASE 
        WHEN ListPrice < 100 THEN 'Budget'
        WHEN ListPrice < 500 THEN 'Mid-Range'
        WHEN ListPrice < 1000 THEN 'Premium'
        ELSE 'Luxury'
    END AS PriceCategory
FROM SalesLT.Product
WHERE ListPrice > 0
ORDER BY ListPrice
GO

-- Product count by category
SELECT 
    pc.Name AS CategoryName,
    COUNT(p.ProductID) AS ProductCount,
    AVG(p.ListPrice) AS AvgPrice,
    MIN(p.ListPrice) AS MinPrice,
    MAX(p.ListPrice) AS MaxPrice
FROM SalesLT.ProductCategory pc
LEFT JOIN SalesLT.Product p ON pc.ProductCategoryID = p.ProductCategoryID
GROUP BY pc.Name
ORDER BY ProductCount DESC
GO

-- Get product models with descriptions
SELECT TOP 20
    pm.ProductModelID,
    pm.Name AS ModelName,
    pmd.Description
FROM SalesLT.ProductModel pm
LEFT JOIN SalesLT.ProductModelProductDescription pmpd ON pm.ProductModelID = pmpd.ProductModelID
LEFT JOIN SalesLT.ProductDescription pmd ON pmpd.ProductDescriptionID = pmd.ProductDescriptionID
WHERE pmpd.Culture = 'en' OR pmpd.Culture IS NULL
ORDER BY pm.Name
GO

-- Products with color and size information
SELECT TOP 25
    ProductID,
    Name,
    ProductNumber,
    Color,
    Size,
    Weight,
    ListPrice
FROM SalesLT.Product
WHERE Color IS NOT NULL AND Size IS NOT NULL
ORDER BY Name
GO
