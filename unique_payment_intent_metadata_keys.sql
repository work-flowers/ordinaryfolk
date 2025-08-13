WITH metadata_keys AS (
  SELECT REGEXP_EXTRACT_ALL(metadata, r'"([^"]+)":') as keys
  FROM `noah-e30be.all_stripe.payment_intent`
  WHERE metadata IS NOT NULL 
    AND metadata != ''
    AND metadata != '{}'
    AND metadata != 'null'
)
SELECT DISTINCT key
FROM metadata_keys, UNNEST(keys) as key
WHERE key IS NOT NULL
ORDER BY 1
