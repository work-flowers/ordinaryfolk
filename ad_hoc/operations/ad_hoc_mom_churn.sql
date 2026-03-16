
-- Monthly churn using month-end Stripe snapshots
WITH base AS (
	SELECT
		sh.customer_id,
		sh.region,
		CASE 
			WHEN sh.condition IN ('ED', 'PE') THEN 'ED + PE'
			ELSE COALESCE(sh.condition, 'N/A') 
			END AS condition,
		sh.obs_date,
		sh.mrr_usd
	FROM all_stripe.subscription_metrics AS sh
	WHERE 
		1 = 1
		AND sh.mrr_usd > 0
		AND sh.obs_date = LAST_DAY(sh.obs_date)
		AND sh.obs_date < DATE_TRUNC(CURRENT_DATE(), MONTH)
		AND sh.obs_date >= DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 7 MONTH), MONTH)
),

-- Look ahead to the next observed month for each customer/condition/region
seq AS (
	SELECT
		customer_id,
		region,
		condition,
		obs_date,
		LEAD(obs_date) OVER (
			PARTITION BY customer_id, region, condition
			ORDER BY obs_date
		) AS next_obs_date,
		mrr_usd,
		LEAD(mrr_usd) OVER (
			PARTITION BY customer_id, region, condition
			ORDER BY obs_date
		) AS next_mrr
	FROM base
),

-- A churn event occurs in the month after the last observed active month,
-- whenever the next observation skips the immediate next month (or is NULL).
churn_events AS (
	SELECT
		LAST_DAY(DATE_ADD(obs_date, INTERVAL 1 MONTH)) AS churn_month,
		customer_id,
		region,
		condition,
		mrr_usd AS churned_mrr
	FROM seq
	WHERE 
		next_obs_date IS NULL
		OR next_obs_date > LAST_DAY(DATE_ADD(obs_date, INTERVAL 1 MONTH))
),

-- Monthly active customers (at month end)
active_by_month AS (
	SELECT
	    obs_date AS month,
		region,
		condition,
		COUNT(DISTINCT customer_id) AS active_customers,
		SUM(mrr_usd) AS mrr
	FROM base
	GROUP BY 1,2,3
),

-- Monthly churned customers
churn_by_month AS (
	SELECT
		churn_month,
		region,
		condition,
		COUNT(DISTINCT customer_id) AS churned_customers,
		SUM(churned_mrr) AS churned_mrr
	FROM churn_events
	GROUP BY 1,2,3
)

SELECT
  c.churn_month,
  c.region,
  c.condition,
  c.churned_customers,
  a.active_customers AS prior_month_actives,
  c.churned_mrr,
  a.mrr AS base_mrr
FROM churn_by_month AS c
LEFT JOIN active_by_month AS a
	ON c.region = a.region
	AND c.condition = a.condition
	AND c.churn_month = LAST_DAY(DATE_ADD(a.month, INTERVAL 1 MONTH))
WHERE c.churn_month < LAST_DAY(CURRENT_DATE())
ORDER BY c.region, c.condition, c.churn_month