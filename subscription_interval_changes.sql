
-- Step 1: Create a Common Table Expression (CTE) called 'all_intervals'
WITH all_intervals_daily AS (
    SELECT DISTINCT
        UPPER(sh.region) AS country,                         -- Normalize country/region to uppercase
        sh.id AS subscription_id,                            -- Subscription ID
        sh._fivetran_start,
        sh.status,                                           -- Subscription status (active, canceled, etc.)
        DATE(sh.created) AS subscription_created,            -- Date the subscription was created
        DATE(sh._fivetran_start) AS subscription_updated,    -- Update timestamp from Fivetran
        p.product_id,                                        -- Product ID
        prod.name AS product_name,                           -- Product name
        JSON_VALUE(prod.metadata, '$.condition') AS condition, -- Extract 'condition' from product JSON metadata
        CASE
    		WHEN p.interval = 'day' THEN p.interval_count
    		WHEN p.interval = 'week' THEN p.interval_count * 7
    		WHEN p.interval = 'month' THEN p.interval_count * 30
    		WHEN p.interval = 'year' THEN p.interval_count * 365
    		END AS current_interval_count
    FROM all_stripe.subscription_history AS sh
    JOIN all_stripe.invoice_line_item AS ili 
        ON sh.latest_invoice_id = ili.invoice_id                -- Link subscription to its most recent invoice
    JOIN all_stripe.plan AS p 
        ON ili.plan_id = p.id                                   -- Link invoice line to plan
    JOIN all_stripe.product AS prod
        ON p.product_id = prod.id                               -- Link plan to product
),

all_intervals AS (
	SELECT 
		aid.*,
        -- Previous interval count for this subscription/product pair
        LAG(aid.current_interval_count) OVER (
            PARTITION BY aid.subscription_id, aid.product_id
            ORDER BY aid._fivetran_start
        ) AS previous_interval_count,

        -- First recorded interval count in the history for this subscription/product
        FIRST_VALUE(aid.current_interval_count) OVER (
            PARTITION BY aid.subscription_id, aid.product_id
            ORDER BY aid._fivetran_start
        ) AS first_interval_count
	FROM all_intervals_daily AS aid
),

-- Step 2: Find the first qualifying active subscription interval for each subscription-product pair
first_interval AS (
    SELECT *
    FROM all_intervals
    WHERE
        1 = 1                       -- Dummy condition for easier commenting/editing
        AND first_interval_count <= 90   -- Only consider if the original interval count was <= 90 days
        AND status = 'active'           -- Only active subscriptions
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY subscription_id, product_id
        ORDER BY subscription_updated
    ) = 1                             -- Keep only the first chronological record per pair
)

-- Step 3: Main select - find upgrades within 90 days to interval counts greater than 3
SELECT 
    fi.country,                                       -- The normalized country/region
    fi.subscription_id,                               -- The subscription ID
    fi.subscription_created,                          -- Date subscription was started
    ai.subscription_updated,                          -- Date subscription was upgraded
    fi.product_id,                                    -- Product ID
    fi.product_name,                                  -- Product name
    fi.condition,                                     -- Product 'condition' metadata
    fi.first_interval_days,                          -- Original interval count (<= 90 days)
    ai.current_interval_days,                        -- The upgraded interval count (> 90 days)
    DATE_DIFF(ai.subscription_updated, ai.subscription_created, DAY) AS days_elapsed -- Days from start to upgrade
FROM first_interval AS fi
LEFT JOIN all_intervals AS ai
    ON fi.subscription_id = ai.subscription_id
    AND fi.product_id = ai.product_id
    AND ai.current_interval_days > ai.previous_interval_days         -- Only true upgrades
    AND ai.current_interval_days > 90                                 -- Only upgrades beyond days
    AND DATE_DIFF(ai.subscription_updated, ai.subscription_created, DAY)  <= 90 -- Upgrade must occur within 90 days
