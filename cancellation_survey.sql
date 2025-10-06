WITH first_eval AS (
	SELECT *
	FROM all_postgres.patient_evaluation
	QUALIFY ROW_NUMBER() OVER(PARTITION BY patientsysid ORDER BY created_at DESC) = 1
)

SELECT
  s.sys_id,
  s.region,
  DATE(s.created_at) AS created_date,
  INITCAP(ev.platform) AS brand,
CASE 
	WHEN ev.name = 'Acne Zoey' THEN 'Acne'
	WHEN ev.name LIKE 'ED%' THEN 'ED'
	WHEN ev.name LIKE 'Hair Loss%' THEN 'Hair Loss'
	WHEN ev.name LIKE 'PE%' THEN 'PE'
	WHEN ev.name LIKE 'Weight Loss%' THEN 'Weight Loss'
	ELSE ev.name 
	END AS condition,
  JSON_VALUE(JSON_EXTRACT_ARRAY(s.question_answers)[SAFE_OFFSET(0)], '$.a') AS a1,
  JSON_VALUE(JSON_EXTRACT_ARRAY(s.question_answers)[SAFE_OFFSET(0)], '$.aOther') AS aOther1,
  JSON_VALUE(JSON_EXTRACT_ARRAY(s.question_answers)[SAFE_OFFSET(1)], '$.a') AS a2,
  JSON_VALUE(JSON_EXTRACT_ARRAY(s.question_answers)[SAFE_OFFSET(1)], '$.aOther') AS aOther2
FROM all_postgres.survey AS s
LEFT JOIN first_eval AS fe
	ON s.patientsysid = fe.patientsysid
LEFT JOIN all_postgres.evaluation AS ev
	ON fe.evaluationsysid = ev.sys_id 
WHERE 
	s.type = 'OrderCancel' 

