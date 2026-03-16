SELECT
	cm.condition,
	SUM(COALESCE(cm.line_item_amount_usd, cm.total_charge_amount_usd)) AS gross_revenue,
	COUNT(DISTINCT cm.customer_id) AS n_customers,
	SAFE_DIVIDE(
		SUM(COALESCE(cm.line_item_amount_usd, cm.total_charge_amount_usd)),
		COUNT(DISTINCT cm.customer_id)
	) AS avg_spend_per_customer
FROM finance_metrics.contribution_margin AS cm
WHERE
	1 = 1
	AND cm.customer_id IS NOT NULL
	AND cm.condition IS NOT NULL
	AND cm.condition NOT IN ('Services', 'Delivery')
	AND cm.purchase_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 365 DAY)
GROUP BY 1