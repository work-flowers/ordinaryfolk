WITH 

-- set of all customers with a transaction in the past 36 months
active_customers AS (
	SELECT DISTINCT
		customer_id
	FROM finance_metrics.contribution_margin AS cm
	WHERE
		1 = 1
		AND COALESCE(cm.line_item_amount_usd, total_charge_amount_usd) > 0
		AND cm.customer_id IS NOT NULL
		AND cm.purchase_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 36 MONTH)
),

monthly_revenue_by_customer_and_condition AS (
	SELECT
		DATE_TRUNC(cm.purchase_date, MONTH) AS purchase_month,
		region,
		customer_id,
		brand,
		condition,
		SUM(COALESCE(cm.line_item_amount_usd, cm.total_charge_amount_usd)) AS gross_revenue
	FROM finance_metrics.contribution_margin AS cm
	INNER JOIN active_customers AS ac
		USING(customer_id)
	WHERE
		1 = 1
		AND cm.customer_id IS NOT NULL
	GROUP BY 1,2,3,4,5
),

first_condition AS (
	SELECT
		mrcc.customer_id,
		mrcc.condition,
		mrcc.purchase_month AS cohort
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

total_revenue_by_customer AS (
	SELECT
		cm.region,
		cm.customer_id,
		COALESCE(brand, 'N/A') AS brand,
		cm.sales_channel,
		SUM(COALESCE(cm.line_item_amount_usd, total_charge_amount_usd)) AS gross_revenue,
		COUNT(DISTINCT cm.charge_id) AS n_charges
	FROM finance_metrics.contribution_margin AS cm
	WHERE
		1 = 1
		AND cm.purchase_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 36 MONTH)
		AND COALESCE(cm.line_item_amount_usd, total_charge_amount_usd) > 0
		AND cm.customer_id IS NOT NULL
	GROUP BY 1,2,3,4
),

revenue_enriched AS (
	SELECT 
		trc.*,
		COALESCE(fc.condition, 'N/A') AS condition,
		fc.cohort
	FROM total_revenue_by_customer AS trc
	INNER JOIN first_condition AS fc
		USING(customer_id)
)

SELECT 
	re.* ,
	DATE_DIFF(CURRENT_DATE, re.cohort, MONTH) AS age_in_months
FROM revenue_enriched AS re