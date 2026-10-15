# retail-customer-analytics

End-to-end retail analytics in Microsoft SQL Server: build a star schema from raw CSV files, validate and quality-check the data, then analyse sales, customers (RFM segmentation), product profitability, payments and returns. The results are published as views that Power BI can read directly.

## Project structure

```
retail-customer-analytics/
├── dataset/                              Source CSV files (one per table)
│   ├── dim_customers.csv                 10,000 customers
│   ├── dim_products.csv                  10,000 products
│   ├── fact_orders.csv                   20,000 orders
│   ├── fact_order_items.csv              37,843 order lines
│   ├── fact_payments.csv                 20,000 payments (one per order)
│   └── fact_returns.csv                  10,000 return records
└── sql/
    ├── 00_run_all.sql                    Runs 01-10 in order (SQLCMD mode)
    │
    │   Setup
    ├── 01_create_tables_with_keys.sql    Database, tables, keys, constraints, indexes
    ├── 02_import_csv_data.sql            BULK INSERT the CSVs, parents first
    │
    │   Validation
    ├── 03_validate_keys_and_rows.sql     Row counts, duplicate keys, orphan FKs, constraint health
    ├── 04_data_quality_checks.sql        Missing, invalid or inconsistent values (read-only)
    │
    │   Analysis
    ├── 05_sales_analysis.sql             KPIs, trends, region, channel, shipping
    ├── 06_rfm_segmentation.sql           RFM scores, segments, retention targets
    ├── 07_product_profitability.sql      Category and product margin, discounts, inventory
    ├── 08_payments_and_returns.sql       Payment methods and fees, return rates and reasons
    │
    │   Reporting layer
    ├── 09_create_analytical_views.sql    Summary views (one per analysis topic)
    └── 10_create_powerbi_model_views.sql Star-schema views for the Power BI model
```

## Data model

```
dim_customers 1 ──< fact_orders 1 ──< fact_order_items >── 1 dim_products
                         │
                         ├── 1:1  fact_payments
                         └── 1:N  fact_returns
```

## How to run

The `dataset/` folder is not in the repository (it is listed in `.gitignore`). Put the six CSV files in `dataset/` before you start.

1. Open `sql/02_import_csv_data.sql` and set `@DataPath` to the `dataset` folder. The path must be readable by the SQL Server service.
2. Run the scripts in number order, or run everything at once with `00_run_all.sql`. First set `SqlDir` in that file to the full path of the `sql` folder.
   - **SSMS:** open `00_run_all.sql`, turn on **Query → SQLCMD Mode**, and execute it. Without SQLCMD Mode, the `:r` lines fail with `Incorrect syntax near ':'`.
   - **Command line:** `sqlcmd -S localhost -E -C -b -i "<path>\sql\00_run_all.sql"`
3. Check that `03_validate_keys_and_rows.sql` reports `PASS`, and read the HIGH items in `04_data_quality_checks.sql` before using the numbers.
4. Connect Power BI to the six `pbi_*` views and create the relationships listed in [Power BI model](#power-bi-model).

You can re-run everything safely. Script `01` skips tables that already exist, `02` skips tables that already contain rows, and `09` replaces the views. To rebuild from scratch, drop the database first.

## Metric definitions

Scripts 05-09 all use these rules.

| Metric | Definition |
|---|---|
| Qualifying order | `OrderStatus <> 'Cancelled'` |
| Net sales | `SUM(LineTotal)` on qualifying orders. Equals the amount paid. |
| Item margin | `SUM(ItemNetMargin)`, which is net sales minus cost of goods |
| Contribution | Item margin − freight − payment processing fee |
| Order return rate | Delivered orders with at least one return ÷ delivered orders |
| Refund (capped) | Refunds per order, capped at the order's net value |

## Power BI model

Load **only** the `pbi_*` views from script 10. They form a star schema:

```
              pbi_dim_date
            /      |       \
 pbi_fact_orders  pbi_fact_order_lines  pbi_fact_returns ── (all three) ── pbi_dim_customer
                          |
                   pbi_dim_product
```

| From (one side) | To (many side) |
|---|---|
| `pbi_dim_date[Date]` | `pbi_fact_orders[OrderDate]` |
| `pbi_dim_date[Date]` | `pbi_fact_order_lines[OrderDate]` |
| `pbi_dim_date[Date]` | `pbi_fact_returns[ReturnDate]` |
| `pbi_dim_customer[CustomerID]` | `pbi_fact_orders[CustomerID]` |
| `pbi_dim_customer[CustomerID]` | `pbi_fact_order_lines[CustomerID]` |
| `pbi_dim_customer[CustomerID]` | `pbi_fact_returns[CustomerID]` |
| `pbi_dim_product[ProductID]` | `pbi_fact_order_lines[ProductID]` |

Every relationship is one-to-many with a single filter direction. Do not relate the fact views to each other on `OrderID`. They connect through the shared dimensions.

## Summary views

The `vw_*` views from script 09 are pre-aggregated, one per analysis topic. They share no keys, so they cannot be joined into a Power BI model. Use them for SQL queries or for single-table report pages.

| View | One row per | Use |
|---|---|---|
| `vw_order_summary` | order | Base layer: sales, costs, payment and returns at order level |
| `vw_sales_monthly` | order month | Executive trend KPIs and return rate |
| `vw_customer_rfm` | purchasing customer | RFM scores and segment |
| `vw_product_profitability` | product | Sales, margin, stock status |
| `vw_payment_summary` | month × method × status | Payment KPIs and fees |
| `vw_returns_summary` | return month × reason × status | Return volume and refund cost |

## Known data issues

Found by `04_data_quality_checks.sql`. The analysis handles each of them as described.

- **Refunds above order value:** 2,206 orders have refunds that add up to more than the order was worth. Refunds are reported both as recorded and capped, and are never subtracted from sales.
- **Orders before signup:** about 38% of orders are dated before the customer's `SignupDate`. The first order date is used instead of signup date.
- **Incomplete recent returns:** returns arrive up to 30 days after delivery, so return rates for the last month are understated.
- **Stock snapshot only:** inventory is a single snapshot with no stock-movement history, so past stock-outs can't be measured.
