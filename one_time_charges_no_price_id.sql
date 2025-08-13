SELECT
	cm.charge_id,
	cm.purchase_date,
	ch.currency,
	ch.amount,
	pi.metadata AS payment_intent_metadata,
	pi.description AS payment_intent_description
FROM finance_metrics.contribution_margin AS cm
INNER JOIN all_stripe.charge AS ch
	ON cm.charge_id = ch.id
INNER JOIN all_stripe.payment_intent AS pi
	ON cm.payment_intent_id = pi.id
LEFT JOIN all_stripe.otc_price_id AS otc
	ON ch.payment_intent_id = otc.payment_intent_id
WHERE
	1 = 1
	AND EXTRACT(YEAR FROM cm.purchase_date) = 2025
	AND cm.sales_channel = 'Stripe'
	AND ch.invoice_id IS NULL
	AND cm.condition IS NULL
	AND otc.payment_intent_id IS NULL
	
	
	