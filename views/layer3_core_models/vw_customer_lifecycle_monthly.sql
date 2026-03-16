DROP VIEW IF EXISTS finance_metrics.customer_lifecycle_monthly;
CREATE VIEW finance_metrics.customer_lifecycle_monthly AS 

WITH customers_monthly AS (
    SELECT
        sm.region,
        sm.customer_id,
        sm.brand,
        obs_date,
        det.condition,
        DATE_TRUNC(det.acquired_date, MONTH) AS acq_date,
        SUM(sm.mrr_usd) AS mrr_usd
    FROM all_stripe.subscription_metrics_monthly AS sm
    LEFT JOIN finance_metrics.acquisition_details AS det
    	ON sm.customer_id = det.customer_id
	GROUP BY 1,2,3,4,5,6
),

-- Calculate lags directly - no need for the complex filling logic
customers_lagged AS (
    SELECT
        region,
        customer_id,
        brand,
        condition,
        obs_date,
        acq_date,
        mrr_usd AS current_mrr,
        LAG(mrr_usd) OVER (
            PARTITION BY customer_id
            ORDER BY obs_date
        ) AS lagged_mrr
    FROM customers_monthly
),

customers_lifecyle AS (
    SELECT
        region,
        obs_date,
        acq_date,
        customer_id,
        brand,
        condition,
        current_mrr,
        COALESCE(lagged_mrr, 0) AS lagged_mrr,
        CASE
            WHEN current_mrr > 0 AND obs_date = acq_date THEN 'New'
            WHEN current_mrr = 0 AND lagged_mrr > 0 THEN 'Churn'
            WHEN current_mrr > 0 AND lagged_mrr = 0 AND obs_date != acq_date THEN 'Reactivation'
            WHEN current_mrr > lagged_mrr AND lagged_mrr > 0 THEN 'Expansion'
            WHEN current_mrr < lagged_mrr AND current_mrr > 0 THEN 'Contraction'
            WHEN current_mrr = lagged_mrr AND current_mrr > 0 THEN 'Retention'
            ELSE NULL
        END AS lifecycle
    FROM customers_lagged
    WHERE current_mrr > 0 OR lagged_mrr > 0
),

final AS (
	SELECT
	    region,
	    obs_date,
	    lifecycle,
	    condition,
	    brand,
	    COUNT(DISTINCT customer_id) AS n_customers,
	    SUM(current_mrr) AS current_mrr,
	    SUM(lagged_mrr) AS lagged_mrr
	FROM customers_lifecyle
	WHERE lifecycle IS NOT NULL
	GROUP BY 1,2,3,4,5
)

SELECT *
FROM final