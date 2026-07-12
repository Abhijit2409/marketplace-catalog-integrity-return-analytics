# Phase A - Bronze Data Audit

**Overall status:** `FAIL`  
**Generated:** 2026-07-07T19:28:01  
**Bronze directory:** `data/01_bronze`

## How to read this report

Bronze is intentionally imperfect (CLAUDE.md - Synthetic Data Rules). This audit **documents** dirt for the Silver layer; it does not clean it.

| Severity | Meaning | Effect |
|---|---|---|
| **FAIL** (error) | Structural violation: duplicate/null primary key, referential-integrity orphan, data leakage, or a broken Golden Rule | Audit fails **closed** (exit 1) |
| **WARN** | Intentional dirt: nulls, duplicate rows, out-of-range values | Reported for Silver cleaning; non-blocking |

## Summary

- Tables audited: **10**
- Total rows: **563,263**
- Checks run: **63** (passed 43, warnings 16, blocking failures 4)

## Blocking failures (fail closed)

| Table | Check | Finding |
|---|---|---|
| `dim_seller` | primary_key | PK ['seller_id'] violated: 8 rows in 4 duplicate group(s), 0 null-key row(s) |
| `dim_listing` | primary_key | PK ['listing_id'] violated: 50 rows in 25 duplicate group(s), 0 null-key row(s) |
| `fact_listing_traffic` | primary_key | PK ['listing_id', 'date_key'] violated: 200 rows in 100 duplicate group(s), 0 null-key row(s) |
| `fact_returns` | primary_key | PK ['return_id'] violated: 50 rows in 25 duplicate group(s), 0 null-key row(s) |

## Data-quality findings for the Silver layer (WARN, non-blocking)

Intentional Bronze dirt. Non-blocking, but material - each is a row-loss or mis-join risk if not handled downstream.

| Table | Check | Finding |
|---|---|---|
| `dim_seller` | duplicate_rows | 8 fully-duplicated row(s) |
| `dim_seller` | null_analysis | 1 column(s) with nulls (intentional dirt) |
| `dim_listing` | duplicate_rows | 50 fully-duplicated row(s) |
| `dim_listing` | null_analysis | 7 column(s) with nulls (intentional dirt) |
| `dim_listing` | membership:category | category: all values map to ref_category_economics.category, but 262 row(s) need case/whitespace normalization (e.g. [' Beauty ', ' Electronics ', ' Fashion ', ' Home ', ' Sports ']) |
| `dim_listing` | distribution_ranges | 2 column(s) out of range |
| `fact_listing_traffic` | duplicate_rows | 200 fully-duplicated row(s) |
| `fact_listing_traffic` | null_analysis | 1 column(s) with nulls (intentional dirt) |
| `fact_orders` | null_analysis | 2 column(s) with nulls (intentional dirt) |
| `fact_orders` | fk:promised_delivery_date_key | promised_delivery_date_key -> dim_date.date_key: 99.2118% of 85,000 non-null keys resolve; 670 beyond-calendar (extend dimension through >= 20260708); 0 null(s) |
| `fact_orders` | fk:actual_delivery_date_key | actual_delivery_date_key -> dim_date.date_key: 99.0372% of 74,780 non-null keys resolve; 720 beyond-calendar (extend dimension through >= 20260716); 10,220 null(s) |
| `fact_orders` | distribution_ranges | 1 column(s) out of range |
| `fact_returns` | duplicate_rows | 50 fully-duplicated row(s) |
| `fact_returns` | null_analysis | 1 column(s) with nulls (intentional dirt) |
| `fact_returns` | fk:return_initiated_date_key | return_initiated_date_key -> dim_date.date_key: 97.4649% of 32,030 non-null keys resolve; 812 beyond-calendar (extend dimension through >= 20260807); 0 null(s) |
| `fact_returns` | fk:return_received_date_key | return_received_date_key -> dim_date.date_key: 96.4377% of 32,030 non-null keys resolve; 1,141 beyond-calendar (extend dimension through >= 20260815); 0 null(s) |

**Recommended Silver actions**

- **Deduplicate** `dim_seller`, `dim_listing`, `fact_listing_traffic` and `fact_returns` on their primary keys (the blocking failures above surface as duplicate rows here too).
- **Extend `dim_date`** to cover the full fact date range (delivery / return keys run past the current calendar end of 2026-06-30); otherwise ~2,600 fact rows drop on the date join.
- **Normalize `category`** case and whitespace in `dim_listing` to the 5 canonical values before joining `ref_category_economics`.
- **Impute / flag nulls** per the null-analysis rows (e.g. `dim_listing` attributes, `fact_orders.shipping_fee_charged`).

## Row counts

| Table | Rows |
|---|---:|
| `dim_date` | 546 |
| `dim_geography` | 19 |
| `dim_return_reason` | 10 |
| `dim_seller` | 454 |
| `ref_category_economics` | 5 |
| `ref_logistics_rate_card` | 24 |
| `dim_listing` | 10,025 |
| `fact_listing_traffic` | 435,150 |
| `fact_orders` | 85,000 |
| `fact_returns` | 32,030 |

## All checks

| Table | Check | Status | Sev | Finding |
|---|---|---|---|---|
| `dim_date` | leakage | OK PASS | error | no leakage columns |
| `dim_date` | primary_key | OK PASS | error | PK ['date_key'] unique & non-null across 546 rows |
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
| `dim_seller` | primary_key | X FAIL | error | PK ['seller_id'] violated: 8 rows in 4 duplicate group(s), 0 null-key row(s) |
| `dim_seller` | duplicate_rows | ! WARN | warn | 8 fully-duplicated row(s) |
| `dim_seller` | null_analysis | ! WARN | warn | 1 column(s) with nulls (intentional dirt) |
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
| `dim_listing` | primary_key | X FAIL | error | PK ['listing_id'] violated: 50 rows in 25 duplicate group(s), 0 null-key row(s) |
| `dim_listing` | duplicate_rows | ! WARN | warn | 50 fully-duplicated row(s) |
| `dim_listing` | null_analysis | ! WARN | warn | 7 column(s) with nulls (intentional dirt) |
| `dim_listing` | fk:seller_id | OK PASS | error | seller_id -> dim_seller.seller_id: 100.0000% of 10,025 non-null keys resolve; 0 null(s) |
| `dim_listing` | membership:category | ! WARN | warn | category: all values map to ref_category_economics.category, but 262 row(s) need case/whitespace normalization (e.g. [' Beauty ', ' Electronics ', ' Fashion ', ' Home ', ' Sports ']) |
| `dim_listing` | distribution_ranges | ! WARN | warn | 2 column(s) out of range |
| `fact_listing_traffic` | leakage | OK PASS | error | no leakage columns |
| `fact_listing_traffic` | primary_key | X FAIL | error | PK ['listing_id', 'date_key'] violated: 200 rows in 100 duplicate group(s), 0 null-key row(s) |
| `fact_listing_traffic` | duplicate_rows | ! WARN | warn | 200 fully-duplicated row(s) |
| `fact_listing_traffic` | null_analysis | ! WARN | warn | 1 column(s) with nulls (intentional dirt) |
| `fact_listing_traffic` | fk:listing_id | OK PASS | error | listing_id -> dim_listing.listing_id: 100.0000% of 435,150 non-null keys resolve; 0 null(s) |
| `fact_listing_traffic` | fk:date_key | OK PASS | error | date_key -> dim_date.date_key: 100.0000% of 435,150 non-null keys resolve; 0 null(s) |
| `fact_listing_traffic` | distribution_ranges | OK PASS | warn | all ranges valid |
| `fact_listing_traffic` | funnel_monotonicity | OK PASS | warn | funnel monotonic (impressions >= detail_page_views >= add_to_carts) |
| `fact_orders` | leakage | OK PASS | error | no leakage columns |
| `fact_orders` | primary_key | OK PASS | error | PK ['order_line_id'] unique & non-null across 85,000 rows |
| `fact_orders` | duplicate_rows | OK PASS | warn | no fully-duplicated rows |
| `fact_orders` | null_analysis | ! WARN | warn | 2 column(s) with nulls (intentional dirt) |
| `fact_orders` | fk:listing_id | OK PASS | error | listing_id -> dim_listing.listing_id: 100.0000% of 85,000 non-null keys resolve; 0 null(s) |
| `fact_orders` | fk:seller_id | OK PASS | error | seller_id -> dim_seller.seller_id: 100.0000% of 85,000 non-null keys resolve; 0 null(s) |
| `fact_orders` | fk:geo_id | OK PASS | error | geo_id -> dim_geography.geo_id: 100.0000% of 85,000 non-null keys resolve; 0 null(s) |
| `fact_orders` | fk:order_date_key | OK PASS | error | order_date_key -> dim_date.date_key: 100.0000% of 85,000 non-null keys resolve; 0 null(s) |
| `fact_orders` | fk:promised_delivery_date_key | ! WARN | warn | promised_delivery_date_key -> dim_date.date_key: 99.2118% of 85,000 non-null keys resolve; 670 beyond-calendar (extend dimension through >= 20260708); 0 null(s) |
| `fact_orders` | fk:actual_delivery_date_key | ! WARN | warn | actual_delivery_date_key -> dim_date.date_key: 99.0372% of 74,780 non-null keys resolve; 720 beyond-calendar (extend dimension through >= 20260716); 10,220 null(s) |
| `fact_orders` | membership:order_status | OK PASS | error | order_status all canonical within order_status_values |
| `fact_orders` | distribution_ranges | ! WARN | warn | 1 column(s) out of range |
| `fact_returns` | leakage | OK PASS | error | no leakage columns |
| `fact_returns` | primary_key | X FAIL | error | PK ['return_id'] violated: 50 rows in 25 duplicate group(s), 0 null-key row(s) |
| `fact_returns` | duplicate_rows | ! WARN | warn | 50 fully-duplicated row(s) |
| `fact_returns` | null_analysis | ! WARN | warn | 1 column(s) with nulls (intentional dirt) |
| `fact_returns` | fk:order_line_id | OK PASS | error | order_line_id -> fact_orders.order_line_id: 100.0000% of 32,030 non-null keys resolve; 0 null(s) |
| `fact_returns` | fk:reported_reason_code | OK PASS | error | reported_reason_code -> dim_return_reason.reason_code: 100.0000% of 31,697 non-null keys resolve; 333 null(s) |
| `fact_returns` | fk:return_initiated_date_key | ! WARN | warn | return_initiated_date_key -> dim_date.date_key: 97.4649% of 32,030 non-null keys resolve; 812 beyond-calendar (extend dimension through >= 20260807); 0 null(s) |
| `fact_returns` | fk:return_received_date_key | ! WARN | warn | return_received_date_key -> dim_date.date_key: 96.4377% of 32,030 non-null keys resolve; 1,141 beyond-calendar (extend dimension through >= 20260815); 0 null(s) |
| `fact_returns` | distribution_ranges | OK PASS | warn | all ranges valid |
| `fact_returns` | returns_delivered_reconciliation | OK PASS | error | all 32,030 returns reconcile to delivered orders |

## Assumptions

- **"Row-count matching"** is interpreted as per-table row counts (above) plus cross-table reconciliation of `fact_returns` -> `fact_orders` (the `returns_delivered_reconciliation` check).
- Foreign-key nulls are treated as missing data (counted in null analysis), **not** as broken references; only non-null unmatched keys are orphans.
- `fact_orders.actual_delivery_date_key` is nullable by design (null when an order was never delivered).
- Nulls, duplicate rows and out-of-range values are expected Bronze dirt and are surfaced as WARN, to be resolved in the Silver layer.

## Downstream to-do (out of Phase A scope)

- Some `fact_orders.actual_delivery_date_key` values on `delivered` orders fall after the dataset as-of date (2026-06-30), i.e. delivered in the future. That is a *logical* (business-rule) violation, not a referential one, and belongs to a Silver-layer temporal-consistency check - not this referential audit.