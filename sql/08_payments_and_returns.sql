/*
===============================================================================
Project     : Enterprise Retail Analytics
Database    : RetailAnalytics
DBMS        : Microsoft SQL Server
Script      : 08_payments_and_returns.sql
Purpose     : Payment outcomes and cost of payment processing; return volume,
              reasons, refund exposure and who/what gets returned.
Run after   : 07_product_profitability.sql
Output      : Payment KPIs by method, return-rate KPIs, reason and status
              breakdowns, category and customer-segment return profiles.
===============================================================================

PAYMENT DEFINITIONS
    Successful payment : PaymentStatus = 'Success'.
    Unsuccessful       : any other status ('Voided / Refunded' in this data,
                         which maps 1:1 to cancelled orders, see 04).
    Effective fee rate : ProcessingFee / TotalAmountPaid on successful payments.

RETURN DEFINITIONS
    Denominator        : DELIVERED orders. Returns only occur on delivered
                         orders (verified in 04), so using all orders would
                         understate the rate.
    Order return rate  : delivered orders with >= 1 return / delivered orders.
                         Uses COUNT(DISTINCT OrderID): one order can have
                         several return records (up to 7 in this data).
    Return records     : raw count of rows in fact_returns.
    Refund (raw)       : SUM(RefundAmount) as recorded.
    Refund (capped)    : per order, total refunds capped at the order's net
                         value. 04 found orders refunded more than they were
                         worth; capping gives a defensible lower-bound
                         exposure. Report BOTH; the gap is a Finance question.
    Value return rate  : capped refunds / net sales of delivered orders.
    Refund status      : 'Inspection Pending' refunds are NOT yet paid; they
                         are an open liability, reported separately.

ALLOCATION RULE (returns by category)
    Returns are recorded at ORDER level, not item level. Two views are given:
      a) Order-incidence: % of delivered orders containing the category that
         had a return. No allocation needed, but an order with several
         categories counts for each of them.
      b) Allocated refund: each order's capped refund is split across its
         lines in proportion to LineTotal. This is an ASSUMPTION (we do not
         know which item came back) and is labelled as such.

TIMING CAVEAT
    Returns lag the sale. For the most recent order months the return window
    is still open, so their return rates are understated (see section 9).
===============================================================================
*/

USE RetailAnalytics;
GO

SET NOCOUNT ON;

-- =========================================
-- PART A. PAYMENTS
-- =========================================

-- A1. Payment status distribution.
SELECT
    PaymentStatus,
    COUNT(*)                                                           AS Payments,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))     AS PaymentSharePct,
    SUM(TotalAmountPaid)                                               AS AmountPaid,
    SUM(ProcessingFee)                                                 AS ProcessingFees
FROM dbo.fact_payments
GROUP BY PaymentStatus
ORDER BY Payments DESC;

-- A2. Payment method scorecard: usage, value, cost and failure rate.
-- Fee rate differences across methods are a direct lever on contribution
-- (e.g. steering customers to a cheaper method at checkout).
SELECT
    PaymentMethod,
    COUNT(*)                                                                   AS Payments,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))             AS UsageSharePct,
    SUM(CASE WHEN PaymentStatus = 'Success' THEN 1 ELSE 0 END)                 AS Successful,
    SUM(CASE WHEN PaymentStatus <> 'Success' THEN 1 ELSE 0 END)                AS Unsuccessful,
    CAST(100.0 * SUM(CASE WHEN PaymentStatus <> 'Success' THEN 1 ELSE 0 END)
         / COUNT(*) AS DECIMAL(5,2))                                           AS UnsuccessfulRatePct,
    SUM(CASE WHEN PaymentStatus = 'Success' THEN TotalAmountPaid ELSE 0 END)   AS AmountCollected,
    CAST(AVG(CASE WHEN PaymentStatus = 'Success' THEN TotalAmountPaid END) AS DECIMAL(12,2)) AS AvgPayment,
    SUM(ProcessingFee)                                                         AS ProcessingFees,
    CAST(100.0 * SUM(CASE WHEN PaymentStatus = 'Success' THEN ProcessingFee ELSE 0 END)
         / NULLIF(SUM(CASE WHEN PaymentStatus = 'Success' THEN TotalAmountPaid ELSE 0 END), 0)
         AS DECIMAL(6,3))                                                      AS EffectiveFeeRatePct
FROM dbo.fact_payments
GROUP BY PaymentMethod
ORDER BY AmountCollected DESC;

-- A3. Payment method by region: local preferences matter for checkout design.
SELECT
    c.Region,
    p.PaymentMethod,
    COUNT(*)                                                                  AS Payments,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY c.Region) AS DECIMAL(5,2)) AS ShareOfRegionPct
FROM dbo.fact_payments p
JOIN dbo.fact_orders   o ON o.OrderID    = p.OrderID
JOIN dbo.dim_customers c ON c.CustomerID = o.CustomerID
GROUP BY c.Region, p.PaymentMethod
ORDER BY c.Region, Payments DESC;

-- A4. Monthly payment trend: success rate and fee cost over time.
SELECT
    FORMAT(DATEFROMPARTS(YEAR(o.OrderTimestamp), MONTH(o.OrderTimestamp), 1), 'yyyy-MM') AS YearMonth,
    COUNT(*)                                                                    AS Payments,
    CAST(100.0 * SUM(CASE WHEN p.PaymentStatus = 'Success' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS SuccessRatePct,
    SUM(CASE WHEN p.PaymentStatus = 'Success' THEN p.TotalAmountPaid ELSE 0 END) AS AmountCollected,
    SUM(p.ProcessingFee)                                                        AS ProcessingFees
FROM dbo.fact_payments p
JOIN dbo.fact_orders   o ON o.OrderID = p.OrderID
GROUP BY DATEFROMPARTS(YEAR(o.OrderTimestamp), MONTH(o.OrderTimestamp), 1)
ORDER BY YearMonth;

-- =========================================
-- PART B. RETURNS
-- =========================================
-- Build two working tables once:
--   #delivered     : one row per delivered order with its value and refunds
--   #return_lines  : one row per return record with capped refund share

IF OBJECT_ID('tempdb..#delivered') IS NOT NULL DROP TABLE #delivered;

SELECT
    o.OrderID,
    o.CustomerID,
    o.OrderTimestamp,
    DATEFROMPARTS(YEAR(o.OrderTimestamp), MONTH(o.OrderTimestamp), 1) AS OrderMonth,
    li.NetSales,
    ISNULL(r.ReturnRecords, 0)                                 AS ReturnRecords,
    ISNULL(r.RefundRaw, 0)                                     AS RefundRaw,
    -- Cap total refunds at the order's net value.
    CASE WHEN ISNULL(r.RefundRaw, 0) > li.NetSales
         THEN li.NetSales ELSE ISNULL(r.RefundRaw, 0) END      AS RefundCapped,
    ISNULL(r.RestockingFees, 0)                                AS RestockingFees,
    CASE WHEN r.OrderID IS NOT NULL THEN 1 ELSE 0 END          AS HasReturn
INTO #delivered
FROM dbo.fact_orders o
JOIN (
    SELECT OrderID, SUM(LineTotal) AS NetSales
    FROM dbo.fact_order_items
    GROUP BY OrderID
) li ON li.OrderID = o.OrderID
LEFT JOIN (
    SELECT OrderID,
           COUNT(*)           AS ReturnRecords,
           SUM(RefundAmount)  AS RefundRaw,
           SUM(RestockingFee) AS RestockingFees
    FROM dbo.fact_returns
    GROUP BY OrderID
) r ON r.OrderID = o.OrderID
WHERE o.OrderStatus = 'Delivered';

CREATE UNIQUE CLUSTERED INDEX CIX_delivered ON #delivered (OrderID);

IF OBJECT_ID('tempdb..#return_lines') IS NOT NULL DROP TABLE #return_lines;

SELECT
    r.ReturnID,
    r.OrderID,
    r.ReturnTimestamp,
    r.ReturnReason,
    r.ReturnStatus,
    r.RefundAmount,
    r.RestockingFee,
    -- Each return's share of the order-level cap, so capped amounts still
    -- add up correctly when summed by reason or status.
    CAST(r.RefundAmount * d.RefundCapped / NULLIF(d.RefundRaw, 0) AS DECIMAL(14,2)) AS RefundCapped,
    DATEDIFF(DAY, d.OrderTimestamp, r.ReturnTimestamp)                              AS DaysToReturn
INTO #return_lines
FROM dbo.fact_returns r
JOIN #delivered d ON d.OrderID = r.OrderID;

-- B1. Headline return KPIs.
SELECT
    COUNT(*)                                                         AS DeliveredOrders,
    SUM(HasReturn)                                                   AS OrdersWithReturn,
    CAST(100.0 * SUM(HasReturn) / COUNT(*) AS DECIMAL(5,2))          AS OrderReturnRatePct,
    SUM(ReturnRecords)                                               AS ReturnRecords,
    CAST(1.0 * SUM(ReturnRecords) / NULLIF(SUM(HasReturn), 0) AS DECIMAL(5,2)) AS ReturnsPerReturnedOrder,
    SUM(NetSales)                                                    AS DeliveredNetSales,
    SUM(RefundRaw)                                                   AS RefundRaw,
    SUM(RefundCapped)                                                AS RefundCapped,
    SUM(RefundRaw) - SUM(RefundCapped)                               AS RefundAboveOrderValue,
    CAST(100.0 * SUM(RefundCapped) / SUM(NetSales) AS DECIMAL(5,2))  AS ValueReturnRatePct,
    SUM(RestockingFees)                                              AS RestockingFeesCharged
FROM #delivered;

-- B2. Return reasons: what goes wrong. Reasons split into who is at fault
-- (operations / supplier vs customer choice) so action owners are clear.
SELECT
    ReturnReason,
    CASE
        WHEN ReturnReason IN ('Defective or Damaged Item', 'Missing Parts or Accessories') THEN 'Product / supplier quality'
        WHEN ReturnReason IN ('Item Not as Described', 'Incorrect Size or Color')        THEN 'Listing / fulfilment accuracy'
        WHEN ReturnReason = 'Late Carrier Delivery'                                      THEN 'Logistics'
        WHEN ReturnReason = 'Customer Remorse / Cancelled Mind'                          THEN 'Customer choice'
        ELSE 'Other'
    END                                                                  AS ReasonOwner,
    COUNT(*)                                                             AS ReturnRecords,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))       AS ReturnSharePct,
    SUM(RefundAmount)                                                    AS RefundRaw,
    SUM(RefundCapped)                                                    AS RefundCapped,
    CAST(AVG(RefundAmount) AS DECIMAL(12,2))                             AS AvgRefund,
    CAST(100.0 * SUM(CASE WHEN RestockingFee > 0 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS PctWithRestockingFee,
    SUM(RestockingFee)                                                   AS RestockingFees,
    CAST(AVG(1.0 * DaysToReturn) AS DECIMAL(6,1))                        AS AvgDaysToReturn
FROM #return_lines
GROUP BY ReturnReason
ORDER BY ReturnRecords DESC;

-- B3. Return status: how much is settled vs still open.
SELECT
    ReturnStatus,
    COUNT(*)                                                         AS ReturnRecords,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))   AS ReturnSharePct,
    SUM(RefundAmount)                                                AS RefundRaw,
    SUM(RefundCapped)                                                AS RefundCapped,
    SUM(RestockingFee)                                               AS RestockingFees,
    CASE ReturnStatus
        WHEN 'Processed & Refunded' THEN 'Cash refunded'
        WHEN 'Store Credit Issued'  THEN 'No cash out; store-credit liability'
        WHEN 'Inspection Pending'   THEN 'Open: refund not yet decided'
    END                                                              AS FinancialMeaning
FROM #return_lines
GROUP BY ReturnStatus
ORDER BY ReturnRecords DESC;

-- B4. Restocking fees: how consistently is the policy applied?
SELECT
    CASE WHEN RestockingFee > 0 THEN 'Fee charged' ELSE 'No fee' END AS RestockingFeeApplied,
    COUNT(*)                                                         AS ReturnRecords,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))   AS SharePct,
    SUM(RefundAmount)                                                AS RefundRaw,
    SUM(RestockingFee)                                               AS RestockingFees,
    CAST(100.0 * SUM(RestockingFee) / NULLIF(SUM(RefundAmount), 0) AS DECIMAL(5,2)) AS FeePctOfRefund
FROM #return_lines
GROUP BY CASE WHEN RestockingFee > 0 THEN 'Fee charged' ELSE 'No fee' END;

-- B5. Time to return: distribution in buckets. Sets the return-window
-- assumption used in the timing caveat.
SELECT
    CASE
        WHEN DaysToReturn <= 7   THEN '1. 0-7 days'
        WHEN DaysToReturn <= 14  THEN '2. 8-14 days'
        WHEN DaysToReturn <= 30  THEN '3. 15-30 days'
        WHEN DaysToReturn <= 60  THEN '4. 31-60 days'
        ELSE                          '5. 60+ days'
    END                                                              AS TimeToReturn,
    COUNT(*)                                                         AS ReturnRecords,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))   AS SharePct
FROM #return_lines
GROUP BY
    CASE
        WHEN DaysToReturn <= 7   THEN '1. 0-7 days'
        WHEN DaysToReturn <= 14  THEN '2. 8-14 days'
        WHEN DaysToReturn <= 30  THEN '3. 15-30 days'
        WHEN DaysToReturn <= 60  THEN '4. 31-60 days'
        ELSE                          '5. 60+ days'
    END
ORDER BY TimeToReturn;

-- =========================================
-- PART C. RETURNS BY PRODUCT CATEGORY
-- =========================================

-- C1. Order incidence (no allocation): of delivered orders containing the
-- category, what % had a return?
;WITH order_category AS (
    SELECT DISTINCT d.OrderID, p.Category, d.HasReturn
    FROM #delivered d
    JOIN dbo.fact_order_items i ON i.OrderID   = d.OrderID
    JOIN dbo.dim_products     p ON p.ProductID = i.ProductID
)
SELECT
    Category,
    COUNT(*)                                                     AS DeliveredOrdersWithCategory,
    SUM(HasReturn)                                               AS ReturnedOrders,
    CAST(100.0 * SUM(HasReturn) / COUNT(*) AS DECIMAL(5,2))      AS OrderReturnRatePct
FROM order_category
GROUP BY Category
ORDER BY OrderReturnRatePct DESC;

-- C2. Allocated refund (ASSUMPTION: refund split by line value share).
-- Value return rate = allocated capped refund / category delivered sales.
;WITH line_share AS (
    SELECT
        p.Category,
        i.LineTotal,
        d.RefundCapped * i.LineTotal / NULLIF(d.NetSales, 0) AS AllocatedRefund
    FROM #delivered d
    JOIN dbo.fact_order_items i ON i.OrderID   = d.OrderID
    JOIN dbo.dim_products     p ON p.ProductID = i.ProductID
)
SELECT
    Category,
    SUM(LineTotal)                                                         AS DeliveredSales,
    CAST(SUM(AllocatedRefund) AS DECIMAL(14,2))                            AS AllocatedRefundCapped,
    CAST(100.0 * SUM(AllocatedRefund) / NULLIF(SUM(LineTotal), 0) AS DECIMAL(5,2)) AS ValueReturnRatePct
FROM line_share
GROUP BY Category
ORDER BY ValueReturnRatePct DESC;

-- C3. Return reasons by category (order incidence). Shows whether quality
-- problems concentrate in specific categories.
;WITH order_category AS (
    SELECT DISTINCT i.OrderID, p.Category
    FROM dbo.fact_order_items i
    JOIN dbo.dim_products     p ON p.ProductID = i.ProductID
)
SELECT
    oc.Category,
    rl.ReturnReason,
    COUNT(*)                                                                          AS ReturnRecords,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY oc.Category) AS DECIMAL(5,2)) AS ShareOfCategoryReturnsPct
FROM #return_lines rl
JOIN order_category oc ON oc.OrderID = rl.OrderID
GROUP BY oc.Category, rl.ReturnReason
ORDER BY oc.Category, ReturnRecords DESC;

-- =========================================
-- PART D. RETURNS BY CUSTOMER SEGMENT
-- =========================================
-- Customer attributes from dim_customers. Return behaviour by RFM segment
-- is available once 09 has run: join vw_customer_rfm to vw_order_summary
-- on CustomerID and group by Segment (HasReturn, RefundCapped are there).

-- D1. By loyalty tier: are premium tiers returning more (generous policy)
-- or less (better-matched purchases)?
SELECT
    c.LoyaltyTier,
    COUNT(*)                                                         AS DeliveredOrders,
    SUM(d.HasReturn)                                                 AS ReturnedOrders,
    CAST(100.0 * SUM(d.HasReturn) / COUNT(*) AS DECIMAL(5,2))        AS OrderReturnRatePct,
    SUM(d.RefundCapped)                                              AS RefundCapped,
    CAST(100.0 * SUM(d.RefundCapped) / SUM(d.NetSales) AS DECIMAL(5,2)) AS ValueReturnRatePct
FROM #delivered d
JOIN dbo.dim_customers c ON c.CustomerID = d.CustomerID
GROUP BY c.LoyaltyTier
ORDER BY OrderReturnRatePct DESC;

-- D2. By region.
SELECT
    c.Region,
    COUNT(*)                                                         AS DeliveredOrders,
    SUM(d.HasReturn)                                                 AS ReturnedOrders,
    CAST(100.0 * SUM(d.HasReturn) / COUNT(*) AS DECIMAL(5,2))        AS OrderReturnRatePct,
    SUM(d.RefundCapped)                                              AS RefundCapped,
    CAST(100.0 * SUM(d.RefundCapped) / SUM(d.NetSales) AS DECIMAL(5,2)) AS ValueReturnRatePct
FROM #delivered d
JOIN dbo.dim_customers c ON c.CustomerID = d.CustomerID
GROUP BY c.Region
ORDER BY OrderReturnRatePct DESC;

-- D3. By acquisition channel: some channels attract bargain hunters who
-- return more. Combine with 05 section 7 to judge true channel value.
SELECT
    c.AcquisitionChannel,
    COUNT(*)                                                         AS DeliveredOrders,
    SUM(d.HasReturn)                                                 AS ReturnedOrders,
    CAST(100.0 * SUM(d.HasReturn) / COUNT(*) AS DECIMAL(5,2))        AS OrderReturnRatePct,
    SUM(d.RefundCapped)                                              AS RefundCapped,
    CAST(100.0 * SUM(d.RefundCapped) / SUM(d.NetSales) AS DECIMAL(5,2)) AS ValueReturnRatePct
FROM #delivered d
JOIN dbo.dim_customers c ON c.CustomerID = d.CustomerID
GROUP BY c.AcquisitionChannel
ORDER BY OrderReturnRatePct DESC;

-- D4. Serial returners: customers with the most return records. Candidates
-- for return-policy review, not automatic action.
SELECT TOP (20)
    d.CustomerID,
    c.LoyaltyTier,
    c.Region,
    COUNT(*)                                                         AS DeliveredOrders,
    SUM(d.HasReturn)                                                 AS ReturnedOrders,
    SUM(d.ReturnRecords)                                             AS ReturnRecords,
    SUM(d.NetSales)                                                  AS DeliveredSales,
    SUM(d.RefundRaw)                                                 AS RefundRaw,
    SUM(d.RefundCapped)                                              AS RefundCapped
FROM #delivered d
JOIN dbo.dim_customers c ON c.CustomerID = d.CustomerID
GROUP BY d.CustomerID, c.LoyaltyTier, c.Region
HAVING SUM(d.HasReturn) > 0
ORDER BY ReturnRecords DESC, RefundRaw DESC;

-- =========================================
-- PART E. RETURN TREND BY ORDER MONTH
-- =========================================
-- Cohorted by the month the order was placed (not the return month), so each
-- month's rate is "of what we delivered that month, how much came back".
-- The last 1-2 months are understated: their return window is still open.

SELECT
    FORMAT(OrderMonth, 'yyyy-MM')                                    AS OrderMonth,
    COUNT(*)                                                         AS DeliveredOrders,
    SUM(HasReturn)                                                   AS ReturnedOrders,
    CAST(100.0 * SUM(HasReturn) / COUNT(*) AS DECIMAL(5,2))          AS OrderReturnRatePct,
    SUM(NetSales)                                                    AS DeliveredSales,
    SUM(RefundCapped)                                                AS RefundCapped,
    CAST(100.0 * SUM(RefundCapped) / SUM(NetSales) AS DECIMAL(5,2))  AS ValueReturnRatePct
FROM #delivered
GROUP BY OrderMonth
ORDER BY OrderMonth;

DROP TABLE #return_lines;
DROP TABLE #delivered;
GO
