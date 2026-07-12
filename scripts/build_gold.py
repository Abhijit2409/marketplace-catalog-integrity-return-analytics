"""One-command Gold build orchestrator.

Rebuilds gold.duckdb from scratch by executing the Gold SQL files in strict
dependency order, then runs every embedded validation. Fails closed on the
first build error, a row-count regression, or any failed validation, and
writes a single build report to docs/gold_build_report.md.

Usage:
    py scripts/build_gold.py
    py scripts/build_gold.py --db PATH

Exit codes: 0 = build + validation OK ; 1 = build or validation failed.
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import time
from pathlib import Path

import duckdb

# Reuse the shared library (splitter, file order, validation runner).
from validate_gold import (
    ROOT, GOLD_DIR, DB_PATH, BUILD_ORDER,
    split_build_validation, run_validations, summarize,
)

# Each build file -> the table it materializes (bootstrap creates none).
TABLE_OF: dict[str, str | None] = {
    "00_bootstrap.sql": None,
    "01_gold_order_line_economics.sql": "gold_order_line_economics",
    "02_gold_return_line_economics.sql": "gold_return_line_economics",
    "03_gold_listing_metrics.sql": "gold_listing_metrics",
    "04_gold_seller_metrics.sql": "gold_seller_metrics",
    "05_gold_category_metrics.sql": "gold_category_metrics",
    "06_gold_executive_summary.sql": "gold_executive_summary",
    "07_gold_intervention_queue.sql": "gold_intervention_queue",
}

# Deterministic row counts (fixed given the frozen Silver layer). The queue is
# threshold-dependent, so it is reported but not hard-asserted.
EXPECTED_ROWS: dict[str, int] = {
    "gold_order_line_economics": 85000,
    "gold_return_line_economics": 32005,
    "gold_listing_metrics": 10000,
    "gold_seller_metrics": 450,
    "gold_category_metrics": 5,
    "gold_executive_summary": 17,
}

REPORT_PATH = ROOT / "docs" / "gold_build_report.md"


def build(con: duckdb.DuckDBPyConnection) -> tuple[list[dict], bool, str | None]:
    """Execute every build file in order. Returns (per-file reports, ok, reason)."""
    reports: list[dict] = []
    for fname in BUILD_ORDER:
        path = GOLD_DIR / fname
        if not path.exists():                       # no skipped scripts
            return reports, False, f"missing script: {fname}"

        build_stmts, _ = split_build_validation(path.read_text(encoding="utf-8"))
        t0 = time.perf_counter()
        try:
            for stmt in build_stmts:
                con.execute(stmt)
        except Exception as exc:                    # fail closed on first error
            reports.append({"file": fname, "table": TABLE_OF.get(fname),
                            "rows": None, "seconds": time.perf_counter() - t0,
                            "status": "FAIL"})
            return reports, False, f"{fname}: {exc}"
        seconds = time.perf_counter() - t0

        table = TABLE_OF.get(fname)
        rows = None
        if table:
            try:
                rows = con.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
            except Exception as exc:                # table existence check
                reports.append({"file": fname, "table": table, "rows": None,
                                "seconds": seconds, "status": "FAIL"})
                return reports, False, f"{table} not created: {exc}"
            expected = EXPECTED_ROWS.get(table)
            if expected is not None and rows != expected:
                reports.append({"file": fname, "table": table, "rows": rows,
                                "seconds": seconds, "status": "FAIL"})
                return reports, False, (f"{table} row count {rows:,} != expected "
                                        f"{expected:,} (regression)")
        reports.append({"file": fname, "table": table, "rows": rows,
                        "seconds": seconds, "status": "OK"})
    return reports, True, None


def write_report(reports: list[dict], vresults: list[dict], *, build_ok: bool,
                 fail_reason: str | None, total_seconds: float,
                 started_at: dt.datetime, overall: bool) -> None:
    vtotal, vpassed, vfailed = summarize(vresults)
    # per-file validation tallies
    per_file: dict[str, list[int]] = {}
    for r in vresults:
        t = per_file.setdefault(r["file"], [0, 0])
        t[0] += 1
        t[1] += 1 if r["pass"] else 0

    lines: list[str] = []
    a = lines.append
    a("# Gold Build Report")
    a("")
    a(f"**Overall:** `{'PASS' if overall else 'FAIL'}`  ")
    a(f"**Build timestamp:** {started_at.isoformat(timespec='seconds')}  ")
    a(f"**Total duration:** {total_seconds:.2f}s  ")
    a(f"**Scripts executed:** {len(reports)} / {len(BUILD_ORDER)}  ")
    a(f"**Validations:** {vpassed}/{vtotal} passed, {vfailed} failed")
    if not build_ok:
        a("")
        a(f"**Build failure:** {fail_reason}")
    a("")
    a("## Execution order, row counts & duration")
    a("")
    a("| # | Script | Table | Rows | Duration (s) | Status |")
    a("|---|---|---|---:|---:|---|")
    for i, r in enumerate(reports):
        rows = "-" if r["rows"] is None else f"{r['rows']:,}"
        a(f"| {i} | `{r['file']}` | {r['table'] or '—'} | {rows} "
          f"| {r['seconds']:.3f} | {r['status']} |")
    a("")
    a("## Validation summary by script")
    a("")
    a("| Script | Passed | Total |")
    a("|---|---:|---:|")
    for fname in BUILD_ORDER:
        if fname in per_file:
            passed, total = per_file[fname][1], per_file[fname][0]
            a(f"| `{fname}` | {passed} | {total} |")
    a("")
    if vfailed:
        a("## Failed validations")
        a("")
        a("| Script | Check | Expected | Actual |")
        a("|---|---|---|---|")
        for r in vresults:
            if not r["pass"]:
                a(f"| `{r['file']}` | {r['check']} | {r['expected']} | {r['actual']} |")
        a("")
    a("## Build system checks")
    a("")
    a(f"- Dependency order enforced: `{' -> '.join(f.split('_')[0] for f in BUILD_ORDER)} -> validation`")
    a(f"- No skipped scripts: {'yes' if len(reports) == len(BUILD_ORDER) and build_ok else 'no'}")
    a("- Table existence: verified via row-count query per script")
    a("- Row-count regression guard: deterministic tables checked against "
      "expected counts")
    a(f"- Fail-closed: exit code {'0' if overall else '1'}")
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text("\n".join(lines), encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Build the Gold layer (one command)")
    p.add_argument("--db", type=Path, default=DB_PATH)
    args = p.parse_args(argv)

    os.chdir(ROOT)  # so read_csv_auto relative paths resolve
    started_at = dt.datetime.now()
    overall_t0 = time.perf_counter()

    if args.db.exists():
        args.db.unlink()                    # clean rebuild
    con = duckdb.connect(str(args.db))

    print(f"Building Gold layer -> {args.db.name}")
    reports, build_ok, fail_reason = build(con)
    for r in reports:
        rows = "" if r["rows"] is None else f"rows={r['rows']:,}"
        print(f"  [{r['status']:>4}] {r['file']:<34} {r['seconds']:.3f}s {rows}")
    if not build_ok:
        print(f"  BUILD FAILED: {fail_reason}")

    vresults: list[dict] = []
    if build_ok:
        print("Running validations...")
        vresults = run_validations(con)
        for r in vresults:
            if not r["pass"]:
                print(f"  [FAIL] {r['file']} :: {r['check']} "
                      f"(expected {r['expected']}, got {r['actual']})")
    con.close()

    total_seconds = time.perf_counter() - overall_t0
    vtotal, vpassed, vfailed = summarize(vresults)
    overall = build_ok and vfailed == 0

    write_report(reports, vresults, build_ok=build_ok, fail_reason=fail_reason,
                 total_seconds=total_seconds, started_at=started_at, overall=overall)

    print("-" * 60)
    print(f"BUILD {'PASS' if overall else 'FAIL'} | scripts {len(reports)}/{len(BUILD_ORDER)} "
          f"| validations {vpassed}/{vtotal} | {total_seconds:.2f}s")
    print(f"Report: {REPORT_PATH.relative_to(ROOT)}")
    return 0 if overall else 1


if __name__ == "__main__":
    raise SystemExit(main())
