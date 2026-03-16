DROP VIEW IF EXISTS all_postgres.survey;
CREATE VIEW all_postgres.survey AS 

SELECT 
	'sg' AS region,
	sg.* 
FROM sg_postgres_rds_public.survey AS sg

UNION ALL

SELECT 
	'hk' AS region,
	hk.* 
FROM hk_postgres_rds_public.survey AS hk

UNION ALL

SELECT 
	'jp' AS region,
	jp.* 
FROM jp_postgres_rds_public.survey AS jp;