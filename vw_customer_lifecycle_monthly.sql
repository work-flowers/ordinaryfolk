DROP VIEW IF EXISTS finance_metrics.customer_lifecycle_monthly;
CREATE VIEW finance_metrics.customer_lifecycle_monthly AS 

WITH customers_monthly AS (
    SELECT
        region,
        customer_id,
        CASE
            -- For canceled with zero MRR, move to first of next month
            WHEN status = 'canceled' AND mrr_usd = 0
            THEN DATE_TRUNC(DATE_ADD(obs_date, INTERVAL 1 MONTH), MONTH)
            -- Otherwise keep first of month
            ELSE DATE_TRUNC(obs_date, MONTH)
        END AS obs_date,
        mrr_usd AS mrr_usd
    FROM all_stripe.subscription_metrics
    WHERE
        (obs_date = DATE_TRUNC(obs_date, MONTH) AND mrr_usd > 0) -- First of month records
        OR (status = 'canceled' AND mrr_usd = 0)  -- Or churn records
),

-- Calculate lags directly - no need for the complex filling logic
customers_lagged AS (
    SELECT
        region,
        customer_id,
        obs_date,
        mrr_usd AS current_mrr,
        LAG(mrr_usd) OVER (
            PARTITION BY customer_id
            ORDER BY obs_date
        ) AS lagged_mrr,
        MIN(CASE WHEN mrr_usd > 0 THEN obs_date END) OVER (
            PARTITION BY customer_id
        ) AS acq_date
    FROM customers_monthly
),

customers_lifecyle AS (
    SELECT
        region,
        obs_date,
        acq_date,
        customer_id,
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
)

SELECT
    region,
    obs_date,
    lifecycle,
    COUNT(DISTINCT customer_id) AS n_customers,
    SUM(current_mrr) AS current_mrr,
    SUM(lagged_mrr) AS lagged_mrr
FROM customers_lifecyle
WHERE lifecycle IS NOT NULL
GROUP BY 1,2,3