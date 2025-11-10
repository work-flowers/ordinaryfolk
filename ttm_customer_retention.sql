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
		COALESCE(brand, 'N/A') AS brand,
		SUM(gross_revenue) AS gross_revenue
	FROM monthly_revenue_by_customer_and_condition
	GROUP BY 1,2,3,4
),

monthly_revenue_enriched AS (
	SELECT 
		mrc.*,
		COALESCE(fc.condition, 'N/A') AS condition,
		MIN(mrc.purchase_month) OVER(PARTITION BY mrc.customer_id) AS cohort
	FROM monthly_revenue_by_customer AS mrc
	LEFT JOIN first_condition AS fc
		ON mrc.customer_id = fc.customer_id
),

obs AS (
  SELECT DISTINCT purchase_month AS obs_month 
  FROM monthly_revenue_by_customer
),

-- all customers who have purchased "compound products"
compound_buyers AS (
	SELECT DISTINCT
		customer_id
	FROM finance_metrics.contribution_margin
	WHERE product_id IN (
		'prod_sg_ed_silchew_12345',
		'prod_sg_ed_t20chew_12345',
		'prod_sg_ed_tadchew_12345',
		'prod_NulHzpHUq09RRN',
		'prod_NulI7SPsNtDv9N',
		'prod_sg_ed_mintad_12345',
		'prod_sg_ed_silof_12345',
		'prod_sg_edpe_CSilDap_12345',
		'prod_sg_edpe_CT20Dap_12345',
		'prod_sg_pe_DapE_12345',
		'prod_NulIStDAhaLvwf',
		'prod_KGK0NrkD3CCHPJ',
		'prod_sg_edpe_pepsdap_1234',
		'prod_sg_edpe_sildap_12345',
		'prod_sg_edpe_t20dap_12345'
	)
)

SELECT 
  o.obs_month,
  mre.region,
  mre.cohort,
  mre.condition,
  mre.brand,
  mre.customer_id,
  cb.customer_id IS NOT NULL AS compound_buyer
FROM obs AS o
INNER JOIN monthly_revenue_enriched AS mre
  ON mre.purchase_month BETWEEN DATE_SUB(o.obs_month, INTERVAL 11 MONTH) AND o.obs_month
LEFT JOIN compound_buyers AS cb
	ON mre.customer_id = cb.customer_id