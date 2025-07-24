WITH campaigns AS (
  SELECT
    ch.id AS campaign_id,
    ch.name AS campaign_name,
    cmap.condition
  FROM facebook_ads.campaign_history AS ch
  LEFT JOIN google_sheets.campaign_condition_map AS cmap
    ON ch.name = cmap.campaign_name
  QUALIFY ROW_NUMBER() OVER(PARTITION BY ch.id ORDER BY ch.updated_time DESC) = 1
),

ads AS (
	SELECT	
		CAST(id AS STRING) AS ad_id,
		campaign_id
	FROM facebook_ads.ad_history
	QUALIFY ROW_NUMBER() OVER(PARTITION BY id ORDER BY updated_time DESC) = 1
),


revenue AS (
  SELECT
    ads.campaign_id,
    aav.date,
    SUM(aav.value) AS total_purchase_revenue
  FROM facebook_ads.basic_ad_action_values aav
  JOIN ads
    ON aav.ad_id = ads.ad_id
  WHERE 
  	1 = 1
  	AND aav.action_type = 'purchase'
  GROUP BY 1,2
),

spend AS (
  SELECT
    ba.campaign_id,
    ba.date,
    SUM(ba.spend) AS total_spend
  FROM facebook_ads.basic_ad ba
  GROUP BY 1,2
)

SELECT
  r.date,
  r.campaign_id,
  c.campaign_name,
  c.condition,
  r.total_purchase_revenue,
  s.total_spend
FROM revenue r
JOIN spend s
  ON r.campaign_id = s.campaign_id 
  AND r.date = s.date
LEFT JOIN campaigns c
  ON r.campaign_id = c.campaign_id
WHERE s.total_spend > 0
ORDER BY r.date DESC