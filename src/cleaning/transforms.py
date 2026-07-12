"""Pure cleaning transforms for the Silver layer (Phase B).

Each function takes a DataFrame (plus rule parameters) and returns a
``(new_frame, TransformRecord)`` tuple. Functions never mutate their input
and never perform I/O; orchestration, logging and reporting live in
``silver_build.py``.

Quality-annotation columns added here all use the ``dq_`` prefix.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field, asdict
from typing import Any

import numpy as np
import pandas as pd

# Strings that should be treated as missing regardless of source formatting.
_NULL_TOKENS = {"", "nan", "null", "na", "none", "n/a", "-"}


@dataclass
class TransformRecord:
    """Auditable record of what one transform did to one table."""

    table: str
    action: str
    summary: str
    details: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


# --- Task 4a: standardize the representation of "missing" -----------------
def standardize_null_tokens(df: pd.DataFrame, table: str
                            ) -> tuple[pd.DataFrame, TransformRecord]:
    """Coerce null-like string tokens ('', 'NA', 'null', ...) to real NaN."""
    out = df.copy()
    replaced = 0
    for col in out.select_dtypes(include="object").columns:
        ser = out[col]
        # Detect token-like cells WITHOUT permanently coercing dtype, so
        # object-typed booleans (True/False/NaN) are left intact.
        as_str = ser.astype("string").str.strip().str.casefold()
        mask = as_str.isin(_NULL_TOKENS).fillna(False)
        replaced += int(mask.sum())
        if mask.any():
            out[col] = ser.mask(mask, other=np.nan)
    return out, TransformRecord(
        table, "standardize_null_tokens",
        f"normalized {replaced} null-like token(s) to NaN",
        {"tokens_normalized": replaced})


# --- Task 1: deduplicate primary-key violations ---------------------------
def deduplicate(df: pd.DataFrame, table: str, pk: list[str]
                ) -> tuple[pd.DataFrame, TransformRecord]:
    """Drop duplicate primary keys, keeping the most-complete row.

    Rows within a PK group are ranked by non-null count (descending); ties
    resolve to the first occurrence, making the result deterministic. For
    fully-identical duplicates this is a lossless drop_duplicates.
    """
    before = len(df)
    completeness = df.notna().sum(axis=1)
    order = completeness.sort_values(kind="stable", ascending=False).index
    out = (df.loc[order]
             .drop_duplicates(subset=pk, keep="first")
             .sort_index())
    removed = before - len(out)
    return out, TransformRecord(
        table, "deduplicate",
        f"removed {removed} duplicate row(s) on PK {pk}",
        {"pk": pk, "rows_before": before, "rows_after": int(len(out)),
         "rows_removed": int(removed)})


# --- Task 2: normalize category casing / spacing --------------------------
def normalize_category(df: pd.DataFrame, table: str, column: str,
                       canonical: list[str], unmapped_value: str
                       ) -> tuple[pd.DataFrame, TransformRecord]:
    """Map free-form category text to a canonical vocabulary.

    Matching is strip + casefold. Values that still do not match become
    ``unmapped_value`` and are counted (none expected for this dataset).
    Adds ``dq_category_normalized`` / ``dq_category_unmapped`` flags.
    """
    out = df.copy()
    lookup = {c.strip().casefold(): c for c in canonical}
    raw = out[column]
    key = raw.astype("string").str.strip().str.casefold()
    mapped = key.map(lookup)

    unmapped_mask = raw.notna() & mapped.isna()
    normalized_mask = raw.notna() & mapped.notna() & (mapped != raw)

    out[column] = mapped.where(raw.notna(), other=pd.NA)
    out.loc[unmapped_mask, column] = unmapped_value
    out["dq_category_normalized"] = normalized_mask.to_numpy()
    out["dq_category_unmapped"] = unmapped_mask.to_numpy()

    return out, TransformRecord(
        table, "normalize_category",
        f"normalized {int(normalized_mask.sum())} category value(s); "
        f"{int(unmapped_mask.sum())} unmapped -> '{unmapped_value}'",
        {"column": column,
         "normalized_count": int(normalized_mask.sum()),
         "unmapped_count": int(unmapped_mask.sum()),
         "canonical": canonical})


# --- Phase B addendum: canonicalize categorical enum columns --------------
def _enum_key(value: str) -> str:
    """Normalization key: strip, casefold, collapse spaces/underscores.

    Maps e.g. 'RESELLABLE', ' resellable ', 'write off' and 'write_off' onto a
    single comparable key so casing, whitespace and space-vs-underscore
    variants all resolve to the same canonical value.
    """
    return re.sub(r"[\s_]+", "_", str(value).strip().casefold())


def normalize_enum(df: pd.DataFrame, table: str, column: str,
                   canonical: list[str]) -> tuple[pd.DataFrame, TransformRecord]:
    """Map free-form enum text to a canonical vocabulary.

    Values matching a canonical term (after key normalization) are rewritten to
    the canonical spelling; unmatched non-null values are left unchanged and
    counted. Adds a ``dq_<column>_normalized`` flag marking rewritten rows.
    """
    out = df.copy()
    lookup = {_enum_key(c): c for c in canonical}
    raw = out[column]
    key = raw.astype("string").map(lambda v: _enum_key(v) if pd.notna(v) else pd.NA)
    mapped = key.map(lookup)

    normalized_mask = raw.notna() & mapped.notna() & (mapped != raw)
    unmapped_mask = raw.notna() & mapped.isna()

    out[column] = mapped.where(mapped.notna(), other=raw)
    out[f"dq_{column}_normalized"] = normalized_mask.to_numpy()

    return out, TransformRecord(
        table, "normalize_enum",
        f"{column}: normalized {int(normalized_mask.sum())} value(s) to "
        f"{canonical}; {int(unmapped_mask.sum())} unmapped (kept as-is)",
        {"column": column,
         "normalized_count": int(normalized_mask.sum()),
         "unmapped_count": int(unmapped_mask.sum()),
         "unmapped_sample": sorted(raw[unmapped_mask].dropna().unique().tolist())[:10],
         "canonical": canonical})


# --- Task 3: extend the date dimension ------------------------------------
def extend_dim_date(df: pd.DataFrame, table: str, through_key: int,
                    weekend_days: list[str], event_defaults: dict[str, bool]
                    ) -> tuple[pd.DataFrame, TransformRecord]:
    """Append calendar rows up to and including ``through_key`` (YYYYMMDD).

    Deterministic fields (weekday, ISO week, month, quarter, year, weekend)
    are derived; event flags use documented defaults (see cleaning_rules).
    """
    current_max = int(df["date_key"].max())
    start = pd.to_datetime(str(current_max), format="%Y%m%d") + pd.Timedelta(days=1)
    end = pd.to_datetime(str(int(through_key)), format="%Y%m%d")
    if end < start:
        return df.copy(), TransformRecord(
            table, "extend_dim_date",
            f"no extension needed (already covers through {current_max})",
            {"current_max": current_max, "rows_added": 0})

    dates = pd.date_range(start, end, freq="D")
    weekend = {d.lower() for d in weekend_days}
    new = pd.DataFrame({
        "date_key": dates.strftime("%Y%m%d").astype(int),
        "full_date": dates.strftime("%Y-%m-%d"),
        "day_of_week": dates.strftime("%A"),
        "week_of_year": dates.isocalendar().week.astype(int).to_numpy(),
        "month": dates.month,
        "quarter": dates.quarter,
        "year": dates.year,
        "is_weekend": [d.strftime("%A").lower() in weekend for d in dates],
    })
    for flag, val in event_defaults.items():
        new[flag] = bool(val)

    new = new[df.columns]  # align column order to Bronze schema
    out = pd.concat([df, new], ignore_index=True).sort_values("date_key")
    return out.reset_index(drop=True), TransformRecord(
        table, "extend_dim_date",
        f"added {len(new)} calendar row(s): "
        f"{new['date_key'].min()}..{new['date_key'].max()}",
        {"current_max": current_max, "extended_through": int(through_key),
         "rows_added": int(len(new))})


# --- Task 4b: standardized null-handling policy ---------------------------
def apply_null_policy(df: pd.DataFrame, table: str,
                      policy: dict[str, dict[str, Any]]
                      ) -> tuple[pd.DataFrame, TransformRecord]:
    """Apply a per-column null strategy.

    Strategies:
      * ``fill``          -> constant fill + ``dq_imputed_<col>`` flag.
      * ``flag_missing``  -> keep NaN + ``dq_missing_<col>`` flag.
      * ``keep``          -> leave untouched (documents intentional null).
    """
    out = df.copy()
    applied: dict[str, Any] = {}
    for col, rule in policy.items():
        if col not in out.columns:
            applied[col] = {"error": "column missing"}
            continue
        strategy = rule["strategy"]
        was_null = out[col].isna()
        if strategy == "fill":
            out[f"dq_imputed_{col}"] = was_null.to_numpy()
            # infer_objects avoids the pandas object-downcast FutureWarning
            # when filling e.g. False into an object (boolean+null) column.
            out[col] = out[col].fillna(rule["value"]).infer_objects(copy=False)
            applied[col] = {"strategy": "fill", "value": rule["value"],
                            "imputed": int(was_null.sum())}
        elif strategy == "flag_missing":
            out[f"dq_missing_{col}"] = was_null.to_numpy()
            applied[col] = {"strategy": "flag_missing",
                            "missing": int(was_null.sum())}
        elif strategy == "keep":
            applied[col] = {"strategy": "keep", "nulls": int(was_null.sum())}
        else:
            applied[col] = {"error": f"unknown strategy '{strategy}'"}
    return out, TransformRecord(
        table, "apply_null_policy",
        f"applied null policy to {len(policy)} column(s)",
        {"columns": applied})


# --- Task 5: flag invalid data ranges -------------------------------------
def flag_invalid_ranges(df: pd.DataFrame, table: str,
                        specs: list[dict[str, Any]]
                        ) -> tuple[pd.DataFrame, TransformRecord]:
    """Flag out-of-range numeric values.

    Adds ``dq_out_of_range_<col>``. ``on_invalid: 'null'`` quarantines the
    value (attributes); ``on_invalid: keep`` preserves it (core fact
    measures) - the flag is always the record of the violation.
    """
    out = df.copy()
    result: dict[str, Any] = {}
    for spec in specs:
        col = spec["column"]
        if col not in out.columns:
            result[col] = {"error": "column missing"}
            continue
        s = pd.to_numeric(out[col], errors="coerce")
        mask = pd.Series(False, index=out.index)
        if "min" in spec:
            mask |= s < spec["min"]
        if "max" in spec:
            mask |= s > spec["max"]
        mask &= s.notna()
        out[f"dq_out_of_range_{col}"] = mask.to_numpy()
        on_invalid = str(spec.get("on_invalid", "keep"))
        if on_invalid == "null" and mask.any():
            out.loc[mask, col] = np.nan
        result[col] = {"out_of_range": int(mask.sum()),
                       "bounds": {k: spec[k] for k in ("min", "max") if k in spec},
                       "on_invalid": on_invalid}
    return out, TransformRecord(
        table, "flag_invalid_ranges",
        f"range-checked {len(specs)} column(s)",
        {"columns": result})


# --- Task 6: temporal consistency flags -----------------------------------
def _num(s: pd.Series) -> pd.Series:
    return pd.to_numeric(s, errors="coerce")


def temporal_flags_orders(df: pd.DataFrame, table: str, as_of_key: int
                          ) -> tuple[pd.DataFrame, TransformRecord]:
    """Row-level temporal checks on fact_orders."""
    out = df.copy()
    order = _num(out["order_date_key"])
    promised = _num(out["promised_delivery_date_key"])
    actual = _num(out["actual_delivery_date_key"])
    status = out["order_status"].astype("string").str.strip()

    flags = {
        "dq_promised_before_order": (promised.notna() & (promised < order)),
        "dq_actual_before_order": (actual.notna() & (actual < order)),
        "dq_delivered_missing_actual":
            (status == "delivered") & actual.isna(),
        "dq_nondelivered_has_actual":
            (status != "delivered") & actual.notna(),
        # Implements the Phase A "delivered in the future" to-do.
        "dq_delivery_after_asof": (actual.notna() & (actual > as_of_key)),
    }
    for name, mask in flags.items():
        out[name] = mask.to_numpy()
    counts = {name: int(mask.sum()) for name, mask in flags.items()}
    return out, TransformRecord(
        table, "temporal_flags_orders",
        f"temporal checks: {counts}", {"as_of_key": int(as_of_key),
                                        "violation_counts": counts})


def temporal_flags_returns(df: pd.DataFrame, table: str, as_of_key: int,
                           order_actual_delivery: pd.Series
                           ) -> tuple[pd.DataFrame, TransformRecord]:
    """Row-level temporal checks on fact_returns (joins delivery date)."""
    out = df.copy()
    initiated = _num(out["return_initiated_date_key"])
    received = _num(out["return_received_date_key"])
    delivery = _num(out["order_line_id"].map(order_actual_delivery))

    flags = {
        "dq_received_before_initiated":
            (initiated.notna() & received.notna() & (received < initiated)),
        "dq_return_before_delivery":
            (initiated.notna() & delivery.notna() & (initiated < delivery)),
        "dq_return_after_asof": (
            (initiated.notna() & (initiated > as_of_key)) |
            (received.notna() & (received > as_of_key))),
    }
    for name, mask in flags.items():
        out[name] = mask.to_numpy()
    counts = {name: int(mask.sum()) for name, mask in flags.items()}
    return out, TransformRecord(
        table, "temporal_flags_returns",
        f"temporal checks: {counts}", {"as_of_key": int(as_of_key),
                                       "violation_counts": counts})
