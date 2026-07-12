"""Reusable, pure data-integrity check primitives for the Bronze audit.

Each function inspects a DataFrame (or key collections) and returns a
:class:`CheckResult`. Functions never mutate their inputs and never perform
I/O; orchestration, logging and reporting live in ``bronze_audit.py``.

Severity contract (see config/bronze_schema.yaml):
    * ``error`` findings fail the audit closed (structural violations).
    * ``warn``  findings are intentional Bronze dirt to be cleaned in Silver.
"""

from __future__ import annotations

from dataclasses import dataclass, field, asdict
from typing import Any, Iterable

import pandas as pd

# Status / severity vocabularies -------------------------------------------
PASS = "PASS"
WARN = "WARN"
FAIL = "FAIL"

SEV_ERROR = "error"  # fail closed
SEV_WARN = "warn"    # intentional dirt / advisory


@dataclass
class CheckResult:
    """Outcome of a single integrity check."""

    table: str
    check: str
    status: str          # PASS | WARN | FAIL
    severity: str         # error | warn
    summary: str
    details: dict[str, Any] = field(default_factory=dict)

    @property
    def is_blocking(self) -> bool:
        """True when this result must fail the audit closed."""
        return self.status == FAIL and self.severity == SEV_ERROR

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


# --- key normalization -----------------------------------------------------
def normalize_keys(series: pd.Series) -> pd.Series:
    """Return a comparison-safe key series.

    CSV round-tripping turns integer keys with any null into floats
    (e.g. ``20251025.0``). To compare such foreign keys against an integer
    parent key we coerce whole-valued floats to a nullable integer, then to
    string. Nulls are preserved as ``pd.NA`` so callers can exclude them.
    """
    if pd.api.types.is_float_dtype(series):
        # Only collapse to int when every non-null value is whole.
        non_null = series.dropna()
        if not non_null.empty and (non_null == non_null.round()).all():
            series = series.astype("Int64")
    return series.astype("string").str.strip()


def normalize_column_name(name: str) -> str:
    """Lowercase and strip to alphanumerics for leakage matching."""
    return "".join(ch for ch in str(name).lower() if ch.isalnum())


# --- structural checks (fail closed) --------------------------------------
def check_primary_key(df: pd.DataFrame, table: str, pk: list[str]) -> CheckResult:
    """Primary key must be present, non-null, and unique. Fails closed."""
    missing = [c for c in pk if c not in df.columns]
    if missing:
        return CheckResult(table, "primary_key", FAIL, SEV_ERROR,
                           f"PK column(s) missing: {missing}",
                           {"pk": pk, "missing_columns": missing})

    keys = df[pk]
    null_rows = int(keys.isna().any(axis=1).sum())
    dup_rows = int(keys.duplicated(keep=False).sum())
    n_dup_groups = int(keys[keys.duplicated(keep=False)].drop_duplicates().shape[0])

    ok = null_rows == 0 and dup_rows == 0
    status = PASS if ok else FAIL
    summary = (
        f"PK {pk} unique & non-null across {len(df):,} rows"
        if ok else
        f"PK {pk} violated: {dup_rows:,} rows in {n_dup_groups:,} duplicate "
        f"group(s), {null_rows:,} null-key row(s)"
    )
    return CheckResult(table, "primary_key", status, SEV_ERROR, summary, {
        "pk": pk,
        "row_count": int(len(df)),
        "null_key_rows": null_rows,
        "duplicate_rows": dup_rows,
        "duplicate_groups": n_dup_groups,
    })


def check_foreign_key(child: pd.DataFrame, table: str, column: str,
                      parent_keys: pd.Series, ref: str,
                      coverage_aware: bool = False) -> CheckResult:
    """Referential integrity for one FK.

    Nulls are missing data (WARN territory, counted separately), NOT broken
    references. Only non-null values with no matching parent are orphans.

    Severity discriminates broken references from deterministically-cleanable
    dirt:
      * A non-null value with no valid referent is corruption -> FAIL (error).
      * When ``coverage_aware`` (the FK targets a calendar dimension), an
        orphan whose value is numeric and strictly greater than the parent's
        maximum key is a *coverage gap* (the calendar simply ends too early)
        -> WARN. Fix = extend the dimension. Orphans at/inside the covered
        range, or unparseable values, remain corruption -> FAIL.
    """
    if column not in child.columns:
        return CheckResult(table, f"fk:{column}", FAIL, SEV_ERROR,
                           f"FK column '{column}' missing", {"ref": ref})

    child_keys = normalize_keys(child[column])
    parent_set = set(normalize_keys(parent_keys).dropna())

    null_count = int(child_keys.isna().sum())
    non_null = child_keys.dropna()
    n_non_null = int(len(non_null))
    orphan_values = non_null[~non_null.isin(parent_set)]
    orphan_count = int(len(orphan_values))
    match_rate = 1.0 if n_non_null == 0 else (n_non_null - orphan_count) / n_non_null

    coverage_count = 0
    broken_count = orphan_count
    coverage_max = None
    if coverage_aware and orphan_count:
        parent_max = pd.to_numeric(parent_keys, errors="coerce").max()
        orphan_num = pd.to_numeric(orphan_values, errors="coerce")
        beyond = orphan_num.notna() & (orphan_num > parent_max)
        coverage_count = int(beyond.sum())
        broken_count = orphan_count - coverage_count
        if coverage_count:
            coverage_max = int(orphan_num[beyond].max())

    if broken_count > 0:
        status, severity = FAIL, SEV_ERROR
    elif coverage_count > 0:
        status, severity = WARN, SEV_WARN
    else:
        status, severity = PASS, SEV_ERROR

    parts = [f"{column} -> {ref}: {match_rate:.4%} of {n_non_null:,} non-null "
             f"keys resolve"]
    if broken_count:
        parts.append(f"{broken_count:,} broken orphan(s)")
    if coverage_count:
        parts.append(f"{coverage_count:,} beyond-calendar (extend dimension "
                     f"through >= {coverage_max})")
    parts.append(f"{null_count:,} null(s)")
    summary = "; ".join(parts)

    return CheckResult(table, f"fk:{column}", status, severity, summary, {
        "ref": ref,
        "null_count": null_count,
        "orphan_count": orphan_count,
        "broken_orphans": broken_count,
        "coverage_orphans": coverage_count,
        "coverage_extend_through": coverage_max,
        "match_rate_on_non_null": round(match_rate, 6),
        "orphan_sample": sorted(orphan_values.unique().tolist())[:10],
    })


def check_leakage(df: pd.DataFrame, table: str,
                  forbidden: Iterable[str]) -> CheckResult:
    """Golden Rule 1: no downstream/derived columns in Bronze. Fails closed."""
    forbidden = list(forbidden)
    hits = [c for c in df.columns
            if any(tok in normalize_column_name(c) for tok in forbidden)]
    status = FAIL if hits else PASS
    summary = (f"leakage columns present: {hits}" if hits
               else "no leakage columns")
    return CheckResult(table, "leakage", status, SEV_ERROR, summary,
                       {"forbidden": forbidden, "offending_columns": hits})


def check_membership(df: pd.DataFrame, table: str, column: str,
                     allowed: set[str], ref_label: str) -> CheckResult:
    """Non-null values of ``column`` must belong to ``allowed``.

    Comparison is on a strip+casefold normalized form, because mixed casing
    and stray whitespace are explicitly-allowed Bronze dirt (CLAUDE.md -
    Synthetic Data Rules). Severity therefore splits:
      * value unknown even after normalization -> FAIL (error): a real
        domain violation with no valid referent.
      * value that matches only after normalization -> WARN: cleanable dirt
        (Silver normalizes case/whitespace).
    """
    if column not in df.columns:
        return CheckResult(table, f"membership:{column}", FAIL, SEV_ERROR,
                           f"column '{column}' missing", {})

    def norm(s: pd.Series) -> pd.Series:
        return s.astype("string").str.strip().str.casefold()

    raw = df[column].dropna().astype("string")
    allowed_norm = {str(a).strip().casefold() for a in allowed}
    raw_norm = norm(raw)

    unknown_mask = ~raw_norm.isin(allowed_norm)
    unknown = sorted(raw[unknown_mask].unique().tolist())[:10]
    unknown_count = int(unknown_mask.sum())

    # Matched-after-normalization: normalizes to a known value but its raw
    # form is not the canonical spelling -> casing/whitespace dirt.
    canonical = {str(a) for a in allowed}
    dirty_mask = (~unknown_mask) & (~raw.isin(canonical))
    dirty_count = int(dirty_mask.sum())
    dirty_sample = sorted(raw[dirty_mask].unique().tolist())[:10]

    if unknown_count > 0:
        status, severity = FAIL, SEV_ERROR
        summary = (f"{column}: {unknown_count:,} value(s) not in {ref_label} "
                   f"even after normalization: {unknown}")
    elif dirty_count > 0:
        status, severity = WARN, SEV_WARN
        summary = (f"{column}: all values map to {ref_label}, but "
                   f"{dirty_count:,} row(s) need case/whitespace normalization "
                   f"(e.g. {dirty_sample[:5]})")
    else:
        status, severity = PASS, SEV_ERROR
        summary = f"{column} all canonical within {ref_label}"

    return CheckResult(table, f"membership:{column}", status, severity, summary, {
        "ref": ref_label,
        "unknown_count": unknown_count,
        "unknown_sample": unknown,
        "needs_normalization_count": dirty_count,
        "needs_normalization_sample": dirty_sample,
    })


def check_delivered_only(returns: pd.DataFrame, orders: pd.DataFrame,
                         table: str, cfg: dict[str, str]) -> CheckResult:
    """Golden Rule 2 + row-count reconciliation.

    Every returned order line must (a) resolve to a row in fact_orders and
    (b) that row's status must be ``delivered``. RTO / cancelled lines must
    never appear in returns. Fails closed.
    """
    ref_col = cfg["order_ref_column"]
    okey = cfg["orders_key"]
    status_col = cfg["orders_status_column"]
    delivered = cfg["delivered_value"]

    r_keys = normalize_keys(returns[ref_col]).dropna()
    o = orders[[okey, status_col]].copy()
    o["_k"] = normalize_keys(o[okey])
    status_by_key = o.dropna(subset=["_k"]).set_index("_k")[status_col]

    orphan_mask = ~r_keys.isin(status_by_key.index)
    orphan_count = int(orphan_mask.sum())

    resolved = r_keys[~orphan_mask]
    resolved_status = status_by_key.reindex(resolved).astype("string").str.strip()
    non_delivered_mask = resolved_status != delivered
    non_delivered_count = int(non_delivered_mask.sum())
    bad_statuses = (resolved_status[non_delivered_mask]
                    .value_counts().to_dict())

    total = int(len(r_keys))
    ok = orphan_count == 0 and non_delivered_count == 0
    status = PASS if ok else FAIL
    summary = (
        f"all {total:,} returns reconcile to delivered orders" if ok else
        f"returns integrity broken: {orphan_count:,} unmatched order_line_id(s), "
        f"{non_delivered_count:,} return(s) against non-delivered orders "
        f"{bad_statuses}"
    )
    return CheckResult(table, "returns_delivered_reconciliation", status,
                       SEV_ERROR, summary, {
        "returns_with_order_ref": total,
        "unmatched_order_lines": orphan_count,
        "returns_against_non_delivered": non_delivered_count,
        "non_delivered_status_breakdown": bad_statuses,
    })


# --- advisory checks (intentional dirt -> WARN) ---------------------------
def check_nulls(df: pd.DataFrame, table: str) -> CheckResult:
    """Per-column null profile. WARN when dirt exists; never fails closed."""
    counts = df.isna().sum()
    counts = counts[counts > 0]
    n = len(df)
    profile = {c: {"nulls": int(v), "pct": round(v / n, 6)}
               for c, v in counts.items()}
    status = WARN if profile else PASS
    summary = (f"{len(profile)} column(s) with nulls (intentional dirt)"
               if profile else "no nulls")
    return CheckResult(table, "null_analysis", status, SEV_WARN, summary,
                       {"row_count": n, "columns_with_nulls": profile})


def check_duplicate_rows(df: pd.DataFrame, table: str) -> CheckResult:
    """Fully-duplicated rows. Advisory WARN (Silver dedupes)."""
    dup = int(df.duplicated(keep=False).sum())
    status = WARN if dup > 0 else PASS
    summary = (f"{dup:,} fully-duplicated row(s)" if dup
               else "no fully-duplicated rows")
    return CheckResult(table, "duplicate_rows", status, SEV_WARN, summary,
                       {"duplicate_rows": dup})


def check_ranges(df: pd.DataFrame, table: str,
                 specs: list[dict[str, Any]]) -> CheckResult:
    """Numeric range/domain checks. Out-of-range = dirt -> WARN."""
    violations: dict[str, Any] = {}
    for spec in specs:
        col = spec["column"]
        if col not in df.columns:
            violations[col] = {"error": "column missing"}
            continue
        s = pd.to_numeric(df[col], errors="coerce")
        mask = pd.Series(False, index=df.index)
        if "min" in spec:
            mask |= s < spec["min"]
        if "max" in spec:
            mask |= s > spec["max"]
        bad = int((mask & s.notna()).sum())
        if bad:
            violations[col] = {
                "out_of_range": bad,
                "bounds": {k: spec[k] for k in ("min", "max") if k in spec},
                "observed_min": None if s.notna().sum() == 0 else float(s.min()),
                "observed_max": None if s.notna().sum() == 0 else float(s.max()),
            }
    status = WARN if violations else PASS
    summary = (f"{len(violations)} column(s) out of range" if violations
               else "all ranges valid")
    return CheckResult(table, "distribution_ranges", status, SEV_WARN, summary,
                       {"violations": violations})


def check_funnel(df: pd.DataFrame, table: str,
                 ordered_cols: list[str]) -> CheckResult:
    """Monotonic funnel: col[0] >= col[1] >= ... (nulls ignored). WARN."""
    missing = [c for c in ordered_cols if c not in df.columns]
    if missing:
        return CheckResult(table, "funnel_monotonicity", WARN, SEV_WARN,
                           f"funnel columns missing: {missing}", {})
    breaches: dict[str, int] = {}
    for upper, lower in zip(ordered_cols, ordered_cols[1:]):
        u = pd.to_numeric(df[upper], errors="coerce")
        l = pd.to_numeric(df[lower], errors="coerce")
        both = u.notna() & l.notna()
        bad = int((both & (u < l)).sum())
        if bad:
            breaches[f"{upper}<{lower}"] = bad
    status = WARN if breaches else PASS
    summary = (f"funnel breaches: {breaches}" if breaches
               else f"funnel monotonic ({' >= '.join(ordered_cols)})")
    return CheckResult(table, "funnel_monotonicity", status, SEV_WARN, summary,
                       {"order": ordered_cols, "breaches": breaches})
