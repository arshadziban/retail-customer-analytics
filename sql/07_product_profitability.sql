/*
Script  : 07_product_profitability.sql
Purpose : Product and category profitability, discounts and inventory.
          Item margin only (freight and fees not allocated). Stock is a current snapshot.
*/

USE RetailAnalytics;
GO

SET NOCOUNT ON;

-- 0. PRODUCT-GRAIN WORKING TABLE
IF OBJECT_ID('tempdb..#product_sales') IS NOT NULL DROP TABLE #product_sales;

DECLARE @LastOrderDate DATE = (
    SELECT MAX(CAST(OrderTimestamp AS DATE)) FROM dbo.fact_orders WHERE OrderStatus <> 'Cancelled'
);

SELECT
    p.ProductID,
    p.ProductName,
    p.Category,
    p.SKU,
    p.UnitPrice                                    AS ListPrice,
    p.UnitCost                                     AS ListCost,
    p.StockOnHand,
    p.ReorderPoint,
    ISNULL(s.OrderLines, 0)                        AS OrderLines,
    ISNULL(s.Orders, 0)                            AS Orders,
    ISNULL(s.Units, 0)                             AS Units,
    ISNULL(s.GrossSales, 0)                        AS GrossSales,
    ISNULL(s.Discounts, 0)                         AS Discounts,
    ISNULL(s.Revenue, 0)                           AS Revenue,
    ISNULL(s.ItemMargin, 0)                        AS ItemMargin,
    ISNULL(s.Units90d, 0)                          AS Units90d,
    s.LastSoldDate
INTO #product_sales
FROM dbo.dim_products p
LEFT JOIN (
    SELECT
        i.ProductID,
        COUNT(*)                                   AS OrderLines,
        COUNT(DISTINCT i.OrderID)                  AS Orders,
        SUM(i.Quantity)                            AS Units,
        SUM(i.Quantity * i.UnitPrice)              AS GrossSales,
        SUM(i.DiscountAmount)                      AS Discounts,
        SUM(i.LineTotal)                           AS Revenue,
        SUM(i.ItemNetMargin)                       AS ItemMargin,
        SUM(CASE WHEN o.OrderTimestamp >= DATEADD(DAY, -89, @LastOrderDate)
                 THEN i.Quantity ELSE 0 END)       AS Units90d,
        MAX(CAST(o.OrderTimestamp AS DATE))        AS LastSoldDate
    FROM dbo.fact_order_items i
    JOIN dbo.fact_orders o ON o.OrderID = i.OrderID
    WHERE o.OrderStatus <> 'Cancelled'
    GROUP BY i.ProductID
) s ON s.ProductID = p.ProductID;

CREATE UNIQUE CLUSTERED INDEX CIX_product_sales ON #product_sales (ProductID);

-- 1. CATEGORY SCORECARD
SELECT
    Category,
    COUNT(*)                                                         AS Products,
    SUM(CASE WHEN Units > 0 THEN 1 ELSE 0 END)                       AS ProductsSold,
    SUM(Units)                                                       AS Units,
    SUM(Revenue)                                                     AS Revenue,
    CAST(100.0 * SUM(Revenue) / SUM(SUM(Revenue)) OVER () AS DECIMAL(5,2))       AS RevenueSharePct,
    SUM(ItemMargin)                                                  AS ItemMargin,
    CAST(100.0 * SUM(ItemMargin) / SUM(SUM(ItemMargin)) OVER () AS DECIMAL(5,2)) AS MarginSharePct,
    CAST(100.0 * SUM(ItemMargin) / NULLIF(SUM(Revenue), 0) AS DECIMAL(5,2))      AS MarginPct,
    CAST(SUM(Revenue) / NULLIF(SUM(Units), 0) AS DECIMAL(10,2))      AS AvgSellingPrice,
    CAST(100.0 * SUM(Discounts) / NULLIF(SUM(GrossSales), 0) AS DECIMAL(5,2))    AS DiscountPct,
    RANK() OVER (ORDER BY SUM(ItemMargin) DESC)                      AS MarginRank
FROM #product_sales
GROUP BY Category
ORDER BY ItemMargin DESC;

-- 2. TOP AND BOTTOM PRODUCTS
-- 2a. Top 20 by item margin.
SELECT TOP (20)
    RANK() OVER (ORDER BY ItemMargin DESC)                       AS MarginRank,
    ProductID, ProductName, Category,
    Units, Revenue, ItemMargin,
    CAST(100.0 * ItemMargin / NULLIF(Revenue, 0) AS DECIMAL(5,2)) AS MarginPct,
    CAST(Revenue / NULLIF(Units, 0) AS DECIMAL(10,2))             AS AvgSellingPrice,
    ListPrice
FROM #product_sales
WHERE Units > 0
ORDER BY ItemMargin DESC;

-- 2b. Bottom 20 by item margin (min 5 units sold).
SELECT TOP (20)
    RANK() OVER (ORDER BY ItemMargin ASC)                        AS WorstRank,
    ProductID, ProductName, Category,
    Units, Revenue, ItemMargin,
    CAST(100.0 * ItemMargin / NULLIF(Revenue, 0) AS DECIMAL(5,2)) AS MarginPct,
    CAST(Revenue / NULLIF(Units, 0) AS DECIMAL(10,2))             AS AvgSellingPrice,
    ListPrice
FROM #product_sales
WHERE Units >= 5
ORDER BY ItemMargin ASC;

-- 2c. Lowest margin % (min 5 units). Different question from 2b: these
SELECT TOP (20)
    ProductID, ProductName, Category,
    Units, Revenue, ItemMargin,
    CAST(100.0 * ItemMargin / NULLIF(Revenue, 0) AS DECIMAL(5,2)) AS MarginPct,
    ListPrice, ListCost,
    CAST(100.0 * (ListPrice - ListCost) / NULLIF(ListPrice, 0) AS DECIMAL(5,2)) AS ListMarginPct
FROM #product_sales
WHERE Units >= 5
ORDER BY 100.0 * ItemMargin / NULLIF(Revenue, 0) ASC;

-- 2d. Top 3 products per category (by margin).
;WITH ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY Category ORDER BY ItemMargin DESC) AS RankInCategory
    FROM #product_sales
    WHERE Units > 0
)
SELECT
    Category, RankInCategory, ProductID, ProductName,
    Units, Revenue, ItemMargin,
    CAST(100.0 * ItemMargin / NULLIF(Revenue, 0) AS DECIMAL(5,2)) AS MarginPct
FROM ranked
WHERE RankInCategory <= 3
ORDER BY Category, RankInCategory;

-- 3. DISCOUNT IMPACT ON MARGIN
;WITH lines AS (
    SELECT i.*, p.Category
    FROM dbo.fact_order_items i
    JOIN dbo.fact_orders  o ON o.OrderID   = i.OrderID
    JOIN dbo.dim_products p ON p.ProductID = i.ProductID
    WHERE o.OrderStatus <> 'Cancelled'
)
SELECT
    CONCAT(CAST(DiscountRate * 100 AS INT), '%')                     AS DiscountTier,
    COUNT(*)                                                         AS OrderLines,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))   AS LineSharePct,
    CAST(AVG(1.0 * Quantity) AS DECIMAL(6,2))                        AS AvgUnitsPerLine,
    SUM(Quantity * UnitPrice)                                        AS GrossSales,
    SUM(DiscountAmount)                                              AS DiscountGiven,
    SUM(LineTotal)                                                   AS Revenue,
    SUM(ItemNetMargin)                                               AS ItemMargin,
    CAST(100.0 * SUM(ItemNetMargin) / NULLIF(SUM(LineTotal), 0) AS DECIMAL(5,2)) AS MarginPct,
    CAST(100.0 * SUM(ItemNetMargin + DiscountAmount) / NULLIF(SUM(Quantity * UnitPrice), 0) AS DECIMAL(5,2)) AS MarginPctAtListPrice
FROM lines
GROUP BY DiscountRate
ORDER BY DiscountRate;

-- 3b. Discount depth by category: where is margin being given away?
SELECT
    p.Category,
    CAST(100.0 * SUM(CASE WHEN i.DiscountRate > 0 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS PctLinesDiscounted,
    SUM(i.DiscountAmount)                                                         AS DiscountGiven,
    CAST(100.0 * SUM(i.DiscountAmount) / NULLIF(SUM(i.Quantity * i.UnitPrice), 0) AS DECIMAL(5,2)) AS DiscountPctOfGross,
    CAST(100.0 * SUM(i.DiscountAmount) / NULLIF(SUM(i.ItemNetMargin + i.DiscountAmount), 0) AS DECIMAL(5,2)) AS PctOfPotentialMarginGivenAway
FROM dbo.fact_order_items i
JOIN dbo.fact_orders  o ON o.OrderID   = i.OrderID
JOIN dbo.dim_products p ON p.ProductID = i.ProductID
WHERE o.OrderStatus <> 'Cancelled'
GROUP BY p.Category
ORDER BY PctOfPotentialMarginGivenAway DESC;

-- 4. REVENUE CONCENTRATION (PARETO)
;WITH ordered AS (
    SELECT
        ProductID,
        Revenue,
        SUM(Revenue) OVER (ORDER BY Revenue DESC, ProductID ROWS UNBOUNDED PRECEDING) AS CumRevenue,
        SUM(Revenue) OVER ()                                                          AS TotalRevenue,
        ROW_NUMBER() OVER (ORDER BY Revenue DESC, ProductID)                          AS RevenueRank,
        COUNT(*) OVER ()                                                              AS ProductsSold
    FROM #product_sales
    WHERE Units > 0
)
SELECT
    Threshold,
    MIN(RevenueRank)                                                AS ProductsNeeded,
    MAX(ProductsSold)                                               AS ProductsSold,
    CAST(100.0 * MIN(RevenueRank) / MAX(ProductsSold) AS DECIMAL(5,2)) AS PctOfProducts
FROM ordered
CROSS JOIN (VALUES (0.50), (0.80), (0.95)) AS t(Threshold)
WHERE CumRevenue >= Threshold * TotalRevenue
GROUP BY Threshold
ORDER BY Threshold;

-- 5. PRICE BAND ANALYSIS
;WITH banded AS (
    SELECT *,
        CASE
            WHEN ListPrice <   25 THEN '1. < 25'
            WHEN ListPrice <  100 THEN '2. 25-99'
            WHEN ListPrice <  250 THEN '3. 100-249'
            WHEN ListPrice <  500 THEN '4. 250-499'
            ELSE                       '5. 500+'
        END AS PriceBand
    FROM #product_sales
)
SELECT
    PriceBand,
    COUNT(*)                                                         AS Products,
    SUM(Units)                                                       AS Units,
    SUM(Revenue)                                                     AS Revenue,
    CAST(100.0 * SUM(Revenue) / SUM(SUM(Revenue)) OVER () AS DECIMAL(5,2)) AS RevenueSharePct,
    CAST(100.0 * SUM(ItemMargin) / NULLIF(SUM(Revenue), 0) AS DECIMAL(5,2)) AS MarginPct
FROM banded
GROUP BY PriceBand
ORDER BY PriceBand;

-- 6. INVENTORY WATCH-LIST
IF OBJECT_ID('tempdb..#inventory') IS NOT NULL DROP TABLE #inventory;

SELECT
    ProductID, ProductName, Category, SKU,
    StockOnHand, ReorderPoint, Units90d,
    CAST(Units90d / 90.0 AS DECIMAL(10,3))                             AS DailyDemand90d,
    CAST(CASE WHEN Units90d > 0 THEN StockOnHand / (Units90d / 90.0) END AS DECIMAL(10,1)) AS DaysOfCover,
    StockOnHand * ListCost                                             AS StockValueAtCost,
    LastSoldDate,
    Revenue,
    CASE
        WHEN StockOnHand = 0                                     THEN '1. Out of stock'
        WHEN StockOnHand <= ReorderPoint                         THEN '2. Reorder now'
        WHEN Units90d > 0 AND StockOnHand / (Units90d / 90.0) < 30 THEN '3. Low cover'
        WHEN Units90d = 0                                        THEN '4. No recent demand'
        WHEN StockOnHand / (Units90d / 90.0) > 365               THEN '5. Overstocked'
        ELSE                                                          '6. Healthy'
    END                                                                AS StockStatus
INTO #inventory
FROM #product_sales;

-- 6a. Status summary: where the stock (and the cash tied up in it) sits.
SELECT
    StockStatus,
    COUNT(*)                                                           AS Products,
    SUM(StockOnHand)                                                   AS UnitsOnHand,
    SUM(StockValueAtCost)                                              AS StockValueAtCost,
    CAST(100.0 * SUM(StockValueAtCost) / SUM(SUM(StockValueAtCost)) OVER () AS DECIMAL(5,2)) AS StockValueSharePct
FROM #inventory
GROUP BY StockStatus
ORDER BY StockStatus;

-- 6b. Action list: products needing replenishment, best sellers first
SELECT TOP (50)
    StockStatus, ProductID, ProductName, Category, SKU,
    StockOnHand, ReorderPoint, Units90d, DaysOfCover, Revenue
FROM #inventory
WHERE StockStatus IN ('1. Out of stock', '2. Reorder now', '3. Low cover')
ORDER BY StockStatus, Revenue DESC;

-- 6c. By category: share of products needing action.
SELECT
    Category,
    COUNT(*)                                                                         AS Products,
    SUM(CASE WHEN StockStatus IN ('1. Out of stock','2. Reorder now','3. Low cover') THEN 1 ELSE 0 END) AS NeedReplenishment,
    SUM(CASE WHEN StockStatus IN ('4. No recent demand','5. Overstocked') THEN 1 ELSE 0 END)           AS SlowOrExcess,
    SUM(CASE WHEN StockStatus IN ('4. No recent demand','5. Overstocked') THEN StockValueAtCost ELSE 0 END) AS SlowOrExcessValue
FROM #inventory
GROUP BY Category
ORDER BY SlowOrExcessValue DESC;

-- 7. PRODUCTS NEVER SOLD
SELECT
    Category,
    COUNT(*)                         AS ProductsNeverSold,
    SUM(StockOnHand)                 AS UnitsOnHand,
    SUM(StockOnHand * ListCost)      AS StockValueAtCost
FROM #product_sales
WHERE Units = 0
GROUP BY Category
ORDER BY StockValueAtCost DESC;

DROP TABLE #inventory;
DROP TABLE #product_sales;
GO
