-- =====================================================================
-- Gold Foundational Fact F1 — gold_order_line_economics
-- =====================================================================
-- Grain      : one row per order line (fact_orders row).      [PK order_line_id]
-- Purpose    : Materialize per-order-line ECONOMICS exactly once so the
--              listing / category / seller marts never re-derive them
--              (CLAUDE.md: "No duplicated business logic").
-- Metrics    : gross_margin (derived_only:false) + rto_rate classification
--              inputs, per config/metrics.yaml. See docs/gold_data_model.md §F1.
-- Golden Rules: Rule 2 — RTO is read only from order_status; it is a
--              classification here, never mixed into a return metric.
-- Dialect    : DuckDB. Run order: standalone (reads Silver only).
--   Execute from repo root, e.g.:
--     duckdb gold.duckdb ".read sql/gold/01_gold_order_line_economics.sql"
-- NOT computed here (later phases): LQS, Recoverable Profit.
-- =====================================================================

-- ---- SOURCE BINDINGS (Silver, read-only views) ----------------------
CREATE OR REPLACE VIEW silver_fact_orders AS
  SELECT * FROM read_csv_auto('data/02_silver/fact_orders.csv');
CREATE OR REPLACE VIEW silver_dim_listing AS
  SELECT * FROM read_csv_auto('data/02_silver/dim_listing.csv');
CREATE OR REPLACE VIEW silver_dim_geography AS
  SELECT * FROM read_csv_auto('data/02_silver/dim_geography.csv');
CREATE OR REPLACE VIEW silver_ref_category_economics AS
  SELECT * FROM read_csv_auto('data/02_silver/ref_category_economics.csv');
CREATE OR REPLACE VIEW silver_ref_logistics_rate_card AS
  SELECT * FROM read_csv_auto('data/02_silver/ref_logistics_rate_card.csv');

-- ---- BUILD ----------------------------------------------------------
CREATE OR REPLACE TABLE gold_order_line_economics AS
WITH
-- Category-median weight, used as the documented fallback for the 239
-- listings flagged dq_missing_item_weight_kg (metrics.yaml: weight_band_map).
category_weight_fallback AS (
    SELECT category, median(item_weight_kg) AS median_weight_kg
    FROM silver_dim_listing
    GROUP BY category
),

-- Enrich each listing with its effective weight and rate-card weight band.
-- Effective weight = actual, else category median. All Silver weights are
-- <= 15kg so the top band ('5-15kg') is the ELSE branch (no >15kg items).
listing_enriched AS (
    SELECT
        l.listing_id,
        l.category,
        COALESCE(l.item_weight_kg, f.median_weight_kg) AS weight_kg_effective,
        CASE
            WHEN COALESCE(l.item_weight_kg, f.median_weight_kg) <= 0.5 THEN '<=0.5kg'
            WHEN COALESCE(l.item_weight_kg, f.median_weight_kg) <= 2   THEN '0.5-2kg'
            WHEN COALESCE(l.item_weight_kg, f.median_weight_kg) <= 5   THEN '2-5kg'
            ELSE '5-15kg'
        END AS weight_band,
        l.dq_missing_item_weight_kg AS weight_is_fallback
    FROM silver_dim_listing l
    LEFT JOIN category_weight_fallback f USING (category)
),

-- Join orders to listing (category, weight band), geography (logistics zone)
-- and category economics (gross margin ratio); derive classification flags
-- and the delivered-only gross margin.
orders_enriched AS (
    SELECT
        o.order_line_id,
        o.order_id,
        o.listing_id,
        o.seller_id,
        o.geo_id,
        le.category,
        o.order_date_key,
        o.payment_method,
        o.order_status,
        o.quantity,
        o.unit_selling_price,
        o.item_discount_amount,
        g.logistics_zone,
        le.weight_band,
        le.weight_is_fallback,
        ce.gross_margin_pct,
        ce.warehouse_handling_cost_aed,
        o.promised_delivery_date_key,
        o.actual_delivery_date_key,
        o.delivery_attempts,
        o.dq_out_of_range_quantity AS is_quantity_invalid,

        -- Order-status classification (Golden Rule 2: RTO lives only here).
        (o.order_status = 'delivered')                                     AS is_delivered,
        (o.order_status IN ('rto_customer_refused','rto_unreachable'))     AS is_rto,
        (o.order_status = 'cancelled_pre_shipment')                        AS is_cancelled,
        (o.order_status <> 'cancelled_pre_shipment')                       AS is_shipped,
        (o.payment_method = 'cod')                                         AS is_cod,

        -- Revenue is recognized ONLY on delivered lines, and invalid
        -- quantities (dq_out_of_range_quantity) are excluded from margin
        -- (NULL rolls up cleanly under SUM). metrics.yaml: gross_margin.
        CASE
            WHEN o.order_status = 'delivered' AND NOT o.dq_out_of_range_quantity
            THEN o.quantity * o.unit_selling_price - o.item_discount_amount
        END AS realized_net_revenue_aed
    FROM silver_fact_orders o
    LEFT JOIN listing_enriched le              ON o.listing_id = le.listing_id
    LEFT JOIN silver_dim_geography g           ON o.geo_id     = g.geo_id
    LEFT JOIN silver_ref_category_economics ce ON le.category  = ce.category
),

-- Attach the forward-leg logistics cost, used only to cost RTO lines
-- (a failed delivery still incurs the forward leg + handling).
rto_costed AS (
    SELECT
        oe.*,
        rc_fwd.cost_aed AS forward_leg_cost_aed,
        -- On-time only meaningful for delivered lines (actual is non-null then).
        (oe.is_delivered
             AND oe.actual_delivery_date_key <= oe.promised_delivery_date_key) AS is_on_time
    FROM orders_enriched oe
    LEFT JOIN silver_ref_logistics_rate_card rc_fwd
        ON  rc_fwd.logistics_zone = oe.logistics_zone
        AND rc_fwd.weight_band    = oe.weight_band
        AND rc_fwd.leg            = 'forward'
)

SELECT
    order_line_id,
    order_id,
    listing_id,
    seller_id,
    geo_id,
    category,
    order_date_key,
    payment_method,
    order_status,
    quantity,
    unit_selling_price,
    item_discount_amount,
    -- Order-line attributes reused DOWNSTREAM by F2 (return economics) so the
    -- zone / weight-band derivation is defined here once, not repeated.
    logistics_zone,
    weight_band,
    weight_is_fallback,
    gross_margin_pct,
    -- Economics.
    realized_net_revenue_aed,
    ROUND(realized_net_revenue_aed * gross_margin_pct, 4) AS gross_margin_aed,
    -- Classification flags.
    is_delivered,
    is_shipped,
    is_rto,
    is_cancelled,
    is_cod,
    is_quantity_invalid,
    -- Delivery performance (feeds trust_score later).
    promised_delivery_date_key,
    actual_delivery_date_key,
    delivery_attempts,
    is_on_time,
    -- RTO economics: forward leg + category handling, ONLY for RTO lines.
    CASE WHEN is_rto THEN forward_leg_cost_aed ELSE 0 END           AS rto_forward_cost_aed,
    CASE WHEN is_rto THEN warehouse_handling_cost_aed ELSE 0 END    AS rto_handling_cost_aed,
    CASE WHEN is_rto THEN ROUND(forward_leg_cost_aed + warehouse_handling_cost_aed, 4)
         ELSE 0 END                                                AS rto_cost_aed
FROM rto_costed;

-- =====================================================================
-- VALIDATION QUERIES  (each returns check | value | pass)
-- =====================================================================
-- V1 Row count preserved vs Silver fact_orders (expect 85,000).
SELECT 'row_count' AS check, COUNT(*) AS value, COUNT(*) = 85000 AS pass
FROM gold_order_line_economics;

-- V2 Primary key is unique & non-null.
SELECT 'pk_unique' AS check, COUNT(*) AS value,
       COUNT(*) = COUNT(DISTINCT order_line_id) AND COUNT(order_line_id) = COUNT(*) AS pass
FROM gold_order_line_economics;

-- V3 Status classification reconciles to the known Silver distribution.
SELECT 'status_reconciliation' AS check, NULL AS value,
       SUM(is_delivered::INT) = 74780
   AND SUM(is_rto::INT)       = 8096
   AND SUM(is_cancelled::INT) = 2124
   AND SUM(is_shipped::INT)   = 82876 AS pass
FROM gold_order_line_economics;

-- V4 Gross margin exists ONLY for delivered lines (revenue recognition).
SELECT 'margin_delivered_only' AS check,
       COUNT(*) FILTER (WHERE gross_margin_aed IS NOT NULL AND NOT is_delivered) AS value,
       COUNT(*) FILTER (WHERE gross_margin_aed IS NOT NULL AND NOT is_delivered) = 0 AS pass
FROM gold_order_line_economics;

-- V5 Invalid quantities (quantity = -1) are excluded from margin.
SELECT 'invalid_qty_excluded' AS check,
       COUNT(*) FILTER (WHERE is_quantity_invalid AND gross_margin_aed IS NOT NULL) AS value,
       COUNT(*) FILTER (WHERE is_quantity_invalid AND gross_margin_aed IS NOT NULL) = 0 AS pass
FROM gold_order_line_economics;

-- V6 Gross margin ratio and revenue are within valid bounds.
SELECT 'margin_pct_and_revenue_bounds' AS check, NULL AS value,
       MIN(gross_margin_pct) >= 0 AND MAX(gross_margin_pct) <= 1
   AND COALESCE(MIN(realized_net_revenue_aed), 0) >= 0 AS pass
FROM gold_order_line_economics;

-- V7 RTO cost is charged ONLY to RTO lines and is strictly positive there.
SELECT 'rto_cost_scoped' AS check,
       COUNT(*) FILTER (WHERE rto_cost_aed > 0 AND NOT is_rto) AS value,
       COUNT(*) FILTER (WHERE rto_cost_aed > 0 AND NOT is_rto) = 0
   AND COUNT(*) FILTER (WHERE is_rto AND rto_cost_aed <= 0)    = 0 AS pass
FROM gold_order_line_economics;

-- V8 Every order line resolved its economics dimensions (no broken joins).
SELECT 'no_unresolved_dimensions' AS check,
       COUNT(*) FILTER (WHERE category IS NULL OR gross_margin_pct IS NULL
                           OR logistics_zone IS NULL OR weight_band IS NULL) AS value,
       COUNT(*) FILTER (WHERE category IS NULL OR gross_margin_pct IS NULL
                           OR logistics_zone IS NULL OR weight_band IS NULL) = 0 AS pass
FROM gold_order_line_economics;
