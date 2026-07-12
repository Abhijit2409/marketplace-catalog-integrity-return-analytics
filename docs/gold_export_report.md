# Gold Export Report

**Overall:** `PASS`  
**Export timestamp:** 2026-07-08T16:34:13  
**Total duration:** 1.59s  
**Tables exported:** 7  
**Formats:** CSV (`data/03_gold/csv/`) + Parquet (`data/03_gold/parquet/`)

## Tables

| Table | Rows | Cols | CSV size | Parquet size | Duration (s) | Status |
|---|---:|---:|---:|---:|---:|---|
| `gold_order_line_economics` | 85,000 | 31 | 16.4 MB | 3.0 MB | 0.356 | OK |
| `gold_return_line_economics` | 32,005 | 22 | 4.9 MB | 1.6 MB | 0.136 | OK |
| `gold_listing_metrics` | 10,000 | 28 | 1.6 MB | 698.7 KB | 0.090 | OK |
| `gold_seller_metrics` | 450 | 39 | 136.3 KB | 78.5 KB | 0.014 | OK |
| `gold_category_metrics` | 5 | 33 | 2.1 KB | 5.6 KB | 0.010 | OK |
| `gold_executive_summary` | 17 | 7 | 1.5 KB | 2.0 KB | 0.006 | OK |
| `gold_intervention_queue` | 1,445 | 24 | 475.7 KB | 134.1 KB | 0.015 | OK |

## Validation summary

Each table verified: exists in DuckDB · CSV row count == DuckDB · Parquet row count == DuckDB · CSV & Parquet columns match names/order (no missing columns).

| Table | DuckDB rows | CSV rows | Parquet rows | Cols match | Result |
|---|---:|---:|---:|:---:|---|
| `gold_order_line_economics` | 85,000 | 85,000 | 85,000 | yes | PASS |
| `gold_return_line_economics` | 32,005 | 32,005 | 32,005 | yes | PASS |
| `gold_listing_metrics` | 10,000 | 10,000 | 10,000 | yes | PASS |
| `gold_seller_metrics` | 450 | 450 | 450 | yes | PASS |
| `gold_category_metrics` | 5 | 5 | 5 | yes | PASS |
| `gold_executive_summary` | 17 | 17 | 17 | yes | PASS |
| `gold_intervention_queue` | 1,445 | 1,445 | 1,445 | yes | PASS |

## Notes

- **Determinism:** every table exported with an explicit `ORDER BY` on its key, so re-runs are byte-stable.
- **Datatypes:** Parquet preserves DuckDB column types; CSV is type-inferred on read (Power BI applies its own types) — prefer the Parquet folder in Power BI when available.
- Read-only with respect to `gold.duckdb`; no SQL, validation, metrics or business logic was modified.