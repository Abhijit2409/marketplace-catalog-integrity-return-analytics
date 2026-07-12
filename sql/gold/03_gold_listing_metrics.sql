-- =====================================================================
-- Gold Entity Mart 1 — gold_listing_metrics
-- =====================================================================
-- Grain      : one row per listing (all 10,000 dim_listing rows).  [PK listing_id]
-- Purpose    : Listing-level catalog & profitability scorecard and the atomic
--              prioritization unit. Birthplace of Listing Quality Score (LQS)
--              and Recoverable Profit. Everything else is AGGREGATED from the
--              foundational facts — no per-line economics are re-derived here
--              (CLAUDE.md: "No duplicated business logic").
-- Inputs     : gold_order_line_economics (F1), gold_return_line_economics (F2),
--              silver dim_listing (catalog attributes for LQS),
--              silver ref_category_economics (category margin for Recoverable Profit).
-- Metrics    : listing_quality_score, gross_margin, return_cost, recovery_rate,
--              catalog_return_rate, net_margin_after_returns, recoverable_profit,
--              rto_rate + observable trust_score inputs (config/metrics.yaml).
-- Golden Rules: R1 — LQS & Recoverable Profit are DERIVED-ONLY, born here.
--              R2 — RTO measured from order status; net_margin_after_returns
--              EXCLUDES RTO; return metrics use delivered-only denominators.
-- Dialect    : DuckDB. Run order: AFTER 01_ and 02_ (reads their tables).
-- Zero-activity listings are retained: 0/NULL activity but a COMPUTED LQS,
-- because a low-LQS, low-traffic listing is itself actionable.
-- =====================================================================

-- ---- SOURCE BINDINGS (Silver, read-only; idempotent) ----------------
CREATE OR REPLACE VIEW silver_dim_listing AS
  SELECT * FROM read_csv_auto('data/02_silver/dim_listing.csv');
CREATE OR REPLACE VIEW silver_ref_category_economics AS
  SELECT * FROM read_csv_auto('data/02_silver/ref_category_economics.csv');

-- ---- BUILD ----------------------------------------------------------
CREATE OR REPLACE TABLE gold_listing_metrics AS
WITH
-- ===================================================================
-- LISTING QUALITY SCORE (LQS)  — metrics.yaml parameters.listing_quality_score
-- ===================================================================
-- Step 1: the DEFAULT weight vector (mirrors config; keep in sync).
signal_default(signal, w) AS (
    VALUES
        ('image_sufficiency',          0.20),
        ('has_video',                  0.10),
        ('title_adequacy',             0.10),
        ('description_adequacy',       0.15),
        ('specifications_filled_pct',  0.20),
        ('has_size_chart',             0.10),
        ('has_dimensions_listed',      0.05),
        ('variant_sufficiency',        0.10)
),

lqs_categories(category) AS (SELECT DISTINCT category FROM silver_dim_listing),

-- Step 2: apply the category_overrides on top of the defaults.
lqs_weight_raw AS (
    SELECT
        c.category,
        d.signal,
        CASE
            WHEN c.category = 'Fashion'     AND d.signal = 'has_size_chart'            THEN 0.25
            WHEN c.category = 'Fashion'     AND d.signal = 'specifications_filled_pct' THEN 0.10
            WHEN c.category = 'Home'        AND d.signal = 'has_dimensions_listed'     THEN 0.20
            WHEN c.category = 'Home'        AND d.signal = 'has_size_chart'            THEN 0.00
            WHEN c.category = 'Electronics' AND d.signal = 'specifications_filled_pct' THEN 0.30
            WHEN c.category = 'Electronics' AND d.signal = 'has_size_chart'            THEN 0.00
            ELSE d.w
        END AS raw_w
    FROM lqs_categories c
    CROSS JOIN signal_default d
),

-- Step 3: RENORMALIZE so each category's weights sum to exactly 1.0
-- (overrides make Fashion & Home raw-sum to 1.05; this rebalances them).
lqs_weight AS (
    SELECT
        category,
        signal,
        raw_w / SUM(raw_w) OVER (PARTITION BY category) AS weight
    FROM lqs_weight_raw
),

-- Step 4: each listing's catalog signals, normalized to [0,1] against the
-- sufficiency_targets. Imputed inputs resolve to their conservative "absent"
-- value (0 / FALSE) so LQS penalizes missing content — metrics.yaml's
-- "imputed inputs treated as absent". Only image_count can be NULL (quarantined).
listing_signals AS (
    SELECT listing_id, category, 'image_sufficiency' AS signal,
           LEAST(COALESCE(image_count, 0) / 5.0, 1.0) AS value          -- target 5 images
    FROM silver_dim_listing
    UNION ALL
    SELECT listing_id, category, 'has_video',
           CASE WHEN has_video THEN 1.0 ELSE 0.0 END
    FROM silver_dim_listing
    UNION ALL
    SELECT listing_id, category, 'title_adequacy',
           -- band [40,120]: full credit once >= 40 (upper bound is a soft
           -- guideline, a long title is not a catalog defect); ramp below 40.
           CASE WHEN title_length_chars >= 40 THEN 1.0
                ELSE title_length_chars / 40.0 END
    FROM silver_dim_listing
    UNION ALL
    SELECT listing_id, category, 'description_adequacy',
           LEAST(COALESCE(description_length_chars, 0) / 300.0, 1.0)     -- target 300 chars
    FROM silver_dim_listing
    UNION ALL
    SELECT listing_id, category, 'specifications_filled_pct',
           COALESCE(specifications_filled_pct, 0)                        -- already [0,1]
    FROM silver_dim_listing
    UNION ALL
    SELECT listing_id, category, 'has_size_chart',
           CASE WHEN has_size_chart THEN 1.0 ELSE 0.0 END
    FROM silver_dim_listing
    UNION ALL
    SELECT listing_id, category, 'has_dimensions_listed',
           CASE WHEN has_dimensions_listed THEN 1.0 ELSE 0.0 END
    FROM silver_dim_listing
    UNION ALL
    SELECT listing_id, category, 'variant_sufficiency',
           LEAST(COALESCE(variant_count, 0) / 3.0, 1.0)                  -- target 3 variants
    FROM silver_dim_listing
),

-- Step 5: LQS = 100 * SUM(weight * signal). Weights sum to 1 and signals are
-- in [0,1], so LQS is guaranteed within [0,100].
lqs AS (
    SELECT
        s.listing_id,
        100.0 * SUM(w.weight * s.value) AS listing_quality_score
    FROM listing_signals s
    JOIN lqs_weight w USING (category, signal)
    GROUP BY s.listing_id
),

-- ===================================================================
-- ORDER-SIDE AGGREGATION  (from F1 — economics already materialized)
-- ===================================================================
order_agg AS (
    SELECT
        listing_id,
        COUNT(*)                                                   AS total_orders,
        SUM(is_delivered::INT)                                     AS delivered_orders,
        SUM(is_shipped::INT)                                       AS shipped_orders,
        SUM(is_rto::INT)                                           AS rto_orders,
        SUM(is_cancelled::INT)                                     AS cancelled_orders,
        -- Delivered units are the denominator for return rates (Golden Rule 2);
        -- invalid quantities (dq_out_of_range_quantity) are excluded.
        SUM(quantity) FILTER (WHERE is_delivered AND NOT is_quantity_invalid) AS delivered_units,
        SUM(gross_margin_aed)                                      AS gross_margin,
        SUM(realized_net_revenue_aed)                             AS realized_net_revenue,
        SUM(rto_cost_aed)                                          AS rto_cost,
        -- Observable delivery-performance inputs for trust_score (seller mart).
        SUM(is_on_time::INT) FILTER (WHERE is_delivered)          AS on_time_delivered,
        AVG(delivery_attempts) FILTER (WHERE is_delivered)        AS avg_delivery_attempts
    FROM gold_order_line_economics
    GROUP BY listing_id
),

-- ===================================================================
-- RETURN-SIDE AGGREGATION  (from F2 — return_cost already materialized)
-- ===================================================================
-- gross_margin_pct is joined ONLY to compute the forgone-margin component of
-- Recoverable Profit (a NEW metric); return_cost itself is reused, not re-derived.
return_agg AS (
    SELECT
        r.listing_id,
        COUNT(*)                                                  AS returned_orders,
        SUM(r.quantity_returned)                                  AS returned_units,
        SUM(r.quantity_returned) FILTER (WHERE r.is_catalog_related) AS catalog_returned_units,
        SUM(r.quantity_returned) FILTER (WHERE r.reason_group = 'damaged') AS damage_returned_units,
        SUM(r.return_cost_aed)                                    AS return_cost,
        SUM(r.returned_value_aed)                                 AS returned_value,
        SUM(r.recovered_value_aed)                               AS recovered_value,
        -- Catalog leakage = catalog-related (return_cost + forgone gross margin).
        -- forgone_gross_margin = returned_value * category gross_margin_pct.
        -- return_cost already includes merchandise_loss (refund - salvage); the
        -- forgone margin is the DISTINCT profit the reversed sale would have
        -- earned, so the two do not double-count (metrics.yaml recoverable_profit).
        SUM(CASE WHEN r.is_catalog_related
                 THEN r.return_cost_aed + r.returned_value_aed * ce.gross_margin_pct
                 ELSE 0 END)                                      AS catalog_leakage
    FROM gold_return_line_economics r
    JOIN silver_ref_category_economics ce ON r.category = ce.category
    GROUP BY r.listing_id
),

-- addressable_fraction mirrors config/metrics.yaml parameters.recoverable_profit
-- (default 1.0 => UPPER BOUND). Single knob; keep in sync with config.
params AS (SELECT 1.0 AS addressable_fraction)

-- ===================================================================
-- FINAL: one row per listing (LEFT JOIN keeps all 10,000)
-- ===================================================================
SELECT
    dl.listing_id,
    dl.category,
    dl.seller_id,

    -- ---- Catalog quality ----
    ROUND(lqs.listing_quality_score, 2)                          AS listing_quality_score,

    -- ---- Volumes (COALESCE 0: zero-activity listings) ----
    COALESCE(oa.total_orders, 0)                                 AS total_orders,
    COALESCE(oa.delivered_orders, 0)                             AS delivered_orders,
    COALESCE(oa.shipped_orders, 0)                               AS shipped_orders,
    COALESCE(oa.rto_orders, 0)                                   AS rto_orders,
    COALESCE(oa.cancelled_orders, 0)                             AS cancelled_orders,
    COALESCE(ra.returned_orders, 0)                              AS returned_orders,
    COALESCE(oa.delivered_units, 0)                              AS delivered_units,
    COALESCE(ra.returned_units, 0)                               AS returned_units,
    COALESCE(ra.catalog_returned_units, 0)                       AS catalog_returned_units,

    -- ---- Rates (NULL when denominator is 0 => undefined, not zero) ----
    -- catalog_return_rate = catalog-related returned units / delivered units.
    -- COALESCE numerator: a delivered listing with no returns is rate 0, not
    -- NULL; NULL is reserved for delivered_units = 0 (rate undefined).
    ROUND(COALESCE(ra.catalog_returned_units, 0) * 1.0 / NULLIF(oa.delivered_units, 0), 6) AS catalog_return_rate,
    -- rto_rate = RTO orders / shipped orders (shipped excludes cancelled).
    ROUND(oa.rto_orders * 1.0 / NULLIF(oa.shipped_orders, 0), 6)  AS rto_rate,
    -- recovery_rate = recovered value / returned value.
    ROUND(ra.recovered_value / NULLIF(ra.returned_value, 0), 6)   AS recovery_rate,

    -- ---- Economics (COALESCE 0; full precision retained for reconciliation) ----
    COALESCE(oa.gross_margin, 0)                                 AS gross_margin,
    COALESCE(ra.return_cost, 0)                                  AS return_cost,
    -- net_margin_after_returns EXCLUDES RTO cost (Golden Rule 2 separation).
    COALESCE(oa.gross_margin, 0) - COALESCE(ra.return_cost, 0)   AS net_margin_after_returns,
    ROUND((COALESCE(oa.gross_margin, 0) - COALESCE(ra.return_cost, 0))
          / NULLIF(oa.realized_net_revenue, 0), 6)               AS net_margin_after_returns_pct,
    COALESCE(oa.rto_cost, 0)                                     AS rto_cost,
    COALESCE(oa.realized_net_revenue, 0)                         AS realized_net_revenue,
    COALESCE(ra.returned_value, 0)                               AS returned_value,
    COALESCE(ra.recovered_value, 0)                              AS recovered_value,

    -- ---- Trust score INPUTS (observable only; trust_score built in seller mart) ----
    -- No hidden variables (SOQ/TPQ/Expectation Gap) are ever used.
    ROUND(oa.on_time_delivered * 1.0 / NULLIF(oa.delivered_orders, 0), 6) AS on_time_delivery_rate,
    ROUND(oa.avg_delivery_attempts, 4)                           AS avg_delivery_attempts,
    ROUND(ra.damage_returned_units * 1.0 / NULLIF(ra.returned_units, 0), 6) AS damage_return_share,
    -- (rto_rate and catalog_return_rate above are also trust_score inputs.)

    -- ---- Priority metric for the future intervention queue ----
    -- Recoverable Profit (catalog_fix ranking): addressable_fraction * catalog leakage.
    ROUND(p.addressable_fraction * COALESCE(ra.catalog_leakage, 0), 2) AS recoverable_profit
FROM silver_dim_listing dl
LEFT JOIN lqs        ON dl.listing_id = lqs.listing_id
LEFT JOIN order_agg  oa ON dl.listing_id = oa.listing_id
LEFT JOIN return_agg ra ON dl.listing_id = ra.listing_id
CROSS JOIN params p;

-- =====================================================================
-- VALIDATION QUERIES  (each returns check | value | pass)
-- =====================================================================
-- V1 Exactly 10,000 rows (one per Silver listing).
SELECT 'row_count_10000' AS check, COUNT(*) AS value, COUNT(*) = 10000 AS pass
FROM gold_listing_metrics;

-- V2 One row per listing — PK unique & non-null (no duplicated listing_id).
SELECT 'one_row_per_listing' AS check, COUNT(*) - COUNT(DISTINCT listing_id) AS value,
       COUNT(*) = COUNT(DISTINCT listing_id) AND COUNT(listing_id) = COUNT(*) AS pass
FROM gold_listing_metrics;

-- V3 LQS bounded to [0,100] and never NULL (computed for every listing).
SELECT 'lqs_bounds' AS check, ROUND(MAX(listing_quality_score), 2) AS value,
       MIN(listing_quality_score) >= 0 AND MAX(listing_quality_score) <= 100
   AND COUNT(*) FILTER (WHERE listing_quality_score IS NULL) = 0 AS pass
FROM gold_listing_metrics;

-- V4 LQS weights renormalize to 1.0 within every category (self-contained;
-- overrides make Fashion/Home raw-sum to 1.05, so normalization is essential).
WITH sd(signal, w) AS (
    VALUES ('image_sufficiency',0.20),('has_video',0.10),('title_adequacy',0.10),
           ('description_adequacy',0.15),('specifications_filled_pct',0.20),
           ('has_size_chart',0.10),('has_dimensions_listed',0.05),('variant_sufficiency',0.10)),
cats(category) AS (SELECT DISTINCT category FROM read_csv_auto('data/02_silver/dim_listing.csv')),
raw AS (
    SELECT c.category, CASE
        WHEN c.category='Fashion' AND sd.signal='has_size_chart' THEN 0.25
        WHEN c.category='Fashion' AND sd.signal='specifications_filled_pct' THEN 0.10
        WHEN c.category='Home' AND sd.signal='has_dimensions_listed' THEN 0.20
        WHEN c.category='Home' AND sd.signal='has_size_chart' THEN 0.00
        WHEN c.category='Electronics' AND sd.signal='specifications_filled_pct' THEN 0.30
        WHEN c.category='Electronics' AND sd.signal='has_size_chart' THEN 0.00
        ELSE sd.w END AS raw_w
    FROM cats c CROSS JOIN sd),
norm AS (SELECT category, raw_w / SUM(raw_w) OVER (PARTITION BY category) AS weight FROM raw)
SELECT 'lqs_weights_sum_to_1' AS check,
       COUNT(*) FILTER (WHERE ABS(wsum - 1.0) > 1e-9) AS value,
       COUNT(*) FILTER (WHERE ABS(wsum - 1.0) > 1e-9) = 0 AS pass
FROM (SELECT category, SUM(weight) AS wsum FROM norm GROUP BY category) t;

-- V5 Return-rate & recovery bounds within [0,1] (where defined).
SELECT 'rate_bounds_0_1' AS check, NULL AS value,
       COALESCE(MAX(catalog_return_rate), 0) <= 1 AND COALESCE(MIN(catalog_return_rate), 0) >= 0
   AND COALESCE(MAX(rto_rate), 0) <= 1 AND COALESCE(MIN(rto_rate), 0) >= 0
   AND COALESCE(MAX(recovery_rate), 0) <= 1 AND COALESCE(MIN(recovery_rate), 0) >= 0
   AND COALESCE(MAX(on_time_delivery_rate), 0) <= 1
   AND COALESCE(MAX(damage_return_share), 0) <= 1 AS pass
FROM gold_listing_metrics;

-- V6 Margin identity: net_margin_after_returns = gross_margin - return_cost.
SELECT 'margin_identity' AS check,
       COUNT(*) FILTER (WHERE ABS(net_margin_after_returns
                                  - (gross_margin - return_cost)) > 0.001) AS value,
       COUNT(*) FILTER (WHERE ABS(net_margin_after_returns
                                  - (gross_margin - return_cost)) > 0.001) = 0 AS pass
FROM gold_listing_metrics;

-- V7 Null-rate checks: economics/LQS never NULL; a NULL rate implies a zero
-- denominator (undefined), never a populated one.
SELECT 'null_rules' AS check,
       COUNT(*) FILTER (WHERE listing_quality_score IS NULL OR gross_margin IS NULL
                          OR return_cost IS NULL OR net_margin_after_returns IS NULL
                          OR recoverable_profit IS NULL)                          AS value,
       COUNT(*) FILTER (WHERE listing_quality_score IS NULL OR gross_margin IS NULL
                          OR return_cost IS NULL OR net_margin_after_returns IS NULL
                          OR recoverable_profit IS NULL) = 0
   AND COUNT(*) FILTER (WHERE catalog_return_rate IS NULL AND delivered_units > 0) = 0
   AND COUNT(*) FILTER (WHERE rto_rate IS NULL AND shipped_orders > 0) = 0
   AND COUNT(*) FILTER (WHERE recovery_rate IS NULL AND returned_units > 0) = 0 AS pass
FROM gold_listing_metrics;

-- V8 Reconciliation vs foundational facts (counts + AED totals must tie out).
SELECT 'reconcile_foundational' AS check, NULL AS value,
       SUM(total_orders)     = (SELECT COUNT(*) FROM gold_order_line_economics)
   AND SUM(delivered_orders) = (SELECT SUM(is_delivered::INT) FROM gold_order_line_economics)
   AND SUM(rto_orders)       = (SELECT SUM(is_rto::INT) FROM gold_order_line_economics)
   AND SUM(returned_orders)  = (SELECT COUNT(*) FROM gold_return_line_economics)
   AND ABS(SUM(gross_margin) - (SELECT SUM(gross_margin_aed) FROM gold_order_line_economics)) < 0.01
   AND ABS(SUM(return_cost)  - (SELECT SUM(return_cost_aed)  FROM gold_return_line_economics)) < 0.01
   AND ABS(SUM(rto_cost)     - (SELECT SUM(rto_cost_aed)     FROM gold_order_line_economics)) < 0.01 AS pass
FROM gold_listing_metrics;

-- V9 Aggregate recovery_rate ties to F2 (SUM salvage / SUM returned value).
SELECT 'recovery_rate_reconcile' AS check,
       ROUND(SUM(recovered_value) / NULLIF(SUM(returned_value), 0), 4) AS value,
       ABS(SUM(recovered_value) / NULLIF(SUM(returned_value), 0)
           - (SELECT SUM(recovered_value_aed) / NULLIF(SUM(returned_value_aed), 0)
              FROM gold_return_line_economics)) < 1e-6 AS pass
FROM gold_listing_metrics;
