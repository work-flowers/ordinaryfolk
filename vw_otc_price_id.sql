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
),

unnested AS (
  SELECT
    e.payment_intent_id,
    e.description,
    REPLACE(SPLIT(match, ') x ')[OFFSET(0)], '-', '_') AS price_id,
    SAFE_CAST(SPLIT(match, ') x ')[OFFSET(1)] AS INT64) AS quantity,
    COALESCE(SAFE_CAST(e.discount_amount_str AS FLOAT64), 0) AS discount_amount,
    COALESCE(SAFE_CAST(e.shipping_amount_str AS FLOAT64), 0) AS shipping_amount
  FROM extracted AS e,
  UNNEST(e.raw_matches) AS match
)

SELECT 
  u.*,
  px.currency,
  px.unit_amount / fx.fx_to_usd / COALESCE(sub.subunits, 100) AS unit_amount_usd,
  pr.name AS product_name,
  JSON_VALUE(pr.metadata, '$.condition') AS condition
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