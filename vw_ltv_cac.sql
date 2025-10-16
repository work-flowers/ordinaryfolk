DROP VIEW IF EXISTS finance_metrics.ltv_cac;
CREATE VIEW finance_metrics.ltv_cac AS 

WITH all_mrr AS (
	SELECT
		region,
		obs_date,
		condition,
		SUM(CASE WHEN lifecycle = 'New' THEN n_customers ELSE 0 END) AS n_new_customers,
		SUM(current_mrr) AS current_mrr,
		SUM(n_customers) AS current_n_customers
	FROM finance_metrics.customer_lifecycle_monthly
	WHERE 
		current_mrr > 0
	GROUP BY 1,2,3
),

churn_info AS (
	SELECT
		region,
		obs_date,
		condition,
		SUM(n_customers) AS n_churned_customers,
		SUM(lagged_mrr) AS churned_mrr		
	FROM finance_metrics.customer_lifecycle_monthly
	WHERE 
		lifecycle = 'Churn'
	GROUP BY 1,2,3
),

gm_inputs AS (
	SELECT
		country,
		date,
		CASE 
			WHEN condition IN ('ED', 'PE') THEN 'ED + PE'
			WHEN condition IN ('Brand', 'OTC', 'Smoking Cessation', 'Sex Toys') THEN 'Other'
			WHEN condition IS NOT NULL THEN condition
			ELSE 'Other'
			END AS condition,
		SUM(net_revenue) AS net_revenue,
		SUM(cogs) AS cogs,
		SUM(marketing_cost) AS marketing_cost
	FROM finance_metrics.monthly_contribution_margin
	WHERE
		(condition IS NULL OR condition <> 'Services')
	GROUP BY 1,2,3
)

SELECT	
	COALESCE(am.region, gm.country) AS region,
	COALESCE(am.obs_date, gm.date) AS obs_date,
	COALESCE(am.condition, gm.condition) AS condition,
	am.n_new_customers,
	am.current_mrr,
	am.current_n_customers,
	ci.n_churned_customers,
	ci.churned_mrr,
	LAG(am.current_n_customers) OVER(
		PARTITION BY am.region, am.condition 
		ORDER BY am.obs_date
	) AS base_n_customers,
	LAG(am.current_mrr) OVER(
		PARTITION BY am.region, am.condition 
		ORDER BY am.obs_date
	) AS base_mrr,
	gm.net_revenue,
	gm.cogs,
	gm.marketing_cost
FROM all_mrr AS am
LEFT JOIN churn_info AS ci
	ON am.obs_date = ci.obs_date
	AND am.region = ci.region
	AND am.condition = ci.condition
FULL OUTER JOIN gm_inputs AS gm
	ON am.obs_date = gm.date
	AND am.region = gm.country
	AND am.condition = gm.condition