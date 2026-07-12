# Phase B - Silver Layer Cleaning Report

**Status:** `OK`  
**Generated:** 2026-07-08T16:28:16  
**Silver directory:** `data/02_silver`  
**Temporal as-of:** `20260707` (events after this are flagged as future-dated anomalies)

## Row counts (Bronze -> Silver)

| Table | Bronze | Silver | Delta |
|---|---:|---:|---:|
| `dim_date` | 546 | 592 | +46 |
| `dim_seller` | 454 | 450 | -4 |
| `dim_listing` | 10,025 | 10,000 | -25 |
| `fact_listing_traffic` | 435,150 | 435,050 | -100 |
| `fact_orders` | 85,000 | 85,000 | +0 |
| `fact_returns` | 32,030 | 32,005 | -25 |
| `dim_geography` | 19 | 19 | +0 |
| `dim_return_reason` | 10 | 10 | +0 |
| `ref_category_economics` | 5 | 5 | +0 |
| `ref_logistics_rate_card` | 24 | 24 | +0 |

## Cleaning actions

| Table | Action | Result |
|---|---|---|
| `dim_date` | extend_dim_date | added 46 calendar row(s): 20260701..20260815 |
| `dim_seller` | standardize_null_tokens | normalized 0 null-like token(s) to NaN |
| `dim_seller` | deduplicate | removed 4 duplicate row(s) on PK ['seller_id'] |
| `dim_seller` | normalize_enum | fulfillment_type: normalized 19 value(s) to ['marketplace_fulfilled', 'seller_fulfilled']; 0 unmapped (kept as-is) |
| `dim_seller` | normalize_enum | seller_country: normalized 9 value(s) to ['local', 'cross_border']; 0 unmapped (kept as-is) |
| `dim_seller` | apply_null_policy | applied null policy to 1 column(s) |
| `dim_listing` | standardize_null_tokens | normalized 0 null-like token(s) to NaN |
| `dim_listing` | deduplicate | removed 25 duplicate row(s) on PK ['listing_id'] |
| `dim_listing` | normalize_category | normalized 261 category value(s); 0 unmapped -> 'Unknown' |
| `dim_listing` | apply_null_policy | applied null policy to 7 column(s) |
| `dim_listing` | flag_invalid_ranges | range-checked 2 column(s) |
| `fact_listing_traffic` | standardize_null_tokens | normalized 0 null-like token(s) to NaN |
| `fact_listing_traffic` | deduplicate | removed 100 duplicate row(s) on PK ['listing_id', 'date_key'] |
| `fact_listing_traffic` | apply_null_policy | applied null policy to 1 column(s) |
| `fact_orders` | standardize_null_tokens | normalized 0 null-like token(s) to NaN |
| `fact_orders` | normalize_enum | payment_method: normalized 1055 value(s) to ['cod', 'card', 'wallet', 'bnpl']; 0 unmapped (kept as-is) |
| `fact_orders` | apply_null_policy | applied null policy to 2 column(s) |
| `fact_orders` | flag_invalid_ranges | range-checked 1 column(s) |
| `fact_orders` | temporal_flags_orders | temporal checks: {'dq_promised_before_order': 0, 'dq_actual_before_order': 0, 'dq_delivered_missing_actual': 0, 'dq_nondelivered_has_actual': 0, 'dq_delivery_after_asof': 55} |
| `fact_returns` | standardize_null_tokens | normalized 0 null-like token(s) to NaN |
| `fact_returns` | deduplicate | removed 25 duplicate row(s) on PK ['return_id'] |
| `fact_returns` | normalize_enum | item_condition_on_receipt: normalized 436 value(s) to ['resellable', 'refurbishable', 'write_off']; 0 unmapped (kept as-is) |
| `fact_returns` | apply_null_policy | applied null policy to 1 column(s) |
| `fact_returns` | temporal_flags_returns | temporal checks: {'dq_received_before_initiated': 0, 'dq_return_before_delivery': 0, 'dq_return_after_asof': 736} |

## Cleaning assumptions

- **Deduplication** keeps the most-complete row per PK (all Bronze PK duplicates were fully-identical, so this is a lossless drop).
- **Never fabricated**: `price`, `item_weight_kg` (feed downstream ratios) and `reported_reason_code` (FK) are kept null + `dq_missing_*` flag. `actual_delivery_date_key` is null by design when undelivered.
- **Documented imputations** (each carries a `dq_imputed_*` flag): `shipping_fee_charged`->0 (free shipping), `add_to_carts`->0, `description_length_chars`->0, `specifications_filled_pct`->0, boolean feature flags->False. These are conservative cleaning assumptions, not asserted facts.
- **Invalid ranges**: `discount_pct`>1 and `image_count`<0 are quarantined to null (attributes); `quantity`<1 is flagged but kept (core fact measure - Gold decides). All carry `dq_out_of_range_*`.
- **Enum normalization** (Phase B addendum) canonicalizes case / whitespace / space-vs-underscore variants for `item_condition_on_receipt`, `payment_method`, `fulfillment_type` and `seller_country`; each carries a `dq_<col>_normalized` flag. This closes the Silver enum gap that Recovery Rate / Return Cost depend on.
- **Date extension** derives weekday/ISO-week/month/quarter/year and Sat-Sun weekends; event flags default False (no major religious / promo / public-holiday events in 2026-07-01..08-15).
- **Temporal as-of = session today**; delivered/return events dated after it are flagged (`dq_delivery_after_asof`, `dq_return_after_asof`) - this implements the Phase A future-delivery to-do without deleting data.

## Verification

Re-run the Phase A audit against the Silver layer:

```
py src/validation/bronze_audit.py --data-dir data/02_silver --report-name validation_report_silver
```

Expected deltas vs Bronze: 4 primary-key FAILs -> 0; date-coverage WARNs -> 0; category normalization WARN -> 0. Intentionally-remaining WARNs: kept nulls (`price`, `item_weight_kg`, `actual_delivery_date_key`, `reported_reason_code`), the quarantined-to-null range values, and `quantity` out-of-range (flagged, kept by design).