CREATE OR REPLACE VIEW all_postgres.address AS 

SELECT 
    'sg' AS region,
    sg.* 
  FROM sg_postgres_rds_public.address AS sg

  UNION ALL

  SELECT 
    'hk' AS region,
    hk.* 
  FROM hk_postgres_rds_public.address AS hk

  UNION ALL

  SELECT 
    'jp' AS region,
    jp.* 
  FROM jp_postgres_rds_public.address AS jp;