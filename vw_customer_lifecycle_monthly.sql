DROP VIEW IF EXISTS finance_metrics.customer_lifecycle_monthly;
CREATE VIEW finance_metrics.customer_lifecycle_monthly AS 

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

customers_monthly AS (
    SELECT
        sm.region,
        sm.customer_id,
        CASE
            -- For canceled with zero MRR, move to first of next month
            WHEN sm.status = 'canceled' AND sm.mrr_usd = 0
            THEN DATE_TRUNC(DATE_ADD(obs_date, INTERVAL 1 MONTH), MONTH)
            -- Otherwise keep first of month
            ELSE DATE_TRUNC(sm.obs_date, MONTH)
        END AS obs_date,
        ad.acquired_date AS acq_date,
        ad.condition,
        sm.mrr_usd AS mrr_usd
    FROM all_stripe.subscription_metrics AS sm
    LEFT JOIN acq_dates AS ad
    	ON sm.customer_id = ad.customer_id
    	AND ad.rn = 1
    WHERE
        (sm.obs_date = DATE_TRUNC(obs_date, MONTH) AND sm.mrr_usd > 0) -- First of month records
        OR (sm.status = 'canceled' AND sm.mrr_usd = 0)  -- Or churn records
),

-- Calculate lags directly - no need for the complex filling logic
customers_lagged AS (
    SELECT
        region,
        customer_id,
        obs_date,
		acq_date,
        condition,
        mrr_usd AS current_mrr,
        LAG(mrr_usd) OVER (
            PARTITION BY customer_id
            ORDER BY obs_date
        ) AS lagged_mrr
    FROM customers_monthly
),

customers_lifecyle AS (
    SELECT
        region,
        obs_date,
        acq_date,
        customer_id,
        condition,
        current_mrr,
        COALESCE(lagged_mrr, 0) AS lagged_mrr,
        CASE
            WHEN current_mrr > 0 AND obs_date = acq_date THEN 'New'
            WHEN current_mrr = 0 AND lagged_mrr > 0 THEN 'Churn'
            WHEN current_mrr > 0 AND lagged_mrr = 0 AND obs_date != acq_date THEN 'Reactivation'
            WHEN current_mrr > lagged_mrr AND lagged_mrr > 0 THEN 'Expansion'
            WHEN current_mrr < lagged_mrr AND current_mrr > 0 THEN 'Contraction'
            WHEN current_mrr = lagged_mrr AND current_mrr > 0 THEN 'Retention'
            ELSE NULL
        END AS lifecycle
    FROM customers_lagged
    WHERE current_mrr > 0 OR lagged_mrr > 0
)

SELECT
    region,
    obs_date,
    lifecycle,
    condition,
    COUNT(DISTINCT customer_id) AS n_customers,
    SUM(current_mrr) AS current_mrr,
    SUM(lagged_mrr) AS lagged_mrr
FROM customers_lifecyle
WHERE lifecycle IS NOT NULL
GROUP BY 1,2,3,4