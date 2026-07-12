"""Phase A - Bronze Data Audit.

Runs the full integrity contract declared in ``config/bronze_schema.yaml``
against every CSV in the Bronze layer and writes a machine-readable JSON
report plus a human-readable Markdown summary.

Checks performed (CLAUDE.md "Validation Rules"):
    row counts, null analysis, duplicate analysis, primary-key validation,
    foreign-key / referential integrity, business-rule validation
    (Golden Rules 1 & 2), and distribution/range checks.

Severity model:
    Structural violations (PK, FK orphans, leakage, Golden-Rule breaches)
    FAIL the audit closed (non-zero exit). Intentional Bronze dirt (nulls,
    duplicate rows, out-of-range values) is reported as WARN - Bronze is
    deliberately imperfect and is cleaned in the Silver layer.

Usage:
    py src/validation/bronze_audit.py [--config PATH] [--root PATH]

Exit codes:
    0 - no blocking (error-severity FAIL) findings
    1 - one or more blocking findings (fail closed)
    2 - audit could not run (missing config / files)
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import logging
import sys
from pathlib import Path

import pandas as pd
import yaml

# Allow "py src/validation/bronze_audit.py" and "-m" invocation alike.
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from src.validation import checks as C  # noqa: E402

LOG = logging.getLogger("bronze_audit")


# --------------------------------------------------------------------------
def load_config(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def load_tables(root: Path, cfg: dict) -> dict[str, pd.DataFrame]:
    """Load every configured Bronze CSV. Missing files abort the audit."""
    bronze = root / cfg["bronze_dir"]
    frames: dict[str, pd.DataFrame] = {}
    for name, tcfg in cfg["tables"].items():
        fp = bronze / tcfg["file"]
        if not fp.exists():
            raise FileNotFoundError(f"Bronze file not found: {fp}")
        frames[name] = pd.read_csv(fp)
        LOG.info("loaded %-22s rows=%-8d cols=%d",
                 name, len(frames[name]), frames[name].shape[1])
    return frames


def as_list(pk) -> list[str]:
    return pk if isinstance(pk, list) else [pk]


# --------------------------------------------------------------------------
def run_table_checks(name: str, tcfg: dict, df: pd.DataFrame,
                     frames: dict[str, pd.DataFrame], cfg: dict
                     ) -> list[C.CheckResult]:
    """Execute every configured check for one table."""
    results: list[C.CheckResult] = []

    # Golden Rule 1 - leakage (applies to every table).
    results.append(C.check_leakage(df, name, cfg["forbidden_columns"]))

    # Primary key (uniqueness + non-null) - fail closed.
    results.append(C.check_primary_key(df, name, as_list(tcfg["primary_key"])))

    # Structural duplicates & null profile.
    results.append(C.check_duplicate_rows(df, name))
    results.append(C.check_nulls(df, name))

    # Foreign keys / referential integrity.
    calendar = cfg.get("calendar_dimension")
    for fk in tcfg.get("foreign_keys", []):
        parent = frames[fk["ref_table"]]
        ref = f"{fk['ref_table']}.{fk['ref_column']}"
        results.append(
            C.check_foreign_key(df, name, fk["column"],
                                parent[fk["ref_column"]], ref,
                                coverage_aware=(fk["ref_table"] == calendar)))

    # Membership (closed vocabularies / category domain).
    for m in tcfg.get("membership", []):
        col = m["column"]
        if "values_ref" in m:
            allowed = set(cfg[m["values_ref"]])
            label = m["values_ref"]
        else:
            allowed = set(frames[m["ref_table"]][m["ref_column"]].dropna())
            label = f"{m['ref_table']}.{m['ref_column']}"
        results.append(C.check_membership(df, name, col, allowed, label))

    # Distribution / range checks.
    if tcfg.get("ranges"):
        results.append(C.check_ranges(df, name, tcfg["ranges"]))

    # Funnel monotonicity.
    if tcfg.get("funnel"):
        results.append(C.check_funnel(df, name, tcfg["funnel"]))

    # Golden Rule 2 - returns reconcile to delivered orders.
    if tcfg.get("delivered_only"):
        d = tcfg["delivered_only"]
        results.append(
            C.check_delivered_only(df, frames[d["orders_table"]], name, d))

    return results


# --------------------------------------------------------------------------
def build_report(cfg: dict, frames: dict[str, pd.DataFrame],
                 results: list[C.CheckResult]) -> dict:
    blocking = [r for r in results if r.is_blocking]
    warns = [r for r in results if r.status == C.WARN]
    overall = "FAIL" if blocking else ("WARN" if warns else "PASS")

    return {
        "audit": "phase_a_bronze_data_audit",
        "generated_at": dt.datetime.now().isoformat(timespec="seconds"),
        "bronze_dir": cfg["bronze_dir"],
        "overall_status": overall,
        "totals": {
            "tables": len(frames),
            "total_rows": int(sum(len(f) for f in frames.values())),
            "checks_run": len(results),
            "passed": sum(r.status == C.PASS for r in results),
            "warnings": len(warns),
            "blocking_failures": len(blocking),
        },
        "row_counts": {n: int(len(f)) for n, f in frames.items()},
        "blocking_failures": [r.to_dict() for r in blocking],
        "results": [r.to_dict() for r in results],
    }


def render_markdown(report: dict) -> str:
    t = report["totals"]
    icon = {"PASS": "PASS", "WARN": "WARN", "FAIL": "FAIL"}
    badge = {"PASS": "OK", "WARN": "!", "FAIL": "X"}
    lines: list[str] = []
    a = lines.append

    a("# Phase A - Bronze Data Audit")
    a("")
    a(f"**Overall status:** `{report['overall_status']}`  ")
    a(f"**Generated:** {report['generated_at']}  ")
    a(f"**Bronze directory:** `{report['bronze_dir']}`")
    a("")
    a("## How to read this report")
    a("")
    a("Bronze is intentionally imperfect (CLAUDE.md - Synthetic Data Rules). "
      "This audit **documents** dirt for the Silver layer; it does not clean it.")
    a("")
    a("| Severity | Meaning | Effect |")
    a("|---|---|---|")
    a("| **FAIL** (error) | Structural violation: duplicate/null primary key, "
      "referential-integrity orphan, data leakage, or a broken Golden Rule | "
      "Audit fails **closed** (exit 1) |")
    a("| **WARN** | Intentional dirt: nulls, duplicate rows, out-of-range "
      "values | Reported for Silver cleaning; non-blocking |")
    a("")
    a("## Summary")
    a("")
    a(f"- Tables audited: **{t['tables']}**")
    a(f"- Total rows: **{t['total_rows']:,}**")
    a(f"- Checks run: **{t['checks_run']}** "
      f"(passed {t['passed']}, warnings {t['warnings']}, "
      f"blocking failures {t['blocking_failures']})")
    a("")

    if report["blocking_failures"]:
        a("## Blocking failures (fail closed)")
        a("")
        a("| Table | Check | Finding |")
        a("|---|---|---|")
        for r in report["blocking_failures"]:
            a(f"| `{r['table']}` | {r['check']} | {r['summary']} |")
        a("")

    warns = [r for r in report["results"] if r["status"] == "WARN"]
    if warns:
        a("## Data-quality findings for the Silver layer (WARN, non-blocking)")
        a("")
        a("Intentional Bronze dirt. Non-blocking, but material - each is a "
          "row-loss or mis-join risk if not handled downstream.")
        a("")
        a("| Table | Check | Finding |")
        a("|---|---|---|")
        for r in warns:
            a(f"| `{r['table']}` | {r['check']} | {r['summary']} |")
        a("")
        a("**Recommended Silver actions**")
        a("")
        a("- **Deduplicate** `dim_seller`, `dim_listing`, `fact_listing_traffic` "
          "and `fact_returns` on their primary keys (the blocking failures "
          "above surface as duplicate rows here too).")
        a("- **Extend `dim_date`** to cover the full fact date range (delivery / "
          "return keys run past the current calendar end of 2026-06-30); "
          "otherwise ~2,600 fact rows drop on the date join.")
        a("- **Normalize `category`** case and whitespace in `dim_listing` to the "
          "5 canonical values before joining `ref_category_economics`.")
        a("- **Impute / flag nulls** per the null-analysis rows (e.g. "
          "`dim_listing` attributes, `fact_orders.shipping_fee_charged`).")
        a("")

    a("## Row counts")
    a("")
    a("| Table | Rows |")
    a("|---|---:|")
    for n, c in report["row_counts"].items():
        a(f"| `{n}` | {c:,} |")
    a("")

    a("## All checks")
    a("")
    a("| Table | Check | Status | Sev | Finding |")
    a("|---|---|---|---|---|")
    for r in report["results"]:
        a(f"| `{r['table']}` | {r['check']} | {badge.get(r['status'], r['status'])} "
          f"{r['status']} | {r['severity']} | {r['summary']} |")
    a("")

    a("## Assumptions")
    a("")
    a("- **\"Row-count matching\"** is interpreted as per-table row counts "
      "(above) plus cross-table reconciliation of `fact_returns` -> "
      "`fact_orders` (the `returns_delivered_reconciliation` check).")
    a("- Foreign-key nulls are treated as missing data (counted in null "
      "analysis), **not** as broken references; only non-null unmatched keys "
      "are orphans.")
    a("- `fact_orders.actual_delivery_date_key` is nullable by design "
      "(null when an order was never delivered).")
    a("- Nulls, duplicate rows and out-of-range values are expected Bronze "
      "dirt and are surfaced as WARN, to be resolved in the Silver layer.")
    a("")
    a("## Downstream to-do (out of Phase A scope)")
    a("")
    a("- Some `fact_orders.actual_delivery_date_key` values on `delivered` "
      "orders fall after the dataset as-of date (2026-06-30), i.e. delivered "
      "in the future. That is a *logical* (business-rule) violation, not a "
      "referential one, and belongs to a Silver-layer temporal-consistency "
      "check - not this referential audit.")
    return "\n".join(lines)


# --------------------------------------------------------------------------
def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)-7s %(name)s | %(message)s",
        datefmt="%H:%M:%S",
    )
    root_default = Path(__file__).resolve().parents[2]
    p = argparse.ArgumentParser(description="Phase A Bronze Data Audit")
    p.add_argument("--root", type=Path, default=root_default,
                   help="Repository root (default: inferred)")
    p.add_argument("--config", type=Path,
                   default=root_default / "config" / "bronze_schema.yaml")
    p.add_argument("--data-dir", type=str, default=None,
                   help="Override the audited layer directory (e.g. "
                        "data/02_silver to verify the Silver layer)")
    p.add_argument("--report-name", type=str, default="validation_report",
                   help="Base name for docs/<name>.{md,json}")
    args = p.parse_args(argv)

    try:
        cfg = load_config(args.config)
        if args.data_dir:
            cfg["bronze_dir"] = args.data_dir
        frames = load_tables(args.root, cfg)
    except (FileNotFoundError, yaml.YAMLError) as exc:
        LOG.error("audit could not run: %s", exc)
        return 2

    results: list[C.CheckResult] = []
    for name, tcfg in cfg["tables"].items():
        for r in run_table_checks(name, tcfg, frames[name], frames, cfg):
            level = logging.ERROR if r.is_blocking else (
                logging.WARNING if r.status == C.WARN else logging.INFO)
            LOG.log(level, "[%s] %s -> %s", name, r.check, r.summary)
            results.append(r)

    report = build_report(cfg, frames, results)

    out_json = args.root / "docs" / f"{args.report_name}.json"
    out_md = args.root / "docs" / f"{args.report_name}.md"
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(report, indent=2), encoding="utf-8")
    out_md.write_text(render_markdown(report), encoding="utf-8")
    LOG.info("wrote %s", out_json)
    LOG.info("wrote %s", out_md)

    t = report["totals"]
    LOG.info("AUDIT %s | tables=%d rows=%d checks=%d warn=%d blocking=%d",
             report["overall_status"], t["tables"], t["total_rows"],
             t["checks_run"], t["warnings"], t["blocking_failures"])

    # Fail closed on any blocking (structural) violation.
    return 1 if report["blocking_failures"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
