/*
Script  : 05_sales_analysis.sql
Purpose : Sales KPIs, trends, region, channel and shipping.
          Qualifying order = not Cancelled. Net sales = SUM(LineTotal).
          Contribution = item margin - freight - processing fee. Refunds are not netted (see 08).
*/

USE RetailAnalytics;
GO

SET NOCOUNT ON;

-- 0. ORDER-GRAIN WORKING TABLE
IF OBJECT_ID('tempdb..#orders') IS NOT NULL DROP TABLE #orders;

SELECT
    o.OrderID,
    o.CustomerID,
    o.OrderTimestamp,
    CAST(o.OrderTimestamp AS DATE)                          AS OrderDate,
    DATEFROMPARTS(YEAR(o.OrderTimestamp), MONTH(o.OrderTimestamp), 1) AS OrderMonth,
    o.OrderStatus,
    o.ShippingMethod,
    o.FreightCost,
    c.Region,
    c.AcquisitionChannel,
    c.LoyaltyTier,
    CASE WHEN o.OrderStatus <> 'Cancelled' THEN 1 ELSE 0 END AS IsQualifying,
    li.LineCount,
    li.Units,
    li.GrossSales,
    li.Discounts,
    li.NetSales,
    li.ItemMargin,
    ISNULL(p.ProcessingFee, 0)                              AS ProcessingFee
INTO #orders
FROM dbo.fact_orders o
JOIN dbo.dim_customers c ON c.CustomerID = o.CustomerID
JOIN (
    SELECT
        OrderID,
        COUNT(*)                     AS LineCount,
        SUM(Quantity)                AS Units,
        SUM(Quantity * UnitPrice)    AS GrossSales,
        SUM(DiscountAmount)          AS Discounts,
        SUM(LineTotal)               AS NetSales,
        SUM(ItemNetMargin)           AS ItemMargin
    FROM dbo.fact_order_items
    GROUP BY OrderID
) li ON li.OrderID = o.OrderID
LEFT JOIN dbo.fact_payments p ON p.OrderID = o.OrderID;

CREATE CLUSTERED INDEX CIX_orders ON #orders (OrderMonth, OrderID);

-- 1. HEADLINE KPIs
SELECT
    MIN(OrderDate)                                                    AS PeriodStart,
    MAX(OrderDate)                                                    AS PeriodEnd,
    COUNT(*)                                                          AS AllOrders,
    SUM(1 - IsQualifying)                                             AS CancelledOrders,
    CAST(100.0 * SUM(1 - IsQualifying) / COUNT(*) AS DECIMAL(5,2))    AS CancellationRatePct,
    SUM(IsQualifying)                                                 AS QualifyingOrders,
    SUM(CASE WHEN IsQualifying = 1 THEN LineCount END)                AS OrderLines,
    SUM(CASE WHEN IsQualifying = 1 THEN Units END)                    AS UnitsSold,
    COUNT(DISTINCT CASE WHEN IsQualifying = 1 THEN CustomerID END)    AS ActiveCustomers,
    SUM(CASE WHEN IsQualifying = 1 THEN GrossSales END)               AS GrossItemSales,
    SUM(CASE WHEN IsQualifying = 1 THEN Discounts END)                AS Discounts,
    SUM(CASE WHEN IsQualifying = 1 THEN NetSales END)                 AS NetSales,
    SUM(CASE WHEN IsQualifying = 1 THEN ItemMargin END)               AS ItemMargin,
    CAST(100.0 * SUM(CASE WHEN IsQualifying = 1 THEN ItemMargin END)
         / NULLIF(SUM(CASE WHEN IsQualifying = 1 THEN NetSales END), 0) AS DECIMAL(5,2)) AS ItemMarginPct,
    SUM(CASE WHEN IsQualifying = 1 THEN FreightCost END)              AS FreightCost,
    SUM(CASE WHEN IsQualifying = 1 THEN ProcessingFee END)            AS ProcessingFees,
    SUM(CASE WHEN IsQualifying = 1 THEN ItemMargin - FreightCost - ProcessingFee END) AS Contribution,
    CAST(100.0 * SUM(CASE WHEN IsQualifying = 1 THEN ItemMargin - FreightCost - ProcessingFee END)
         / NULLIF(SUM(CASE WHEN IsQualifying = 1 THEN NetSales END), 0) AS DECIMAL(5,2)) AS ContributionPct,
    CAST(SUM(CASE WHEN IsQualifying = 1 THEN NetSales END)
         / NULLIF(SUM(IsQualifying), 0) AS DECIMAL(12,2))             AS AvgOrderValue,
    CAST(1.0 * SUM(CASE WHEN IsQualifying = 1 THEN Units END)
         / NULLIF(SUM(IsQualifying), 0) AS DECIMAL(6,2))              AS UnitsPerOrder,
    CAST(100.0 * SUM(CASE WHEN IsQualifying = 1 THEN Discounts END)
         / NULLIF(SUM(CASE WHEN IsQualifying = 1 THEN GrossSales END), 0) AS DECIMAL(5,2)) AS DiscountRatePct
FROM #orders;

SELECT DISTINCT
    CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY NetSales) OVER () AS DECIMAL(12,2)) AS MedianOrderValue,
    CAST(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY NetSales) OVER () AS DECIMAL(12,2)) AS P90OrderValue
FROM #orders
WHERE IsQualifying = 1;

-- 2. YEARLY PERFORMANCE
;WITH yearly AS (
    SELECT
        YEAR(OrderDate)                         AS OrderYear,
        COUNT(*)                                AS QualifyingOrders,
        COUNT(DISTINCT CustomerID)              AS ActiveCustomers,
        SUM(NetSales)                           AS NetSales,
        SUM(ItemMargin)                         AS ItemMargin,
        SUM(ItemMargin - FreightCost - ProcessingFee) AS Contribution
    FROM #orders
    WHERE IsQualifying = 1
    GROUP BY YEAR(OrderDate)
)
SELECT
    OrderYear,
    QualifyingOrders,
    ActiveCustomers,
    NetSales,
    CAST(NetSales / QualifyingOrders AS DECIMAL(12,2))             AS AvgOrderValue,
    CAST(100.0 * ItemMargin / NetSales AS DECIMAL(5,2))            AS ItemMarginPct,
    Contribution,
    CAST(100.0 * (NetSales - LAG(NetSales) OVER (ORDER BY OrderYear))
         / NULLIF(LAG(NetSales) OVER (ORDER BY OrderYear), 0) AS DECIMAL(6,2)) AS NetSalesYoYPct
FROM yearly
ORDER BY OrderYear;

-- 3. QUARTERLY TREND
;WITH quarterly AS (
    SELECT
        YEAR(OrderDate)                                  AS OrderYear,
        DATEPART(QUARTER, OrderDate)                     AS OrderQuarter,
        COUNT(*)                                         AS QualifyingOrders,
        SUM(NetSales)                                    AS NetSales,
        SUM(ItemMargin)                                  AS ItemMargin
    FROM #orders
    WHERE IsQualifying = 1
    GROUP BY YEAR(OrderDate), DATEPART(QUARTER, OrderDate)
)
SELECT
    CONCAT(OrderYear, '-Q', OrderQuarter)                AS YearQuarter,
    QualifyingOrders,
    NetSales,
    CAST(100.0 * ItemMargin / NetSales AS DECIMAL(5,2))  AS ItemMarginPct,
    CAST(100.0 * (NetSales - LAG(NetSales, 1) OVER (ORDER BY OrderYear, OrderQuarter))
         / NULLIF(LAG(NetSales, 1) OVER (ORDER BY OrderYear, OrderQuarter), 0) AS DECIMAL(6,2)) AS QoQPct,
    CAST(100.0 * (NetSales - LAG(NetSales, 4) OVER (ORDER BY OrderYear, OrderQuarter))
         / NULLIF(LAG(NetSales, 4) OVER (ORDER BY OrderYear, OrderQuarter), 0) AS DECIMAL(6,2)) AS YoYPct
FROM quarterly
ORDER BY OrderYear, OrderQuarter;

-- 4. MONTHLY TREND
;WITH monthly AS (
    SELECT
        OrderMonth,
        COUNT(*)                                                   AS AllOrders,
        SUM(1 - IsQualifying)                                      AS CancelledOrders,
        SUM(IsQualifying)                                          AS QualifyingOrders,
        COUNT(DISTINCT CASE WHEN IsQualifying = 1 THEN CustomerID END) AS ActiveCustomers,
        SUM(CASE WHEN IsQualifying = 1 THEN NetSales END)          AS NetSales,
        SUM(CASE WHEN IsQualifying = 1 THEN ItemMargin END)        AS ItemMargin,
        SUM(CASE WHEN IsQualifying = 1 THEN Discounts END)         AS Discounts
    FROM #orders
    GROUP BY OrderMonth
)
SELECT
    FORMAT(OrderMonth, 'yyyy-MM')                                  AS YearMonth,
    AllOrders,
    CancelledOrders,
    QualifyingOrders,
    ActiveCustomers,
    NetSales,
    CAST(NetSales / NULLIF(QualifyingOrders, 0) AS DECIMAL(12,2))  AS AvgOrderValue,
    CAST(100.0 * ItemMargin / NULLIF(NetSales, 0) AS DECIMAL(5,2)) AS ItemMarginPct,
    Discounts,
    CAST(100.0 * (NetSales - LAG(NetSales, 1) OVER (ORDER BY OrderMonth))
         / NULLIF(LAG(NetSales, 1) OVER (ORDER BY OrderMonth), 0) AS DECIMAL(6,2))  AS MoMPct,
    CAST(100.0 * (NetSales - LAG(NetSales, 12) OVER (ORDER BY OrderMonth))
         / NULLIF(LAG(NetSales, 12) OVER (ORDER BY OrderMonth), 0) AS DECIMAL(6,2)) AS YoYPct,
    SUM(NetSales) OVER (PARTITION BY YEAR(OrderMonth) ORDER BY OrderMonth
                        ROWS UNBOUNDED PRECEDING)                  AS NetSalesYTD
FROM monthly
ORDER BY OrderMonth;

-- 5. BEST AND WORST MONTHS
;WITH monthly AS (
    SELECT
        OrderMonth,
        COUNT(DISTINCT OrderDate)  AS DaysWithOrders,
        COUNT(*)                   AS QualifyingOrders,
        SUM(NetSales)              AS NetSales,
        SUM(ItemMargin)            AS ItemMargin
    FROM #orders
    WHERE IsQualifying = 1
    GROUP BY OrderMonth
),
ranked AS (
    SELECT *,
           RANK() OVER (ORDER BY NetSales DESC) AS BestRank,
           RANK() OVER (ORDER BY NetSales ASC)  AS WorstRank
    FROM monthly
)
SELECT
    CASE WHEN BestRank <= 3 THEN 'Top 3' ELSE 'Bottom 3' END AS Bucket,
    FORMAT(OrderMonth, 'yyyy-MM') AS YearMonth,
    DaysWithOrders,
    QualifyingOrders,
    NetSales,
    CAST(100.0 * ItemMargin / NetSales AS DECIMAL(5,2)) AS ItemMarginPct
FROM ranked
WHERE BestRank <= 3 OR WorstRank <= 3
ORDER BY NetSales DESC;

-- 6. REVENUE BY REGION
SELECT
    Region,
    COUNT(*)                                                   AS QualifyingOrders,
    COUNT(DISTINCT CustomerID)                                 AS ActiveCustomers,
    SUM(NetSales)                                              AS NetSales,
    CAST(100.0 * SUM(NetSales) / SUM(SUM(NetSales)) OVER () AS DECIMAL(5,2)) AS SalesSharePct,
    CAST(SUM(NetSales) / COUNT(*) AS DECIMAL(12,2))            AS AvgOrderValue,
    CAST(SUM(NetSales) / COUNT(DISTINCT CustomerID) AS DECIMAL(12,2)) AS SalesPerCustomer,
    CAST(100.0 * SUM(ItemMargin) / SUM(NetSales) AS DECIMAL(5,2)) AS ItemMarginPct,
    CAST(100.0 * SUM(ItemMargin - FreightCost - ProcessingFee) / SUM(NetSales) AS DECIMAL(5,2)) AS ContributionPct
FROM #orders
WHERE IsQualifying = 1
GROUP BY Region
ORDER BY NetSales DESC;

-- 7. REVENUE BY ACQUISITION CHANNEL
;WITH channel_customers AS (
    SELECT AcquisitionChannel, COUNT(*) AS CustomersAcquired
    FROM dbo.dim_customers
    GROUP BY AcquisitionChannel
)
SELECT
    o.AcquisitionChannel,
    cc.CustomersAcquired,
    COUNT(DISTINCT o.CustomerID)                                       AS PurchasingCustomers,
    CAST(100.0 * COUNT(DISTINCT o.CustomerID) / cc.CustomersAcquired AS DECIMAL(5,2)) AS ConversionPct,
    COUNT(*)                                                           AS QualifyingOrders,
    CAST(1.0 * COUNT(*) / COUNT(DISTINCT o.CustomerID) AS DECIMAL(5,2)) AS OrdersPerCustomer,
    SUM(o.NetSales)                                                    AS NetSales,
    CAST(100.0 * SUM(o.NetSales) / SUM(SUM(o.NetSales)) OVER () AS DECIMAL(5,2)) AS SalesSharePct,
    CAST(SUM(o.NetSales) / COUNT(*) AS DECIMAL(12,2))                  AS AvgOrderValue,
    CAST(SUM(o.NetSales) / COUNT(DISTINCT o.CustomerID) AS DECIMAL(12,2)) AS SalesPerCustomer
FROM #orders o
JOIN channel_customers cc ON cc.AcquisitionChannel = o.AcquisitionChannel
WHERE o.IsQualifying = 1
GROUP BY o.AcquisitionChannel, cc.CustomersAcquired
ORDER BY NetSales DESC;

-- 7b. Region x channel matrix (pivot in Power BI; long format here).
SELECT
    Region,
    AcquisitionChannel,
    COUNT(*)        AS QualifyingOrders,
    SUM(NetSales)   AS NetSales,
    CAST(100.0 * SUM(NetSales) / SUM(SUM(NetSales)) OVER (PARTITION BY Region) AS DECIMAL(5,2)) AS ShareOfRegionPct
FROM #orders
WHERE IsQualifying = 1
GROUP BY Region, AcquisitionChannel
ORDER BY Region, NetSales DESC;

-- 8. ORDER STATUS DISTRIBUTION
SELECT
    OrderStatus,
    COUNT(*)                                                         AS Orders,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))   AS OrderSharePct,
    SUM(NetSales)                                                    AS OrderValue,
    CAST(100.0 * SUM(NetSales) / SUM(SUM(NetSales)) OVER () AS DECIMAL(5,2)) AS ValueSharePct,
    CAST(AVG(NetSales) AS DECIMAL(12,2))                             AS AvgOrderValue
FROM #orders
GROUP BY OrderStatus
ORDER BY Orders DESC;

-- 9. SHIPPING METHOD AND FREIGHT COST
SELECT
    ShippingMethod,
    COUNT(*)                                                         AS QualifyingOrders,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))   AS OrderSharePct,
    SUM(NetSales)                                                    AS NetSales,
    CAST(SUM(NetSales) / COUNT(*) AS DECIMAL(12,2))                  AS AvgOrderValue,
    SUM(FreightCost)                                                 AS TotalFreight,
    CAST(AVG(FreightCost) AS DECIMAL(10,2))                          AS AvgFreightPerOrder,
    CAST(100.0 * SUM(FreightCost) / SUM(NetSales) AS DECIMAL(5,2))   AS FreightPctOfSales,
    CAST(100.0 * SUM(ItemMargin - FreightCost - ProcessingFee) / SUM(NetSales) AS DECIMAL(5,2)) AS ContributionPct
FROM #orders
WHERE IsQualifying = 1
GROUP BY ShippingMethod
ORDER BY QualifyingOrders DESC;

-- 9b. Freight burden by order-value band: shows where freight eats the margin.
;WITH banded AS (
    SELECT *,
        CASE
            WHEN NetSales <  50   THEN '1. < 50'
            WHEN NetSales <  100  THEN '2. 50-99'
            WHEN NetSales <  250  THEN '3. 100-249'
            WHEN NetSales <  500  THEN '4. 250-499'
            WHEN NetSales <  1000 THEN '5. 500-999'
            ELSE                       '6. 1000+'
        END AS OrderValueBand
    FROM #orders
    WHERE IsQualifying = 1
)
SELECT
    OrderValueBand,
    COUNT(*)                                                       AS QualifyingOrders,
    SUM(NetSales)                                                  AS NetSales,
    CAST(AVG(FreightCost) AS DECIMAL(10,2))                        AS AvgFreight,
    CAST(100.0 * SUM(FreightCost) / SUM(NetSales) AS DECIMAL(6,2)) AS FreightPctOfSales,
    CAST(100.0 * SUM(ItemMargin - FreightCost - ProcessingFee) / SUM(NetSales) AS DECIMAL(6,2)) AS ContributionPct,
    SUM(CASE WHEN ItemMargin - FreightCost - ProcessingFee < 0 THEN 1 ELSE 0 END) AS LossMakingOrders
FROM banded
GROUP BY OrderValueBand
ORDER BY OrderValueBand;

-- 10. DAY-OF-WEEK PATTERN
SELECT
    DATENAME(WEEKDAY, OrderDate)                                   AS DayOfWeek,
    COUNT(*)                                                       AS QualifyingOrders,
    SUM(NetSales)                                                  AS NetSales,
    CAST(100.0 * SUM(NetSales) / SUM(SUM(NetSales)) OVER () AS DECIMAL(5,2)) AS SalesSharePct,
    CAST(AVG(NetSales) AS DECIMAL(12,2))                           AS AvgOrderValue
FROM #orders
WHERE IsQualifying = 1
GROUP BY DATENAME(WEEKDAY, OrderDate), (DATEDIFF(DAY, '19000101', OrderDate) % 7)
ORDER BY (DATEDIFF(DAY, '19000101', OrderDate) % 7);   -- 0 = Monday
DROP TABLE #orders;
GO
