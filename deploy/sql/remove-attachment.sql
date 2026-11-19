-- Removes one attachment (protocol 28, attachments plan D22) without a client:
--
--   psql -v blob=0123456789abcdef0123456789abcdef -f remove-attachment.sql
--   psql -v blob=0123456789abcdef0123456789abcdef -v reason='Reported as spam' \
--       -f remove-attachment.sql
--
-- blob is the attachment's ID, 32 hex characters (attachment-usage.sql -v owner=NAME lists
-- them). A Ready or Bound attachment becomes a Removed tombstone, exactly as an admin's
-- Remove attachment makes it, except that removed_by_user_id stays empty: its message stays
-- and lists the file as removed, nobody can download it, and it no longer counts toward its
-- owner's quota. It fails without changing anything for an unknown, uploading or already
-- removed attachment.
--
-- Since protocol 29 (#138) it also adds a row to the removal log (attachment_removals) in the
-- same transaction, with no admin: admins see it in Server settings, Removed files, as removed
-- by an operator. reason is optional, at most 500 bytes with no control characters, and is kept
-- in the log indefinitely, as an admin's is.
--
-- SQL cannot reach the server's storage worker or its clients, so two things happen later:
--
-- - The file in HAYCHAT_ATTACHMENT_DIR is deleted by the server's hourly pass (and at its next
--   start). A download already running is cut off by that pass too.
-- - Connected clients see the file as removed on their next history fetch, as with other
--   changes made in the database. An admin who removes it from the client tells everyone who
--   may read the message at once.

\set ON_ERROR_STOP on

\if :{?reason}
\else
\set reason ''
\endif

BEGIN;

SELECT set_config('haychat.blob', :'blob', true) AS blob,
	set_config('haychat.reason', :'reason', true) <> '' AS has_reason;

-- The server's SQL tests run this block as it is (server/database_attachments_test.odin), with
-- the two settings above: keep it one DO block that reads only them.
DO $$
DECLARE
	blobHex TEXT := lower(current_setting('haychat.blob'));
	reasonText TEXT := NULLIF(current_setting('haychat.reason'), '');
	currentState SMALLINT;
	removed attachments%ROWTYPE;
BEGIN
	IF blobHex !~ '^[0-9a-f]{32}$' THEN
		RAISE EXCEPTION 'blob must be 32 hex characters, not %', blobHex;
	END IF;
	IF octet_length(reasonText) > 500 OR reasonText ~ '[\u0001-\u001f\u007f-\u009f]' THEN
		RAISE EXCEPTION 'reason must be at most 500 bytes, without control characters';
	END IF;
	UPDATE attachments SET state = 3, removed_at = now()
	WHERE blob_id = decode(blobHex, 'hex') AND state IN (1, 2)
	RETURNING * INTO removed;
	IF NOT FOUND THEN
		SELECT state INTO currentState FROM attachments WHERE blob_id = decode(blobHex, 'hex');
		IF currentState IS NULL THEN
			RAISE EXCEPTION 'no attachment has the ID %', blobHex;
		ELSIF currentState = 3 THEN
			RAISE EXCEPTION 'attachment % is already removed', blobHex;
		END IF;
		RAISE EXCEPTION 'attachment % is still uploading', blobHex;
	END IF;
	INSERT INTO attachment_removals (blob_id, owner_user_id, removed_by_user_id, removed_at,
		reason, room_id, direct, encrypted, chat_message_id, direct_message_id, name)
	VALUES (removed.blob_id, removed.owner_user_id, NULL, removed.removed_at, reasonText,
		removed.room_id,
		removed.room_id IS NULL AND (removed.peer_user_id IS NOT NULL
			OR removed.direct_message_id IS NOT NULL),
		removed.encrypted, removed.chat_message_id, removed.direct_message_id,
		CASE WHEN removed.encrypted THEN NULL ELSE removed.name END);
	RAISE NOTICE 'attachment % removed; the server deletes its file within the hour', blobHex;
END
$$;

COMMIT;
