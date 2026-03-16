DROP VIEW IF EXISTS all_stripe.otc_price_id;
CREATE VIEW all_stripe.otc_price_id AS

WITH extracted AS (
	SELECT
		id AS payment_intent_id,
		description,
		REGEXP_EXTRACT_ALL(description, r'price-[a-zA-Z0-9]+\)\s*x\s*\d+') AS raw_matches,
		REGEXP_EXTRACT(description, r'Discount:\s*[-–−]?\$([0-9]+\.[0-9]+)') AS discount_amount_str,
		REGEXP_EXTRACT(description, r'Shipping:\s*\$([0-9]+\.[0-9]+)') AS shipping_amount_str
  FROM all_stripe.payment_intent
)


SELECT
	e.payment_intent_id,
	e.description,
	REPLACE(SPLIT(match, ') x ')[OFFSET(0)], '-', '_') AS price_id,
	SAFE_CAST(SPLIT(match, ') x ')[OFFSET(1)] AS INT64) AS quantity,
	COALESCE(SAFE_CAST(e.discount_amount_str AS FLOAT64), 0) AS discount_amount_local,
	COALESCE(SAFE_CAST(e.shipping_amount_str AS FLOAT64), 0) AS shipping_amount_local
FROM extracted AS e,
UNNEST(e.raw_matches) AS match