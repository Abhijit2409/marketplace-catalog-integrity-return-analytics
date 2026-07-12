"""Export the Gold layer from gold.duckdb to portable files for Power BI.

Power BI cannot consume DuckDB portably, so every Gold table is exported to
BOTH CSV (universal) and Parquet (types preserved) under data/03_gold/. Exports
are **deterministic** — each table is written with an explicit ORDER BY on its
key, so re-running produces byte-stable files — and the run **fails closed** if
any export or post-export check fails.

This script only READS gold.duckdb and WRITES export files; it never modifies
the database, SQL, validation, metrics, or business logic.

Usage:
    py scripts/export_gold.py [--db PATH]

Exit codes: 0 = all tables exported and validated ; 1 = a failure occurred.
"""

from __future__ import annotations

import argparse
import datetime as dt
import time
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parents[1]
DB_PATH = ROOT / "gold.duckdb"
OUT_DIR = ROOT / "data" / "03_gold"
CSV_DIR = OUT_DIR / "csv"
PARQUET_DIR = OUT_DIR / "parquet"
REPORT_PATH = ROOT / "docs" / "gold_export_report.md"

# Gold table -> deterministic sort key (its primary/natural key) so exports are
# reproducible and byte-stable across runs.
GOLD_TABLES: dict[str, str] = {
    "gold_order_line_economics": "order_line_id",
    "gold_return_line_economics": "return_id",
    "gold_listing_metrics": "listing_id",
    "gold_seller_metrics": "seller_id",
    "gold_category_metrics": "category",
    "gold_executive_summary": "kpi_sort",
    "gold_intervention_queue": "global_priority_rank",
}


def columns_of(con: duckdb.DuckDBPyConnection, relation_sql: str) -> list[str]:
    """Ordered column names of a relation (table name or read_* expression)."""
    con.execute(f"SELECT * FROM {relation_sql} LIMIT 0")
    return [d[0] for d in con.description]


def human_size(num_bytes: int) -> str:
    size = float(num_bytes)
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024 or unit == "GB":
            return f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} GB"


def export_table(con: duckdb.DuckDBPyConnection, table: str, order_by: str) -> dict:
    """Export one table to CSV + Parquet and validate the results."""
    result: dict = {"table": table, "status": "OK", "error": None}

    # Source truth: row count + column names in gold.duckdb.
    src_rows = con.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
    src_cols = columns_of(con, table)

    csv_path = CSV_DIR / f"{table}.csv"
    parquet_path = PARQUET_DIR / f"{table}.parquet"
    # DuckDB wants forward-slash paths; COPY overwrites the target file safely.
    csv_posix = csv_path.as_posix()
    pq_posix = parquet_path.as_posix()
    ordered = f"SELECT * FROM {table} ORDER BY {order_by}"

    t0 = time.perf_counter()
    con.execute(f"COPY ({ordered}) TO '{csv_posix}' (FORMAT CSV, HEADER, OVERWRITE_OR_IGNORE)")
    con.execute(f"COPY ({ordered}) TO '{pq_posix}' (FORMAT PARQUET, OVERWRITE_OR_IGNORE)")
    result["seconds"] = time.perf_counter() - t0

    # Read the exports back and reconcile row counts + columns.
    csv_rows = con.execute(f"SELECT COUNT(*) FROM read_csv_auto('{csv_posix}')").fetchone()[0]
    pq_rows = con.execute(f"SELECT COUNT(*) FROM read_parquet('{pq_posix}')").fetchone()[0]
    csv_cols = columns_of(con, f"read_csv_auto('{csv_posix}')")
    pq_cols = columns_of(con, f"read_parquet('{pq_posix}')")

    result.update({
        "src_rows": src_rows, "csv_rows": csv_rows, "parquet_rows": pq_rows,
        "n_cols": len(src_cols),
        "csv_path": csv_path, "parquet_path": parquet_path,
        "csv_bytes": csv_path.stat().st_size if csv_path.exists() else 0,
        "parquet_bytes": parquet_path.stat().st_size if parquet_path.exists() else 0,
    })

    checks = {
        "csv_rowcount_matches": csv_rows == src_rows,
        "parquet_rowcount_matches": pq_rows == src_rows,
        "csv_columns_match": csv_cols == src_cols,      # ordered, no missing/renamed
        "parquet_columns_match": pq_cols == src_cols,
    }
    result["checks"] = checks
    if not all(checks.values()):
        result["status"] = "FAIL"
        result["error"] = ", ".join(k for k, v in checks.items() if not v)
    return result


def write_report(results: list[dict], *, started_at: dt.datetime,
                 total_seconds: float, overall_ok: bool) -> None:
    lines: list[str] = []
    a = lines.append
    a("# Gold Export Report")
    a("")
    a(f"**Overall:** `{'PASS' if overall_ok else 'FAIL'}`  ")
    a(f"**Export timestamp:** {started_at.isoformat(timespec='seconds')}  ")
    a(f"**Total duration:** {total_seconds:.2f}s  ")
    a(f"**Tables exported:** {len(results)}  ")
    a(f"**Formats:** CSV (`data/03_gold/csv/`) + Parquet (`data/03_gold/parquet/`)")
    a("")
    a("## Tables")
    a("")
    a("| Table | Rows | Cols | CSV size | Parquet size | Duration (s) | Status |")
    a("|---|---:|---:|---:|---:|---:|---|")
    for r in results:
        a(f"| `{r['table']}` | {r.get('src_rows', 0):,} | {r.get('n_cols', 0)} "
          f"| {human_size(r.get('csv_bytes', 0))} | {human_size(r.get('parquet_bytes', 0))} "
          f"| {r.get('seconds', 0):.3f} | {r['status']} |")
    a("")
    a("## Validation summary")
    a("")
    a("Each table verified: exists in DuckDB · CSV row count == DuckDB · Parquet "
      "row count == DuckDB · CSV & Parquet columns match names/order (no missing "
      "columns).")
    a("")
    a("| Table | DuckDB rows | CSV rows | Parquet rows | Cols match | Result |")
    a("|---|---:|---:|---:|:---:|---|")
    for r in results:
        cols_ok = r.get("checks", {}).get("csv_columns_match") and \
            r.get("checks", {}).get("parquet_columns_match")
        a(f"| `{r['table']}` | {r.get('src_rows', 0):,} | {r.get('csv_rows', 0):,} "
          f"| {r.get('parquet_rows', 0):,} | {'yes' if cols_ok else 'NO'} "
          f"| {'PASS' if r['status'] == 'OK' else 'FAIL — ' + (r['error'] or '')} |")
    a("")
    a("## Notes")
    a("")
    a("- **Determinism:** every table exported with an explicit `ORDER BY` on its "
      "key, so re-runs are byte-stable.")
    a("- **Datatypes:** Parquet preserves DuckDB column types; CSV is type-inferred "
      "on read (Power BI applies its own types) — prefer the Parquet folder in "
      "Power BI when available.")
    a("- Read-only with respect to `gold.duckdb`; no SQL, validation, metrics or "
      "business logic was modified.")
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text("\n".join(lines), encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Export the Gold layer for Power BI")
    p.add_argument("--db", type=Path, default=DB_PATH)
    args = p.parse_args(argv)

    started_at = dt.datetime.now()
    overall_t0 = time.perf_counter()

    if not args.db.exists():
        print(f"ERROR: {args.db} not found — run scripts/build_gold.py first.")
        return 1
    CSV_DIR.mkdir(parents=True, exist_ok=True)
    PARQUET_DIR.mkdir(parents=True, exist_ok=True)

    con = duckdb.connect(str(args.db))
    # Confirm every expected table exists before exporting (fail closed).
    present = {r[0] for r in con.execute("SHOW TABLES").fetchall()}
    missing = [t for t in GOLD_TABLES if t not in present]
    if missing:
        con.close()
        print(f"ERROR: missing Gold tables in {args.db.name}: {missing}")
        return 1

    print(f"Exporting {len(GOLD_TABLES)} Gold tables -> {OUT_DIR}")
    results: list[dict] = []
    ok = True
    for table, order_by in GOLD_TABLES.items():
        try:
            r = export_table(con, table, order_by)
        except Exception as exc:                      # fail closed on any error
            r = {"table": table, "status": "FAIL", "error": str(exc)[:120]}
            ok = False
        results.append(r)
        if r["status"] != "OK":
            ok = False
        rows = r.get("src_rows", "?")
        print(f"  [{r['status']:>4}] {table:<32} rows={rows} "
              f"csv={r.get('csv_path', '')} pq={r.get('parquet_path', '')} "
              f"{r.get('seconds', 0):.3f}s"
              + (f"  ERROR: {r['error']}" if r["status"] != "OK" else ""))
    con.close()

    total_seconds = time.perf_counter() - overall_t0
    write_report(results, started_at=started_at, total_seconds=total_seconds,
                 overall_ok=ok)

    print("-" * 60)
    exported = sum(1 for r in results if r["status"] == "OK")
    print(f"EXPORT {'PASS' if ok else 'FAIL'} | {exported}/{len(GOLD_TABLES)} tables "
          f"| {total_seconds:.2f}s")
    print(f"Report: {REPORT_PATH.relative_to(ROOT)}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
