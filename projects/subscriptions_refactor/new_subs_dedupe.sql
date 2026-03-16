WITH sm_new AS (
	SELECT	
		sm.subscription_id,
		SUM(sm.mrr_usd) AS mrr_usd
	
	FROM all_stripe.subscription_metrics_new AS sm
	WHERE 
		obs_date = '2025-10-01'
		AND mrr_usd > 0
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
		sm_new.*,
	FROM sm_new
	LEFT JOIN old
		ON sm_new.subscription_id = old.subscription_id
	WHERE 
		COALESCE(old.mrr_usd, 0) = 0
),

final AS(
	SELECT 
		sm.*,
		issue_set.mrr_usd AS new_mrr,
		ROW_NUMBER() OVER(PARTITION BY sm.subscription_id ORDER BY sm.obs_date DESC) AS rn
	FROM all_stripe.subscription_metrics AS sm
	INNER JOIN issue_set
		ON sm.subscription_id = issue_set.subscription_id

)
SELECT *
FROM final
WHERE
	rn <= 5
	AND ROUND(mrr_usd, 0) <> ROUND(new_mrr, 0)
ORDER BY subscription_id, obs_date DESC	

