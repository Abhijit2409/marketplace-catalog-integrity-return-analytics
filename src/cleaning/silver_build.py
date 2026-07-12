"""Phase B - Silver Layer Builder.

Reads the Bronze layer (read-only), applies the cleaning contract declared
in ``config/cleaning_rules.yaml``, and writes a cleaned, self-contained
Silver layer to ``data/02_silver`` plus a cleaning report to ``docs/``.

Cleaning priorities implemented:
    1. Deduplicate primary-key violations
    2. Normalize category casing / spacing
    3. Extend the date dimension (dim_date)
    4. Standardized null-handling policy
    5. Flag invalid data ranges
    6. Temporal consistency flags

Verification is performed separately by re-running the Phase A audit against
the Silver layer (see the printed instructions / docs), reusing existing
validation machinery rather than duplicating it.

Usage:
    py src/cleaning/silver_build.py [--config PATH] [--root PATH]

Exit codes:
    0 - Silver built and internal PK guard passed
    1 - a dedup target still has duplicate primary keys (fail closed)
    2 - build could not run (missing config / files)
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

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from src.cleaning import transforms as T  # noqa: E402

LOG = logging.getLogger("silver_build")


def load_config(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def clean_table(name: str, tcfg: dict, df: pd.DataFrame, cfg: dict,
                cleaned: dict[str, pd.DataFrame], records: list) -> pd.DataFrame:
    """Apply the configured cleaning pipeline to one table, in order."""
    def step(result):
        frame, rec = result
        records.append(rec)
        LOG.info("[%s] %s -> %s", name, rec.action, rec.summary)
        return frame

    df = step(T.standardize_null_tokens(df, name))

    if tcfg.get("dedup_pk"):
        df = step(T.deduplicate(df, name, tcfg["dedup_pk"]))

    if tcfg.get("normalize_category"):
        df = step(T.normalize_category(
            df, name, tcfg["normalize_category"],
            cfg["categories"]["canonical"],
            cfg["categories"]["unmapped_value"]))

    for enum in tcfg.get("normalize_enums", []):
        df = step(T.normalize_enum(df, name, enum["column"], enum["canonical"]))

    if tcfg.get("null_policy"):
        df = step(T.apply_null_policy(df, name, tcfg["null_policy"]))

    if tcfg.get("ranges"):
        df = step(T.flag_invalid_ranges(df, name, tcfg["ranges"]))

    temporal = tcfg.get("temporal")
    if temporal == "orders":
        df = step(T.temporal_flags_orders(df, name, cfg["as_of_date_key"]))
    elif temporal == "returns":
        orders = cleaned["fact_orders"]
        actual = orders.set_index("order_line_id")["actual_delivery_date_key"]
        df = step(T.temporal_flags_returns(
            df, name, cfg["as_of_date_key"], actual))

    return df


def guard_primary_keys(cfg: dict, cleaned: dict[str, pd.DataFrame]) -> list[str]:
    """Fail-closed guard: dedup targets must have unique PKs post-clean."""
    failures = []
    for name, tcfg in cfg["tables"].items():
        pk = tcfg.get("dedup_pk")
        if pk:
            dups = int(cleaned[name].duplicated(pk, keep=False).sum())
            if dups:
                failures.append(f"{name} still has {dups} duplicate PK row(s)")
    return failures


def build_report(cfg: dict, bronze: dict, silver: dict,
                 records: list, guard_failures: list[str]) -> dict:
    return {
        "phase": "phase_b_silver_cleaning",
        "generated_at": dt.datetime.now().isoformat(timespec="seconds"),
        "as_of_date_key": cfg["as_of_date_key"],
        "silver_dir": cfg["silver_dir"],
        "status": "FAIL" if guard_failures else "OK",
        "guard_failures": guard_failures,
        "row_counts": {
            n: {"bronze": int(len(bronze[n])), "silver": int(len(silver[n]))}
            for n in silver
        },
        "actions": [r.to_dict() for r in records],
    }


def render_markdown(report: dict) -> str:
    lines: list[str] = []
    a = lines.append
    a("# Phase B - Silver Layer Cleaning Report")
    a("")
    a(f"**Status:** `{report['status']}`  ")
    a(f"**Generated:** {report['generated_at']}  ")
    a(f"**Silver directory:** `{report['silver_dir']}`  ")
    a(f"**Temporal as-of:** `{report['as_of_date_key']}` (events after this "
      "are flagged as future-dated anomalies)")
    a("")
    a("## Row counts (Bronze -> Silver)")
    a("")
    a("| Table | Bronze | Silver | Delta |")
    a("|---|---:|---:|---:|")
    for n, c in report["row_counts"].items():
        delta = c["silver"] - c["bronze"]
        a(f"| `{n}` | {c['bronze']:,} | {c['silver']:,} | {delta:+,} |")
    a("")
    a("## Cleaning actions")
    a("")
    a("| Table | Action | Result |")
    a("|---|---|---|")
    for r in report["actions"]:
        a(f"| `{r['table']}` | {r['action']} | {r['summary']} |")
    a("")
    if report["guard_failures"]:
        a("## Fail-closed guard")
        a("")
        for f in report["guard_failures"]:
            a(f"- {f}")
        a("")
    a("## Cleaning assumptions")
    a("")
    a("- **Deduplication** keeps the most-complete row per PK (all Bronze PK "
      "duplicates were fully-identical, so this is a lossless drop).")
    a("- **Never fabricated**: `price`, `item_weight_kg` (feed downstream "
      "ratios) and `reported_reason_code` (FK) are kept null + `dq_missing_*` "
      "flag. `actual_delivery_date_key` is null by design when undelivered.")
    a("- **Documented imputations** (each carries a `dq_imputed_*` flag): "
      "`shipping_fee_charged`->0 (free shipping), `add_to_carts`->0, "
      "`description_length_chars`->0, `specifications_filled_pct`->0, "
      "boolean feature flags->False. These are conservative cleaning "
      "assumptions, not asserted facts.")
    a("- **Invalid ranges**: `discount_pct`>1 and `image_count`<0 are "
      "quarantined to null (attributes); `quantity`<1 is flagged but kept "
      "(core fact measure - Gold decides). All carry `dq_out_of_range_*`.")
    a("- **Enum normalization** (Phase B addendum) canonicalizes case / "
      "whitespace / space-vs-underscore variants for "
      "`item_condition_on_receipt`, `payment_method`, `fulfillment_type` and "
      "`seller_country`; each carries a `dq_<col>_normalized` flag. This "
      "closes the Silver enum gap that Recovery Rate / Return Cost depend on.")
    a("- **Date extension** derives weekday/ISO-week/month/quarter/year and "
      "Sat-Sun weekends; event flags default False (no major religious / "
      "promo / public-holiday events in 2026-07-01..08-15).")
    a("- **Temporal as-of = session today**; delivered/return events dated "
      "after it are flagged (`dq_delivery_after_asof`, `dq_return_after_asof`) "
      "- this implements the Phase A future-delivery to-do without deleting "
      "data.")
    a("")
    a("## Verification")
    a("")
    a("Re-run the Phase A audit against the Silver layer:")
    a("")
    a("```")
    a("py src/validation/bronze_audit.py --data-dir data/02_silver "
      "--report-name validation_report_silver")
    a("```")
    a("")
    a("Expected deltas vs Bronze: 4 primary-key FAILs -> 0; date-coverage "
      "WARNs -> 0; category normalization WARN -> 0. Intentionally-remaining "
      "WARNs: kept nulls (`price`, `item_weight_kg`, `actual_delivery_date_key`"
      ", `reported_reason_code`), the quarantined-to-null range values, and "
      "`quantity` out-of-range (flagged, kept by design).")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)-7s %(name)s | %(message)s",
        datefmt="%H:%M:%S")
    root_default = Path(__file__).resolve().parents[2]
    p = argparse.ArgumentParser(description="Phase B Silver Layer Builder")
    p.add_argument("--root", type=Path, default=root_default)
    p.add_argument("--config", type=Path,
                   default=root_default / "config" / "cleaning_rules.yaml")
    args = p.parse_args(argv)

    try:
        cfg = load_config(args.config)
        bronze_dir = args.root / cfg["bronze_dir"]
        silver_dir = args.root / cfg["silver_dir"]
        silver_dir.mkdir(parents=True, exist_ok=True)
    except (FileNotFoundError, yaml.YAMLError) as exc:
        LOG.error("build could not run: %s", exc)
        return 2

    records: list = []
    bronze: dict[str, pd.DataFrame] = {}
    silver: dict[str, pd.DataFrame] = {}

    # 1) Calendar dimension (extension).
    cal = cfg["calendar"]
    dim_date = pd.read_csv(bronze_dir / f"{cal['table']}.csv")
    bronze[cal["table"]] = dim_date.copy()
    dim_date, rec = T.extend_dim_date(
        dim_date, cal["table"], cal["extend_through"],
        cal["weekend_days"], cal["event_flag_defaults"])
    records.append(rec)
    LOG.info("[%s] %s -> %s", cal["table"], rec.action, rec.summary)
    silver[cal["table"]] = dim_date

    # 2) Per-table cleaning (fact_orders before fact_returns for the join).
    for name, tcfg in cfg["tables"].items():
        df = pd.read_csv(bronze_dir / tcfg["file"])
        bronze[name] = df.copy()
        silver[name] = clean_table(name, tcfg, df, cfg, silver, records)

    # 3) Pass-through tables (verbatim copy into the Silver layer).
    for pt in cfg.get("passthrough", []):
        stem = Path(pt["file"]).stem
        df = pd.read_csv(bronze_dir / pt["file"])
        bronze[stem] = df.copy()
        silver[stem] = df
        LOG.info("[%s] passthrough -> copied %d row(s) verbatim", stem, len(df))

    # 4) Fail-closed PK guard.
    guard_failures = guard_primary_keys(cfg, silver)
    for f in guard_failures:
        LOG.error(f)

    # 5) Write Silver CSVs.
    for name, df in silver.items():
        fp = silver_dir / (
            cfg["tables"].get(name, {}).get("file")
            or (f"{name}.csv"))
        df.to_csv(fp, index=False)
    LOG.info("wrote %d Silver table(s) to %s", len(silver), silver_dir)

    # 6) Reports.
    report = build_report(cfg, bronze, silver, records, guard_failures)
    out_json = args.root / "docs" / "cleaning_report.json"
    out_md = args.root / "docs" / "cleaning_report.md"
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(report, indent=2), encoding="utf-8")
    out_md.write_text(render_markdown(report), encoding="utf-8")
    LOG.info("wrote %s", out_json)
    LOG.info("wrote %s", out_md)
    LOG.info("SILVER %s | tables=%d actions=%d", report["status"],
             len(silver), len(records))

    return 1 if guard_failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
