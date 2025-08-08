SELECT DISTINCT 
	p.sys_id AS patient_id,
	REGEXP_REPLACE(add.postal, r'[^0-9]', '') AS postcode,
	DATE_DIFF(CURRENT_DATE(), p.dob, YEAR) AS age,
	cm.brand,
	COALESCE(cm.condition, 'Unknown') AS condition,
	SUM(COALESCE(line_item_amount_usd, total_charge_amount_usd)) AS gross_revenue
FROM finance_metrics.contribution_margin AS cm
INNER JOIN jp_postgres_rds_public.patient AS p
	ON cm.customer_id = p.stripe_customer_id
LEFT JOIN jp_postgres_rds_public.address AS add
	ON p.deliveryaddresssysid = add.sys_id
GROUP BY 1,2,3,4,5