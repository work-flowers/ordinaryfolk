SELECT DISTINCT
	pat.sys_id AS patient_sys_id,
	DATE_DIFF(CURRENT_DATE(), pat.dob, YEAR) AS age,
	INITCAP(pat.gender) AS gender


FROM finance_metrics.contribution_margin AS cm
INNER JOIN all_postgres.patient AS pat
	ON cm.customer_id = pat.stripe_customer_id
WHERE 
	1 = 1
	AND cm.product_name = 'Saxenda'
	AND cm.region = 'hk'