WITH marketing AS (
	SELECT
		date,
		country_code AS country,
		COALESCE(condition, 'N/A') AS condition,
		SUM(cost_usd) AS marketing_spend
	FROM cac.marketing_spend
	GROUP BY 1,2,3
),

first_day AS (
	SELECT 
		customer_id, 
		MIN(obs_date) AS first_obs_date
  FROM all_stripe.subscription_metrics
  WHERE 
  	mrr_usd > 0
  GROUP BY 1
),

acq_dates AS (
	SELECT
		sh.customer_id,
		sh.region,
		COALESCE(sh.condition, 'N/A') AS condition,
		sh.obs_date AS acquired_date,
		sh.mrr_usd,
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
		region,
		condition,
		acquired_date,
		COUNT(DISTINCT customer_id) AS n_new_customers
	FROM acq_dates
	WHERE 
		rn = 1
	GROUP BY 1,2,3
)

SELECT
	mar.date,
	mar.country,
	mar.marketing_spend,
	mar.condition,
	COALESCE(a.n_new_customers,0)
FROM marketing AS mar
LEFT JOIN acquisitions AS a
	ON mar.date = a.acquired_date
	AND LOWER(mar.country) = LOWER(a.region)
	AND mar.condition = a.condition