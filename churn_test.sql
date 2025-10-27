WITH actives AS 
(
	SELECT
		obs_date,
		customer_id,
		SUM(mrr_usd) AS mrr_usd
	FROM all_stripe.subscription_metrics
	WHERE 
		1 = 1
		AND obs_date = DATE_TRUNC(obs_date, MONTH)
		AND mrr_usd > 0
	GROUP BY 1,2
)
