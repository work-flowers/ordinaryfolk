WITH seg AS (
	SELECT
		DATE_TRUNC(DATE(tr.received_at), MONTH) AS datemonth,
		COUNT(DISTINCT oc.message_id) AS n_orders
	FROM segment.order_completed AS oc
	INNER JOIN segment.tracks AS tr
		ON oc.message_id = tr.message_id
	GROUP BY 1
),

mp AS (
	SELECT  
		DATE_TRUNC(DATE(e.time), MONTH) AS datemonth,
		COUNT(*) AS n_orders
	
	FROM mixpanel.event AS e
	WHERE
		e.name = 'Order Completed'
	GROUP BY 1
)

SELECT

	seg.datemonth,
	seg.n_orders AS segment_orders_completed,
	mp.n_orders AS mp_orders_completed
FROM seg
LEFT JOIN mp 
	USING (datemonth)