DROP VIEW IF EXISTS all_stripe.otc_price_id;
CREATE VIEW all_stripe.otc_price_id AS

WITH extracted AS (
  SELECT
    id AS payment_intent_id,
    description,
    REGEXP_EXTRACT_ALL(description, r'price-([a-zA-Z0-9]+)\)\s*x\s*(\d+)') AS raw_matches
  FROM all_stripe.payment_intent
),
unnested AS (
  SELECT
    payment_intent_id,
    description,
    REPLACE(SPLIT(match, ') x ')[OFFSET(0)], '-', '_') AS price_id,
    SAFE_CAST(SPLIT(match, ') x ')[OFFSET(1)] AS INT64) AS quantity
  FROM extracted,
  UNNEST(REGEXP_EXTRACT_ALL(description, r'price-[a-zA-Z0-9]+\)\s*x\s*\d+')) AS match
)
SELECT 
<<<<<<< Updated upstream
	u.*,
	px.currency,
	px.unit_amount / fx.fx_to_usd / COALESCE(sub.subunits, 100) AS amount_usd,
	pr.name AS product_name,
	JSON_VALUE(pr.metadata, '$.condition') AS condition
=======
  u.payment_intent_id,
  u.description,
  u.price_id,
  u.quantity,
  px.currency,
  u.discount_amount / fx.fx_to_usd AS discount_amount_usd,
  u.shipping_amount / fx.fx_to_usd AS shipping_amount_usd,
  px.unit_amount / fx.fx_to_usd / COALESCE(sub.subunits, 100) AS unit_amount_usd,
  pr.name AS product_name,
  JSON_VALUE(pr.metadata, '$.condition') AS condition
>>>>>>> Stashed changes
FROM unnested AS u
LEFT JOIN all_stripe.price AS px
	ON u.price_id = LOWER(px.id)
LEFT JOIN all_stripe.product AS pr
	ON px.product_id = pr.id
LEFT JOIN ref.fx_rates AS fx
	ON px.currency = fx.currency
LEFT JOIN ref.stripe_currency_subunits AS sub
	ON px.currency = sub.currency
;