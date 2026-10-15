/*
===============================================================================
Project     : Enterprise Retail Analytics
Database    : RetailAnalytics
DBMS        : Microsoft SQL Server
Script      : 00_run_all.sql
Purpose     : Build the whole project end to end, in the correct order.
===============================================================================

HOW TO RUN
    This script uses SQLCMD commands (:setvar, :r, :on error), which plain
    T-SQL does not understand. Without SQLCMD mode every one of those lines
    fails with "Incorrect syntax near ':'".

    SSMS        : 1. Query menu -> SQLCMD Mode (toggle it ON for this tab)
                  2. Check SqlDir below points at this sql folder
                  3. Execute
    Command line: sqlcmd -S localhost -E -C -b -i "<path>\00_run_all.sql"

    SqlDir must be an ABSOLUTE path. A relative path (".") is resolved from
    the SSMS / sqlcmd working directory, not from where this file lives.

SAFE TO RE-RUN
    01 skips tables/indexes that exist, 02 skips tables that already have
    rows, 03-08 are read-only, and 09 uses CREATE OR ALTER. Running this on
    an already-loaded database just refreshes the reports and views.
    :on error exit stops at the first failing script.
===============================================================================
*/

-- Guard: if SQLCMD mode is off, stop here with a clear message instead of a
-- wall of syntax errors further down.
:setvar SqlCmdEnabled "True"
GO
IF N'$(SqlCmdEnabled)' <> N'True'
BEGIN
    RAISERROR(N'SQLCMD Mode is OFF. In SSMS: Query menu -> SQLCMD Mode, then run again.', 16, 1);
    SET NOEXEC ON;   -- compile but do not execute the rest of the script
END
GO

:on error exit
:setvar SqlDir "E:\Important\Skills\retail-customer-analytics\sql"

PRINT '== 01 Create tables';
GO
:r $(SqlDir)\01_create_tables_with_keys.sql

PRINT '== 02 Import CSV data';
GO
:r $(SqlDir)\02_import_csv_data.sql

PRINT '== 03 Validate keys and rows';
GO
:r $(SqlDir)\03_validate_keys_and_rows.sql

PRINT '== 04 Data quality checks';
GO
:r $(SqlDir)\04_data_quality_checks.sql

PRINT '== 05 Sales analysis';
GO
:r $(SqlDir)\05_sales_analysis.sql

PRINT '== 06 RFM segmentation';
GO
:r $(SqlDir)\06_rfm_segmentation.sql

PRINT '== 07 Product profitability';
GO
:r $(SqlDir)\07_product_profitability.sql

PRINT '== 08 Payments and returns';
GO
:r $(SqlDir)\08_payments_and_returns.sql

PRINT '== 09 Create analytical views';
GO
:r $(SqlDir)\09_create_analytical_views.sql

PRINT '== Done';
GO
SET NOEXEC OFF;
GO
