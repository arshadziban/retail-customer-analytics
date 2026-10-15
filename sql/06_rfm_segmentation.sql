/*
===============================================================================
Project     : Enterprise Retail Analytics
Database    : RetailAnalytics
DBMS        : Microsoft SQL Server
Script      : 06_rfm_segmentation.sql
Purpose     : Segment customers by purchasing behaviour (Recency, Frequency,
              Monetary) and turn the segments into retention actions.
Run after   : 05_sales_analysis.sql
Output      : Customer-level RFM scores and segments, segment economics,
              and a prioritised retention list.
===============================================================================

DEFINITIONS
    Qualifying order : OrderStatus <> 'Cancelled' (same rule as 05).
    Analysis period  : all qualifying orders in the data
                       (2024-01-01 to 2025-12-30 at time of writing).
    As-of date       : the day AFTER the last qualifying order in the data,
                       NOT GETDATE(). The dataset is a historical extract;
                       measuring recency from today would make every customer
                       look lapsed and would change results every time the
                       script runs.
    Recency  (R)     : days from the customer's last qualifying order to the
                       as-of date. Lower = better.
    Frequency (F)    : number of qualifying orders.
    Monetary (M)     : SUM(LineTotal) across qualifying orders (net sales).

SCORING (1 = worst, 5 = best)
    R : NTILE(5) on recency. Quintiles fit because recency is continuous.
    M : NTILE(5) on monetary, for the same reason.
    F : FIXED bands, not quintiles: 1, 2, 3, 4, 5+ orders.
        Most customers have 1-3 orders, so quintiles would split customers
        with the SAME order count into different scores purely on sort order.
        Fixed bands keep the score explainable ("F=3 means 3 orders").
    NTILE ties are broken by CustomerID so results are repeatable.

SEGMENT RULES (evaluated top to bottom; first match wins; every customer
gets exactly one segment)
    Champions           R >= 4 AND F >= 4   bought recently and often
    Loyal Customers     R >= 3 AND F >= 3   regular buyers, still active
    Potential Loyalists R >= 4 AND F <= 2   recent but few orders: nurture
    Need Attention      R  = 3 AND F <= 2   middling recency, low frequency
    At Risk             R <= 2 AND F >= 3   used to buy often, gone quiet
    Hibernating         R <= 2 AND F <= 2   long gone, low engagement
    These thresholds are a business choice, not a universal standard. Change
    them here and in vw_customer_rfm (09) together.

    Monetary is NOT in the segment rule. It is used to RANK customers inside
    a segment, so a high-spend At Risk customer gets contacted first.

OUT OF SCOPE
    Customers with no qualifying order (never bought, or only cancelled) have
    no R/F/M. They are counted in section 2 but not scored.
===============================================================================
*/

USE RetailAnalytics;
GO

SET NOCOUNT ON;

-- =========================================
-- 1. CUSTOMER RFM BASE
-- =========================================

IF OBJECT_ID('tempdb..#rfm') IS NOT NULL DROP TABLE #rfm;

DECLARE @AsOfDate DATE = (
    SELECT DATEADD(DAY, 1, MAX(CAST(OrderTimestamp AS DATE)))
    FROM dbo.fact_orders
    WHERE OrderStatus <> 'Cancelled'
);

;WITH order_value AS (
    -- Lines -> order grain first, so Monetary is not affected by joins.
    SELECT o.OrderID, o.CustomerID, CAST(o.OrderTimestamp AS DATE) AS OrderDate,
           SUM(i.LineTotal) AS NetSales
    FROM dbo.fact_orders o
    JOIN dbo.fact_order_items i ON i.OrderID = o.OrderID
    WHERE o.OrderStatus <> 'Cancelled'
    GROUP BY o.OrderID, o.CustomerID, CAST(o.OrderTimestamp AS DATE)
),
customer_base AS (
    SELECT
        CustomerID,
        MIN(OrderDate)                          AS FirstOrderDate,
        MAX(OrderDate)                          AS LastOrderDate,
        DATEDIFF(DAY, MAX(OrderDate), @AsOfDate) AS RecencyDays,
        COUNT(*)                                AS Frequency,
        SUM(NetSales)                           AS Monetary
    FROM order_value
    GROUP BY CustomerID
),
scored AS (
    SELECT
        cb.*,
        -- Most recent customers (smallest RecencyDays) land in tile 5.
        NTILE(5) OVER (ORDER BY cb.RecencyDays DESC, cb.CustomerID) AS R_Score,
        CASE
            WHEN cb.Frequency >= 5 THEN 5
            ELSE cb.Frequency
        END                                                         AS F_Score,
        NTILE(5) OVER (ORDER BY cb.Monetary ASC, cb.CustomerID)     AS M_Score
    FROM customer_base cb
)
SELECT
    s.CustomerID,
    c.CustomerName,
    c.Region,
    c.AcquisitionChannel,
    c.LoyaltyTier,
    s.FirstOrderDate,
    s.LastOrderDate,
    s.RecencyDays,
    s.Frequency,
    s.Monetary,
    CAST(s.Monetary / s.Frequency AS DECIMAL(12,2))  AS AvgOrderValue,
    s.R_Score,
    s.F_Score,
    s.M_Score,
    CONCAT(s.R_Score, s.F_Score, s.M_Score)          AS RFM_Code,
    CASE
        WHEN s.R_Score >= 4 AND s.F_Score >= 4 THEN 'Champions'
        WHEN s.R_Score >= 3 AND s.F_Score >= 3 THEN 'Loyal Customers'
        WHEN s.R_Score >= 4 AND s.F_Score <= 2 THEN 'Potential Loyalists'
        WHEN s.R_Score  = 3 AND s.F_Score <= 2 THEN 'Need Attention'
        WHEN s.R_Score <= 2 AND s.F_Score >= 3 THEN 'At Risk'
        ELSE                                        'Hibernating'
    END                                              AS Segment,
    @AsOfDate                                        AS AsOfDate
INTO #rfm
FROM scored s
JOIN dbo.dim_customers c ON c.CustomerID = s.CustomerID;

CREATE UNIQUE CLUSTERED INDEX CIX_rfm ON #rfm (CustomerID);

-- =========================================
-- 2. SCOPE AND AS-OF DATE
-- =========================================
-- Shows exactly who is and is not scored, so totals reconcile to 05.

SELECT
    (SELECT MAX(AsOfDate) FROM #rfm)                              AS AsOfDate,
    (SELECT MIN(FirstOrderDate) FROM #rfm)                        AS PeriodStart,
    (SELECT MAX(LastOrderDate) FROM #rfm)                         AS PeriodEnd,
    (SELECT COUNT(*) FROM dbo.dim_customers)                      AS AllCustomers,
    (SELECT COUNT(*) FROM #rfm)                                   AS ScoredCustomers,
    (SELECT COUNT(*) FROM dbo.dim_customers c
      WHERE NOT EXISTS (SELECT 1 FROM dbo.fact_orders o WHERE o.CustomerID = c.CustomerID))
                                                                  AS NeverOrdered,
    (SELECT COUNT(*) FROM dbo.dim_customers c
      WHERE EXISTS     (SELECT 1 FROM dbo.fact_orders o WHERE o.CustomerID = c.CustomerID)
        AND NOT EXISTS (SELECT 1 FROM #rfm r WHERE r.CustomerID = c.CustomerID))
                                                                  AS OnlyCancelledOrders,
    (SELECT SUM(Monetary) FROM #rfm)                              AS TotalMonetary;  -- should equal NetSales in 05

-- =========================================
-- 3. SCORE DISTRIBUTION (sanity check)
-- =========================================
-- R and M quintiles should hold ~20% each. F will NOT be even (fixed bands);
-- that is by design. The value ranges show what each score actually means.

SELECT 'R' AS Dimension, R_Score AS Score, COUNT(*) AS Customers,
       MIN(RecencyDays) AS MinValue, MAX(RecencyDays) AS MaxValue
FROM #rfm GROUP BY R_Score
UNION ALL
SELECT 'F', F_Score, COUNT(*), MIN(Frequency), MAX(Frequency)
FROM #rfm GROUP BY F_Score
UNION ALL
SELECT 'M', M_Score, COUNT(*), MIN(Monetary), MAX(Monetary)
FROM #rfm GROUP BY M_Score
ORDER BY Dimension, Score;

-- =========================================
-- 4. SEGMENT SUMMARY
-- =========================================
-- The headline table: how big each segment is and how much it is worth.
-- The gap between CustomerSharePct and RevenueSharePct is the story.

SELECT
    Segment,
    COUNT(*)                                                           AS Customers,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))     AS CustomerSharePct,
    SUM(Monetary)                                                      AS Revenue,
    CAST(100.0 * SUM(Monetary) / SUM(SUM(Monetary)) OVER () AS DECIMAL(5,2)) AS RevenueSharePct,
    CAST(AVG(1.0 * RecencyDays) AS DECIMAL(8,1))                       AS AvgRecencyDays,
    CAST(AVG(1.0 * Frequency)   AS DECIMAL(6,2))                       AS AvgFrequency,
    CAST(AVG(Monetary)          AS DECIMAL(12,2))                      AS AvgMonetary,
    CAST(SUM(Monetary) / SUM(Frequency) AS DECIMAL(12,2))              AS AvgOrderValue
FROM #rfm
GROUP BY Segment
ORDER BY Revenue DESC;

-- =========================================
-- 5. CUSTOMER-LEVEL RFM (full list)
-- =========================================
-- One row per scored customer. Use for export or Power BI drill-through.

SELECT
    CustomerID, CustomerName, Region, AcquisitionChannel, LoyaltyTier,
    FirstOrderDate, LastOrderDate, RecencyDays, Frequency, Monetary, AvgOrderValue,
    R_Score, F_Score, M_Score, RFM_Code, Segment,
    RANK() OVER (ORDER BY Monetary DESC)                         AS ValueRankOverall,
    RANK() OVER (PARTITION BY Segment ORDER BY Monetary DESC)    AS ValueRankInSegment
FROM #rfm
ORDER BY Monetary DESC;

-- =========================================
-- 6. TOP 20 HIGH-VALUE CUSTOMERS
-- =========================================
-- Who the business can least afford to lose. Segment shows whether each
-- is still engaged (Champions) or slipping (At Risk / Hibernating).

SELECT TOP (20)
    CustomerID, CustomerName, Region, LoyaltyTier, Segment, RFM_Code,
    Frequency, Monetary, LastOrderDate, RecencyDays,
    CAST(100.0 * Monetary / SUM(Monetary) OVER () AS DECIMAL(6,3)) AS ShareOfTotalPct  -- share of all scored revenue
FROM #rfm
ORDER BY Monetary DESC;

-- =========================================
-- 7. RETENTION OPPORTUNITIES
-- =========================================
-- Customers who were valuable but are going quiet. Prioritised by spend so
-- the campaign budget goes to the biggest revenue at risk first.
--   At Risk                 : frequent buyers who have stopped.
--   High-value Hibernating  : low frequency but top-quintile spend.
--   Need Attention (M >= 4) : big spenders drifting toward inactivity.

SELECT TOP (100)
    CustomerID, CustomerName, Region, AcquisitionChannel, LoyaltyTier,
    Segment, RFM_Code, Frequency, Monetary, LastOrderDate, RecencyDays,
    CASE
        WHEN Segment = 'At Risk'        THEN 'Win-back offer + personal outreach'
        WHEN Segment = 'Hibernating'    THEN 'Reactivation campaign (high value)'
        WHEN Segment = 'Need Attention' THEN 'Targeted recommendation / limited-time offer'
    END AS SuggestedAction
FROM #rfm
WHERE Segment = 'At Risk'
   OR (Segment = 'Hibernating'    AND M_Score = 5)
   OR (Segment = 'Need Attention' AND M_Score >= 4)
ORDER BY Monetary DESC;

-- 7b. Size of the prize: revenue history of the retention target groups.
SELECT
    CASE
        WHEN Segment = 'At Risk' THEN 'At Risk'
        WHEN Segment = 'Hibernating'    AND M_Score = 5  THEN 'Hibernating, top spend'
        WHEN Segment = 'Need Attention' AND M_Score >= 4 THEN 'Need Attention, high spend'
    END                                       AS RetentionGroup,
    COUNT(*)                                  AS Customers,
    SUM(Monetary)                             AS HistoricRevenue,
    CAST(AVG(Monetary) AS DECIMAL(12,2))      AS AvgRevenuePerCustomer,
    CAST(AVG(1.0 * RecencyDays) AS DECIMAL(8,1)) AS AvgRecencyDays
FROM #rfm
WHERE Segment = 'At Risk'
   OR (Segment = 'Hibernating'    AND M_Score = 5)
   OR (Segment = 'Need Attention' AND M_Score >= 4)
GROUP BY
    CASE
        WHEN Segment = 'At Risk' THEN 'At Risk'
        WHEN Segment = 'Hibernating'    AND M_Score = 5  THEN 'Hibernating, top spend'
        WHEN Segment = 'Need Attention' AND M_Score >= 4 THEN 'Need Attention, high spend'
    END
ORDER BY HistoricRevenue DESC;

-- =========================================
-- 8. SEGMENTS BY CUSTOMER ATTRIBUTES
-- =========================================
-- Does the loyalty programme line up with actual behaviour? If many
-- Platinum/Gold customers sit in At Risk or Hibernating, tier benefits are
-- not driving repeat purchase.

SELECT
    LoyaltyTier,
    Segment,
    COUNT(*)                                                              AS Customers,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY LoyaltyTier) AS DECIMAL(5,2)) AS PctOfTier,
    SUM(Monetary)                                                         AS Revenue
FROM #rfm
GROUP BY LoyaltyTier, Segment
ORDER BY LoyaltyTier, Customers DESC;

-- 8b. Segment mix by acquisition channel: which channels produce loyal
-- customers rather than one-off buyers.
SELECT
    AcquisitionChannel,
    COUNT(*)                                                                         AS Customers,
    CAST(100.0 * SUM(CASE WHEN Segment IN ('Champions','Loyal Customers') THEN 1 ELSE 0 END)
         / COUNT(*) AS DECIMAL(5,2))                                                 AS PctChampionsOrLoyal,
    CAST(100.0 * SUM(CASE WHEN Segment IN ('At Risk','Hibernating') THEN 1 ELSE 0 END)
         / COUNT(*) AS DECIMAL(5,2))                                                 AS PctAtRiskOrHibernating,
    CAST(AVG(1.0 * Frequency) AS DECIMAL(5,2))                                       AS AvgFrequency,
    CAST(AVG(Monetary) AS DECIMAL(12,2))                                             AS AvgMonetary
FROM #rfm
GROUP BY AcquisitionChannel
ORDER BY PctChampionsOrLoyal DESC;

-- 8c. Segment mix by region.
SELECT
    Region,
    Segment,
    COUNT(*)                                                               AS Customers,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY Region) AS DECIMAL(5,2)) AS PctOfRegion,
    SUM(Monetary)                                                          AS Revenue
FROM #rfm
GROUP BY Region, Segment
ORDER BY Region, Revenue DESC;

DROP TABLE #rfm;
GO
