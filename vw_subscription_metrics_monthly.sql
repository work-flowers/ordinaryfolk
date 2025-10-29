CREATE OR REPLACE VIEW all_stripe.subscription_metrics_monthly AS 

WITH 
-- map each customer_id to a brand
patient_brand_stripe_ids AS (
	SELECT DISTINCT
		stripe_customer_id,
		INITCAP(from_platform_env) AS brand
	FROM all_postgres.patient
),

-- date of first ever purchase for identifying net new customers
customer_first_purchase AS (
	SELECT
		customer_id,
		MIN(purchase_date) AS first_purchase_date
	FROM finance_metrics.contribution_margin AS cm
	WHERE
		1 = 1
		AND cm.total_charge_amount_usd > 0
		AND customer_id IS NOT NULL
		AND (cm.condition IS NULL OR cm.condition <> 'Services')
	GROUP BY 1
),

-- override for the end date of subscriptions canceled in July 2024
july_override AS (
	SELECT
		inv.subscription_id,
		MAX(DATE(ch.created)) AS last_paid
	FROM all_stripe.charge AS ch
	INNER JOIN all_stripe.invoice AS inv
		ON ch.invoice_id = inv.id
	INNER JOIN all_stripe.subscription_history AS sh
		ON inv.subscription_id = sh.id
		AND DATE_TRUNC(DATE(ended_at), MONTH) IN ('2024-07-01')
	WHERE
		1 = 1
		AND ch.status = 'succeeded'
	GROUP BY 1
),

-- latest state of each subscription
sub_latest AS (
	SELECT
    	sh.id AS subscription_id,
    	sh.customer_id,
    	sh.region,
    	sh.status,
    	DATE(sh.start_date) AS created_at,
    	-- for subs canceled in July 24, we'll use the last successful charge date
    	-- this smooths out giant cliff from bulk cancellation of lapsed subs that month
    	COALESCE(jo.last_paid, DATE(sh.ended_at)) AS ended_at,
    	COALESCE(jo.last_paid, DATE(sh.ended_at), CURRENT_DATE()) AS end_span_date
  	FROM all_stripe.subscription_history AS sh
	LEFT JOIN july_override AS jo
		ON sh.id = jo.subscription_id
  	QUALIFY ROW_NUMBER() OVER (PARTITION BY sh.id ORDER BY sh._fivetran_end DESC) = 1
),

-- generate monthly observation dates for all months
-- between subscription start and either end_date or current date
time_series AS (
	SELECT
    	s.subscription_id,
    	s.customer_id,
    	s.region,
    	s.status,
    	s.created_at,
    	s.ended_at,
    	s.end_span_date,
    	DATE_ADD(DATE_TRUNC(s.created_at, MONTH), INTERVAL n MONTH) AS obs_date
	FROM sub_latest AS s
	JOIN UNNEST(
		GENERATE_ARRAY(0, DATE_DIFF(DATE_TRUNC(s.end_span_date, MONTH), DATE_TRUNC(s.created_at, MONTH), MONTH))
	) AS n
),

final AS (
	SELECT
		ts.*,
		sd.* EXCEPT(subscription_id, subscription_mrr),
		CASE 
			WHEN ts.ended_at IS NOT NULL AND DATE_TRUNC(ts.obs_date, MONTH) >= DATE_TRUNC(ts.ended_at, MONTH) THEN 0
			ELSE sd.subscription_mrr
			END AS mrr_local,
		CASE 
			WHEN ts.ended_at IS NOT NULL AND DATE_TRUNC(ts.obs_date, MONTH) >= DATE_TRUNC(ts.ended_at, MONTH) THEN 0
			ELSE sd.subscription_mrr / COALESCE(fx.fx_to_usd, 1)
			END AS mrr_usd,
		pbsi.brand,
		CASE
        	WHEN cfp.first_purchase_date IS NOT NULL AND cfp.first_purchase_date < ts.created_at THEN 'Existing'
        	ELSE 'New'
    		END AS new_existing
	FROM time_series AS ts
	
	-- view with subscription-level product and mrr details
	-- https://github.com/work-flowers/ordinaryfolk/blob/main/subscriptions_refactor/vw_subscription_details.sql
	-- only includes subs with at least one successful charge
	INNER JOIN all_stripe.subscription_details AS sd
		ON ts.subscription_id = sd.subscription_id
	LEFT JOIN ref.fx_rates AS fx
    	ON sd.currency = fx.currency
	LEFT JOIN patient_brand_stripe_ids AS pbsi
		ON ts.customer_id = pbsi.stripe_customer_id
	LEFT JOIN customer_first_purchase AS cfp
    	ON ts.customer_id = cfp.customer_id
)

SELECT *
FROM final