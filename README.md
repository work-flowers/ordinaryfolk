# Ordinary Folk — Data Warehouse & Analytics

This repository contains the BigQuery SQL views, ad-hoc queries, and supporting files that power Ordinary Folk's data pipeline and Tableau dashboards. The pipeline serves a healthcare subscription business operating in Singapore, Hong Kong, and Japan across two brands (Noah and Zoey).

## How the pipeline works

Raw data is ingested via **Fivetran** from Stripe (×3 regions), Postgres (×3 regions), Facebook Ads, Google Ads, Taboola, Segment, and 31 Google Sheets worksheets. It lands in BigQuery, where a layered set of SQL views transforms it into analytics-ready models consumed by Tableau.

```
Stripe / Postgres / Ad Platforms / Sheets
        │  Fivetran
        ▼
BigQuery raw datasets (sg_stripe, hk_stripe, jp_stripe, …)
        │  SQL Views
        ▼
Layer 1  Regional unions (all_stripe.*, all_postgres.*, ref.*)
Layer 2  Enriched entities (product_cost, marketing_spend, subscription_metrics, …)
Layer 3  Core models (contribution_margin, customer_lifecycle, acquisition_details, …)
Layer 4  Reporting (monthly_contribution_margin, ltv_cac, daily_roas, cm3, …)
        │  Tableau Extracts
        ▼
Tableau dashboards (Monthly Metrics, WBR, Investor & Board, …)
```

For full documentation — including per-view reference, dependency graphs, Tableau mapping, Fivetran connector inventory, and maintenance checklists — see **[data-pipeline-documentation.md](data-pipeline-documentation.md)**.

## Repository structure

```
├── views/                             Production BigQuery views (42 files)
│   ├── layer1_regional_unions/        UNION ALL across SG/HK/JP + reference lookups
│   ├── layer2_enriched_entities/      Cost tables, marketing spend, subscription metrics
│   ├── layer3_core_models/            Contribution margin, customer lifecycle, acquisition
│   └── layer4_reporting/              Monthly P&L, LTV/CAC, ROAS, CM3
│
├── ad_hoc/                            One-off and exploratory queries (59 files)
│   ├── revenue_and_charges/
│   ├── subscriptions/
│   ├── marketing/
│   ├── operations/
│   └── data_quality/
│
├── analysis/                          Non-SQL analysis (R scripts, prompts)
├── projects/                          Self-contained project folders
├── reference/                         Supporting data exports (CSVs)
├── tableau/                           Tableau-related queries
│
├── data-pipeline-documentation.md     Full pipeline documentation
└── README.md                          This file
```

## View execution order

Views must be created in layer order, since higher layers depend on lower ones. Within each layer, dependencies are noted in the documentation, but the general order is:

1. **Layer 1** — can be created in any order (no interdependencies)
2. **Layer 2** — `product_cost_per_box` before `product_cost_stripe`; most others are independent
3. **Layer 3** — `contribution_margin` first (most Layer 3 and 4 views depend on it), then `acquisition_details`, then lifecycle views
4. **Layer 4** — `monthly_contribution_margin` first, then `ltv_cac` and other reporting views

## Key dependencies

- **Fivetran** must be syncing for data to stay current. There are 47 connectors; see the documentation for the full inventory and status. Notable: `jp_postgres_rds` is currently paused.
- **Google Sheets** (31 worksheets) are manually maintained inputs for COGS, marketplace orders, delivery costs, opex, tax rates, and campaign mappings. See Section 4.1 of the documentation for the full list with update frequencies and impact-if-stale notes.
- **Tableau extracts** refresh on a schedule managed in Tableau Cloud. The `tableau/tableau_jobs.sql` query audits refresh status.

## Contact

Pipeline built and maintained by Dennis Chiuten at [work.flowers](https://work.flowers) (dennis@work.flowers).
