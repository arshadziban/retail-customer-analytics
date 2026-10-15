/*
Script  : 10_create_powerbi_model_views.sql
Purpose : Star schema views for Power BI. Load only the six pbi_ views.
          Relationships (one-to-many, dim -> fact):
            pbi_dim_date[Date]           -> fact_orders[OrderDate], fact_order_lines[OrderDate], fact_returns[ReturnDate]
            pbi_dim_customer[CustomerID] -> all three facts
            pbi_dim_product[ProductID]   -> pbi_fact_order_lines
*/

USE RetailAnalytics;
GO

-- 1. pbi_dim_date
CREATE OR ALTER VIEW dbo.pbi_dim_date
AS
WITH bounds AS (
    SELECT
        DATEFROMPARTS(YEAR(MIN(OrderTimestamp)), 1, 1)  AS StartDate,
        DATEFROMPARTS(YEAR((SELECT MAX(ReturnTimestamp) FROM dbo.fact_returns)), 12, 31) AS EndDate
    FROM dbo.fact_orders
),
digits AS (
    SELECT d FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) AS v(d)
),
tally AS (
    SELECT a.d + 10 * b.d + 100 * c.d + 1000 * e.d AS n
    FROM digits a CROSS JOIN digits b CROSS JOIN digits c CROSS JOIN digits e
),
days AS (
    SELECT DATEADD(DAY, t.n, b.StartDate) AS [Date]
    FROM tally t
    CROSS JOIN bounds b
    WHERE DATEADD(DAY, t.n, b.StartDate) <= b.EndDate
)
SELECT
    [Date],
    YEAR([Date])                                        AS [Year],
    DATEPART(QUARTER, [Date])                           AS QuarterNo,
    CONCAT('Q', DATEPART(QUARTER, [Date]))              AS [Quarter],
    CONCAT(YEAR([Date]), '-Q', DATEPART(QUARTER, [Date])) AS YearQuarter,
    MONTH([Date])                                       AS MonthNo,
    DATENAME(MONTH, [Date])                             AS MonthName,
    LEFT(DATENAME(MONTH, [Date]), 3)                    AS MonthShort,
    DATEFROMPARTS(YEAR([Date]), MONTH([Date]), 1)       AS MonthStart,
    FORMAT([Date], 'yyyy-MM')                           AS YearMonth,
    YEAR([Date]) * 100 + MONTH([Date])                  AS YearMonthSort,   -- sort key for YearMonth
    DATENAME(WEEKDAY, [Date])                           AS DayName,
    (DATEDIFF(DAY, '19000101', [Date]) % 7) + 1         AS DayOfWeekNo,     -- 1 = Monday, independent of DATEFIRST
    CASE WHEN (DATEDIFF(DAY, '19000101', [Date]) % 7) >= 5 THEN 1 ELSE 0 END AS IsWeekend
FROM days;
GO

-- 2. pbi_dim_customer
CREATE OR ALTER VIEW dbo.pbi_dim_customer
AS
SELECT
    c.CustomerID,
    c.CustomerName,
    c.Region,
    c.AcquisitionChannel,
    c.LoyaltyTier,
    CASE c.LoyaltyTier
        WHEN 'Platinum' THEN 1 WHEN 'Gold' THEN 2
        WHEN 'Silver'   THEN 3 WHEN 'Standard' THEN 4 ELSE 5
    END                                          AS LoyaltyTierSortOrder,
    c.SignupDate,
    r.FirstOrderDate,
    r.LastOrderDate,
    r.RecencyDays,
    ISNULL(r.Frequency, 0)                       AS Frequency,
    ISNULL(r.Monetary, 0)                        AS Monetary,
    r.R_Score,
    r.F_Score,
    r.M_Score,
    r.RFM_Code,
    ISNULL(r.Segment, 'No Purchase')             AS Segment,
    ISNULL(r.SegmentSortOrder, 7)                AS SegmentSortOrder,
    CASE WHEN r.CustomerID IS NULL THEN 0 ELSE 1 END AS HasPurchased
FROM dbo.dim_customers c
LEFT JOIN dbo.vw_customer_rfm r ON r.CustomerID = c.CustomerID;
GO

-- 3. pbi_dim_product
CREATE OR ALTER VIEW dbo.pbi_dim_product
AS
SELECT
    ProductID,
    ProductName,
    Category,
    SKU,
    ListPrice,
    ListCost,
    CAST(100.0 * (ListPrice - ListCost) / NULLIF(ListPrice, 0) AS DECIMAL(5,2)) AS ListMarginPct,
    CASE
        WHEN ListPrice <  25 THEN '1. < 25'
        WHEN ListPrice < 100 THEN '2. 25-99'
        WHEN ListPrice < 250 THEN '3. 100-249'
        WHEN ListPrice < 500 THEN '4. 250-499'
        ELSE                      '5. 500+'
    END                                          AS PriceBand,
    StockOnHand,
    ReorderPoint,
    StockValueAtCost,
    Units90d,
    DaysOfCover,
    StockStatus
FROM dbo.vw_product_profitability;
GO

-- 4. pbi_fact_orders  (one row per order)
CREATE OR ALTER VIEW dbo.pbi_fact_orders
AS
SELECT
    OrderID,
    CustomerID,
    OrderDate,                                   -- relationship key to pbi_dim_date
    OrderTimestamp,                              -- full date and time, as in the source
    DATEPART(HOUR, OrderTimestamp)               AS OrderHour,
    OrderStatus,
    IsQualifying,
    IsDelivered,
    ShippingMethod,
    PaymentID,
    PaymentMethod,
    PaymentStatus,
    LineCount,
    Units,
    GrossSales,
    Discounts,
    NetSales,
    ItemMargin,
    FreightCost,
    ProcessingFee,
    Contribution,
    AmountPaid,
    HasReturn,
    ReturnRecords,
    RefundRaw,
    RefundCapped,
    RestockingFees
FROM dbo.vw_order_summary;
GO

-- 5. pbi_fact_order_lines  (one row per order line)
CREATE OR ALTER VIEW dbo.pbi_fact_order_lines
AS
SELECT
    i.OrderItemID,
    i.OrderID,
    i.ProductID,
    o.CustomerID,
    CAST(o.OrderTimestamp AS DATE)                           AS OrderDate,
    o.OrderStatus,
    CASE WHEN o.OrderStatus <> 'Cancelled' THEN 1 ELSE 0 END AS IsQualifying,
    i.Quantity,
    i.UnitPrice,
    i.UnitCost,
    i.DiscountRate,
    CONCAT(CAST(i.DiscountRate * 100 AS INT), '%')           AS DiscountTier,
    i.Quantity * i.UnitPrice                                 AS GrossSales,
    i.DiscountAmount,
    i.LineTotal                                              AS NetSales,
    i.ItemNetMargin                                          AS ItemMargin
FROM dbo.fact_order_items i
JOIN dbo.fact_orders      o ON o.OrderID = i.OrderID;
GO

-- 6. pbi_fact_returns  (one row per return record)
CREATE OR ALTER VIEW dbo.pbi_fact_returns
AS
WITH order_refund AS (
    SELECT OrderID, CustomerID, OrderTimestamp, RefundRaw, RefundCapped
    FROM dbo.vw_order_summary
    WHERE HasReturn = 1
)
SELECT
    r.ReturnID,
    r.OrderID,
    o.CustomerID,
    CAST(r.ReturnTimestamp AS DATE)                                      AS ReturnDate,   -- relationship key
    r.ReturnTimestamp,                                                                    -- full date and time
    CAST(o.OrderTimestamp AS DATE)                                       AS OrderDate,
    DATEDIFF(DAY, o.OrderTimestamp, r.ReturnTimestamp)                   AS DaysToReturn,
    r.ReturnReason,
    CASE
        WHEN r.ReturnReason IN ('Defective or Damaged Item', 'Missing Parts or Accessories') THEN 'Product / supplier quality'
        WHEN r.ReturnReason IN ('Item Not as Described', 'Incorrect Size or Color')        THEN 'Listing / fulfilment accuracy'
        WHEN r.ReturnReason = 'Late Carrier Delivery'                                      THEN 'Logistics'
        WHEN r.ReturnReason = 'Customer Remorse / Cancelled Mind'                          THEN 'Customer choice'
        ELSE 'Other'
    END                                                                  AS ReasonOwner,
    r.ReturnStatus,
    r.RefundAmount                                                       AS RefundRaw,
    CAST(r.RefundAmount * o.RefundCapped / NULLIF(o.RefundRaw, 0) AS DECIMAL(14,2)) AS RefundCapped,
    r.RestockingFee
FROM dbo.fact_returns r
JOIN order_refund     o ON o.OrderID = r.OrderID;
GO

-- 7. VERIFY THE MODEL WILL CONNECT
SELECT 'pbi_fact_orders.CustomerID -> pbi_dim_customer' AS Relationship,
       (SELECT COUNT(*) FROM dbo.pbi_fact_orders f
         WHERE NOT EXISTS (SELECT 1 FROM dbo.pbi_dim_customer d WHERE d.CustomerID = f.CustomerID)) AS Orphans
UNION ALL
SELECT 'pbi_fact_order_lines.CustomerID -> pbi_dim_customer',
       (SELECT COUNT(*) FROM dbo.pbi_fact_order_lines f
         WHERE NOT EXISTS (SELECT 1 FROM dbo.pbi_dim_customer d WHERE d.CustomerID = f.CustomerID))
UNION ALL
SELECT 'pbi_fact_returns.CustomerID -> pbi_dim_customer',
       (SELECT COUNT(*) FROM dbo.pbi_fact_returns f
         WHERE NOT EXISTS (SELECT 1 FROM dbo.pbi_dim_customer d WHERE d.CustomerID = f.CustomerID))
UNION ALL
SELECT 'pbi_fact_order_lines.ProductID -> pbi_dim_product',
       (SELECT COUNT(*) FROM dbo.pbi_fact_order_lines f
         WHERE NOT EXISTS (SELECT 1 FROM dbo.pbi_dim_product d WHERE d.ProductID = f.ProductID))
UNION ALL
SELECT 'pbi_fact_orders.OrderDate -> pbi_dim_date',
       (SELECT COUNT(*) FROM dbo.pbi_fact_orders f
         WHERE NOT EXISTS (SELECT 1 FROM dbo.pbi_dim_date d WHERE d.[Date] = f.OrderDate))
UNION ALL
SELECT 'pbi_fact_order_lines.OrderDate -> pbi_dim_date',
       (SELECT COUNT(*) FROM dbo.pbi_fact_order_lines f
         WHERE NOT EXISTS (SELECT 1 FROM dbo.pbi_dim_date d WHERE d.[Date] = f.OrderDate))
UNION ALL
SELECT 'pbi_fact_returns.ReturnDate -> pbi_dim_date',
       (SELECT COUNT(*) FROM dbo.pbi_fact_returns f
         WHERE NOT EXISTS (SELECT 1 FROM dbo.pbi_dim_date d WHERE d.[Date] = f.ReturnDate));

-- 8. COMPLETENESS: ALL SOURCE DATA REACHES THE MODEL
SELECT CheckName, SourceValue, ModelValue, ModelValue - SourceValue AS Difference
FROM (
    SELECT 'Rows: customers' AS CheckName,
           CAST((SELECT COUNT(*) FROM dbo.dim_customers) AS DECIMAL(18,2)) AS SourceValue,
           CAST((SELECT COUNT(*) FROM dbo.pbi_dim_customer) AS DECIMAL(18,2)) AS ModelValue
    UNION ALL SELECT 'Rows: products',
           (SELECT COUNT(*) FROM dbo.dim_products), (SELECT COUNT(*) FROM dbo.pbi_dim_product)
    UNION ALL SELECT 'Rows: orders',
           (SELECT COUNT(*) FROM dbo.fact_orders), (SELECT COUNT(*) FROM dbo.pbi_fact_orders)
    UNION ALL SELECT 'Rows: order lines',
           (SELECT COUNT(*) FROM dbo.fact_order_items), (SELECT COUNT(*) FROM dbo.pbi_fact_order_lines)
    UNION ALL SELECT 'Rows: payments',
           (SELECT COUNT(*) FROM dbo.fact_payments), (SELECT COUNT(PaymentID) FROM dbo.pbi_fact_orders)
    UNION ALL SELECT 'Rows: returns',
           (SELECT COUNT(*) FROM dbo.fact_returns), (SELECT COUNT(*) FROM dbo.pbi_fact_returns)
    UNION ALL SELECT 'Sum: Quantity',
           (SELECT SUM(Quantity) FROM dbo.fact_order_items), (SELECT SUM(Quantity) FROM dbo.pbi_fact_order_lines)
    UNION ALL SELECT 'Sum: LineTotal',
           (SELECT SUM(LineTotal) FROM dbo.fact_order_items), (SELECT SUM(NetSales) FROM dbo.pbi_fact_order_lines)
    UNION ALL SELECT 'Sum: ItemNetMargin',
           (SELECT SUM(ItemNetMargin) FROM dbo.fact_order_items), (SELECT SUM(ItemMargin) FROM dbo.pbi_fact_order_lines)
    UNION ALL SELECT 'Sum: DiscountAmount',
           (SELECT SUM(DiscountAmount) FROM dbo.fact_order_items), (SELECT SUM(DiscountAmount) FROM dbo.pbi_fact_order_lines)
    UNION ALL SELECT 'Sum: FreightCost',
           (SELECT SUM(FreightCost) FROM dbo.fact_orders), (SELECT SUM(FreightCost) FROM dbo.pbi_fact_orders)
    UNION ALL SELECT 'Sum: TotalAmountPaid',
           (SELECT SUM(TotalAmountPaid) FROM dbo.fact_payments), (SELECT SUM(AmountPaid) FROM dbo.pbi_fact_orders)
    UNION ALL SELECT 'Sum: ProcessingFee',
           (SELECT SUM(ProcessingFee) FROM dbo.fact_payments), (SELECT SUM(ProcessingFee) FROM dbo.pbi_fact_orders)
    UNION ALL SELECT 'Sum: RefundAmount',
           (SELECT SUM(RefundAmount) FROM dbo.fact_returns), (SELECT SUM(RefundRaw) FROM dbo.pbi_fact_returns)
    UNION ALL SELECT 'Sum: RestockingFee',
           (SELECT SUM(RestockingFee) FROM dbo.fact_returns), (SELECT SUM(RestockingFee) FROM dbo.pbi_fact_returns)
    UNION ALL SELECT 'Sum: StockOnHand',
           (SELECT SUM(StockOnHand) FROM dbo.dim_products), (SELECT SUM(StockOnHand) FROM dbo.pbi_dim_product)
) AS c;

SELECT
    (SELECT COUNT(*) FROM dbo.pbi_dim_date)          AS DimDateRows,
    (SELECT COUNT(*) FROM dbo.pbi_dim_customer)      AS DimCustomerRows,
    (SELECT COUNT(*) FROM dbo.pbi_dim_product)       AS DimProductRows,
    (SELECT COUNT(*) FROM dbo.pbi_fact_orders)       AS FactOrderRows,
    (SELECT COUNT(*) FROM dbo.pbi_fact_order_lines)  AS FactLineRows,
    (SELECT COUNT(*) FROM dbo.pbi_fact_returns)      AS FactReturnRows,
    (SELECT SUM(NetSales) FROM dbo.pbi_fact_orders      WHERE IsQualifying = 1) AS NetSalesFromOrders,
    (SELECT SUM(NetSales) FROM dbo.pbi_fact_order_lines WHERE IsQualifying = 1) AS NetSalesFromLines;
GO
