WITH sm_new AS (
	SELECT	
		sm.subscription_id,
		SUM(sm.mrr_usd) AS mrr_usd
	
	FROM all_stripe.subscription_metrics_new AS sm
	WHERE obs_date = '2025-10-01'
	GROUP BY 1
),

old AS (
	SELECT
		sm.subscription_id,
		SUM(sm.mrr_usd) AS mrr_usd
	FROM all_stripe.subscription_metrics AS sm
	WHERE obs_date = '2025-10-01'
	GROUP BY 1
),

issue_set AS (
	SELECT
		sm_new.*
	FROM sm_new
	LEFT JOIN old
		ON sm_new.subscription_id = old.subscription_id
	WHERE old.subscription_id IS NULL
)

SELECT * FROM issue_set