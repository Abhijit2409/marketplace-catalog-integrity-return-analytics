# Power BI Dashboard Specification — Marketplace Catalog Integrity & Return Analytics

**Status:** Specification only (no `.pbix` built in this task).
**Data source:** the validated Gold layer (`gold.duckdb`, built by
`scripts/build_gold.py`). **Only Gold tables are used**, plus the Silver
`dim_date` as a Power BI Date dimension for time intelligence (called out
explicitly wherever used).
**Audience fit:** UAE / GCC marketplace, commercial, seller-ops and operations
analysts and their executive sponsors. Currency is **AED**; COD/RTO and
catalog-driven returns are the central business narrative.

> **Metric governance.** Every figure on the dashboard traces to a Gold column.
> Measures are labelled either **[Gold passthrough]** (a `SUM`/`MAX` of an
> existing Gold column) or **[Display measure]** (a visual-context
> re-aggregation of existing Gold *component* columns using the *same formula*
> already defined in `config/metrics.yaml` — e.g. a weighted rate). **No new
> business metric is introduced.** LQS, Trust Score, Return Cost and Recoverable
> Profit are consumed as-is from Gold, never recomputed.

---

## 1. Design principles

1. **Action-first, not report-first.** Every page ends in a "so what" — the
   Intervention Queue is the destination, not an appendix.
2. **One grain per page.** Each page is anchored to a single Gold table so
   measures never sum across two fact tables at different grains. The only page
   that blends the two line-level facts is *Returns & RTO*, and it does so with
   explicit, grain-safe measures.
3. **Executive legibility.** Landing page answers "how big is the leakage and
   where is the recovery" in five seconds; detail is one drill-through away.
4. **GCC context baked in.** AED formatting, COD vs prepaid segmentation, RTO as
   a first-class (non-return) loss, and Ramadan / Eid / White-Friday seasonality
   from the Date dimension.
5. **Accessible by construction.** Fixed categorical color order, reserved status
   colors with icon+label, one y-axis per chart, legends for ≥2 series, a light
   **and** dark theme, and — for every chart — a backing **table view / export**
   so identity is never colour-alone. Three light-mode categorical slots (aqua,
   yellow, magenta) sit below 3:1 contrast, so the **relief rule** applies to
   them: ship visible direct labels or the table view.
6. **Point-in-time, and honest about it.** This is a **snapshot** built as of
   `2026-07-07`; the entity marts have no time axis. Trends are legitimate **only**
   on the two line-level facts (which carry real order/return dates spanning the
   calendar) and are confined to the *Returns & RTO* page. The as-of date is shown
   in the global header so no one mistakes the dashboard for a live feed.

---

## 2. Recommended Power BI data model

Import mode (the data is small — ≤ 435k rows in the largest fact — and fully
refreshed by the Gold build). Model shape is a **star with two line-level facts,
three entity marts that double as dimensions-with-measures, one tall KPI table,
one action fact, and a shared Date dimension.**

| Table | Role | Grain | Primary use |
|---|---|---|---|
| `gold_order_line_economics` | Fact | order line | Returns & RTO page, time trends, payment/geo cuts |
| `gold_return_line_economics` | Fact | return line | Returns & RTO page, reason/condition/cost decomposition |
| `gold_listing_metrics` | Mart / dimension | listing | Listing Quality page; listing attributes for facts |
| `gold_seller_metrics` | Mart / dimension | seller | Seller Performance page; seller attributes |
| `gold_category_metrics` | Mart / dimension | category (5) | Category Performance page; category attributes |
| `gold_executive_summary` | KPI table (tall) | one KPI/row (17) | Executive cards (read via measures) |
| `gold_intervention_queue` | Action fact | intervention (1,445) | Intervention Queue page |
| `Date` (from `dim_date`) | Date dimension | day (592) | Time intelligence & GCC seasonality slicers |

**Grain-safety rule (state on the model diagram):** never place
`gold_order_line_economics` and `gold_return_line_economics` measures in the same
visual without an explicit grain-aware measure — they are different facts.
Prefer the pre-aggregated marts for entity KPIs.

---

## 3. Table relationships

All relationships are **single-direction** (filter flows from fact → dimension/mart,
and down the mart hierarchy), **many-to-one**, unless noted.

| From (many) | To (one) | Active? | Notes |
|---|---|---|---|
| `Date[date_key]` | `gold_order_line_economics[order_date_key]` | **Active** | default date context |
| `Date[date_key]` | `gold_return_line_economics[return_initiated_date_key]` | Inactive | `USERELATIONSHIP` for return timing |
| `gold_order_line_economics[listing_id]` | `gold_listing_metrics[listing_id]` | Active | slice line fact by listing attrs |
| `gold_order_line_economics[seller_id]` | `gold_seller_metrics[seller_id]` | Active | |
| `gold_order_line_economics[category]` | `gold_category_metrics[category]` | Active | |
| `gold_return_line_economics[listing_id]` | `gold_listing_metrics[listing_id]` | Active | |
| `gold_listing_metrics[seller_id]` | `gold_seller_metrics[seller_id]` | Active | mart hierarchy |
| `gold_listing_metrics[category]` | `gold_category_metrics[category]` | Active | |
| `gold_seller_metrics[primary_category]` | `gold_category_metrics[category]` | Active | |
| `gold_intervention_queue[seller_id]` | `gold_seller_metrics[seller_id]` | Active | |
| `gold_intervention_queue[category]` | `gold_category_metrics[category]` | Active | |

- `gold_executive_summary` is **unrelated** (standalone). Its cards are driven by
  filtered measures on `kpi_name`; it is filtered to the single `as_of_date_key`.
- `gold_intervention_queue.entity_id` is polymorphic (a listing *or* a seller),
  so it is **not** related to `gold_listing_metrics`; listing drill-through uses
  `entity_id` as a report-drill filter instead of a model relationship.

---

## 4. DAX measure list

Grouped; each tagged **[P]** = Gold passthrough or **[D]** = display measure
(re-aggregation of Gold components, identical formula, no new logic). Names are
suggestions; formats in brackets.

### 4.1 Executive KPI pickers (from `gold_executive_summary`) — [D]
A single helper pattern reads any KPI by name:
```
KPI Value :=
VAR k = SELECTEDVALUE( _KpiName[kpi_name] )   -- or hardcode per card
RETURN CALCULATE( SUM( gold_executive_summary[kpi_value] ),
                  gold_executive_summary[kpi_name] = k )
```
Concrete cards (each a thin wrapper, `[AED #,0]` / `[#,0]` / `[0.0%]`):
`Total Return Cost`, `Total Recoverable Profit`, `Total Gross Margin`,
`Net Margin After Returns`, `Marketplace Catalog Return Rate`,
`Marketplace RTO Rate`, `Aggregate Recovery Rate`, `Toxic RTO Concentration`,
`Fashion Return-Cost Share`, `Fashion Recoverable-Profit Share`,
`Bottom-LQS Revenue Share`, `Bottom-LQS Return-Cost Share`,
`Loss-Making Listings`, plus the four volume counts.

### 4.2 Financial totals (marts / facts) — [P]
`Gross Margin AED := SUM(gold_listing_metrics[gross_margin])` (or the
seller/category mart on their pages) `[AED #,0]`;
`Return Cost AED`, `Recoverable Profit AED`,
`Net Margin After Returns AED := SUM([gross_margin]) - SUM([return_cost])`,
`RTO Cost AED := SUM(gold_order_line_economics[rto_cost_aed])`,
`Realized Revenue AED`, `Returned Value AED`, `Recovered Value AED`.

### 4.3 Weighted rates (never average a rate) — [D]
Recompute from Gold component columns exactly as `metrics.yaml` defines them, so
they respond to slicer context:
```
Catalog Return Rate := DIVIDE( SUM([catalog_returned_units]), SUM([delivered_units]) )   -- [0.0%]
RTO Rate            := DIVIDE( SUM([rto_orders]),            SUM([shipped_orders]) )
Recovery Rate       := DIVIDE( SUM([recovered_value]),      SUM([returned_value]) )
On-Time Rate        := DIVIDE( SUM(oe[is_on_time]),         SUM(oe[is_delivered]) )     -- from order fact
```
(Component columns exist on the listing/seller/category marts; on the facts use
the boolean flags cast to int.)

### 4.4 Quality & trust (marts) — [P]
`Avg LQS := AVERAGE(gold_listing_metrics[listing_quality_score])` `[0.0]`;
`Avg Trust Score := AVERAGE(gold_seller_metrics[trust_score])`.

### 4.5 Ranking / concentration — [P] / [D]
`Toxic RTO Concentration := DIVIDE( CALCULATE(SUM(seller_rto_cost), gold_seller_metrics[is_top_decile_rto_cost]=TRUE), SUM(seller_rto_cost) )` **[D]**;
`Loss-Making Listings := CALCULATE(COUNTROWS(gold_listing_metrics), gold_listing_metrics[net_margin_after_returns] < 0)` **[D]**;
`Queue Opportunity AED := SUM(gold_intervention_queue[priority_opportunity_aed])` **[P]**.

### 4.6 Time intelligence (Date dim) — [D]
`Return Cost MTD/QTD/YTD`, `Return Cost MoM %`, `Orders by Month` — standard
`TOTALYTD` / `DATEADD` patterns on `Date[full_date]`. GCC-season measures:
`Ramadan Return Cost := CALCULATE([Return Cost AED], Date[is_ramadan]=TRUE)`.

### 4.7 Display/format helpers — [D]
`AED KPI (label)`, dynamic titles (`"Return cost — " & SELECTEDVALUE(category)`),
conditional-format status keys (see §6 status colors).

---

## 5. Page navigation plan

- **Landing:** Executive Command Center. A left nav rail (bookmarks + buttons)
  links all six pages; the active page is highlighted.
- **Drill-through targets:**
  - Category Performance → Listing Quality (filtered to category).
  - Seller Performance → Listing Quality (filtered to seller) and → Seller detail tooltip page.
  - Listing Quality → a Listing detail drill-through (single-listing card).
  - Intervention Queue → the entity's page (Seller Performance for seller rows;
    Listing detail for listing rows) via `entity_id`.
- **Global:** a persistent header with the `as_of_date_key`, a Category slicer
  synced across pages (Category, Seller, Listing, Returns), and a "Reset filters"
  bookmark. Back buttons on every drill-through target.

---

## 6. Visual design & color guidance

Grounded in the data-viz reference palette (validate the exported Power BI theme
JSON with the skill's `scripts/validate_palette.js` when it is built in the next
phase).

**Categorical (identity) — fixed order, assigned by entity, never by rank, never
cycled:** blue `#2a78d6`, aqua `#1baf7a`, yellow `#eda100`, green `#008300`,
violet `#4a3aa7`, red `#e34948`, magenta `#e87ba4`, orange `#eb6834`. Used for the
**five product categories** (fixed mapping so Fashion is always the same hue on
every page) and for payment methods. A 9th series folds into "Other".

**Sequential (magnitude) — single blue hue, light→dark** (`#cde2fb` → `#0d366b`):
LQS heat, return-cost intensity, choropleth-style tables.

**Diverging (polarity) — blue ↔ red with a gray midpoint** (`#f0efec` light /
`#383835` dark): `net_margin_after_returns` (loss vs profit) and
`seller_percentile_within_category`. Never a hue at the midpoint.

**Status (reserved — never a series color), always with icon + label:**
good `#0ca30c`, warning `#fab219`, serious `#ec835a`, critical `#d03b3b`. Used for
priority bands, toxic-RTO flags, loss-making flags, LQS bands.

**Ink & chrome:** primary `#0b0b0b`/dark `#ffffff`, secondary `#52514e`/`#c3c2b7`,
muted axis `#898781`, hairline grid `#e1e0d9`/`#2c2c2a`. Surfaces `#fcfcfb` light /
`#1a1a19` dark. Deliver **both** themes.

**Rules (non-negotiable):** one y-axis per chart (no dual-axis — use two charts or
index to a base); legend present for ≥2 series and ≤4 series also direct-labeled;
recessive gridlines; text uses ink tokens (never the series color); font
`system-ui/Segoe UI`; `tabular-nums` on table columns and axis ticks; **AED**
currency with thousands separators; percentages one decimal.

**GCC specifics:** support an **Arabic / RTL** layout variant (mirror visuals,
right-aligned nav); surface UAE public-holiday / Ramadan / Eid / White-Friday
context from the Date dimension in trend tooltips.

**Optional modern enhancements (nice-to-have, not core):**
- **Field parameters** on Category & Seller pages to let the user swap the
  ranking metric (recoverable profit ↔ return cost ↔ net margin) in one visual —
  cuts visual count and reads as current Power BI practice.
- **Custom report tooltip pages** standardized across entity visuals (a compact
  entity card on hover) rather than the default tooltip.
These are explicitly optional so the core build stays lean.

---

## 7. Dashboard storytelling flow

1. **How big?** Executive Command Center: ~AED 2.81M return-cost leakage, AED 3.19M
   recoverable, net margin after returns AED 1.87M.
2. **Where?** Category Performance: Fashion ≈ 50% of return cost and ≈ 59% of the
   recovery opportunity.
3. **Who?** Seller Performance: the top-decile RTO-cost tail and low-trust sellers.
4. **Why?** Listing Quality: low LQS drives catalog returns; the bottom-LQS
   quartile over-indexes on return cost.
5. **Through what mechanism?** Returns & RTO: catalog-reason mix, recovery by
   condition, COD-driven RTO.
6. **So do what?** Intervention Queue: 1,445 ranked actions worth ~AED 1.59M,
   owner-assigned, highest-opportunity first.

Each page carries a one-line narrative banner stating its step in this flow.

---

## 8. Page specifications

### Page 1 — Executive Command Center
- **Target audience:** Head of Marketplace, Commercial Director, executive sponsors.
- **Business objective:** size the return/RTO leakage and point to the biggest
  recoverable opportunity in one screen.
- **Source Gold tables:** `gold_executive_summary` (all cards); `gold_category_metrics`
  (Fashion/share bars).
- **KPI cards:** one **north-star hero number** — **Total Recoverable Profit**
  (the money on the table) — then **6 primary tiles**: Total Return Cost, Net
  Margin After Returns, Marketplace Catalog Return Rate, Marketplace RTO Rate,
  Toxic RTO Concentration, Loss-Making Listings. A collapsed **secondary strip**
  (below the fold / on hover) carries the rest: Total Gross Margin, Aggregate
  Recovery Rate, and the four volume counts. Keeping the primary set to seven
  protects five-second legibility.
- **Visuals:** (a) leakage **waterfall** Gross Margin → −Return Cost → Net Margin
  After Returns; (b) 100%-stacked / share bars of `percentage_of_marketplace_return_cost`
  and `_recoverable_profit` by category (Fashion highlighted); (c) recovery-rate
  gauge; (d) bottom-LQS revenue vs return-cost share mini-bars.
- **Slicers:** as-of date (display), category (synced).
- **Drill-throughs:** category bar → Category Performance.
- **Interactions:** cards are static headline; clicking a category bar cross-filters
  the share visuals.
- **Required DAX:** §4.1 pickers; `Toxic RTO Concentration`, `Loss-Making Listings`.
- **Layout:** north-star number top-left at largest type; the 6 primary tiles in
  one row beside it; waterfall centre-left, category shares centre-right;
  secondary strip collapsed along the bottom. Narrative banner: "How big, and where."
- **Insight narrative:** "AED 2.81M leaks to returns; AED 3.19M is recoverable, and
  Fashion is half the problem."
- **Interview talking points:** why RTO is separated from returns (Golden Rule 2);
  why recoverable profit is an addressable-fraction upper bound; how the tall KPI
  table drives cards via one measure pattern.

### Page 2 — Category Performance
- **Target audience:** Category Managers, Commercial Analysts.
- **Business objective:** compare the 5 categories on margin, return economics and
  recovery opportunity; decide where to invest.
- **Source Gold tables:** `gold_category_metrics`.
- **KPI cards:** selected-category Gross Margin, Return Cost, Recoverable Profit,
  Net Margin After Returns, Avg LQS, Avg Trust, Catalog Return Rate.
- **Visuals:** (a) bar of Recoverable Profit by category with `category_rank_by_recoverable_profit`
  labels; (b) **margin vs return cost** grouped bars (one y-axis, AED); (c) rank
  table (3 rank columns + shares); (d) catalog-return-rate vs LQS scatter (5 points).
- **Slicers:** category (multi-select), Date-season (Ramadan/Eid/White-Friday) for
  context via order fact if trend added.
- **Drill-throughs:** category → Listing Quality (filtered) and → Seller Performance
  (filtered to `primary_category`).
- **Interactions:** selecting a category highlights it across all visuals.
- **Required DAX:** §4.2 totals on category mart; ranks are passthrough columns.
- **Layout:** KPI strip top; recoverable-profit bar + rank table middle; scatter +
  share bars bottom.
- **Insight narrative:** "Fashion tops recoverable profit but ranks best on margin
  loss — its gross margin absorbs the return cost."
- **Interview talking points:** why `margin_loss` ranks on net margin (distinct from
  return-cost rank); marketplace-share percentages summing to 100%.

### Page 3 — Seller Performance
- **Target audience:** Seller Experience / Marketplace Governance, Risk.
- **Business objective:** rank sellers on trust and profitability; surface the toxic
  RTO tail and coaching candidates.
- **Source Gold tables:** `gold_seller_metrics`.
- **KPI cards:** Avg Trust Score, sellers in top-decile RTO cost, Toxic RTO
  Concentration, Net Margin After Returns, Recoverable Profit.
- **Visuals:** (a) **Trust Score distribution** histogram; (b) toxic-RTO tail —
  bar of `seller_rto_cost` for `is_top_decile_rto_cost` sellers (status-colored);
  (c) `seller_percentile_within_category` vs trust scatter (diverging color); (d)
  seller scorecard **table** (tabular-nums): tier, primary_category, trust, LQS,
  RTO rate, net margin, recoverable profit, rank.
- **Slicers:** seller_tier, seller_country, fulfillment_type, primary_category.
- **Drill-throughs:** seller → Listing Quality (filtered to seller).
- **Interactions:** table row selection cross-filters the scatter/bars.
- **Required DAX:** `Avg Trust Score` [P]; `Toxic RTO Concentration` [D];
  top-decile count `CALCULATE(COUNTROWS, is_top_decile_rto_cost=TRUE)`.
- **Layout:** KPI strip; distribution + tail bar middle; scatter + scorecard table
  bottom (table is the workhorse).
- **Insight narrative:** "Trust clusters high (71–84); RTO cost is only mildly
  concentrated (top-decile ≈ 17%), so target coaching by absolute opportunity."
- **Interview talking points:** why `is_toxic_rto` is 0 on this data and the exec
  uses the concentration scalar instead; Trust Score is an observable proxy (no
  hidden variables); category-adjusted percentile benchmarking.

### Page 4 — Listing Quality
- **Target audience:** Catalog / Content Quality Managers, Category ops.
- **Business objective:** connect catalog quality (LQS) to catalog-driven returns and
  to recoverable profit; find the listings to fix.
- **Source Gold tables:** `gold_listing_metrics`.
- **KPI cards:** Avg LQS, Bottom-LQS Return-Cost Share (from exec), Recoverable
  Profit, Catalog Return Rate.
- **Visuals:** (a) **LQS distribution** histogram with quartile bands (status-banded);
  (b) **LQS vs catalog_return_rate** scatter (sequential-blue density, trendline);
  (c) recoverable-profit **Pareto** (bar + cumulative line — two charts, not
  dual-axis); (d) bottom-quartile listing table.
- **Slicers:** category, seller_tier (via seller relationship), has-video / size-chart
  proxies not in mart → omit (only Gold columns).
- **Drill-throughs:** listing → Listing detail card; up to Seller Performance.
- **Interactions:** brushing the scatter filters the Pareto and table.
- **Required DAX:** `Avg LQS` [P]; `Catalog Return Rate` [D];
  `Recoverable Profit AED` [P].
- **Layout:** KPI strip; distribution + scatter middle; Pareto + table bottom.
- **Insight narrative:** "Bottom-LQS quartile ≈ 25% of listings but ≈ 22% of return
  cost — poor catalog quality drives disproportionate returns."
- **Interview talking points:** how LQS is category-aware and weight-renormalized;
  why imputed catalog signals are treated as "absent"; LQS is Gold-only (Golden Rule 1).

### Page 5 — Returns & RTO
- **Target audience:** Reverse Logistics, Last-Mile / Fulfillment Ops, COD Risk.
- **Business objective:** explain the return/RTO *mechanism* — reasons, salvage, and
  the COD-driven RTO story — over time and geography.
- **Source Gold tables:** `gold_return_line_economics` **and** `gold_order_line_economics`
  (the only page that blends the two facts, with grain-safe measures) + `Date`.
- **KPI cards:** Return Cost AED, Recovery Rate, RTO Cost AED, RTO Rate,
  Merchandise Loss AED.
- **Visuals — 3 primary (keep the page legible):** (a) **RTO rate by
  payment_method** (COD vs prepaid — the headline GCC story); (b) **return-cost
  decomposition** stacked bar (reverse logistics + handling + merchandise loss),
  2px surface gaps; (c) returns by `reason_group` (catalog-related highlighted).
  **Secondary (a toggle/bookmark or custom tooltip, not co-equal):** recovery by
  `item_condition_on_receipt`; RTO by `logistics_zone`; return-cost monthly
  **trend** (return fact + Date, Ramadan/Eid markers). This prevents the page from
  becoming five co-equal stories.
- **Slicers:** category, payment_method, reason_group, logistics_zone, Date range.
- **Drill-throughs:** none outward; this is the explanatory page.
- **Interactions:** payment_method slicer drives the RTO visuals; reason slicer drives
  the return visuals; grain-safe measures keep the two facts separate.
- **Required DAX:** `RTO Rate` [D] and `On-Time Rate` [D] from the order fact;
  `Recovery Rate` [D] and return-cost component sums [P] from the return fact;
  time-intelligence measures §4.6.
- **Layout:** KPI strip; decomposition + reason mix middle; condition recovery +
  COD/zone RTO + monthly trend bottom.
- **Insight narrative:** "COD RTO runs ~14.5% vs ~1.6% prepaid (~9×); recovery holds
  at ~69% but write-offs are the salvage ceiling."
- **Interview talking points:** why RTO cost uses the forward leg + handling; why
  returns are delivered-only (Golden Rule 2); the two-fact grain-safety design.

### Page 6 — Intervention Queue
- **Target audience:** everyone operational — Catalog Ops, Seller Experience, COD
  Risk, Category Management (the daily worklist).
- **Business objective:** answer "with limited resources this week, what do we fix
  first to maximize recovered profit?"
- **Source Gold tables:** `gold_intervention_queue`.
- **KPI cards:** Total Queue Opportunity AED, opportunity by the four intervention
  types (Seller Coaching, Catalog Fix, COD Risk Reduction, Delisting), High-priority
  count.
- **Visuals:** (a) the **ranked action table** (workhorse; tabular-nums):
  global_priority_rank, intervention_type, entity_id, category, priority_opportunity_aed,
  recommended_owner, recommendation_summary — sorted by rank; (b) opportunity by
  intervention_type bar; (c) opportunity by recommended_owner bar; (d) priority-band
  (High/Medium/Low) donut with status colors.
- **Slicers:** intervention_type, recommended_owner, priority, category, entity_type.
- **Drill-throughs:** row → Seller Performance (seller rows) or Listing detail
  (listing rows) via `entity_id`.
- **Interactions:** slicers narrow the table; selecting a type/owner bar filters the
  table; the table is exportable for hand-off.
- **Required DAX:** `Queue Opportunity AED` [P]; counts by band `CALCULATE(COUNTROWS,
  priority="High")` [P].
- **Layout:** KPI strip top; type/owner/band charts as a thin band; the ranked table
  fills the rest (it is the deliverable).
- **Insight narrative:** "Top actions are Seller Coaching of high-leakage Fashion/
  Electronics sellers — coaching fixes many listings at once."
- **Interview talking points:** the single comparable ranking unit
  (`priority_opportunity_aed`); anti-double-count design (systemic sellers coached
  instead of per-listing fixes); owner-assigned, exportable worklist.

---

## 9. Appendix — page → primary Gold table map

| Page | Primary table | Supporting |
|---|---|---|
| Executive Command Center | `gold_executive_summary` | `gold_category_metrics` |
| Category Performance | `gold_category_metrics` | — |
| Seller Performance | `gold_seller_metrics` | — |
| Listing Quality | `gold_listing_metrics` | `gold_seller_metrics` (slice) |
| Returns & RTO | `gold_return_line_economics` + `gold_order_line_economics` | `Date` |
| Intervention Queue | `gold_intervention_queue` | `gold_seller_metrics`, `gold_category_metrics` |

*Specification only. No `.pbix`, theme JSON, Python, README, or GitHub work is
part of this task.*
