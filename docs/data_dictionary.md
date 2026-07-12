# Data Dictionary — Silver Layer & Gold Semantic Contract

**Source layer:** `data/02_silver` (produced by Phase B, verified by the Phase A
audit re-run — see `docs/validation_report_silver.md`).
**Companion contract:** `config/metrics.yaml` (metric definitions).
**Purpose:** document every Silver table and column — type, business meaning,
nullability, cleaning applied in Phase B, and whether the column participates in
a Gold metric — so the Gold layer can be implemented against a fixed contract.

---

## Conventions & legend

- **Type** is a logical type: `date_key` = integer `YYYYMMDD`; `AED` = decimal
  currency; `bool`, `int`, `float`, `string`, `date`.
- **Nullable** — "No" = never null; "Yes" = legitimately nullable (reason
  given); "Yes→No" = was nullable in Bronze, filled in Phase B.
- **`dq_*` columns** are data-quality annotations added in Phase B (all boolean,
  never null). They are metric **guards**, not measures: they mark imputed,
  missing, quarantined or temporally-anomalous rows so Gold can down-weight or
  exclude them.
- **Metric codes** (defined in `config/metrics.yaml`):

  | Code | Metric | Derived-only (Golden Rule 1) |
  |---|---|---|
  | GM | Gross Margin | no |
  | RR | Recovery Rate | no |
  | RTO | RTO Rate | no |
  | CRR | Catalog Return Rate | no |
  | LQS | Listing Quality Score | **yes** |
  | RC | Return Cost | **yes** |
  | NMAR | Net Margin After Returns | no |
  | RP | Recoverable Profit | **yes** |
  | TRC | Toxic RTO Concentration | no |
  | TS | Trust Score | **yes** |

> **Golden Rule 1** — `LQS`, `RC`, `RP`, `TS` are **derived-only**. They do not
> exist in Bronze or Silver and appear nowhere in the tables below; they are
> created only in Gold. See the [derived-only section](#derived-only-gold-metrics-golden-rule-1).
>
> **Golden Rule 2** — RTO lives only in `fact_orders.order_status`;
> `fact_returns` contains only delivered order lines.

---

## `dim_date` — calendar dimension (592 rows)

Extended in Phase B by **+46 rows** through `2026-08-15` (inclusive) so all
fact date keys resolve.

| Column | Type | Business meaning | Nullable | Cleaning applied (Phase B) | Gold participation |
|---|---|---|---|---|---|
| `date_key` | date_key (PK) | Surrogate calendar key | No | Extension rows appended | Join key / time grain (all metrics) |
| `full_date` | date | Calendar date | No | Derived for extension | Time slicer |
| `day_of_week` | string | Weekday name | No | Derived | Time slicer |
| `week_of_year` | int | ISO week number | No | Derived (ISO week) | Time slicer |
| `month` | int | Month 1–12 | No | Derived | Time slicer |
| `quarter` | int | Quarter 1–4 | No | Derived | Time slicer |
| `year` | int | Calendar year | No | Derived | Time slicer |
| `is_weekend` | bool | Sat/Sun (UAE) | No | Derived (Sat/Sun) | Seasonality slicer |
| `is_ramadan` | bool | Ramadan flag | No | `False` in extension window (assumption) | Seasonality slicer |
| `is_eid_period` | bool | Eid flag | No | `False` in extension window (assumption) | Seasonality slicer |
| `is_white_friday_period` | bool | White Friday promo flag | No | `False` in extension window (assumption) | Promo/seasonality slicer |
| `is_uae_public_holiday` | bool | UAE public holiday | No | `False` in extension window (assumption) | Seasonality slicer |

---

## `dim_geography` — delivery geography (19 rows)

| Column | Type | Business meaning | Nullable | Cleaning applied | Gold participation |
|---|---|---|---|---|---|
| `geo_id` | string (PK) | Geography surrogate key | No | None | Join key — RC, TRC, RTO |
| `emirate` | string | Emirate (Dubai, Abu Dhabi, …) | No | None | Geo slicer |
| `city` | string | City / district | No | None | Geo slicer |
| `zone_type` | string | `urban_core` / `suburban` / `remote` | No | None | Context |
| `logistics_zone` | string | Rate-card zone (`urban_core`/`suburban`/`remote`) | No | None | **RC, TRC** (rate-card join) |

---

## `dim_listing` — product listing dimension (10,000 rows)

Deduplicated in Phase B (**−25** duplicate `listing_id`s). Category normalized
(261 values). Catalog attributes are the raw material for **LQS**.

| Column | Type | Business meaning | Nullable | Cleaning applied | Gold participation |
|---|---|---|---|---|---|
| `listing_id` | string (PK) | Listing surrogate key | No | Deduplicated | Join key — GM/LQS/RC/RP rollups |
| `seller_id` | string (FK→dim_seller) | Owning seller | No | None | Join → seller rollups |
| `category` | string | Product category (5 canonical) | No | **Normalized** case+whitespace | **GM, RR, RC, RP, CRR, LQS** (drives economics & LQS weights) |
| `subcategory` | string | Subcategory (24 values) | No | None | Slicer |
| `brand` | string | Brand | Yes→No | Imputed `Unknown` (+`dq_imputed_brand`) | Slicer |
| `listing_created_date` | date | Listing creation date | No | None | Context (listing age) |
| `price` | AED | List price | **Yes** (kept) | `flag_missing` (never fabricated) | Context (value uses `unit_selling_price`) |
| `discount_pct` | float [0,1] | List discount fraction | **Yes** (10 quarantined) | Values >1 nulled + flag | Context |
| `image_count` | int | # listing images | **Yes** (10 quarantined) | Negatives nulled + flag | **LQS** |
| `has_video` | bool | Has product video | No | None | **LQS** |
| `title_length_chars` | int | Title length | No | None | **LQS** |
| `description_length_chars` | float | Description length | Yes→No | Imputed `0` + flag | **LQS** |
| `specifications_filled_pct` | float [0,1] | Spec completeness | Yes→No | Imputed `0` + flag | **LQS** |
| `has_size_chart` | bool | Size chart present | Yes→No | Imputed `False` + flag | **LQS** (weighted up for Fashion) |
| `has_dimensions_listed` | bool | Dimensions present | Yes→No | Imputed `False` + flag | **LQS** (weighted up for Home) |
| `variant_count` | int | # variants | No | None | **LQS** |
| `item_weight_kg` | float | Item weight | **Yes** (kept) | `flag_missing` (never fabricated) | **RC, TRC** (weight band) |
| `dq_category_normalized` | bool | Category value was normalized | No | Added | Audit guard |
| `dq_category_unmapped` | bool | Category could not map (→`Unknown`) | No | Added | Audit guard (expect all False) |
| `dq_imputed_brand` | bool | `brand` was imputed | No | Added | Guard |
| `dq_imputed_description_length_chars` | bool | imputed | No | Added | **LQS** guard (down-weight) |
| `dq_imputed_specifications_filled_pct` | bool | imputed | No | Added | **LQS** guard |
| `dq_imputed_has_size_chart` | bool | imputed | No | Added | **LQS** guard |
| `dq_imputed_has_dimensions_listed` | bool | imputed | No | Added | **LQS** guard |
| `dq_missing_price` | bool | `price` is missing | No | Added | Guard |
| `dq_missing_item_weight_kg` | bool | `item_weight_kg` missing | No | Added | **RC** guard (weight fallback) |
| `dq_out_of_range_discount_pct` | bool | discount >1 quarantined | No | Added | Guard |
| `dq_out_of_range_image_count` | bool | image_count <0 quarantined | No | Added | **LQS** guard |

---

## `dim_seller` — seller dimension (450 rows)

Deduplicated in Phase B (**−4** duplicate `seller_id`s).

| Column | Type | Business meaning | Nullable | Cleaning applied | Gold participation |
|---|---|---|---|---|---|
| `seller_id` | string (PK) | Seller surrogate key | No | Deduplicated | Join key |
| `seller_name` | string | Seller display name | No | None | Descriptive |
| `seller_tier` | string | `T1`/`T2`/`T3`/`Unknown` | Yes→No | Imputed `Unknown` (+`dq_imputed_seller_tier`) | **TS** (`seller_tier_prior`) |
| `fulfillment_type` | string | `marketplace_fulfilled`/`seller_fulfilled` | No | **Normalized** case+whitespace+separator (+`dq_fulfillment_type_normalized`) | Risk slicer |
| `seller_country` | string | `local`/`cross_border` | No | **Normalized** case+whitespace+separator (+`dq_seller_country_normalized`) | Risk slicer |
| `join_date` | date | Seller onboarding date | No | None | Context (tenure) |
| `dq_imputed_seller_tier` | bool | `seller_tier` was imputed | No | Added | **TS** guard (down-weight) |
| `dq_fulfillment_type_normalized` | bool | `fulfillment_type` was canonicalized | No | Added (Phase B addendum, 19 rows) | Guard |
| `dq_seller_country_normalized` | bool | `seller_country` was canonicalized | No | Added (Phase B addendum, 9 rows) | Guard |

---

## `dim_return_reason` — return reason lookup (10 rows)

| Column | Type | Business meaning | Nullable | Cleaning applied | Gold participation |
|---|---|---|---|---|---|
| `reason_code` | string (PK) | Reason code `R001`–`R010` | No | None | Join — **CRR, RP** |
| `reason_description` | string | Human-readable reason | No | None | Descriptive |
| `reason_group` | string | `catalog_mismatch`/`sizing`/`damaged`/`remorse`/`delivery_issue` | No | None | **TS** (damage share), analysis slicer |
| `is_catalog_related` | bool | Reason is catalog-attributable | No | None | **CRR, RP** (defines addressable returns) |
| `is_refund_eligible` | bool | Reason qualifies for refund | No | None | Refund-policy context |

---

## `fact_listing_traffic` — daily listing traffic (435,050 rows)

Deduplicated in Phase B (**−100** duplicate `(listing_id, date_key)`).

| Column | Type | Business meaning | Nullable | Cleaning applied | Gold participation |
|---|---|---|---|---|---|
| `listing_id` | string (FK→dim_listing) | Listing | No | None | Join |
| `date_key` | date_key (FK→dim_date) | Traffic date | No | None | Time join |
| `impressions` | int | Search/browse impressions | No | None | Traffic/conversion analytics *(supporting; not a core-10 input)* |
| `detail_page_views` | int | Detail-page views | No | None | Traffic/conversion analytics *(supporting)* |
| `add_to_carts` | float | Add-to-cart events | Yes→No | Imputed `0` + flag | Traffic/conversion analytics *(supporting)* |
| `dq_imputed_add_to_carts` | bool | `add_to_carts` imputed | No | Added | Guard |

> This table supports conversion-funnel analysis and future LQS calibration, but
> is **not** a direct input to any of the ten contracted metrics.

---

## `fact_orders` — order lines (85,000 rows)

The central fact. Not deduplicated (PK was clean). Carries RTO status
(Golden Rule 2) and temporal `dq_*` flags from Phase B.

| Column | Type | Business meaning | Nullable | Cleaning applied | Gold participation |
|---|---|---|---|---|---|
| `order_line_id` | string (PK) | Order-line surrogate key | No | None | Join — returns link |
| `order_id` | string | Parent order | No | None | Order grouping |
| `listing_id` | string (FK) | Listing sold | No | None | **GM, RC, RP, LQS** rollup join |
| `seller_id` | string (FK) | Seller | No | None | **RTO, TS, TRC** join |
| `order_date_key` | date_key (FK) | Order date | No | None | Time grain |
| `geo_id` | string (FK) | Delivery geography | No | None | **RC, TRC, RTO** (logistics/geo) |
| `payment_method` | string | `cod`/`card`/`wallet`/`bnpl` | No | **Normalized** case+whitespace (+`dq_payment_method_normalized`) | **RTO, TRC** (COD segmentation) |
| `quantity` | int | Units ordered | No (−1 flagged, kept) | `dq_out_of_range_quantity` | **GM**, denominators |
| `unit_selling_price` | AED | Per-unit price charged | No | None | **GM, RR, RC, RP** (value base) |
| `item_discount_amount` | AED | Line discount (AED) | No | None | **GM** |
| `shipping_fee_charged` | AED | Customer-paid shipping | Yes→No | Imputed `0` + flag | Revenue context (logistics offset) |
| `promised_delivery_date_key` | date_key (FK) | Promised delivery | No | None | **TS** (on-time) |
| `actual_delivery_date_key` | date_key (FK) | Actual delivery | **Yes — by design** (null iff undelivered) | Kept null | **TS** (on-time) |
| `delivery_attempts` | int | Delivery attempts (0–3; 0 = cancelled) | No | None | **TS** (efficiency) |
| `order_status` | string | `delivered`/`cancelled_pre_shipment`/`rto_customer_refused`/`rto_unreachable` | No | None | **RTO**, denominators, Golden Rule 2 |
| `dq_imputed_shipping_fee_charged` | bool | shipping imputed | No | Added | Guard |
| `dq_out_of_range_quantity` | bool | quantity <1 (kept) | No | Added | **GM** guard (exclude) |
| `dq_promised_before_order` | bool | promised < order date | No | Added | Temporal guard (all False) |
| `dq_actual_before_order` | bool | actual < order date | No | Added | Temporal guard (all False) |
| `dq_delivered_missing_actual` | bool | delivered but no actual date | No | Added | Temporal guard (all False) |
| `dq_nondelivered_has_actual` | bool | non-delivered but has actual date | No | Added | Temporal guard (all False) |
| `dq_delivery_after_asof` | bool | delivered after as-of (future-dated) | No | Added (55 rows) | Temporal guard |
| `dq_payment_method_normalized` | bool | `payment_method` was canonicalized | No | Added (Phase B addendum, 1,055 rows) | Guard |

---

## `fact_returns` — return lines (32,005 rows)

Deduplicated in Phase B (**−25** duplicate `return_id`s). Delivered-only by
construction (Golden Rule 2).

| Column | Type | Business meaning | Nullable | Cleaning applied | Gold participation |
|---|---|---|---|---|---|
| `return_id` | string (PK) | Return surrogate key | No | Deduplicated | Join key |
| `order_line_id` | string (FK→fact_orders) | Returned order line (delivered) | No | None | **RC, RP, CRR** link (Golden Rule 2) |
| `return_initiated_date_key` | date_key (FK) | Return initiated | No | None | Time / temporal |
| `return_received_date_key` | date_key (FK) | Return received at warehouse | No | None | Time / temporal |
| `reported_reason_code` | string (FK→dim_return_reason) | Customer-reported reason | **Yes** (kept) | `flag_missing` (`dq_missing_reported_reason_code`) | **CRR, RP** (catalog attribution) |
| `item_condition_on_receipt` | string | `resellable`/`refurbishable`/`write_off` | No | **Normalized** case+whitespace+separator (+`dq_item_condition_on_receipt_normalized`) | **RR, RC** (recovery mapping) |
| `quantity_returned` | int | Units returned | No | None | **RR, RC, CRR, RP** |
| `refund_amount` | AED | Refund paid to customer | No | None | **RC** (merchandise loss) |
| `refund_method` | string | `original_payment`/`wallet_credit`/`manual_refund` | No | None | Context |
| `dq_missing_reported_reason_code` | bool | reason missing | No | Added | **CRR** guard |
| `dq_received_before_initiated` | bool | received < initiated | No | Added | Temporal guard (all False) |
| `dq_return_before_delivery` | bool | return before delivery | No | Added | Temporal guard (all False) |
| `dq_return_after_asof` | bool | return event after as-of (future-dated) | No | Added (736 rows) | Temporal guard |
| `dq_item_condition_on_receipt_normalized` | bool | `item_condition_on_receipt` was canonicalized | No | Added (Phase B addendum, 436 rows) | **RR, RC** guard |

---

## `ref_category_economics` — category economics (5 rows, pass-through)

| Column | Type | Business meaning | Nullable | Cleaning applied | Gold participation |
|---|---|---|---|---|---|
| `category` | string (PK) | Category | No | None | Join — **GM, RR, RC, RP** |
| `gross_margin_pct` | float [0,1] | Category gross-margin ratio | No | None | **GM, RP** |
| `warehouse_handling_cost_aed` | AED | Per-return handling cost | No | None | **RC, TRC** |
| `recovery_pct_resellable` | float [0,1] | Salvage ratio if resellable | No | None | **RR, RC** |
| `recovery_pct_refurbishable` | float [0,1] | Salvage ratio if refurbishable | No | None | **RR, RC** |

---

## `ref_logistics_rate_card` — logistics rate card (24 rows, pass-through)

| Column | Type | Business meaning | Nullable | Cleaning applied | Gold participation |
|---|---|---|---|---|---|
| `logistics_zone` | string (PK) | `urban_core`/`suburban`/`remote` | No | None | Join — **RC, TRC** |
| `weight_band` | string (PK) | `<=0.5kg`/`0.5-2kg`/`2-5kg`/`5-15kg` | No | None | Join — **RC, TRC** |
| `leg` | string (PK) | `forward` / `reverse` | No | None | **RC** (reverse), **TRC** (forward) |
| `cost_aed` | AED | Leg cost | No | None | **RC, TRC** |

---

## Derived-only Gold metrics (Golden Rule 1)

The following are **created in Gold only** and must **not** appear in any Bronze
or Silver table above. Verified absent from Silver. Definitions in
`config/metrics.yaml`.

| Column (Gold) | Metric | Grain |
|---|---|---|
| `listing_quality_score` | LQS | listing |
| `return_cost_aed` | RC | return line |
| `recoverable_profit_aed` | RP | listing |
| `trust_score` | TS | seller (also listing) |

---

## Known Silver data-quality gaps — RESOLVED (Phase B addendum)

The enum-casing gaps found while drafting this contract have been fixed in a
Phase B addendum: a `normalize_enums` policy in `config/cleaning_rules.yaml`
canonicalizes case / whitespace / space-vs-underscore variants (strip +
casefold + separator collapse), each with a `dq_<col>_normalized` flag. The
Silver build and audit were re-run (no regression; validation still passes).

| Column | Former issue | Status | Values normalized |
|---|---|---|---|
| `fact_returns.item_condition_on_receipt` | `RESELLABLE`, `' resellable '`, `write off` vs `write_off` | ✅ Resolved | 436 rows → `{resellable, refurbishable, write_off}` |
| `fact_orders.payment_method` | `COD`, `' cod '` vs `cod` | ✅ Resolved | 1,055 rows → `{cod, card, wallet, bnpl}` |
| `dim_seller.fulfillment_type` | mixed casing/whitespace | ✅ Resolved | 19 rows → `{marketplace_fulfilled, seller_fulfilled}` |
| `dim_seller.seller_country` | `LOCAL`, `cross border` vs `cross_border` | ✅ Resolved | 9 rows → `{local, cross_border}` |

All four kept in the Silver layer (the clean layer) rather than worked around at
Gold read time. 0 unmapped values in every column.

---

## Cross-file consistency

Every column listed as a `required_input_columns` entry in `config/metrics.yaml`
appears in this dictionary with its metric code in the **Gold participation**
column; every column tagged with a metric code here is cited by that metric in
the contract. The two files are intended to be maintained together.
