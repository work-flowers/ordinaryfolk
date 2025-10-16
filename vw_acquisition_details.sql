DROP VIEW IF EXISTS finance_metrics.acquisition_details;
CREATE VIEW finance_metrics.acquisition_details AS 

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
)

SELECT 
	customer_id,
	region,
	condition,
	acquired_date
FROM acq_dates
WHERE rn = 1