-- query that demonstrates that all subs with end dates <= 2025-01-01 
-- were never active at any prior point in history

SELECT DISTINCT 
	region,
	id,
	DATE(ended_at) AS end_date,
	DATE(_fivetran_start) AS from_date,
	DATE(_fivetran_end) AS to_date,
	status
FROM all_stripe.subscription_history AS sh
WHERE id IN (
	SELECT DISTINCT id
	FROM all_stripe.subscription_history
	WHERE DATE(ended_at) <= '2025-01-01'
)
ORDER BY 2,3