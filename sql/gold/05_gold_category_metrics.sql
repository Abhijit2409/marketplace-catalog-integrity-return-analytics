-- =====================================================================
-- Gold Entity Mart 2 — gold_category_metrics  (Category Performance Mart)
-- =====================================================================
-- Grain      : one row per category (5 rows).                 [PK category]
-- Purpose    : Summarize marketplace performance at the category level for
--              Category Managers and Commercial Directors.
-- Nature     : AGGREGATION LAYER, NOT a computation layer. Every business
--              metric (LQS, Return Cost, Recoverable Profit, Trust Score,
--              Gross Margin) is REUSED from upstream marts and only summed /
--              averaged here — nothing is recomputed (CLAUDE.md, TASK-007).
-- Inputs     : gold_listing_metrics   (primary rollup source),
--              gold_seller_metrics    (average_trust_score — Trust lives there,
--                                      per the Seller -> Category hierarchy),
--              gold_order_line_economics (F1 — on-time & attempt numerators the
--                                      listing mart exposes only as rates),
--              ref_category_economics (structural margin ratio, context).
-- Golden Rules: R2 — net_margin_after_returns EXCLUDES RTO; return rates use
--              delivered-only denominators; RTO from order status only.
-- Dialect    : DuckDB. Run order: AFTER 01_..04_.
-- =====================================================================

-- ---- SOURCE BINDINGS (Silver reference, read-only; idempotent) ------
CREATE OR REPLACE VIEW silver_ref_category_economics AS
  SELECT * FROM read_csv_auto('data/02_silver/ref_category_economics.csv');

-- ---- BUILD ----------------------------------------------------------
CREATE OR REPLACE TABLE gold_category_metrics AS
WITH
-- Primary rollup: SUM/AVG the already-computed listing-grain metrics.
listing_by_cat AS (
    SELECT
        category,
        COUNT(*)                                  AS listing_count,
        COUNT(DISTINCT seller_id)                 AS seller_count,
        AVG(listing_quality_score)                AS average_listing_quality_score,
        SUM(total_orders)                         AS total_orders,
        SUM(delivered_orders)                     AS delivered_orders,
        SUM(shipped_orders)                       AS shipped_orders,
        SUM(returned_orders)                      AS returned_orders,
        SUM(rto_orders)                           AS rto_orders,
        SUM(delivered_units)                      AS delivered_units,
        SUM(returned_units)                       AS returned_units,
        SUM(catalog_returned_units)               AS catalog_returned_units,
        SUM(gross_margin)                         AS gross_margin,
        SUM(return_cost)                          AS return_cost,
        SUM(recoverable_profit)                   AS recoverable_profit,
        SUM(rto_cost)                             AS rto_cost,
        SUM(realized_net_revenue)                 AS realized_net_revenue,
        SUM(returned_value)                       AS returned_value,
        SUM(recovered_value)                      AS recovered_value
    FROM gold_listing_metrics
    GROUP BY category
),

-- On-time & delivery-attempt inputs: re-aggregate the is_on_time flag and
-- attempts already materialized in F1 (the listing mart holds only the rate).
ontime_by_cat AS (
    SELECT
        category,
        SUM(is_on_time::INT) FILTER (WHERE is_delivered)    AS on_time_delivered,
        SUM(is_delivered::INT)                              AS delivered_orders_f1,
        AVG(delivery_attempts) FILTER (WHERE is_delivered)  AS average_delivery_attempts
    FROM gold_order_line_economics
    GROUP BY category
),

-- Average Trust Score of the distinct sellers operating in each category.
-- Trust is seller-grain (born in gold_seller_metrics); a multi-category seller
-- contributes to each category it lists in. No recomputation of Trust here.
trust_by_cat AS (
    SELECT cs.category, AVG(sm.trust_score) AS average_trust_score
    FROM (SELECT DISTINCT category, seller_id FROM gold_listing_metrics) cs
    JOIN gold_seller_metrics sm ON cs.seller_id = sm.seller_id
    GROUP BY cs.category
),

-- Structural category margin ratio (context for Category Managers).
cat_econ AS (
    SELECT category, gross_margin_pct AS category_gross_margin_pct
    FROM silver_ref_category_economics
),

-- Assemble per-category base with derived rates (delivered-only denominators).
base AS (
    SELECT
        l.category,
        l.listing_count,
        l.seller_count,
        l.total_orders,
        l.delivered_orders,
        l.shipped_orders,
        l.returned_orders,
        l.rto_orders,
        l.delivered_units,
        l.returned_units,
        l.catalog_returned_units,
        -- Financials.
        l.gross_margin,
        l.return_cost,
        l.recoverable_profit,
        (l.gross_margin - l.return_cost)                                 AS net_margin_after_returns,
        (l.gross_margin - l.return_cost) / NULLIF(l.realized_net_revenue, 0) AS net_margin_after_returns_pct,
        l.rto_cost,
        l.realized_net_revenue,
        l.returned_value,
        l.recovered_value,
        -- Quality.
        l.average_listing_quality_score,
        -- Marketplace-health rates.
        l.recovered_value / NULLIF(l.returned_value, 0)                 AS recovery_rate,
        l.catalog_returned_units * 1.0 / NULLIF(l.delivered_units, 0)   AS catalog_return_rate,
        l.rto_orders * 1.0 / NULLIF(l.shipped_orders, 0)               AS rto_rate,
        -- Commercial.
        t.average_trust_score,
        o.average_delivery_attempts,
        o.on_time_delivered * 1.0 / NULLIF(o.delivered_orders_f1, 0)    AS on_time_delivery_rate,
        e.category_gross_margin_pct
    FROM listing_by_cat l
    LEFT JOIN ontime_by_cat o ON l.category = o.category
    LEFT JOIN trust_by_cat  t ON l.category = t.category
    LEFT JOIN cat_econ      e ON l.category = e.category
)

-- Final projection: add cross-category rankings and marketplace-share
-- percentages via window functions over the 5 category rows.
SELECT
    category,
    -- ---- Business volume ----
    listing_count,
    seller_count,
    total_orders,
    delivered_orders,
    shipped_orders,
    returned_orders,
    rto_orders,
    delivered_units,
    returned_units,
    catalog_returned_units,
    -- ---- Financial ----
    gross_margin,
    return_cost,
    recoverable_profit,
    net_margin_after_returns,
    ROUND(net_margin_after_returns_pct, 6) AS net_margin_after_returns_pct,
    rto_cost,
    realized_net_revenue,
    returned_value,
    recovered_value,
    -- ---- Quality ----
    ROUND(average_listing_quality_score, 2) AS average_listing_quality_score,
    -- ---- Marketplace health ----
    ROUND(recovery_rate, 6)        AS recovery_rate,
    ROUND(catalog_return_rate, 6)  AS catalog_return_rate,
    ROUND(rto_rate, 6)             AS rto_rate,
    -- ---- Commercial ----
    ROUND(average_trust_score, 2)      AS average_trust_score,
    ROUND(average_delivery_attempts, 4) AS average_delivery_attempts,
    ROUND(on_time_delivery_rate, 6)    AS on_time_delivery_rate,
    ROUND(category_gross_margin_pct, 4) AS category_gross_margin_pct,
    -- ---- Ranking (1 = most severe / largest; ROW_NUMBER => strict, unique) ----
    -- margin loss = ranking of net_margin_after_returns ASC (rank 1 retains the
    -- LEAST margin after returns). Distinct from return_cost rank by design.
    ROW_NUMBER() OVER (ORDER BY net_margin_after_returns ASC, category) AS category_rank_by_margin_loss,
    ROW_NUMBER() OVER (ORDER BY return_cost DESC, category)             AS category_rank_by_return_cost,
    ROW_NUMBER() OVER (ORDER BY recoverable_profit DESC, category)      AS category_rank_by_recoverable_profit,
    -- ---- Risk: share of the marketplace total ----
    ROUND(return_cost        / SUM(return_cost) OVER (), 6)        AS percentage_of_marketplace_return_cost,
    ROUND(recoverable_profit / SUM(recoverable_profit) OVER (), 6) AS percentage_of_marketplace_recoverable_profit
FROM base;

-- =====================================================================
-- VALIDATION QUERIES  (check | expected | actual | pass)
-- =====================================================================
-- 1. Exactly 5 rows.
SELECT 'row_count' AS check, '5' AS expected, COUNT(*)::VARCHAR AS actual,
       COUNT(*) = 5 AS pass FROM gold_category_metrics;

-- 2 & 3. One row per category / no duplicate category.
SELECT 'one_row_per_category' AS check, 'count = distinct' AS expected,
       COUNT(*)::VARCHAR || ' / ' || COUNT(DISTINCT category)::VARCHAR AS actual,
       COUNT(*) = COUNT(DISTINCT category) AND COUNT(category) = COUNT(*) AS pass
FROM gold_category_metrics;

-- 4. Gross Margin reconciles to the Listing mart.
SELECT 'gross_margin_reconcile' AS check,
       ROUND((SELECT SUM(gross_margin) FROM gold_listing_metrics), 2)::VARCHAR AS expected,
       ROUND(SUM(gross_margin), 2)::VARCHAR AS actual,
       ABS(SUM(gross_margin) - (SELECT SUM(gross_margin) FROM gold_listing_metrics)) < 0.01 AS pass
FROM gold_category_metrics;

-- 5. Return Cost reconciles to the Listing mart.
SELECT 'return_cost_reconcile' AS check,
       ROUND((SELECT SUM(return_cost) FROM gold_listing_metrics), 2)::VARCHAR AS expected,
       ROUND(SUM(return_cost), 2)::VARCHAR AS actual,
       ABS(SUM(return_cost) - (SELECT SUM(return_cost) FROM gold_listing_metrics)) < 0.01 AS pass
FROM gold_category_metrics;

-- 6. Recoverable Profit reconciles to the Listing mart.
SELECT 'recoverable_profit_reconcile' AS check,
       ROUND((SELECT SUM(recoverable_profit) FROM gold_listing_metrics), 2)::VARCHAR AS expected,
       ROUND(SUM(recoverable_profit), 2)::VARCHAR AS actual,
       ABS(SUM(recoverable_profit) - (SELECT SUM(recoverable_profit) FROM gold_listing_metrics)) < 0.01 AS pass
FROM gold_category_metrics;

-- 7. Order counts reconcile to the Listing mart.
SELECT 'order_counts_reconcile' AS check, '85000/74780/32005/8096' AS expected,
       SUM(total_orders)::VARCHAR || '/' || SUM(delivered_orders)::VARCHAR || '/' ||
       SUM(returned_orders)::VARCHAR || '/' || SUM(rto_orders)::VARCHAR AS actual,
       SUM(total_orders)     = (SELECT SUM(total_orders) FROM gold_listing_metrics)
   AND SUM(delivered_orders) = (SELECT SUM(delivered_orders) FROM gold_listing_metrics)
   AND SUM(returned_orders)  = (SELECT SUM(returned_orders) FROM gold_listing_metrics)
   AND SUM(rto_orders)       = (SELECT SUM(rto_orders) FROM gold_listing_metrics) AS pass
FROM gold_category_metrics;

-- 8. Rate metrics within [0,1].
SELECT 'rate_bounds_0_1' AS check, 'all in [0,1]' AS expected,
       'min/max checked' AS actual,
       MIN(recovery_rate) >= 0 AND MAX(recovery_rate) <= 1
   AND MIN(catalog_return_rate) >= 0 AND MAX(catalog_return_rate) <= 1
   AND MIN(rto_rate) >= 0 AND MAX(rto_rate) <= 1
   AND MIN(on_time_delivery_rate) >= 0 AND MAX(on_time_delivery_rate) <= 1 AS pass
FROM gold_category_metrics;

-- 9. No impossible percentages (each share in [0,1]).
SELECT 'percentage_bounds' AS check, 'all in [0,1]' AS expected, 'checked' AS actual,
       MIN(percentage_of_marketplace_return_cost) >= 0 AND MAX(percentage_of_marketplace_return_cost) <= 1
   AND MIN(percentage_of_marketplace_recoverable_profit) >= 0
   AND MAX(percentage_of_marketplace_recoverable_profit) <= 1 AS pass
FROM gold_category_metrics;

-- 10. Ranking uniqueness (each rank column is a strict 1..5 permutation).
SELECT 'ranking_uniqueness' AS check, '5/5/5 distinct' AS expected,
       COUNT(DISTINCT category_rank_by_margin_loss)::VARCHAR || '/' ||
       COUNT(DISTINCT category_rank_by_return_cost)::VARCHAR || '/' ||
       COUNT(DISTINCT category_rank_by_recoverable_profit)::VARCHAR AS actual,
       COUNT(DISTINCT category_rank_by_margin_loss) = 5
   AND COUNT(DISTINCT category_rank_by_return_cost) = 5
   AND COUNT(DISTINCT category_rank_by_recoverable_profit) = 5 AS pass
FROM gold_category_metrics;

-- 11. NULL rules: no NULLs in any required metric (all 5 categories are active).
SELECT 'null_rules' AS check, '0 nulls' AS expected,
       COUNT(*) FILTER (WHERE gross_margin IS NULL OR return_cost IS NULL
                          OR recoverable_profit IS NULL OR net_margin_after_returns IS NULL
                          OR average_listing_quality_score IS NULL OR average_trust_score IS NULL
                          OR recovery_rate IS NULL OR catalog_return_rate IS NULL
                          OR rto_rate IS NULL OR on_time_delivery_rate IS NULL)::VARCHAR AS actual,
       COUNT(*) FILTER (WHERE gross_margin IS NULL OR return_cost IS NULL
                          OR recoverable_profit IS NULL OR net_margin_after_returns IS NULL
                          OR average_listing_quality_score IS NULL OR average_trust_score IS NULL
                          OR recovery_rate IS NULL OR catalog_return_rate IS NULL
                          OR rto_rate IS NULL OR on_time_delivery_rate IS NULL) = 0 AS pass
FROM gold_category_metrics;

-- 12. Category percentages sum to 100% (1.0) across the 5 categories.
SELECT 'percentages_sum_to_1' AS check, '1.0 / 1.0' AS expected,
       ROUND(SUM(percentage_of_marketplace_return_cost), 6)::VARCHAR || ' / ' ||
       ROUND(SUM(percentage_of_marketplace_recoverable_profit), 6)::VARCHAR AS actual,
       ABS(SUM(percentage_of_marketplace_return_cost) - 1) < 1e-6
   AND ABS(SUM(percentage_of_marketplace_recoverable_profit) - 1) < 1e-6 AS pass
FROM gold_category_metrics;

-- 13. Financial identity: net_margin_after_returns = gross_margin - return_cost.
SELECT 'financial_identity' AS check, '0 violations' AS expected,
       COUNT(*) FILTER (WHERE ABS(net_margin_after_returns - (gross_margin - return_cost)) > 0.001)::VARCHAR AS actual,
       COUNT(*) FILTER (WHERE ABS(net_margin_after_returns - (gross_margin - return_cost)) > 0.001) = 0 AS pass
FROM gold_category_metrics;
