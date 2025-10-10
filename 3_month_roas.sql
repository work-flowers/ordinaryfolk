-- CAC but only for NET NEW subscribers 
-- Defined as new subscribers who never made any one-time purchases prior to subscribing

WITH marketing AS (
	SELECT
		date,
		country_code AS country,
		CASE 
			WHEN condition IN ('ED', 'PE') THEN 'ED + PE'
			WHEN condition IS NOT NULL THEN condition
			ELSE 'N/A'
			END AS condition
		SUM(cost_usd) AS marketing_spend
	FROM cac.marketing_spend AS ms
	WHERE 
		(condition IS NULL OR condition <> 'Brand'
	GROUP BY 1,2,3
),

first_day AS (
	SELECT 
		customer_id, 
		MIN(obs_date) AS first_obs_date
  FROM all_stripe.subscription_metrics
  WHERE 
  	mrr_usd > 0
  	AND new_existing = 'New'
  GROUP BY 1
),

acq_dates AS (
	SELECT
		sh.customer_id,
		sh.region,
		CASE 
			WHEN condition IN ('ED', 'PE') THEN 'ED + PE'
			WHEN condition IS NOT NULL THEN condition
			ELSE 'N/A'
			END AS condition,
		sh.obs_date AS acquired_date,
		ROW_NUMBER() OVER (
			PARTITION BY sh.customer_id
			ORDER BY sh.mrr_usd DESC
		) AS rn
	FROM all_stripe.subscription_metrics AS sh
	JOIN first_day AS fd
		ON sh.customer_id = fd.customer_id
		AND sh.obs_date = fd.first_obs_date
	WHERE 
		sh.mrr_usd > 0
),

acquisitions AS (
	SELECT 
		ad.region,
		ad.condition,
		ad.acquired_date,
		COUNT(ad.customer_id) AS n_new_customers,
		SUM(COALESCE(cm.line_item_amount_usd, cm.total_charge_amount_usd)) AS gross_revenue
	FROM acq_dates AS ad
	INNER JOIN finance_metrics.contribution_margin AS cm
		ON ad.region = cm.region
		AND ad.customer_id = cm.customer_id
		AND DATE_ADD(ad.acquired_date, INTERVAL 3 MONTH) >= cm.purchase_date
		AND (cm.condition IS NULL OR cm.condition <> 'Services')
		AND cm.purchase_type = 'Subscription'
	WHERE 
		ad.rn = 1
	GROUP BY 1,2,3
)

SELECT
	mar.date,
	mar.country,
	mar.marketing_spend,
	mar.condition,
	COALESCE(a.n_new_customers, 0) AS n_new_customers,
	COALESCE(a.gross_revenue, 0) AS gross_revenue
	
FROM marketing AS mar
LEFT JOIN acquisitions AS a
	ON mar.date = a.acquired_date
	AND LOWER(mar.country) = LOWER(a.region)
	AND mar.condition = a.condition	