"""Automated validation for the Gold layer.

Executes every embedded validation query in sql/gold/01_..07_ against an
existing gold.duckdb, aggregates PASS/FAIL, and fails closed (non-zero exit)
on any failure. Also serves as the shared library for build_gold.py (SQL
splitting + validation runner), so it must not import build_gold.

Usage:
    py scripts/validate_gold.py              # validate the existing gold.duckdb
    py scripts/validate_gold.py --db PATH
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parents[1]
GOLD_DIR = ROOT / "sql" / "gold"
DB_PATH = ROOT / "gold.duckdb"

# Dependency-ordered build files (bootstrap first). Single source of truth for
# both build and validation ordering.
BUILD_ORDER = [
    "00_bootstrap.sql",
    "01_gold_order_line_economics.sql",
    "02_gold_return_line_economics.sql",
    "03_gold_listing_metrics.sql",
    "04_gold_seller_metrics.sql",
    "05_gold_category_metrics.sql",
    "06_gold_executive_summary.sql",
    "07_gold_intervention_queue.sql",
]

VALIDATION_MARKER = "-- VALIDATION QUERIES"


# --------------------------------------------------------------------------
def split_sql(sql: str) -> list[str]:
    """Split SQL into statements on ';', respecting single-quoted strings and
    line (--) / block (/* */) comments (a naive split breaks on a semicolon
    inside a string literal)."""
    stmts: list[str] = []
    buf: list[str] = []
    i, n = 0, len(sql)
    in_str = in_line = in_block = False
    while i < n:
        c = sql[i]
        nxt = sql[i + 1] if i + 1 < n else ""
        if in_line:
            buf.append(c)
            if c == "\n":
                in_line = False
            i += 1
        elif in_block:
            buf.append(c)
            if c == "*" and nxt == "/":
                buf.append(nxt)
                i += 2
                in_block = False
            else:
                i += 1
        elif in_str:
            buf.append(c)
            if c == "'":
                if nxt == "'":            # escaped quote inside string
                    buf.append(nxt)
                    i += 2
                    continue
                in_str = False
            i += 1
        elif c == "-" and nxt == "-":
            in_line = True
            buf.append(c)
            i += 1
        elif c == "/" and nxt == "*":
            in_block = True
            buf.append(c)
            i += 1
        elif c == "'":
            in_str = True
            buf.append(c)
            i += 1
        elif c == ";":
            stmt = "".join(buf).strip()
            if stmt:
                stmts.append(stmt)
            buf = []
            i += 1
        else:
            buf.append(c)
            i += 1
    tail = "".join(buf).strip()
    if tail:
        stmts.append(tail)
    return stmts


def split_build_validation(text: str) -> tuple[list[str], list[str]]:
    """Split a Gold SQL file into (build statements, validation statements)
    at the VALIDATION QUERIES marker. Files without the marker (bootstrap)
    return all-build, no-validation."""
    idx = text.find(VALIDATION_MARKER)
    if idx == -1:
        return split_sql(text), []
    return split_sql(text[:idx]), split_sql(text[idx:])


def run_validations(con: duckdb.DuckDBPyConnection,
                    files: list[str] = BUILD_ORDER) -> list[dict]:
    """Execute every validation query and return one result dict per check."""
    results: list[dict] = []
    for fname in files:
        _, vstmts = split_build_validation((GOLD_DIR / fname).read_text(encoding="utf-8"))
        for stmt in vstmts:
            try:
                rows = con.execute(stmt).fetchall()
                cols = [d[0] for d in con.description]
            except Exception as exc:  # a broken validation is a FAIL, not a crash
                results.append({"file": fname, "check": "<query error>",
                                "pass": False, "expected": "", "actual": str(exc)[:80]})
                continue
            if not rows:
                results.append({"file": fname, "check": "<no rows returned>",
                                "pass": False, "expected": "", "actual": ""})
                continue
            for r in rows:
                rec = dict(zip(cols, r))
                results.append({
                    "file": fname,
                    "check": rec.get("check", "<unnamed>"),
                    "pass": bool(rec.get("pass")),
                    "expected": rec.get("expected"),
                    "actual": rec.get("actual"),
                })
    return results


def summarize(results: list[dict]) -> tuple[int, int, int]:
    total = len(results)
    passed = sum(1 for r in results if r["pass"])
    return total, passed, total - passed


# --------------------------------------------------------------------------
def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Validate the Gold layer")
    p.add_argument("--db", type=Path, default=DB_PATH)
    args = p.parse_args(argv)

    os.chdir(ROOT)  # validation queries read Silver CSVs via relative paths
    if not args.db.exists():
        print(f"ERROR: {args.db} not found — run scripts/build_gold.py first.")
        return 2

    con = duckdb.connect(str(args.db), read_only=True)
    results = run_validations(con)
    con.close()

    for r in results:
        mark = "PASS" if r["pass"] else "FAIL"
        print(f"  [{mark}] {r['file']:<34} {r['check']}")
    total, passed, failed = summarize(results)
    print(f"\nVALIDATION: {passed}/{total} passed, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
