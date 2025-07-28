-- ================================================================
-- Facebook Ads Performance Report with Revenue and Spend Analysis
-- ================================================================
-- This query creates a comprehensive report combining Facebook Ads spend data 

DROP VIEW IF EXISTS cac.facebook_campaign_metrics;
CREATE VIEW cac.facebook_campaign_metrics AS 


WITH 
	-- CTE 1: Get the latest campaign information and conditions
	campaigns AS (
		SELECT
			CAST(ch.id AS STRING) AS campaign_id, -- Convert campaign ID to string for consistent joins
			ch.name AS campaign_name, -- Campaign display name
			cmap.condition, -- Custom condition mapping from Google Sheets
			CAST(ch.account_id AS STRING) AS account_id -- Convert account ID to string for consistent joins
		FROM facebook_ads.campaign_history AS ch
		-- Join with Google Sheets to get custom campaign condition mappings
		LEFT JOIN google_sheets.campaign_condition_map AS cmap 
			ON ch.name = cmap.campaign_name
		-- Use QUALIFY to get only the most recent version of each campaign
		-- This handles cases where campaigns are updated over time
		QUALIFY ROW_NUMBER() OVER (PARTITION BY ch.id ORDER BY ch.updated_time DESC) = 1
	),
	-- CTE 2: Get the latest ad information with hierarchical relationships
	ads AS (
		SELECT
			CAST(id AS STRING) AS ad_id, -- Individual ad identifier
			CAST(ad_set_id AS STRING) AS ad_set_id, -- Parent ad set (contains targeting info)
			CAST(campaign_id AS STRING) AS campaign_id -- Parent campaign
		FROM facebook_ads.ad_history
			-- Get only the most recent version of each ad to avoid duplicates
		QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY updated_time DESC) = 1
	),
	-- CTE 3: Get account-level information including currency and brand
	accounts AS (
		SELECT
			CAST(id AS STRING) AS account_id,
			currency, -- Account currency for FX conversion
			SPLIT(name, ' ') [OFFSET(0)] AS brand -- Extract brand name (first word of account name)
		FROM facebook_ads.account_history
		-- Get the most recent account information (using created_time as proxy for latest)
		QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY _fivetran_synced DESC) = 1
	),
	-- CTE 4: Get ad set targeting information (geographic and audience targeting)
	targeting AS (
		SELECT *
		FROM facebook_ads.ad_set_history
		-- Get only the most recent targeting configuration for each ad set
		QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY updated_time DESC) = 1
	),
	-- CTE 5: Aggregate purchase revenue by ad and date
	revenue AS (
		SELECT
			CAST(aav.ad_id AS STRING) AS ad_id, -- Ad that generated the revenue
			aav.date, -- Date of the purchase
			SUM(aav.value) AS total_purchase_revenue -- Sum all purchase values for the ad/date
		FROM facebook_ads.basic_ad_action_values AS aav
		WHERE
			1 = 1 -- Placeholder for additional filters
			AND aav.action_type = 'purchase' -- Only include actual purchases (not other actions)
		GROUP BY 1, 2
	),
	
	-- CTE 6: Aggregate purchase volume by ad and date
	purchases AS (
		SELECT
			CAST(ad_id AS STRING) AS ad_id, -- Ad that generated the revenue
			date, -- Date of the purchase
			SUM(value) AS total_purchase_volume -- Sum all purchase values for the ad/date
		FROM facebook_ads.basic_ad_actions
		WHERE
			1 = 1 -- Placeholder for additional filters
			AND action_type = 'purchase' -- Only include actual purchases (not other actions)
		GROUP BY 1, 2
	),
	-- CTE 7: Aggregate spend by ad and date
	spend AS (
		SELECT
			CAST(ba.ad_id AS STRING) AS ad_id, -- Ad that incurred the spend
			ba.date, -- Date of the spend
			SUM(ba.spend) AS total_spend -- Total spend for the ad/date
		FROM facebook_ads.basic_ad AS ba
		-- Join with ads to ensure we only include valid ads
		LEFT JOIN ads 
			ON ba.ad_id = ads.ad_id
		GROUP BY 1,2
	)
	-- ================================================================
	-- MAIN QUERY: Combine all CTEs for final reporting
	-- ================================================================
SELECT
	s.date, -- Reporting date
	c.campaign_id, -- Campaign identifier
	c.campaign_name, -- Campaign display name
	c.condition, -- Custom campaign condition from mapping
	accounts.brand, -- Brand name extracted from account
	accounts.currency, 
	-- Complex country extraction logic with fallback hierarchy
	-- Tries multiple targeting fields to determine the target country
	COALESCE(
		REGEXP_REPLACE(targeting.targeting_geo_locations_countries, r'[\[\]"]', ''), -- Remove JSON formatting from countries
		JSON_VALUE(targeting.targeting_geo_locations_cities, '$[0].country'), -- Extract country from first city
		JSON_VALUE(targeting.targeting_geo_locations_regions, '$[0].country'), -- Extract country from first region
		JSON_VALUE(targeting.targeting_geo_locations_custom_locations, '$[0].country') -- Extract country from custom locations
	) AS country,
	mt.cpr_threshold,
	-- COALESCE handles cases where there's no revenue data (sets to 0)
	SUM(COALESCE(p.total_purchase_volume, 0)) AS purchase_volume,
	SUM(COALESCE(r.total_purchase_revenue, 0)) AS purchase_revenue,
	-- Convert spend to USD using foreign exchange rates
	SUM(s.total_spend) AS spend
FROM spend AS s -- Start with spend data as the base

-- Left join revenue to include spend records even without corresponding revenue
LEFT JOIN revenue AS r 
	ON s.ad_id = r.ad_id
	AND s.date = r.date

-- Left join purchase volumes for calculating CPR
LEFT JOIN purchases AS p
	ON s.ad_id = p.ad_id
	AND s.date = p.date

-- Inner join ads to get campaign/ad set hierarchy (required for targeting info)
INNER JOIN ads 
	ON s.ad_id = ads.ad_id
	-- Left join targeting to get geographic and audience information
LEFT JOIN targeting 
	ON ads.ad_set_id = CAST(targeting.id AS STRING)

-- Left join campaigns to get campaign-level information and conditions
LEFT JOIN campaigns AS c 
	ON ads.campaign_id = c.campaign_id

-- Left join accounts to get brand and currency information
INNER JOIN accounts 
	ON c.account_id = accounts.account_id
	AND accounts.currency = 'SGD' -- only include ad accounts denominated in SGD


-- Left join CPR thresholds for "winning" campaigns	
LEFT JOIN google_sheets.marketing_thresholds AS mt
	ON c.condition = mt.condition

WHERE
	1 = 1
	AND s.total_spend > 0 -- Only include records with actual spend (exclude $0 spend days)

GROUP BY 1,2,3,4,5,6,7,8