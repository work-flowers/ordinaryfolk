SELECT
	DATE_TRUNC(cm.purchase_date, MONTH) AS purchase_month,
	cm.region,
	cm.condition,
	cm.customer_id,
	cm.charge_id,
	SUM(COALESCE(cm.line_item_amount_usd, cm.total_charge_amount_usd)) AS gross_revenue
FROM finance_metrics.contribution_margin AS cm
WHERE
	1 = 1
	AND cm.condition IS NOT NULL
	AND cm.condition NOT IN ('Services', 'Delivery')
	AND cm.customer_id IS NOT NULL
GROUP BY 1,2,3,4,5