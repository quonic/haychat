-- Removes one attachment (protocol 28, attachments plan D22) without a client:
--
--   psql -v blob=0123456789abcdef0123456789abcdef -f remove-attachment.sql
--
-- blob is the attachment's ID, 32 hex characters (attachment-usage.sql -v owner=NAME lists
-- them). A Ready or Bound attachment becomes a Removed tombstone, exactly as an admin's
-- Remove attachment makes it, except that removed_by_user_id stays empty: its message stays
-- and lists the file as removed, nobody can download it, and it no longer counts toward its
-- owner's quota. It fails without changing anything for an unknown, uploading or already
-- removed attachment.
--
-- SQL cannot reach the server's storage worker or its clients, so two things happen later:
--
-- - The file in HAYCHAT_ATTACHMENT_DIR is deleted by the server's hourly pass (and at its next
--   start). A download already running is cut off by that pass too.
-- - Connected clients see the file as removed on their next history fetch, as with other
--   changes made in the database. An admin who removes it from the client tells everyone who
--   may read the message at once.

\set ON_ERROR_STOP on

BEGIN;

SELECT set_config('haychat.blob', :'blob', true) AS blob;

DO $$
DECLARE
	blobHex TEXT := lower(current_setting('haychat.blob'));
	removedRows INTEGER;
	currentState SMALLINT;
BEGIN
	IF blobHex !~ '^[0-9a-f]{32}$' THEN
		RAISE EXCEPTION 'blob must be 32 hex characters, not %', blobHex;
	END IF;
	UPDATE attachments SET state = 3, removed_at = now()
	WHERE blob_id = decode(blobHex, 'hex') AND state IN (1, 2);
	GET DIAGNOSTICS removedRows = ROW_COUNT;
	IF removedRows = 0 THEN
		SELECT state INTO currentState FROM attachments WHERE blob_id = decode(blobHex, 'hex');
		IF currentState IS NULL THEN
			RAISE EXCEPTION 'no attachment has the ID %', blobHex;
		ELSIF currentState = 3 THEN
			RAISE EXCEPTION 'attachment % is already removed', blobHex;
		END IF;
		RAISE EXCEPTION 'attachment % is still uploading', blobHex;
	END IF;
	RAISE NOTICE 'attachment % removed; the server deletes its file within the hour', blobHex;
END
$$;

COMMIT;
