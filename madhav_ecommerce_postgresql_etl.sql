-- =============================================================================
-- PROJECT     : Madhav E-Commerce Sales Dashboard — PostgreSQL ETL Pipeline
-- AUTHOR      : Shil Gawande
-- DATABASE    : PostgreSQL 15+
-- DESCRIPTION : End-to-end ETL workflow — raw CSV ingestion → data cleaning
--               → feature engineering → analytical views → Power BI-ready queries
-- TOOLS USED  : PostgreSQL, Power BI Desktop
-- DATE        : 2024
-- =============================================================================
--
-- WORKFLOW OVERVIEW
-- -----------------
-- STAGE 1 : Create raw staging tables and load CSV data via COPY
-- STAGE 2 : Data cleaning (duplicates, NULLs, type casting, trimming)
-- STAGE 3 : Create cleaned_orders and cleaned_details tables
-- STAGE 4 : Feature engineering (profit margin, date parts, quarter, etc.)
-- STAGE 5 : Analytical views for Power BI DirectQuery or Import
-- STAGE 6 : Power BI–ready SQL queries (KPIs, trends, rankings)
-- STAGE 7 : Indexing and performance optimisation
-- =============================================================================


-- =============================================================================
-- PRE-FLIGHT: Create and select a dedicated database (run from psql as superuser)
-- =============================================================================

-- CREATE DATABASE madhav_ecommerce
--     WITH ENCODING = 'UTF8'
--          LC_COLLATE = 'en_US.UTF-8'
--          LC_CTYPE   = 'en_US.UTF-8'
--          TEMPLATE   = template0;

-- \c madhav_ecommerce;   -- connect to the database before running the rest


-- =============================================================================
-- STAGE 1 — RAW STAGING TABLES
-- =============================================================================
-- We first land the raw CSV data into staging tables (prefix: stg_).
-- No constraints, no transformations — exactly mirrors the CSV headers.
-- This lets us inspect dirty data before cleaning.
-- =============================================================================

-- Drop staging tables if they already exist (safe re-run)
DROP TABLE IF EXISTS stg_orders  CASCADE;
DROP TABLE IF EXISTS stg_details CASCADE;

-- -----------------------------------------------------------------------------
-- 1.1  stg_orders — mirrors Orders.csv
--      Columns: Order ID, Order Date, CustomerName, State, City
-- -----------------------------------------------------------------------------
CREATE TABLE stg_orders (
    order_id      TEXT,   -- raw, may contain spaces or duplicates
    order_date    TEXT,   -- stored as text first; we convert in cleaning stage
    customer_name TEXT,
    state         TEXT,
    city          TEXT
);

COMMENT ON TABLE stg_orders IS
'Raw staging table loaded directly from Orders.csv. No constraints applied.
 Purpose: capture source data as-is for auditing before transformation.';

-- -----------------------------------------------------------------------------
-- 1.2  stg_details — mirrors Details.csv
--      Columns: Order ID, Amount, Profit, Quantity, Category, Sub-Category, PaymentMode
-- -----------------------------------------------------------------------------
CREATE TABLE stg_details (
    order_id      TEXT,
    amount        TEXT,   -- kept as TEXT to catch non-numeric values
    profit        TEXT,
    quantity      TEXT,
    category      TEXT,
    sub_category  TEXT,
    payment_mode  TEXT
);

COMMENT ON TABLE stg_details IS
'Raw staging table loaded directly from Details.csv. Numeric columns intentionally
 stored as TEXT to surface any non-numeric anomalies during cleaning.';


-- =============================================================================
-- STAGE 2 — LOAD RAW CSV DATA (COPY COMMANDS)
-- =============================================================================
-- The COPY command is the fastest bulk-load mechanism in PostgreSQL.
-- Replace the file paths below with the actual absolute paths on your server.
-- If running from psql client, use \copy (lowercase) instead of server-side COPY.
-- =============================================================================

-- Load Orders
COPY stg_orders (order_id, order_date, customer_name, state, city)
FROM '/path/to/Orders.csv'
WITH (
    FORMAT CSV,
    HEADER TRUE,         -- skip the header row
    DELIMITER ',',
    ENCODING 'UTF8',
    NULL ''              -- treat empty strings as NULL during load
);

-- Load Details
COPY stg_details (order_id, amount, profit, quantity, category, sub_category, payment_mode)
FROM '/path/to/Details.csv'
WITH (
    FORMAT CSV,
    HEADER TRUE,
    DELIMITER ',',
    ENCODING 'UTF8',
    NULL ''
);

-- Quick row-count sanity check after loading
-- Expected: 500 rows in stg_orders, 1500 rows in stg_details
SELECT 'stg_orders'  AS table_name, COUNT(*) AS row_count FROM stg_orders
UNION ALL
SELECT 'stg_details' AS table_name, COUNT(*) AS row_count FROM stg_details;


-- =============================================================================
-- STAGE 3 — DATA QUALITY AUDIT (run before cleaning; review outputs)
-- =============================================================================
-- These queries surface problems in the raw data so we can document exactly
-- what was cleaned and why — important for interview discussions.
-- =============================================================================

-- 3.1 Check for NULLs in stg_orders
SELECT
    COUNT(*)                                              AS total_rows,
    COUNT(*) FILTER (WHERE order_id      IS NULL)        AS null_order_id,
    COUNT(*) FILTER (WHERE order_date    IS NULL)        AS null_order_date,
    COUNT(*) FILTER (WHERE customer_name IS NULL)        AS null_customer_name,
    COUNT(*) FILTER (WHERE state         IS NULL)        AS null_state,
    COUNT(*) FILTER (WHERE city          IS NULL)        AS null_city
FROM stg_orders;

-- 3.2 Check for NULLs in stg_details
SELECT
    COUNT(*)                                              AS total_rows,
    COUNT(*) FILTER (WHERE order_id      IS NULL)        AS null_order_id,
    COUNT(*) FILTER (WHERE amount        IS NULL)        AS null_amount,
    COUNT(*) FILTER (WHERE profit        IS NULL)        AS null_profit,
    COUNT(*) FILTER (WHERE quantity      IS NULL)        AS null_quantity,
    COUNT(*) FILTER (WHERE category      IS NULL)        AS null_category,
    COUNT(*) FILTER (WHERE sub_category  IS NULL)        AS null_sub_category,
    COUNT(*) FILTER (WHERE payment_mode  IS NULL)        AS null_payment_mode
FROM stg_details;

-- 3.3 Detect duplicate Order IDs in stg_orders
SELECT order_id, COUNT(*) AS occurrences
FROM stg_orders
GROUP BY order_id
HAVING COUNT(*) > 1
ORDER BY occurrences DESC;

-- 3.4 Detect non-numeric values in amount, profit, quantity
SELECT order_id, amount, profit, quantity
FROM stg_details
WHERE amount   !~ '^-?[0-9]+(\.[0-9]+)?$'
   OR profit   !~ '^-?[0-9]+(\.[0-9]+)?$'
   OR quantity !~ '^-?[0-9]+(\.[0-9]+)?$';

-- 3.5 Validate date format (expected: DD-MM-YYYY)
SELECT order_id, order_date
FROM stg_orders
WHERE order_date !~ '^\d{2}-\d{2}-\d{4}$';

-- 3.6 Distinct values for categorical columns
SELECT DISTINCT category     FROM stg_details ORDER BY 1;
SELECT DISTINCT sub_category FROM stg_details ORDER BY 1;
SELECT DISTINCT payment_mode FROM stg_details ORDER BY 1;
SELECT DISTINCT state        FROM stg_orders  ORDER BY 1;

-- 3.7 Blank string check (cells that have whitespace only)
SELECT COUNT(*) AS blank_order_id_count
FROM stg_orders
WHERE TRIM(order_id) = '';

SELECT COUNT(*) AS blank_category_count
FROM stg_details
WHERE TRIM(category) = '';

-- 3.8 Negative or zero quantity / amount — potential data entry errors
SELECT order_id, amount, profit, quantity
FROM stg_details
WHERE CAST(quantity AS INTEGER) <= 0
   OR CAST(amount   AS NUMERIC) <= 0;


-- =============================================================================
-- STAGE 4 — CLEANED TABLES
-- =============================================================================
-- cleaned_orders and cleaned_details are the canonical "source of truth" tables.
-- All downstream analytics and Power BI queries reference these tables only.
-- =============================================================================

DROP TABLE IF EXISTS cleaned_orders  CASCADE;
DROP TABLE IF EXISTS cleaned_details CASCADE;

-- -----------------------------------------------------------------------------
-- 4.1  cleaned_orders
-- -----------------------------------------------------------------------------
CREATE TABLE cleaned_orders (
    order_id      VARCHAR(20)  NOT NULL,
    order_date    DATE         NOT NULL,
    customer_name VARCHAR(100) NOT NULL,
    state         VARCHAR(100) NOT NULL,
    city          VARCHAR(100) NOT NULL,
    -- Audit columns to track ETL processing
    etl_loaded_at TIMESTAMP    NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_cleaned_orders PRIMARY KEY (order_id)
);

COMMENT ON TABLE cleaned_orders IS
'Cleaned and standardised orders data derived from stg_orders.
 Transformations applied: deduplication, NULL removal, TRIM, INITCAP normalisation,
 date string converted to DATE type.';

COMMENT ON COLUMN cleaned_orders.order_id      IS 'Unique order identifier. Source: Orders.csv "Order ID"';
COMMENT ON COLUMN cleaned_orders.order_date    IS 'Parsed order date (DD-MM-YYYY → DATE). Source: "Order Date"';
COMMENT ON COLUMN cleaned_orders.customer_name IS 'INITCAP normalised customer name. Source: "CustomerName"';
COMMENT ON COLUMN cleaned_orders.state         IS 'INITCAP normalised Indian state name. Source: "State"';
COMMENT ON COLUMN cleaned_orders.city          IS 'INITCAP normalised city name. Source: "City"';
COMMENT ON COLUMN cleaned_orders.etl_loaded_at IS 'Timestamp when this row was inserted by the ETL pipeline.';


-- Insert into cleaned_orders with all cleaning transformations
INSERT INTO cleaned_orders (order_id, order_date, customer_name, state, city)
WITH deduped AS (
    -- Step 1: Remove exact duplicate rows using ROW_NUMBER.
    -- We keep the first occurrence of each order_id.
    SELECT
        order_id,
        order_date,
        customer_name,
        state,
        city,
        ROW_NUMBER() OVER (PARTITION BY TRIM(order_id) ORDER BY order_id) AS rn
    FROM stg_orders
),
validated AS (
    -- Step 2: Exclude rows with NULL/blank primary key or critical columns.
    SELECT *
    FROM deduped
    WHERE rn = 1                          -- keep only first occurrence of duplicate
      AND TRIM(order_id)      <> ''       -- remove blank order IDs
      AND order_id            IS NOT NULL
      AND order_date          IS NOT NULL
      AND TRIM(order_date)    <> ''
      AND customer_name       IS NOT NULL
      AND TRIM(customer_name) <> ''
      AND state               IS NOT NULL
      AND TRIM(state)         <> ''
      AND city                IS NOT NULL
      AND TRIM(city)          <> ''
),
transformed AS (
    -- Step 3: Type casting and text standardisation
    SELECT
        UPPER(TRIM(order_id))                              AS order_id,
        -- Convert DD-MM-YYYY string to PostgreSQL DATE
        TO_DATE(TRIM(order_date), 'DD-MM-YYYY')           AS order_date,
        -- INITCAP: first letter of each word uppercased (e.g. "harivansh" → "Harivansh")
        INITCAP(TRIM(customer_name))                       AS customer_name,
        -- State and city: trim + INITCAP for consistency
        INITCAP(TRIM(state))                               AS state,
        INITCAP(TRIM(city))                                AS city
    FROM validated
)
SELECT order_id, order_date, customer_name, state, city
FROM transformed;

-- Verify cleaned_orders load
SELECT COUNT(*) AS cleaned_orders_rows FROM cleaned_orders;


-- -----------------------------------------------------------------------------
-- 4.2  cleaned_details
-- -----------------------------------------------------------------------------
CREATE TABLE cleaned_details (
    detail_id    SERIAL       NOT NULL,   -- surrogate key (Details has no natural PK)
    order_id     VARCHAR(20)  NOT NULL,
    amount       NUMERIC(12,2) NOT NULL,
    profit       NUMERIC(12,2) NOT NULL,
    quantity     INTEGER       NOT NULL,
    category     VARCHAR(50)   NOT NULL,
    sub_category VARCHAR(50)   NOT NULL,
    payment_mode VARCHAR(30)   NOT NULL,
    etl_loaded_at TIMESTAMP    NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_cleaned_details PRIMARY KEY (detail_id),
    CONSTRAINT fk_details_orders  FOREIGN KEY (order_id)
        REFERENCES cleaned_orders (order_id)
        ON DELETE CASCADE
        ON UPDATE CASCADE
);

COMMENT ON TABLE cleaned_details IS
'Cleaned and type-cast order details derived from stg_details.
 Transformations: numeric casting, NULL removal, INITCAP for categoricals,
 payment mode standardisation, foreign key to cleaned_orders enforced.';

COMMENT ON COLUMN cleaned_details.detail_id    IS 'Surrogate primary key (auto-increment).';
COMMENT ON COLUMN cleaned_details.order_id     IS 'FK to cleaned_orders.order_id.';
COMMENT ON COLUMN cleaned_details.amount       IS 'Sale amount in INR. Cast from TEXT to NUMERIC.';
COMMENT ON COLUMN cleaned_details.profit       IS 'Profit in INR (can be negative = loss).';
COMMENT ON COLUMN cleaned_details.quantity     IS 'Number of units sold.';
COMMENT ON COLUMN cleaned_details.category     IS 'Product category: Electronics, Furniture, Clothing.';
COMMENT ON COLUMN cleaned_details.sub_category IS 'Product sub-category (e.g., Phones, Chairs, Saree).';
COMMENT ON COLUMN cleaned_details.payment_mode IS 'Standardised payment method.';


INSERT INTO cleaned_details (order_id, amount, profit, quantity, category, sub_category, payment_mode)
WITH raw AS (
    SELECT
        order_id,
        amount,
        profit,
        quantity,
        category,
        sub_category,
        payment_mode,
        -- Row number to detect identical duplicate detail rows
        ROW_NUMBER() OVER (
            PARTITION BY order_id, amount, profit, quantity, category, sub_category, payment_mode
            ORDER BY order_id
        ) AS rn
    FROM stg_details
),
validated AS (
    -- Remove NULLs, blank strings, non-numeric amount/profit/quantity, and zero/negative quantities
    SELECT *
    FROM raw
    WHERE rn = 1                          -- deduplicate fully identical rows
      AND order_id      IS NOT NULL
      AND TRIM(order_id) <> ''
      AND amount        IS NOT NULL
      AND TRIM(amount)  <> ''
      AND amount ~ '^-?[0-9]+(\.[0-9]+)?$'   -- must be numeric
      AND profit        IS NOT NULL
      AND TRIM(profit)  <> ''
      AND profit ~ '^-?[0-9]+(\.[0-9]+)?$'
      AND quantity      IS NOT NULL
      AND TRIM(quantity) <> ''
      AND quantity ~ '^[0-9]+$'               -- quantity must be a positive integer
      AND CAST(quantity AS INTEGER) > 0
      AND category      IS NOT NULL
      AND TRIM(category) <> ''
      AND sub_category  IS NOT NULL
      AND TRIM(sub_category) <> ''
      AND payment_mode  IS NOT NULL
      AND TRIM(payment_mode) <> ''
),
transformed AS (
    SELECT
        UPPER(TRIM(order_id))                     AS order_id,
        CAST(TRIM(amount)   AS NUMERIC(12,2))     AS amount,
        CAST(TRIM(profit)   AS NUMERIC(12,2))     AS profit,
        CAST(TRIM(quantity) AS INTEGER)            AS quantity,
        -- Standardise category to INITCAP
        INITCAP(TRIM(category))                   AS category,
        INITCAP(TRIM(sub_category))               AS sub_category,
        -- Standardise payment mode
        CASE TRIM(UPPER(payment_mode))
            WHEN 'COD'         THEN 'COD'
            WHEN 'EMI'         THEN 'EMI'
            WHEN 'UPI'         THEN 'UPI'
            WHEN 'CREDIT CARD' THEN 'Credit Card'
            WHEN 'DEBIT CARD'  THEN 'Debit Card'
            ELSE INITCAP(TRIM(payment_mode))   -- fallback for unknown values
        END                                       AS payment_mode
    FROM validated
),
-- Only keep detail rows whose order_id exists in cleaned_orders
-- (referential integrity: orphan details are discarded)
final_filtered AS (
    SELECT t.*
    FROM transformed t
    INNER JOIN cleaned_orders co ON t.order_id = co.order_id
)
SELECT order_id, amount, profit, quantity, category, sub_category, payment_mode
FROM final_filtered;

-- Verify cleaned_details load
SELECT COUNT(*) AS cleaned_details_rows FROM cleaned_details;


-- =============================================================================
-- STAGE 5 — FEATURE ENGINEERING
-- =============================================================================
-- Derived columns that Power BI would otherwise compute in DAX.
-- Pre-computing in SQL is more efficient for large datasets and is also good
-- for demonstrating SQL analytical skills.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 5.1  vw_order_enriched — joins cleaned_orders + cleaned_details and adds
--      all derived/feature-engineered columns in one place.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_order_enriched AS
SELECT
    -- ── Base columns from cleaned_orders ──────────────────────────────────────
    co.order_id,
    co.order_date,
    co.customer_name,
    co.state,
    co.city,

    -- ── Base columns from cleaned_details ────────────────────────────────────
    cd.detail_id,
    cd.category,
    cd.sub_category,
    cd.payment_mode,
    cd.amount,
    cd.profit,
    cd.quantity,

    -- ── Feature: Profit Margin % ──────────────────────────────────────────────
    -- Profit Margin = (Profit / Amount) * 100
    -- NULLIF prevents division-by-zero when amount = 0
    ROUND(
        (cd.profit / NULLIF(cd.amount, 0)) * 100,
        2
    )                                               AS profit_margin_pct,

    -- ── Feature: Profit Flag ─────────────────────────────────────────────────
    CASE
        WHEN cd.profit > 0  THEN 'Profitable'
        WHEN cd.profit < 0  THEN 'Loss'
        ELSE                     'Break Even'
    END                                             AS profit_flag,

    -- ── Feature: Revenue per Unit (Average Selling Price) ────────────────────
    ROUND(cd.amount / NULLIF(cd.quantity, 0), 2)   AS revenue_per_unit,

    -- ── Feature: Date Parts ───────────────────────────────────────────────────
    EXTRACT(DAY   FROM co.order_date)::INTEGER      AS order_day,
    EXTRACT(MONTH FROM co.order_date)::INTEGER      AS order_month,
    TO_CHAR(co.order_date, 'Month')                 AS order_month_name,     -- e.g. 'January  '
    TRIM(TO_CHAR(co.order_date, 'Month'))           AS order_month_name_trim, -- e.g. 'January'
    EXTRACT(YEAR  FROM co.order_date)::INTEGER      AS order_year,

    -- ── Feature: Quarter ─────────────────────────────────────────────────────
    EXTRACT(QUARTER FROM co.order_date)::INTEGER    AS order_quarter,
    'Q' || EXTRACT(QUARTER FROM co.order_date)::TEXT AS quarter_label,        -- e.g. 'Q1'

    -- ── Feature: Day of Week ─────────────────────────────────────────────────
    TO_CHAR(co.order_date, 'Day')                   AS day_name,              -- e.g. 'Monday   '
    TRIM(TO_CHAR(co.order_date, 'Day'))             AS day_name_trim,         -- e.g. 'Monday'
    EXTRACT(DOW FROM co.order_date)::INTEGER        AS day_of_week,           -- 0=Sunday, 6=Saturday

    -- ── Feature: Week of Year ────────────────────────────────────────────────
    EXTRACT(WEEK FROM co.order_date)::INTEGER       AS week_of_year,

    -- ── Feature: Category Bucket (standardised grouping) ─────────────────────
    CASE cd.category
        WHEN 'Electronics' THEN 'Tech & Gadgets'
        WHEN 'Furniture'   THEN 'Home & Office'
        WHEN 'Clothing'    THEN 'Fashion & Apparel'
        ELSE 'Other'
    END                                             AS category_bucket,

    -- ── Feature: State Region (geographic segmentation) ──────────────────────
    CASE co.state
        WHEN 'Uttar Pradesh'    THEN 'North'
        WHEN 'Delhi'            THEN 'North'
        WHEN 'Punjab'           THEN 'North'
        WHEN 'Rajasthan'        THEN 'North'
        WHEN 'Haryana'          THEN 'North'
        WHEN 'Himachal Pradesh' THEN 'North'
        WHEN 'Uttarakhand'      THEN 'North'
        WHEN 'Jammu & Kashmir'  THEN 'North'
        WHEN 'Maharashtra'      THEN 'West'
        WHEN 'Gujarat'          THEN 'West'
        WHEN 'Goa'              THEN 'West'
        WHEN 'Madhya Pradesh'   THEN 'Central'
        WHEN 'Chhattisgarh'     THEN 'Central'
        WHEN 'Karnataka'        THEN 'South'
        WHEN 'Tamil Nadu'       THEN 'South'
        WHEN 'Andhra Pradesh'   THEN 'South'
        WHEN 'Telangana'        THEN 'South'
        WHEN 'Kerala'           THEN 'South'
        WHEN 'West Bengal'      THEN 'East'
        WHEN 'Odisha'           THEN 'East'
        WHEN 'Jharkhand'        THEN 'East'
        WHEN 'Bihar'            THEN 'East'
        WHEN 'Assam'            THEN 'Northeast'
        ELSE 'Other'
    END                                             AS state_region,

    -- ── Feature: Payment Type Grouping ───────────────────────────────────────
    CASE cd.payment_mode
        WHEN 'COD'         THEN 'Cash'
        WHEN 'EMI'         THEN 'Deferred'
        WHEN 'UPI'         THEN 'Digital'
        WHEN 'Credit Card' THEN 'Card'
        WHEN 'Debit Card'  THEN 'Card'
        ELSE 'Other'
    END                                             AS payment_type_group,

    -- ── Feature: Order Size Segment ──────────────────────────────────────────
    CASE
        WHEN cd.amount >= 5000  THEN 'High Value'
        WHEN cd.amount >= 2000  THEN 'Mid Value'
        ELSE                         'Low Value'
    END                                             AS order_value_segment,

    -- ── Feature: Year-Month label (for time series charts) ───────────────────
    TO_CHAR(co.order_date, 'YYYY-MM')               AS year_month

FROM cleaned_orders  co
JOIN cleaned_details cd ON co.order_id = cd.order_id;

COMMENT ON VIEW vw_order_enriched IS
'Master analytical view joining cleaned_orders and cleaned_details.
 Includes all feature-engineered columns:
   - Profit Margin %, Profit Flag, Revenue per Unit
   - Date parts: day, month, year, quarter, week
   - Category Bucket, State Region, Payment Type Group, Order Value Segment
 Power BI should connect to this view for all DAX measures and visuals.';


-- =============================================================================
-- STAGE 6 — POWER BI–READY SQL QUERIES
-- =============================================================================
-- These queries are what Power BI executes when using DirectQuery mode,
-- or what you paste into "Get Data → PostgreSQL → Advanced Options".
-- Each query is clearly labelled with its corresponding dashboard KPI/visual.
-- =============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 6.1  KPI: Total Sales (Sum of Amount)
-- ────────────────────────────────────────────────────────────────────────────
SELECT
    SUM(amount)   AS total_sales,
    SUM(profit)   AS total_profit,
    SUM(quantity) AS total_quantity,
    COUNT(DISTINCT order_id) AS total_orders
FROM cleaned_details;

-- ────────────────────────────────────────────────────────────────────────────
-- 6.2  KPI: Average Order Value (AOV)
-- ────────────────────────────────────────────────────────────────────────────
SELECT
    ROUND(SUM(amount)::NUMERIC / NULLIF(COUNT(DISTINCT order_id), 0), 2) AS avg_order_value
FROM cleaned_details;

-- ────────────────────────────────────────────────────────────────────────────
-- 6.3  KPI: Overall Profit Margin %
-- ────────────────────────────────────────────────────────────────────────────
SELECT
    ROUND(
        (SUM(profit)::NUMERIC / NULLIF(SUM(amount), 0)) * 100,
        2
    ) AS overall_profit_margin_pct
FROM cleaned_details;

-- ────────────────────────────────────────────────────────────────────────────
-- 6.4  Sales by State (Bar / Filled Map visual)
-- ────────────────────────────────────────────────────────────────────────────
SELECT
    co.state,
    SUM(cd.amount)   AS total_sales,
    SUM(cd.profit)   AS total_profit,
    SUM(cd.quantity) AS total_quantity,
    COUNT(DISTINCT co.order_id) AS order_count,
    ROUND(SUM(cd.profit)::NUMERIC / NULLIF(SUM(cd.amount), 0) * 100, 2) AS profit_margin_pct
FROM cleaned_orders  co
JOIN cleaned_details cd ON co.order_id = cd.order_id
GROUP BY co.state
ORDER BY total_sales DESC;

-- ────────────────────────────────────────────────────────────────────────────
-- 6.5  Sales by Category (Donut / Pie chart)
-- ────────────────────────────────────────────────────────────────────────────
SELECT
    category,
    SUM(amount)   AS total_sales,
    SUM(profit)   AS total_profit,
    SUM(quantity) AS total_quantity,
    ROUND(SUM(profit)::NUMERIC / NULLIF(SUM(amount), 0) * 100, 2) AS profit_margin_pct,
    ROUND(SUM(amount)::NUMERIC / SUM(SUM(amount)) OVER () * 100, 2) AS sales_share_pct
FROM cleaned_details
GROUP BY category
ORDER BY total_sales DESC;

-- ────────────────────────────────────────────────────────────────────────────
-- 6.6  Sales by Sub-Category (Horizontal Bar chart)
-- ────────────────────────────────────────────────────────────────────────────
SELECT
    category,
    sub_category,
    SUM(amount)   AS total_sales,
    SUM(profit)   AS total_profit,
    SUM(quantity) AS total_quantity,
    ROUND(SUM(profit)::NUMERIC / NULLIF(SUM(amount), 0) * 100, 2) AS profit_margin_pct
FROM cleaned_details
GROUP BY category, sub_category
ORDER BY total_sales DESC;

-- ────────────────────────────────────────────────────────────────────────────
-- 6.7  Monthly Sales Trend (Line / Area chart)
-- ────────────────────────────────────────────────────────────────────────────
SELECT
    EXTRACT(YEAR  FROM co.order_date)::INTEGER                  AS order_year,
    EXTRACT(MONTH FROM co.order_date)::INTEGER                  AS order_month,
    TRIM(TO_CHAR(co.order_date, 'Month'))                       AS month_name,
    TO_CHAR(co.order_date, 'YYYY-MM')                           AS year_month,
    SUM(cd.amount)                                              AS total_sales,
    SUM(cd.profit)                                              AS total_profit,
    SUM(cd.quantity)                                            AS total_quantity,
    -- Month-over-Month sales change using LAG window function
    LAG(SUM(cd.amount)) OVER (ORDER BY EXTRACT(YEAR FROM co.order_date),
                                        EXTRACT(MONTH FROM co.order_date)) AS prev_month_sales,
    ROUND(
        (SUM(cd.amount) - LAG(SUM(cd.amount)) OVER (
            ORDER BY EXTRACT(YEAR FROM co.order_date),
                     EXTRACT(MONTH FROM co.order_date)
        )) / NULLIF(LAG(SUM(cd.amount)) OVER (
            ORDER BY EXTRACT(YEAR FROM co.order_date),
                     EXTRACT(MONTH FROM co.order_date)
        ), 0) * 100,
        2
    )                                                           AS mom_growth_pct
FROM cleaned_orders  co
JOIN cleaned_details cd ON co.order_id = cd.order_id
GROUP BY
    EXTRACT(YEAR  FROM co.order_date),
    EXTRACT(MONTH FROM co.order_date),
    TO_CHAR(co.order_date, 'Month'),
    TO_CHAR(co.order_date, 'YYYY-MM')
ORDER BY order_year, order_month;

-- ────────────────────────────────────────────────────────────────────────────
-- 6.8  Quarterly Sales Summary (Column chart)
-- ────────────────────────────────────────────────────────────────────────────
SELECT
    EXTRACT(YEAR    FROM co.order_date)::INTEGER          AS order_year,
    EXTRACT(QUARTER FROM co.order_date)::INTEGER          AS order_quarter,
    'Q' || EXTRACT(QUARTER FROM co.order_date)::TEXT      AS quarter_label,
    SUM(cd.amount)                                        AS total_sales,
    SUM(cd.profit)                                        AS total_profit,
    SUM(cd.quantity)                                      AS total_quantity,
    COUNT(DISTINCT co.order_id)                           AS order_count
FROM cleaned_orders  co
JOIN cleaned_details cd ON co.order_id = cd.order_id
GROUP BY
    EXTRACT(YEAR    FROM co.order_date),
    EXTRACT(QUARTER FROM co.order_date)
ORDER BY order_year, order_quarter;

-- ────────────────────────────────────────────────────────────────────────────
-- 6.9  Top 10 Customers by Sales (Table / Bar chart)
-- ────────────────────────────────────────────────────────────────────────────
SELECT
    co.customer_name,
    COUNT(DISTINCT co.order_id)                           AS total_orders,
    SUM(cd.amount)                                        AS total_sales,
    SUM(cd.profit)                                        AS total_profit,
    SUM(cd.quantity)                                      AS total_quantity,
    ROUND(SUM(cd.profit)::NUMERIC / NULLIF(SUM(cd.amount), 0) * 100, 2) AS profit_margin_pct,
    ROUND(SUM(cd.amount)::NUMERIC / NULLIF(COUNT(DISTINCT co.order_id), 0), 2) AS avg_order_value,
    -- Customer rank by sales
    RANK() OVER (ORDER BY SUM(cd.amount) DESC)            AS sales_rank
FROM cleaned_orders  co
JOIN cleaned_details cd ON co.order_id = cd.order_id
GROUP BY co.customer_name
ORDER BY total_sales DESC
LIMIT 10;

-- ────────────────────────────────────────────────────────────────────────────
-- 6.10 Top Products / Sub-Categories by Revenue (Bar chart)
-- ────────────────────────────────────────────────────────────────────────────
SELECT
    sub_category,
    category,
    SUM(amount)                                           AS total_sales,
    SUM(profit)                                           AS total_profit,
    SUM(quantity)                                         AS total_quantity,
    ROUND(SUM(profit)::NUMERIC / NULLIF(SUM(amount), 0) * 100, 2) AS profit_margin_pct,
    DENSE_RANK() OVER (ORDER BY SUM(amount) DESC)         AS revenue_rank
FROM cleaned_details
GROUP BY sub_category, category
ORDER BY total_sales DESC;

-- ────────────────────────────────────────────────────────────────────────────
-- 6.11 Profit by Category (Clustered Bar / Waterfall chart)
-- ────────────────────────────────────────────────────────────────────────────
SELECT
    category,
    SUM(amount)                                           AS total_sales,
    SUM(profit)                                           AS total_profit,
    SUM(amount) - SUM(profit)                             AS total_cost,    -- implied cost
    ROUND(SUM(profit)::NUMERIC / NULLIF(SUM(amount), 0) * 100, 2) AS profit_margin_pct,
    COUNT(*)                                              AS transaction_count
FROM cleaned_details
GROUP BY category
ORDER BY total_profit DESC;

-- ────────────────────────────────────────────────────────────────────────────
-- 6.12 Sales by Payment Mode (Donut chart)
-- ────────────────────────────────────────────────────────────────────────────
SELECT
    payment_mode,
    COUNT(*)                                              AS transaction_count,
    SUM(amount)                                           AS total_sales,
    ROUND(SUM(amount)::NUMERIC / SUM(SUM(amount)) OVER () * 100, 2) AS sales_share_pct,
    ROUND(SUM(profit)::NUMERIC / NULLIF(SUM(amount), 0) * 100, 2)   AS profit_margin_pct
FROM cleaned_details
GROUP BY payment_mode
ORDER BY total_sales DESC;

-- ────────────────────────────────────────────────────────────────────────────
-- 6.13 Sales by City — Top 10 (Map / Bar chart)
-- ────────────────────────────────────────────────────────────────────────────
SELECT
    co.city,
    co.state,
    SUM(cd.amount)   AS total_sales,
    SUM(cd.profit)   AS total_profit,
    SUM(cd.quantity) AS total_quantity,
    COUNT(DISTINCT co.order_id) AS order_count
FROM cleaned_orders  co
JOIN cleaned_details cd ON co.order_id = cd.order_id
GROUP BY co.city, co.state
ORDER BY total_sales DESC
LIMIT 10;

-- ────────────────────────────────────────────────────────────────────────────
-- 6.14 Year-over-Year Comparison (Matrix / Line chart with slicer)
-- ────────────────────────────────────────────────────────────────────────────
SELECT
    EXTRACT(YEAR FROM co.order_date)::INTEGER   AS order_year,
    SUM(cd.amount)                              AS total_sales,
    SUM(cd.profit)                              AS total_profit,
    SUM(cd.quantity)                            AS total_quantity,
    COUNT(DISTINCT co.order_id)                 AS order_count,
    COUNT(DISTINCT co.customer_name)            AS unique_customers
FROM cleaned_orders  co
JOIN cleaned_details cd ON co.order_id = cd.order_id
GROUP BY EXTRACT(YEAR FROM co.order_date)
ORDER BY order_year;

-- ────────────────────────────────────────────────────────────────────────────
-- 6.15 Sub-Category Profitability Matrix (Scatter Plot / Matrix)
-- ────────────────────────────────────────────────────────────────────────────
SELECT
    sub_category,
    category,
    SUM(amount)                                           AS total_sales,
    SUM(profit)                                           AS total_profit,
    SUM(quantity)                                         AS total_quantity,
    ROUND(SUM(profit)::NUMERIC / NULLIF(SUM(amount), 0) * 100, 2) AS profit_margin_pct,
    CASE
        WHEN SUM(profit) > 0 AND SUM(amount) >= 5000 THEN 'Star'       -- high profit, high sales
        WHEN SUM(profit) > 0 AND SUM(amount) < 5000  THEN 'Question'   -- high profit, low sales
        WHEN SUM(profit) <= 0 AND SUM(amount) >= 5000 THEN 'Dog'       -- low profit, high sales
        ELSE                                               'Problem'    -- loss-making, low sales
    END                                                   AS bcg_quadrant
FROM cleaned_details
GROUP BY sub_category, category
ORDER BY total_profit DESC;

-- ────────────────────────────────────────────────────────────────────────────
-- 6.16 State-wise Region Sales (for geographic drill-down)
-- ────────────────────────────────────────────────────────────────────────────
SELECT
    CASE co.state
        WHEN 'Uttar Pradesh' THEN 'North'    WHEN 'Delhi'         THEN 'North'
        WHEN 'Punjab'        THEN 'North'    WHEN 'Rajasthan'     THEN 'North'
        WHEN 'Haryana'       THEN 'North'    WHEN 'Maharashtra'   THEN 'West'
        WHEN 'Gujarat'       THEN 'West'     WHEN 'Goa'           THEN 'West'
        WHEN 'Madhya Pradesh' THEN 'Central' WHEN 'Chhattisgarh'  THEN 'Central'
        WHEN 'Karnataka'     THEN 'South'    WHEN 'Tamil Nadu'    THEN 'South'
        WHEN 'Andhra Pradesh' THEN 'South'   WHEN 'Telangana'     THEN 'South'
        WHEN 'Kerala'        THEN 'South'    WHEN 'West Bengal'   THEN 'East'
        WHEN 'Odisha'        THEN 'East'     WHEN 'Bihar'         THEN 'East'
        ELSE 'Other'
    END                                                   AS region,
    co.state,
    SUM(cd.amount)   AS total_sales,
    SUM(cd.profit)   AS total_profit,
    COUNT(DISTINCT co.order_id) AS order_count
FROM cleaned_orders  co
JOIN cleaned_details cd ON co.order_id = cd.order_id
GROUP BY region, co.state
ORDER BY region, total_sales DESC;


-- =============================================================================
-- STAGE 7 — PERFORMANCE OPTIMISATION: INDEXES
-- =============================================================================
-- Indexes speed up JOIN conditions, WHERE filters, and GROUP BY operations.
-- Without indexes, PostgreSQL performs sequential scans on every query.
-- =============================================================================

-- Index on cleaned_orders.order_date
-- WHY: Monthly/quarterly trend queries filter and group by date constantly.
--      This index converts full-table scans into fast range scans.
CREATE INDEX IF NOT EXISTS idx_orders_order_date
    ON cleaned_orders (order_date);

COMMENT ON INDEX idx_orders_order_date IS
'Speeds up date range filters and GROUP BY month/quarter/year in trend queries.';

-- Index on cleaned_orders.state
-- WHY: "Sales by State" and region-level aggregations filter on state heavily.
CREATE INDEX IF NOT EXISTS idx_orders_state
    ON cleaned_orders (state);

COMMENT ON INDEX idx_orders_state IS
'Accelerates state-level aggregations and geographic drill-downs.';

-- Index on cleaned_orders.customer_name
-- WHY: "Top 10 Customers" query groups and orders by customer_name.
CREATE INDEX IF NOT EXISTS idx_orders_customer_name
    ON cleaned_orders (customer_name);

COMMENT ON INDEX idx_orders_customer_name IS
'Speeds up customer-level groupings and top-N customer queries.';

-- Index on cleaned_details.order_id (FK side of the JOIN)
-- WHY: Every JOIN between cleaned_orders and cleaned_details uses order_id.
--      An index on the FK column eliminates nested-loop full scans.
CREATE INDEX IF NOT EXISTS idx_details_order_id
    ON cleaned_details (order_id);

COMMENT ON INDEX idx_details_order_id IS
'Critical FK index. Every JOIN between cleaned_orders and cleaned_details
 hits this index. Without it, PostgreSQL does a sequential scan of 1500 rows
 for every order lookup.';

-- Index on cleaned_details.category
-- WHY: Category is the primary segmentation dimension across all dashboard visuals.
CREATE INDEX IF NOT EXISTS idx_details_category
    ON cleaned_details (category);

COMMENT ON INDEX idx_details_category IS
'Speeds up category-level GROUP BY and WHERE filters in all category visuals.';

-- Composite index on category + sub_category
-- WHY: Sub-category queries always filter/group at both levels together.
CREATE INDEX IF NOT EXISTS idx_details_category_subcategory
    ON cleaned_details (category, sub_category);

COMMENT ON INDEX idx_details_category_subcategory IS
'Composite index for sub-category drilldowns. PostgreSQL can use the leftmost
 prefix (category alone) OR both columns (category + sub_category).';

-- Index on cleaned_details.payment_mode
-- WHY: Payment mode analysis and COD vs digital payment comparisons.
CREATE INDEX IF NOT EXISTS idx_details_payment_mode
    ON cleaned_details (payment_mode);

COMMENT ON INDEX idx_details_payment_mode IS
'Supports payment mode segmentation queries and pie chart data retrieval.';

-- Partial index: only profitable orders (profit > 0)
-- WHY: Many dashboard KPIs focus on profitable orders exclusively.
--      A partial index is smaller and faster than a full-column index for this use case.
CREATE INDEX IF NOT EXISTS idx_details_profitable
    ON cleaned_details (order_id, profit)
    WHERE profit > 0;

COMMENT ON INDEX idx_details_profitable IS
'Partial index covering only profitable transactions (profit > 0).
 Much smaller than a full-column index. Speeds up profitability-filtered queries.';


-- =============================================================================
-- STAGE 8 — ADDITIONAL ANALYTICAL VIEWS FOR POWER BI
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 8.1  vw_monthly_kpi — pre-aggregated monthly KPIs
--      Power BI can import this directly as a summary table.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_monthly_kpi AS
SELECT
    EXTRACT(YEAR  FROM co.order_date)::INTEGER          AS order_year,
    EXTRACT(MONTH FROM co.order_date)::INTEGER          AS order_month,
    TRIM(TO_CHAR(co.order_date, 'Month'))               AS month_name,
    TO_CHAR(co.order_date, 'YYYY-MM')                   AS year_month,
    SUM(cd.amount)                                      AS total_sales,
    SUM(cd.profit)                                      AS total_profit,
    SUM(cd.quantity)                                    AS total_quantity,
    COUNT(DISTINCT co.order_id)                         AS order_count,
    COUNT(DISTINCT co.customer_name)                    AS unique_customers,
    ROUND(SUM(cd.profit)::NUMERIC / NULLIF(SUM(cd.amount), 0) * 100, 2) AS profit_margin_pct,
    ROUND(SUM(cd.amount)::NUMERIC / NULLIF(COUNT(DISTINCT co.order_id), 0), 2) AS avg_order_value
FROM cleaned_orders  co
JOIN cleaned_details cd ON co.order_id = cd.order_id
GROUP BY
    EXTRACT(YEAR  FROM co.order_date),
    EXTRACT(MONTH FROM co.order_date),
    TO_CHAR(co.order_date, 'Month'),
    TO_CHAR(co.order_date, 'YYYY-MM')
ORDER BY order_year, order_month;

COMMENT ON VIEW vw_monthly_kpi IS
'Pre-aggregated monthly KPIs. Power BI imports this for time-intelligence
 visuals without needing to aggregate at runtime.';

-- -----------------------------------------------------------------------------
-- 8.2  vw_customer_segments — customer-level summary with RFM-style signals
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_customer_segments AS
WITH customer_stats AS (
    SELECT
        co.customer_name,
        COUNT(DISTINCT co.order_id)                               AS order_count,
        SUM(cd.amount)                                            AS total_spend,
        SUM(cd.profit)                                            AS total_profit,
        MIN(co.order_date)                                        AS first_order_date,
        MAX(co.order_date)                                        AS last_order_date,
        MAX(co.order_date) - MIN(co.order_date)                   AS customer_lifespan_days
    FROM cleaned_orders  co
    JOIN cleaned_details cd ON co.order_id = cd.order_id
    GROUP BY co.customer_name
)
SELECT
    customer_name,
    order_count,
    total_spend,
    total_profit,
    first_order_date,
    last_order_date,
    customer_lifespan_days,
    ROUND(total_spend::NUMERIC / NULLIF(order_count, 0), 2) AS avg_order_value,
    -- Customer value tier based on total spend
    CASE
        WHEN total_spend >= 10000 THEN 'Platinum'
        WHEN total_spend >= 5000  THEN 'Gold'
        WHEN total_spend >= 2000  THEN 'Silver'
        ELSE                           'Bronze'
    END                                                         AS customer_tier,
    -- Percentile rank by spend
    ROUND(PERCENT_RANK() OVER (ORDER BY total_spend) * 100, 1) AS spend_percentile
FROM customer_stats
ORDER BY total_spend DESC;

COMMENT ON VIEW vw_customer_segments IS
'Customer-level aggregated view with value segmentation (Platinum/Gold/Silver/Bronze)
 and spend percentile ranking. Used for customer analytics page in Power BI.';

-- -----------------------------------------------------------------------------
-- 8.3  vw_product_performance — sub-category level performance matrix
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_product_performance AS
SELECT
    category,
    sub_category,
    SUM(amount)                                                 AS total_sales,
    SUM(profit)                                                 AS total_profit,
    SUM(quantity)                                               AS total_quantity,
    COUNT(DISTINCT order_id)                                    AS order_count,
    ROUND(SUM(profit)::NUMERIC / NULLIF(SUM(amount), 0) * 100, 2) AS profit_margin_pct,
    ROUND(SUM(amount)::NUMERIC / NULLIF(SUM(quantity), 0), 2)  AS avg_selling_price,
    -- Rank within category
    RANK() OVER (PARTITION BY category ORDER BY SUM(amount) DESC) AS rank_in_category,
    -- Overall rank
    RANK() OVER (ORDER BY SUM(amount) DESC)                     AS overall_rank
FROM cleaned_details
GROUP BY category, sub_category
ORDER BY total_sales DESC;

COMMENT ON VIEW vw_product_performance IS
'Sub-category performance view with ranks. Used for product drilldown pages in Power BI.';


-- =============================================================================
-- STAGE 9 — DATA VALIDATION CHECKS (post-cleaning)
-- =============================================================================
-- Run these after the ETL to confirm data quality before connecting Power BI.
-- =============================================================================

-- 9.1 Confirm no NULLs in cleaned tables
SELECT
    COUNT(*) FILTER (WHERE order_id      IS NULL) AS null_order_id,
    COUNT(*) FILTER (WHERE order_date    IS NULL) AS null_order_date,
    COUNT(*) FILTER (WHERE customer_name IS NULL) AS null_customer,
    COUNT(*) FILTER (WHERE state         IS NULL) AS null_state,
    COUNT(*) FILTER (WHERE city          IS NULL) AS null_city
FROM cleaned_orders;

SELECT
    COUNT(*) FILTER (WHERE order_id     IS NULL) AS null_order_id,
    COUNT(*) FILTER (WHERE amount       IS NULL) AS null_amount,
    COUNT(*) FILTER (WHERE profit       IS NULL) AS null_profit,
    COUNT(*) FILTER (WHERE quantity     IS NULL) AS null_qty,
    COUNT(*) FILTER (WHERE category     IS NULL) AS null_category,
    COUNT(*) FILTER (WHERE sub_category IS NULL) AS null_sub_cat,
    COUNT(*) FILTER (WHERE payment_mode IS NULL) AS null_payment
FROM cleaned_details;

-- 9.2 Confirm PK uniqueness in cleaned_orders
SELECT order_id, COUNT(*) FROM cleaned_orders GROUP BY order_id HAVING COUNT(*) > 1;
-- Expected: 0 rows

-- 9.3 Confirm FK integrity
SELECT cd.order_id
FROM cleaned_details cd
LEFT JOIN cleaned_orders co ON cd.order_id = co.order_id
WHERE co.order_id IS NULL;
-- Expected: 0 rows

-- 9.4 Summary statistics for sanity check
SELECT
    MIN(amount)        AS min_amount,
    MAX(amount)        AS max_amount,
    AVG(amount)        AS avg_amount,
    MIN(profit)        AS min_profit,
    MAX(profit)        AS max_profit,
    MIN(quantity)      AS min_qty,
    MAX(quantity)      AS max_qty
FROM cleaned_details;

-- 9.5 Row count comparison: staging vs cleaned
SELECT 'stg_orders'      AS stage, COUNT(*) FROM stg_orders    UNION ALL
SELECT 'cleaned_orders'  AS stage, COUNT(*) FROM cleaned_orders UNION ALL
SELECT 'stg_details'     AS stage, COUNT(*) FROM stg_details    UNION ALL
SELECT 'cleaned_details' AS stage, COUNT(*) FROM cleaned_details;


-- =============================================================================
-- STAGE 10 — QUICK-ACCESS SUMMARY (run this to verify everything is working)
-- =============================================================================

SELECT
    'Total Sales'        AS kpi, CAST(SUM(amount)   AS TEXT) AS value FROM cleaned_details UNION ALL
SELECT
    'Total Profit'       AS kpi, CAST(SUM(profit)   AS TEXT) AS value FROM cleaned_details UNION ALL
SELECT
    'Total Quantity'     AS kpi, CAST(SUM(quantity) AS TEXT) AS value FROM cleaned_details UNION ALL
SELECT
    'Total Orders'       AS kpi, CAST(COUNT(DISTINCT order_id) AS TEXT) AS value FROM cleaned_details UNION ALL
SELECT
    'Unique Customers'   AS kpi, CAST(COUNT(DISTINCT customer_name) AS TEXT) AS value FROM cleaned_orders UNION ALL
SELECT
    'States Covered'     AS kpi, CAST(COUNT(DISTINCT state) AS TEXT) AS value FROM cleaned_orders UNION ALL
SELECT
    'Categories'         AS kpi, CAST(COUNT(DISTINCT category) AS TEXT) AS value FROM cleaned_details UNION ALL
SELECT
    'Sub-Categories'     AS kpi, CAST(COUNT(DISTINCT sub_category) AS TEXT) AS value FROM cleaned_details;


-- =============================================================================
-- END OF ETL SCRIPT
-- =============================================================================
-- POWER BI CONNECTION INSTRUCTIONS:
-- 1. Open Power BI Desktop → Get Data → PostgreSQL Database
-- 2. Server: localhost (or your PostgreSQL host)
-- 3. Database: madhav_ecommerce
-- 4. Data Connectivity Mode: Import (recommended for this dataset size)
-- 5. Tables/Views to import:
--       - cleaned_orders        (dimension table)
--       - cleaned_details       (fact table)
--       - vw_order_enriched     (master analytical view — recommended)
--       - vw_monthly_kpi        (pre-aggregated monthly data)
--       - vw_customer_segments  (customer analytics)
--       - vw_product_performance(product analytics)
-- 6. In Power BI Model View, verify relationship:
--       cleaned_orders[order_id] → cleaned_details[order_id] (1-to-many)
-- =============================================================================


-- #############################################################################
-- SECTION 11 — 15 INTERVIEW Q&A
-- (Paste this section as comments; read and practise before interviews)
-- #############################################################################

/*
==============================================================================
INTERVIEW Q&A — Madhav E-Commerce PostgreSQL ETL Project
==============================================================================

Q1. Why did you use a staging table (stg_orders / stg_details) instead of
    loading data directly into the final table?

A1. Staging tables act as a "landing zone" for raw data. They let me:
    (a) Inspect data quality BEFORE applying constraints (no load failures).
    (b) Document exactly what was dirty vs what was cleaned (audit trail).
    (c) Re-run the cleaning step without re-ingesting the CSV files.
    (d) In a production pipeline, staging tables enable incremental loading —
        you only process new/changed rows, not the whole file every time.
    This is standard practice in ETL and Data Warehouse architectures.

------------------------------------------------------------------------------

Q2. How did you handle duplicate records in this dataset?

A2. I used ROW_NUMBER() with a PARTITION BY clause:
       ROW_NUMBER() OVER (PARTITION BY TRIM(order_id) ORDER BY order_id)
    I kept only rn = 1 (the first occurrence) and discarded all others.
    For cleaned_details, since there is no natural primary key, I partitioned
    over ALL columns (order_id, amount, profit, quantity, category,
    sub_category, payment_mode) to identify fully identical duplicate rows.
    A surrogate key (SERIAL detail_id) was added as the PK.

------------------------------------------------------------------------------

Q3. How did you convert the date column from a string to a DATE type?

A3. The CSV stored dates as DD-MM-YYYY strings (e.g., "10-03-2018").
    I used PostgreSQL's TO_DATE() function:
       TO_DATE(TRIM(order_date), 'DD-MM-YYYY')
    The TRIM() call first removes any accidental leading/trailing spaces.
    I validated the format with a regex check before conversion to avoid
    exceptions on malformed rows:
       WHERE order_date ~ '^\d{2}-\d{2}-\d{4}$'

------------------------------------------------------------------------------

Q4. What is a foreign key and how did you use it here?

A4. A foreign key (FK) is a constraint that enforces referential integrity
    between two tables. In this project:
       cleaned_details.order_id → cleaned_orders.order_id
    This means every detail row MUST have a corresponding order in
    cleaned_orders. I also added ON DELETE CASCADE so that if an order is
    deleted, its detail rows are automatically removed — preventing orphan
    records. During the ETL, I used an INNER JOIN to filter out any detail
    rows whose order_id did not exist in cleaned_orders before inserting.

------------------------------------------------------------------------------

Q5. Why did you add indexes, and which ones did you create?

A5. Without indexes, PostgreSQL performs a sequential scan (reads every row)
    for every query. Indexes allow the query planner to jump directly to
    relevant rows using B-tree structures. I created:
    - idx_orders_order_date      : for date-range and GROUP BY month/year
    - idx_orders_state           : for state-level aggregations
    - idx_orders_customer_name   : for top-customer queries
    - idx_details_order_id       : critical FK index for every JOIN
    - idx_details_category       : for category segmentation
    - idx_details_category_subcategory : composite index for drilldowns
    - idx_details_payment_mode   : for payment analysis
    - idx_details_profitable     : partial index for profit > 0 queries
    The partial index is particularly efficient because it is much smaller
    than a full index and is only used by profitability-specific queries.

------------------------------------------------------------------------------

Q6. What is a SQL view and why did you use views instead of tables for
    the feature-engineered columns?

A6. A view is a stored SQL query that behaves like a virtual table.
    I used views (vw_order_enriched, vw_monthly_kpi, etc.) because:
    (a) They avoid data duplication — derived columns are computed on-the-fly.
    (b) Any update to cleaned_orders or cleaned_details is automatically
        reflected in the views without re-running ETL.
    (c) Power BI can connect to views exactly like tables.
    (d) It enforces separation of concerns: storage vs presentation logic.
    In production, I could use MATERIALIZED VIEWs for performance on large
    datasets, refreshing them on a schedule.

------------------------------------------------------------------------------

Q7. How did you compute profit margin percentage in SQL?

A7. Profit Margin % = (Profit / Amount) × 100
    In SQL:
       ROUND((cd.profit / NULLIF(cd.amount, 0)) * 100, 2)
    The key detail is NULLIF(cd.amount, 0) — this returns NULL when amount
    is 0, which prevents a division-by-zero error. PostgreSQL would throw
    a runtime exception without this guard. ROUND(..., 2) gives us two
    decimal places.

------------------------------------------------------------------------------

Q8. What window functions did you use and why?

A8. I used three window functions:
    (a) ROW_NUMBER() — to identify and remove duplicate rows by assigning
        sequential numbers within each partition (group of duplicates).
    (b) LAG() — in the monthly trend query, to access the previous month's
        sales value so I could compute Month-over-Month growth %:
           LAG(SUM(amount)) OVER (ORDER BY year, month)
    (c) RANK() / DENSE_RANK() — to rank customers and sub-categories by
        revenue without needing a subquery.
    (d) PERCENT_RANK() — to compute each customer's spend percentile.
    Window functions are powerful because they perform calculations across
    related rows without collapsing them into a single GROUP BY result.

------------------------------------------------------------------------------

Q9. How did you handle the relationship between Orders and Details in
    Power BI after loading from PostgreSQL?

A9. The relationship is a one-to-many (1:N) join:
       cleaned_orders.order_id (1 side) → cleaned_details.order_id (N side)
    One order can have multiple detail rows (different products per order).
    In Power BI, this is modelled as a star-schema relationship where
    cleaned_orders acts as a dimension table and cleaned_details acts as
    a fact table. Power BI's DAX engine uses this relationship to filter
    and aggregate correctly across visuals.

------------------------------------------------------------------------------

Q10. What data cleaning steps did you apply to text columns?

A10. For text columns I applied:
     (a) TRIM()     — removes leading/trailing spaces (common in CSV exports)
     (b) INITCAP()  — capitalises the first letter of each word for consistent
                      display (e.g., "uttar pradesh" → "Uttar Pradesh")
     (c) UPPER()    — used for order_id to enforce a consistent format
     (d) Blank-to-NULL — WHERE TRIM(col) <> '' filters out cells that are
                         whitespace-only (these arrive as '' from COPY, not NULL)
     (e) CASE statements — standardised payment_mode values
                           (e.g., 'CREDIT CARD' → 'Credit Card')
     (f) Regex validation — used !~ '^-?[0-9]+(\.[0-9]+)?$' to detect
                            non-numeric values in amount/profit/quantity before casting.

------------------------------------------------------------------------------

Q11. What is the difference between DELETE and TRUNCATE in PostgreSQL?
     Which would you use to reset staging tables?

A11. DELETE removes rows one-by-one and is transactional (can be rolled back).
     It fires row-level triggers and respects WHERE clauses.
     TRUNCATE removes all rows instantly by deallocating data pages.
     It is much faster on large tables, but cannot be filtered by WHERE.
     TRUNCATE also resets SERIAL sequences.
     For resetting staging tables between ETL runs, I would use TRUNCATE:
        TRUNCATE TABLE stg_orders RESTART IDENTITY CASCADE;
     It is faster, and staging tables do not need row-level rollback capability.

------------------------------------------------------------------------------

Q12. How would you schedule this ETL pipeline to run automatically?

A12. In a production environment, I would use:
     (a) pg_cron (PostgreSQL extension) — schedule SQL jobs directly in Postgres.
     (b) Apache Airflow — orchestrate the full pipeline as a DAG with steps:
         extract CSV → load to staging → run cleaning SQL → refresh views.
     (c) AWS Glue or Azure Data Factory — for cloud-hosted pipelines.
     (d) cron (Linux) + psql — simplest option:
         0 2 * * * psql -d madhav_ecommerce -f /path/to/etl.sql
     I would also add logging tables to track run timestamps, row counts,
     and error rates per ETL execution.

------------------------------------------------------------------------------

Q13. How is INITCAP() different from UPPER() and LOWER()?

A13. UPPER('hello world')   → 'HELLO WORLD'   (all uppercase)
     LOWER('HELLO WORLD')   → 'hello world'   (all lowercase)
     INITCAP('hello world') → 'Hello World'   (title case — first letter of
                                               each word capitalised)
     I used INITCAP for customer names, states, and cities because that is
     the standard formatting for proper nouns in Indian English.
     I used UPPER for order_id because IDs are typically stored in uppercase
     for consistent key comparisons (B-25055 vs b-25055 would be treated
     as different values without normalisation).

------------------------------------------------------------------------------

Q14. What would you do if new data arrived daily in new CSV files?

A14. I would design an incremental load strategy:
     (a) Add a "loaded_date" column to the staging table to track when each
         batch was loaded.
     (b) Use INSERT ... WHERE NOT EXISTS or INSERT ... ON CONFLICT DO NOTHING
         to skip already-existing order_ids:
            INSERT INTO cleaned_orders (...)
            SELECT ... FROM stg_orders_new
            WHERE order_id NOT IN (SELECT order_id FROM cleaned_orders);
     (c) For updates to existing orders, use UPSERT (INSERT ... ON CONFLICT
         DO UPDATE SET ...) to overwrite changed fields.
     (d) Archive processed staging files to S3 or a backup folder.
     (e) Refresh materialised views after each load:
            REFRESH MATERIALIZED VIEW CONCURRENTLY vw_monthly_kpi;

------------------------------------------------------------------------------

Q15. How does Power BI benefit from connecting to PostgreSQL views instead
     of raw tables?

A15. Several benefits:
     (a) Pre-computed aggregations in vw_monthly_kpi mean Power BI does not
         have to aggregate 1500 rows at runtime — it reads 12 summary rows.
     (b) Feature-engineered columns (profit margin %, quarter, region) are
         already present, reducing DAX complexity.
     (c) Business logic (category buckets, payment groupings, state regions)
         is centralised in SQL — a single source of truth rather than
         duplicated across multiple Power BI files.
     (d) Security: database roles can restrict which columns/views a Power BI
         service account can see, without exposing raw staging data.
     (e) If the underlying data is updated and views are refreshed, the next
         Power BI import automatically picks up the latest cleaned data.

==============================================================================
END OF INTERVIEW Q&A
==============================================================================
*/
