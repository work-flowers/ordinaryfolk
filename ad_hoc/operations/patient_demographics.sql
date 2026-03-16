WITH customers AS (
	SELECT 
		customer_id,
		brand,
		condition,
		SUM(COALESCE(line_item_amount_usd, total_charge_amount_usd, 0)) AS gross_revenue
	FROM finance_metrics.contribution_margin
	WHERE 
		1 = 1
		AND COALESCE(line_item_amount_usd, total_charge_amount_usd) > 0
		AND customer_id IS NOT NULL
	GROUP BY 1,2,3
)

SELECT
	p.region,
	p.sys_id,
	INITCAP(p.gender) AS gender,
	DATE_DIFF(CURRENT_DATE(), p.dob, YEAR) AS age,
	UPPER(p.locale) AS language,
	DATE(p.created_at) AS created_at,
	p.dob,
	c.customer_id IS NOT NULL AS is_customer,
	c.brand,
	c.condition,
	c.gross_revenue
FROM all_postgres.patient AS p
LEFT JOIN customers AS c
	ON p.stripe_customer_id = c.customer_id
