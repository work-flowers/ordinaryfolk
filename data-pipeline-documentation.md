# Ordinary Folk — Data Pipeline Documentation

**Prepared by:** Dennis Chiuten, work.flowers
**Date:** March 2026
**Scope:** BigQuery views, Fivetran sync layer, and Tableau reporting

---

## Part 1: Architecture Overview

### 1.1 Pipeline Summary

The Ordinary Folk data pipeline ingests data from multiple operational systems via Fivetran into BigQuery, transforms it through a layered set of SQL views, and surfaces metrics in Tableau dashboards. The pipeline supports a healthcare subscription business operating across Singapore, Hong Kong, and Japan with two consumer brands (Noah and Zoey).

```
┌──────────────────────────────────────────────────────────────────────┐
│                        PRIMARY DATA SOURCES                          │
│  Stripe (SG/HK/JP)  ·  Postgres (SG/HK/JP)  ·  Facebook Ads        │
│  Google Ads  ·  Taboola  ·  Segment  ·  Google Sheets (manual)      │
└──────────────────────┬───────────────────────────────────────────────┘
                       │  Fivetran
                       ▼
┌──────────────────────────────────────────────────────────────────────┐
│                     BIGQUERY RAW DATASETS                            │
│  sg_stripe / hk_stripe / jp_stripe                                   │
│  sg_postgres_rds_public / hk_postgres_rds_public / jp_postgres_…     │
│  facebook_ads  ·  google_ads  ·  taboola  ·  segment                 │
│  google_sheets (manual COGS, orders, opex, delivery, tax rates)      │
└──────────────────────┬───────────────────────────────────────────────┘
                       │  SQL Views (this document)
                       ▼
┌──────────────────────────────────────────────────────────────────────┐
│  LAYER 1 — REGIONAL UNIONS & REFERENCE                               │
│  all_stripe.*  ·  all_postgres.*  ·  ref.*  ·  cac.utm_source_map   │
├──────────────────────────────────────────────────────────────────────┤
│  LAYER 2 — ENRICHED ENTITIES                                         │
│  all_stripe.product_cost  ·  all_stripe.otc_price_id                 │
│  all_stripe.subscription_metrics_monthly                             │
│  cac.marketing_spend  ·  cac.facebook_campaign_metrics               │
├──────────────────────────────────────────────────────────────────────┤
│  LAYER 3 — CORE ANALYTICAL MODELS                                    │
│  finance_metrics.contribution_margin  ·  customer_lifecycle_monthly  │
│  finance_metrics.acquisition_details  ·  subscription_lifecycle_…     │
├──────────────────────────────────────────────────────────────────────┤
│  LAYER 4 — REPORTING AGGREGATIONS                                    │
│  finance_metrics.monthly_contribution_margin  ·  ltv_cac             │
│  finance_metrics.cm3  ·  consolidated_cm3  ·  daily_roas             │
└──────────────────────┬───────────────────────────────────────────────┘
                       │  Tableau Extracts
                       ▼
┌──────────────────────────────────────────────────────────────────────┐
│                      TABLEAU DASHBOARDS                              │
│  Monthly Metrics  ·  WBR Dash  ·  Investor & Board Dash             │
│  Facebook Campaign Details  ·  Patient Demographics                  │
│  Active Subscription Analytics  ·  Free Sample AB Testing  · etc.    │
└──────────────────────────────────────────────────────────────────────┘
```

### 1.2 Fivetran Connectors

| Connector | BigQuery Dataset(s) | Sync Notes |
|---|---|---|
| Stripe SG | `sg_stripe` | Live extract; includes charge, invoice, subscription_history, etc. |
| Stripe HK | `hk_stripe` | Live extract |
| Stripe JP | `jp_stripe` | Live extract |
| Postgres SG | `sg_postgres_rds_public` | Patient, order, evaluation, consultation, survey tables |
| Postgres HK | `hk_postgres_rds_public` | Same schema as SG |
| Postgres JP | `jp_postgres_rds_public` | Same schema as SG |
| Facebook Ads | `facebook_ads` | Campaigns, ad sets, ads, basic_ad metrics |
| Google Ads | `google_ads` | Campaign stats, criteria, account history |
| Taboola | `taboola` | Platform report, campaigns, targeting |
| Segment | `segment` | Event tracking: pages, signed_up, tracks, checkout_completed, etc. |
| Google Sheets | `google_sheets` | Manual inputs: COGS, marketplace orders, delivery costs, opex, tax rates, campaign mappings |
| Tableau (metadata) | `tableau_source` | Extract refresh tasks and workbook metadata |

### 1.3 BigQuery Datasets

| Dataset | Purpose | Populated By |
|---|---|---|
| `all_stripe` | Unified Stripe data with `region` column | Views that UNION ALL across sg/hk/jp_stripe |
| `all_postgres` | Unified application data with `region` column | Views that UNION ALL across regional postgres |
| `ref` | Lookup/reference tables (FX rates, tax history, currency subunits) | Google Sheets + views |
| `cac` | Marketing analytics (spend, ROAS, funnel metrics) | Views on top of ad platform data |
| `finance_metrics` | Core analytical models (CM, lifecycle, LTV/CAC) | Views on top of all_stripe + all_postgres + cac |

### 1.4 View Dependency Graph

The following diagram shows how views depend on one another. An arrow means "is consumed by".

```
LAYER 1 — Regional Unions & Reference
──────────────────────────────────────
vw_all_postgres_acuity ──────────────────► vw_acuity_appointment_latest
vw_all_postgres_consultation_sessions
vw_all_postgres_evaluation
vw_all_postgres_patient_evaluation
vw_all_postgres_survey
vw_all_postgres_user ────────────────────► vw_all_user_emails
vw_all_postgres_address
vw_consultation_audit
vw_consultation_sessions
vw_tax_rate_history
vw_utm_source_map

LAYER 2 — Enriched Entities
────────────────────────────
vw_product_cost_per_box ─────────────────► vw_product_cost_stripe
vw_otc_price_id
vw_payment_intent_price_id_unnested
vw_third_party_product_costs (×3)
vw_cod_sg_orders_all
vw_cod_hk_orders_all
vw_marketing_spend
vw_facebook_daily_campaign_metrics

LAYER 2.5 — Composite Entities
──────────────────────────────
vw_consultation_sessions ─┐
vw_consultation_audit ────┤
vw_utm_source_map ────────┴──────────────► vw_all_appointments_new
vw_subscription_metrics_monthly

LAYER 3 — Core Analytical Models
─────────────────────────────────
vw_product_cost_stripe ──────┐
vw_otc_price_id ─────────────┤
vw_payment_intent_… ─────────┤
vw_third_party_product_… ────┤
vw_cod_sg_orders_all ────────┤
vw_cod_hk_orders_all ────────┤
vw_tax_rate_history ─────────┴──────────► vw_contribution_margin ─────┐
                                                                      │
vw_subscription_metrics_monthly ──────► vw_acquisition_details ──┐    │
                                                                 │    │
vw_subscription_metrics_monthly ──┐                              │    │
vw_acquisition_details ───────────┴──► vw_customer_lifecycle_monthly  │
                                                                      │
vw_subscription_metrics_monthly ─────► vw_subscription_lifecycle_monthly
                                                                      │
vw_new_subscribers                                                    │
vw_subscription_renewals ◄───────────── vw_contribution_margin ◄──────┘

LAYER 4 — Reporting Aggregations
─────────────────────────────────
vw_contribution_margin ──────────────────► vw_monthly_contribution_margin
vw_contribution_margin ──────────────────► vw_cm3_new
vw_contribution_margin ──────────────────► vw_consolidated_cm3
vw_contribution_margin + vw_marketing_spend ► vw_daily_roas
vw_customer_lifecycle_monthly + vw_monthly_contribution_margin ► vw_ltv_cac
vw_subscription_lifecycle_monthly + vw_monthly_contribution_margin ► vw_ltv_cac_by_condition
vw_customer_ltv_cac_latest (snapshot)
vw_marketing_cost_per_action (funnel)
```

### 1.5 Key Conventions

**Currency handling:** All monetary amounts originate in local currency subunits (cents for SGD/HKD, units for JPY). They are converted to USD using `ref.fx_rates` and normalised from subunits using `ref.stripe_currency_subunits`.

**Multi-region pattern:** Raw data is stored per-region (`sg_stripe`, `hk_stripe`, `jp_stripe`). Layer 1 views UNION ALL these with an added `region` column. All downstream joins include `AND a.region = b.region`.

**Effective date ranges:** Cost, tax, and FX rate tables use `from_date`/`to_date` ranges computed with `LEAD()` window functions. Downstream views join with `BETWEEN from_date AND to_date`.

**Deduplication:** Fivetran SCD Type 2 tables (e.g. `subscription_history`) are deduplicated with `QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY _fivetran_end DESC) = 1`.

**Condition grouping:** Medical conditions are standardised: ED and PE are grouped as "ED + PE"; Brand, OTC, Smoking Cessation, and Sex Toys are grouped as "Other".

**New vs Existing customers:** A customer is "New" if their purchase date is within 7 days of their acquisition date (first-ever purchase). Otherwise "Existing".

---

## Part 2: Detailed View Reference

### Layer 1 — Regional Unions & Reference

#### `all_postgres.acuity_appointment`
**File:** `vw_all_postgres_acuity.sql`
**Purpose:** Regional union of Acuity appointment data.
**Sources:** `sg_postgres_rds_public.acuity_appointment`, `hk_postgres_rds_public.acuity_appointment`, `jp_postgres_rds_public.acuity_appointment`
**Logic:** Simple UNION ALL with `region` column added. Also creates `all_postgres.order_acuity_appointment`.

#### `all_postgres.acuity_appointment_latest`
**File:** `vw_acuity_appointment_latest.sql`
**Purpose:** Most recent version of each appointment record.
**Sources:** `all_postgres.acuity_appointment`
**Logic:** `QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY updated_at DESC) = 1`
**Depends on:** `vw_all_postgres_acuity.sql`

#### `all_postgres.address`
**File:** `vw_all_postgres_address.sql`
**Purpose:** Regional union of address data.
**Sources:** Regional address tables from SG, HK, JP.
**Logic:** UNION ALL with `region` column.

#### `all_postgres.consultation_sessions`
**File:** `vw_all_postgres_consultation_sessions.sql` / `vw_consultation_sessions.sql`
**Purpose:** Consolidated consultation session data with explicit column selection.
**Sources:** Regional `consultation_sessions` tables from SG, HK, JP.
**Key columns:** `region`, `sys_id`, `created_at`, `consultation_session_type`, `order_sys_id`, `consultation_session_status`, `progress_status`, `prescribed_at`

#### `all_postgres.consultation_audit`
**File:** `vw_consultation_audit.sql`
**Purpose:** Regional union of consultation audit records.
**Sources:** Regional `consultation_audit` tables from SG, HK, JP.

#### `all_postgres.evaluation`
**File:** `vw_all_postgres_evaluation.sql`
**Purpose:** Regional union of evaluation (medical questionnaire) records.
**Sources:** Regional `evaluation` tables.

#### `all_postgres.patient_evaluation`
**File:** `vw_all_postgres_patient_evaluation.sql`
**Purpose:** Regional union of patient evaluation data.
**Sources:** Regional `patient_evaluation` tables.

#### `all_postgres.survey`
**File:** `vw_all_postgres_survey.sql`
**Purpose:** Regional union of survey responses.
**Sources:** Regional `survey` tables.

#### `all_postgres.user`
**File:** `vw_all_postgres_user.sql`
**Purpose:** Regional union of user records.
**Sources:** Regional `user` tables.

#### `all_postgres.user_emails`
**File:** `vw_all_user_emails.sql`
**Purpose:** Deduplicated users by email, keeping the most recent record.
**Sources:** `all_postgres.user`
**Key columns:** `email`, `sys_id`, `utm_source`
**Logic:** `QUALIFY ROW_NUMBER() OVER (PARTITION BY email ORDER BY updated_at DESC) = 1`
**Depends on:** `vw_all_postgres_user.sql`

#### `ref.tax_rate_history`
**File:** `vw_tax_rate_history.sql`
**Purpose:** GST/VAT rate history with effective date ranges by region.
**Sources:** `google_sheets.tax_rates`
**Key columns:** `region`, `from_date`, `to_date`, `rate`
**Logic:** Uses `LEAD(effective_from)` to compute `to_date`, defaulting to `'9999-12-31'`.

#### `cac.utm_source_map`
**File:** `vw_utm_source_map.sql`
**Purpose:** Maps raw UTM campaign sources to standardised marketing channels.
**Sources:** `segment.pages`
**Key columns:** `context_campaign_source`, `channel`
**Logic:** Case-insensitive LIKE matching maps 14 source patterns to channels (e.g. `facebook` → `facebook_ads`, `google` → `google_ads`, `taboola` → `taboola`, `chatgpt`, `menarini`, `edm`, etc.). Unmatched sources pass through as-is.

---

### Layer 2 — Enriched Entities

#### `all_stripe.product_cost_per_box`
**File:** `vw_product_cost_per_box.sql`
**Purpose:** Regional product cost and packaging data with effective date ranges.
**Sources:** `google_sheets.sg_product_cost_stripe`, `google_sheets.hk_product_cost_stripe`, `google_sheets.jp_product_cost_stripe`
**Key columns:** `region`, `product_id`, `cost_box`, `packaging_cost`, `from_date`, `to_date`
**Logic:** UNION of three regional sources. Computes `to_date` as `LEAD(effective_date) - 1` partitioned by `id`, defaulting to `'9999-12-31'`.

#### `all_stripe.product_cost`
**File:** `vw_product_cost_stripe.sql`
**Purpose:** Complete product cost view: COGS = cost per box × number of boxes.
**Sources:** `all_stripe.product_cost_per_box`, `all_stripe.price`
**Key columns:** `region`, `product_id`, `price_id`, `from_date`, `to_date`, `currency`, `cogs`, `packaging`, `cashback` (fixed 2%)
**Logic:** Joins price metadata to extract `$.boxes` (defaults to 1). COGS = `cost_box * n_boxes`.
**Depends on:** `vw_product_cost_per_box.sql`

#### `all_stripe.otc_price_id`
**File:** `vw_otc_price_id.sql`
**Purpose:** Extracts price IDs and quantities from one-time charge payment intent descriptions.
**Sources:** `all_stripe.payment_intent`
**Key columns:** `payment_intent_id`, `price_id`, `quantity`, `discount_amount_local`, `shipping_amount_local`
**Logic:** Uses `REGEXP_EXTRACT_ALL` to find patterns like `price-[a-zA-Z0-9]+) x \d+` in descriptions. UNNESTs to one row per price ID.

#### `all_stripe.payment_intent_price_id`
**File:** `vw_payment_intent_price_id_unnested.sql`
**Purpose:** Extracts and unnests comma-separated price IDs from payment intent metadata.
**Sources:** `all_stripe.payment_intent`
**Key columns:** `payment_intent_id`, `price_id`
**Logic:** Checks three metadata fields in order: `paymentIntentPriceId`, `stripePriceIds`, `priceIds`. SPLITs on commas and UNNESTs.

#### `finance_metrics.tiktok_product_costs` / `shopee_product_costs` / `lazada_product_costs`
**File:** `vw_third_party_product_costs.sql`
**Purpose:** Marketplace product costs with effective date ranges (three separate views).
**Sources:** `google_sheets.tiktok_cogs`, `google_sheets.shopee_cogs`, `google_sheets.lazada_cogs`
**Logic:** Each view computes effective date ranges using `LEAD()`. Partitioned by platform-specific SKU columns.

#### `finance_metrics.cod_sg_orders_all`
**File:** `vw_cod_sg_orders_all.sql`
**Purpose:** Consolidated Singapore Cash-on-Delivery orders.
**Sources:** `google_sheets.cod_sg_revenue_pre_2025`, `google_sheets.cod_sg_revenue`
**Logic:** Simple UNION of pre-2025 legacy data and current revenue data.

#### `finance_metrics.cod_hk_orders_all`
**File:** `vw_cod_hk_orders_all.sql`
**Purpose:** Consolidated Hong Kong Cash-on-Delivery orders from multiple sources.
**Sources:** `google_sheets.cod_hk_revenue_pre_2025`, `google_sheets.sf_express_airway_bills`, `google_sheets.sf_express_line_items`, `google_sheets.hk_product_cost_stripe`
**Logic:** Two data sources: legacy pre-2025 data and SF Express bills. Prorates service charges proportionally by revenue.

#### `cac.marketing_spend`
**File:** `vw_marketing_spend.sql`
**Purpose:** Consolidated marketing spend across all ad platforms.
**Sources:** `google_ads.*`, `facebook_ads.*`, `taboola.*`, `google_sheets.manual_ad_spend`, `google_sheets.campaign_condition_map`, `ref.fx_rates`
**Key columns:** `channel`, `brand`, `date`, `campaign_name`, `condition`, `country_code`, `cost_local`, `cost_usd`, `clicks`, `impressions`, `reach`
**Logic:** UNION of four platform-specific blocks:

- **Google Ads:** Converts `cost_micros` to standard currency; maps campaigns to conditions via `campaign_condition_map`.
- **Facebook Ads:** Extracts country from multiple nested JSON targeting fields; calculates clicks from CTR; filters to Zoey/Noah brands only.
- **Taboola:** All spend attributed to Noah brand; prorates service charges.
- **Manual:** Direct entry of spend data from Google Sheets.

All platforms convert to USD via `ref.fx_rates`.

#### `cac.facebook_campaign_metrics`
**File:** `vw_facebook_daily_campaign_metrics.sql`
**Purpose:** Facebook Ads performance aggregated by date, campaign, and condition.
**Sources:** `facebook_ads.campaign_history`, `facebook_ads.ad_history`, `facebook_ads.account_history`, `facebook_ads.ad_set_history`, `facebook_ads.basic_ad*`, `google_sheets.campaign_condition_map`
**Key columns:** `date`, `ad_id`, `campaign_id`, `campaign_name`, `condition`, `brand`, `country`, `spend`, `purchase_volume`, `purchase_revenue`, `impressions`
**Logic:** Uses QUALIFY to get latest versions of campaigns, ads, ad sets, and accounts. Joins revenue and purchase volume separately. Filters to SGD currency accounts only. Includes CPR threshold from `marketing_thresholds`.

#### `all_stripe.subscription_metrics_monthly`
**File:** `vw_subscription_metrics_monthly.sql`
**Purpose:** Monthly subscription-level revenue and customer type data with time series generation.
**Sources:** `all_stripe.subscription_history`, `all_stripe.subscription_details`, `all_postgres.patient`, `finance_metrics.contribution_margin`, `ref.fx_rates`
**Key columns:** `subscription_id`, `customer_id`, `region`, `status`, `obs_date`, `mrr_local`, `mrr_usd`, `brand`, `condition`, `new_existing`, `first_condition`
**Logic:**
- Generates a monthly time series for every month between subscription start and end using `GENERATE_ARRAY` + `UNNEST`.
- Handles July 2024 bulk cancellations specially (uses `last_paid` date instead of `ended_at`).
- Sets MRR to 0 for months after cancellation.
- Derives `new_existing`: "New" if first purchase date < subscription start, else "Existing".
- Maps `customer_id` to brand from `patient` table.

#### `all_postgres.atome_parsed`
**File:** `vw_atome_parsed.sql`
**Purpose:** Parses nested JSON from Atome BNPL payments and order calculations.
**Sources:** `sg_postgres_rds_public.atome_payments`, `all_postgres.order`
**Key columns:** `external_platform_id`, `created_at`, `atome_status`, `order_status`, `amount`, `refundableAmount`, `payment_tenor`, plus 20+ fields from nested `prescription_order_calculation` JSON.
**Logic:** Handles both object and array JSON formats with COALESCE for flexibility.

#### `all_postgres.all_appointments`
**File:** `vw_all_appointments_new.sql`
**Purpose:** Merges consultation sessions with order and audit data.
**Sources:** `all_postgres.consultation_sessions`, `all_postgres.order`, `all_postgres.consultation_audit`, `google_sheets.postgres_stripe_condition_map`, `cac.utm_source_map`
**Key columns:** `region`, `date`, `consult_sys_id`, `order_short_id`, `patient_id`, `condition`, `utm_source`, `has_prescription`, `has_subscription`
**Logic:** Maps Postgres conditions to Stripe conditions; extracts UTM source from order metadata with fallback.
**Depends on:** `vw_consultation_sessions.sql`, `vw_consultation_audit.sql`, `vw_utm_source_map.sql`

---

### Layer 3 — Core Analytical Models

#### `finance_metrics.contribution_margin`
**File:** `vw_contribution_margin.sql`
**Purpose:** The central revenue and cost dataset — unified transaction-level data across all seven sales channels with detailed line-item breakdown.
**Sources:** Stripe tables (`charge`, `invoice`, `payment_intent`, `balance_transaction`, `product_cost`), Google Sheets marketplace tables (`tiktok_orders`, `shopee_orders`, `lazada_orders`, `atome_manual`), COD views (`cod_sg_orders_all`, `cod_hk_orders_all`), reference tables (`fx_rates`, `tax_rate_history`)
**Key columns:** `sales_channel`, `region`, `purchase_date`, `purchase_type`, `billing_reason`, `customer_id`, `charge_id`, `product_id`, `product_name`, `condition`, `brand`, `quantity`, `line_item_amount_usd`, `total_charge_amount_usd`, `cogs`, `packaging`, `cashback`, `fee_rate`, `gst_vat`, `refund_rate`, `amount_refunded_usd`, `acquisition_date`, `new_existing`, `subscription_id`, `subscription_created_date`
**Logic (9 major CTEs):**

1. **Stripe subscriptions:** Joins charge → invoice → invoice_line_item → price → product → product_cost. Prorates line item amounts based on invoice breakdown. Extracts condition from product metadata.
2. **Stripe one-time charges:** Uses price ID fallback chain across `invoice_line_item`, `otc_price_id`, and `payment_intent` metadata.
3. **TikTok / Shopee / Lazada:** Aggregates by order with platform-specific fee calculations. Joins to third-party product cost tables with date ranges.
4. **Atome:** Groups transactions by order, handles BNPL-specific fees.
5. **COD SG / COD HK:** Reads from the COD order views.
6. **Acquisition tagging:** Computes `acquisition_date` (first purchase per customer) and tags `new_existing` based on 7-day window.

All channels output identical column structures and are UNIONed.
**Depends on:** `vw_product_cost_stripe.sql`, `vw_otc_price_id.sql`, `vw_payment_intent_price_id_unnested.sql`, `vw_third_party_product_costs.sql`, `vw_cod_sg_orders_all.sql`, `vw_cod_hk_orders_all.sql`, `vw_tax_rate_history.sql`

#### `finance_metrics.acquisition_details`
**File:** `vw_acquisition_details.sql`
**Purpose:** Identifies when each customer was first acquired and their associated condition.
**Sources:** `all_stripe.subscription_metrics`
**Key columns:** `customer_id`, `region`, `condition`, `acquired_date`
**Logic:** Finds first date where customer had MRR > 0. Applies standard condition grouping. Ranks by MRR amount when multiple entries exist for the same acquisition date.

#### `finance_metrics.customer_lifecycle_monthly`
**File:** `vw_customer_lifecycle_monthly.sql`
**Purpose:** Enhanced monthly customer lifecycle states with condition and brand dimensions.
**Sources:** `all_stripe.subscription_metrics_monthly`, `finance_metrics.acquisition_details`
**Key columns:** `region`, `obs_date`, `acq_date`, `customer_id`, `brand`, `condition`, `lifecycle`, `n_customers`, `current_mrr`, `lagged_mrr`
**Logic:** Uses `LAG(mrr_usd)` to compute month-over-month MRR changes. Lifecycle states:

- **New** — first month with MRR > 0
- **Churn** — current MRR = 0, lagged MRR > 0
- **Reactivation** — current MRR > 0, lagged MRR = 0, not the acquisition month
- **Expansion** — current MRR > lagged MRR (both > 0)
- **Contraction** — current MRR < lagged MRR (both > 0)
- **Retention** — current MRR = lagged MRR (both > 0)

Filters to rows where `current_mrr > 0 OR lagged_mrr > 0`. Aggregates by region, date, lifecycle, condition, brand.
**Depends on:** `vw_subscription_metrics_monthly.sql`, `vw_acquisition_details.sql`

#### `finance_metrics.customer_lifecycle_monthly_test`
**File:** `vw_customer_lifecycle_monthly_test.sql`
**Purpose:** Alternative lifecycle calculation with special handling for cancelled subscriptions.
**Sources:** `all_stripe.subscription_metrics`, `finance_metrics.acquisition_details`, `all_postgres.patient`
**Logic:** For cancelled subs with zero MRR, moves `obs_date` to first of next month. Derives acquisition date as `MIN(obs_date)` where MRR > 0 per customer.
**Note:** Test/alternative version — may diverge from the primary `customer_lifecycle_monthly`.

#### `finance_metrics.subscription_lifecycle_monthly`
**File:** `vw_subscription_lifecycle_monthly.sql`
**Purpose:** Monthly subscription-level (not customer-level) lifecycle states.
**Sources:** `all_stripe.subscription_metrics`
**Key columns:** `region`, `obs_date`, `lifecycle`, `condition`, `n_subscriptions`, `current_mrr`, `lagged_mrr`
**Logic:** Same lifecycle classification as `customer_lifecycle_monthly` but at the subscription grain. For cancelled subs, moves `obs_date` to first of next month. Derives `acq_date` per subscription as `MIN(obs_date)` where MRR > 0.

#### `finance_metrics.customer_lifecyle` (note: typo in view name)
**File:** `vw_customer_lifecycle.sql`
**Purpose:** Simplified monthly customer lifecycle states (no condition/brand dimensions).
**Sources:** `all_stripe.subscription_metrics`
**Key columns:** `region`, `obs_date`, `lifecycle`, `n_customers`, `current_mrr`, `lagged_mrr`
**Note:** Older/simpler version of `customer_lifecycle_monthly`.

#### `finance_metrics.new_subs`
**File:** `vw_new_subscribers.sql`
**Purpose:** Identifies truly new subscribers — customers with no purchases in the 7 days prior to subscription creation.
**Sources:** `all_stripe.subscription_history`, `all_stripe.subscription_item`, `all_stripe.plan`, `all_stripe.product`, `all_stripe.charge`
**Key columns:** `customer_id`, `region`, `first_sub_created`, `condition`
**Logic:** Gets first active subscription per customer. LEFT JOINs charges and only keeps rows where NO charge exists in the 7 days before subscription creation.

#### `all_stripe.subscription_renewals`
**File:** `vw_subscription_renewals.sql`
**Purpose:** Tracks renewal metrics for subscriptions in the first 90 days.
**Sources:** `finance_metrics.contribution_margin`
**Key columns:** `region`, `created_date`, `subscription_id`, `condition`, `n_charges_in_first_90d`, `amount_usd_in_first_90d`
**Logic:** Finds first charge date per subscription, then counts charges and sums amounts within a 90-day window (excluding the initial creation charge).
**Depends on:** `vw_contribution_margin.sql`

---

### Layer 4 — Reporting Aggregations

#### `finance_metrics.monthly_contribution_margin`
**File:** `vw_monthly_contribution_margin.sql`
**Purpose:** Monthly P&L with sales, marketing, delivery, and opex blocks. The primary financial reporting view.
**Sources:** `finance_metrics.contribution_margin`, `cac.marketing_spend`, `google_sheets.delivery_cost`, `google_sheets.opex`, `ref.fx_rates`
**Key columns:** `source`, `date`, `country`, `condition`, `sales_channel`, `brand`, `amount` (gross revenue), `cogs`, `packaging`, `cashback`, `tax_paid_usd`, `gateway_fees`, `refunds`, `marketing_cost`, `delivery_cost`, `dispensing_fees`, `operating_expense`, `staff_cost`, `gross_revenue`, `net_revenue`, `gross_profit`, `cm2`, `cm3`, `ebitda`
**Logic:** Five separate UNION blocks:

1. **Sales** — aggregates `contribution_margin` by month/country/condition/brand
2. **Marketing** — zero-amount rows with `marketing_cost` populated
3. **Delivery** — zero-amount rows with `delivery_cost` populated
4. **Opex** — dispensing fees, staff costs, operating expenses, teleconsultation fees
5. **Teleconsult COGS** — treats teleconsultation fees as COGS for the "Services" condition

Final SELECT computes margin waterfall: `net_revenue` → `gross_profit` → `cm2` → `cm3` → `ebitda`.
**Depends on:** `vw_contribution_margin.sql`

#### `finance_metrics.cm3`
**File:** `vw_cm3_new.sql`
**Purpose:** Transaction-level CM3 — revenue minus COGS, packaging, delivery, payment fees, and marketing costs.
**Sources:** `finance_metrics.contribution_margin`, `google_sheets.delivery_cost`, `cac.marketing_spend`, `google_sheets.opex`, `ref.fx_rates`
**Key columns:** `revenue`, `cogs`, `packaging`, `cashback`, `tax_paid_usd`, `payment_gateway_fees`, `refunds`, `delivery_cost`, `marketing_cost`, `running_revenue`
**Logic:** Prorates delivery, marketing, and opex costs by revenue within specific dimensions (country/condition/date). Computes running revenue per customer/charge/condition/country.
**Depends on:** `vw_contribution_margin.sql`

#### `finance_metrics.consolidated_cm3`
**File:** `vw_consolidated_cm3.sql`
**Purpose:** Complete P&L statement with all costs allocated and CM3 calculated.
**Sources:** Same as `cm3` above.
**Key columns:** `gross_revenue`, `net_revenue`, `gross_profit`, `cm2`, `cm3`, `cogs`, `delivery_cost`, `marketing_cost`, `dispensing_fees`, `operating_expense`, `staff_cost`
**Logic:** Treats Services condition specially (teleconsultation fees as COGS). Prorates costs by revenue. Computes multiple margin levels.
**Depends on:** `vw_contribution_margin.sql`

#### `cac.daily_roas`
**File:** `vw_daily_roas.sql`
**Purpose:** Daily Return on Ad Spend by condition, brand, and country.
**Sources:** `cac.marketing_spend`, `finance_metrics.contribution_margin`
**Key columns:** `date`, `country`, `condition`, `brand`, `marketing_spend`, `impressions`, `clicks`, `revenue`, `n_new_customers`, `first_purchase_amount`
**Logic:** Creates a complete key space (all date/condition/country/brand combinations from both tables) then LEFT JOINs both marketing and sales data to avoid missing combinations. Groups ED+PE together.
**Depends on:** `vw_marketing_spend.sql`, `vw_contribution_margin.sql`

#### `finance_metrics.ltv_cac`
**File:** `vw_ltv_cac.sql`
**Purpose:** Combined customer lifecycle and financial metrics for LTV/CAC analysis.
**Sources:** `finance_metrics.customer_lifecycle_monthly`, `finance_metrics.monthly_contribution_margin`
**Key columns:** `region`, `obs_date`, `condition`, `brand`, `n_new_customers`, `current_mrr`, `n_churned_customers`, `churned_mrr`, `net_revenue`, `cogs`, `marketing_cost`, `lagged_n_customers`
**Logic:** FULL OUTER JOIN between lifecycle and gross margin data. Filters to SG, HK, JP. Excludes Services condition. Includes lagged customer count for churn rate calculations.
**Depends on:** `vw_customer_lifecycle_monthly.sql`, `vw_monthly_contribution_margin.sql`

#### `finance_metrics.ltv_cac_by_condition`
**File:** `vw_ltv_cac_by_condition.sql`
**Purpose:** LTV/CAC metrics at subscription and condition level (rather than customer level).
**Sources:** `finance_metrics.subscription_lifecycle_monthly`, `finance_metrics.monthly_contribution_margin`
**Key columns:** `region`, `obs_date`, `condition`, `n_new_subscriptions`, `current_mrr`, `n_churned_subscriptions`, `churned_mrr`, `net_revenue`, `cogs`, `marketing_cost`
**Logic:** Uses `subscription_lifecycle_monthly` instead of `customer_lifecycle_monthly`. Includes base (prior month) subscription counts and MRR for growth calculations.
**Depends on:** `vw_subscription_lifecycle_monthly.sql`, `vw_monthly_contribution_margin.sql`

#### `finance_metrics.customer_ltv_cac_latest`
**File:** `vw_customer_ltv_cac_latest.sql`
**Purpose:** Current-day snapshot of customer metrics for the LTV/CAC dashboard.
**Sources:** `all_stripe.subscription_metrics`, `finance_metrics.monthly_contribution_margin`, `cac.marketing_spend`
**Key columns:** `region`, `total_current_mrr`, `total_lagged_mrr`, `n_active_customers`, `n_churned_customers`, `n_new_customers`, `new_mrr`, `net_revenue`, `gross_profit`, `marketing_spend`, `n_acq_gross`
**Logic:** Snapshots current day (`obs_date = CURRENT_DATE()`), compares to 30 days prior, derives lifecycle states, includes month-to-date revenue and marketing spend.

#### `cac.marketing_cost_per_action`
**File:** `vw_marketing_cost_per_action.sql`
**Purpose:** Marketing spend and funnel action metrics by date, channel, and condition.
**Sources:** `finance_metrics.contribution_margin`, `segment.signed_up`, `segment.tracks`, `segment.viewed_4_th_question_of_eval`, `segment.checkout_completed`, `all_postgres.order`, `all_postgres.all_appointments`, `cac.marketing_spend`, `cac.utm_source_map`, `google_sheets.postgres_stripe_condition_map`
**Key columns:** `date`, `country`, `channel`, `condition`, `ad_impressions`, `cost_usd`, `clicks`, `n_signups`, `n_q3_completions`, `n_checkouts_completed`, `n_consults`
**Logic:** Tracks 5 funnel stages: signups → Q3 completions (evaluation progress) → checkouts (with teleconsultation) → consults → spend. Filters checkouts to only those with Teleconsultation product. Creates superset of all dimension combinations.
**Depends on:** `vw_contribution_margin.sql`, `vw_all_appointments_new.sql`, `vw_marketing_spend.sql`, `vw_utm_source_map.sql`

---

## Part 3: Tableau Dashboard Mapping

### 3.1 Workbooks and Their Views

#### Monthly Metrics (`ecd5e0f4`)
The primary subscription and financial metrics workbook with 13 sheets:

| Sheet | Description |
|---|---|
| MRR Change Breakdown | Month-over-month MRR movement by lifecycle state |
| Current MRR | Current MRR snapshot |
| Cumulative Charge History | Cumulative charges over time |
| Financial Ratios | Key financial ratio trends |
| Marketing Efficiency | Marketing efficiency metrics |
| Revenue and Customer Count | Revenue trends alongside customer counts |
| Quarterly Metrics | Quarterly aggregated metrics |
| Customer LTV Metrics | Customer-level LTV calculations |
| Subscription LTV Metrics | Subscription-level LTV calculations |
| Cumulative CM1/CAC and CM2/CAC | Payback period visualisation |
| Customer Retention | Retention cohort analysis |
| Average Order Value | AOV trends |
| Transactions per Customer, Last 36 Months | Purchase frequency analysis |

#### WBR Dash (`321684a1`)
Weekly Business Review dashboard with 8 sheets:

| Sheet | Description |
|---|---|
| Metrics Snapshot | Top-level KPI summary |
| Acquisition | New customer acquisition metrics |
| Retention | Customer retention and churn |
| Repeat Purchase | Repeat purchase rates |
| Consult – Subscription Conversion | Conversion from consultations to subscriptions |
| Subscription Upgrades | Plan upgrade tracking |
| Subscription Interval Upgrades | Interval change tracking (e.g. monthly → quarterly) |
| Marketing Funnel | Full funnel from impressions to purchase |

#### Investor and Board Dash (`23fde0d0`)
| Sheet | Description |
|---|---|
| Board: Revenue | Revenue overview for board reporting |
| Investor Update | Investor-facing metrics summary |

#### Facebook Campaign Details Dash (`b88ed2d0`)
| Sheet | Description |
|---|---|
| Facebook Campaign Details | Granular Facebook ad campaign performance |

#### How Did You Hear About Us (`937b061a`)
| Sheet | Description |
|---|---|
| Survey Responses | Attribution survey analysis |

#### Free Sample AB Testing (`85265022`)
| Sheet | Description |
|---|---|
| AOV | Average order value for test cohorts |
| Cross-Sell | Cross-sell rates between conditions |

#### Active Subscription Analytics (`02d4dc57`)
| Sheet | Description |
|---|---|
| Snapshot | Current active subscription overview |
| Maturity Analysis | Subscription age/maturity distribution |

#### Cancellation Survey Responses (`a086410b`)
| Sheet | Description |
|---|---|
| Question 1 | Cancellation reason analysis |

#### Patient Demographics (`d6785152`)
| Sheet | Description |
|---|---|
| Users | User overview |
| Age Distribution | Age distribution of patients |
| Japan Geographic Distribution | Geographic distribution within Japan |

#### Regional Demographics (`b1ac4d90`)
| Sheet | Description |
|---|---|
| Age Distributions | Cross-region age comparison |
| Geographic Distribution | Geographic distribution across regions |

### 3.2 Data Sources and Their BigQuery Origins

The following table maps each Tableau published data source to the BigQuery view(s) that most likely power it.

| Tableau Data Source | Likely BigQuery View(s) | Used By |
|---|---|---|
| Contribution Margin Main Data Set | `finance_metrics.contribution_margin` | Monthly Metrics, WBR Dash |
| Monthly Contribution Margins | `finance_metrics.monthly_contribution_margin` | Monthly Metrics, Investor & Board Dash |
| LTV and CAC Metrics | `finance_metrics.ltv_cac` | Monthly Metrics |
| Customer LTV and CAC Inputs | `finance_metrics.ltv_cac` / `ltv_cac_by_condition` | Monthly Metrics |
| Current Customer LTV/CAC | `finance_metrics.customer_ltv_cac_latest` | Monthly Metrics |
| Subscriber Lifecycle Monthly | `finance_metrics.subscription_lifecycle_monthly` | Monthly Metrics |
| Subscription Data | `all_stripe.subscription_metrics_monthly` | Monthly Metrics, WBR Dash |
| Customer Acquisition Cost (CAC) | `cac.marketing_spend` | WBR Dash, Monthly Metrics |
| Daily ROAS | `cac.daily_roas` | WBR Dash |
| 3-Month ROAS | `all_stripe.subscription_renewals` + `cac.marketing_spend` | WBR Dash |
| Marketing Cost per Action | `cac.marketing_cost_per_action` | WBR Dash |
| Ad Metrics | `cac.marketing_spend` (aggregated) | WBR Dash |
| Facebook Creatives | `cac.facebook_campaign_metrics` | Facebook Campaign Details Dash |
| New Subscribers | `finance_metrics.new_subs` | WBR Dash |
| Subscription Renewals | `all_stripe.subscription_renewals` | WBR Dash |
| Net New Customer Acquisition Cost (nCAC) | `cac.marketing_spend` + `finance_metrics.contribution_margin` | Monthly Metrics |
| Direct Variable Cost | `finance_metrics.cm3` / `consolidated_cm3` | Monthly Metrics |
| Consultations | `all_postgres.all_appointments` | WBR Dash |
| Acuity Appointments | `all_postgres.acuity_appointment_latest` | WBR Dash |
| Order Completions | `all_postgres.order` (direct) | WBR Dash |
| Segment Pages | `segment.pages` (direct Fivetran table) | WBR Dash |
| Evaluation Starts and Q4 Views | `segment.tracks` / `segment.viewed_4_th_question_of_eval` | WBR Dash |
| Cost per Q3 Completion | `cac.marketing_cost_per_action` | WBR Dash |
| Views by Country and Condition | `segment.pages` (aggregated) | WBR Dash |
| Subscription Interval Changes | `all_stripe.subscription_history` (direct) | WBR Dash |
| Interval Upgrades (Normalised) | `all_stripe.subscription_history` (transformed) | WBR Dash |
| Upgrade Intent | `all_postgres.survey` / `segment.tracks` | Active Subscription Analytics |
| TOR Attendance | `all_postgres.consultation_sessions` | WBR Dash |

### 3.3 Extract Refresh

Tableau extract refreshes are managed via scheduled tasks stored in `tableau_source.extract_refresh_task` (synced by Fivetran). The `tableau_jobs.sql` query can be used to audit which data sources and workbooks have scheduled refreshes and when they are next due.

---

## Part 4: Operational Notes

### 4.1 Google Sheets Manual Inputs

The following Google Sheets are used as manual data inputs via the Fivetran Google Sheets connector. These must be maintained by the Ordinary Folk team after handover:

| Sheet | Purpose | Update Frequency |
|---|---|---|
| `sg_product_cost_stripe` / `hk_…` / `jp_…` | Product COGS per box by region | When costs change |
| `tiktok_cogs` / `shopee_cogs` / `lazada_cogs` | Marketplace product costs | When costs change |
| `tiktok_orders` / `shopee_orders` / `lazada_orders` | Marketplace order data | Ongoing (manual entry) |
| `atome_manual` | Atome BNPL transaction data | Ongoing |
| `cod_sg_revenue` / `cod_hk_revenue_pre_2025` etc. | Cash-on-delivery orders | Ongoing |
| `delivery_cost` | Shipping costs by date/country | Monthly |
| `opex` | Operating expenses (dispensing, staff, teleconsult) | Monthly |
| `tax_rates` | GST/VAT rates by region | When rates change |
| `campaign_condition_map` | Maps ad campaigns to medical conditions | When new campaigns launch |
| `manual_ad_spend` | Manual ad spend entries (non-API platforms) | As needed |
| `postgres_stripe_condition_map` | Maps Postgres condition names to Stripe condition names | Rarely |
| `sf_express_airway_bills` / `sf_express_line_items` | HK COD shipping data | Ongoing |

### 4.2 Known Quirks and Edge Cases

- **July 2024 bulk cancellations:** `vw_subscription_metrics_monthly.sql` has special handling for subscriptions cancelled in July 2024 — it uses the `last_paid` date instead of `ended_at` to avoid a spike in churn metrics.
- **View name typo:** `finance_metrics.customer_lifecyle` (missing an "c") in `vw_customer_lifecycle.sql`. Do not rename without updating downstream references.
- **Duplicate view definitions:** `vw_appointments_orders.sql` and `vw_all_appointments_new.sql` both create `all_postgres.all_appointments`. Only the latter should be considered current.
- **Test view:** `vw_customer_lifecycle_monthly_test.sql` creates `finance_metrics.customer_lifecycle_monthly_test` — an alternative version with slightly different acquisition date logic. This is not used in production dashboards.
- **Stripe price ID fallback chain:** In `vw_contribution_margin.sql`, the price ID for one-time charges is resolved through a multi-step fallback: `invoice_line_item.price_id` → `otc_price_id.price_id` → `payment_intent.metadata.priceIds` → `payment_intent.metadata.stripePriceIds` → `payment_intent.metadata.paymentIntentPriceId`.
- **Services condition:** In the monthly contribution margin and consolidated CM3 views, teleconsultation fees are treated as COGS for the "Services" condition rather than as operating expenses.
- **Fixed cashback rate:** Product cost views apply a hardcoded 2% cashback rate (`0.02`).

### 4.3 Maintenance Checklist

After handover, the Ordinary Folk team should:

1. **Keep Google Sheets updated** — marketplace orders, COGS, delivery costs, and opex must be entered regularly for financial reporting to remain accurate.
2. **Monitor Fivetran syncs** — all connectors (Stripe ×3, Postgres ×3, Facebook Ads, Google Ads, Taboola, Segment, Google Sheets) should sync successfully on their configured schedules.
3. **Monitor Tableau extract refreshes** — use the `tableau_jobs.sql` query or Tableau Server admin to verify extracts are refreshing.
4. **Update campaign_condition_map** — when new ad campaigns are created, add mappings to this sheet so spend is attributed to the correct medical condition.
5. **Update cost tables** — when product costs, tax rates, or delivery costs change, add new rows with the new effective date. The views will automatically compute the `to_date` using `LEAD()`.
6. **Review FX rates** — `ref.fx_rates` contains annual average rates. Update annually or if significant currency movements occur.
