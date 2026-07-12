-- =====================================================================
-- Gold Bootstrap — 00_bootstrap.sql
-- =====================================================================
-- Runs FIRST in the Gold build. Establishes shared infrastructure so the
-- 01_..07_ scripts have a single, consistent set of Silver source views and
-- reusable macros. It creates no Gold tables and has no validation section.
--
-- Schema strategy: DuckDB's default schema is `main`. The 01_..07_ scripts
-- create UNQUALIFIED tables, so all Gold objects live in `main` under the
-- `gold_` name prefix (a logical namespace). We also declare a `gold` schema
-- for any future qualified objects. Silver sources are exposed as `silver_*`
-- views in `main` (the exact names the 01_..07_ scripts reference).
--
-- Idempotent: every object uses CREATE OR REPLACE, so re-running bootstrap —
-- or the inline source bindings still present in 01_..07_ — is harmless.
-- Requires the process working directory to be the repo root (relative CSV
-- paths); the build/validate scripts guarantee this.
-- Dialect: DuckDB.
-- =====================================================================

-- ---- Schemas --------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS gold;   -- reserved for future qualified Gold objects

-- ---- Reusable Silver source views (single definition) ---------------
-- All ten Silver tables are exposed, even those a given mart does not use,
-- so future Gold work binds to one canonical set.
CREATE OR REPLACE VIEW silver_dim_date              AS SELECT * FROM read_csv_auto('data/02_silver/dim_date.csv');
CREATE OR REPLACE VIEW silver_dim_geography         AS SELECT * FROM read_csv_auto('data/02_silver/dim_geography.csv');
CREATE OR REPLACE VIEW silver_dim_listing           AS SELECT * FROM read_csv_auto('data/02_silver/dim_listing.csv');
CREATE OR REPLACE VIEW silver_dim_return_reason     AS SELECT * FROM read_csv_auto('data/02_silver/dim_return_reason.csv');
CREATE OR REPLACE VIEW silver_dim_seller            AS SELECT * FROM read_csv_auto('data/02_silver/dim_seller.csv');
CREATE OR REPLACE VIEW silver_fact_listing_traffic  AS SELECT * FROM read_csv_auto('data/02_silver/fact_listing_traffic.csv');
CREATE OR REPLACE VIEW silver_fact_orders           AS SELECT * FROM read_csv_auto('data/02_silver/fact_orders.csv');
CREATE OR REPLACE VIEW silver_fact_returns          AS SELECT * FROM read_csv_auto('data/02_silver/fact_returns.csv');
CREATE OR REPLACE VIEW silver_ref_category_economics AS SELECT * FROM read_csv_auto('data/02_silver/ref_category_economics.csv');
CREATE OR REPLACE VIEW silver_ref_logistics_rate_card AS SELECT * FROM read_csv_auto('data/02_silver/ref_logistics_rate_card.csv');

-- ---- Reusable helper macros -----------------------------------------
-- NULL-safe division: returns NULL on a zero/NULL denominator (the "undefined
-- rate" convention used throughout the Gold layer). Available to future Gold
-- SQL; the existing marts inline the equivalent NULLIF pattern.
CREATE OR REPLACE MACRO safe_divide(numerator, denominator) AS
    numerator / NULLIF(denominator, 0);
