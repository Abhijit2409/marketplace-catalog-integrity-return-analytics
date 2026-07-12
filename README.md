# Marketplace Catalog Integrity & Return Analytics

A production-style analytics-engineering project that simulates a GCC marketplace
(Noon / Amazon MENA style) and quantifies **catalog-driven revenue leakage** — the
profit lost to returns and RTO (return-to-origin) — then prioritizes the listing and
seller interventions that recover the most profit per unit of effort.

Built as a layered **Bronze → Silver → Gold** pipeline (DuckDB SQL + Python), with a
fail-closed validation framework at every layer and a semantic contract that governs
every business metric. The Gold layer feeds a six-page Power BI dashboard.

---

## 1. Project overview

The repository takes deliberately imperfect raw marketplace data and turns it into a
governed semantic layer and a ranked, owner-assigned action queue. It demonstrates
data modeling, data quality, SQL, Python, commercial analytics, and BI storytelling
end to end — reproducible from one raw input with a fixed build order.

- **Scale:** 85,000 order lines, 32,005 return lines, 10,000 listings, 450 sellers,
  5 categories, ~435k daily traffic rows.
- **Market:** UAE / GCC. Currency **AED**. COD and RTO are first-class concerns.

## 2. Business problem

Marketplaces lose margin not only to returns but to *catalog quality* — poor images,
missing specs, absent size charts — which drives "item not as described" and sizing
returns, and to **COD-driven RTO**, where orders fail on delivery and never reach the
customer. These losses are diffuse and hard to attribute. The project answers:

> Where is return/RTO profit leaking, how much is *recoverable*, and which specific
> listings and sellers should we fix first to recover the most profit?

## 3. Executive story

From the validated Gold layer (point-in-time snapshot):

- **AED 2.81M** total return cost; **AED 3.19M** recoverable (addressable) profit;
  net margin after returns **AED 1.87M**.
- **Fashion** carries ~**50%** of marketplace return cost and ~**59%** of the recovery
  opportunity — the single biggest lever.
- The **bottom-LQS quartile** of listings holds **22%** of return cost but only **19%**
  of revenue — poor catalog quality drives disproportionate returns.
- **COD RTO** runs **~14.5%** vs **~1.6%** prepaid (~9×) — a structural GCC risk.
- Output: **1,445 ranked interventions** worth **~AED 1.59M** in prioritized recovery,
  each with an owner and a single comparable AED opportunity.

## 4. Repository architecture

Four principles govern the build:

- **Layered and one-directional** — Bronze (raw) → Silver (clean) → Gold (semantic).
  No layer is skipped; no layer reaches backward.
- **Configuration-driven** — schema contracts, cleaning rules and metric definitions
  live in `config/*.yaml`, not in code.
- **Validation before transformation, fail closed** — every layer is audited; a
  structural violation stops the pipeline.
- **Semantic governance** — the four "derived-only" metrics (Listing Quality Score,
  Trust Score, Return Cost, Recoverable Profit) are defined once in `config/metrics.yaml`
  and may exist **only** in Gold.

## 5. Bronze → Silver → Gold

| Layer | Owns | Never contains |
|---|---|---|
| **Bronze** | Raw, deliberately imperfect data (missing values, dupes, mixed casing, invalid values, out-of-range outliers) | Any derived or cleaned value |
| **Silver** | Cleaned, deduplicated, type-consistent rows at source grain; documented `dq_*` quality flags | Business KPIs; the four derived-only metrics |
| **Gold** | Business-metric-bearing tables reshaped to decision grains | Raw cleaning logic; anything an analyst shouldn't consume directly |

## 6. Data pipeline

- **Bronze audit** (`src/validation/bronze_audit.py`) — generic, config-driven data
  audit: primary-key uniqueness, referential integrity (coverage-aware for the calendar
  dimension), null profiling, distribution/range checks, leakage checks, and the
  Golden-Rule reconciliations. Fails closed on structural violations.
- **Silver build** (`src/cleaning/silver_build.py`, `src/cleaning/transforms.py`) —
  deduplication, category & enum normalization (case/whitespace/separator), a
  standardized null-handling policy, invalid-range quarantine, calendar extension, and
  temporal consistency flags. Every synthesized value carries an auditable `dq_*` flag.
- **Gold build** (`sql/gold/00_..07_*.sql`) — two foundational per-line economics facts,
  three entity marts (listing / seller / category), one executive KPI table, and the
  intervention queue. All business logic is defined once and reused downstream.
- **Gold export** (`scripts/export_gold.py`) — deterministic CSV + Parquet export for
  Power BI.

## 7. Validation framework

Validation is not an afterthought — it is a layer.

- **Bronze/Silver:** the same declarative audit runs against both (via `--data-dir`),
  classifying findings as **FAIL** (structural: PK, FK orphans, leakage, broken Golden
  Rules) or **WARN** (intentional dirt to clean downstream). Bronze is *expected* to
  fail closed — that failure is the finding that justifies Silver.
- **Gold:** every `sql/gold/*.sql` file embeds its own validation queries (row counts,
  PK uniqueness, bounds, reconciliation to upstream, financial identities). The
  orchestrator (`scripts/build_gold.py`) runs them as part of the build and **fails
  closed**; `scripts/validate_gold.py` re-runs them independently. Current status:
  **72/72 Gold validations pass**, and every mart reconciles exactly to the foundational
  facts.

## 8. Gold layer overview

| Table | Grain | Rows | Purpose |
|---|---|---:|---|
| `gold_order_line_economics` | order line | 85,000 | Gross margin, RTO classification & cost, delivery timeliness (defined once) |
| `gold_return_line_economics` | return line | 32,005 | Fully-loaded **Return Cost**, recovery, catalog attribution (defined once) |
| `gold_listing_metrics` | listing | 10,000 | **LQS**, catalog return rate, **Recoverable Profit**, net margin after returns |
| `gold_seller_metrics` | seller | 450 | **Trust Score**, RTO toxicity ingredients, category-adjusted percentile |
| `gold_category_metrics` | category | 5 | Portfolio rollups, marketplace-share %, rankings |
| `gold_executive_summary` | KPI (tall) | 17 | Marketplace headline KPIs for the executive page |
| `gold_intervention_queue` | intervention | 1,445 | Ranked, owner-assigned action list on one comparable AED unit |

## 9. Power BI dashboard overview

Six pages (specified in `docs/powerbi_dashboard_spec.md`), consuming the Gold export:

1. **Executive Command Center** — leakage size and recovery opportunity.
2. **Category Performance** — margin vs return economics across categories.
3. **Seller Performance** — trust, RTO toxicity, category-adjusted benchmarking.
4. **Listing Quality** — LQS vs catalog returns; bottom-LQS concentration.
5. **Returns & RTO** — reason mix, recovery by condition, COD-driven RTO.
6. **Intervention Queue** — the daily "what to fix first" worklist.

> The six-page dashboard is built and included in the repository as
> `powerbi/marketplace_dashboard.pbix`.

## 10. Technology stack

- **DuckDB** (embedded analytical SQL) — the Gold layer and its validation.
- **Python 3.13** — `pandas` (Silver cleaning), `duckdb` (build/validate/export),
  `pyyaml` (config).
- **YAML** — declarative schema, cleaning-rule and metric contracts.
- **Power BI** — semantic model + six-page dashboard, built and included as
  `powerbi/marketplace_dashboard.pbix` (spec in `docs/powerbi_dashboard_spec.md`).

## 11. Repository structure

```
.
├── CLAUDE.md                     # project charter, golden rules, workflow
├── README.md
├── config/                       # declarative contracts (no logic in code)
│   ├── bronze_schema.yaml
│   ├── cleaning_rules.yaml
│   └── metrics.yaml              # the semantic metric contract
├── data/
│   ├── 01_bronze/                # raw sample data (kept)
│   ├── 02_silver/                # cleaned sample data (kept)
│   └── 03_gold/                  # generated CSV + Parquet exports (gitignored)
├── src/
│   ├── cleaning/                 # Silver build + pure transforms
│   └── validation/               # Bronze/Silver audit framework
├── sql/gold/                     # 00_bootstrap + 01..07 Gold SQL (+ embedded validation)
├── scripts/                      # build_gold, validate_gold, export_gold
└── docs/                         # data dictionary, model, metric contract, specs, run reports
```

## 12. Build instructions

Prerequisites: Python 3.13 with `pandas`, `duckdb`, `pyyaml`. On Windows, invoke via
the `py` launcher (shown below); on macOS/Linux use `python3`.

```bash
# 1. Bronze audit — audits raw data; EXPECTED to fail closed (documents the dirt)
py src/validation/bronze_audit.py

# 2. Silver build — clean, dedupe, normalize, flag
py src/cleaning/silver_build.py

# 3. Silver validation — re-run the audit against the Silver layer (WARN, 0 blocking)
py src/validation/bronze_audit.py --data-dir data/02_silver --report-name validation_report_silver

# 4. Gold build — build gold.duckdb in dependency order + run embedded validations
py scripts/build_gold.py

# 5. Gold validation — independent re-validation of the built database
py scripts/validate_gold.py

# 6. Gold export — deterministic CSV + Parquet for Power BI
py scripts/export_gold.py

# 7. Power BI — Get Data → Folder → data/03_gold/parquet  (types preserved)
```

Build order:

```
Bronze Audit → Silver Build → Silver Validation → Gold Build → Gold Validation → Gold Export → Power BI
```

## 13. Reproducing the project

The pipeline is deterministic. From the raw `data/01_bronze/` inputs, steps 2–6 rebuild
the Silver layer, `gold.duckdb`, and the exports identically on every run (the export is
byte-stable — verified via hash). Step 1 is expected to exit non-zero: the Bronze audit
reports 4 primary-key violations by design, which is the finding that motivates the
Silver layer, not a build failure. Every downstream step exits 0.

## 14. Key business insights

- **AED 2.81M** return-cost leakage; **AED 3.19M** recoverable; **1,934** loss-making
  listings after returns.
- **Fashion** is ~50% of return cost and ~59% of the recovery opportunity (catalog
  return rate ~44.6% vs Beauty ~9.9%) — "Fashion has structurally higher returns" holds.
- **COD RTO ~14.5% vs ~1.6% prepaid** — the clearest COD-risk signal.
- RTO cost is only mildly concentrated (top-decile sellers ≈ **16.9%** of RTO cost), so
  interventions rank on **absolute** avoidable cost, not a toxicity flag.
- Aggregate salvage/recovery rate ≈ **68.8%**; write-offs set the recovery ceiling.

## 15. Interview talking points

- **Why Bronze / Silver / Gold?** Separation of concerns: raw fidelity, then cleaning,
  then business semantics. Each layer has one job, is independently testable, and is
  reproducible. It also makes data-quality decisions explicit and auditable.
- **Why is Return Cost created only in Gold?** It is a *derived* metric (reverse
  logistics + handling + merchandise loss net of salvage) that composes reference rate
  cards, category economics and recovery ratios. Placing it in Bronze/Silver would leak
  business logic into the raw/clean layers and let inconsistent definitions proliferate;
  it is defined once, in `gold_return_line_economics`.
- **Why is LQS derived (never raw)?** Listing Quality Score is a category-aware weighted
  composite of catalog signals — a *model output*, not an observed field. It is
  computed once (`gold_listing_metrics`), so no upstream table can smuggle in a
  conflicting version, and it stays tunable via `config/metrics.yaml`.
- **Why is RTO separated from Returns?** RTO is a *pre-delivery* failure
  (`order_status`), while a return is a *post-delivery* event. Conflating them
  double-counts loss and hides the COD signal. RTO lives only in the order fact; return
  metrics use delivered-only denominators (a hard Golden Rule).
- **Why was the synthetic data calibrated (not random)?** The generator injects
  realistic, category-aware behavior (COD raises RTO, Fashion returns more, electronics
  refurbish costlier, geography affects delivery) plus intentional dirt, so the pipeline
  exercises real cleaning and the metrics tell a business-true story rather than noise.
- **Why does the validation framework exist?** To make correctness a build gate, not a
  hope. Structural violations fail closed; intentional dirt is surfaced as WARN. Gold
  ships with 72 embedded checks that reconcile every mart to its source — the number a
  reviewer trusts.
- **Why is the intervention queue commercially valuable?** It converts diffuse analytics
  into a ranked, owner-assigned worklist on **one comparable AED unit**
  (`priority_opportunity_aed`), with an anti-double-count design (systemic sellers coached
  instead of per-listing fixes). It answers the only question operators ask: *what do we
  fix first this week?*

## 16. Future improvements

- Lift the last hardcoded knobs (LQS weights, intervention thresholds) into a
  `config/gold_model.yaml`.
- A seeded, in-repo Bronze generator so the raw layer is reproducible from code, not just
  provided.
- Learn the `addressable_fraction` recovery rate (ML on catalog fix → return reduction)
  to replace the current upper-bound assumption.
- Time-series/history (the current build is a point-in-time snapshot).
- CI that runs `build_gold.py` on every change and blocks merge on a failed validation.
- Python EDA notebooks and the executive decision memo.

## 17. License

MIT (see `LICENSE`).

## 18. Contact

**Abhijit Mishra** — abhijitmishra0103@gmail.com
_GitHub / LinkedIn: add links before publication._
