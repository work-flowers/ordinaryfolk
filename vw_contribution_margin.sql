-- Drop the existing view if it exists and recreate it
-- This view consolidates contribution margin data from multiple sales channels

DROP VIEW IF EXISTS finance_metrics.contribution_margin; 
CREATE VIEW finance_metrics.contribution_margin AS

-- CTE to get subscription start dates from Stripe subscription history
WITH sub_starts AS (
	SELECT DISTINCT
		id AS subscription_id,
		DATE(created) AS create_date
	FROM all_stripe.subscription_history
),

-- CTE to map Stripe customer IDs to patient brands
patient_brand_stripe_ids AS (
	SELECT DISTINCT
		stripe_customer_id,
		INITCAP(from_platform_env) AS brand
	FROM all_postgres.patient
),


-- Main CTE for Stripe payment data
-- Processes all Stripe charges and associated invoice/subscription data
stripe_data AS (

	SELECT
		'Stripe' AS sales_channel,
		ch.region,
		bt.type, -- Balance transaction type (payment, payout, etc.)
		CASE 
			WHEN ii.subscription_id IS NULL THEN 'One-Time'
			ELSE 'Subscription'
			END AS purchase_type, -- Determine if this is a one-time payment or subscription
		COALESCE(inv.billing_reason, 'manual') AS billing_reason, -- Why the invoice was created
		pbsi.brand,
		ch.customer_id,
		cust.email,
		ch.id AS charge_id,
		JSON_VALUE(ch.metadata, '$.orderId') AS order_sys_id, -- Extract internal order ID from charge metadata
		ch.payment_intent_id,
		inv.subscription_id,
		px.recurring_interval,  -- monthly, yearly, etc.
		px.recurring_interval_count, -- how many intervals (e.g., 3 months)
		DATE(ch.created) AS purchase_date,
		ch.amount / fx.fx_to_usd / COALESCE(sub.subunits, 100) AS total_charge_amount_usd, -- Convert charge amount to USD using FX rates and currency subunits
		COALESCE(ch.amount_refunded / ch.amount, 0) AS refund_rate, -- Percentage refunded
		ch.amount_refunded / fx.fx_to_usd / COALESCE(sub.subunits, 100) AS amount_refunded_usd,
		
		-- Product identification with fallbacks for different charge types
		prod.id AS product_id,
		prod.name AS product_name,
		px.id AS price_id,
		JSON_VALUE(prod.metadata, '$.condition') AS condition, -- Medical condition being treated
		COALESCE(ii.quantity, otc.quantity, 1) AS quantity,
		ch.currency,
		
		-- Calculate line item amount proportionally based on invoice breakdown
		SAFE_DIVIDE(
			ch.amount,
			CASE 
				WHEN inv.subtotal > 0 THEN inv.subtotal
				WHEN px.unit_amount> 0 THEN SUM(px.unit_amount) OVER(PARTITION BY ch.payment_intent_id)
				ELSE ch.amount 
				END
		) * COALESCE(ii.amount, px.unit_amount) / fx.fx_to_usd / COALESCE(sub.subunits, 100) AS line_item_amount_usd,		
		-- Cost of Goods Sold (COGS) - note: teleconsult COGS handled separately in monthly pipeline
		pc.cogs / fx.fx_to_usd AS cogs,
		pc.cashback,
		t.rate AS gst_vat, -- Tax rate (GST/VAT) applicable, in % terms
		COALESCE(bt.fee / bt.amount, 0) AS fee_rate,
		pc.packaging / fx.fx_to_usd AS packaging,
		MIN(DATE(ch.created)) OVER(PARTITION BY ch.customer_id) AS acquisition_date, -- Customer acquisition date (first purchase date for this customer)
		MAX(ch._fivetran_synced) OVER() AS as_of
	FROM all_stripe.charge AS ch
	LEFT JOIN all_stripe.payment_intent AS pi
		ON ch.payment_intent_id = pi.id
	LEFT JOIN all_stripe.customer AS cust
		ON ch.customer_id = cust.id
	LEFT JOIN patient_brand_stripe_ids AS pbsi
		ON ch.customer_id = pbsi.stripe_customer_id
	INNER JOIN all_stripe.balance_transaction AS bt
		ON ch.balance_transaction_id = bt.id
	INNER JOIN ref.fx_rates AS fx
		ON ch.currency = fx.currency
	
	-- Handle Stripe currency subunits (e.g., cents vs dollars)
	-- https://docs.stripe.com/currencies#zero-decimal
	LEFT JOIN ref.stripe_currency_subunits AS sub
		ON fx.currency = sub.currency
	
	-- Join invoice and line item data for subscription/invoice-based charges
	LEFT JOIN all_stripe.invoice AS inv
		ON ch.invoice_id = inv.id
	LEFT JOIN all_stripe.invoice_line_item AS ii
		ON ch.invoice_id = ii.invoice_id
	
	-- Join OTC (one-time-charge) pricing for non-invoice charges
	LEFT JOIN all_stripe.otc_price_id AS otc
		ON ch.payment_intent_id = otc.payment_intent_id
		AND ch.invoice_id IS NULL -- ONLY for OTC charges which have no invoice_id
	
	LEFT JOIN all_stripe.price AS px
		ON LOWER(
			COALESCE(
				ii.price_id, 
				otc.price_id, 
				JSON_VALUE(pi.metadata, '$.priceIds'),
				JSON_VALUE(pi.metadata, '$.stripePriceIds'),
				JSON_VALUE(pi.metadata, '$.paymentIntentPriceId')
			)
		) = LOWER(px.id) -- need LOWER() because price_ids extracted from otc payment_intent metadata are all lowercase
	LEFT JOIN all_stripe.product AS prod
		ON px.product_id = prod.id
	
	-- Join cost data with date range validation
	LEFT JOIN all_stripe.product_cost AS pc
		ON px.id = pc.price_id
		AND DATE(ch.created) BETWEEN pc.from_date AND pc.to_date
	
	-- Join tax data with date range validation
	LEFT JOIN ref.tax_rate_history AS t
		ON ch.region = t.region
		AND DATE(ch.created) BETWEEN t.from_date AND t.to_date
	WHERE
		ch.status = 'succeeded'
		
),

-- CTE for TikTok Shop sales data
tiktok_data AS(

		SELECT	
		'TikTok' AS sales_channel,
		'sg' AS region,  -- TikTok sales are Singapore-based
		CAST(NULL AS STRING) AS type,
		'One-Time' AS purchase_type,  -- TikTok doesn't support subscriptions
		'manual' AS billing_reason,
		'N/A' AS brand,  -- No brand differentiation for TikTok
		tik.buyer_username AS customer_id,
		CAST(NULL AS STRING) AS email,  -- Email not available from TikTok
		CAST(tik.order_id AS STRING) AS charge_id,
		CAST(NULL AS STRING) AS order_sys_id,
		CAST(NULL AS STRING) AS payment_intent_id,
		CAST(NULL AS STRING) AS subscription_id,
		CAST(NULL AS STRING) AS recurring_interval,
		NULL AS recurring_interval_count,
		tik.created_time AS purchase_date,
		0 AS total_charge_amount_usd,  -- TikTok doesn't provide total charge info
		-- Calculate refund rate as percentage of subtotal
		SAFE_DIVIDE(COALESCE(tik.order_refund_amount, 0), COALESCE(tik.sku_subtotal_after_discount, 1)) AS refund_rate,
		COALESCE(tik.order_refund_amount, 0) / fx.fx_to_usd AS amount_refunded_usd,
		CAST(tik.sku_id AS STRING) AS product_id,
		tok.product_name,
		CAST(NULL AS STRING) AS price_id,
		tok.condition,
		tik.quantity,
		LOWER(tik.currency) AS currency,
		tik.sku_subtotal_after_discount / fx.fx_to_usd AS line_item_amount_usd,
		tik.quantity * tok.cogs / fx.fx_to_usd AS cogs,  -- COGS multiplied by quantity
		0 AS cashback,  -- No cashback on TikTok
		t.rate AS gst_vat,
		-- TikTok fees are entered as negative numbers in the source sheet
		-COALESCE(SAFE_DIVIDE(tik.payment_gateway_fee, COALESCE(tik.sku_subtotal_after_discount, 1)), 0) AS fee_rate,
		tok.packaging / fx.fx_to_usd AS packaging,
		-- Customer acquisition date for TikTok users
		MIN(DATE(tik.created_time)) OVER(PARTITION BY tik.buyer_username) AS acquisition_date,
		MAX(tik._fivetran_synced) OVER() AS as_of
	FROM google_sheets.tiktok_orders AS tik
	-- Join product cost data with date range validation
	LEFT JOIN finance_metrics.tiktok_product_costs AS tok
		ON tik.sku_id = tok.sku_id
		AND tik.created_time BETWEEN tok.from_date AND tok.to_date
	LEFT JOIN ref.fx_rates AS fx
		ON LOWER(tik.currency) = LOWER(fx.currency)
	-- Apply Singapore tax rates for TikTok orders
	LEFT JOIN ref.tax_rate_history AS t
		ON t.region = 'sg'
		AND tik.created_time BETWEEN t.from_date AND t.to_date
),

-- CTE for Lazada marketplace sales data
-- Aggregates different transaction types (sales, refunds, fees) by order
lazada_data AS (
	SELECT
		o.transaction_date AS purchase_date,
		lc.product_name,
		o.seller_sku,
		lc.cogs / fx.fx_to_usd AS cogs,
		lc.condition,
		lc.packaging / fx.fx_to_usd AS packaging,
		LOWER(o.currency) AS currency,
		-- Sum sales transactions
		SUM(CASE WHEN o.transaction_type = 'Orders-Sales' THEN o.amount / fx.fx_to_usd ELSE 0 END) AS line_item_amount_usd,
		-- Sum refund transactions (negative amounts become positive refunds)
		SUM(CASE WHEN o.transaction_type LIKE 'Refunds%' THEN -o.amount / fx.fx_to_usd ELSE 0 END) AS refunds,
		-- Sum various fee types charged by Lazada
		SUM(
			CASE 
				WHEN o.transaction_type IN (
					'Orders-Lazada Fees',
					'Orders-Logistics', 
					'Orders-Marketing Fees',
					'Other Services-Marketing Fees'
				) THEN -o.amount / fx.fx_to_usd ELSE 0 END
		) AS fees,
		MAX(o._fivetran_synced) AS as_of
	FROM google_sheets.lazada_orders AS o
	LEFT JOIN ref.fx_rates AS fx
		ON LOWER(o.currency) = fx.currency
	-- Join product costs with date range validation
	LEFT JOIN finance_metrics.lazada_product_costs AS lc
		ON o.seller_sku = lc.seller_sku
		AND o.transaction_date BETWEEN lc.from_date AND lc.to_date
	GROUP BY 1,2,3,4,5,6,7
),

-- CTE for Shopee marketplace sales data
shopee_data AS (
	SELECT
		'Shopee' AS sales_channel,
		'sg' AS region,  -- Shopee sales are Singapore-based
		CAST(NULL AS STRING) AS type,
		-- Determine purchase type from condition mapping, default to one-time
		COALESCE(cttp.purchase_type, 'One-Time') AS purchase_type,
		COALESCE(cttp.billing_reason, 'manual') AS billing_reason,
		'N/A' AS brand,  -- No brand differentiation for Shopee
		so.username_buyer_ AS customer_id,
		CAST(NULL AS STRING) AS email,  -- Email not available from Shopee
		CAST(NULL AS STRING) AS charge_id,
		CAST(NULL AS STRING) AS order_sys_id,
		CAST(NULL AS STRING) AS payment_intent_id,
		CAST(NULL AS STRING) AS subscription_id,
		CAST(NULL AS STRING) AS recurring_interval,
		NULL AS recurring_interval_count,
		DATE(so.payout_completed_date) AS purchase_date,  -- Use payout date as purchase date
		0 AS total_charge_amount_usd,  -- Total charge not separately tracked
		so.refund_amount / GREATEST(so.product_price, 1) AS refund_rate,  -- Avoid division by zero
		so.refund_amount / fx.fx_to_usd AS amount_refunded_usd,
		CAST(so.product_id AS STRING) AS product_id,
		so.product_name,
		CAST(NULL AS STRING) AS price_id,
		sc.condition,
		COALESCE(q.quantity, 1) AS quantity,
		LOWER(so.currency) AS currency,
		so.product_price / fx.fx_to_usd AS line_item_amount_usd,
		sc.cogs / fx.fx_to_usd AS cogs,
		0 AS cashback,  -- No cashback on Shopee
		t.rate AS gst_vat,
		
		-- Calculate total fee rate from multiple Shopee fee components (negative because they're costs)
		-(so.commission_fee_incl_gst_ + so.ps_finance_pdf_income_service_fee_for_sg + so.transaction_fee_incl_gst_ + so.ams_commission_fee) / GREATEST(so.product_price, 1) AS fee_rate,
		sc.packaging / fx.fx_to_usd AS packaging,
		
		-- Customer acquisition date for Shopee users
		MIN(DATE(so.payout_completed_date)) OVER(PARTITION BY so.username_buyer_) AS acquisition_date,
		MAX(so._fivetran_synced) OVER() AS as_of
	FROM google_sheets.shopee_orders AS so
	LEFT JOIN ref.fx_rates AS fx
		ON LOWER(so.currency) = fx.currency
	
	-- Join quantity data (separate table for Shopee)
	LEFT JOIN google_sheets.shopee_order_quantities AS q
		ON so.order_id = q.order_id
	
	-- Join product costs with date and SKU validation
	LEFT JOIN finance_metrics.shopee_product_costs AS sc
		ON so.product_id = sc.product_id
		AND q.sku_reference_no_ = sc.sku_reference_no_
		AND DATE(so.payout_completed_date) BETWEEN sc.from_date AND sc.to_date
	
	-- Map medical conditions to transaction types
	LEFT JOIN google_sheets.condition_transaction_type_map AS cttp
		ON sc.condition = cttp.condition
	
	-- Apply Singapore tax rates
	LEFT JOIN ref.tax_rate_history AS t
		ON t.region = 'sg'
		AND DATE(so.payout_completed_date) BETWEEN t.from_date AND t.to_date
),

-- CTE for Singapore Cash on Delivery (COD) orders
sg_cod_data AS (
	SELECT
		'SG COD' AS sales_channel,
		'sg' AS region,
		CAST(NULL AS STRING) AS type,
		COALESCE(cttp.purchase_type, 'One-Time') AS purchase_type,
		COALESCE(cttp.billing_reason, 'manual') AS billing_reason,
		'N/A' AS brand,  -- No brand differentiation for COD
		o.email AS customer_id,  -- Use email as customer identifier
		o.email,
		CAST(NULL AS STRING) AS charge_id,
		CAST(NULL AS STRING) AS order_sys_id,
		CAST(NULL AS STRING) AS payment_intent_id,
		CAST(NULL AS STRING) AS subscription_id,
		CAST(NULL AS STRING) AS recurring_interval,
		NULL AS recurring_interval_count,
		o.date AS purchase_date,
		o.purchase_amount / fx.fx_to_usd AS total_charge_amount_usd,
		0 AS refund_rate,  -- COD orders typically don't have refunds tracked this way
		0 AS amount_refunded_usd,
		o.email AS product_id,  -- Using email as product ID (seems unusual - may need verification)
		prod.name AS product_name,
		CAST(NULL AS STRING) AS price_id,
		JSON_EXTRACT_SCALAR(prod.metadata, '$.condition') AS condition,
		o.quantity,
		o.currency,
		o.purchase_amount / fx.fx_to_usd AS line_item_amount_usd,
		c.cost_box / fx.fx_to_usd AS cogs,  -- Cost per box
		.02 AS cashback,  -- Fixed 2% cashback for COD orders
		t.rate AS gst_vat,
		0 AS fee_rate,  -- No payment processing fees for COD
		c.packaging_cost / fx.fx_to_usd AS packaging,
		-- Customer acquisition date based on email
		MIN(o.date) OVER(PARTITION BY o.email) AS acquisition_date,
		MAX(cttp._fivetran_synced) OVER() AS as_of
	FROM finance_metrics.cod_sg_orders_all AS o
	LEFT JOIN ref.fx_rates AS fx
		ON o.currency = fx.currency
	-- Join cost data with date and region validation
	LEFT JOIN all_stripe.product_cost_per_box AS c
		ON o.product_id = c.product_id
		AND o.date BETWEEN c.from_date AND c.to_date
		AND c.region = 'sg'
	LEFT JOIN all_stripe.product AS prod
		ON o.product_id = prod.id
	-- Map conditions to transaction types
	LEFT JOIN google_sheets.condition_transaction_type_map AS cttp
		ON JSON_EXTRACT_SCALAR(prod.metadata, '$.condition') = cttp.condition
	-- Apply Singapore tax rates
	LEFT JOIN ref.tax_rate_history AS t
		ON t.region = 'sg'
		AND o.date BETWEEN t.from_date AND t.to_date
),

-- CTE for Hong Kong Cash on Delivery (COD) orders
-- Similar structure to SG COD but for Hong Kong market
hk_cod_data AS (
	SELECT
		'HK COD' AS sales_channel,
		'hk' AS region,  -- Hong Kong region
		CAST(NULL AS STRING) AS type,
		COALESCE(cttp.purchase_type, 'One-Time') AS purchase_type,
		COALESCE(cttp.billing_reason, 'manual') AS billing_reason,
		'N/A' AS brand,
		o.email AS customer_id,
		o.email,
		CAST(NULL AS STRING) AS charge_id,
		CAST(NULL AS STRING) AS order_sys_id,
		CAST(NULL AS STRING) AS payment_intent_id,
		CAST(NULL AS STRING) AS subscription_id,
		CAST(NULL AS STRING) AS recurring_interval,
		NULL AS recurring_interval_count,
		o.date AS purchase_date,
		o.purchase_amount / fx.fx_to_usd AS total_charge_amount_usd,
		0 AS refund_rate,
		0 AS amount_refunded_usd,
		o.email AS product_id,  -- Same unusual pattern as SG COD
		prod.name AS product_name,
		CAST(NULL AS STRING) AS price_id,
		JSON_EXTRACT_SCALAR(prod.metadata, '$.condition') AS condition,
		o.quantity,
		o.currency,
		o.purchase_amount / fx.fx_to_usd AS line_item_amount_usd,
		c.cost_box / fx.fx_to_usd AS cogs,
		.02 AS cashback,  -- Fixed 2% cashback
		t.rate AS gst_vat,
		-- HK COD has payment gateway fees unlike SG COD
		SAFE_DIVIDE(o.payment_gateway_fees, o.purchase_amount) AS fee_rate,
		c.packaging_cost / fx.fx_to_usd AS packaging,
		MIN(o.date) OVER(PARTITION BY o.email) AS acquisition_date,
		MAX(prod._fivetran_synced) OVER() AS as_of
	FROM finance_metrics.cod_hk_orders_all AS o
	LEFT JOIN ref.fx_rates AS fx
		ON o.currency = fx.currency
	-- Join cost data with HK region filter
	LEFT JOIN all_stripe.product_cost_per_box AS c
		ON o.product_id = c.product_id
		AND o.date BETWEEN c.from_date AND c.to_date
		AND c.region = 'hk'
	LEFT JOIN all_stripe.product AS prod
		ON o.product_id = prod.id
	LEFT JOIN google_sheets.condition_transaction_type_map AS cttp
		ON JSON_EXTRACT_SCALAR(prod.metadata, '$.condition') = cttp.condition
	-- Apply Hong Kong tax rates
	LEFT JOIN ref.tax_rate_history AS t
		ON t.region = 'hk'
		AND o.date BETWEEN t.from_date AND t.to_date
),

-- CTE to get Atome order dates
-- Atome transactions can have multiple entries, so we need the earliest date per order
atome_order_dates AS (
	SELECT
		atome_order_id,
		MIN(transaction_time) AS order_date  -- Get the first transaction time for each order
	FROM google_sheets.atome_manual
	GROUP BY 1
),

-- CTE for Atome Buy Now Pay Later (BNPL) transactions
-- Aggregates Atome transaction data by order
atome_final AS (
	SELECT
		'Atome' AS sales_channel,
		'sg' AS region,  -- Atome operates in Singapore
		CAST(NULL AS STRING) AS type,
		-- Determine if subscription based on Stripe subscription ID presence
		CASE 
			WHEN o.stripe_subscription_id IS NOT NULL THEN 'Subscription'
			ELSE 'One-Time' 
		END AS purchase_type,
		'manual' AS billing_reason,
		INITCAP(p.from_platform_env) AS brand,  -- Capitalize brand name
		o.patient_id AS customer_id,
		p.email,
		am.atome_order_id AS charge_id,
		o.sys_id AS order_sys_id,
		o.stripe_payment_intent_id AS payment_intent_id,
		o.stripe_subscription_id AS subscription_id,
		CAST(NULL AS STRING) AS recurring_interval,
		NULL AS recurring_interval_count,
		aod.order_date AS purchase_date,
		-- Sum positive transaction amounts as total charge
		SUM(GREATEST(am.transaction_amount, 0) / fx.fx_to_usd) AS total_charge_amount_usd,
		-- Calculate refund rate as negative amounts over positive amounts
		SUM(ABS(LEAST(am.transaction_amount, 0))) / SUM(GREATEST(am.transaction_amount, 0)) AS refund_rate,
		SUM(ABS(LEAST(am.transaction_amount, 0)) / fx.fx_to_usd) AS amount_refunded_usd,
		px.product_id,
		prod.name AS product_name,
		COALESCE(o.prescription_price_id, o.price_id) AS price_id,  -- Prefer prescription price if available
		JSON_EXTRACT_SCALAR(prod.metadata, '$.condition') AS condition,
		1 AS quantity,  -- Default quantity for Atome orders
		LOWER(am.currency) AS currency,
		SUM(GREATEST(am.transaction_amount, 0) / fx.fx_to_usd) AS line_item_amount_usd,
		pc.cogs / fx.fx_to_usd AS cogs,
		pc.cashback,
		t.rate AS gst_vat,
		-- Calculate fee rate from Atome fees (sponsored vouchers, MDR fees, flat fees)
		-SUM(am.sponsored_voucher_amount + mdr_fee + flat_fee) / SUM(GREATEST(am.transaction_amount, 0) / fx.fx_to_usd) AS fee_rate,
		pc.packaging,
		-- Customer acquisition date based on patient ID
		MIN(aod.order_date) OVER (PARTITION BY o.patient_id) AS acquisition_date,
		MAX(am._fivetran_synced) AS as_of
	FROM google_sheets.atome_manual AS am
	INNER JOIN atome_order_dates AS aod
		ON am.atome_order_id = aod.atome_order_id
	-- Join order data from Singapore PostgreSQL database
	LEFT JOIN sg_postgres_rds_public.order AS o
		ON am.e_commerce_platform_order_id = o.short_id
	LEFT JOIN all_postgres.patient AS p
		ON o.patient_id = p.sys_id
	LEFT JOIN ref.fx_rates AS fx
		ON LOWER(am.currency) = fx.currency
	LEFT JOIN all_stripe.price AS px
		ON COALESCE(o.prescription_price_id, o.price_id) = px.id
	LEFT JOIN all_stripe.product AS prod
		ON px.product_id = prod.id
	-- Join product costs with date validation
	LEFT JOIN all_stripe.product_cost AS pc
		ON COALESCE(o.prescription_price_id, o.price_id) = pc.price_id
		AND aod.order_date BETWEEN (pc.from_date) AND pc.to_date
	-- Apply Singapore tax rates
	LEFT JOIN ref.tax_rate_history AS t
		ON 'sg' = t.region
		AND am.transaction_time BETWEEN t.from_date AND t.to_date
	-- Group by all non-aggregated columns
	GROUP BY 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,19,20,21,22,24,26,27,28,30
	-- Only include orders with positive total amounts
	HAVING SUM(GREATEST(am.transaction_amount, 0)) > 0
),

-- Main CTE that unions all sales channel data
-- Combines data from all different sales channels into a unified structure
unioned_data AS (
	SELECT * FROM stripe_data
	
	UNION ALL
	
	SELECT * FROM tiktok_data
	
	UNION ALL
	
	SELECT * FROM shopee_data
	
	UNION ALL
	
	SELECT * FROM sg_cod_data
	
	UNION ALL
	
	SELECT * FROM hk_cod_data
	
	UNION ALL

	-- Lazada data needs transformation to match the standard structure
	SELECT
		'Lazada' AS sales_channel,
		'sg' AS region,
		CAST(NULL AS STRING) AS type,
		'One-Time' AS purchase_type,  -- Lazada doesn't support subscriptions
		'manual' AS billing_reason,
		'N/A' AS brand,
		CAST(NULL AS STRING) AS customer_id,  -- Customer ID not available from Lazada
		CAST(NULL AS STRING) AS email,
		CAST(NULL AS STRING) AS charge_id,
		CAST(NULL AS STRING) AS order_sys_id,
		CAST(NULL AS STRING) AS payment_intent_id,
		CAST(NULL AS STRING) AS subscription_id,
		CAST(NULL AS STRING) AS recurring_interval,
		NULL AS recurring_interval_count,
		purchase_date,
		0 AS total_charge_amount_usd,  -- Not tracked separately
		refunds / line_item_amount_usd AS refund_rate,  -- Calculate refund percentage
		refunds AS amount_refunded_usd,
		seller_sku AS product_id,  -- Use SKU as product identifier
		product_name,
		CAST(NULL AS STRING) AS price_id,
		condition,
		1 AS quantity,  -- Default quantity
		currency,
		line_item_amount_usd,
		cogs,
		0 AS cashback,  -- No cashback on Lazada
		t.rate AS gst_vat,
		fees / line_item_amount_usd AS fee_rate,  -- Calculate fee percentage
		packaging,
		CAST(NULL AS DATE) AS acquisition_date,  -- Not tracked for Lazada b/c we don't have any unique customer identifier
		as_of
	FROM lazada_data
	-- Apply Singapore tax rates to Lazada data
	LEFT JOIN ref.tax_rate_history AS t
		ON t.region = 'sg'
		AND lazada_data.purchase_date BETWEEN t.from_date AND t.to_date
	WHERE line_item_amount_usd > 0  -- Only include orders with positive amounts
	
	UNION ALL
	
	SELECT * FROM atome_final
)

-- Final SELECT with additional calculated fields
SELECT
	unioned_data.*,
	-- Classify customers as new or existing based on acquisition date
	-- New customers are those purchasing within 7 days of their first purchase
	CASE 
		WHEN purchase_date <= DATE_ADD(acquisition_date, INTERVAL 7 DAY) THEN 'New'
		WHEN acquisition_date IS NOT NULL THEN 'Existing'
	END AS new_existing,
	-- Add subscription creation date for subscription-based purchases
	sub_starts.create_date AS subscription_created_date
FROM unioned_data
LEFT JOIN sub_starts
	ON unioned_data.subscription_id = sub_starts.subscription_id
