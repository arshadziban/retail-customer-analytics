/*
===============================================================================
Project     : Enterprise Retail Analytics
Database    : RetailAnalytics
DBMS        : Microsoft SQL Server
Script      : 03_validate_keys_and_rows.sql
Purpose     : Structural validation of the import. Answers one question:
              "Did the data land completely and are the relationships intact?"
Run after   : 02_import_csv_data.sql
Run before  : 04_data_quality_checks.sql
===============================================================================

WHAT THIS SCRIPT CHECKS
    1. All six tables exist
    2. Row counts match the source CSV files
    3. No duplicate primary / unique keys
    4. No orphan foreign keys
    5. Every order has items and a payment (parent-side coverage)
    5b. No hidden CR/LF or edge spaces left in text columns by the import
    6. Constraints are enabled AND trusted

HOW TO READ THE OUTPUT
    Every check writes one row into #validation with Status = PASS / FAIL /
    WARN. The final SELECT is the validation report: anything other than PASS
    must be explained before moving on to analysis.

WHY CHECK KEYS THE DATABASE ALREADY ENFORCES?
    Constraints can be disabled, dropped, or bypassed (e.g. BULK INSERT
    without CHECK_CONSTRAINTS). These queries test the DATA, not the schema,
    so they still catch problems if the constraints were not active at load.
    This script is read-only.
===============================================================================
*/

USE RetailAnalytics;
GO

SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#validation') IS NOT NULL DROP TABLE #validation;

CREATE TABLE #validation (
    CheckNo      INT IDENTITY(1,1),
    CheckGroup   VARCHAR(30),
    CheckName    VARCHAR(200),
    Expected     BIGINT NULL,
    Actual       BIGINT NULL,
    Status       VARCHAR(4)
);

-- =========================================
-- 1. TABLE EXISTENCE
-- =========================================
-- Expected value = 1 (table exists).

INSERT INTO #validation (CheckGroup, CheckName, Expected, Actual, Status)
SELECT
    'Table exists',
    t.TableName,
    1,
    CASE WHEN OBJECT_ID(N'dbo.' + t.TableName, N'U') IS NOT NULL THEN 1 ELSE 0 END,
    CASE WHEN OBJECT_ID(N'dbo.' + t.TableName, N'U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
FROM (VALUES
    ('dim_customers'), ('dim_products'), ('fact_orders'),
    ('fact_order_items'), ('fact_payments'), ('fact_returns')
) AS t(TableName);

-- =========================================
-- 2. ROW COUNTS VS SOURCE FILES
-- =========================================
-- Expected counts = data rows in each CSV (header excluded), recorded at the
-- time the dataset was profiled. Update them if the source files change.

;WITH expected AS (
    SELECT * FROM (VALUES
        ('dim_customers',    10000),
        ('dim_products',     10000),
        ('fact_orders',      20000),
        ('fact_order_items', 37843),
        ('fact_payments',    20000),
        ('fact_returns',     10000)
    ) AS e(TableName, ExpectedRows)
),
actual AS (
    SELECT 'dim_customers'    AS TableName, COUNT_BIG(*) AS ActualRows FROM dbo.dim_customers
    UNION ALL SELECT 'dim_products',     COUNT_BIG(*) FROM dbo.dim_products
    UNION ALL SELECT 'fact_orders',      COUNT_BIG(*) FROM dbo.fact_orders
    UNION ALL SELECT 'fact_order_items', COUNT_BIG(*) FROM dbo.fact_order_items
    UNION ALL SELECT 'fact_payments',    COUNT_BIG(*) FROM dbo.fact_payments
    UNION ALL SELECT 'fact_returns',     COUNT_BIG(*) FROM dbo.fact_returns
)
INSERT INTO #validation (CheckGroup, CheckName, Expected, Actual, Status)
SELECT
    'Row count',
    e.TableName,
    e.ExpectedRows,
    a.ActualRows,
    CASE WHEN a.ActualRows = e.ExpectedRows THEN 'PASS' ELSE 'FAIL' END
FROM expected e
JOIN actual a ON a.TableName = e.TableName;

-- =========================================
-- 3. DUPLICATE PRIMARY / UNIQUE KEYS
-- =========================================
-- Actual = number of key values that appear more than once. Expected = 0.

INSERT INTO #validation (CheckGroup, CheckName, Expected, Actual, Status)
SELECT 'Duplicate key', d.CheckName, 0, d.Dupes,
       CASE WHEN d.Dupes = 0 THEN 'PASS' ELSE 'FAIL' END
FROM (
    SELECT 'dim_customers.CustomerID' AS CheckName,
           (SELECT COUNT(*) FROM (SELECT CustomerID FROM dbo.dim_customers GROUP BY CustomerID HAVING COUNT(*) > 1) x) AS Dupes
    UNION ALL
    SELECT 'dim_products.ProductID',
           (SELECT COUNT(*) FROM (SELECT ProductID FROM dbo.dim_products GROUP BY ProductID HAVING COUNT(*) > 1) x)
    UNION ALL
    SELECT 'dim_products.SKU',
           (SELECT COUNT(*) FROM (SELECT SKU FROM dbo.dim_products GROUP BY SKU HAVING COUNT(*) > 1) x)
    UNION ALL
    SELECT 'fact_orders.OrderID',
           (SELECT COUNT(*) FROM (SELECT OrderID FROM dbo.fact_orders GROUP BY OrderID HAVING COUNT(*) > 1) x)
    UNION ALL
    SELECT 'fact_order_items.OrderItemID',
           (SELECT COUNT(*) FROM (SELECT OrderItemID FROM dbo.fact_order_items GROUP BY OrderItemID HAVING COUNT(*) > 1) x)
    UNION ALL
    SELECT 'fact_payments.PaymentID',
           (SELECT COUNT(*) FROM (SELECT PaymentID FROM dbo.fact_payments GROUP BY PaymentID HAVING COUNT(*) > 1) x)
    UNION ALL
    SELECT 'fact_payments.OrderID (1 payment per order)',
           (SELECT COUNT(*) FROM (SELECT OrderID FROM dbo.fact_payments GROUP BY OrderID HAVING COUNT(*) > 1) x)
    UNION ALL
    SELECT 'fact_returns.ReturnID',
           (SELECT COUNT(*) FROM (SELECT ReturnID FROM dbo.fact_returns GROUP BY ReturnID HAVING COUNT(*) > 1) x)
) AS d;

-- =========================================
-- 4. ORPHAN FOREIGN KEYS
-- =========================================
-- Actual = child rows whose parent key does not exist. Expected = 0.
-- NOT EXISTS is used (not LEFT JOIN ... IS NULL) because it reads clearly as
-- "child with no parent" and is null-safe.

INSERT INTO #validation (CheckGroup, CheckName, Expected, Actual, Status)
SELECT 'Orphan FK', o.CheckName, 0, o.Orphans,
       CASE WHEN o.Orphans = 0 THEN 'PASS' ELSE 'FAIL' END
FROM (
    SELECT 'fact_orders.CustomerID -> dim_customers' AS CheckName,
           (SELECT COUNT_BIG(*) FROM dbo.fact_orders c
             WHERE NOT EXISTS (SELECT 1 FROM dbo.dim_customers p WHERE p.CustomerID = c.CustomerID)) AS Orphans
    UNION ALL
    SELECT 'fact_order_items.OrderID -> fact_orders',
           (SELECT COUNT_BIG(*) FROM dbo.fact_order_items c
             WHERE NOT EXISTS (SELECT 1 FROM dbo.fact_orders p WHERE p.OrderID = c.OrderID))
    UNION ALL
    SELECT 'fact_order_items.ProductID -> dim_products',
           (SELECT COUNT_BIG(*) FROM dbo.fact_order_items c
             WHERE NOT EXISTS (SELECT 1 FROM dbo.dim_products p WHERE p.ProductID = c.ProductID))
    UNION ALL
    SELECT 'fact_payments.OrderID -> fact_orders',
           (SELECT COUNT_BIG(*) FROM dbo.fact_payments c
             WHERE NOT EXISTS (SELECT 1 FROM dbo.fact_orders p WHERE p.OrderID = c.OrderID))
    UNION ALL
    SELECT 'fact_returns.OrderID -> fact_orders',
           (SELECT COUNT_BIG(*) FROM dbo.fact_returns c
             WHERE NOT EXISTS (SELECT 1 FROM dbo.fact_orders p WHERE p.OrderID = c.OrderID))
) AS o;

-- =========================================
-- 5. RELATIONSHIP COVERAGE (parent side)
-- =========================================
-- FKs only guarantee child -> parent. These check the reverse expectations of
-- the business process: every order should have at least one line and
-- exactly one payment. Missing children are WARN, not FAIL: they may be
-- legitimate (e.g. an order still being built) but must be understood.

INSERT INTO #validation (CheckGroup, CheckName, Expected, Actual, Status)
SELECT 'Coverage', c.CheckName, 0, c.Missing,
       CASE WHEN c.Missing = 0 THEN 'PASS' ELSE 'WARN' END
FROM (
    SELECT 'Orders with no order items' AS CheckName,
           (SELECT COUNT_BIG(*) FROM dbo.fact_orders o
             WHERE NOT EXISTS (SELECT 1 FROM dbo.fact_order_items i WHERE i.OrderID = o.OrderID)) AS Missing
    UNION ALL
    SELECT 'Orders with no payment',
           (SELECT COUNT_BIG(*) FROM dbo.fact_orders o
             WHERE NOT EXISTS (SELECT 1 FROM dbo.fact_payments p WHERE p.OrderID = o.OrderID))
) AS c;

-- Informational: customers who never ordered. Not an error (prospects, or
-- sign-ups who did not convert) but it changes the denominator of any
-- "per customer" metric, so record it.
INSERT INTO #validation (CheckGroup, CheckName, Expected, Actual, Status)
SELECT 'Coverage', 'Customers with no orders (info)', NULL,
       (SELECT COUNT_BIG(*) FROM dbo.dim_customers c
         WHERE NOT EXISTS (SELECT 1 FROM dbo.fact_orders o WHERE o.CustomerID = c.CustomerID)),
       'INFO';

-- Informational: products never sold (same reasoning as above).
INSERT INTO #validation (CheckGroup, CheckName, Expected, Actual, Status)
SELECT 'Coverage', 'Products never sold (info)', NULL,
       (SELECT COUNT_BIG(*) FROM dbo.dim_products p
         WHERE NOT EXISTS (SELECT 1 FROM dbo.fact_order_items i WHERE i.ProductID = p.ProductID)),
       'INFO';

-- =========================================
-- 5b. HIDDEN CHARACTERS FROM THE IMPORT
-- =========================================
-- If the row terminator does not match the file's line endings, a carriage
-- return (CHAR(13)) is glued to the last column of every row. The value
-- looks right on screen but 'Gold' + CHAR(13) <> 'Gold', so every filter and
-- GROUP BY on that column breaks. Check every text column that ends a row,
-- plus leading/trailing spaces anywhere a filter is likely.
-- Fix (one-off, after confirming the count), e.g.:
--   UPDATE dbo.dim_customers SET LoyaltyTier  = REPLACE(REPLACE(LoyaltyTier,  CHAR(13), ''), CHAR(10), '');
--   UPDATE dbo.fact_returns  SET ReturnStatus = REPLACE(REPLACE(ReturnStatus, CHAR(13), ''), CHAR(10), '');
-- or truncate and reload with the corrected 02 script.

INSERT INTO #validation (CheckGroup, CheckName, Expected, Actual, Status)
SELECT 'Hidden characters', h.CheckName, 0, h.BadRows,
       CASE WHEN h.BadRows = 0 THEN 'PASS' ELSE 'FAIL' END
FROM (
    SELECT 'dim_customers.LoyaltyTier: CR/LF or edge spaces' AS CheckName,
           (SELECT COUNT_BIG(*) FROM dbo.dim_customers
             WHERE LoyaltyTier LIKE '%' + CHAR(13) + '%' OR LoyaltyTier LIKE '%' + CHAR(10) + '%'
                OR DATALENGTH(LoyaltyTier) <> DATALENGTH(LTRIM(RTRIM(LoyaltyTier)))) AS BadRows
    UNION ALL
    SELECT 'dim_customers.Region / AcquisitionChannel: CR/LF or edge spaces',
           (SELECT COUNT_BIG(*) FROM dbo.dim_customers
             WHERE Region LIKE '%' + CHAR(13) + '%' OR AcquisitionChannel LIKE '%' + CHAR(13) + '%'
                OR DATALENGTH(Region) <> DATALENGTH(LTRIM(RTRIM(Region)))
                OR DATALENGTH(AcquisitionChannel) <> DATALENGTH(LTRIM(RTRIM(AcquisitionChannel))))
    UNION ALL
    SELECT 'fact_orders.OrderStatus / ShippingMethod: CR/LF or edge spaces',
           (SELECT COUNT_BIG(*) FROM dbo.fact_orders
             WHERE OrderStatus LIKE '%' + CHAR(13) + '%' OR ShippingMethod LIKE '%' + CHAR(13) + '%'
                OR DATALENGTH(OrderStatus) <> DATALENGTH(LTRIM(RTRIM(OrderStatus)))
                OR DATALENGTH(ShippingMethod) <> DATALENGTH(LTRIM(RTRIM(ShippingMethod))))
    UNION ALL
    SELECT 'fact_payments.PaymentMethod / PaymentStatus: CR/LF or edge spaces',
           (SELECT COUNT_BIG(*) FROM dbo.fact_payments
             WHERE PaymentMethod LIKE '%' + CHAR(13) + '%' OR PaymentStatus LIKE '%' + CHAR(13) + '%'
                OR DATALENGTH(PaymentMethod) <> DATALENGTH(LTRIM(RTRIM(PaymentMethod)))
                OR DATALENGTH(PaymentStatus) <> DATALENGTH(LTRIM(RTRIM(PaymentStatus))))
    UNION ALL
    SELECT 'fact_returns.ReturnStatus / ReturnReason: CR/LF or edge spaces',
           (SELECT COUNT_BIG(*) FROM dbo.fact_returns
             WHERE ReturnStatus LIKE '%' + CHAR(13) + '%' OR ReturnStatus LIKE '%' + CHAR(10) + '%'
                OR ReturnReason LIKE '%' + CHAR(13) + '%'
                OR DATALENGTH(ReturnStatus) <> DATALENGTH(LTRIM(RTRIM(ReturnStatus)))
                OR DATALENGTH(ReturnReason) <> DATALENGTH(LTRIM(RTRIM(ReturnReason))))
    UNION ALL
    SELECT 'dim_products.Category / ProductName / SKU: CR/LF or edge spaces',
           (SELECT COUNT_BIG(*) FROM dbo.dim_products
             WHERE Category LIKE '%' + CHAR(13) + '%' OR ProductName LIKE '%' + CHAR(13) + '%'
                OR DATALENGTH(Category) <> DATALENGTH(LTRIM(RTRIM(Category)))
                OR DATALENGTH(SKU) <> DATALENGTH(LTRIM(RTRIM(SKU))))
) AS h;

-- =========================================
-- 6. CONSTRAINT HEALTH
-- =========================================
-- A constraint can exist but be disabled, or be enabled but "not trusted"
-- (data was loaded without checking it). Untrusted constraints:
--   - may hide rows that violate them, and
--   - cannot be used by the optimizer (e.g. for join elimination).
-- Fix after validating the data (one-off, re-checks every row):
--   ALTER TABLE dbo.<table> WITH CHECK CHECK CONSTRAINT ALL;

INSERT INTO #validation (CheckGroup, CheckName, Expected, Actual, Status)
SELECT
    'Constraint health',
    OBJECT_NAME(k.parent_object_id) + '.' + k.name,
    0,
    CAST(k.is_disabled AS INT) + CAST(k.is_not_trusted AS INT),
    CASE
        WHEN k.is_disabled = 1    THEN 'FAIL'
        WHEN k.is_not_trusted = 1 THEN 'WARN'
        ELSE 'PASS'
    END
FROM (
    SELECT name, parent_object_id, is_disabled, is_not_trusted FROM sys.foreign_keys
    UNION ALL
    SELECT name, parent_object_id, is_disabled, is_not_trusted FROM sys.check_constraints
) AS k
WHERE OBJECT_SCHEMA_NAME(k.parent_object_id) = 'dbo';

-- =========================================
-- 7. VALIDATION REPORT
-- =========================================

-- 7a. Summary: one line per check group. Read this first.
SELECT
    CheckGroup,
    COUNT(*)                                        AS Checks,
    SUM(CASE WHEN Status = 'PASS' THEN 1 ELSE 0 END) AS Passed,
    SUM(CASE WHEN Status = 'WARN' THEN 1 ELSE 0 END) AS Warnings,
    SUM(CASE WHEN Status = 'FAIL' THEN 1 ELSE 0 END) AS Failed,
    SUM(CASE WHEN Status = 'INFO' THEN 1 ELSE 0 END) AS Info
FROM #validation
GROUP BY CheckGroup
ORDER BY MIN(CheckNo);

-- 7b. Detail: every check, problems first.
SELECT CheckNo, CheckGroup, CheckName, Expected, Actual, Status
FROM #validation
ORDER BY
    CASE Status WHEN 'FAIL' THEN 1 WHEN 'WARN' THEN 2 WHEN 'INFO' THEN 3 ELSE 4 END,
    CheckNo;

-- 7c. Overall verdict.
SELECT
    CASE
        WHEN EXISTS (SELECT 1 FROM #validation WHERE Status = 'FAIL') THEN 'FAIL - fix before analysis'
        WHEN EXISTS (SELECT 1 FROM #validation WHERE Status = 'WARN') THEN 'PASS WITH WARNINGS - review WARN rows'
        ELSE 'PASS'
    END AS OverallResult;

DROP TABLE #validation;
GO
