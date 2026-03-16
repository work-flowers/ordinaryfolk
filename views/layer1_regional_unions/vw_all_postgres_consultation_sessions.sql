DROP VIEW IF EXISTS all_postgres.consultation_sessions;
CREATE VIEW all_postgres.consultation_sessions AS 

SELECT 
	'sg' AS region,
	sys_id,
	created_at,
	updated_at,
	updated_by,
	order_sys_id,
	consultation_session_status,
	consultation_session_type,
	text_conversation_id,
	doctorsysid, 
	progress_status, 
	consultationauditsysid,
	prescribed_at,  
	_fivetran_deleted,
	_fivetran_synced
FROM sg_postgres_rds_public.consultation_sessions AS sg

UNION ALL

SELECT 
	'hk' AS region,
	sys_id,
	created_at,
	updated_at,
	updated_by,
	order_sys_id,
	consultation_session_status,
	consultation_session_type,
	text_conversation_id,
	doctorsysid, 
	progress_status, 
	consultationauditsysid,
	prescribed_at,  
	_fivetran_deleted,
	_fivetran_synced
FROM hk_postgres_rds_public.consultation_sessions AS hk

UNION ALL

SELECT 
	'jp' AS region,
	sys_id,
	created_at,
	updated_at,
	updated_by,
	order_sys_id,
	consultation_session_status,
	consultation_session_type,
	text_conversation_id,
	doctorsysid, 
	progress_status, 
	consultationauditsysid,
	prescribed_at,  
	_fivetran_deleted,
	_fivetran_synced
FROM jp_postgres_rds_public.consultation_sessions AS jp;