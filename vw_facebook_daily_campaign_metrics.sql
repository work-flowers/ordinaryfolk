WITH campaigns AS (
  SELECT
    CAST(ch.id AS STRING) AS campaign_id,
    ch.name AS campaign_name,
    cmap.condition,
    CAST(ch.account_id AS STRING) AS account_id
  FROM facebook_ads.campaign_history AS ch
  LEFT JOIN google_sheets.campaign_condition_map AS cmap
    ON ch.name = cmap.campaign_name
  QUALIFY ROW_NUMBER() OVER(PARTITION BY ch.id ORDER BY ch.updated_time DESC) = 1
),

ads AS (
	SELECT	
		CAST(id AS STRING) AS ad_id,
		CAST(ad_set_id AS STRING) AS ad_set_id,
		CAST(campaign_id AS STRING) AS campaign_id
	FROM facebook_ads.ad_history
	QUALIFY ROW_NUMBER() OVER(PARTITION BY id ORDER BY updated_time DESC) = 1
),

accounts AS (
	SELECT
		CAST(id AS STRING) AS account_id,
		currency,
		SPLIT(name, ' ')[OFFSET(0)] AS brand
    FROM facebook_ads.account_history
	QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY created_time DESC) = 1
),

targeting AS (
	SELECT *
	FROM facebook_ads.ad_set_history
	QUALIFY ROW_NUMBER() OVER(PARTITION BY id ORDER BY updated_time DESC) = 1
),

revenue AS (
	SELECT
		CAST(aav.ad_id AS STRING) AS ad_id,		
    	aav.date,
    	SUM(aav.value) AS total_purchase_revenue
  	FROM facebook_ads.basic_ad_action_values aav
	WHERE 
		1 = 1
		AND aav.action_type = 'purchase'
		AND aav.date = '2022-08-10'
	GROUP BY 1,2
),

spend AS (
	SELECT
		CAST(ba.ad_id AS STRING) AS ad_id,
		ba.date,
		SUM(ba.spend) AS total_spend
	FROM facebook_ads.basic_ad AS ba
	LEFT JOIN ads
		ON ba.ad_id = ads.ad_id
	GROUP BY 1,2
)

SELECT
	s.date,
	c.campaign_id,
	c.campaign_name,
	c.condition,
	accounts.brand,
	COALESCE(
    	REGEXP_REPLACE(targeting.targeting_geo_locations_countries, r'[\[\]"]', ''),
    	JSON_VALUE(targeting.targeting_geo_locations_cities, '$[0].country'),
    	JSON_VALUE(targeting.targeting_geo_locations_regions, '$[0].country'),
    	JSON_VALUE(targeting.targeting_geo_locations_custom_locations, '$[0].country')
    ) AS country,
	SUM(COALESCE(r.total_purchase_revenue / fx.fx_to_usd, 0)) AS purchase_revenue,
	SUM(s.total_spend / fx.fx_to_usd) AS spend
FROM spend AS s 
LEFT JOIN revenue AS r
	ON r.ad_id = s.ad_id
	AND r.date = s.date
INNER JOIN ads
	ON s.ad_id = ads.ad_id
LEFT JOIN targeting	
	ON ads.ad_set_id = CAST(targeting.id AS STRING)
LEFT JOIN campaigns c
	ON ads.campaign_id = c.campaign_id
LEFT JOIN accounts
	ON c.account_id = accounts.account_id
LEFT JOIN ref.fx_rates AS fx
	ON LOWER(accounts.currency) = LOWER(fx.currency)
WHERE 
	s.total_spend > 0
GROUP BY 1,2,3,4,5,6