# Known Data Model & Postgres Issues

This document catalogues the systemic data model issues encountered during the work.flowers engagement (Feb 2025 – Mar 2026). These are structural problems rather than one-off bugs; most remain unresolved and will continue to affect reporting accuracy until addressed at the application or infrastructure level.

---

## 1. Postgres ↔ Stripe linkage is unreliable

The `order` table in Postgres has two columns that should connect orders to Stripe payments — `stripe_payment_intent_id` and `utmSource` — but both are empty for roughly 90% of records. This makes it impossible to reliably join Stripe charges to internal order data, which in turn blocks accurate revenue attribution by product/condition and any form of marketing attribution.

**Workarounds attempted:**

- For recurring subscriptions, the `invoice_id` on the Stripe charge object can be joined to invoice line items, which in turn carry an `orderId` in their metadata. This works for the majority of subscription revenue.
- For one-time purchases (processed via Webflow's Stripe integration), the `price_id` and quantity are stored in an unstructured Description field on the payment intent. A BigQuery view (`vw_otc_price_id.sql`) parses this with regex.
- Peter identified that the `latest_invoice` JSONB column on Postgres order rows contains the Stripe invoice ID, offering another join path — but its completeness has not been verified.

**Impact:** A material share of revenue (particularly one-time purchases and newer products like Wegovy) remains unattributed to any product or condition in the financial model.

**References:** Slack thread 06 Aug 2025 (Peter's Stripe metadata analysis), Linear WFOF-265, WFOF-286

---

## 2. Inconsistent and duplicated Stripe metadata

Stripe object metadata is riddled with inconsistencies that undermine any attempt at programmatic analysis:

- Duplicate keys with different casing and different values on the same object (e.g. `charge_purpose` vs `chargePurpose`, `condition` vs `Condition`).
- Multiple fields for the same concept (`priceIds` and `stripePriceIds`) that sometimes disagree.
- The `requires_prescription` flag is set on teleconsultation products — but teleconsultations exist precisely to *grant* prescriptions, creating a logical impossibility.
- Price ID was historically used to identify products, but a single product can have multiple prices. This caused a double-charging bug where a long-standing subscriber was charged twice after a follow-up consultation assigned a different (lower-cost) price for the same medication.
- Product metadata (e.g. `condition`) was not consistently populated when new products were launched. There was no SOP requiring it, so new SKUs would appear as unattributed revenue until someone noticed and manually updated Stripe.

**Impact:** Revenue attribution, condition classification, and product-level reporting are all affected. Any downstream consumer of Stripe metadata must handle edge cases defensively.

**References:** DMs with Peter (Sep–Oct 2025), Slack channel (Aug–Sep 2025), Linear WFOF-272

---

## 3. JP Postgres → BigQuery sync (Fivetran) is architecturally fragile

The Fivetran connector for the Japan Postgres database broke silently on 17 August 2025 and was not detected until Dennis flagged it in January 2026 — over four months of missing JP data.

**Root cause:** The connection runs through an AWS Network Load Balancer, which can only target bare IPv4 addresses. AWS can reassign these IPs during maintenance windows. When this happened, the NLB's target became unreachable. Application Load Balancers support hostname-based targets but only handle HTTP traffic, not the raw TCP connections that Postgres requires.

Peter confirmed the issue is architectural and **will recur** under the current setup. HK and SG Postgres connections were unaffected because their AWS environments are configured differently.

**Impact:** Any reporting that depends on JP Postgres data (order completions, consultation sessions, customer lifecycle) was silently incomplete for roughly four months. The same failure mode can strike again at any time.

**References:** DMs with Peter (Jan 2026), Slack channel thread on WFOF-348

---

## 4. Schema inconsistencies across regional databases

Ordinary Folk runs three separate Postgres instances (SG, HK, JP), ostensibly from the same codebase. In practice, the schemas diverge:

- When a new column (`preview_video_link`) was added to `consultation_sessions`, it appeared in HK and SG but not JP (or vice versa, depending on Fivetran sync timing). This broke BigQuery UNION queries that used `SELECT *`. The fix was to explicitly enumerate columns in all cross-regional UNIONs. (Linear WFOF-297)
- Segment event payloads differ by region: HK and SG `order_completed` events are missing the `order_id` field entirely, while JP has it. This is the opposite of what was expected given that HK and JP are supposedly more closely aligned. (Slack thread, Jan 2026)
- Fivetran column hashing settings vary by region, leading to cases where PII columns (e.g. `dob`) are hashed in one region's sync but not another's.

**Impact:** Any query that unions data across regions must defensively handle schema differences. New columns added by engineers can silently break downstream pipelines.

**References:** Slack channel (Sep 2025, Jan 2026), Linear WFOF-297

---

## 5. Poorly defined business logic and lack of documentation

There is no single source of truth for how key business metrics should be calculated. Different stakeholders use different definitions for terms like "new customer", "active subscriber", and "order completed". This creates a persistent cycle of: metric is built → stakeholder says it looks wrong → investigation reveals a definitional mismatch rather than a data bug.

Specific examples:

- **Subscription churn:** ~8,500 subscriptions were left in a zombie state (active in Stripe but effectively defunct) until a bulk cleanup in mid-2024. This retroactively distorted historical MRR and churn metrics. Additionally, Stripe's `trialing` status was misused to implement custom billing intervals, making it impossible to distinguish genuine trials from multi-month billing cycles.
- **New vs existing customers:** No agreed definition existed. Dennis built lifecycle tracking based on monthly MRR windows for Stripe subscription customers, but this excludes one-time purchasers and non-Stripe channels.
- **Order lifecycle:** Peter described the order lifecycle in Postgres as needing a complete rebuild. The backend code stores the current state of an order but not its history, making it impossible to reconstruct historical statuses (e.g. "how many orders were in status X at time Y").

**Impact:** Significant time was spent investigating "wrong" numbers that turned out to be definitional disagreements rather than data bugs.

**References:** DMs with Peter (Oct–Dec 2025), Slack channel (multiple threads)

---

## 6. Upstream data hygiene

Manual data entry and Google Sheets serve as a critical part of the data pipeline for non-Stripe channels (TikTok, Lazada, Shopee, Atome, COD). These are prone to a recurring set of issues:

- **Named ranges not covering all rows:** Fivetran syncs from Google Sheets monitor named ranges. Several times, these ranges were defined with fixed row limits (e.g. stopping at row 89 or 150), causing new data to silently drop. The fix was to redefine ranges using full column references (e.g. `A:O`).
- **Naming convention changes without notice:** The `Campaign - Condition Mapping` sheet was edited to abbreviate conditions (e.g. "Hair Loss" → "HL"), breaking downstream BigQuery queries that relied on consistent naming. The financial model showed zero marketing spend for affected conditions until the issue was spotted.
- **Duplicate product IDs:** Ops imported fundamentally different products (e.g. "Wegovy 3 months Pens only" and "Wegovy 3 months with nutritionist and psychologist consult") under the same `product_id`, making it impossible to distinguish them in reporting.
- **Manual date entry errors:** COD revenue transactions were entered with dates in December 2026 instead of 2025, causing the Tableau daily run-rate calculation to divide by 31 days instead of the correct number of elapsed days in the month.

**Impact:** These issues are individually small but collectively account for a large share of the "firefighting" work required to keep reporting accurate.

**References:** Slack channel (multiple threads, 2025–2026), Linear WFOF-355, WFOF-347

---

## Recommendations

These issues are interconnected and reinforce each other. Addressing them properly would require:

1. **Rebuild the Postgres data model** with a clearly documented schema, proper use of foreign keys, and an event-sourced order lifecycle that preserves historical state transitions. Peter was working towards this before the engagement ended.
2. **Standardise Stripe metadata** with an enforced SOP for product setup and a one-time cleanup of legacy objects. Use Product ID (not Price ID) as the canonical product identifier.
3. **Re-architect the JP AWS networking** to eliminate the ephemeral-IP failure mode, or implement monitoring/alerting so that sync failures are caught within hours rather than months.
4. **Establish canonical metric definitions** in a shared, versioned document that all stakeholders sign off on before any new metric is built.
5. **Reduce reliance on manual Google Sheets** by moving marketplace and COD data into structured, validated data entry workflows (or direct API integrations where available).
