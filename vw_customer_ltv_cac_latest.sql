CREATE OR REPLACE VIEW finance_metrics.customer_ltv_cac_latest AS

WITH

-- current snapshot: strict equality (subscription_metrics is today-only)
current_pt AS (
  SELECT
    s.customer_id,
    s.region,
    s.mrr_usd AS current_mrr
  FROM all_stripe.subscription_metrics s
  WHERE s.obs_date = CURRENT_DATE()
),

-- prior snapshot: last state on/before same day last month (handles missing exact date)
prior_pt AS (
  SELECT
    s.customer_id,
    s.region,
    s.mrr_usd AS prior_mrr
  FROM all_stripe.subscription_metrics s
  WHERE s.obs_date = DATE_SUB(DATE_TRUNC(CURRENT_DATE(), MONTH), INTERVAL 1 DAY)
),

-- acquisition date up to today (first time mrr > 0 on or before today)
acq AS (
  SELECT
    s.customer_id,
    s.region,
    MIN(s.obs_date) AS acq_date
  FROM all_stripe.subscription_metrics s
  WHERE s.mrr_usd > 0
  GROUP BY 1,2
),

combined AS (
  SELECT
    COALESCE(c.customer_id, p.customer_id) AS customer_id,
    COALESCE(c.region, p.region) AS region,
    COALESCE(c.current_mrr, 0) AS current_mrr,   
    COALESCE(p.prior_mrr, 0) AS lagged_mrr,
    ac.acq_date,
    CURRENT_DATE() AS obs_date
  FROM current_pt AS c 
  FULL OUTER JOIN prior_pt AS p 
  	ON p.customer_id = c.customer_id
  LEFT JOIN acq ac 
  	ON ac.customer_id = COALESCE(c.customer_id, p.customer_id)

),

customer_lifecyle AS (
	SELECT
		region,
		CASE
			WHEN acq_date >= DATE_TRUNC(CURRENT_DATE(), MONTH) THEN 'New'
			WHEN current_mrr = 0 AND lagged_mrr > 0 THEN 'Churn'
			WHEN current_mrr > 0 AND lagged_mrr = 0 AND obs_date != acq_date THEN 'Reactivation'
			WHEN current_mrr  > 0 THEN 'Retention'
  		END AS lifecycle,
		COUNT(DISTINCT customer_id) AS n_customers,
		SUM(current_mrr) AS current_mrr,
		SUM(lagged_mrr) AS lagged_mrr
	FROM combined
	WHERE 
		(current_mrr > 0 OR lagged_mrr > 0)
	GROUP BY 1,2
),

mrr_final AS (
	SELECT
		cl.region,
	    SUM(cl.current_mrr) AS total_current_mrr,
	    SUM(cl.lagged_mrr)  AS total_lagged_mrr,
	    SUM(CASE WHEN cl.current_mrr > 0 THEN cl.n_customers ELSE 0 END) AS n_active_customers,
	    SUM(CASE WHEN cl.lifecycle = 'Churn' THEN cl.lagged_mrr ELSE 0 END) AS churned_lagged_mrr,
	    SUM(CASE WHEN cl.lifecycle = 'Churn' THEN cl.n_customers ELSE 0 END) AS n_churned_customers,
	    SUM(CASE WHEN cl.lifecycle = 'New' THEN cl.n_customers ELSE 0 END) AS n_new_customers,
	    SUM(CASE WHEN cl.lifecycle = 'New' THEN cl.current_mrr ELSE 0 END) AS new_mrr,
	    SUM(CASE WHEN cl.lifecycle = 'Reactivation' THEN cl.n_customers ELSE 0 END) AS n_reactivated_customers,
	    SUM(CASE WHEN cl.lifecycle = 'Reactivation' THEN cl.current_mrr ELSE 0 END) AS reactivated_mrr
	FROM customer_lifecyle cl
	GROUP BY cl.region
),

gm_month AS (
	SELECT
		gm.country AS region,
    	SUM(gm.net_revenue) AS net_revenue,
    	SUM(gross_profit) AS gross_profit    
	FROM finance_metrics.monthly_contribution_margin gm
	WHERE
		-- first day of prior month
  		1 = 1
  		AND gm.date = DATE_TRUNC(CURRENT_DATE(), MONTH)
  		AND (gm.condition IS NULL OR gm.condition <> 'Services')
	GROUP BY 1
),

marketing AS (
	SELECT
		ms.country_code AS region,
		SUM(ms.cost_usd) AS marketing_spend
	FROM cac.marketing_spend AS ms
	WHERE
		DATE_TRUNC(ms.date, MONTH) = DATE_TRUNC(CURRENT_DATE(), MONTH)
	GROUP BY 1
),

acq_in_current_month AS (
	SELECT 
		region,
		COUNT(*) AS n_acq_gross
	FROM acq
	WHERE DATE_TRUNC(acq_date, MONTH) = DATE_TRUNC(CURRENT_DATE(), MONTH)
	GROUP BY 1
)

SELECT
  mf.*,
  acm.n_acq_gross,
  gm.net_revenue,
  gm.gross_profit,
  m.marketing_spend
FROM mrr_final AS mf
LEFT JOIN acq_in_current_month AS acm
	ON mf.region = acm.region
LEFT JOIN gm_month AS gm
  ON mf.region = gm.region
LEFT JOIN marketing AS m
  ON LOWER(gm.region) = LOWER(m.region)
ORDER BY mf.region