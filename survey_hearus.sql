WITH first_eval AS (
	SELECT *
	FROM all_postgres.patient_evaluation
	QUALIFY ROW_NUMBER() OVER(PARTITION BY patientsysid ORDER BY created_at DESC) = 1
)

SELECT
	s.region,
	DATE(s.created_at) AS date_created,
	INITCAP(ev.platform) AS brand,
	CASE 
		WHEN ev.name = 'Acne Zoey' THEN 'Acne'
		WHEN ev.name LIKE 'ED%' THEN 'ED'
		WHEN ev.name LIKE 'Hair Loss%' THEN 'Hair Loss'
		WHEN ev.name LIKE 'PE%' THEN 'PE'
		WHEN ev.name LIKE 'Weight Loss%' THEN 'Weight Loss'
		ELSE ev.name 
		END AS condition, 
	JSON_VALUE(item, '$.key') AS answer
FROM all_postgres.survey AS s
CROSS JOIN UNNEST(JSON_QUERY_ARRAY(answers)) AS item
LEFT JOIN first_eval AS fe
	ON s.patientsysid = fe.patientsysid
LEFT JOIN all_postgres.evaluation AS ev
	ON fe.evaluationsysid = ev.sys_id 
WHERE 
	1 = 1
	AND s.type = 'HearUs'
	AND s.answers IS NOT NULL