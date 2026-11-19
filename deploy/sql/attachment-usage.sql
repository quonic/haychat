-- Shows attachment storage use (protocol 28, attachments plan D22) without a client:
--
--   psql -f attachment-usage.sql                      totals and the top 100 accounts
--   psql -v limit=20 -f attachment-usage.sql          the top 20
--   psql -v owner=alice -f attachment-usage.sql       also alice's files, newest first
--
-- Stored bytes are those of every blob that is not Removed: tombstones (removed by an admin,
-- or a cancelled upload) count toward nothing, and an upload in progress counts with the size
-- it reserved. This is what Server settings, Admin, Storage shows an admin and what the
-- per-account quota (HAYCHAT_ATTACHMENT_ACCOUNT_QUOTA_BYTES) and the capacity
-- (HAYCHAT_ATTACHMENT_CAPACITY_BYTES) compare against. The blob IDs it lists are what
-- remove-attachment.sql takes. It changes nothing.

\set ON_ERROR_STOP on
\if :{?limit}
\else
\set limit 100
\endif

SELECT count(*) FILTER (WHERE state <> 3) AS stored_blobs,
	COALESCE(sum(size) FILTER (WHERE state <> 3), 0) AS stored_bytes,
	pg_size_pretty(COALESCE(sum(size) FILTER (WHERE state <> 3), 0)) AS stored,
	count(*) FILTER (WHERE state = 0) AS uploading,
	count(*) FILTER (WHERE state = 3) AS tombstones
FROM attachments;

SELECT u.id AS user_id, u.nickname, count(*) AS blobs, sum(a.size) AS bytes,
	pg_size_pretty(sum(a.size)) AS stored
FROM attachments a JOIN users u ON u.id = a.owner_user_id
WHERE a.state <> 3
GROUP BY u.id, u.nickname
ORDER BY bytes DESC, u.id
LIMIT :limit;

\if :{?owner}
SELECT encode(a.blob_id, 'hex') AS blob,
	CASE a.state WHEN 0 THEN 'uploading' WHEN 1 THEN 'ready' WHEN 2 THEN 'bound'
		ELSE 'removed' END AS state,
	a.size AS bytes, a.encrypted,
	COALESCE(a.name, CASE WHEN a.encrypted THEN '(encrypted)' ELSE '' END) AS name,
	CASE WHEN a.room_id IS NOT NULL THEN 'room ' || a.room_id::text
		WHEN a.peer_user_id IS NOT NULL THEN 'direct message to ' || a.peer_user_id::text
		ELSE '' END AS conversation,
	a.created_at
FROM attachments a JOIN users u ON u.id = a.owner_user_id
WHERE u.nickname = :'owner'
ORDER BY a.created_at DESC, a.id DESC;
\endif
