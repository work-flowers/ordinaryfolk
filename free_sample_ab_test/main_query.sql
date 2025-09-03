WITH test_group AS (
	SELECT *
	FROM google_sheets.otc_ab_test
	WHERE
		1 = 1
		AND email IS NOT NULL
	QUALIFY ROW_NUMBER() OVER(PARTITION BY email ORDER BY date) = 1
)

SELECT
	cm.sales_channel,
	cm.region,
	cm.purchase_type,
	cm.new_existing,
	cm.purchase_date,
	COALESCE(cm.brand, 'N/A') AS brand,
	cm.condition,
	cm.product_name,
	cm.product_id,
	cm.charge_id,
	cm.customer_id,
	cm.subscription_id,
	tg.received_not_received,
	tg.date AS sample_date,
	COALESCE(cm.line_item_amount_usd, cm.total_charge_amount_usd) AS gross_revenue
FROM finance_metrics.contribution_margin AS cm
INNER JOIN test_group AS tg
	ON cm.email = tg.email
WHERE
	1 = 1
	AND cm.purchase_date >= '2025-01-01'