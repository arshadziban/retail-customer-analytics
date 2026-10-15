/*
===============================================================================
Project     : Enterprise Retail Analytics
Database    : RetailAnalytics
DBMS        : Microsoft SQL Server
Script      : 07_product_profitability.sql
Purpose     : Which products and categories make money, how discounting
              affects margin, and which stock positions need attention.
Run after   : 06_rfm_segmentation.sql
Output      : Category scorecard, product rankings, discount impact,
              revenue concentration, inventory watch-list.
===============================================================================

DEFINITIONS (consistent with 05)
    Scope           : order lines on qualifying orders (OrderStatus <> 'Cancelled').
    Revenue         : SUM(LineTotal), net of discount.
    Item margin     : SUM(ItemNetMargin) = revenue - Quantity * UnitCost.
    Margin %        : item margin / revenue.
    Avg selling price (ASP) : revenue / units. Below list price when discounted.
    Prices and costs come from the ORDER LINE (price at time of sale), not
    from dim_products, which holds the current price list only.

    Freight and payment fees are order-level costs. They are deliberately NOT
    allocated to products here: any split (by value, by units) would be an
    assumption that changes the ranking. Product margin is therefore item
    margin, before fulfilment costs.

INVENTORY CAVEAT
    StockOnHand and ReorderPoint are a single snapshot. There is no stock
    movement history, so this script cannot say whether a product was out of
    stock in the past, only where it stands now. Days of cover uses the last
    90 days of sales as the demand rate.

SECTIONS
    0. Product-grain working table
    1. Category scorecard
    2. Top and bottom products
    3. Discount impact on margin
    4. Revenue concentration (Pareto)
    5. Price band analysis
    6. Inventory watch-list
    7. Products never sold
===============================================================================
*/

USE RetailAnalytics;
GO

SET NOCOUNT ON;

-- =========================================
-- 0. PRODUCT-GRAIN WORKING TABLE
-- =========================================
-- One row per product, including products that never sold (LEFT JOIN) so
-- dead stock is visible rather than silently missing.

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

-- =========================================
-- 1. CATEGORY SCORECARD
-- =========================================
-- Revenue share vs margin share is the key comparison: a category whose
-- margin share is below its revenue share is diluting overall profitability.

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

-- =========================================
-- 2. TOP AND BOTTOM PRODUCTS
-- =========================================
-- Ranked on item margin (absolute profit), not revenue: a high-revenue,
-- thin-margin product is less valuable than it looks.
-- Bottom list only includes products that sold at least 5 units, so a
-- single small sale does not label a product a "worst performer".

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
-- products may sell well but leave little on each sale; pricing candidates.
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

-- =========================================
-- 3. DISCOUNT IMPACT ON MARGIN
-- =========================================
-- Line-level, because the discount is decided per line. The question:
-- do discounts buy enough extra volume to pay for themselves?
-- Compare margin % and units per line across discount tiers.

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
    -- Margin that would have been earned at list price on the same lines.
    -- The difference is exactly the discount: margin given away.
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

-- =========================================
-- 4. REVENUE CONCENTRATION (PARETO)
-- =========================================
-- What share of products produces 80% of revenue? High concentration means
-- the business depends on a few SKUs: protect their stock and pricing.

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

-- =========================================
-- 5. PRICE BAND ANALYSIS
-- =========================================
-- Do expensive items carry better margins, and where does volume sit?
-- Banded on list price so each product sits in one band.

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

-- =========================================
-- 6. INVENTORY WATCH-LIST
-- =========================================
-- Current stock against recent demand.
--   DailyDemand90d = units sold in the last 90 days / 90
--   DaysOfCover    = StockOnHand / DailyDemand90d
-- Status rules (first match wins):
--   Out of stock        : StockOnHand = 0
--   Reorder now         : StockOnHand <= ReorderPoint
--   Low cover           : fewer than 30 days of cover at current demand
--   No recent demand    : stock held but nothing sold in 90 days
--   Overstocked         : more than 365 days of cover
--   Healthy             : everything else

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
-- (a stock-out on a top seller costs the most).
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

-- =========================================
-- 7. PRODUCTS NEVER SOLD
-- =========================================
-- In the catalogue, never on a qualifying order. Candidates for delisting or
-- promotion; their stock is cash with no return.

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
