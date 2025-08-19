SELECT
  ch.id AS charge_id,
  ch.payment_intent_id,
  DATE(ch.created) AS charge_date,
  ch.currency,
  ch.amount AS charge_amount,
  SUM(px.unit_amount) AS price_total,
  STRING_AGG(pp.price_id, ',') AS all_prices
FROM all_stripe.charge AS ch
INNER JOIN all_stripe.payment_intent_price_id AS pp
	ON ch.payment_intent_id = pp.payment_intent_id
INNER JOIN all_stripe.price AS px
	ON pp.price_id = px.id
-- anti-join - we want to *exclude* charges that are found in the otc table
LEFT JOIN all_stripe.otc_price_id AS otc
  ON ch.payment_intent_id = otc.payment_intent_id
WHERE
  ch.invoice_id IS NULL
  AND otc.price_id IS NULL -- anti-join
GROUP BY 1,2,3,4,5