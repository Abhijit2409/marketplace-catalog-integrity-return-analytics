# Gold Layer Data Model — Semantic Design

**Status:** Final semantic design before implementation. **No SQL herein.**
**Upstream contracts:** `data/02_silver` (clean layer), `config/metrics.yaml`
(metric definitions), `docs/data_dictionary.md` (column-level reference).
**As-of:** `2026-07-07` (matches the Silver build; snapshot grain — see
[grain policy](#grain-policy)).

This document defines every Gold table: purpose, grain, keys, dependencies,
source Silver tables, source metrics, refresh, expected row count, target Power
BI page, business owner, and — per table — **why it exists and why it belongs in
Gold rather than Silver**.

---

## 1. Design principles

### Why Gold at all — the Bronze→Silver→Gold boundary

| Layer | Owns | Never contains |
|---|---|---|
| **Silver** | Clean, source-aligned rows at entity grain; cleaning only; row-preserving | Business KPIs; the four derived-only metrics (Golden Rule 1); aggregates |
| **Gold** | Semantic, business-metric-bearing tables reshaped to a *decision* grain; denormalized for BI | Raw cleaning logic; anything an analyst shouldn't consume directly |

A table earns its place in Gold for one of **three distinct reasons** (each Gold
table below is tagged with the one that applies — this is not boilerplate):

- **[G1] Golden-Rule-1 derived-only.** It first materializes a metric that is
  *forbidden* in Bronze/Silver: `listing_quality_score`, `return_cost`,
  `recoverable_profit`, `trust_score`. These *cannot* live in Silver by rule.
- **[AGG] Aggregation / reshape to a decision grain.** It collapses multiple
  Silver fact grains into a grain that has no Silver equivalent (category
  portfolio, marketplace summary).
- **[BIZ] Business logic / thresholds.** It encodes policy — prioritization,
  cutoffs, a synthesized ranking unit — that is decision-making, not data.

### Golden Rules carried into Gold
- **Rule 1 — no leakage:** the four derived-only metrics appear *first* in Gold,
  never before. `gold_return_line_economics`, `gold_listing_metrics`,
  `gold_seller_metrics` are their legal birthplaces.
- **Rule 2 — RTO is not a return:** RTO is measured only from
  `fact_orders.order_status`; return metrics use delivered-only denominators.
  The two never mix inside a single rate.
- **Hidden variables** (SOQ, TPQ, Expectation Gap, courier performance) are
  never columns here; Trust Score is an observable proxy only.

### Grain policy
Primary grain is a **snapshot as-of `2026-07-07`**, which keeps expected row
counts deterministic. A **monthly time-grain** variant (adding `date_key` /
`month` to the entity marts and executive summary) is a documented **extension**,
not part of this first cut.

### Thresholds & parameters
All cutoffs (LQS threshold, minimum recoverable profit, `toxic_rto`
`top_fraction` / `min_shipped_orders` / `toxic_rto_rate_threshold`,
`addressable_fraction`) are **config-driven** and reference
`config/metrics.yaml` `parameters`. A thin `config/gold_model.yaml` will hold
Gold-only knobs (queue top-N, page mappings). **Nothing is hard-coded.**

---

## 2. Model overview & build DAG

Two **foundational facts** (computation layer) define the per-line economics
*once* (CLAUDE.md: "No duplicated business logic"), then three **entity marts**
aggregate them, then two **consumption tables** serve executives and operators.
Foundational-vs-view is an implementation choice; the contract is a *single
definition* of each calculation.

```
        SILVER (data/02_silver)
              │
   ┌──────────┴───────────┐
   ▼                      ▼
gold_order_line_economics  gold_return_line_economics     ← foundational facts
   └──────────┬───────────┘
              ▼
      gold_listing_metrics                                ← atomic entity mart
              │
     ┌────────┴─────────┐
     ▼                  ▼
gold_category_metrics  gold_seller_metrics                ← entity marts
     └────────┬─────────┘
     ┌────────┴─────────┐
     ▼                  ▼
gold_executive_summary  gold_intervention_queue           ← consumption
```

Foreign keys are **logical references** (for BI relationships), deliberately
decoupled from build order, so `gold_listing_metrics.seller_id →
gold_seller_metrics` does not imply a circular build.

| # | Table | Class | Grain | PK | Rows | Named deliverable |
|---|---|---|---|---|---:|:---:|
| F1 | `gold_order_line_economics` | [BIZ]/DRY | order line | `order_line_id` | 85,000 | supporting |
| F2 | `gold_return_line_economics` | **[G1]** | return line | `return_id` | 32,005 | supporting |
| 1 | **`gold_listing_metrics`** | **[G1]** | listing | `listing_id` | 10,000 | ★ |
| 2 | **`gold_category_metrics`** | [AGG] | category | `category` | 5 | ★ |
| 3 | **`gold_seller_metrics`** | **[G1]** | seller | `seller_id` | 450 | ★ |
| 4 | **`gold_executive_summary`** | [AGG] | marketplace KPI | `(as_of_date_key, kpi_name)` | ~14 | ★ |
| 5 | **`gold_intervention_queue`** | **[BIZ]** | recommended action | `intervention_id` | O(1,000)* | ★ |

*Config-bounded (thresholds + top-N).

---

## 3. Foundational facts (computation layer — secondary to the five marts)

### F1 · `gold_order_line_economics`

- **Business purpose:** One row per order line enriched with per-line economics —
  realized net revenue, gross margin (AED), RTO classification, and delivery
  timeliness. The single, reusable definition of order-line business logic that
  every downstream mart draws on.
- **Grain:** order line (one per `fact_orders` row).
- **Primary key:** `order_line_id`.
- **Foreign keys (logical):** `listing_id → gold_listing_metrics`;
  `seller_id → gold_seller_metrics`; `geo_id → dim_geography`;
  `order_date_key → dim_date`.
- **Dependencies:** none (Gold base; reads Silver only).
- **Source Silver tables:** `fact_orders`, `dim_listing` (category),
  `ref_category_economics` (gross_margin_pct), `dim_geography` (zone for RTO
  cost), `ref_logistics_rate_card` (forward leg for RTO cost).
- **Source metrics:** `gross_margin`; `rto_rate` (row-level classification
  inputs); delivery-timeliness inputs feeding `trust_score`.
- **Refresh strategy:** nightly full rebuild (idempotent batch).
- **Expected row count:** 85,000 (all order lines; status retained, incl. the
  2,124 `cancelled_pre_shipment` and 8,096 RTO, flagged not filtered).
- **Target Power BI page:** none — computation layer (feeds all pages).
- **Business owner:** Commercial Finance (metric owner); Analytics Engineering
  (table owner).
- **Why it exists / why Gold not Silver — [BIZ]/DRY:** `gross_margin` is
  `derived_only: false`, so it is *not* barred from Silver by Golden Rule 1 —
  its real justification is different: it applies **category-margin economics and
  RTO/timeliness classification** (business logic), and materializes that logic
  **once** so the three marts don't each re-derive it. Silver preserves source
  rows without economics; this table is the economics.

### F2 · `gold_return_line_economics`

- **Business purpose:** One row per return line carrying the fully-loaded
  **Return Cost** (reverse logistics + warehouse handling + merchandise loss net
  of salvage), the recovery credit, and the catalog-attribution flag. The one
  place Return Cost is computed.
- **Grain:** return line (one per `fact_returns` row).
- **Primary key:** `return_id`.
- **Foreign keys (logical):** `order_line_id → gold_order_line_economics`;
  `listing_id → gold_listing_metrics`; `reported_reason_code → dim_return_reason`.
- **Dependencies:** none (Gold base; reads Silver). Linkage value
  (`unit_selling_price`) sourced from `fact_orders`.
- **Source Silver tables:** `fact_returns`, `fact_orders` (unit value, geo,
  listing), `dim_listing` (item_weight_kg, category), `dim_geography`
  (logistics_zone), `dim_return_reason` (is_catalog_related),
  `ref_logistics_rate_card` (reverse leg), `ref_category_economics` (handling,
  recovery_pct_*).
- **Source metrics:** `return_cost`, `recovery_rate`, and the catalog-attribution
  input to `catalog_return_rate`.
- **Refresh strategy:** nightly full rebuild.
- **Expected row count:** 32,005 (all return lines; delivered-only by
  construction — Golden Rule 2).
- **Target Power BI page:** none — computation layer.
- **Business owner:** Reverse Logistics / Supply Chain Finance.
- **Why it exists / why Gold not Silver — [G1]:** **Return Cost is a
  derived-only metric explicitly forbidden in Bronze and Silver** (Golden
  Rule 1). This is its legal birthplace. It also enforces DRY: listing,
  category, seller and intervention tables all consume this single definition
  rather than re-summing rate-card + handling + salvage independently.

---

## 4. Primary Gold marts (the five deliverables)

### 1 · `gold_listing_metrics` ★

- **Business purpose:** The listing-level catalog & profitability scorecard and
  the **atomic prioritization unit**: Listing Quality Score, catalog return rate,
  aggregated return cost, recoverable profit, net margin after returns, gross
  margin, and traffic/conversion — one row per listing.
- **Grain:** listing (one per `dim_listing.listing_id`).
- **Primary key:** `listing_id`.
- **Foreign keys (logical):** `seller_id → gold_seller_metrics`;
  `category → gold_category_metrics` (and `ref_category_economics`).
- **Dependencies:** `gold_order_line_economics`, `gold_return_line_economics`
  (aggregated up); `dim_listing`, `fact_listing_traffic` (direct).
- **Source Silver tables:** `dim_listing`, `fact_listing_traffic` (+ orders /
  returns / refs via the foundational facts).
- **Source metrics:** `listing_quality_score`, `gross_margin`, `return_cost`,
  `recovery_rate`, `catalog_return_rate`, `net_margin_after_returns`,
  `recoverable_profit` (listing grain).
- **Refresh strategy:** nightly full rebuild, after the foundational facts.
- **Expected row count:** **10,000 — all listings.** Zero-order / zero-traffic
  listings get zero/null activity metrics but still a **computed LQS**:
  low-LQS + low-traffic is itself an actionable state, so they must not be
  dropped.
- **Target Power BI page:** *Catalog dashboard → Listing Detail* (drill-through).
- **Business owner:** Catalog / Content Quality Manager.
- **Why it exists / why Gold not Silver — [G1]:** houses **LQS and Recoverable
  Profit**, both derived-only (forbidden in Silver). It also reshapes three
  distinct fact grains (orders, returns, traffic) into one listing-grain
  semantic row — impossible at Silver's source-aligned grain.

### 2 · `gold_category_metrics` ★

- **Business purpose:** The category portfolio view — margin, return economics,
  RTO, recovery, and recoverable profit across the five categories — for mix
  analysis and benchmarking by Commercial / Category Management.
- **Grain:** category (snapshot).
- **Primary key:** `category`.
- **Foreign keys (logical):** `category → ref_category_economics`.
- **Dependencies:** `gold_listing_metrics` (roll-up), `gold_order_line_economics`,
  `gold_return_line_economics`.
- **Source Silver tables:** `ref_category_economics` (+ facts via the marts).
- **Source metrics:** `gross_margin`, `catalog_return_rate`, `rto_rate`,
  `return_cost`, `recovery_rate`, `net_margin_after_returns`,
  `recoverable_profit`; **optional** per-category `toxic_rto_concentration`
  scalar (concentration within the category's sellers).
- **Refresh strategy:** nightly, after `gold_listing_metrics`.
- **Expected row count:** **5** (one per category). *Extension:* category ×
  month → 5 × N.
- **Target Power BI page:** *Category Performance* (Category Management).
- **Business owner:** Category Management / Commercial Analytics.
- **Why it exists / why Gold not Silver — [AGG]:** it is an **aggregate to a
  5-row portfolio grain** that has no Silver equivalent (Silver has no
  "category" row — only 10,000 listings). It exists to make cross-category
  trade-offs legible at a glance.

### 3 · `gold_seller_metrics` ★

- **Business purpose:** The seller scorecard for governance and risk — Trust
  Score, RTO behavior, catalog return rate, net margin after returns,
  recoverable profit, and on-time delivery — one row per seller.
- **Grain:** seller (one per `dim_seller.seller_id`).
- **Primary key:** `seller_id`.
- **Foreign keys (logical):** `seller_id → dim_seller`.
- **Dependencies:** `gold_listing_metrics` (mean LQS across the seller's
  listings), `gold_order_line_economics`, `gold_return_line_economics`.
- **Source Silver tables:** `dim_seller` (+ orders / returns / reasons via facts).
- **Source metrics:** `trust_score`, `rto_rate`, `catalog_return_rate`,
  `net_margin_after_returns`, `recoverable_profit`, `recovery_rate`. **Carries
  the `toxic_rto` *ingredients* only** — per-seller `rto_cost`, `rto_rate`,
  `is_toxic` flag, `rto_cost_rank` — **not** the concentration ratio (a scalar
  that is meaningless at 1-row-per-seller grain; it lives in the executive
  summary).
- **Refresh strategy:** nightly, after `gold_listing_metrics`.
- **Expected row count:** **450.**
- **Target Power BI page:** *Seller scorecards / Trust dashboard*.
- **Business owner:** Seller Experience / Marketplace Governance.
- **Why it exists / why Gold not Silver — [G1]:** houses **Trust Score**
  (derived-only, forbidden in Silver) and enriches the seller with cross-listing
  roll-ups (mean LQS) that don't exist at Silver grain.

### 4 · `gold_executive_summary` ★

- **Business purpose:** The marketplace headline-KPI table for the executive
  landing page and the Decision Memo — total recoverable profit (the leakage
  number), total return cost, overall RTO and catalog return rates, net margin
  after returns, the **`toxic_rto_concentration` scalar**, mean Trust Score and
  mean LQS — marketplace health at a glance.
- **Grain:** one row per **headline KPI** at marketplace level, per as-of
  snapshot (tall KPI register — flexible for card grids and target/status columns).
- **Primary key:** `(as_of_date_key, kpi_name)`.
- **Foreign keys (logical):** `as_of_date_key → dim_date`.
- **Dependencies:** `gold_category_metrics`, `gold_seller_metrics`,
  `gold_listing_metrics` (+ foundational facts for grand totals).
- **Source Silver tables:** none directly (aggregates Gold).
- **Source metrics:** **all ten** — `gross_margin`, `recovery_rate`, `rto_rate`,
  `catalog_return_rate`, `listing_quality_score` (mean), `return_cost` (total),
  `net_margin_after_returns`, `recoverable_profit` (total),
  **`toxic_rto_concentration` (the scalar lives here)**, `trust_score` (mean).
- **Refresh strategy:** nightly, last (after all marts).
- **Expected row count:** **~14** (one per KPI) per as-of.
- **Target Power BI page:** *Executive Overview* (Executive P&L /
  revenue-leakage dashboard); feeds the Executive Decision Memo.
- **Business owner:** Head of Marketplace / Commercial (executive sponsor).
- **Why it exists / why Gold not Silver — [AGG]:** it is a **fully-collapsed
  marketplace aggregate** with no Silver analogue, and it is the correct — and
  only sensible — home for the portfolio-grain `toxic_rto_concentration` scalar.

### 5 · `gold_intervention_queue` ★

- **Business purpose:** The prioritized, operational worklist that turns the
  analytics into action — every recommended intervention (**catalog fix**,
  **COD-risk mitigation**, **delisting candidate**) ranked by a single,
  comparable **estimated AED opportunity**. Answers "what do we fix first?"
- **Grain:** one row per recommended intervention.
- **Primary key:** `intervention_id` (surrogate). **Natural key:**
  `(entity_type, entity_id, intervention_type)`.
- **Foreign keys (logical):** `entity_id → gold_listing_metrics` when
  `entity_type = 'listing'`, or `→ gold_seller_metrics` when
  `entity_type = 'seller'`; `category → gold_category_metrics`.
- **Dependencies:** `gold_listing_metrics`, `gold_seller_metrics`.
- **Source Silver tables:** none directly (built from the marts).
- **Source metrics & ranking unit:** every row exposes one sortable
  `priority_opportunity_aed`, defined per intervention type so a *single* ranking
  is valid:
  - `catalog_fix` → `recoverable_profit` (from `listing_quality_score` +
    `recoverable_profit`; include when LQS < cutoff **and** recoverable_profit > min).
  - `cod_risk` → avoidable RTO cost (from `rto_rate` + `toxic_rto` ingredients;
    include when `is_toxic`).
  - `delist_candidate` → margin-loss-stopped (from `net_margin_after_returns`;
    include when persistently negative).
- **Thresholds:** LQS cutoff, min recoverable profit, and the `toxic_rto`
  parameters come from config (referencing `metrics.yaml parameters`), never
  hard-coded.
- **Refresh strategy:** nightly, after the entity marts.
- **Expected row count:** **O(1,000)**, config-bounded — catalog_fix candidates
  (LQS below cutoff & recoverable_profit > 0) dominate; cod_risk ≈ tens of toxic
  sellers; delist ≈ tens–low-hundreds. Governed by thresholds + a queue top-N.
- **Target Power BI page:** *Intervention Queue / Action Center* (Catalog
  prioritization + COD policy review).
- **Business owner:** Commercial Analytics (orchestrator). Action owners:
  Catalog Ops (`catalog_fix`), COD Risk Ops (`cod_risk`), Category Management
  (`delist_candidate`).
- **Why it exists / why Gold not Silver — [BIZ]:** it is pure **decision logic** —
  thresholds, intervention typing, and a synthesized common ranking unit. It is
  the furthest table from raw data and has no Silver analogue; it encodes policy,
  not facts.

---

## 5. Cross-contract consistency

- **Pages** map onto the `expected_consumers` vocabulary already in
  `config/metrics.yaml` (Executive P&L / revenue-leakage, Catalog dashboard,
  Category Management, Seller scorecards / Trust dashboard, COD policy review) —
  no new page names invented.
- **Source metrics** per table match each metric's `grain` and `dependencies`
  in `metrics.yaml`; the two foundational facts correspond to the return-line /
  order-line grains those metrics are defined at.
- **Derived-only placement** is auditable: `listing_quality_score`,
  `return_cost`, `recoverable_profit`, `trust_score` appear only in the tables
  tagged **[G1]** above and nowhere upstream — the Gold implementation must
  preserve this (a Silver audit that ever finds these columns is a Rule-1
  breach).

## 6. Open implementation choices (recorded, not decided here)

1. **Physical form** of the foundational facts: materialized tables vs. views —
   pick at implementation; the invariant is one definition of each calculation.
2. **Snapshot vs. monthly** time grain (Section 1) — snapshot first.
3. **`gold_model.yaml`**: whether Gold knobs extend `metrics.yaml` or get their
   own file. Recommended: a dedicated `config/gold_model.yaml` that *references*
   `metrics.yaml parameters`, keeping metric definitions and Gold assembly knobs
   separate.

*No SQL is written until this design is approved.*
