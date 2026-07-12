-- =====================================================================
-- Gold Decision Engine — gold_intervention_queue
-- =====================================================================
-- Grain      : one row per recommended intervention.        [PK intervention_id]
-- Natural key: (entity_type, entity_id, intervention_type).
-- Purpose    : Turn marketplace analytics into a prioritized worklist that
--              answers "with limited resources this week, what do we fix first
--              to maximize recovered profit?" Every row is ranked on ONE
--              comparable unit: priority_opportunity_aed.
-- Inputs     : gold_listing_metrics, gold_seller_metrics, gold_category_metrics,
--              gold_return_line_economics (for the catalog return-cost split).
-- Rules      : Reuse upstream metrics only. LQS / Trust / Return Cost /
--              Recoverable Profit are NEVER recomputed here.
-- Anti-double-count: recoverable_profit is attributed ONCE — either to a
--              listing's Catalog Fix row, or (for systemic sellers) aggregated
--              into a Seller Coaching row whose listings are then suppressed
--              from Catalog Fix. Delisting uses net-loss-stopped and COD Risk
--              uses RTO cost — distinct AED dimensions.
-- Dialect    : DuckDB. Run order: AFTER 01_..06_.
-- =====================================================================

CREATE OR REPLACE TABLE gold_intervention_queue AS
WITH
-- Tunable thresholds (mirror a future config/gold_model.yaml; keep in sync).
params AS (
    SELECT 70.0  AS lqs_cutoff,           -- below this LQS a listing is "improvable"
           45.0  AS delist_lqs,           -- below this + loss-making => beyond repair
           100.0 AS min_opportunity_aed,  -- materiality floor for any queued action
           8     AS coach_min_listings    -- systemic threshold => coach the seller
),

-- Per-listing catalog return cost (re-aggregated from F2; reused, not recomputed).
-- recoverable_profit = catalog_return_cost + forgone_catalog_margin, so this
-- lets us split the opportunity into cost-reduction vs margin-recovery.
listing_catalog_econ AS (
    SELECT listing_id,
           SUM(return_cost_aed) FILTER (WHERE is_catalog_related) AS catalog_return_cost
    FROM gold_return_line_economics
    GROUP BY listing_id
),

-- Classify each listing into at most one listing-level intervention.
listing_classified AS (
    SELECT l.*,
           COALESCE(ce.catalog_return_cost, 0) AS catalog_return_cost,
           CASE
               WHEN l.net_margin_after_returns < 0
                    AND l.listing_quality_score < p.delist_lqs
                    AND -l.net_margin_after_returns >= p.min_opportunity_aed
                    THEN 'delist'
               WHEN l.listing_quality_score < p.lqs_cutoff
                    AND l.recoverable_profit >= p.min_opportunity_aed
                    THEN 'catalog'
               ELSE NULL
           END AS intervention_class
    FROM gold_listing_metrics l
    LEFT JOIN listing_catalog_econ ce USING (listing_id)
    CROSS JOIN params p
),
listing_candidates AS (
    SELECT * FROM listing_classified WHERE intervention_class IS NOT NULL
),

-- Systemic sellers: many catalog-eligible listings => coach the seller instead
-- of raising many individual Catalog Fix tickets. This aggregates (and later
-- SUPPRESSES) those listings so recoverable_profit is never double-counted.
seller_catalog_rollup AS (
    SELECT seller_id,
           COUNT(*)                    AS catalog_listing_count,
           SUM(recoverable_profit)     AS total_recoverable_profit,
           SUM(catalog_return_cost)    AS total_catalog_return_cost
    FROM listing_candidates
    WHERE intervention_class = 'catalog'
    GROUP BY seller_id
),
coached_sellers AS (
    SELECT * FROM seller_catalog_rollup
    WHERE catalog_listing_count >= (SELECT coach_min_listings FROM params)
),

-- ================= INTERVENTION SET 1: CATALOG FIX (listing) =================
-- Individual content fixes for improvable listings whose seller is NOT being
-- coached (isolated bad listings). Opportunity = listing recoverable_profit.
catalog_fix AS (
    SELECT
        'listing' AS entity_type, lc.listing_id AS entity_id, lc.category, lc.seller_id,
        'Catalog Fix' AS intervention_type,
        concat('Low LQS (', ROUND(lc.listing_quality_score, 0),
               ') with AED ', ROUND(lc.recoverable_profit, 0),
               ' catalog-return leakage') AS intervention_reason,
        lc.recoverable_profit                              AS priority_opportunity_aed,
        lc.catalog_return_cost                             AS estimated_return_cost_reduction,
        lc.recoverable_profit - lc.catalog_return_cost     AS estimated_margin_recovery,
        lc.recoverable_profit                              AS estimated_recoverable_profit,
        lc.listing_quality_score, sm.trust_score, lc.catalog_return_rate, lc.rto_rate,
        lc.return_cost, lc.gross_margin, lc.net_margin_after_returns,
        'Catalog Operations' AS recommended_owner,
        'Add images / specs / description to cut catalog-driven returns' AS expected_business_outcome,
        concat('Fix catalog for ', lc.listing_id, ' to recover ~AED ',
               ROUND(lc.recoverable_profit, 0)) AS recommendation_summary
    FROM listing_candidates lc
    JOIN gold_seller_metrics sm USING (seller_id)
    WHERE lc.intervention_class = 'catalog'
      AND lc.seller_id NOT IN (SELECT seller_id FROM coached_sellers)
),

-- ================= INTERVENTION SET 2: DELISTING (listing) ===================
-- Loss-making, very-low-quality listings beyond catalog repair.
-- Opportunity = net loss stopped (-net_margin_after_returns).
delist AS (
    SELECT
        'listing' AS entity_type, lc.listing_id AS entity_id, lc.category, lc.seller_id,
        'Delisting Candidate' AS intervention_type,
        concat('Loss-making (net AED ', ROUND(lc.net_margin_after_returns, 0),
               ') with very low LQS (', ROUND(lc.listing_quality_score, 0), ')') AS intervention_reason,
        -lc.net_margin_after_returns                       AS priority_opportunity_aed,
        -lc.net_margin_after_returns                       AS estimated_return_cost_reduction,
        0.0                                                AS estimated_margin_recovery,
        -lc.net_margin_after_returns                       AS estimated_recoverable_profit,
        lc.listing_quality_score, sm.trust_score, lc.catalog_return_rate, lc.rto_rate,
        lc.return_cost, lc.gross_margin, lc.net_margin_after_returns,
        'Category Management' AS recommended_owner,
        'Stop the margin bleed by delisting or renegotiating terms' AS expected_business_outcome,
        concat('Delist ', lc.listing_id, ' to stop ~AED ',
               ROUND(-lc.net_margin_after_returns, 0), ' net loss') AS recommendation_summary
    FROM listing_candidates lc
    JOIN gold_seller_metrics sm USING (seller_id)
    WHERE lc.intervention_class = 'delist'
),

-- ================= INTERVENTION SET 3: SELLER COACHING (seller) ==============
-- Systemic catalog failures across many listings. Opportunity = the aggregated
-- recoverable_profit of those listings (which are suppressed from Catalog Fix).
seller_coaching AS (
    SELECT
        'seller' AS entity_type, s.seller_id AS entity_id, s.primary_category AS category, s.seller_id,
        'Seller Coaching' AS intervention_type,
        concat('Systemic catalog issues across ', cs.catalog_listing_count,
               ' listings, AED ', ROUND(cs.total_recoverable_profit, 0), ' recoverable') AS intervention_reason,
        cs.total_recoverable_profit                                   AS priority_opportunity_aed,
        cs.total_catalog_return_cost                                  AS estimated_return_cost_reduction,
        cs.total_recoverable_profit - cs.total_catalog_return_cost    AS estimated_margin_recovery,
        cs.total_recoverable_profit                                   AS estimated_recoverable_profit,
        s.average_listing_quality_score AS listing_quality_score, s.trust_score,
        s.catalog_return_rate, s.rto_rate, s.return_cost, s.gross_margin, s.net_margin_after_returns,
        'Seller Experience' AS recommended_owner,
        'Coach seller on catalog standards to fix issues at scale' AS expected_business_outcome,
        concat('Coach seller ', s.seller_id, ' (', cs.catalog_listing_count,
               ' listings) to recover ~AED ', ROUND(cs.total_recoverable_profit, 0)) AS recommendation_summary
    FROM coached_sellers cs
    JOIN gold_seller_metrics s USING (seller_id)
),

-- ================= INTERVENTION SET 4: COD RISK REDUCTION (seller) ===========
-- Top-decile RTO-cost sellers. Opportunity = avoidable RTO cost (distinct AED
-- dimension; not returns). is_toxic_rto is NOT used (0 on this dataset).
cod_risk AS (
    SELECT
        'seller' AS entity_type, s.seller_id AS entity_id, s.primary_category AS category, s.seller_id,
        'COD Risk Reduction' AS intervention_type,
        concat('Top-decile RTO cost (AED ', ROUND(s.seller_rto_cost, 0),
               '), RTO rate ', ROUND(s.rto_rate, 3)) AS intervention_reason,
        s.seller_rto_cost                                  AS priority_opportunity_aed,
        s.seller_rto_cost                                  AS estimated_return_cost_reduction,
        0.0                                                AS estimated_margin_recovery,
        s.seller_rto_cost                                  AS estimated_recoverable_profit,
        s.average_listing_quality_score AS listing_quality_score, s.trust_score,
        s.catalog_return_rate, s.rto_rate, s.return_cost, s.gross_margin, s.net_margin_after_returns,
        'COD Risk Ops' AS recommended_owner,
        'Cut failed COD deliveries via prepaid nudges and address verification' AS expected_business_outcome,
        concat('Mitigate COD RTO for seller ', s.seller_id, ' to avoid ~AED ',
               ROUND(s.seller_rto_cost, 0)) AS recommendation_summary
    FROM gold_seller_metrics s
    WHERE s.is_top_decile_rto_cost
      AND s.seller_rto_cost >= (SELECT min_opportunity_aed FROM params)
),

-- ---- Union all interventions into the common queue shape. ----
unioned AS (
    SELECT * FROM catalog_fix
    UNION ALL SELECT * FROM delist
    UNION ALL SELECT * FROM seller_coaching
    UNION ALL SELECT * FROM cod_risk
)

-- ---- Final: identity, priority band, and the single global ranking. ----
SELECT
    -- Identification.
    concat(
        CASE intervention_type
            WHEN 'Catalog Fix'         THEN 'CATFIX'
            WHEN 'Delisting Candidate' THEN 'DELIST'
            WHEN 'Seller Coaching'     THEN 'COACH'
            WHEN 'COD Risk Reduction'  THEN 'CODRISK'
        END, '-', entity_id) AS intervention_id,
    entity_type, entity_id, category, seller_id,
    -- Intervention.
    intervention_type, intervention_reason,
    -- Priority band (tertile of the comparable opportunity).
    CASE NTILE(3) OVER (ORDER BY priority_opportunity_aed DESC)
        WHEN 1 THEN 'High' WHEN 2 THEN 'Medium' ELSE 'Low' END AS priority,
    -- Financial (all AED; the estimated split reconciles to the opportunity).
    ROUND(priority_opportunity_aed, 2)        AS priority_opportunity_aed,
    ROUND(estimated_return_cost_reduction, 2) AS estimated_return_cost_reduction,
    -- Derive margin recovery from the two rounded values so the identity
    -- (cost_reduction + margin_recovery = recoverable = opportunity) is exact.
    ROUND(estimated_recoverable_profit, 2) - ROUND(estimated_return_cost_reduction, 2) AS estimated_margin_recovery,
    ROUND(estimated_recoverable_profit, 2)    AS estimated_recoverable_profit,
    -- Supporting metrics (reused from upstream marts).
    ROUND(listing_quality_score, 2) AS listing_quality_score,
    ROUND(trust_score, 2)           AS trust_score,
    ROUND(catalog_return_rate, 6)   AS catalog_return_rate,
    ROUND(rto_rate, 6)              AS rto_rate,
    ROUND(return_cost, 2)           AS return_cost,
    ROUND(gross_margin, 2)          AS gross_margin,
    ROUND(net_margin_after_returns, 2) AS net_margin_after_returns,
    -- Business context.
    recommended_owner, expected_business_outcome, recommendation_summary,
    -- Ranking on the ONE comparable unit.
    ROW_NUMBER() OVER (ORDER BY priority_opportunity_aed DESC, entity_type, entity_id) AS global_priority_rank,
    ROW_NUMBER() OVER (PARTITION BY category ORDER BY priority_opportunity_aed DESC, entity_type, entity_id) AS category_priority_rank
FROM unioned;

-- =====================================================================
-- VALIDATION QUERIES  (check | expected | actual | pass)
-- =====================================================================
-- 1. No duplicate intervention_id.
SELECT 'no_duplicate_intervention_id' AS check, 'count = distinct' AS expected,
       COUNT(*)::VARCHAR || ' / ' || COUNT(DISTINCT intervention_id)::VARCHAR AS actual,
       COUNT(*) = COUNT(DISTINCT intervention_id) AS pass
FROM gold_intervention_queue;

-- 2. Global ranking uniqueness (strict 1..N permutation).
SELECT 'global_rank_unique' AS check, 'distinct = count' AS expected,
       COUNT(DISTINCT global_priority_rank)::VARCHAR || ' / ' || COUNT(*)::VARCHAR AS actual,
       COUNT(DISTINCT global_priority_rank) = COUNT(*) AS pass
FROM gold_intervention_queue;

-- 3. No NULL priorities / priority bands.
SELECT 'no_null_priority' AS check, '0' AS expected,
       COUNT(*) FILTER (WHERE priority IS NULL OR priority_opportunity_aed IS NULL
                          OR global_priority_rank IS NULL)::VARCHAR AS actual,
       COUNT(*) FILTER (WHERE priority IS NULL OR priority_opportunity_aed IS NULL
                          OR global_priority_rank IS NULL) = 0 AS pass
FROM gold_intervention_queue;

-- 4. Financial identity: cost reduction + margin recovery = recoverable = opportunity.
SELECT 'financial_reconcile' AS check, '0 violations' AS expected,
       COUNT(*) FILTER (WHERE ABS(estimated_return_cost_reduction + estimated_margin_recovery
                                  - estimated_recoverable_profit) > 0.01
                          OR ABS(estimated_recoverable_profit - priority_opportunity_aed) > 0.01)::VARCHAR AS actual,
       COUNT(*) FILTER (WHERE ABS(estimated_return_cost_reduction + estimated_margin_recovery
                                  - estimated_recoverable_profit) > 0.01
                          OR ABS(estimated_recoverable_profit - priority_opportunity_aed) > 0.01) = 0 AS pass
FROM gold_intervention_queue;

-- 5. All opportunity / estimate values >= 0.
SELECT 'opportunity_non_negative' AS check, 'all >= 0' AS expected,
       MIN(priority_opportunity_aed)::VARCHAR AS actual,
       MIN(priority_opportunity_aed) >= 0 AND MIN(estimated_return_cost_reduction) >= 0
   AND MIN(estimated_margin_recovery) >= 0 AND MIN(estimated_recoverable_profit) >= 0 AS pass
FROM gold_intervention_queue;

-- 6. Intervention types are valid.
SELECT 'valid_intervention_types' AS check, '4 known types' AS expected,
       COUNT(*) FILTER (WHERE intervention_type NOT IN
             ('Catalog Fix','Delisting Candidate','Seller Coaching','COD Risk Reduction'))::VARCHAR AS actual,
       COUNT(*) FILTER (WHERE intervention_type NOT IN
             ('Catalog Fix','Delisting Candidate','Seller Coaching','COD Risk Reduction')) = 0 AS pass
FROM gold_intervention_queue;

-- 7. Recommended owners are valid.
SELECT 'valid_owners' AS check, '4 known owners' AS expected,
       COUNT(*) FILTER (WHERE recommended_owner NOT IN
             ('Catalog Operations','Category Management','Seller Experience','COD Risk Ops'))::VARCHAR AS actual,
       COUNT(*) FILTER (WHERE recommended_owner NOT IN
             ('Catalog Operations','Category Management','Seller Experience','COD Risk Ops')) = 0 AS pass
FROM gold_intervention_queue;

-- 8. Global priority ranks are consecutive 1..N.
SELECT 'global_ranks_consecutive' AS check, '1..N' AS expected,
       MIN(global_priority_rank)::VARCHAR || '..' || MAX(global_priority_rank)::VARCHAR AS actual,
       MIN(global_priority_rank) = 1 AND MAX(global_priority_rank) = COUNT(*) AS pass
FROM gold_intervention_queue;

-- 9. Category ranks are consecutive 1..count within every category.
SELECT 'category_ranks_consecutive' AS check, '1..count per category' AS expected,
       COUNT(*) FILTER (WHERE bad)::VARCHAR || ' bad categories' AS actual,
       COUNT(*) FILTER (WHERE bad) = 0 AS pass
FROM (
    SELECT category,
           (MIN(category_priority_rank) <> 1
            OR MAX(category_priority_rank) <> COUNT(*)
            OR COUNT(DISTINCT category_priority_rank) <> COUNT(*)) AS bad
    FROM gold_intervention_queue GROUP BY category
) t;

-- 10. Opportunity ordering: rank 1 carries the maximum opportunity.
SELECT 'opportunity_ordering' AS check, 'rank1 = max opportunity' AS expected,
       (SELECT ROUND(priority_opportunity_aed, 2) FROM gold_intervention_queue WHERE global_priority_rank = 1)::VARCHAR AS actual,
       (SELECT priority_opportunity_aed FROM gold_intervention_queue WHERE global_priority_rank = 1)
           = (SELECT MAX(priority_opportunity_aed) FROM gold_intervention_queue) AS pass;

-- 11. No impossible combinations: entity_type matches intervention_type, and
--     no listing is BOTH a Catalog Fix and a Delisting Candidate.
SELECT 'no_impossible_combinations' AS check, '0' AS expected,
       (COUNT(*) FILTER (WHERE (intervention_type IN ('Catalog Fix','Delisting Candidate') AND entity_type <> 'listing')
                            OR (intervention_type IN ('Seller Coaching','COD Risk Reduction') AND entity_type <> 'seller'))
        + (SELECT COUNT(*) FROM (
               SELECT entity_id FROM gold_intervention_queue
               WHERE intervention_type IN ('Catalog Fix','Delisting Candidate')
               GROUP BY entity_id HAVING COUNT(*) > 1)))::VARCHAR AS actual,
       (COUNT(*) FILTER (WHERE (intervention_type IN ('Catalog Fix','Delisting Candidate') AND entity_type <> 'listing')
                            OR (intervention_type IN ('Seller Coaching','COD Risk Reduction') AND entity_type <> 'seller'))
        + (SELECT COUNT(*) FROM (
               SELECT entity_id FROM gold_intervention_queue
               WHERE intervention_type IN ('Catalog Fix','Delisting Candidate')
               GROUP BY entity_id HAVING COUNT(*) > 1))) = 0 AS pass
FROM gold_intervention_queue;

-- 12. Anti-double-count reconciliation: Catalog Fix + Seller Coaching
--     recoverable profit == total catalog recoverable profit of all
--     catalog-eligible listings (each counted exactly once).
SELECT 'catalog_recoverable_reconcile' AS check,
       ROUND((SELECT SUM(recoverable_profit) FROM (
                SELECT l.recoverable_profit
                FROM gold_listing_metrics l
                WHERE (l.net_margin_after_returns >= 0 OR l.listing_quality_score >= 45.0
                       OR -l.net_margin_after_returns < 100.0)
                  AND l.listing_quality_score < 70.0
                  AND l.recoverable_profit >= 100.0)), 2)::VARCHAR AS expected,
       ROUND(SUM(estimated_recoverable_profit) FILTER (WHERE intervention_type IN ('Catalog Fix','Seller Coaching')), 2)::VARCHAR AS actual,
       ABS(SUM(estimated_recoverable_profit) FILTER (WHERE intervention_type IN ('Catalog Fix','Seller Coaching'))
           - (SELECT SUM(recoverable_profit) FROM (
                SELECT l.recoverable_profit
                FROM gold_listing_metrics l
                WHERE (l.net_margin_after_returns >= 0 OR l.listing_quality_score >= 45.0
                       OR -l.net_margin_after_returns < 100.0)
                  AND l.listing_quality_score < 70.0
                  AND l.recoverable_profit >= 100.0)) ) < 0.01 AS pass
FROM gold_intervention_queue;
