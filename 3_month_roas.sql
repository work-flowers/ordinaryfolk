-- CAC but only for NET NEW subscribers 
-- Defined as new subscribers who never made any one-time purchases prior to subscribing

WITH marketing AS (
	SELECT
		date,
		country_code AS country,
		CASE 
			WHEN condition IN ('ED', 'PE') THEN 'ED + PE'
			WHEN condition IS NOT NULL THEN condition
			ELSE 'N/A'
			END AS condition,
		brand,
		SUM(cost_usd) AS marketing_spend
	FROM cac.marketing_spend AS ms
	WHERE 
		(condition IS NULL OR condition <> 'Brand')
	GROUP BY 1,2,3,4
),

acq_dates AS (
	SELECT DISTINCT
		sh.subscription_id,
		sh.region,
		sh.created_at AS acquired_date
	FROM all_stripe.subscription_metrics AS sh
	WHERE 
		sh.mrr_usd > 0
),

acquisitions AS (
	SELECT 
		ad.region,
		CASE 
			WHEN cm.condition IN ('ED', 'PE') THEN 'ED + PE'
			WHEN cm.condition IS NOT NULL THEN condition
			ELSE 'N/A'
			END AS condition,
		ad.acquired_date,
		cm.brand,
		COUNT(ad.subscription_id) AS n_new_subscriptions,
		SUM(COALESCE(cm.line_item_amount_usd, cm.total_charge_amount_usd)) AS gross_revenue
	FROM acq_dates AS ad
	INNER JOIN finance_metrics.contribution_margin AS cm
		ON ad.region = cm.region
		AND ad.subscription_id = cm.subscription_id
		AND cm.purchase_date >= ad.acquired_date
		AND cm.purchase_date < DATE_ADD(ad.acquired_date, INTERVAL 3 MONTH)
		AND (cm.condition IS NULL OR cm.condition <> 'Services')
	GROUP BY 1,2,3,4
)

SELECT
	mar.date,
	mar.country,
	mar.marketing_spend,
	mar.condition,
	mar.brand,
	COALESCE(a.n_new_subscriptions, 0) AS n_new_subscriptions,
	COALESCE(a.gross_revenue, 0) AS gross_revenue_first_3_months
	
FROM marketing AS mar
LEFT JOIN acquisitions AS a
	ON mar.date = a.acquired_date
	AND LOWER(mar.country) = LOWER(a.region)
	AND mar.condition = a.condition	
	AND mar.brand = a.brand
WHERE mar.date <= DATE_SUB(CURRENT_DATE, INTERVAL 3 MONTH)