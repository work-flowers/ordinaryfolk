CREATE OR REPLACE VIEW all_stripe.subscription_details AS 

-- view to use for condition, product, and MRR details by subscription
WITH paid_subs AS (
	SELECT DISTINCT
		inv.subscription_id
	FROM all_stripe.charge AS ch
	INNER JOIN all_stripe.invoice AS inv
		ON ch.invoice_id = inv.id
		AND inv.subscription_id IS NOT NULL
	WHERE ch.status = 'succeeded'
),

final AS (
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
		JSON_VALUE(pl.metadata, '$.boxes') AS n_boxes,
		prod.name AS product_name,
		COALESCE(JSON_VALUE(prod.metadata, '$.condition'), 'N/A') AS condition
	FROM all_stripe.subscription_item AS si
	-- Only include subs with at least 1 successful charge
	INNER JOIN paid_subs AS ps USING(subscription_id)
	INNER JOIN all_stripe.plan AS pl
		ON si.plan_id = pl.id
	LEFT JOIN all_stripe.product AS prod
		ON pl.product_id = prod.id
	LEFT JOIN ref.stripe_currency_subunits AS subs
		ON pl.currency = subs.currency
	WHERE
		si.quantity > 0
)

SELECT 
	* EXCEPT(subscription_mrr),
	ROUND(subscription_mrr, 2) AS subscription_mrr
FROM final
