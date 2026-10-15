/*
Script  : 00_run_all.sql
Purpose : Run all scripts (01-10) in order.
          SSMS: turn on Query > SQLCMD Mode first.
          Set SqlDir to the full path of this folder. Safe to re-run.
*/

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

PRINT '== 10 Create Power BI model views';
GO
:r $(SqlDir)\10_create_powerbi_model_views.sql

PRINT '== Done';
GO
SET NOEXEC OFF;
GO
