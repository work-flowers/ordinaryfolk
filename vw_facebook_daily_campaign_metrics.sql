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
		CAST(campaign_id AS STRING) AS campaign_id
	FROM facebook_ads.ad_history
	QUALIFY ROW_NUMBER() OVER(PARTITION BY id ORDER BY updated_time DESC) = 1
),

<<<<<<< Updated upstream
<<<<<<< Updated upstream
=======
=======
>>>>>>> Stashed changes
fb_brands AS (
	SELECT
		CAST(id AS STRING) AS account_id,
		currency,
		SPLIT(name, ' ')[OFFSET(0)] AS brand
    FROM facebook_ads.account_history
	QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY created_time DESC) = 1
),
<<<<<<< Updated upstream
>>>>>>> Stashed changes
=======
>>>>>>> Stashed changes

revenue AS (
	SELECT
		ads.campaign_id,
    	aav.date,
    	SUM(aav.value) AS total_purchase_revenue
  	FROM facebook_ads.basic_ad_action_values aav
  	INNER JOIN ads
    	ON aav.ad_id = ads.ad_id	
	WHERE 
		1 = 1
		AND aav.action_type = 'purchase'
	GROUP BY 1,2
),

spend AS (
	SELECT
		CAST(ads.campaign_id AS STRING) AS campaign_id,
		ba.date,
		SUM(ba.spend) AS total_spend
	FROM facebook_ads.basic_ad AS ba
	LEFT JOIN ads
		ON ba.ad_id = ads.ad_id
	GROUP BY 1,2
)

SELECT
	r.date,
	r.campaign_id,
	c.campaign_name,
	c.condition,
	fb_brands.brand,
	r.total_purchase_revenue,
	s.total_spend
FROM revenue r
INNER JOIN spend s
	ON r.campaign_id = s.campaign_id 
	AND r.date = s.date
LEFT JOIN campaigns c
	ON r.campaign_id = c.campaign_id
LEFT JOIN fb_brands
	ON c.account_id = fb_brands.account_id
WHERE 
	s.total_spend > 0
ORDER BY r.date DESC