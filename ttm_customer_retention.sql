WITH monthly_revenue_by_customer_and_condition AS (
	SELECT
		DATE_TRUNC(cm.purchase_date, MONTH) AS purchase_month,
		region,
		customer_id,
		brand,
		condition,
		SUM(COALESCE(cm.line_item_amount_usd, cm.total_charge_amount_usd)) AS gross_revenue
	FROM finance_metrics.contribution_margin AS cm
	WHERE
		1 = 1
		AND cm.customer_id IS NOT NULL
	GROUP BY 1,2,3,4,5
),

first_condition AS (
	SELECT
		mrcc.customer_id,
		mrcc.condition
	FROM monthly_revenue_by_customer_and_condition AS mrcc
	WHERE
		1 = 1
		AND mrcc.condition IS NOT NULL
		AND mrcc.condition NOT IN ('Services', 'Delivery')
	QUALIFY ROW_NUMBER() OVER(
		PARTITION BY customer_id 
		ORDER BY 
			purchase_month DESC, 
			gross_revenue DESC
	) = 1
),

monthly_revenue_by_customer AS (
	SELECT
		purchase_month,
		region,
		customer_id,
		brand,
		SUM(gross_revenue) AS gross_revenue
	FROM monthly_revenue_by_customer_and_condition
	GROUP BY 1,2,3,4
),
	

monthly_revenue_enriched AS (
	SELECT 
		mrc.*,
		fc.condition,
		MIN(mrc.purchase_month) OVER(PARTITION BY mrc.customer_id) AS cohort
	FROM monthly_revenue_by_customer AS mrc
	LEFT JOIN first_condition AS fc
		ON mrc.customer_id = fc.customer_id
),

obs AS (
  SELECT DISTINCT purchase_month AS obs_month 
  FROM monthly_revenue_by_customer
)

SELECT 
  o.obs_month,
  mre.region,
  mre.cohort,
  mre.condition,
  mre.brand,
  mre.customer_id
FROM obs AS o
INNER JOIN monthly_revenue_enriched AS mre
  ON mre.purchase_month BETWEEN DATE_SUB(o.obs_month, INTERVAL 11 MONTH) AND o.obs_month