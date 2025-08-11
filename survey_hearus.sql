SELECT
	s.region,
	DATE(s.created_at) AS date_created,
	s.ordersysid,
	ev.name,
	ev.platform,
	ev.type,
	JSON_VALUE(item, '$.key') AS answer
FROM all_postgres.survey AS s
CROSS JOIN UNNEST(JSON_QUERY_ARRAY(answers)) AS item
LEFT JOIN all_postgres.order AS o
	ON s.ordersysid = o.sys_id
LEFT JOIN all_postgres.evaluation AS ev
	ON o.evaluation_id = ev.sys_id 
WHERE 
	1 = 1
	AND s.type = 'HearUs'
	AND s.answers IS NOT NULL