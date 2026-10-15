/*
===============================================================================
Project     : Enterprise Retail Analytics
Database    : RetailAnalytics
DBMS        : Microsoft SQL Server
Script      : 02_import_csv_data.sql
Purpose     : Load the six CSV files in /dataset into the tables created by
              01_create_tables_with_keys.sql.
Run after   : 01_create_tables_with_keys.sql
Run before  : 03_validate_keys_and_rows.sql
===============================================================================

NOTES
    - BULK INSERT reads the file from the SQL SERVER machine, so @DataPath must
      be reachable by the server (and its service account). Edit it if needed.
    - Tables load parent-first (dimensions -> orders -> child facts) so every
      foreign key already has its parent row when the child arrives.
    - CHECK_CONSTRAINTS makes BULK INSERT validate FKs and CHECKs during the
      load. Without it SQL Server skips them and marks every constraint
      "not trusted", which hides bad rows and stops the optimizer from using
      the constraints. 03_validate_keys_and_rows.sql reports trust status.
    - The CSVs use Windows line endings (CR LF), so the row terminator is
      0x0d0a. Using 0x0a (LF only) leaves an invisible CR (CHAR(13)) on the
      last column of every row, e.g. 'Gold' + CHAR(13), and every text filter
      on that column silently returns nothing. 03 checks for this.
    - Re-runnable: a table that already contains rows is SKIPPED, never
      appended to (appending would duplicate keys). To reload a table,
      delete its child tables' rows first, then its own, then re-run.
===============================================================================
*/

USE RetailAnalytics;
GO

SET NOCOUNT ON;

DECLARE @DataPath NVARCHAR(400) = N'E:\Important\Skills\retail-customer-analytics\dataset\';
DECLARE @Table SYSNAME, @sql NVARCHAR(MAX), @HasRows BIT;

-- Load order matters: parents before children.
DECLARE @Tables TABLE (Ord INT IDENTITY(1,1), TableName SYSNAME);
INSERT INTO @Tables (TableName) VALUES
    (N'dim_customers'),
    (N'dim_products'),
    (N'fact_orders'),
    (N'fact_order_items'),
    (N'fact_payments'),
    (N'fact_returns');

DECLARE tbl_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT TableName FROM @Tables ORDER BY Ord;

OPEN tbl_cursor;
FETCH NEXT FROM tbl_cursor INTO @Table;

WHILE @@FETCH_STATUS = 0
BEGIN
    -- Skip tables that are already loaded.
    SET @sql = N'SELECT @HasRows = CASE WHEN EXISTS (SELECT 1 FROM dbo.'
             + QUOTENAME(@Table) + N') THEN 1 ELSE 0 END;';
    EXEC sys.sp_executesql @sql, N'@HasRows BIT OUTPUT', @HasRows = @HasRows OUTPUT;

    IF @HasRows = 1
    BEGIN
        PRINT CONCAT(N'Skipped ', @Table, N' (already contains rows)');
        FETCH NEXT FROM tbl_cursor INTO @Table;
        CONTINUE;
    END

    SET @sql = N'BULK INSERT dbo.' + QUOTENAME(@Table) + N'
        FROM ''' + @DataPath + @Table + N'.csv''
        WITH (
            FORMAT = ''CSV'',
            FIRSTROW = 2,
            FIELDTERMINATOR = '','',
            ROWTERMINATOR = ''0x0d0a'',
            CODEPAGE = ''65001'',
            CHECK_CONSTRAINTS,
            TABLOCK
        );';
    EXEC sys.sp_executesql @sql;
    PRINT CONCAT(N'Loaded ', @Table);
    FETCH NEXT FROM tbl_cursor INTO @Table;
END

CLOSE tbl_cursor;
DEALLOCATE tbl_cursor;
GO

-- =========================================
-- QUICK ROW-COUNT CHECK (full validation lives in 03)
-- Expected: dim_customers 10000, dim_products 10000, fact_orders 20000,
--           fact_order_items 37843, fact_payments 20000, fact_returns 10000
-- =========================================

SELECT 'dim_customers'    AS TableName, COUNT(*) AS RowCnt FROM dbo.dim_customers
UNION ALL SELECT 'dim_products',      COUNT(*) FROM dbo.dim_products
UNION ALL SELECT 'fact_orders',       COUNT(*) FROM dbo.fact_orders
UNION ALL SELECT 'fact_order_items',  COUNT(*) FROM dbo.fact_order_items
UNION ALL SELECT 'fact_payments',     COUNT(*) FROM dbo.fact_payments
UNION ALL SELECT 'fact_returns',      COUNT(*) FROM dbo.fact_returns;
GO
