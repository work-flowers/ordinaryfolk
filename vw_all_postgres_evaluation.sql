DROP VIEW IF EXISTS all_postgres.evaluation;
CREATE VIEW all_postgres.evaluation AS 

SELECT 
	'sg' AS region,
	sg.* 
FROM sg_postgres_rds_public.evaluation AS sg

UNION ALL

SELECT 
	'hk' AS region,
	hk.* 
FROM hk_postgres_rds_public.evaluation AS hk

UNION ALL

SELECT 
	'jp' AS region,
	jp.* 
FROM jp_postgres_rds_public.evaluation AS jp;