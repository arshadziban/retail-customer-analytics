/*
Script  : 08_payments_and_returns.sql
Purpose : Payment outcomes and fees; return rates, reasons and refunds.
          Return rate base = delivered orders. Refunds capped at order value (RefundCapped).
*/

USE RetailAnalytics;
GO

SET NOCOUNT ON;

-- PART A. PAYMENTS
SELECT
    PaymentStatus,
    COUNT(*)                                                           AS Payments,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))     AS PaymentSharePct,
    SUM(TotalAmountPaid)                                               AS AmountPaid,
    SUM(ProcessingFee)                                                 AS ProcessingFees
FROM dbo.fact_payments
GROUP BY PaymentStatus
ORDER BY Payments DESC;

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

-- PART B. RETURNS
IF OBJECT_ID('tempdb..#delivered') IS NOT NULL DROP TABLE #delivered;

SELECT
    o.OrderID,
    o.CustomerID,
    o.OrderTimestamp,
    DATEFROMPARTS(YEAR(o.OrderTimestamp), MONTH(o.OrderTimestamp), 1) AS OrderMonth,
    li.NetSales,
    ISNULL(r.ReturnRecords, 0)                                 AS ReturnRecords,
    ISNULL(r.RefundRaw, 0)                                     AS RefundRaw,
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
    CAST(r.RefundAmount * d.RefundCapped / NULLIF(d.RefundRaw, 0) AS DECIMAL(14,2)) AS RefundCapped,
    DATEDIFF(DAY, d.OrderTimestamp, r.ReturnTimestamp)                              AS DaysToReturn
INTO #return_lines
FROM dbo.fact_returns r
JOIN #delivered d ON d.OrderID = r.OrderID;

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

SELECT
    CASE WHEN RestockingFee > 0 THEN 'Fee charged' ELSE 'No fee' END AS RestockingFeeApplied,
    COUNT(*)                                                         AS ReturnRecords,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))   AS SharePct,
    SUM(RefundAmount)                                                AS RefundRaw,
    SUM(RestockingFee)                                               AS RestockingFees,
    CAST(100.0 * SUM(RestockingFee) / NULLIF(SUM(RefundAmount), 0) AS DECIMAL(5,2)) AS FeePctOfRefund
FROM #return_lines
GROUP BY CASE WHEN RestockingFee > 0 THEN 'Fee charged' ELSE 'No fee' END;

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

-- PART C. RETURNS BY PRODUCT CATEGORY
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

-- PART D. RETURNS BY CUSTOMER SEGMENT
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

-- PART E. RETURN TREND BY ORDER MONTH
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
