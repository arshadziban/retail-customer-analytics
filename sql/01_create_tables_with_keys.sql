/*
===============================================================================
Project     : Enterprise Retail Analytics
Database    : RetailAnalytics
DBMS        : Microsoft SQL Server
Script      : 01_create_tables_with_keys.sql
===============================================================================

MODEL OVERVIEW (star schema, two dimensions + four fact tables)

    dim_customers (1) ----< (N) fact_orders (1) ----< (N) fact_order_items (N) >---- (1) dim_products
                                     |
                                     |-- (1:1) fact_payments
                                     |-- (1:N) fact_returns

GRAIN (one row represents...)
    dim_customers     one customer
    dim_products      one product / SKU
    fact_orders       one order (header level: status, shipping, freight)
    fact_order_items  one product line within an order (revenue & margin live here)
    fact_payments     one payment per order (enforced 1:1 via UNIQUE on OrderID)
    fact_returns      one return event, linked to the ORDER (not to an item)

CONVENTIONS
    - dim_ / fact_ prefixes make the role of each table obvious to BI users.
    - IDs are natural business keys (e.g. CUST000001), kept as VARCHAR because
      they are identifiers, not quantities, and carry a readable prefix.
    - Money is DECIMAL (never FLOAT) to avoid rounding drift in aggregates.
    - Every column is NOT NULL: the source data is complete, so we enforce it
      and let the database reject bad loads instead of hiding them in reports.
    - Text columns are NVARCHAR with headroom above the longest observed value.

KNOWN ANALYTICAL CAVEATS (read before building metrics)
    - Returns reference OrderID only, so item-level return rates are not
      possible without an allocation rule. Analyse returns at order level.
    - Orders with OrderStatus = 'Cancelled' and payments with
      PaymentStatus = 'Voided / Refunded' exist in the data. Decide explicitly
      whether to exclude them from revenue; do not sum LineTotal blindly.
    - UnitPrice / UnitCost are stored on the order line as well as on the
      product. The order-line values are the price/cost AT TIME OF SALE and are
      the ones to use for revenue and margin; dim_products holds the current
      price list only.
===============================================================================
*/

-- =========================================
-- 1. CREATE DATABASE
-- =========================================
-- Idempotent: every CREATE below is guarded (IF ... IS NULL / NOT EXISTS), so
-- re-running the script skips objects that already exist instead of failing.
-- Note the guard does not ALTER an existing table: to change a column
-- definition, drop and rebuild.

IF DB_ID(N'RetailAnalytics') IS NULL
    CREATE DATABASE RetailAnalytics;
GO

USE RetailAnalytics;
GO

-- =========================================
-- 2. CUSTOMER DIMENSION
-- =========================================
-- Grain : one row per customer.
-- Use   : slice every fact by acquisition channel, region and loyalty tier
--         (cohort, CAC-by-channel and retention analysis).
-- Note  : SignupDate is stored as DATE (time of day is irrelevant). Do NOT
--         use it as the cohort anchor: 04_data_quality_checks.sql found
--         ~38% of orders dated before the customer's SignupDate. Use the
--         first order date instead.

IF OBJECT_ID(N'dbo.dim_customers', N'U') IS NULL
CREATE TABLE dbo.dim_customers (
    CustomerID VARCHAR(20) NOT NULL,          -- business key, e.g. CUST000001
    CustomerName NVARCHAR(100) NOT NULL,
    AcquisitionChannel NVARCHAR(50) NOT NULL, -- marketing source (Google Ads, Paid Social, ...)
    SignupDate DATE NOT NULL,                 -- see note above before using
    Region NVARCHAR(50) NOT NULL,             -- geographic reporting level
    LoyaltyTier NVARCHAR(30) NOT NULL,        -- Standard / Silver / Gold / Platinum

    CONSTRAINT PK_dim_customers
        PRIMARY KEY (CustomerID)
);
GO

-- =========================================
-- 3. PRODUCT DIMENSION
-- =========================================
-- Grain : one row per product (SKU).
-- Use   : category / margin analysis and inventory health.
-- Note  : StockOnHand vs ReorderPoint supports stock-out and overstock
--         monitoring. UnitCost vs UnitPrice gives the list-price margin.
-- Rules : SKU is a second unique identifier; CHECKs block negative prices,
--         costs and stock so bad data fails at load time.

IF OBJECT_ID(N'dbo.dim_products', N'U') IS NULL
CREATE TABLE dbo.dim_products (
    ProductID VARCHAR(20) NOT NULL,           -- business key, e.g. PROD00001
    Category NVARCHAR(100) NOT NULL,
    ProductName NVARCHAR(150) NOT NULL,
    SKU VARCHAR(30) NOT NULL,                 -- stock keeping unit, unique
    UnitCost DECIMAL(12,2) NOT NULL,          -- current landed cost
    UnitPrice DECIMAL(12,2) NOT NULL,         -- current list price
    StockOnHand INT NOT NULL,
    ReorderPoint INT NOT NULL,                -- replenish when StockOnHand <= this

    CONSTRAINT PK_dim_products
        PRIMARY KEY (ProductID),

    CONSTRAINT UQ_dim_products_SKU
        UNIQUE (SKU),

    CONSTRAINT CK_dim_products_UnitCost
        CHECK (UnitCost >= 0),

    CONSTRAINT CK_dim_products_UnitPrice
        CHECK (UnitPrice >= 0),

    CONSTRAINT CK_dim_products_StockOnHand
        CHECK (StockOnHand >= 0),

    CONSTRAINT CK_dim_products_ReorderPoint
        CHECK (ReorderPoint >= 0)
);
GO

-- =========================================
-- 4. ORDER FACT TABLE
-- =========================================
-- Grain : one row per order (header).
-- Use   : order volume, fulfilment status mix, shipping-method mix,
--         customer purchase frequency and recency.
-- Note  : Revenue is NOT stored here; it is the sum of fact_order_items.
--         Freight is an order-level cost, so it must be counted once per
--         order. Joining to items and summing FreightCost will multiply it.
-- Time  : DATETIME2(0) = second precision, matching the source data.

IF OBJECT_ID(N'dbo.fact_orders', N'U') IS NULL
CREATE TABLE dbo.fact_orders (
    OrderID VARCHAR(20) NOT NULL,             -- business key, e.g. ORD0000001
    CustomerID VARCHAR(20) NOT NULL,
    OrderTimestamp DATETIME2(0) NOT NULL,     -- order placement time
    OrderStatus NVARCHAR(30) NOT NULL,        -- Processing / Shipped / Delivered / Cancelled
    ShippingMethod NVARCHAR(100) NOT NULL,
    FreightCost DECIMAL(12,2) NOT NULL,       -- shipping cost, order level

    CONSTRAINT PK_fact_orders
        PRIMARY KEY (OrderID),

    CONSTRAINT FK_fact_orders_dim_customers
        FOREIGN KEY (CustomerID)
        REFERENCES dbo.dim_customers(CustomerID),

    CONSTRAINT CK_fact_orders_FreightCost
        CHECK (FreightCost >= 0)
);
GO

-- =========================================
-- 5. ORDER ITEMS FACT TABLE
-- =========================================
-- Grain : one row per product line within an order. This is the core
--         revenue and margin table; most KPIs start here.
-- Note  : Price and cost are snapshotted on the line (see caveats above).
--         The measures are stored pre-computed in the source:
--             DiscountAmount = Quantity * UnitPrice * DiscountRate
--             LineTotal      = Quantity * UnitPrice - DiscountAmount
--             ItemNetMargin  = LineTotal - Quantity * UnitCost
--         They are kept as stored columns for query speed. Reconcile them
--         against the formulas in data-quality checks.
-- Rules : DiscountRate is a fraction (0.05 = 5%), hence DECIMAL(6,4) with a
--         0..1 check. Quantity must be positive. ItemNetMargin has no CHECK
--         on purpose: a line sold below cost can legitimately go negative.

IF OBJECT_ID(N'dbo.fact_order_items', N'U') IS NULL
CREATE TABLE dbo.fact_order_items (
    OrderItemID VARCHAR(20) NOT NULL,         -- business key, e.g. ITEM00000001
    OrderID VARCHAR(20) NOT NULL,
    ProductID VARCHAR(20) NOT NULL,
    Quantity INT NOT NULL,
    UnitPrice DECIMAL(12,2) NOT NULL,         -- price at time of sale
    UnitCost DECIMAL(12,2) NOT NULL,          -- cost at time of sale
    DiscountRate DECIMAL(6,4) NOT NULL,       -- fraction, 0.0500 = 5%
    DiscountAmount DECIMAL(14,2) NOT NULL,
    LineTotal DECIMAL(14,2) NOT NULL,         -- net revenue for the line
    ItemNetMargin DECIMAL(14,2) NOT NULL,     -- LineTotal minus cost of goods

    CONSTRAINT PK_fact_order_items
        PRIMARY KEY (OrderItemID),

    CONSTRAINT FK_fact_order_items_fact_orders
        FOREIGN KEY (OrderID)
        REFERENCES dbo.fact_orders(OrderID),

    CONSTRAINT FK_fact_order_items_dim_products
        FOREIGN KEY (ProductID)
        REFERENCES dbo.dim_products(ProductID),

    CONSTRAINT CK_fact_order_items_Quantity
        CHECK (Quantity > 0),

    CONSTRAINT CK_fact_order_items_UnitPrice
        CHECK (UnitPrice >= 0),

    CONSTRAINT CK_fact_order_items_UnitCost
        CHECK (UnitCost >= 0),

    CONSTRAINT CK_fact_order_items_DiscountRate
        CHECK (DiscountRate >= 0 AND DiscountRate <= 1),

    CONSTRAINT CK_fact_order_items_DiscountAmount
        CHECK (DiscountAmount >= 0),

    CONSTRAINT CK_fact_order_items_LineTotal
        CHECK (LineTotal >= 0)
);
GO

-- =========================================
-- 6. PAYMENTS FACT TABLE
-- =========================================
-- Grain : one payment per order.
-- Use   : payment-method mix, processing-fee cost, failed / voided payments.
-- Rules : UNIQUE(OrderID) enforces the 1:1 relationship with fact_orders, so
--         joining orders to payments cannot duplicate order rows.
-- Note  : ProcessingFee is a cost to the business (gateway fee). Deduct it
--         when calculating contribution margin per order.

IF OBJECT_ID(N'dbo.fact_payments', N'U') IS NULL
CREATE TABLE dbo.fact_payments (
    PaymentID VARCHAR(20) NOT NULL,           -- business key, e.g. PAY0000001
    OrderID VARCHAR(20) NOT NULL,
    PaymentMethod NVARCHAR(50) NOT NULL,
    PaymentStatus NVARCHAR(30) NOT NULL,      -- Success / Voided / Refunded
    ProcessingFee DECIMAL(14,2) NOT NULL,
    TotalAmountPaid DECIMAL(14,2) NOT NULL,   -- cash amount charged to the customer

    CONSTRAINT PK_fact_payments
        PRIMARY KEY (PaymentID),

    CONSTRAINT UQ_fact_payments_OrderID
        UNIQUE (OrderID),

    CONSTRAINT FK_fact_payments_fact_orders
        FOREIGN KEY (OrderID)
        REFERENCES dbo.fact_orders(OrderID),

    CONSTRAINT CK_fact_payments_ProcessingFee
        CHECK (ProcessingFee >= 0),

    CONSTRAINT CK_fact_payments_TotalAmountPaid
        CHECK (TotalAmountPaid >= 0)
);
GO

-- =========================================
-- 7. RETURNS FACT TABLE
-- =========================================
-- Grain : one row per return event, at ORDER level (no item reference).
-- Use   : return rate, return-reason analysis, refund and restocking cost.
-- Note  : Agree the treatment of RestockingFee (income retained vs. offset
--         against RefundAmount) with Finance before reporting net refunds.
--         Only 'Processed & Refunded' is a completed cash refund;
--         'Inspection Pending' is an open liability, not a final figure.
-- Rules : an order can have several returns (about 2.5k orders do), so there
--         is deliberately no UNIQUE on OrderID (contrast with fact_payments).
--         Count DISTINCT OrderID when calculating the order return rate.

IF OBJECT_ID(N'dbo.fact_returns', N'U') IS NULL
CREATE TABLE dbo.fact_returns (
    ReturnID VARCHAR(20) NOT NULL,            -- business key, e.g. RET000001
    OrderID VARCHAR(20) NOT NULL,
    ReturnTimestamp DATETIME2(0) NOT NULL,
    ReturnReason NVARCHAR(100) NOT NULL,
    RefundAmount DECIMAL(14,2) NOT NULL,
    RestockingFee DECIMAL(14,2) NOT NULL,
    ReturnStatus NVARCHAR(50) NOT NULL,       -- Inspection Pending / Processed & Refunded / Store Credit Issued

    CONSTRAINT PK_fact_returns
        PRIMARY KEY (ReturnID),

    CONSTRAINT FK_fact_returns_fact_orders
        FOREIGN KEY (OrderID)
        REFERENCES dbo.fact_orders(OrderID),

    CONSTRAINT CK_fact_returns_RefundAmount
        CHECK (RefundAmount >= 0),

    CONSTRAINT CK_fact_returns_RestockingFee
        CHECK (RestockingFee >= 0)
);
GO

-- =========================================
-- 8. CREATE INDEXES
-- =========================================
-- Primary and unique keys are already indexed by SQL Server. These cover the
-- foreign-key join paths that analytical queries hit most. SQL Server does
-- NOT create an index on a foreign key automatically.
--   fact_payments.OrderID is already covered by UQ_fact_payments_OrderID.

-- Customer history queries: orders per customer ordered by time
-- (recency, frequency, cohort and repeat-purchase analysis).
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_fact_orders_CustomerID_OrderTimestamp')
CREATE INDEX IX_fact_orders_CustomerID_OrderTimestamp
    ON dbo.fact_orders(CustomerID, OrderTimestamp);
GO

-- Order -> its lines (revenue and margin rolled up to order level).
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_fact_order_items_OrderID')
CREATE INDEX IX_fact_order_items_OrderID
    ON dbo.fact_order_items(OrderID);
GO

-- Product -> its sales (product and category performance).
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_fact_order_items_ProductID')
CREATE INDEX IX_fact_order_items_ProductID
    ON dbo.fact_order_items(ProductID);
GO

-- Order -> its returns (return-rate calculations).
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_fact_returns_OrderID')
CREATE INDEX IX_fact_returns_OrderID
    ON dbo.fact_returns(OrderID);
GO

-- =========================================
-- 9. VERIFY TABLE CREATION
-- =========================================
-- Expect 6 base tables: dim_customers, dim_products, fact_orders,
-- fact_order_items, fact_payments, fact_returns.

SELECT
    TABLE_SCHEMA,
    TABLE_NAME
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_TYPE = 'BASE TABLE'
ORDER BY TABLE_NAME;
GO
