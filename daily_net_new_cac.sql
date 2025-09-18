-- CAC but only for NET NEW subscribers 
-- Defined as new subscribers who never made any one-time purchases prior to subscribing

WITH marketing AS (
	SELECT
		date,
		country_code AS country,
		COALESCE(condition, 'N/A') AS condition,
		SUM(cost_usd) AS marketing_spend
	FROM cac.marketing_spend
	GROUP BY 1,2,3
),

acq_dates AS (
	SELECT
		sh.region,
		sh.customer_id,
		COALESCE(sh.condition, 'N/A') AS condition,
		sh.obs_date AS acquired_date
	FROM all_stripe.subscription_metrics AS sh
	WHERE 
		sh.mrr_usd > 0
		AND sh.new_existing = 'New'
	QUALIFY ROW_NUMBER() OVER(
		PARTITION BY 
			sh.customer_id 
		ORDER BY 
			sh.obs_date DESC,
			sh.mrr_usd DESC
		) = 1
)

SELECT
	mar.date,
	mar.country,
	mar.marketing_spend,
	mar.condition,
	COUNT(DISTINCT ad.customer_id) AS n_new_customers
FROM marketing AS mar
LEFT JOIN acq_dates AS ad
	ON DATE(mar.date) = DATE(ad.acquired_date)
	AND LOWER(mar.country) = LOWER(ad.region)
	AND mar.condition = ad.condition
GROUP BY 1,2,3,4