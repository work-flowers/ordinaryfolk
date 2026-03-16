WITH first_day AS (
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
		CASE 
			WHEN sh.condition IN ('ED', 'PE') THEN 'ED + PE'
			ELSE COALESCE(sh.condition, 'N/A') 
			END AS condition,
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

-- current snapshot: strict equality (subscription_metrics is today-only)
current_pt AS (
	SELECT
		s.customer_id,
		s.region,
		SUM(s.mrr_usd) AS current_mrr
	FROM all_stripe.subscription_metrics AS s
	WHERE 
		s.obs_date = CURRENT_DATE()
	GROUP BY 1,2
),


-- prior snapshot: last state on/before same day last month (handles missing exact date)
prior_pt AS (
	SELECT
		s.customer_id,
		s.region,
		SUM(s.mrr_usd) AS prior_mrr
	FROM all_stripe.subscription_metrics s
	WHERE 
  		s.obs_date = DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH)
	GROUP BY 1,2
),


combined AS (
	SELECT
		COALESCE(c.customer_id, p.customer_id) AS customer_id,
		COALESCE(c.region, p.region) AS region,
		COALESCE(c.current_mrr, 0) AS current_mrr,   
		COALESCE(p.prior_mrr, 0) AS lagged_mrr,
		ad.acquired_date,
		ad.condition,
		CURRENT_DATE() AS obs_date
	FROM current_pt AS c 
	FULL OUTER JOIN prior_pt AS p 
  		ON p.customer_id = c.customer_id
	LEFT JOIN acq_dates AS ad
		ON COALESCE(c.customer_id, p.customer_id) = ad.customer_id
),

customer_lifecyle AS (
	SELECT
		region,
		CASE
			WHEN acquired_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH) THEN 'New'
			WHEN current_mrr = 0 AND lagged_mrr > 0 THEN 'Churn'
			WHEN current_mrr > 0 AND lagged_mrr = 0 AND obs_date != acquired_date THEN 'Reactivation'
			WHEN current_mrr  > 0 THEN 'Retention'
  		END AS lifecycle,
  		condition,
		COUNT(DISTINCT customer_id) AS n_customers,
		SUM(current_mrr) AS current_mrr,
		SUM(lagged_mrr) AS lagged_mrr
	FROM combined
	WHERE 
		(current_mrr > 0 OR lagged_mrr > 0)
	GROUP BY 1,2,3
),

mrr_final AS (
	SELECT
		cl.region,
		cl.condition,
		SUM(CASE WHEN cl.current_mrr > 0 THEN cl.n_customers ELSE 0 END) AS n_active_customers,
	    SUM(cl.current_mrr) AS total_current_mrr,
	    SUM(cl.lagged_mrr)  AS total_lagged_mrr,
	    SUM(CASE WHEN cl.lifecycle = 'Churn' THEN cl.lagged_mrr ELSE 0 END) AS churned_lagged_mrr
	FROM customer_lifecyle AS cl
	GROUP BY 1,2
),

gm_ytd AS (
	SELECT
		gm.country AS region,
		CASE 
			WHEN gm.condition IN ('ED', 'PE') THEN 'ED + PE'
			ELSE COALESCE(gm.condition, 'N/A') 
			END AS condition,
    	SUM(gm.net_revenue) AS net_revenue,
    	SUM(gross_profit) AS gross_profit    
	FROM finance_metrics.monthly_contribution_margin gm
	WHERE
		-- first day of prior month
  		1 = 1
  		AND DATE_TRUNC(gm.date, YEAR) = DATE_TRUNC(CURRENT_DATE(), YEAR)
  		AND (gm.condition IS NULL OR gm.condition <> 'Services')
	GROUP BY 1,2
),

marketing AS (
	SELECT
		LOWER(ms.country_code) AS region,
		CASE 
			WHEN ms.condition IN ('ED', 'PE') THEN 'ED + PE'
			ELSE COALESCE(ms.condition, 'N/A') 
			END AS condition,
		SUM(ms.cost_usd) AS marketing_spend
	FROM cac.marketing_spend AS ms
	WHERE
		DATE_TRUNC(ms.date, YEAR) = DATE_TRUNC(CURRENT_DATE(), YEAR)
	GROUP BY 1,2
),

acq_in_current_year AS (
	SELECT 
		region,
		condition,
		COUNT(*) AS n_acq_gross
	FROM acq_dates
	WHERE 
		DATE_TRUNC(acquired_date, YEAR) = DATE_TRUNC(CURRENT_DATE(), YEAR)
		AND rn = 1
	GROUP BY 1,2
)

SELECT
  mf.*,
  acy.n_acq_gross,
  gm.net_revenue,
  gm.gross_profit,
  m.marketing_spend
FROM mrr_final AS mf
LEFT JOIN acq_in_current_year AS acy
	ON mf.region = acy.region
	AND mf.condition = acy.condition
LEFT JOIN gm_ytd AS gm
  ON mf.region = gm.region
  AND mf.condition = gm.condition
LEFT JOIN marketing AS m
  ON mf.region = m.region
  AND mf.condition = m.condition
WHERE
	mf.condition IN (
		'ED', 
		'ED + PE', 
		'PE', 
		'Weight Loss', 
		'Hair Loss'
	)