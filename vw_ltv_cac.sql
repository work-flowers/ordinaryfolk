DROP VIEW IF EXISTS finance_metrics.ltv_cac;
CREATE VIEW finance_metrics.ltv_cac AS 

WITH all_mrr AS (
	SELECT	
		region,
		obs_date,
		condition,
		brand,
		SUM(n_customers) AS current_n_customers,
		SUM(CASE WHEN lifecycle = 'New' THEN n_customers ELSE 0 END) AS n_new_customers,
    	SUM(CASE WHEN lifecycle = 'Churn' THEN n_customers ELSE 0 END) AS n_churned_customers,
    	SUM(current_mrr) AS current_mrr,
    	SUM(lagged_mrr) AS lagged_mrr,
    	SUM(CASE WHEN lifecycle = 'Churn' THEN lagged_mrr ELSE 0 END) AS churned_mrr
	FROM finance_metrics.customer_lifecycle_monthly
	GROUP BY 1,2,3,4
),

churn_info AS (
	SELECT
		region,
		obs_date,
		condition,
		brand,
		SUM(n_customers) AS n_churned_customers,
		SUM(lagged_mrr) AS churned_mrr		
	FROM finance_metrics.customer_lifecycle_monthly
	WHERE 
		lifecycle = 'Churn'
	GROUP BY 1,2,3,4
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
		brand,
		SUM(net_revenue) AS net_revenue,
		SUM(cogs) AS cogs,
		SUM(marketing_cost) AS marketing_cost
	FROM finance_metrics.monthly_contribution_margin
	WHERE
		1 = 1
		AND (condition IS NULL OR condition <> 'Services')
		-- filter for random countries with small marketing spend
		AND country IN ('hk', 'jp', 'sg')
	GROUP BY 1,2,3,4
)

SELECT	
	COALESCE(am.region, gm.country) AS region,
	COALESCE(am.obs_date, gm.date) AS obs_date,
	COALESCE(am.condition, gm.condition) AS condition,
	COALESCE(am.brand, gm.brand) AS brand,
	am.n_new_customers,
	am.current_mrr,
	am.current_n_customers,
	am.n_churned_customers,
	am.churned_mrr,
	am.lagged_mrr AS base_mrr,
	gm.net_revenue,
	gm.cogs,
	gm.marketing_cost
FROM all_mrr AS am
FULL OUTER JOIN gm_inputs AS gm
	ON am.obs_date = gm.date
	AND am.region = gm.country
	AND am.condition = gm.condition
	AND am.brand = gm.brand