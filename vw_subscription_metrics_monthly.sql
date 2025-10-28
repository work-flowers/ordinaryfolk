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

-- identify all subscriptions with at least one successful charge
active_subs AS (
	SELECT
		inv.subscription_id,
		MAX(DATE(ch.created)) AS last_paid
	FROM all_stripe.charge AS ch
	INNER JOIN all_stripe.invoice AS inv
		ON ch.invoice_id = inv.id
		AND inv.subscription_id IS NOT NULL
	WHERE ch.status = 'succeeded'
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
  	 -- filter for those that had a succesful charge
  	INNER JOIN active_subs AS act
  		ON sh.id = act.subscription_id
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

mrr_by_sub AS (
    SELECT
        si.subscription_id,
        pl.currency,
        pl.id AS plan_id,
        pl.interval,
        pl.interval_count,
        pl.product_id,
        CASE
            WHEN pl.interval = 'month' THEN pl.amount * si.quantity / COALESCE(subs.subunits, 100) / COALESCE(pl.interval_count, 1)
            WHEN pl.interval = 'year' THEN pl.amount * si.quantity / COALESCE(subs.subunits, 100) / (12 * COALESCE(pl.interval_count, 1))
            WHEN pl.interval = 'week' THEN pl.amount * si.quantity / COALESCE(subs.subunits, 100) * (52 / 12) / COALESCE(pl.interval_count, 1)
            WHEN pl.interval = 'day' THEN pl.amount * si.quantity / COALESCE(subs.subunits, 100) * (365 / 12)/ COALESCE(pl.interval_count, 1)
            ELSE 0
        END AS subscription_mrr,
        JSON_EXTRACT_SCALAR(pl.metadata, '$.boxes') AS n_boxes,
        prod.name AS product_name,
        COALESCE(JSON_EXTRACT_SCALAR(prod.metadata, '$.condition'), 'Other') AS condition
    FROM all_stripe.subscription_item AS si
    INNER JOIN all_stripe.plan AS pl
        ON si.plan_id = pl.id
    LEFT JOIN all_stripe.product AS prod
        ON pl.product_id = prod.id
    LEFT JOIN ref.stripe_currency_subunits AS subs
        ON pl.currency = subs.currency
    WHERE
        si.quantity > 0
),

final AS (
	SELECT
		ts.*,
		mbs.* EXCEPT(subscription_id, subscription_mrr),
		CASE 
			WHEN ts.ended_at IS NOT NULL AND DATE_TRUNC(ts.obs_date, MONTH) >= DATE_TRUNC(ts.ended_at, MONTH) THEN 0
			ELSE mbs.subscription_mrr
			END AS mrr_local,
		CASE 
			WHEN ts.ended_at IS NOT NULL AND DATE_TRUNC(ts.obs_date, MONTH) >= DATE_TRUNC(ts.ended_at, MONTH) THEN 0
			ELSE mbs.subscription_mrr / COALESCE(fx.fx_to_usd, 1)
			END AS mrr_usd,
		pbsi.brand,
		CASE
        	WHEN cfp.first_purchase_date IS NOT NULL AND cfp.first_purchase_date < ts.created_at THEN 'Existing'
        	ELSE 'New'
    		END AS new_existing
	FROM time_series AS ts
	INNER JOIN mrr_by_sub AS mbs
		ON ts.subscription_id = mbs.subscription_id
	LEFT JOIN ref.fx_rates AS fx
    	ON mbs.currency = fx.currency
	LEFT JOIN patient_brand_stripe_ids AS pbsi
		ON ts.customer_id = pbsi.stripe_customer_id
	LEFT JOIN customer_first_purchase AS cfp
    	ON ts.customer_id = cfp.customer_id
)

SELECT *
FROM final