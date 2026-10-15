/*
===============================================================================
Project     : Enterprise Retail Analytics
Database    : RetailAnalytics
DBMS        : Microsoft SQL Server
Script      : 04_data_quality_checks.sql
Purpose     : Find missing, inconsistent or suspicious values BEFORE they
              reach a KPI. 03 proved the data is structurally sound; this
              script asks whether it is believable.
Run after   : 03_validate_keys_and_rows.sql
Run before  : 05_sales_analysis.sql
===============================================================================

APPROACH
    - Every check writes one row to #dq_results: what was tested, how many
      rows are affected, severity, and what to do about it.
    - Severity:
        HIGH   : changes a headline KPI if ignored. Must have a documented rule.
        MEDIUM : affects a specific analysis; handle where that analysis runs.
        LOW    : cosmetic or informational.
        OK     : check ran and found nothing.
    - Section 9 returns sample rows for the issues that need investigation.

GOVERNANCE RULE
    This script is READ-ONLY. Nothing is deleted or "fixed" here. Suspicious
    records may be valid business cases (a return weeks after delivery, a
    zero-freight promotion). Decide the treatment, document it, and apply it
    in the analysis layer (05-09) where it is visible and reversible.

TOLERANCE
    Money comparisons allow 0.01 per row (or per order) for rounding, because
    the source stores pre-rounded line values.
===============================================================================
*/

USE RetailAnalytics;
GO

SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#dq_results') IS NOT NULL DROP TABLE #dq_results;

CREATE TABLE #dq_results (
    CheckNo        INT IDENTITY(1,1),
    Area           VARCHAR(30),
    CheckName      VARCHAR(200),
    RowsAffected   BIGINT,
    RowsChecked    BIGINT,
    Severity       VARCHAR(6),     -- HIGH / MEDIUM / LOW / OK
    Recommendation VARCHAR(400)
);

-- Helper rule used throughout: if RowsAffected = 0 the severity becomes OK,
-- so the report only shouts about real problems.

-- =========================================
-- 1. MISSING VALUES
-- =========================================
-- Columns are NOT NULL, so true NULLs are impossible. The realistic risk is
-- blank or whitespace-only text that passed the NOT NULL constraint.

INSERT INTO #dq_results (Area, CheckName, RowsAffected, RowsChecked, Severity, Recommendation)
SELECT 'Missing values', m.CheckName, m.Affected, m.Checked,
       CASE WHEN m.Affected = 0 THEN 'OK' ELSE 'MEDIUM' END,
       'Map blanks to an explicit ''Unknown'' member in reporting; do not drop the rows.'
FROM (
    SELECT 'dim_customers: blank name / channel / region / tier' AS CheckName,
           SUM(CASE WHEN LTRIM(RTRIM(CustomerName)) = '' OR LTRIM(RTRIM(AcquisitionChannel)) = ''
                      OR LTRIM(RTRIM(Region)) = ''       OR LTRIM(RTRIM(LoyaltyTier)) = ''
                    THEN 1 ELSE 0 END) AS Affected,
           COUNT(*) AS Checked
    FROM dbo.dim_customers
    UNION ALL
    SELECT 'dim_products: blank category / name / SKU',
           SUM(CASE WHEN LTRIM(RTRIM(Category)) = '' OR LTRIM(RTRIM(ProductName)) = ''
                      OR LTRIM(RTRIM(SKU)) = '' THEN 1 ELSE 0 END),
           COUNT(*)
    FROM dbo.dim_products
    UNION ALL
    SELECT 'fact_orders: blank status / shipping method',
           SUM(CASE WHEN LTRIM(RTRIM(OrderStatus)) = '' OR LTRIM(RTRIM(ShippingMethod)) = ''
                    THEN 1 ELSE 0 END),
           COUNT(*)
    FROM dbo.fact_orders
    UNION ALL
    SELECT 'fact_payments: blank method / status',
           SUM(CASE WHEN LTRIM(RTRIM(PaymentMethod)) = '' OR LTRIM(RTRIM(PaymentStatus)) = ''
                    THEN 1 ELSE 0 END),
           COUNT(*)
    FROM dbo.fact_payments
    UNION ALL
    SELECT 'fact_returns: blank reason / status',
           SUM(CASE WHEN LTRIM(RTRIM(ReturnReason)) = '' OR LTRIM(RTRIM(ReturnStatus)) = ''
                    THEN 1 ELSE 0 END),
           COUNT(*)
    FROM dbo.fact_returns
) AS m;

-- =========================================
-- 2. UNEXPECTED CATEGORY VALUES (domain checks)
-- =========================================
-- Any value outside the agreed list would silently fall out of every
-- CASE / filter in the analysis scripts. Allowed lists reflect the values
-- profiled in the source data; extend them deliberately, never implicitly.

INSERT INTO #dq_results (Area, CheckName, RowsAffected, RowsChecked, Severity, Recommendation)
SELECT 'Domain values', d.CheckName, d.Affected, d.Checked,
       CASE WHEN d.Affected = 0 THEN 'OK' ELSE 'HIGH' END,
       'Agree a mapping for the new value before it enters KPI filters.'
FROM (
    SELECT 'fact_orders.OrderStatus not in allowed list' AS CheckName,
           SUM(CASE WHEN OrderStatus NOT IN ('Processing','Shipped','Delivered','Cancelled') THEN 1 ELSE 0 END) AS Affected,
           COUNT(*) AS Checked
    FROM dbo.fact_orders
    UNION ALL
    SELECT 'fact_payments.PaymentStatus not in allowed list',
           SUM(CASE WHEN PaymentStatus NOT IN ('Success','Voided / Refunded') THEN 1 ELSE 0 END),
           COUNT(*)
    FROM dbo.fact_payments
    UNION ALL
    SELECT 'fact_returns.ReturnStatus not in allowed list',
           SUM(CASE WHEN ReturnStatus NOT IN ('Inspection Pending','Processed & Refunded','Store Credit Issued') THEN 1 ELSE 0 END),
           COUNT(*)
    FROM dbo.fact_returns
    UNION ALL
    SELECT 'dim_customers.LoyaltyTier not in allowed list',
           SUM(CASE WHEN LoyaltyTier NOT IN ('Standard','Silver','Gold','Platinum') THEN 1 ELSE 0 END),
           COUNT(*)
    FROM dbo.dim_customers
) AS d;

-- =========================================
-- 3. DATE AND TIMELINE LOGIC
-- =========================================
-- Types guarantee valid dates; these test whether the SEQUENCE of events
-- makes business sense.

-- 3a. Orders placed before the customer signed up.
INSERT INTO #dq_results (Area, CheckName, RowsAffected, RowsChecked, Severity, Recommendation)
SELECT 'Timeline', 'Orders placed before customer SignupDate',
       SUM(CASE WHEN CAST(o.OrderTimestamp AS DATE) < c.SignupDate THEN 1 ELSE 0 END),
       COUNT(*),
       CASE WHEN SUM(CASE WHEN CAST(o.OrderTimestamp AS DATE) < c.SignupDate THEN 1 ELSE 0 END) = 0 THEN 'OK' ELSE 'HIGH' END,
       'Do not use SignupDate as the cohort anchor or for tenure. Use the customer''s first order date instead; raise with the source-system owner.'
FROM dbo.fact_orders o
JOIN dbo.dim_customers c ON c.CustomerID = o.CustomerID;

-- 3b. Returns recorded before the order was placed (impossible).
INSERT INTO #dq_results (Area, CheckName, RowsAffected, RowsChecked, Severity, Recommendation)
SELECT 'Timeline', 'Returns dated before their order',
       SUM(CASE WHEN r.ReturnTimestamp < o.OrderTimestamp THEN 1 ELSE 0 END),
       COUNT(*),
       CASE WHEN SUM(CASE WHEN r.ReturnTimestamp < o.OrderTimestamp THEN 1 ELSE 0 END) = 0 THEN 'OK' ELSE 'HIGH' END,
       'Exclude from return-lag analysis; investigate timestamp source.'
FROM dbo.fact_returns r
JOIN dbo.fact_orders  o ON o.OrderID = r.OrderID;

-- 3c. Events dated in the future relative to when the script runs.
INSERT INTO #dq_results (Area, CheckName, RowsAffected, RowsChecked, Severity, Recommendation)
SELECT 'Timeline', f.CheckName, f.Affected, f.Checked,
       CASE WHEN f.Affected = 0 THEN 'OK' ELSE 'HIGH' END,
       'Future-dated rows are usually test data or timezone errors. Exclude from trends.'
FROM (
    SELECT 'Orders dated in the future' AS CheckName,
           SUM(CASE WHEN OrderTimestamp > SYSDATETIME() THEN 1 ELSE 0 END) AS Affected, COUNT(*) AS Checked
    FROM dbo.fact_orders
    UNION ALL
    SELECT 'Returns dated in the future',
           SUM(CASE WHEN ReturnTimestamp > SYSDATETIME() THEN 1 ELSE 0 END), COUNT(*)
    FROM dbo.fact_returns
    UNION ALL
    SELECT 'Customers with SignupDate in the future',
           SUM(CASE WHEN SignupDate > CAST(SYSDATETIME() AS DATE) THEN 1 ELSE 0 END), COUNT(*)
    FROM dbo.dim_customers
) AS f;

-- 3d. Returns logged after the order data ends. Not wrong (returns lag the
-- sale), but it means the return window for late orders is still open, which
-- understates return rates for the most recent months.
INSERT INTO #dq_results (Area, CheckName, RowsAffected, RowsChecked, Severity, Recommendation)
SELECT 'Timeline', 'Returns dated after the last order in the dataset (info)',
       SUM(CASE WHEN r.ReturnTimestamp > x.LastOrder THEN 1 ELSE 0 END),
       COUNT(*),
       CASE WHEN SUM(CASE WHEN r.ReturnTimestamp > x.LastOrder THEN 1 ELSE 0 END) = 0 THEN 'OK' ELSE 'LOW' END,
       'Expected. Treat return rates for the final 1-2 months as incomplete (return window still open).'
FROM dbo.fact_returns r
CROSS JOIN (SELECT MAX(OrderTimestamp) AS LastOrder FROM dbo.fact_orders) x;

-- =========================================
-- 4. NEGATIVE OR ZERO VALUES
-- =========================================
-- CHECK constraints already block negatives when trusted (see 03). Re-tested
-- here on the data itself, plus zero values that pass the constraints but are
-- commercially suspicious.

INSERT INTO #dq_results (Area, CheckName, RowsAffected, RowsChecked, Severity, Recommendation)
SELECT 'Negative / zero', n.CheckName, n.Affected, n.Checked,
       CASE WHEN n.Affected = 0 THEN 'OK' ELSE n.Sev END,
       n.Rec
FROM (
    SELECT 'Products with negative cost / price / stock' AS CheckName,
           SUM(CASE WHEN UnitCost < 0 OR UnitPrice < 0 OR StockOnHand < 0 OR ReorderPoint < 0 THEN 1 ELSE 0 END) AS Affected,
           COUNT(*) AS Checked, 'HIGH' AS Sev,
           'Should be impossible with trusted constraints; correct at source.' AS Rec
    FROM dbo.dim_products
    UNION ALL
    SELECT 'Products with zero UnitPrice or UnitCost',
           SUM(CASE WHEN UnitCost = 0 OR UnitPrice = 0 THEN 1 ELSE 0 END), COUNT(*), 'MEDIUM',
           'Zero cost inflates margin %; zero price may be a free sample. Confirm with product team.'
    FROM dbo.dim_products
    UNION ALL
    SELECT 'Order lines with negative values',
           SUM(CASE WHEN Quantity <= 0 OR UnitPrice < 0 OR UnitCost < 0 OR DiscountAmount < 0 OR LineTotal < 0 THEN 1 ELSE 0 END),
           COUNT(*), 'HIGH',
           'Should be impossible with trusted constraints; correct at source.'
    FROM dbo.fact_order_items
    UNION ALL
    SELECT 'Order lines sold below cost (negative ItemNetMargin)',
           SUM(CASE WHEN ItemNetMargin < 0 THEN 1 ELSE 0 END), COUNT(*), 'MEDIUM',
           'Legitimate for clearance / loss leaders, but review discount policy.'
    FROM dbo.fact_order_items
    UNION ALL
    SELECT 'Non-cancelled orders with zero FreightCost',
           SUM(CASE WHEN FreightCost = 0 AND OrderStatus <> 'Cancelled' THEN 1 ELSE 0 END), COUNT(*), 'LOW',
           'Could be free-shipping promotions; confirm before modelling freight cost.'
    FROM dbo.fact_orders
    UNION ALL
    SELECT 'Payments / refunds with negative amounts',
           (SELECT COUNT(*) FROM dbo.fact_payments WHERE ProcessingFee < 0 OR TotalAmountPaid < 0)
         + (SELECT COUNT(*) FROM dbo.fact_returns  WHERE RefundAmount < 0 OR RestockingFee < 0),
           (SELECT COUNT(*) FROM dbo.fact_payments) + (SELECT COUNT(*) FROM dbo.fact_returns),
           'HIGH', 'Should be impossible with trusted constraints; correct at source.'
) AS n;

-- =========================================
-- 5. DISCOUNTS AND PRICING
-- =========================================

-- 5a. Discount rate outside the standard tiers. The source uses fixed tiers
-- (0%, 5%, 10%, 15%, 20%); anything else suggests a manual override.
INSERT INTO #dq_results (Area, CheckName, RowsAffected, RowsChecked, Severity, Recommendation)
SELECT 'Discounts', 'DiscountRate outside standard tiers (0/5/10/15/20%)',
       SUM(CASE WHEN DiscountRate NOT IN (0.00, 0.05, 0.10, 0.15, 0.20) THEN 1 ELSE 0 END),
       COUNT(*),
       CASE WHEN SUM(CASE WHEN DiscountRate NOT IN (0.00, 0.05, 0.10, 0.15, 0.20) THEN 1 ELSE 0 END) = 0 THEN 'OK' ELSE 'MEDIUM' END,
       'Investigate manual overrides; keep the rows.'
FROM dbo.fact_order_items;

-- 5b. Discount rate above 50%: allowed by the constraint (0..1) but unusual.
INSERT INTO #dq_results (Area, CheckName, RowsAffected, RowsChecked, Severity, Recommendation)
SELECT 'Discounts', 'DiscountRate above 50%',
       SUM(CASE WHEN DiscountRate > 0.50 THEN 1 ELSE 0 END),
       COUNT(*),
       CASE WHEN SUM(CASE WHEN DiscountRate > 0.50 THEN 1 ELSE 0 END) = 0 THEN 'OK' ELSE 'MEDIUM' END,
       'Validate against promotion calendar.'
FROM dbo.fact_order_items;

-- 5c. Selling price differs from current list price. Expected over time
-- (price changes), so informational, but it tells us whether dim_products
-- prices can stand in for historical prices. Answer: always use line price.
INSERT INTO #dq_results (Area, CheckName, RowsAffected, RowsChecked, Severity, Recommendation)
SELECT 'Discounts', 'Line UnitPrice differs from product list price (info)',
       SUM(CASE WHEN i.UnitPrice <> p.UnitPrice THEN 1 ELSE 0 END),
       COUNT(*),
       CASE WHEN SUM(CASE WHEN i.UnitPrice <> p.UnitPrice THEN 1 ELSE 0 END) = 0 THEN 'OK' ELSE 'LOW' END,
       'Always use fact_order_items prices for revenue; dim_products is the current price list only.'
FROM dbo.fact_order_items i
JOIN dbo.dim_products     p ON p.ProductID = i.ProductID;

-- =========================================
-- 6. DERIVED-COLUMN RECONCILIATION
-- =========================================
-- The source ships pre-computed measures. If they disagree with their own
-- formula, every revenue and margin KPI inherits the error.
--   DiscountAmount = Quantity * UnitPrice * DiscountRate
--   LineTotal      = Quantity * UnitPrice - DiscountAmount
--   ItemNetMargin  = LineTotal - Quantity * UnitCost

INSERT INTO #dq_results (Area, CheckName, RowsAffected, RowsChecked, Severity, Recommendation)
SELECT 'Reconciliation', r.CheckName, r.Affected, r.Checked,
       CASE WHEN r.Affected = 0 THEN 'OK' ELSE 'HIGH' END,
       'If non-zero, recompute the measure from its components rather than trusting the stored value.'
FROM (
    SELECT 'DiscountAmount <> Qty * UnitPrice * DiscountRate' AS CheckName,
           SUM(CASE WHEN ABS(DiscountAmount - Quantity * UnitPrice * DiscountRate) > 0.01 THEN 1 ELSE 0 END) AS Affected,
           COUNT(*) AS Checked
    FROM dbo.fact_order_items
    UNION ALL
    SELECT 'LineTotal <> Qty * UnitPrice - DiscountAmount',
           SUM(CASE WHEN ABS(LineTotal - (Quantity * UnitPrice - DiscountAmount)) > 0.01 THEN 1 ELSE 0 END),
           COUNT(*)
    FROM dbo.fact_order_items
    UNION ALL
    SELECT 'ItemNetMargin <> LineTotal - Qty * UnitCost',
           SUM(CASE WHEN ABS(ItemNetMargin - (LineTotal - Quantity * UnitCost)) > 0.01 THEN 1 ELSE 0 END),
           COUNT(*)
    FROM dbo.fact_order_items
) AS r;

-- =========================================
-- 7. CROSS-TABLE AMOUNT CONSISTENCY
-- =========================================
-- Each table is aggregated to ORDER grain first, then compared. Joining raw
-- lines to payments/returns would repeat the order-level amounts once per
-- line and give wrong answers.

IF OBJECT_ID('tempdb..#order_value') IS NOT NULL DROP TABLE #order_value;

SELECT
    o.OrderID,
    o.OrderStatus,
    o.FreightCost,
    li.ItemsNet,
    p.PaymentStatus,
    p.TotalAmountPaid,
    p.ProcessingFee,
    ISNULL(rt.TotalRefund, 0) AS TotalRefund,
    ISNULL(rt.ReturnCount, 0) AS ReturnCount
INTO #order_value
FROM dbo.fact_orders o
JOIN (
    SELECT OrderID, SUM(LineTotal) AS ItemsNet
    FROM dbo.fact_order_items
    GROUP BY OrderID
) li ON li.OrderID = o.OrderID
LEFT JOIN dbo.fact_payments p ON p.OrderID = o.OrderID
LEFT JOIN (
    SELECT OrderID, SUM(RefundAmount) AS TotalRefund, COUNT(*) AS ReturnCount
    FROM dbo.fact_returns
    GROUP BY OrderID
) rt ON rt.OrderID = o.OrderID;

-- 7a. Amount paid vs order item total. Profiling showed TotalAmountPaid
-- equals SUM(LineTotal): freight and processing fee are NOT charged to the
-- customer, they are business costs. This check guards that assumption.
INSERT INTO #dq_results (Area, CheckName, RowsAffected, RowsChecked, Severity, Recommendation)
SELECT 'Consistency', 'TotalAmountPaid <> SUM(LineTotal) for the order',
       SUM(CASE WHEN ABS(TotalAmountPaid - ItemsNet) > 0.01 THEN 1 ELSE 0 END),
       COUNT(*),
       CASE WHEN SUM(CASE WHEN ABS(TotalAmountPaid - ItemsNet) > 0.01 THEN 1 ELSE 0 END) = 0 THEN 'OK' ELSE 'HIGH' END,
       'If non-zero, the revenue definition in 05 (SUM(LineTotal)) no longer equals cash collected; revisit it.'
FROM #order_value
WHERE TotalAmountPaid IS NOT NULL;

-- 7b. Order status and payment status disagree.
-- Expected pairing: Cancelled <-> 'Voided / Refunded', everything else <-> 'Success'.
INSERT INTO #dq_results (Area, CheckName, RowsAffected, RowsChecked, Severity, Recommendation)
SELECT 'Consistency', 'Order status and payment status disagree',
       SUM(CASE WHEN (OrderStatus =  'Cancelled' AND PaymentStatus <> 'Voided / Refunded')
                  OR (OrderStatus <> 'Cancelled' AND PaymentStatus <> 'Success') THEN 1 ELSE 0 END),
       COUNT(*),
       CASE WHEN SUM(CASE WHEN (OrderStatus =  'Cancelled' AND PaymentStatus <> 'Voided / Refunded')
                            OR (OrderStatus <> 'Cancelled' AND PaymentStatus <> 'Success') THEN 1 ELSE 0 END) = 0
            THEN 'OK' ELSE 'HIGH' END,
       'Revenue rule uses OrderStatus; mismatches would make cash and sales disagree.'
FROM #order_value
WHERE PaymentStatus IS NOT NULL;

-- 7c. Cancelled orders that still carry freight or fees (cost with no sale).
INSERT INTO #dq_results (Area, CheckName, RowsAffected, RowsChecked, Severity, Recommendation)
SELECT 'Consistency', 'Cancelled orders with FreightCost or ProcessingFee > 0',
       SUM(CASE WHEN FreightCost > 0 OR ProcessingFee > 0 THEN 1 ELSE 0 END),
       COUNT(*),
       CASE WHEN SUM(CASE WHEN FreightCost > 0 OR ProcessingFee > 0 THEN 1 ELSE 0 END) = 0 THEN 'OK' ELSE 'MEDIUM' END,
       'Keep as a real cost of cancellations in profitability analysis.'
FROM #order_value
WHERE OrderStatus = 'Cancelled';

-- 7d. Returns against orders that were never delivered.
INSERT INTO #dq_results (Area, CheckName, RowsAffected, RowsChecked, Severity, Recommendation)
SELECT 'Consistency', 'Returns on orders not in Delivered status',
       SUM(CASE WHEN o.OrderStatus <> 'Delivered' THEN 1 ELSE 0 END),
       COUNT(*),
       CASE WHEN SUM(CASE WHEN o.OrderStatus <> 'Delivered' THEN 1 ELSE 0 END) = 0 THEN 'OK' ELSE 'HIGH' END,
       'Return-rate denominator in 08 is Delivered orders; returns on other statuses break that rule.'
FROM dbo.fact_returns r
JOIN dbo.fact_orders  o ON o.OrderID = r.OrderID;

-- 7e. Single return refunding more than the whole order.
INSERT INTO #dq_results (Area, CheckName, RowsAffected, RowsChecked, Severity, Recommendation)
SELECT 'Consistency', 'Single return with RefundAmount > order item total',
       SUM(CASE WHEN r.RefundAmount > ov.ItemsNet + 0.01 THEN 1 ELSE 0 END),
       COUNT(*),
       CASE WHEN SUM(CASE WHEN r.RefundAmount > ov.ItemsNet + 0.01 THEN 1 ELSE 0 END) = 0 THEN 'OK' ELSE 'HIGH' END,
       'Cap refunds at order value in net-revenue calculations and raise with Finance.'
FROM dbo.fact_returns r
JOIN #order_value     ov ON ov.OrderID = r.OrderID;

-- 7f. Several returns on one order whose refunds ADD UP to more than the
-- order value. Each return alone looks fine; together they over-refund.
INSERT INTO #dq_results (Area, CheckName, RowsAffected, RowsChecked, Severity, Recommendation)
SELECT 'Consistency', 'Orders whose total refunds exceed order item total',
       SUM(CASE WHEN TotalRefund > ItemsNet + 0.01 THEN 1 ELSE 0 END),
       SUM(CASE WHEN ReturnCount > 0 THEN 1 ELSE 0 END),
       CASE WHEN SUM(CASE WHEN TotalRefund > ItemsNet + 0.01 THEN 1 ELSE 0 END) = 0 THEN 'OK' ELSE 'HIGH' END,
       'Do NOT subtract raw refunds from sales: net revenue would be understated. Report refunds separately, or cap at order value (see 08).'
FROM #order_value;

-- 7g. Restocking fee larger than the refund it is charged against.
INSERT INTO #dq_results (Area, CheckName, RowsAffected, RowsChecked, Severity, Recommendation)
SELECT 'Consistency', 'RestockingFee greater than RefundAmount',
       SUM(CASE WHEN RestockingFee > RefundAmount THEN 1 ELSE 0 END),
       COUNT(*),
       CASE WHEN SUM(CASE WHEN RestockingFee > RefundAmount THEN 1 ELSE 0 END) = 0 THEN 'OK' ELSE 'MEDIUM' END,
       'Investigate fee calculation.'
FROM dbo.fact_returns;

-- =========================================
-- 8. DUPLICATE BUSINESS RECORDS AND OUTLIERS
-- =========================================
-- Unique IDs do not prevent the same real-world event being recorded twice
-- under two IDs. These look for business-level duplicates.

INSERT INTO #dq_results (Area, CheckName, RowsAffected, RowsChecked, Severity, Recommendation)
SELECT 'Duplicates', b.CheckName, b.Affected, b.Checked,
       CASE WHEN b.Affected = 0 THEN 'OK' ELSE 'MEDIUM' END,
       'Review sample; merge only with business confirmation.'
FROM (
    SELECT 'Customers sharing the same CustomerName' AS CheckName,
           (SELECT ISNULL(SUM(n), 0) FROM (SELECT COUNT(*) n FROM dbo.dim_customers GROUP BY CustomerName HAVING COUNT(*) > 1) x) AS Affected,
           (SELECT COUNT(*) FROM dbo.dim_customers) AS Checked
    UNION ALL
    SELECT 'Products sharing the same ProductName',
           (SELECT ISNULL(SUM(n), 0) FROM (SELECT COUNT(*) n FROM dbo.dim_products GROUP BY ProductName HAVING COUNT(*) > 1) x),
           (SELECT COUNT(*) FROM dbo.dim_products)
    UNION ALL
    SELECT 'Orders: same customer, same timestamp (possible double submit)',
           (SELECT ISNULL(SUM(n), 0) FROM (SELECT COUNT(*) n FROM dbo.fact_orders GROUP BY CustomerID, OrderTimestamp HAVING COUNT(*) > 1) x),
           (SELECT COUNT(*) FROM dbo.fact_orders)
    UNION ALL
    SELECT 'Order lines: same product repeated within one order',
           (SELECT ISNULL(SUM(n), 0) FROM (SELECT COUNT(*) n FROM dbo.fact_order_items GROUP BY OrderID, ProductID HAVING COUNT(*) > 1) x),
           (SELECT COUNT(*) FROM dbo.fact_order_items)
) AS b;

-- 8b. Statistical outliers: order value more than 3 standard deviations above
-- the mean. Not errors by default (B2B or bulk orders exist) but they can
-- dominate averages, so analyses should also report medians.
INSERT INTO #dq_results (Area, CheckName, RowsAffected, RowsChecked, Severity, Recommendation)
SELECT 'Outliers', 'Orders with value > mean + 3 std dev',
       SUM(CASE WHEN ov.ItemsNet > s.MeanVal + 3 * s.StdVal THEN 1 ELSE 0 END),
       COUNT(*),
       CASE WHEN SUM(CASE WHEN ov.ItemsNet > s.MeanVal + 3 * s.StdVal THEN 1 ELSE 0 END) = 0 THEN 'OK' ELSE 'LOW' END,
       'Keep. Report median alongside average order value.'
FROM #order_value ov
CROSS JOIN (SELECT AVG(ItemsNet) AS MeanVal, STDEV(ItemsNet) AS StdVal FROM #order_value) s;

-- 8c. Unusually high processing fee rate (fee / amount paid). The typical
-- rate is ~2.4% plus a fixed component, so small orders show higher rates.
INSERT INTO #dq_results (Area, CheckName, RowsAffected, RowsChecked, Severity, Recommendation)
SELECT 'Outliers', 'Successful payments with fee rate above 5%',
       SUM(CASE WHEN ProcessingFee > 0.05 * TotalAmountPaid THEN 1 ELSE 0 END),
       COUNT(*),
       CASE WHEN SUM(CASE WHEN ProcessingFee > 0.05 * TotalAmountPaid THEN 1 ELSE 0 END) = 0 THEN 'OK' ELSE 'LOW' END,
       'Mostly small orders where a fixed fee dominates. Consider a minimum order value.'
FROM dbo.fact_payments
WHERE PaymentStatus = 'Success' AND TotalAmountPaid > 0;

-- 8d. Inventory signals (informational; feeds 07).
INSERT INTO #dq_results (Area, CheckName, RowsAffected, RowsChecked, Severity, Recommendation)
SELECT 'Inventory', 'Products at or below ReorderPoint (info)',
       SUM(CASE WHEN StockOnHand <= ReorderPoint THEN 1 ELSE 0 END),
       COUNT(*),
       CASE WHEN SUM(CASE WHEN StockOnHand <= ReorderPoint THEN 1 ELSE 0 END) = 0 THEN 'OK' ELSE 'LOW' END,
       'Snapshot only; no stock-movement history, so historical stock-outs cannot be measured.'
FROM dbo.dim_products;

-- =========================================
-- 9. DATA QUALITY REPORT
-- =========================================

-- 9a. Full report, most severe first.
SELECT
    CheckNo,
    Severity,
    Area,
    CheckName,
    RowsAffected,
    RowsChecked,
    CAST(100.0 * RowsAffected / NULLIF(RowsChecked, 0) AS DECIMAL(6,2)) AS PctAffected,
    Recommendation
FROM #dq_results
ORDER BY
    CASE Severity WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 3 ELSE 4 END,
    CheckNo;

-- 9b. Scorecard.
SELECT Severity, COUNT(*) AS Checks
FROM #dq_results
GROUP BY Severity
ORDER BY CASE Severity WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 3 ELSE 4 END;

-- =========================================
-- 10. SAMPLE ROWS FOR INVESTIGATION
-- =========================================
-- Evidence for the HIGH findings, small enough to paste into a ticket.

-- 10a. Orders before signup: how far before?
SELECT TOP (20)
    o.OrderID, o.CustomerID, c.SignupDate,
    CAST(o.OrderTimestamp AS DATE)                         AS OrderDate,
    DATEDIFF(DAY, CAST(o.OrderTimestamp AS DATE), c.SignupDate) AS DaysBeforeSignup
FROM dbo.fact_orders o
JOIN dbo.dim_customers c ON c.CustomerID = o.CustomerID
WHERE CAST(o.OrderTimestamp AS DATE) < c.SignupDate
ORDER BY DaysBeforeSignup DESC;

-- 10b. Orders refunded more than they were worth.
SELECT TOP (20)
    OrderID, ItemsNet, TotalAmountPaid, ReturnCount, TotalRefund,
    TotalRefund - ItemsNet AS OverRefund
FROM #order_value
WHERE TotalRefund > ItemsNet + 0.01
ORDER BY OverRefund DESC;

DROP TABLE #order_value;
DROP TABLE #dq_results;
GO
