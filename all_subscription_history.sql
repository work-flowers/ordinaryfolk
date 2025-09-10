-- Drop the existing view if it exists
DROP VIEW IF EXISTS all_stripe.subscription_metrics;

-- Create the view
CREATE VIEW all_stripe.subscription_metrics AS

WITH
-- Get all subscription state changes over time (preserve history)
subscription_history AS (
    SELECT
        region,
        id AS subscription_id,
        customer_id,
        status,
        DATE(created) AS created_at,
        DATE(COALESCE(ended_at)) AS ended_at,
        DATE(_fivetran_start) AS valid_from,
        DATE(_fivetran_end) AS valid_to
    FROM all_stripe.subscription_history
    -- control for cases where there are multiple state changes within the same day
    QUALIFY ROW_NUMBER() OVER (PARTITION BY id, DATE(_fivetran_end) ORDER BY _fivetran_end DESC) = 1
),

-- Calculate MRR per subscription_id with product and condition breakout
mrr_by_sub AS (
    SELECT
        si.subscription_id,
        pl.currency,
        pl.id AS plan_id,
        pl.interval,
        pl.interval_count,
        pl.product_id,
        CASE
            WHEN pl.interval = 'month' THEN pl.amount * si.quantity / COALESCE(subs.subunits, 100) / COALESCE(pl.interval_count, 1)
            WHEN pl.interval = 'year' THEN pl.amount * si.quantity / COALESCE(subs.subunits, 100) / (12 * COALESCE(pl.interval_count, 1))
            WHEN pl.interval = 'week' THEN pl.amount * si.quantity / COALESCE(subs.subunits, 100) * (52 / 12) / COALESCE(pl.interval_count, 1)
            WHEN pl.interval = 'day' THEN pl.amount * si.quantity / COALESCE(subs.subunits, 100) * (365 / 12)/ COALESCE(pl.interval_count, 1)
            ELSE 0
        END AS subscription_mrr,
        JSON_EXTRACT_SCALAR(pl.metadata, '$.boxes') AS n_boxes,
        prod.name AS product_name,
        COALESCE(JSON_EXTRACT_SCALAR(prod.metadata, '$.condition'), 'Other') AS condition
    FROM all_stripe.subscription_item AS si
    INNER JOIN all_stripe.plan AS pl
        ON si.plan_id = pl.id
    LEFT JOIN all_stripe.product AS prod
        ON pl.product_id = prod.id
    LEFT JOIN ref.stripe_currency_subunits AS subs
        ON pl.currency = subs.currency
    WHERE
        si.quantity > 0
        AND si.subscription_id IN (
    		SELECT DISTINCT id
    		FROM all_stripe.subscription_history
    		WHERE status = 'active'
		)
),

-- Date range calendar
calendar AS (
    SELECT
        obs_date
    FROM UNNEST(GENERATE_DATE_ARRAY(DATE '2020-08-01', CURRENT_DATE(), INTERVAL 1 DAY)) AS obs_date
),

-- Last successful charge date for canceled subscriptions
last_payment AS (
    SELECT
        i.subscription_id,
        CAST(MAX(c.created) AS DATE) AS last_paid
    FROM all_stripe.invoice AS i
    JOIN all_stripe.charge AS c
        ON i.id = c.invoice_id
        AND c.status = 'succeeded'
    GROUP BY 1
),

-- Get the final state of each subscription (for the "day after" logic)
subscription_final_state AS (
    SELECT
        region,
        id AS subscription_id,
        customer_id,
        status,
        DATE(created) AS created_at,
        DATE(ended_at) AS ended_at,
        DATE(_fivetran_start) AS valid_from,
        DATE(_fivetran_end) AS valid_to
    FROM all_stripe.subscription_history AS sh
    -- control for cases where there are multiple state changes within the same day
    QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY _fivetran_end DESC) = 1
),

-- Point-in-time subscription states INCLUDING the day after cancellation
subscription_point_in_time AS (
    -- Regular point-in-time records
    SELECT
        cal.obs_date,
        sh.region,
        sh.subscription_id,
        sh.customer_id,
        sh.status,
        sh.created_at,
        COALESCE(lp.last_paid, sfs.ended_at) AS ended_at
    FROM calendar AS cal
    INNER JOIN subscription_history AS sh
        ON cal.obs_date >= sh.valid_from
        AND cal.obs_date < sh.valid_to
    INNER JOIN subscription_final_state AS sfs
    	ON sh.subscription_id = sfs.subscription_id
	LEFT JOIN last_payment AS lp
		ON sfs.subscription_id = lp.subscription_id
        AND sfs.status = 'canceled'
	WHERE 
		1 = 1
		AND sh.status IN ('active', 'past_due')
		AND cal.obs_date <= CURRENT_DATE

    UNION ALL

    -- Add the "day after" record for ended subscriptions
    SELECT
        DATE_ADD(COALESCE(lp.last_paid, sfs.ended_at), INTERVAL 1 DAY) AS obs_date,
        sfs.region,
        sfs.subscription_id,
        sfs.customer_id,
        sfs.status,
        sfs.created_at,
        COALESCE(lp.last_paid, sfs.ended_at) AS ended_at
    FROM subscription_final_state AS sfs
    LEFT JOIN last_payment AS lp
        ON sfs.subscription_id = lp.subscription_id
        AND sfs.status = 'canceled'
    WHERE sfs.status IN ('canceled', 'ended', 'unpaid')
        AND COALESCE(lp.last_paid, sfs.ended_at) IS NOT NULL
        AND DATE_ADD(COALESCE(lp.last_paid, sfs.ended_at), INTERVAL 1 DAY) <= CURRENT_DATE()
),

-- First purchase date per customer_id
customer_first_purchase AS (
    SELECT
        customer_id,
        MIN(DATE(created)) AS first_purchase_date
    FROM all_stripe.charge
    WHERE status = 'succeeded'
    GROUP BY 1
)

-- Final SELECT
SELECT
    spit.region,
    spit.subscription_id,
    spit.customer_id,
    CASE
        WHEN cfp.first_purchase_date < spit.created_at THEN 'Existing'
        ELSE 'New'
    END AS new_existing,
    spit.obs_date,
    spit.status,
    spit.created_at,
    spit.ended_at,
    sm.currency,
    sm.plan_id,
    sm.interval,
    sm.interval_count,
    sm.product_id,
    sm.product_name,
    sm.n_boxes,
    sm.condition,
    -- MRR based on status at observation date
    CASE
        WHEN spit.status IN ('active', 'trialing')
        THEN COALESCE(sm.subscription_mrr, 0)
        ELSE 0
    END AS mrr_local,
    CASE
        WHEN spit.status IN ('active', 'trialing')
        THEN COALESCE(sm.subscription_mrr, 0) / COALESCE(fx.fx_to_usd, 1)
        ELSE 0
    END AS mrr_usd
FROM subscription_point_in_time AS spit
LEFT JOIN mrr_by_sub AS sm
    ON spit.subscription_id = sm.subscription_id
LEFT JOIN ref.fx_rates fx
    ON sm.currency = fx.currency
LEFT JOIN last_payment AS lp
    ON spit.subscription_id = lp.subscription_id
    AND spit.status = 'canceled'
LEFT JOIN customer_first_purchase AS cfp
    ON spit.customer_id = cfp.customer_id
WHERE
    spit.obs_date >= spit.created_at
