WITH customers AS (
	SELECT DISTINCT
		customer_id
	FROM all_stripe.charge
	WHERE status = 'succeeded'
)

SELECT
	p.sys_id,
	DATE(p.created_at) AS created_at,
	p.dob,
	p.region,
	p.country,
	c.customer_id IS NOT NULL AS is_customer
FROM all_postgres.patient AS p
LEFT JOIN customers AS c
	ON p.stripe_customer_id = c.customer_id

