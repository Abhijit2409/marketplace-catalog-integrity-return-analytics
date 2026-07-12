# Gold Build Report

**Overall:** `PASS`  
**Build timestamp:** 2026-07-08T16:28:19  
**Total duration:** 2.65s  
**Scripts executed:** 8 / 8  
**Validations:** 72/72 passed, 0 failed

## Execution order, row counts & duration

| # | Script | Table | Rows | Duration (s) | Status |
|---|---|---|---:|---:|---|
| 0 | `00_bootstrap.sql` | — | - | 0.294 | OK |
| 1 | `01_gold_order_line_economics.sql` | gold_order_line_economics | 85,000 | 0.690 | OK |
| 2 | `02_gold_return_line_economics.sql` | gold_return_line_economics | 32,005 | 0.213 | OK |
| 3 | `03_gold_listing_metrics.sql` | gold_listing_metrics | 10,000 | 0.855 | OK |
| 4 | `04_gold_seller_metrics.sql` | gold_seller_metrics | 450 | 0.116 | OK |
| 5 | `05_gold_category_metrics.sql` | gold_category_metrics | 5 | 0.024 | OK |
| 6 | `06_gold_executive_summary.sql` | gold_executive_summary | 17 | 0.014 | OK |
| 7 | `07_gold_intervention_queue.sql` | gold_intervention_queue | 1,445 | 0.035 | OK |

## Validation summary by script

| Script | Passed | Total |
|---|---:|---:|
| `01_gold_order_line_economics.sql` | 8 | 8 |
| `02_gold_return_line_economics.sql` | 9 | 9 |
| `03_gold_listing_metrics.sql` | 9 | 9 |
| `04_gold_seller_metrics.sql` | 9 | 9 |
| `05_gold_category_metrics.sql` | 12 | 12 |
| `06_gold_executive_summary.sql` | 13 | 13 |
| `07_gold_intervention_queue.sql` | 12 | 12 |

## Build system checks

- Dependency order enforced: `00 -> 01 -> 02 -> 03 -> 04 -> 05 -> 06 -> 07 -> validation`
- No skipped scripts: yes
- Table existence: verified via row-count query per script
- Row-count regression guard: deterministic tables checked against expected counts
- Fail-closed: exit code 0