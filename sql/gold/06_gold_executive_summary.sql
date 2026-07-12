-- =====================================================================
-- Gold Consumption Table — gold_executive_summary  (Executive KPI table)
-- =====================================================================
-- Grain      : one row per executive KPI (17 rows).   [PK (as_of_date_key, kpi_name)]
-- Purpose    : Power BI Page 1. Answers: "How big is the return/RTO leakage
--              problem, and where is the biggest recovery opportunity?"
-- Nature     : Pure marketplace-grain AGGREGATION of already-validated Gold
--              marts. No metric is recomputed (LQS / Trust / Return Cost /
--              Recoverable Profit are all reused).
-- Inputs     : gold_listing_metrics, gold_seller_metrics, gold_category_metrics,
--              gold_order_line_economics, gold_return_line_economics.
-- Golden Rules: R2 — net_margin_after_returns EXCLUDES RTO; return rates use
--              delivered-only denominators.
-- Dialect    : DuckDB. Run order: AFTER 01_..05_.
-- =====================================================================

-- ---- BUILD ----------------------------------------------------------
CREATE OR REPLACE TABLE gold_executive_summary AS
WITH
-- Marketplace roll-up from the listing mart (single row of totals).
mkt AS (
    SELECT
        SUM(total_orders)                                   AS total_orders,
        SUM(delivered_orders)                               AS delivered_orders,
        SUM(returned_orders)                                AS returned_orders,
        SUM(rto_orders)                                     AS rto_orders,
        SUM(shipped_orders)                                 AS shipped_orders,
        SUM(delivered_units)                                AS delivered_units,
        SUM(catalog_returned_units)                         AS catalog_returned_units,
        SUM(returned_value)                                 AS returned_value,
        SUM(recovered_value)                                AS recovered_value,
        SUM(realized_net_revenue)                           AS realized_net_revenue,
        SUM(gross_margin)                                   AS total_gross_margin,
        SUM(return_cost)                                    AS total_return_cost,
        SUM(recoverable_profit)                             AS total_recoverable_profit,
        COUNT(*) FILTER (WHERE net_margin_after_returns < 0) AS loss_making_listing_count
    FROM gold_listing_metrics
),

-- Bottom-LQS band = listings in the lowest LQS quartile (data-driven band).
-- These KPIs show whether poor-quality listings carry disproportionate
-- revenue / return cost — an executive aggregation, not a new metric.
lqs_band AS (
    SELECT quantile_cont(listing_quality_score, 0.25) AS p25_lqs
    FROM gold_listing_metrics
),
bottom_lqs AS (
    SELECT
        SUM(realized_net_revenue) AS bottom_lqs_revenue,
        SUM(return_cost)          AS bottom_lqs_return_cost
    FROM gold_listing_metrics
    WHERE listing_quality_score <= (SELECT p25_lqs FROM lqs_band)
),

-- Toxic RTO concentration (executive scalar): share of total RTO cost held by
-- the top-decile sellers. Uses the seller mart's top-decile INGREDIENT flag,
-- NOT is_toxic_rto (which is 0 on this dataset).
toxic AS (
    SELECT
        SUM(seller_rto_cost) FILTER (WHERE is_top_decile_rto_cost)
            / NULLIF(SUM(seller_rto_cost), 0) AS toxic_rto_concentration
    FROM gold_seller_metrics
),

-- Fashion shares taken straight from the category mart, so they reconcile by
-- construction (no re-derivation of Return Cost / Recoverable Profit).
fashion AS (
    SELECT
        percentage_of_marketplace_return_cost        AS fashion_return_cost_share,
        percentage_of_marketplace_recoverable_profit AS fashion_recoverable_profit_share
    FROM gold_category_metrics
    WHERE category = 'Fashion'
),

-- Single-row wide frame of every KPI, cast to DOUBLE for a uniform value column.
agg AS (
    SELECT
        mkt.total_orders::DOUBLE                             AS total_orders,
        mkt.delivered_orders::DOUBLE                         AS delivered_orders,
        mkt.returned_orders::DOUBLE                          AS returned_orders,
        mkt.rto_orders::DOUBLE                               AS rto_orders,
        mkt.total_gross_margin::DOUBLE                       AS total_gross_margin,
        mkt.total_return_cost::DOUBLE                        AS total_return_cost,
        mkt.total_recoverable_profit::DOUBLE                 AS total_recoverable_profit,
        -- net margin after returns EXCLUDES RTO (Golden Rule 2).
        (mkt.total_gross_margin - mkt.total_return_cost)::DOUBLE AS net_margin_after_returns,
        (mkt.catalog_returned_units * 1.0 / NULLIF(mkt.delivered_units, 0))::DOUBLE AS marketplace_catalog_return_rate,
        (mkt.rto_orders * 1.0 / NULLIF(mkt.shipped_orders, 0))::DOUBLE AS marketplace_rto_rate,
        (mkt.recovered_value / NULLIF(mkt.returned_value, 0))::DOUBLE AS aggregate_recovery_rate,
        toxic.toxic_rto_concentration::DOUBLE                AS toxic_rto_concentration,
        fashion.fashion_return_cost_share::DOUBLE            AS fashion_return_cost_share,
        fashion.fashion_recoverable_profit_share::DOUBLE     AS fashion_recoverable_profit_share,
        (bottom_lqs.bottom_lqs_revenue / NULLIF(mkt.realized_net_revenue, 0))::DOUBLE AS bottom_lqs_revenue_share,
        (bottom_lqs.bottom_lqs_return_cost / NULLIF(mkt.total_return_cost, 0))::DOUBLE AS bottom_lqs_return_cost_share,
        mkt.loss_making_listing_count::DOUBLE                AS loss_making_listing_count
    FROM mkt, toxic, fashion, bottom_lqs
),

-- Pivot the wide frame into the tall KPI grain.
unpvt AS (
    UNPIVOT agg
    ON  total_orders, delivered_orders, returned_orders, rto_orders,
        total_gross_margin, total_return_cost, total_recoverable_profit, net_margin_after_returns,
        marketplace_catalog_return_rate, marketplace_rto_rate, aggregate_recovery_rate,
        toxic_rto_concentration, fashion_return_cost_share, fashion_recoverable_profit_share,
        bottom_lqs_revenue_share, bottom_lqs_return_cost_share, loss_making_listing_count
    INTO NAME kpi_name VALUE kpi_value
),

-- KPI presentation metadata (label / group / unit / display order).
meta(kpi_name, kpi_label, kpi_group, kpi_unit, kpi_sort) AS (
    VALUES
        ('total_orders',                    'Total Orders',                      'Volume',    'count', 1),
        ('delivered_orders',                'Delivered Orders',                  'Volume',    'count', 2),
        ('returned_orders',                 'Returned Orders',                   'Volume',    'count', 3),
        ('rto_orders',                      'RTO Orders',                        'Volume',    'count', 4),
        ('total_gross_margin',              'Total Gross Margin',                'Financial', 'aed',   5),
        ('total_return_cost',               'Total Return Cost',                 'Financial', 'aed',   6),
        ('total_recoverable_profit',        'Total Recoverable Profit',          'Financial', 'aed',   7),
        ('net_margin_after_returns',        'Net Margin After Returns',          'Financial', 'aed',   8),
        ('marketplace_catalog_return_rate', 'Marketplace Catalog Return Rate',   'Rate',      'rate',  9),
        ('marketplace_rto_rate',            'Marketplace RTO Rate',              'Rate',      'rate', 10),
        ('aggregate_recovery_rate',         'Aggregate Recovery Rate',           'Rate',      'rate', 11),
        ('toxic_rto_concentration',         'Toxic RTO Concentration (top 10%)', 'Risk',      'share',12),
        ('fashion_return_cost_share',       'Fashion Share of Return Cost',      'Risk',      'share',13),
        ('fashion_recoverable_profit_share','Fashion Share of Recoverable Profit','Risk',     'share',14),
        ('bottom_lqs_revenue_share',        'Bottom-LQS Revenue Share',          'Quality Risk','share',15),
        ('bottom_lqs_return_cost_share',    'Bottom-LQS Return Cost Share',      'Quality Risk','share',16),
        ('loss_making_listing_count',       'Loss-Making Listings',              'Quality Risk','count',17)
)

SELECT
    20260707 AS as_of_date_key,          -- config/metrics.yaml as_of_date_key
    m.kpi_sort,
    m.kpi_group,
    u.kpi_name,
    m.kpi_label,
    m.kpi_unit,
    u.kpi_value
FROM unpvt u
JOIN meta m USING (kpi_name)
ORDER BY m.kpi_sort;

-- =====================================================================
-- VALIDATION QUERIES  (check | expected | actual | pass)
-- =====================================================================
-- Helper convention: KPI values are read as
--   (SELECT kpi_value FROM gold_executive_summary WHERE kpi_name = '<name>')

-- 1. KPI names are unique.
SELECT 'kpi_names_unique' AS check, 'count = distinct' AS expected,
       COUNT(*)::VARCHAR || ' / ' || COUNT(DISTINCT kpi_name)::VARCHAR AS actual,
       COUNT(*) = COUNT(DISTINCT kpi_name) AS pass
FROM gold_executive_summary;

-- 2. KPI count within the expected range (12..20).
SELECT 'kpi_count_range' AS check, '12..20' AS expected, COUNT(*)::VARCHAR AS actual,
       COUNT(*) BETWEEN 12 AND 20 AS pass
FROM gold_executive_summary;

-- 3. No NULL KPI values (none are allowed to be NULL on this dataset).
SELECT 'no_null_values' AS check, '0' AS expected,
       COUNT(*) FILTER (WHERE kpi_value IS NULL)::VARCHAR AS actual,
       COUNT(*) FILTER (WHERE kpi_value IS NULL) = 0 AS pass
FROM gold_executive_summary;

-- 4. Total gross margin reconciles to listing, category AND seller marts.
SELECT 'gross_margin_reconcile' AS check,
       ROUND((SELECT SUM(gross_margin) FROM gold_listing_metrics), 2)::VARCHAR AS expected,
       ROUND((SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='total_gross_margin'), 2)::VARCHAR AS actual,
       ABS((SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='total_gross_margin')
           - (SELECT SUM(gross_margin) FROM gold_listing_metrics)) < 0.01
   AND ABS((SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='total_gross_margin')
           - (SELECT SUM(gross_margin) FROM gold_category_metrics)) < 0.01
   AND ABS((SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='total_gross_margin')
           - (SELECT SUM(gross_margin) FROM gold_seller_metrics)) < 0.01 AS pass;

-- 5. Total return cost reconciles to listing, category AND seller marts.
SELECT 'return_cost_reconcile' AS check,
       ROUND((SELECT SUM(return_cost) FROM gold_listing_metrics), 2)::VARCHAR AS expected,
       ROUND((SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='total_return_cost'), 2)::VARCHAR AS actual,
       ABS((SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='total_return_cost')
           - (SELECT SUM(return_cost) FROM gold_listing_metrics)) < 0.01
   AND ABS((SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='total_return_cost')
           - (SELECT SUM(return_cost) FROM gold_category_metrics)) < 0.01
   AND ABS((SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='total_return_cost')
           - (SELECT SUM(return_cost) FROM gold_seller_metrics)) < 0.01 AS pass;

-- 6. Total recoverable profit reconciles to listing AND category marts.
SELECT 'recoverable_profit_reconcile' AS check,
       ROUND((SELECT SUM(recoverable_profit) FROM gold_listing_metrics), 2)::VARCHAR AS expected,
       ROUND((SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='total_recoverable_profit'), 2)::VARCHAR AS actual,
       ABS((SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='total_recoverable_profit')
           - (SELECT SUM(recoverable_profit) FROM gold_listing_metrics)) < 0.01
   AND ABS((SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='total_recoverable_profit')
           - (SELECT SUM(recoverable_profit) FROM gold_category_metrics)) < 0.01 AS pass;

-- 7. Marketplace rate KPIs are within [0,1].
SELECT 'rate_bounds_0_1' AS check, 'all in [0,1]' AS expected,
       'checked' AS actual,
       BOOL_AND(kpi_value BETWEEN 0 AND 1) AS pass
FROM gold_executive_summary
WHERE kpi_name IN ('marketplace_catalog_return_rate','marketplace_rto_rate','aggregate_recovery_rate');

-- 8. Toxic RTO concentration is within [0,1].
SELECT 'toxic_rto_concentration_bounds' AS check, '[0,1]' AS expected,
       ROUND((SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='toxic_rto_concentration'), 4)::VARCHAR AS actual,
       (SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='toxic_rto_concentration') BETWEEN 0 AND 1 AS pass;

-- 9. Bottom-LQS shares are within [0,1].
SELECT 'bottom_lqs_share_bounds' AS check, 'all in [0,1]' AS expected, 'checked' AS actual,
       BOOL_AND(kpi_value BETWEEN 0 AND 1) AS pass
FROM gold_executive_summary
WHERE kpi_name IN ('bottom_lqs_revenue_share','bottom_lqs_return_cost_share');

-- 10. Fashion shares reconcile to the category mart.
SELECT 'fashion_shares_reconcile' AS check, 'match category mart' AS expected,
       ROUND((SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='fashion_return_cost_share'), 6)::VARCHAR AS actual,
       ABS((SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='fashion_return_cost_share')
           - (SELECT percentage_of_marketplace_return_cost FROM gold_category_metrics WHERE category='Fashion')) < 1e-6
   AND ABS((SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='fashion_recoverable_profit_share')
           - (SELECT percentage_of_marketplace_recoverable_profit FROM gold_category_metrics WHERE category='Fashion')) < 1e-6 AS pass;

-- 11. Loss-making listing count reconciles to the listing mart.
SELECT 'loss_making_reconcile' AS check,
       (SELECT COUNT(*) FROM gold_listing_metrics WHERE net_margin_after_returns < 0)::VARCHAR AS expected,
       (SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='loss_making_listing_count')::VARCHAR AS actual,
       (SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='loss_making_listing_count')
           = (SELECT COUNT(*) FROM gold_listing_metrics WHERE net_margin_after_returns < 0) AS pass;

-- 12. Order-count KPIs reconcile to the foundational facts / listing mart.
SELECT 'order_counts_reconcile' AS check, '85000/74780/32005/8096' AS expected,
       (SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='total_orders')::BIGINT::VARCHAR || '/' ||
       (SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='delivered_orders')::BIGINT::VARCHAR || '/' ||
       (SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='returned_orders')::BIGINT::VARCHAR || '/' ||
       (SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='rto_orders')::BIGINT::VARCHAR AS actual,
       (SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='total_orders') = (SELECT COUNT(*) FROM gold_order_line_economics)
   AND (SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='delivered_orders') = (SELECT SUM(is_delivered::INT) FROM gold_order_line_economics)
   AND (SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='returned_orders') = (SELECT COUNT(*) FROM gold_return_line_economics)
   AND (SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='rto_orders') = (SELECT SUM(is_rto::INT) FROM gold_order_line_economics) AS pass;

-- 13. Financial identity: net_margin_after_returns = gross_margin - return_cost.
SELECT 'financial_identity' AS check, '0 diff' AS expected,
       ROUND((SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='net_margin_after_returns')
             - ((SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='total_gross_margin')
                - (SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='total_return_cost')), 4)::VARCHAR AS actual,
       ABS((SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='net_margin_after_returns')
           - ((SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='total_gross_margin')
              - (SELECT kpi_value FROM gold_executive_summary WHERE kpi_name='total_return_cost'))) < 0.01 AS pass;
