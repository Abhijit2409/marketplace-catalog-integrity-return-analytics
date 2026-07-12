# Phase A - Bronze Data Audit

**Overall status:** `WARN`  
**Generated:** 2026-07-08T16:28:19  
**Bronze directory:** `data/02_silver`

## How to read this report

Bronze is intentionally imperfect (CLAUDE.md - Synthetic Data Rules). This audit **documents** dirt for the Silver layer; it does not clean it.

| Severity | Meaning | Effect |
|---|---|---|
| **FAIL** (error) | Structural violation: duplicate/null primary key, referential-integrity orphan, data leakage, or a broken Golden Rule | Audit fails **closed** (exit 1) |
| **WARN** | Intentional dirt: nulls, duplicate rows, out-of-range values | Reported for Silver cleaning; non-blocking |

## Summary

- Tables audited: **10**
- Total rows: **563,155**
- Checks run: **63** (passed 59, warnings 4, blocking failures 0)

## Data-quality findings for the Silver layer (WARN, non-blocking)

Intentional Bronze dirt. Non-blocking, but material - each is a row-loss or mis-join risk if not handled downstream.

| Table | Check | Finding |
|---|---|---|
| `dim_listing` | null_analysis | 4 column(s) with nulls (intentional dirt) |
| `fact_orders` | null_analysis | 1 column(s) with nulls (intentional dirt) |
| `fact_orders` | distribution_ranges | 1 column(s) out of range |
| `fact_returns` | null_analysis | 1 column(s) with nulls (intentional dirt) |

**Recommended Silver actions**

- **Deduplicate** `dim_seller`, `dim_listing`, `fact_listing_traffic` and `fact_returns` on their primary keys (the blocking failures above surface as duplicate rows here too).
- **Extend `dim_date`** to cover the full fact date range (delivery / return keys run past the current calendar end of 2026-06-30); otherwise ~2,600 fact rows drop on the date join.
- **Normalize `category`** case and whitespace in `dim_listing` to the 5 canonical values before joining `ref_category_economics`.
- **Impute / flag nulls** per the null-analysis rows (e.g. `dim_listing` attributes, `fact_orders.shipping_fee_charged`).

## Row counts

| Table | Rows |
|---|---:|
| `dim_date` | 592 |
| `dim_geography` | 19 |
| `dim_return_reason` | 10 |
| `dim_seller` | 450 |
| `ref_category_economics` | 5 |
| `ref_logistics_rate_card` | 24 |
| `dim_listing` | 10,000 |
| `fact_listing_traffic` | 435,050 |
| `fact_orders` | 85,000 |
| `fact_returns` | 32,005 |

## All checks

| Table | Check | Status | Sev | Finding |
|---|---|---|---|---|
| `dim_date` | leakage | OK PASS | error | no leakage columns |
| `dim_date` | primary_key | OK PASS | error | PK ['date_key'] unique & non-null across 592 rows |
| `dim_date` | duplicate_rows | OK PASS | warn | no fully-duplicated rows |
| `dim_date` | null_analysis | OK PASS | warn | no nulls |
| `dim_geography` | leakage | OK PASS | error | no leakage columns |
| `dim_geography` | primary_key | OK PASS | error | PK ['geo_id'] unique & non-null across 19 rows |
| `dim_geography` | duplicate_rows | OK PASS | warn | no fully-duplicated rows |
| `dim_geography` | null_analysis | OK PASS | warn | no nulls |
| `dim_return_reason` | leakage | OK PASS | error | no leakage columns |
| `dim_return_reason` | primary_key | OK PASS | error | PK ['reason_code'] unique & non-null across 10 rows |
| `dim_return_reason` | duplicate_rows | OK PASS | warn | no fully-duplicated rows |
| `dim_return_reason` | null_analysis | OK PASS | warn | no nulls |
| `dim_seller` | leakage | OK PASS | error | no leakage columns |
| `dim_seller` | primary_key | OK PASS | error | PK ['seller_id'] unique & non-null across 450 rows |
| `dim_seller` | duplicate_rows | OK PASS | warn | no fully-duplicated rows |
| `dim_seller` | null_analysis | OK PASS | warn | no nulls |
| `ref_category_economics` | leakage | OK PASS | error | no leakage columns |
| `ref_category_economics` | primary_key | OK PASS | error | PK ['category'] unique & non-null across 5 rows |
| `ref_category_economics` | duplicate_rows | OK PASS | warn | no fully-duplicated rows |
| `ref_category_economics` | null_analysis | OK PASS | warn | no nulls |
| `ref_category_economics` | distribution_ranges | OK PASS | warn | all ranges valid |
| `ref_logistics_rate_card` | leakage | OK PASS | error | no leakage columns |
| `ref_logistics_rate_card` | primary_key | OK PASS | error | PK ['logistics_zone', 'weight_band', 'leg'] unique & non-null across 24 rows |
| `ref_logistics_rate_card` | duplicate_rows | OK PASS | warn | no fully-duplicated rows |
| `ref_logistics_rate_card` | null_analysis | OK PASS | warn | no nulls |
| `ref_logistics_rate_card` | distribution_ranges | OK PASS | warn | all ranges valid |
| `dim_listing` | leakage | OK PASS | error | no leakage columns |
| `dim_listing` | primary_key | OK PASS | error | PK ['listing_id'] unique & non-null across 10,000 rows |
| `dim_listing` | duplicate_rows | OK PASS | warn | no fully-duplicated rows |
| `dim_listing` | null_analysis | ! WARN | warn | 4 column(s) with nulls (intentional dirt) |
| `dim_listing` | fk:seller_id | OK PASS | error | seller_id -> dim_seller.seller_id: 100.0000% of 10,000 non-null keys resolve; 0 null(s) |
| `dim_listing` | membership:category | OK PASS | error | category all canonical within ref_category_economics.category |
| `dim_listing` | distribution_ranges | OK PASS | warn | all ranges valid |
| `fact_listing_traffic` | leakage | OK PASS | error | no leakage columns |
| `fact_listing_traffic` | primary_key | OK PASS | error | PK ['listing_id', 'date_key'] unique & non-null across 435,050 rows |
| `fact_listing_traffic` | duplicate_rows | OK PASS | warn | no fully-duplicated rows |
| `fact_listing_traffic` | null_analysis | OK PASS | warn | no nulls |
| `fact_listing_traffic` | fk:listing_id | OK PASS | error | listing_id -> dim_listing.listing_id: 100.0000% of 435,050 non-null keys resolve; 0 null(s) |
| `fact_listing_traffic` | fk:date_key | OK PASS | error | date_key -> dim_date.date_key: 100.0000% of 435,050 non-null keys resolve; 0 null(s) |
| `fact_listing_traffic` | distribution_ranges | OK PASS | warn | all ranges valid |
| `fact_listing_traffic` | funnel_monotonicity | OK PASS | warn | funnel monotonic (impressions >= detail_page_views >= add_to_carts) |
| `fact_orders` | leakage | OK PASS | error | no leakage columns |
| `fact_orders` | primary_key | OK PASS | error | PK ['order_line_id'] unique & non-null across 85,000 rows |
| `fact_orders` | duplicate_rows | OK PASS | warn | no fully-duplicated rows |
| `fact_orders` | null_analysis | ! WARN | warn | 1 column(s) with nulls (intentional dirt) |
| `fact_orders` | fk:listing_id | OK PASS | error | listing_id -> dim_listing.listing_id: 100.0000% of 85,000 non-null keys resolve; 0 null(s) |
| `fact_orders` | fk:seller_id | OK PASS | error | seller_id -> dim_seller.seller_id: 100.0000% of 85,000 non-null keys resolve; 0 null(s) |
| `fact_orders` | fk:geo_id | OK PASS | error | geo_id -> dim_geography.geo_id: 100.0000% of 85,000 non-null keys resolve; 0 null(s) |
| `fact_orders` | fk:order_date_key | OK PASS | error | order_date_key -> dim_date.date_key: 100.0000% of 85,000 non-null keys resolve; 0 null(s) |
| `fact_orders` | fk:promised_delivery_date_key | OK PASS | error | promised_delivery_date_key -> dim_date.date_key: 100.0000% of 85,000 non-null keys resolve; 0 null(s) |
| `fact_orders` | fk:actual_delivery_date_key | OK PASS | error | actual_delivery_date_key -> dim_date.date_key: 100.0000% of 74,780 non-null keys resolve; 10,220 null(s) |
| `fact_orders` | membership:order_status | OK PASS | error | order_status all canonical within order_status_values |
| `fact_orders` | distribution_ranges | ! WARN | warn | 1 column(s) out of range |
| `fact_returns` | leakage | OK PASS | error | no leakage columns |
| `fact_returns` | primary_key | OK PASS | error | PK ['return_id'] unique & non-null across 32,005 rows |
| `fact_returns` | duplicate_rows | OK PASS | warn | no fully-duplicated rows |
| `fact_returns` | null_analysis | ! WARN | warn | 1 column(s) with nulls (intentional dirt) |
| `fact_returns` | fk:order_line_id | OK PASS | error | order_line_id -> fact_orders.order_line_id: 100.0000% of 32,005 non-null keys resolve; 0 null(s) |
| `fact_returns` | fk:reported_reason_code | OK PASS | error | reported_reason_code -> dim_return_reason.reason_code: 100.0000% of 31,672 non-null keys resolve; 333 null(s) |
| `fact_returns` | fk:return_initiated_date_key | OK PASS | error | return_initiated_date_key -> dim_date.date_key: 100.0000% of 32,005 non-null keys resolve; 0 null(s) |
| `fact_returns` | fk:return_received_date_key | OK PASS | error | return_received_date_key -> dim_date.date_key: 100.0000% of 32,005 non-null keys resolve; 0 null(s) |
| `fact_returns` | distribution_ranges | OK PASS | warn | all ranges valid |
| `fact_returns` | returns_delivered_reconciliation | OK PASS | error | all 32,005 returns reconcile to delivered orders |

## Assumptions

- **"Row-count matching"** is interpreted as per-table row counts (above) plus cross-table reconciliation of `fact_returns` -> `fact_orders` (the `returns_delivered_reconciliation` check).
- Foreign-key nulls are treated as missing data (counted in null analysis), **not** as broken references; only non-null unmatched keys are orphans.
- `fact_orders.actual_delivery_date_key` is nullable by design (null when an order was never delivered).
- Nulls, duplicate rows and out-of-range values are expected Bronze dirt and are surfaced as WARN, to be resolved in the Silver layer.

## Downstream to-do (out of Phase A scope)

- Some `fact_orders.actual_delivery_date_key` values on `delivered` orders fall after the dataset as-of date (2026-06-30), i.e. delivered in the future. That is a *logical* (business-rule) violation, not a referential one, and belongs to a Silver-layer temporal-consistency check - not this referential audit.