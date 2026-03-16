SELECT
  ch.id AS charge_id,
  ch.payment_intent_id,
  DATE(ch.created) AS charge_date,
  ch.currency,
  ch.amount,
  JSON_VALUE(pi.metadata, '$.paymentIntentPriceId') AS paymentIntentPriceId,
  JSON_VALUE(pi.metadata, '$.stripePriceIds') AS stripePriceIds,
  JSON_VALUE(pi.metadata, '$.priceIds') AS priceIds,

  -- Normalise each field to a sorted, de-duplicated string of price IDs
  (
    SELECT
      -- count non-null original fields
      IF(
        ARRAY_LENGTH(ARRAY(SELECT x FROM UNNEST([
          JSON_VALUE(pi.metadata, '$.paymentIntentPriceId'),
          JSON_VALUE(pi.metadata, '$.stripePriceIds'),
          JSON_VALUE(pi.metadata, '$.priceIds')
        ]) AS x WHERE x IS NOT NULL AND TRIM(x) <> '')) > 1
        AND
        -- distinct canonical sets across non-null fields > 1
        ARRAY_LENGTH(ARRAY(
          SELECT DISTINCT canon
          FROM UNNEST([
            -- field 1 canon
            (SELECT IF(
               (SELECT COUNT(1) FROM UNNEST(REGEXP_EXTRACT_ALL(JSON_VALUE(pi.metadata, '$.paymentIntentPriceId'), r'price_[A-Za-z0-9_]+'))) > 0,
               (SELECT STRING_AGG(DISTINCT id, ',' ORDER BY id)
                FROM UNNEST(REGEXP_EXTRACT_ALL(JSON_VALUE(pi.metadata, '$.paymentIntentPriceId'), r'price_[A-Za-z0-9_]+')) AS id),
               NULL
            )),
            -- field 2 canon
            (SELECT IF(
               (SELECT COUNT(1) FROM UNNEST(REGEXP_EXTRACT_ALL(JSON_VALUE(pi.metadata, '$.stripePriceIds'), r'price_[A-Za-z0-9_]+'))) > 0,
               (SELECT STRING_AGG(DISTINCT id, ',' ORDER BY id)
                FROM UNNEST(REGEXP_EXTRACT_ALL(JSON_VALUE(pi.metadata, '$.stripePriceIds'), r'price_[A-Za-z0-9_]+')) AS id),
               NULL
            )),
            -- field 3 canon
            (SELECT IF(
               (SELECT COUNT(1) FROM UNNEST(REGEXP_EXTRACT_ALL(JSON_VALUE(pi.metadata, '$.priceIds'), r'price_[A-Za-z0-9_]+'))) > 0,
               (SELECT STRING_AGG(DISTINCT id, ',' ORDER BY id)
                FROM UNNEST(REGEXP_EXTRACT_ALL(JSON_VALUE(pi.metadata, '$.priceIds'), r'price_[A-Za-z0-9_]+')) AS id),
               NULL
            ))
          ]) AS canon
          WHERE canon IS NOT NULL
        )) > 1,
        TRUE, FALSE
      )
  ) AS has_conflicting_price_ids

FROM all_stripe.charge AS ch
JOIN all_stripe.payment_intent AS pi
  ON ch.payment_intent_id = pi.id
LEFT JOIN all_stripe.otc_price_id AS otc
  ON ch.payment_intent_id = otc.payment_intent_id
WHERE
  ch.invoice_id IS NULL
  AND otc.price_id IS NULL
  AND COALESCE(
    JSON_VALUE(pi.metadata, '$.paymentIntentPriceId'),
    JSON_VALUE(pi.metadata, '$.stripePriceIds'),
    JSON_VALUE(pi.metadata, '$.priceIds')
  ) IS NOT NULL;