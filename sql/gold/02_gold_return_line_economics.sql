-- =====================================================================
-- Gold Foundational Fact F2 — gold_return_line_economics
-- =====================================================================
-- Grain      : one row per return line (fact_returns row).      [PK return_id]
-- Purpose    : Materialize the fully-loaded RETURN COST once — reverse
--              logistics + warehouse handling + merchandise loss net of
--              salvage — plus the recovery and catalog-attribution inputs.
--              Consumed by the listing / category / seller / intervention
--              layers (CLAUDE.md: "No duplicated business logic").
-- Metrics    : return_cost, recovery_rate, catalog_return_rate attribution
--              (config/metrics.yaml). See docs/gold_data_model.md §F2.
-- Golden Rule 1: return_cost is DERIVED-ONLY — this is its legal birthplace;
--              it must never appear in Bronze/Silver.
-- Golden Rule 2: fact_returns is delivered-only by construction; validated below.
-- Dialect    : DuckDB. Run order: AFTER 01_gold_order_line_economics.sql
--              (this file reads the gold_order_line_economics table for the
--              order-line value / zone / weight-band derived there once).
-- NOT computed here (later phases): LQS, Recoverable Profit.
-- =====================================================================

-- ---- SOURCE BINDINGS (Silver, read-only; idempotent) ----------------
CREATE OR REPLACE VIEW silver_fact_returns AS
  SELECT * FROM read_csv_auto('data/02_silver/fact_returns.csv');
CREATE OR REPLACE VIEW silver_dim_return_reason AS
  SELECT * FROM read_csv_auto('data/02_silver/dim_return_reason.csv');
CREATE OR REPLACE VIEW silver_ref_category_economics AS
  SELECT * FROM read_csv_auto('data/02_silver/ref_category_economics.csv');
CREATE OR REPLACE VIEW silver_ref_logistics_rate_card AS
  SELECT * FROM read_csv_auto('data/02_silver/ref_logistics_rate_card.csv');

-- ---- BUILD ----------------------------------------------------------
CREATE OR REPLACE TABLE gold_return_line_economics AS
WITH
-- Join each return to its order line (F1 gives value, category, zone, band —
-- derived once upstream), to category economics (handling + recovery ratios)
-- and to the return-reason lookup (catalog attribution).
returns_joined AS (
    SELECT
        r.return_id,
        r.order_line_id,
        o.listing_id,
        o.seller_id,
        o.category,
        o.logistics_zone,
        o.weight_band,
        o.unit_selling_price,
        o.gross_margin_pct,
        r.return_initiated_date_key,
        r.return_received_date_key,
        r.item_condition_on_receipt,
        r.quantity_returned,
        r.refund_amount,
        r.reported_reason_code,
        rr.reason_group,
        COALESCE(rr.is_catalog_related, FALSE) AS is_catalog_related,
        r.dq_missing_reported_reason_code       AS is_reason_missing,
        ce.warehouse_handling_cost_aed,
        ce.recovery_pct_resellable,
        ce.recovery_pct_refurbishable
    FROM silver_fact_returns r
    -- INNER join enforces the delivered-only linkage (Golden Rule 2).
    JOIN gold_order_line_economics o          ON r.order_line_id = o.order_line_id
    LEFT JOIN silver_dim_return_reason rr      ON r.reported_reason_code = rr.reason_code
    LEFT JOIN silver_ref_category_economics ce ON o.category = ce.category
),

-- Apply the condition -> recovery mapping (metrics.yaml condition_recovery_map)
-- and the reverse-leg logistics cost.
costed AS (
    SELECT
        rj.*,
        -- Salvage ratio by receipt condition; write_off = total loss (0).
        CASE rj.item_condition_on_receipt
            WHEN 'resellable'    THEN rj.recovery_pct_resellable
            WHEN 'refurbishable' THEN rj.recovery_pct_refurbishable
            WHEN 'write_off'     THEN 0.0
            ELSE 0.0  -- defensive; item_condition is normalized in Silver
        END AS recovery_pct,
        rc_rev.cost_aed AS reverse_logistics_cost_aed,
        rj.quantity_returned * rj.unit_selling_price AS returned_value_aed
    FROM returns_joined rj
    LEFT JOIN silver_ref_logistics_rate_card rc_rev
        ON  rc_rev.logistics_zone = rj.logistics_zone
        AND rc_rev.weight_band    = rj.weight_band
        AND rc_rev.leg            = 'reverse'
)

SELECT
    return_id,
    order_line_id,
    listing_id,
    seller_id,
    category,
    reported_reason_code,
    reason_group,
    return_initiated_date_key,
    return_received_date_key,
    item_condition_on_receipt,
    quantity_returned,
    unit_selling_price,
    -- Merchandise value & salvage.
    ROUND(returned_value_aed, 4)                          AS returned_value_aed,
    recovery_pct,
    ROUND(returned_value_aed * recovery_pct, 4)           AS recovered_value_aed,
    -- Return-cost components (defined ONCE here; summed downstream).
    reverse_logistics_cost_aed,
    warehouse_handling_cost_aed                            AS handling_cost_aed,
    ROUND(refund_amount - returned_value_aed * recovery_pct, 4) AS merchandise_loss_aed,
    -- return_cost = reverse logistics + handling + (refund - salvage).
    ROUND(reverse_logistics_cost_aed
          + warehouse_handling_cost_aed
          + (refund_amount - returned_value_aed * recovery_pct), 4) AS return_cost_aed,
    refund_amount,
    -- Catalog attribution (drives catalog_return_rate & recoverable_profit).
    is_catalog_related,
    is_reason_missing
FROM costed;

-- =====================================================================
-- VALIDATION QUERIES  (each returns check | value | pass)
-- =====================================================================
-- V1 Row count preserved vs Silver fact_returns (expect 32,005).
SELECT 'row_count' AS check, COUNT(*) AS value, COUNT(*) = 32005 AS pass
FROM gold_return_line_economics;

-- V2 Primary key is unique & non-null.
SELECT 'pk_unique' AS check, COUNT(*) AS value,
       COUNT(*) = COUNT(DISTINCT return_id) AND COUNT(return_id) = COUNT(*) AS pass
FROM gold_return_line_economics;

-- V3 Golden Rule 2 — every return line traces to a DELIVERED order line.
SELECT 'golden_rule_2_delivered_only' AS check,
       COUNT(*) FILTER (WHERE NOT o.is_delivered) AS value,
       COUNT(*) FILTER (WHERE NOT o.is_delivered) = 0 AS pass
FROM gold_return_line_economics r
JOIN gold_order_line_economics o USING (order_line_id);

-- V4 Salvage never exceeds merchandise value (recovery_pct <= 1).
SELECT 'recovered_le_returned' AS check,
       COUNT(*) FILTER (WHERE recovered_value_aed > returned_value_aed) AS value,
       COUNT(*) FILTER (WHERE recovered_value_aed > returned_value_aed) = 0 AS pass
FROM gold_return_line_economics;

-- V5 Recovery ratio within [0, 1].
SELECT 'recovery_pct_bounds' AS check, NULL AS value,
       MIN(recovery_pct) >= 0 AND MAX(recovery_pct) <= 1 AS pass
FROM gold_return_line_economics;

-- V6 write_off condition yields zero salvage.
SELECT 'writeoff_zero_recovery' AS check,
       COUNT(*) FILTER (WHERE item_condition_on_receipt = 'write_off'
                          AND recovered_value_aed <> 0) AS value,
       COUNT(*) FILTER (WHERE item_condition_on_receipt = 'write_off'
                          AND recovered_value_aed <> 0) = 0 AS pass
FROM gold_return_line_economics;

-- V7 Logistics and handling cost components are populated and positive.
SELECT 'cost_components_positive' AS check,
       COUNT(*) FILTER (WHERE reverse_logistics_cost_aed IS NULL
                          OR reverse_logistics_cost_aed <= 0
                          OR handling_cost_aed <= 0) AS value,
       COUNT(*) FILTER (WHERE reverse_logistics_cost_aed IS NULL
                          OR reverse_logistics_cost_aed <= 0
                          OR handling_cost_aed <= 0) = 0 AS pass
FROM gold_return_line_economics;

-- V8 return_cost identity holds (components sum to the total).
SELECT 'return_cost_identity' AS check,
       COUNT(*) FILTER (WHERE ROUND(reverse_logistics_cost_aed + handling_cost_aed
                                    + merchandise_loss_aed, 4) <> return_cost_aed) AS value,
       COUNT(*) FILTER (WHERE ROUND(reverse_logistics_cost_aed + handling_cost_aed
                                    + merchandise_loss_aed, 4) <> return_cost_aed) = 0 AS pass
FROM gold_return_line_economics;

-- V9 Aggregate recovery_rate (SUM salvage / SUM value) within [0, 1].
SELECT 'recovery_rate_aggregate' AS check,
       ROUND(SUM(recovered_value_aed) / NULLIF(SUM(returned_value_aed), 0), 4) AS value,
       (SUM(recovered_value_aed) / NULLIF(SUM(returned_value_aed), 0)) BETWEEN 0 AND 1 AS pass
FROM gold_return_line_economics;
