DROP VIEW IF EXISTS finance_metrics.new_subs;
CREATE VIEW finance_metrics.new_subs AS 

WITH first_sub AS (
    SELECT
        sh.customer_id,
        sh.region,
        JSON_VALUE(pr.metadata, '$.condition') AS condition,
        DATE(sh.created) AS first_sub_created
    FROM all_stripe.subscription_history AS sh
    LEFT JOIN all_stripe.subscription_item AS si
    	ON sh.id = si.subscription_id
	LEFT JOIN all_stripe.plan AS pl
		ON si.plan_id = pl.id
	LEFT JOIN all_stripe.product AS pr
		ON pl.product_id = pr.id
    WHERE 
    	sh.status = 'active'
	QUALIFY ROW_NUMBER() OVER(PARTITION BY sh.customer_id ORDER BY sh.created DESC) = 1
),

first_charge AS (
    SELECT 
        customer_id,
        region,
        MIN(DATE(created)) AS first_charge_created
    FROM all_stripe.charge
    WHERE status = 'succeeded'
    GROUP BY 1,2
)

SELECT
    fs.customer_id,
    fs.region,
    fs.first_sub_created,
    fs.condition,
FROM first_sub AS fs
LEFT JOIN first_charge AS fc
    ON fs.customer_id = fc.customer_id
    AND fs.region = fc.region
       -- Only join if the charge was >7 days before subscription
    AND fc.first_charge_created <= DATE_SUB(fs.first_sub_created, INTERVAL 7 DAY)
WHERE 
    fc.first_charge_created IS NULL -- Only keep those with NO charge >7 days before sub