-- =====================================================================
-- Gold Entity Mart 3 — gold_seller_metrics
-- =====================================================================
-- Grain      : one row per seller (all dim_seller rows, ~450).  [PK seller_id]
-- Purpose    : Seller scorecard for governance & risk. Birthplace of TRUST
--              SCORE. Holds the toxic-RTO *ingredients* (cost, rank, flags) —
--              NOT the concentration scalar (that is executive-grain).
-- Inputs     : gold_listing_metrics (primary rollup source),
--              gold_order_line_economics (F1 — on-time flag & attempts, which
--              the listing mart does not expose as summable counts),
--              gold_return_line_economics (F2 — damage-unit numerator),
--              silver dim_seller (attributes).
-- Metrics    : trust_score (born here), plus seller rollups of gross_margin,
--              return_cost, net_margin_after_returns, recovery_rate,
--              catalog_return_rate, rto_rate, recoverable_profit
--              (config/metrics.yaml).
-- Golden Rules: R1 — Trust Score derived-only, first materialized here.
--              R2 — RTO from order status; net_margin_after_returns EXCLUDES
--              RTO; return rates use delivered-only denominators.
-- No hidden variables (SOQ / TPQ / Expectation Gap). LQS and Return Cost are
-- REUSED from upstream, never recomputed.
-- Dialect    : DuckDB. Run order: AFTER 01_, 02_, 03_.
-- =====================================================================

-- ---- SOURCE BINDINGS (Silver, read-only; idempotent) ----------------
CREATE OR REPLACE VIEW silver_dim_seller AS
  SELECT * FROM read_csv_auto('data/02_silver/dim_seller.csv');

-- ---- BUILD ----------------------------------------------------------
CREATE OR REPLACE TABLE gold_seller_metrics AS
WITH
-- Trust-score weights & toxic-RTO thresholds mirror config/metrics.yaml
-- (parameters.trust_score, parameters.toxic_rto). Single knobs; keep in sync.
params AS (
    SELECT 0.25 AS w_ontime, 0.20 AS w_inv_rto, 0.20 AS w_inv_catalog,
           0.10 AS w_inv_damage, 0.10 AS w_deliv_eff, 0.10 AS w_lqs, 0.05 AS w_tier,
           0.25 AS toxic_rate_threshold, 30 AS min_shipped_orders, 0.10 AS toxic_top_fraction
),

-- ---- Primary rollup: SUM additive listing-grain metrics to the seller.
-- Everything here is already correctly aggregated per listing, so seller
-- totals are just SUMs — this is what guarantees reconciliation and avoids
-- re-deriving any economics.
listing_agg AS (
    SELECT
        seller_id,
        COUNT(*)                                        AS listing_count,
        COUNT(*) FILTER (WHERE total_orders > 0)        AS active_listing_count,
        AVG(listing_quality_score)                      AS average_listing_quality_score,
        SUM(total_orders)                               AS total_orders,
        SUM(delivered_orders)                           AS delivered_orders,
        SUM(shipped_orders)                             AS shipped_orders,
        SUM(rto_orders)                                 AS rto_orders,
        SUM(cancelled_orders)                           AS cancelled_orders,
        SUM(returned_orders)                            AS returned_orders,
        SUM(delivered_units)                            AS delivered_units,
        SUM(returned_units)                             AS returned_units,
        SUM(catalog_returned_units)                     AS catalog_returned_units,
        SUM(gross_margin)                               AS gross_margin,
        SUM(return_cost)                                AS return_cost,
        SUM(rto_cost)                                   AS rto_cost,
        SUM(realized_net_revenue)                       AS realized_net_revenue,
        SUM(returned_value)                             AS returned_value,
        SUM(recovered_value)                            AS recovered_value,
        SUM(recoverable_profit)                         AS recoverable_profit
    FROM gold_listing_metrics
    GROUP BY seller_id
),

-- On-time & delivery-attempt inputs: the listing mart exposes only the RATE
-- (non-summable), so we re-aggregate the is_on_time FLAG already materialized
-- in F1 at seller grain. This reuses upstream logic, it does not re-derive it.
ontime_agg AS (
    SELECT
        seller_id,
        SUM(is_delivered::INT)                                    AS delivered_orders_f1,
        SUM(is_on_time::INT) FILTER (WHERE is_delivered)          AS on_time_delivered,
        AVG(delivery_attempts) FILTER (WHERE is_delivered)        AS avg_delivery_attempts
    FROM gold_order_line_economics
    GROUP BY seller_id
),

-- Damage-return numerator: not exposed by the listing mart, so aggregate the
-- reason_group already attached in F2.
damage_agg AS (
    SELECT
        seller_id,
        SUM(quantity_returned)                                    AS returned_units_f2,
        SUM(quantity_returned) FILTER (WHERE reason_group = 'damaged') AS damage_returned_units
    FROM gold_return_line_economics
    GROUP BY seller_id
),

-- Each seller's primary category = the category holding most of its listings
-- (stable even for low-activity sellers). Used for category-adjusted ranking.
primary_cat AS (
    SELECT seller_id, category AS primary_category
    FROM (
        SELECT seller_id, category,
               ROW_NUMBER() OVER (PARTITION BY seller_id
                                  ORDER BY COUNT(*) DESC, category) AS rn
        FROM gold_listing_metrics
        GROUP BY seller_id, category
    ) WHERE rn = 1
),

-- ---- Assemble base row per seller (all 450 retained via dim_seller). ----
base AS (
    SELECT
        s.seller_id, s.seller_name, s.seller_country, s.fulfillment_type, s.seller_tier,
        pc.primary_category,
        COALESCE(la.listing_count, 0)          AS listing_count,
        COALESCE(la.active_listing_count, 0)   AS active_listing_count,
        la.average_listing_quality_score,
        COALESCE(la.total_orders, 0)           AS total_orders,
        COALESCE(la.delivered_orders, 0)       AS delivered_orders,
        COALESCE(la.shipped_orders, 0)         AS shipped_orders,
        COALESCE(la.rto_orders, 0)             AS rto_orders,
        COALESCE(la.cancelled_orders, 0)       AS cancelled_orders,
        COALESCE(la.returned_orders, 0)        AS returned_orders,
        COALESCE(la.delivered_units, 0)        AS delivered_units,
        COALESCE(la.returned_units, 0)         AS returned_units,
        COALESCE(la.catalog_returned_units, 0) AS catalog_returned_units,
        COALESCE(la.gross_margin, 0)           AS gross_margin,
        COALESCE(la.return_cost, 0)            AS return_cost,
        COALESCE(la.rto_cost, 0)               AS rto_cost,
        COALESCE(la.realized_net_revenue, 0)   AS realized_net_revenue,
        COALESCE(la.returned_value, 0)         AS returned_value,
        COALESCE(la.recovered_value, 0)        AS recovered_value,
        COALESCE(la.recoverable_profit, 0)     AS recoverable_profit,
        oa.on_time_delivered,
        oa.avg_delivery_attempts,
        dm.damage_returned_units,
        p.*
    FROM silver_dim_seller s
    LEFT JOIN listing_agg  la ON s.seller_id = la.seller_id
    LEFT JOIN ontime_agg   oa ON s.seller_id = oa.seller_id
    LEFT JOIN damage_agg   dm ON s.seller_id = dm.seller_id
    LEFT JOIN primary_cat  pc ON s.seller_id = pc.seller_id
    CROSS JOIN params p
),

-- ---- Derive rates, trust components, and Trust Score. ----
derived AS (
    SELECT
        b.*,
        -- Rates (NULL when denominator is 0 => undefined, not zero).
        b.catalog_returned_units * 1.0 / NULLIF(b.delivered_units, 0)  AS catalog_return_rate,
        b.rto_orders * 1.0 / NULLIF(b.shipped_orders, 0)               AS rto_rate,
        b.recovered_value / NULLIF(b.returned_value, 0)                AS recovery_rate,
        (b.gross_margin - b.return_cost)                               AS net_margin_after_returns,
        (b.gross_margin - b.return_cost) / NULLIF(b.realized_net_revenue, 0) AS net_margin_after_returns_pct,
        b.on_time_delivered * 1.0 / NULLIF(b.delivered_orders, 0)      AS on_time_delivery_rate,
        -- damage share for the reported column: NULL if no returns (undefined).
        b.damage_returned_units * 1.0 / NULLIF(b.returned_units, 0)    AS damage_return_share,

        -- ---- Trust-score COMPONENTS (each observable, in [0,1], higher=better) ----
        -- Weights renormalize over whatever components are defined for the seller,
        -- so a seller lacking deliveries/returns still scores on available signals
        -- (seller_tier is always present, so the denominator is never 0).
        b.on_time_delivered * 1.0 / NULLIF(b.delivered_orders, 0)      AS c_on_time,
        1 - (b.rto_orders * 1.0 / NULLIF(b.shipped_orders, 0))         AS c_inv_rto,
        1 - LEAST(b.catalog_returned_units * 1.0 / NULLIF(b.delivered_units, 0), 1) AS c_inv_catalog,
        -- no returns but has deliveries => 0 damage => component 1 (best).
        CASE WHEN b.returned_units > 0
             THEN 1 - b.damage_returned_units * 1.0 / b.returned_units
             WHEN b.delivered_orders > 0 THEN 1.0
             ELSE NULL END                                            AS c_inv_damage,
        -- delivery-attempt efficiency: 1 attempt -> 1.0, 3 -> 0.0 (delivered range).
        CASE WHEN b.delivered_orders > 0
             THEN GREATEST(0, 1 - (b.avg_delivery_attempts - 1) / 2.0)
             ELSE NULL END                                            AS c_deliv_eff,
        b.average_listing_quality_score / 100.0                       AS c_lqs,
        CASE b.seller_tier WHEN 'T1' THEN 1.0 WHEN 'T2' THEN 0.67
             WHEN 'T3' THEN 0.33 ELSE 0.0 END                         AS c_tier
    FROM base b
),

trust AS (
    SELECT d.*,
        ROUND(100.0 * (
              COALESCE(w_ontime      * c_on_time,    0)
            + COALESCE(w_inv_rto     * c_inv_rto,    0)
            + COALESCE(w_inv_catalog * c_inv_catalog, 0)
            + COALESCE(w_inv_damage  * c_inv_damage, 0)
            + COALESCE(w_deliv_eff   * c_deliv_eff,  0)
            + COALESCE(w_lqs         * c_lqs,        0)
            + COALESCE(w_tier        * c_tier,       0)
        ) / NULLIF(
              CASE WHEN c_on_time     IS NOT NULL THEN w_ontime      ELSE 0 END
            + CASE WHEN c_inv_rto     IS NOT NULL THEN w_inv_rto     ELSE 0 END
            + CASE WHEN c_inv_catalog IS NOT NULL THEN w_inv_catalog ELSE 0 END
            + CASE WHEN c_inv_damage  IS NOT NULL THEN w_inv_damage  ELSE 0 END
            + CASE WHEN c_deliv_eff   IS NOT NULL THEN w_deliv_eff   ELSE 0 END
            + CASE WHEN c_lqs         IS NOT NULL THEN w_lqs         ELSE 0 END
            + CASE WHEN c_tier        IS NOT NULL THEN w_tier        ELSE 0 END, 0)
        , 2) AS trust_score
    FROM derived d
)

-- ---- FINAL: add cross-seller rankings (windows). ----
SELECT
    seller_id, seller_name, seller_country, fulfillment_type, seller_tier,
    primary_category,
    listing_count, active_listing_count,
    total_orders, delivered_orders, shipped_orders, rto_orders,
    cancelled_orders, returned_orders,
    delivered_units, returned_units, catalog_returned_units,
    -- Economics.
    gross_margin, return_cost, net_margin_after_returns,
    ROUND(net_margin_after_returns_pct, 6) AS net_margin_after_returns_pct,
    realized_net_revenue, returned_value, recovered_value, recoverable_profit, rto_cost,
    -- Rates.
    ROUND(catalog_return_rate, 6) AS catalog_return_rate,
    ROUND(rto_rate, 6)            AS rto_rate,
    ROUND(recovery_rate, 6)       AS recovery_rate,
    ROUND(on_time_delivery_rate, 6) AS on_time_delivery_rate,
    ROUND(avg_delivery_attempts, 4) AS avg_delivery_attempts,
    ROUND(damage_return_share, 6) AS damage_return_share,
    ROUND(average_listing_quality_score, 2) AS average_listing_quality_score,
    -- Trust Score (born here).
    trust_score,
    -- Toxic-RTO ingredients (concentration scalar lives in the exec table).
    rto_cost AS seller_rto_cost,
    ROW_NUMBER() OVER (ORDER BY rto_cost DESC, seller_id) AS rto_cost_rank,
    (PERCENT_RANK() OVER (ORDER BY rto_cost DESC) <= toxic_top_fraction) AS is_top_decile_rto_cost,
    (rto_rate > toxic_rate_threshold AND shipped_orders >= min_shipped_orders) AS is_toxic_rto,
    -- Category-adjusted benchmarking: percentile of net margin within the
    -- seller's primary category (1.0 = best-in-category).
    ROUND(PERCENT_RANK() OVER (PARTITION BY primary_category
                               ORDER BY net_margin_after_returns), 4)
        AS seller_percentile_within_category
FROM trust;

-- =====================================================================
-- VALIDATION QUERIES  (each returns check | value | pass)
-- =====================================================================
-- V1 One row per seller, ~450, no duplicate seller_id.
SELECT 'row_count_450' AS check, COUNT(*) AS value,
       COUNT(*) = (SELECT COUNT(*) FROM read_csv_auto('data/02_silver/dim_seller.csv'))
   AND COUNT(*) = COUNT(DISTINCT seller_id) AS pass
FROM gold_seller_metrics;

-- V2 Trust Score bounded to [0,100] and never NULL.
SELECT 'trust_score_bounds' AS check,
       ROUND(MIN(trust_score), 2) || ' .. ' || ROUND(MAX(trust_score), 2) AS value,
       MIN(trust_score) >= 0 AND MAX(trust_score) <= 100
   AND COUNT(*) FILTER (WHERE trust_score IS NULL) = 0 AS pass
FROM gold_seller_metrics;

-- V3 Reconcile row-level totals vs gold_listing_metrics.
SELECT 'reconcile_listing_mart' AS check, NULL AS value,
       SUM(listing_count)  = (SELECT COUNT(*) FROM gold_listing_metrics)
   AND SUM(total_orders)   = (SELECT SUM(total_orders) FROM gold_listing_metrics)
   AND SUM(delivered_orders) = (SELECT SUM(delivered_orders) FROM gold_listing_metrics)
   AND SUM(rto_orders)     = (SELECT SUM(rto_orders) FROM gold_listing_metrics)
   AND SUM(returned_orders) = (SELECT SUM(returned_orders) FROM gold_listing_metrics)
   AND ABS(SUM(recoverable_profit) - (SELECT SUM(recoverable_profit) FROM gold_listing_metrics)) < 0.01 AS pass
FROM gold_seller_metrics;

-- V4 Gross-margin reconciliation (seller totals == F1 total).
SELECT 'gross_margin_reconcile' AS check, ROUND(SUM(gross_margin), 2) AS value,
       ABS(SUM(gross_margin) - (SELECT SUM(gross_margin_aed) FROM gold_order_line_economics)) < 0.01 AS pass
FROM gold_seller_metrics;

-- V5 Return-cost reconciliation (seller totals == F2 total).
SELECT 'return_cost_reconcile' AS check, ROUND(SUM(return_cost), 2) AS value,
       ABS(SUM(return_cost) - (SELECT SUM(return_cost_aed) FROM gold_return_line_economics)) < 0.01 AS pass
FROM gold_seller_metrics;

-- V6 Margin identity holds per seller.
SELECT 'margin_identity' AS check,
       COUNT(*) FILTER (WHERE ABS(net_margin_after_returns - (gross_margin - return_cost)) > 0.001) AS value,
       COUNT(*) FILTER (WHERE ABS(net_margin_after_returns - (gross_margin - return_cost)) > 0.001) = 0 AS pass
FROM gold_seller_metrics;

-- V7 Seller ranking consistency: rto_cost_rank is a strict 1..N permutation
--    and rank 1 carries the maximum RTO cost.
SELECT 'ranking_consistency' AS check, MAX(rto_cost_rank) AS value,
       COUNT(*) = COUNT(DISTINCT rto_cost_rank)
   AND MAX(rto_cost_rank) = COUNT(*)
   AND (SELECT seller_rto_cost FROM gold_seller_metrics WHERE rto_cost_rank = 1)
       = (SELECT MAX(seller_rto_cost) FROM gold_seller_metrics) AS pass
FROM gold_seller_metrics;

-- V8 Rate bounds within [0,1]; percentile within [0,1].
SELECT 'rate_and_percentile_bounds' AS check, NULL AS value,
       COALESCE(MAX(catalog_return_rate),0) <= 1 AND COALESCE(MIN(catalog_return_rate),0) >= 0
   AND COALESCE(MAX(rto_rate),0) <= 1 AND COALESCE(MAX(recovery_rate),0) <= 1
   AND COALESCE(MAX(on_time_delivery_rate),0) <= 1
   AND MIN(seller_percentile_within_category) >= 0 AND MAX(seller_percentile_within_category) <= 1 AS pass
FROM gold_seller_metrics;

-- V9 Null-rate checks: attributes/economics/trust never NULL; a NULL rate
--    implies a zero denominator (undefined), never a populated one.
SELECT 'null_rules' AS check,
       COUNT(*) FILTER (WHERE trust_score IS NULL OR gross_margin IS NULL
                          OR return_cost IS NULL OR net_margin_after_returns IS NULL
                          OR seller_tier IS NULL) AS value,
       COUNT(*) FILTER (WHERE trust_score IS NULL OR gross_margin IS NULL
                          OR return_cost IS NULL OR net_margin_after_returns IS NULL
                          OR seller_tier IS NULL) = 0
   AND COUNT(*) FILTER (WHERE catalog_return_rate IS NULL AND delivered_units > 0) = 0
   AND COUNT(*) FILTER (WHERE rto_rate IS NULL AND shipped_orders > 0) = 0
   AND COUNT(*) FILTER (WHERE recovery_rate IS NULL AND returned_units > 0) = 0 AS pass
FROM gold_seller_metrics;
