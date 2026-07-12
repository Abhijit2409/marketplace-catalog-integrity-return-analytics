# CLAUDE.md

# Marketplace Catalog Integrity & Return Analytics

## Project Mission

Build a production-quality analytics repository that simulates a GCC
marketplace (Noon / Amazon MENA style) to identify catalog-driven
revenue leakage and prioritize listing improvements that maximize
recoverable profit.

Target audience:

-   Senior Data Analyst
-   Business Intelligence Analyst
-   Commercial Analyst
-   Marketplace Analyst
-   Operations Analyst

Primary market:

-   UAE / GCC

------------------------------------------------------------------------

# Project Philosophy

This repository should resemble work produced by an Analytics
Engineering team, not a bootcamp project.

Every design choice should prioritize:

-   Correctness over convenience
-   Business realism over perfect metrics
-   Reproducibility over shortcuts
-   Readability over clever code

------------------------------------------------------------------------

# Golden Rules

## 1. No Data Leakage

The following values must NEVER exist in the Bronze layer:

-   Listing Quality Score (LQS)
-   Trust Score
-   Return Cost
-   Recoverable Profit

These are derived downstream only.

------------------------------------------------------------------------

## 2. RTO Is NOT A Return

RTO belongs ONLY inside:

fact_orders.order_status

Possible statuses include:

-   delivered
-   cancelled_pre_shipment
-   rto_customer_refused
-   rto_unreachable

fact_returns must contain ONLY delivered order lines.

Never violate this rule.

------------------------------------------------------------------------

## 3. Layered Architecture

Bronze (Raw) ↓ Silver (Clean) ↓ Gold (Semantic) ↓ EDA ↓ Machine Learning
↓ Power BI

Never skip a layer.

------------------------------------------------------------------------

## 4. Business First

Every feature must answer:

"What business decision does this support?"

If it does not support a decision, it does not belong in the project.

------------------------------------------------------------------------

# Repository Workflow

The implementation order is fixed.

1.  Bronze Data Audit
2.  Cleaning Rules
3.  Silver Layer
4.  Validation
5.  Gold Semantic Layer
6.  SQL Metrics
7.  Python Analytics
8.  Machine Learning
9.  Power BI Dashboard
10. Executive Decision Memo

------------------------------------------------------------------------

# Coding Standards

-   One module at a time.
-   One responsibility per file.
-   Small functions.
-   Type hints where appropriate.
-   Clear docstrings.
-   Structured logging.
-   No duplicated business logic.
-   Configuration-driven design.
-   Validation before transformation.

------------------------------------------------------------------------

# Validation Rules

Every module must include validation.

Minimum checks:

-   Row counts
-   Null analysis
-   Duplicate analysis
-   Primary key validation
-   Foreign key validation
-   Business rule validation
-   Referential integrity
-   Distribution checks

Fail closed whenever validation fails.

------------------------------------------------------------------------

# Synthetic Data Rules

The generator should produce realistic but imperfect data.

Allowed imperfections:

-   Missing values
-   Duplicate rows
-   Mixed casing
-   Mixed date formats
-   Invalid values
-   Outliers
-   Noisy relationships

Do NOT generate perfectly clean data.

------------------------------------------------------------------------

# Business Rules

-   Category-aware behavior is required.
-   COD must increase RTO risk.
-   Fashion has structurally higher returns.
-   Electronics have lower return rates but higher refurbishment costs.
-   Weight influences logistics cost.
-   Geography influences delivery performance.
-   Courier performance is a hidden variable.
-   Seller Operational Quality (SOQ) is hidden.
-   Expectation Gap is hidden.
-   True Product Quality (TPQ) is hidden.

Hidden variables are never exposed to analytics users.

------------------------------------------------------------------------

# AI Operating Rules

When working on this repository:

-   Do not redesign the architecture unless explicitly requested.
-   Do not invent new business rules.
-   Do not remove validation.
-   Do not duplicate calculations across files.
-   If a critical design issue is found, stop and explain it before
    changing code.
-   Prefer maintainability over optimization.
-   Explain implementation decisions clearly.

------------------------------------------------------------------------

# Definition of Done

A module is complete only if:

-   Code is implemented.
-   Validation passes.
-   Outputs are documented.
-   Assumptions are explained.
-   Manual test steps are provided.

Only then move to the next module.

------------------------------------------------------------------------

# End Goal

Deliver a production-quality analytics project that demonstrates:

-   Analytics Engineering
-   SQL
-   Python
-   Data Modeling
-   Data Quality
-   Business Intelligence
-   Commercial Analytics
-   Executive Storytelling

The final repository should be credible enough to discuss confidently
with senior hiring managers in the UAE/GCC market.
