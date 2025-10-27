WITH 
dates AS (
	SELECT
	  DATE_TRUNC(DATE_ADD('2022-01-01', INTERVAL n MONTH), MONTH) AS obs_date
	FROM UNNEST(GENERATE_ARRAY(0, DATE_DIFF('2025-10-01', '2022-01-01', MONTH))) AS n
),

actives AS 
(
	SELECT DISTINCT
		obs_date,
		customer_id
	FROM all_stripe.subscription_history AS sh
	INNER JOIN dates AS d
		ON DATE_TRUNC(DATE(_fivetran_start), MONTH) <= d.obs_date
		AND DATE_TRUNC(DATE(_fivetran_end), MONTH) >= d.obs_date
	WHERE 
		1 = 1
		AND sh.status IN ('active', 'trialing')
),

joined AS (
	SELECT 
		a.obs_date,
		a.customer_id,
		b.customer_id IS NOT NULL AS retained_flag
	FROM actives AS a
	LEFT JOIN actives AS b
		ON a.customer_id = b.customer_id
		AND DATE_ADD(a.obs_date, INTERVAL 1 MONTH) = b.obs_date
)

SELECT
	obs_date,
	retained_flag,
	COUNT(DISTINCT customer_id) AS n,
	SUM(COUNT(DISTINCT customer_id)) OVER(PARTITION BY obs_date) AS total_n,
	COUNT(DISTINCT customer_id) / SUM(COUNT(DISTINCT customer_id)) OVER(PARTITION BY obs_date) AS share_of_customers
FROM joined
GROUP BY 1,2
ORDER BY 1,2