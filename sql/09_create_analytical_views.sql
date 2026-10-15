/*
===============================================================================
Project     : Enterprise Retail Analytics
Database    : RetailAnalytics
DBMS        : Microsoft SQL Server
Script      : 09_create_analytical_views.sql
Purpose     : Publish the analysis logic from 05-08 as reusable views, so
              Power BI (and anyone else) reads one governed definition of
              each metric instead of re-implementing it.
Run after   : 05-08 (the logic below mirrors those scripts)
===============================================================================

VIEWS
    vw_order_summary          one row per order. The base layer: revenue,
                              margin, costs, payment and return measures all
                              at ORDER grain. Most other views build on it.
    vw_sales_monthly          one row per order month: sales KPIs + returns.
    vw_customer_rfm           one row per purchasing customer: RFM scores
                              and segment (same rules as 06).
    vw_product_profitability  one row per product: sales, margin, stock status.
    vw_payment_summary        one row per order month x method x status.
    vw_returns_summary        one row per return month x reason x status.

DESIGN RULES
    - Every view repeats the metric definitions from 05 (qualifying order =
      not Cancelled; net sales = SUM(LineTotal); refunds capped at order value).
      If a rule changes, change it here AND in the matching analysis script.
    - Views expose ADDITIVE components (sums and counts) alongside ratios.
      In Power BI, build ratios as measures from the components, e.g.
      DIVIDE(SUM(ItemMargin), SUM(NetSales)). Averaging a pre-computed
      percentage across rows gives the wrong answer.
    - No ORDER BY inside views (SQL Server ignores it); sort in the report.
    - CREATE OR ALTER makes the script safe to re-run (SQL Server 2016 SP1+).
    - Dates are relative to the data (last order), not GETDATE(), so results
      are stable for a historical extract.
===============================================================================
*/

USE RetailAnalytics;
GO

-- =========================================
-- 1. vw_order_summary  (grain: one row per order)
-- =========================================
-- The single place where lines, payments and returns are rolled up to the
-- order. Every child table is aggregated BEFORE the join, so no amount is
-- ever duplicated. Includes cancelled orders; filter on IsQualifying.

CREATE OR ALTER VIEW dbo.vw_order_summary
AS
SELECT
    o.OrderID,
    o.CustomerID,
    o.OrderTimestamp,
    CAST(o.OrderTimestamp AS DATE)                                  AS OrderDate,
    DATEFROMPARTS(YEAR(o.OrderTimestamp), MONTH(o.OrderTimestamp), 1) AS OrderMonth,
    o.OrderStatus,
    CASE WHEN o.OrderStatus <> 'Cancelled' THEN 1 ELSE 0 END        AS IsQualifying,
    CASE WHEN o.OrderStatus =  'Delivered' THEN 1 ELSE 0 END        AS IsDelivered,
    o.ShippingMethod,
    c.Region,
    c.AcquisitionChannel,
    c.LoyaltyTier,
    p.PaymentMethod,
    p.PaymentStatus,

    -- Line measures
    li.LineCount,
    li.Units,
    li.GrossSales,
    li.Discounts,
    li.NetSales,
    li.ItemMargin,

    -- Order-level costs (absorbed by the business, not charged to customer)
    o.FreightCost,
    ISNULL(p.ProcessingFee, 0)                                      AS ProcessingFee,
    li.ItemMargin - o.FreightCost - ISNULL(p.ProcessingFee, 0)      AS Contribution,
    ISNULL(p.TotalAmountPaid, 0)                                    AS AmountPaid,

    -- Return measures (refund capped at order value, see 08)
    CASE WHEN r.OrderID IS NOT NULL THEN 1 ELSE 0 END               AS HasReturn,
    ISNULL(r.ReturnRecords, 0)                                      AS ReturnRecords,
    ISNULL(r.RefundRaw, 0)                                          AS RefundRaw,
    CASE WHEN ISNULL(r.RefundRaw, 0) > li.NetSales
         THEN li.NetSales ELSE ISNULL(r.RefundRaw, 0) END           AS RefundCapped,
    ISNULL(r.RestockingFees, 0)                                     AS RestockingFees
FROM dbo.fact_orders o
JOIN dbo.dim_customers c ON c.CustomerID = o.CustomerID
JOIN (
    SELECT
        OrderID,
        COUNT(*)                  AS LineCount,
        SUM(Quantity)             AS Units,
        SUM(Quantity * UnitPrice) AS GrossSales,
        SUM(DiscountAmount)       AS Discounts,
        SUM(LineTotal)            AS NetSales,
        SUM(ItemNetMargin)        AS ItemMargin
    FROM dbo.fact_order_items
    GROUP BY OrderID
) li ON li.OrderID = o.OrderID
LEFT JOIN dbo.fact_payments p ON p.OrderID = o.OrderID
LEFT JOIN (
    SELECT
        OrderID,
        COUNT(*)           AS ReturnRecords,
        SUM(RefundAmount)  AS RefundRaw,
        SUM(RestockingFee) AS RestockingFees
    FROM dbo.fact_returns
    GROUP BY OrderID
) r ON r.OrderID = o.OrderID;
GO

-- =========================================
-- 2. vw_sales_monthly  (grain: one row per order month)
-- =========================================
-- Executive trend view. Revenue columns are qualifying orders only; return
-- columns use delivered orders as the base (same rules as 05 and 08).
-- Return figures for the latest months are incomplete (window still open).

CREATE OR ALTER VIEW dbo.vw_sales_monthly
AS
SELECT
    OrderMonth,
    YEAR(OrderMonth)                                                AS OrderYear,
    DATEPART(QUARTER, OrderMonth)                                   AS OrderQuarter,

    COUNT(*)                                                        AS AllOrders,
    SUM(1 - IsQualifying)                                           AS CancelledOrders,
    SUM(IsQualifying)                                               AS QualifyingOrders,
    COUNT(DISTINCT CASE WHEN IsQualifying = 1 THEN CustomerID END)  AS ActiveCustomers,

    SUM(CASE WHEN IsQualifying = 1 THEN Units         ELSE 0 END)   AS UnitsSold,
    SUM(CASE WHEN IsQualifying = 1 THEN GrossSales    ELSE 0 END)   AS GrossSales,
    SUM(CASE WHEN IsQualifying = 1 THEN Discounts     ELSE 0 END)   AS Discounts,
    SUM(CASE WHEN IsQualifying = 1 THEN NetSales      ELSE 0 END)   AS NetSales,
    SUM(CASE WHEN IsQualifying = 1 THEN ItemMargin    ELSE 0 END)   AS ItemMargin,
    SUM(CASE WHEN IsQualifying = 1 THEN FreightCost   ELSE 0 END)   AS FreightCost,
    SUM(CASE WHEN IsQualifying = 1 THEN ProcessingFee ELSE 0 END)   AS ProcessingFees,
    SUM(CASE WHEN IsQualifying = 1 THEN Contribution  ELSE 0 END)   AS Contribution,
    SUM(CASE WHEN IsQualifying = 0 THEN NetSales      ELSE 0 END)   AS CancelledOrderValue,

    SUM(IsDelivered)                                                AS DeliveredOrders,
    SUM(CASE WHEN IsDelivered = 1 THEN NetSales ELSE 0 END)         AS DeliveredNetSales,
    SUM(CASE WHEN IsDelivered = 1 THEN HasReturn ELSE 0 END)        AS ReturnedOrders,
    SUM(RefundCapped)                                               AS RefundCapped,
    SUM(RefundRaw)                                                  AS RefundRaw,

    -- Convenience ratios for this grain only (do not average across months).
    CAST(SUM(CASE WHEN IsQualifying = 1 THEN NetSales ELSE 0 END)
         / NULLIF(SUM(IsQualifying), 0) AS DECIMAL(12,2))           AS AvgOrderValue,
    CAST(100.0 * SUM(CASE WHEN IsQualifying = 1 THEN ItemMargin ELSE 0 END)
         / NULLIF(SUM(CASE WHEN IsQualifying = 1 THEN NetSales ELSE 0 END), 0) AS DECIMAL(5,2)) AS ItemMarginPct,
    CAST(100.0 * SUM(CASE WHEN IsDelivered = 1 THEN HasReturn ELSE 0 END)
         / NULLIF(SUM(IsDelivered), 0) AS DECIMAL(5,2))             AS OrderReturnRatePct
FROM dbo.vw_order_summary
GROUP BY OrderMonth;
GO

-- =========================================
-- 3. vw_customer_rfm  (grain: one row per purchasing customer)
-- =========================================
-- Same scoring and segment rules as 06 (see that header for the reasoning).
-- Customers with no qualifying order are not included.

CREATE OR ALTER VIEW dbo.vw_customer_rfm
AS
WITH as_of AS (
    SELECT DATEADD(DAY, 1, MAX(OrderDate)) AS AsOfDate
    FROM dbo.vw_order_summary
    WHERE IsQualifying = 1
),
customer_base AS (
    SELECT
        s.CustomerID,
        MIN(s.OrderDate)                              AS FirstOrderDate,
        MAX(s.OrderDate)                              AS LastOrderDate,
        DATEDIFF(DAY, MAX(s.OrderDate), a.AsOfDate)   AS RecencyDays,
        COUNT(*)                                      AS Frequency,
        SUM(s.NetSales)                               AS Monetary,
        a.AsOfDate
    FROM dbo.vw_order_summary s
    CROSS JOIN as_of a
    WHERE s.IsQualifying = 1
    GROUP BY s.CustomerID, a.AsOfDate
),
scored AS (
    SELECT
        cb.*,
        NTILE(5) OVER (ORDER BY cb.RecencyDays DESC, cb.CustomerID) AS R_Score,
        CASE WHEN cb.Frequency >= 5 THEN 5 ELSE cb.Frequency END    AS F_Score,
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
    s.AsOfDate,
    s.RecencyDays,
    s.Frequency,
    s.Monetary,
    CAST(s.Monetary / s.Frequency AS DECIMAL(12,2)) AS AvgOrderValue,
    s.R_Score,
    s.F_Score,
    s.M_Score,
    CONCAT(s.R_Score, s.F_Score, s.M_Score)         AS RFM_Code,
    CASE
        WHEN s.R_Score >= 4 AND s.F_Score >= 4 THEN 'Champions'
        WHEN s.R_Score >= 3 AND s.F_Score >= 3 THEN 'Loyal Customers'
        WHEN s.R_Score >= 4 AND s.F_Score <= 2 THEN 'Potential Loyalists'
        WHEN s.R_Score  = 3 AND s.F_Score <= 2 THEN 'Need Attention'
        WHEN s.R_Score <= 2 AND s.F_Score >= 3 THEN 'At Risk'
        ELSE                                        'Hibernating'
    END                                             AS Segment,
    -- Sort key so Power BI shows segments best-to-worst, not alphabetically.
    CASE
        WHEN s.R_Score >= 4 AND s.F_Score >= 4 THEN 1
        WHEN s.R_Score >= 3 AND s.F_Score >= 3 THEN 2
        WHEN s.R_Score >= 4 AND s.F_Score <= 2 THEN 3
        WHEN s.R_Score  = 3 AND s.F_Score <= 2 THEN 4
        WHEN s.R_Score <= 2 AND s.F_Score >= 3 THEN 5
        ELSE                                        6
    END                                             AS SegmentSortOrder
FROM scored s
JOIN dbo.dim_customers c ON c.CustomerID = s.CustomerID;
GO

-- =========================================
-- 4. vw_product_profitability  (grain: one row per product)
-- =========================================
-- All catalogue products, including never-sold ones (zeros, not missing).
-- Item margin only: freight and fees are not allocated to products (see 07).
-- StockStatus uses the same rules and 90-day demand window as 07.

CREATE OR ALTER VIEW dbo.vw_product_profitability
AS
WITH last_order AS (
    SELECT MAX(CAST(OrderTimestamp AS DATE)) AS LastOrderDate
    FROM dbo.fact_orders
    WHERE OrderStatus <> 'Cancelled'
),
sales AS (
    SELECT
        i.ProductID,
        COUNT(*)                                   AS OrderLines,
        COUNT(DISTINCT i.OrderID)                  AS Orders,
        SUM(i.Quantity)                            AS Units,
        SUM(i.Quantity * i.UnitPrice)              AS GrossSales,
        SUM(i.DiscountAmount)                      AS Discounts,
        SUM(i.LineTotal)                           AS Revenue,
        SUM(i.ItemNetMargin)                       AS ItemMargin,
        SUM(CASE WHEN o.OrderTimestamp >= DATEADD(DAY, -89, lo.LastOrderDate)
                 THEN i.Quantity ELSE 0 END)       AS Units90d,
        MAX(CAST(o.OrderTimestamp AS DATE))        AS LastSoldDate
    FROM dbo.fact_order_items i
    JOIN dbo.fact_orders o ON o.OrderID = i.OrderID
    CROSS JOIN last_order lo
    WHERE o.OrderStatus <> 'Cancelled'
    GROUP BY i.ProductID
),
base AS (
    SELECT
        p.ProductID,
        p.ProductName,
        p.Category,
        p.SKU,
        p.UnitPrice                      AS ListPrice,
        p.UnitCost                       AS ListCost,
        p.StockOnHand,
        p.ReorderPoint,
        p.StockOnHand * p.UnitCost       AS StockValueAtCost,
        ISNULL(s.OrderLines, 0)          AS OrderLines,
        ISNULL(s.Orders, 0)              AS Orders,
        ISNULL(s.Units, 0)               AS Units,
        ISNULL(s.GrossSales, 0)          AS GrossSales,
        ISNULL(s.Discounts, 0)           AS Discounts,
        ISNULL(s.Revenue, 0)             AS Revenue,
        ISNULL(s.ItemMargin, 0)          AS ItemMargin,
        ISNULL(s.Units90d, 0)            AS Units90d,
        s.LastSoldDate
    FROM dbo.dim_products p
    LEFT JOIN sales s ON s.ProductID = p.ProductID
)
SELECT
    *,
    CAST(100.0 * ItemMargin / NULLIF(Revenue, 0) AS DECIMAL(5,2))       AS MarginPct,
    CAST(Revenue / NULLIF(Units, 0) AS DECIMAL(10,2))                    AS AvgSellingPrice,
    CAST(CASE WHEN Units90d > 0 THEN StockOnHand / (Units90d / 90.0) END AS DECIMAL(10,1)) AS DaysOfCover,
    CASE
        WHEN StockOnHand = 0                                       THEN '1. Out of stock'
        WHEN StockOnHand <= ReorderPoint                           THEN '2. Reorder now'
        WHEN Units90d > 0 AND StockOnHand / (Units90d / 90.0) < 30 THEN '3. Low cover'
        WHEN Units90d = 0                                          THEN '4. No recent demand'
        WHEN StockOnHand / (Units90d / 90.0) > 365                 THEN '5. Overstocked'
        ELSE                                                            '6. Healthy'
    END                                                                  AS StockStatus,
    RANK() OVER (ORDER BY ItemMargin DESC)                               AS MarginRankOverall,
    RANK() OVER (PARTITION BY Category ORDER BY ItemMargin DESC)         AS MarginRankInCategory
FROM base;
GO

-- =========================================
-- 5. vw_payment_summary  (grain: order month x payment method x status)
-- =========================================
-- Small, additive table for payment KPIs. Success rate and fee rate are
-- built as measures in Power BI from the counts and sums below.

CREATE OR ALTER VIEW dbo.vw_payment_summary
AS
SELECT
    DATEFROMPARTS(YEAR(o.OrderTimestamp), MONTH(o.OrderTimestamp), 1) AS OrderMonth,
    p.PaymentMethod,
    p.PaymentStatus,
    CASE WHEN p.PaymentStatus = 'Success' THEN 1 ELSE 0 END          AS IsSuccessful,
    COUNT(*)                                                         AS Payments,
    SUM(p.TotalAmountPaid)                                           AS AmountPaid,
    SUM(p.ProcessingFee)                                             AS ProcessingFees
FROM dbo.fact_payments p
JOIN dbo.fact_orders   o ON o.OrderID = p.OrderID
GROUP BY
    DATEFROMPARTS(YEAR(o.OrderTimestamp), MONTH(o.OrderTimestamp), 1),
    p.PaymentMethod,
    p.PaymentStatus;
GO

-- =========================================
-- 6. vw_returns_summary  (grain: return month x reason x status)
-- =========================================
-- Return VOLUME and COST by when they were logged, why, and how far along
-- they are. Return RATES need an order denominator and live in
-- vw_sales_monthly (by order month), so the two views answer different
-- questions and should not be mixed in one visual.
-- RefundCapped: each return's share of its order's capped refund (see 08).

CREATE OR ALTER VIEW dbo.vw_returns_summary
AS
WITH order_refund AS (
    SELECT OrderID, NetSales, RefundRaw, RefundCapped, OrderTimestamp
    FROM dbo.vw_order_summary
    WHERE HasReturn = 1
),
return_lines AS (
    SELECT
        r.ReturnID,
        r.OrderID,
        DATEFROMPARTS(YEAR(r.ReturnTimestamp), MONTH(r.ReturnTimestamp), 1) AS ReturnMonth,
        r.ReturnReason,
        r.ReturnStatus,
        r.RefundAmount,
        r.RestockingFee,
        r.RefundAmount * o.RefundCapped / NULLIF(o.RefundRaw, 0)            AS RefundCapped,
        DATEDIFF(DAY, o.OrderTimestamp, r.ReturnTimestamp)                  AS DaysToReturn
    FROM dbo.fact_returns r
    JOIN order_refund o ON o.OrderID = r.OrderID
)
SELECT
    ReturnMonth,
    ReturnReason,
    CASE
        WHEN ReturnReason IN ('Defective or Damaged Item', 'Missing Parts or Accessories') THEN 'Product / supplier quality'
        WHEN ReturnReason IN ('Item Not as Described', 'Incorrect Size or Color')        THEN 'Listing / fulfilment accuracy'
        WHEN ReturnReason = 'Late Carrier Delivery'                                      THEN 'Logistics'
        WHEN ReturnReason = 'Customer Remorse / Cancelled Mind'                          THEN 'Customer choice'
        ELSE 'Other'
    END                                                   AS ReasonOwner,
    ReturnStatus,
    COUNT(*)                                              AS ReturnRecords,
    COUNT(DISTINCT OrderID)                               AS OrdersAffected,
    SUM(RefundAmount)                                     AS RefundRaw,
    CAST(SUM(RefundCapped) AS DECIMAL(14,2))              AS RefundCapped,
    SUM(RestockingFee)                                    AS RestockingFees,
    SUM(CASE WHEN RestockingFee > 0 THEN 1 ELSE 0 END)    AS ReturnsWithRestockingFee,
    SUM(DaysToReturn)                                     AS TotalDaysToReturn   -- / ReturnRecords = avg days
FROM return_lines
GROUP BY ReturnMonth, ReturnReason, ReturnStatus;
GO

-- =========================================
-- 7. VERIFY VIEWS AND RECONCILE TO SOURCE
-- =========================================
-- Views exist, and their totals tie back to the base tables. If any
-- Difference is non-zero, a view is double counting or dropping rows.

SELECT name AS ViewName, create_date, modify_date
FROM sys.views
WHERE name IN ('vw_order_summary', 'vw_sales_monthly', 'vw_customer_rfm',
               'vw_product_profitability', 'vw_payment_summary', 'vw_returns_summary')
ORDER BY name;

SELECT 'Net sales: vw_sales_monthly vs fact tables' AS Reconciliation,
       (SELECT SUM(NetSales) FROM dbo.vw_sales_monthly)                       AS ViewTotal,
       (SELECT SUM(i.LineTotal) FROM dbo.fact_order_items i
          JOIN dbo.fact_orders o ON o.OrderID = i.OrderID
         WHERE o.OrderStatus <> 'Cancelled')                                  AS SourceTotal
UNION ALL
SELECT 'Monetary: vw_customer_rfm vs qualifying net sales',
       (SELECT SUM(Monetary) FROM dbo.vw_customer_rfm),
       (SELECT SUM(i.LineTotal) FROM dbo.fact_order_items i
          JOIN dbo.fact_orders o ON o.OrderID = i.OrderID
         WHERE o.OrderStatus <> 'Cancelled')
UNION ALL
SELECT 'Revenue: vw_product_profitability vs qualifying net sales',
       (SELECT SUM(Revenue) FROM dbo.vw_product_profitability),
       (SELECT SUM(i.LineTotal) FROM dbo.fact_order_items i
          JOIN dbo.fact_orders o ON o.OrderID = i.OrderID
         WHERE o.OrderStatus <> 'Cancelled')
UNION ALL
SELECT 'Amount paid: vw_payment_summary vs fact_payments',
       (SELECT SUM(AmountPaid) FROM dbo.vw_payment_summary),
       (SELECT SUM(TotalAmountPaid) FROM dbo.fact_payments)
UNION ALL
SELECT 'Return records: vw_returns_summary vs fact_returns',
       (SELECT SUM(ReturnRecords) FROM dbo.vw_returns_summary),
       (SELECT COUNT(*) FROM dbo.fact_returns)
UNION ALL
SELECT 'Capped refunds: vw_returns_summary vs vw_order_summary',
       (SELECT SUM(RefundCapped) FROM dbo.vw_returns_summary),
       (SELECT SUM(RefundCapped) FROM dbo.vw_order_summary);
GO
