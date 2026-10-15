/*
Script  : 01_create_tables_with_keys.sql
Purpose : Create the database, tables, keys, constraints and indexes.
          Star schema: 2 dimensions + 4 fact tables. Safe to re-run (skips existing objects).
*/

-- 1. CREATE DATABASE
IF DB_ID(N'RetailAnalytics') IS NULL
    CREATE DATABASE RetailAnalytics;
GO

USE RetailAnalytics;
GO

-- 2. CUSTOMER DIMENSION
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

-- 3. PRODUCT DIMENSION
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

-- 4. ORDER FACT TABLE
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

-- 5. ORDER ITEMS FACT TABLE
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

-- 6. PAYMENTS FACT TABLE
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

-- 7. RETURNS FACT TABLE
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

-- 8. CREATE INDEXES
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_fact_orders_CustomerID_OrderTimestamp')
CREATE INDEX IX_fact_orders_CustomerID_OrderTimestamp
    ON dbo.fact_orders(CustomerID, OrderTimestamp);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_fact_order_items_OrderID')
CREATE INDEX IX_fact_order_items_OrderID
    ON dbo.fact_order_items(OrderID);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_fact_order_items_ProductID')
CREATE INDEX IX_fact_order_items_ProductID
    ON dbo.fact_order_items(ProductID);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_fact_returns_OrderID')
CREATE INDEX IX_fact_returns_OrderID
    ON dbo.fact_returns(OrderID);
GO

-- 9. VERIFY TABLE CREATION
SELECT
    TABLE_SCHEMA,
    TABLE_NAME
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_TYPE = 'BASE TABLE'
ORDER BY TABLE_NAME;
GO
