/*
Script  : 02_import_csv_data.sql
Purpose : Load the CSV files into the tables (parents first).
          Set @DataPath to the dataset folder. CSVs use CRLF, so ROWTERMINATOR = 0x0d0a.
          Tables that already have rows are skipped.
*/

USE RetailAnalytics;
GO

SET NOCOUNT ON;

DECLARE @DataPath NVARCHAR(400) = N'E:\Important\Skills\retail-customer-analytics\dataset\';
DECLARE @Table SYSNAME, @sql NVARCHAR(MAX), @HasRows BIT;

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

-- Row-count check (expected: 10000, 10000, 20000, 37843, 20000, 10000)
SELECT 'dim_customers'    AS TableName, COUNT(*) AS RowCnt FROM dbo.dim_customers
UNION ALL SELECT 'dim_products',      COUNT(*) FROM dbo.dim_products
UNION ALL SELECT 'fact_orders',       COUNT(*) FROM dbo.fact_orders
UNION ALL SELECT 'fact_order_items',  COUNT(*) FROM dbo.fact_order_items
UNION ALL SELECT 'fact_payments',     COUNT(*) FROM dbo.fact_payments
UNION ALL SELECT 'fact_returns',      COUNT(*) FROM dbo.fact_returns;
GO
