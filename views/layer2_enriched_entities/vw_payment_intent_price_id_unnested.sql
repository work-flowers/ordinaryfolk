DROP VIEW IF EXISTS all_stripe.payment_intent_price_id;
CREATE VIEW all_stripe.payment_intent_price_id AS 

WITH base AS (
	SELECT
	    pi.id AS payment_intent_id,
		COALESCE(
			JSON_VALUE(pi.metadata, '$.paymentIntentPriceId'),
	  		JSON_VALUE(pi.metadata, '$.stripePriceIds'),
	  		JSON_VALUE(pi.metadata, '$.priceIds')
		) AS final_price_id
	FROM all_stripe.payment_intent AS pi
)
SELECT
  payment_intent_id,
  price_id
FROM base,
UNNEST(SPLIT(final_price_id, ',')) AS price_id
WHERE final_price_id IS NOT NULL