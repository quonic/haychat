-- Truncates an encrypted room's damaged member log (protocol 35, #196) without a client:
--
--   psql -v room_id=12 -v to_version=4 -f truncate-room-log.sql
--
-- A member log that does not replay, or does not end at the room's head, makes the server
-- refuse every change to the room's members, and a ban names the room in failedRoomIds. The
-- server says what to do in a line of its log when it meets such a room:
--
--   [RoomLog] Room 12's member log is damaged: version 5 does not replay (BadSignature); ...
--   Truncate it to version 4 (...)
--
-- and an admin's client shows the same under Server settings, Admin, Member logs, where
-- Truncate log to version 4... does all of this on a running server and tells the members.
-- Prefer that. This helper is for a server no admin can reach.
--
-- SQL cannot check the entries' signatures, so to_version must be the version the server
-- reported: the last one that replays. The helper only checks that entries 1 to to_version
-- exist, that the first is a Create, and that there is something after it to delete (or a
-- head to move); a to_version that is too low would undo real member changes, and one that
-- is too high leaves the log damaged.
--
-- In one transaction, with the room locked, it does what the server's truncation does:
--
-- - deletes the log entries after to_version,
-- - deletes the room key envelopes, the sealed messages (with their edits) and the sealed edits
--   of the epochs after to_version, whose numbers the next entries will use again (the
--   messages' files lose their message, and the server's hourly sweeper deletes them),
-- - makes the room's members, its log managers and its access the ones at to_version, read
--   from the entries (a removed member's read marker goes too), and sets its head to
--   to_version.
--
-- It cannot reach a running server: restart the server afterwards. Until then, connected
-- clients keep what they had and the room's voice keeps the old epoch. (Database change
-- notifications, #116, would need a trigger for this table, which a rare manual repair does not
-- justify.) Members whose app had verified a version after to_version see "This room's member
-- list was changed on the server" for the room, as after an admin's truncation.

\set ON_ERROR_STOP on

BEGIN;

SELECT set_config('haychat.room_id', :'room_id', true) AS room_id,
	set_config('haychat.to_version', :'to_version', true) AS to_version;

-- The server's SQL tests run this block as it is (server/database_room_log_test.odin), with
-- the two settings above: keep it one DO block that reads only them.
DO $$
DECLARE
	roomText TEXT := current_setting('haychat.room_id');
	versionText TEXT := current_setting('haychat.to_version');
	targetRoomID BIGINT;
	toVersion BIGINT;
	isEncrypted BOOLEAN;
	headVersion BIGINT;
	lastVersion BIGINT;
	keptEntries BIGINT;
	newAccess SMALLINT;
	deletedEntries BIGINT;
	deletedEnvelopes BIGINT;
	deletedEdits BIGINT;
	deletedMessages BIGINT;
	removedMembers BIGINT;
	addedMembers BIGINT;
BEGIN
	IF roomText !~ '^[0-9]{1,18}$' OR versionText !~ '^[0-9]{1,18}$' THEN
		RAISE EXCEPTION 'room_id and to_version must be numbers, not % and %', roomText,
			versionText;
	END IF;
	targetRoomID := roomText::bigint;
	toVersion := versionText::bigint;
	SELECT encrypted, log_version INTO isEncrypted, headVersion FROM rooms
	WHERE id = targetRoomID FOR UPDATE;
	IF NOT FOUND THEN
		RAISE EXCEPTION 'no room has the ID %', targetRoomID;
	END IF;
	IF NOT isEncrypted THEN
		RAISE EXCEPTION 'room % is not encrypted: it has no member log', targetRoomID;
	END IF;
	IF toVersion < 1 THEN
		RAISE EXCEPTION 'to_version must be at least 1; a log whose Create does not replay '
			'cannot be kept: delete the room';
	END IF;
	SELECT COALESCE(max(version), 0), count(*) FILTER (WHERE version <= toVersion)
	INTO lastVersion, keptEntries FROM room_log_entries WHERE room_id = targetRoomID;
	IF keptEntries <> toVersion THEN
		RAISE EXCEPTION 'room % does not have every entry from version 1 to %', targetRoomID,
			toVersion;
	END IF;
	IF lastVersion = toVersion AND headVersion = toVersion THEN
		RAISE EXCEPTION 'room %''s log already ends at version %: nothing to truncate',
			targetRoomID, toVersion;
	END IF;
	IF (SELECT get_byte(entry, 49) FROM room_log_entries
		WHERE room_id = targetRoomID AND version = 1) <> 1 THEN
		RAISE EXCEPTION 'version 1 of room %''s log is not a Create', targetRoomID;
	END IF;

	DELETE FROM room_log_entries WHERE room_id = targetRoomID AND version > toVersion;
	GET DIAGNOSTICS deletedEntries = ROW_COUNT;
	DELETE FROM room_key_envelopes WHERE room_id = targetRoomID AND epoch > toVersion;
	GET DIAGNOSTICS deletedEnvelopes = ROW_COUNT;
	-- Sealed edits of kept messages made on a later epoch's chain (a SealedRoomMessage's epoch
	-- is bytes 1 to 8, little-endian); the messages' edit counts follow.
	WITH gone AS (DELETE FROM chat_message_edits ed USING chat_messages m
		WHERE ed.message_id = m.id AND m.room_id = targetRoomID AND ed.sealed IS NOT NULL
		AND octet_length(ed.sealed) >= 9
		AND (SELECT bit_or(get_byte(ed.sealed, 1 + i)::bigint << (8 * i))
			FROM generate_series(0, 7) AS i) > toVersion
		AND COALESCE(m.epoch, 0) <= toVersion
		RETURNING ed.id, ed.message_id),
	counted AS (SELECT message_id, count(*) AS n FROM gone GROUP BY message_id),
	fixed AS (UPDATE chat_messages m SET edit_count = m.edit_count - c.n,
		edited_at = (SELECT max(e.created_at) FROM chat_message_edits e
			WHERE e.message_id = m.id AND e.id NOT IN (SELECT id FROM gone))
		FROM counted c WHERE m.id = c.message_id RETURNING m.id)
	SELECT count(*) INTO deletedEdits FROM gone;
	DELETE FROM chat_messages WHERE room_id = targetRoomID AND epoch > toVersion;
	GET DIAGNOSTICS deletedMessages = ROW_COUNT;

	-- The log's state at toVersion, from the entries' fixed layout (common/e2ee.odin): action
	-- at byte 49, target at 50 and actor at 90 (8 bytes little-endian each), Create's
	-- creatorJoins at 141, its manager count at 142 (2 bytes) and its managers from 144 (an
	-- 8-byte ID and a 32-byte key each), the access of Create and SetAccess at 139. Each
	-- account's last member and manager event decides.
	CREATE TEMP TABLE haychat_log_state ON COMMIT DROP AS
	WITH e AS (SELECT version, entry, get_byte(entry, 49) AS action,
		(SELECT bit_or(get_byte(entry, 50 + i)::bigint << (8 * i))
			FROM generate_series(0, 7) AS i) AS target,
		(SELECT bit_or(get_byte(entry, 90 + i)::bigint << (8 * i))
			FROM generate_series(0, 7) AS i) AS actor
		FROM room_log_entries WHERE room_id = targetRoomID AND version <= toVersion),
	events AS (
		SELECT version, 'member' AS kind, actor AS user_id, true AS joined FROM e
		WHERE action = 1 AND get_byte(entry, 141) = 1
		UNION ALL SELECT version, 'member', target, action = 2 FROM e WHERE action IN (2, 3, 6)
		UNION ALL SELECT e.version, 'manager',
			(SELECT bit_or(get_byte(e.entry, 144 + 40 * m + i)::bigint << (8 * i))
				FROM generate_series(0, 7) AS i), true
		FROM e, generate_series(0, get_byte(e.entry, 142) + 256 * get_byte(e.entry, 143) - 1)
			AS m
		WHERE e.action = 1
		UNION ALL SELECT version, 'manager', target, action = 4 FROM e WHERE action IN (4, 5))
	SELECT kind, user_id FROM (SELECT DISTINCT ON (kind, user_id) kind, user_id, joined
		FROM events ORDER BY kind, user_id, version DESC) AS latest WHERE joined;

	DELETE FROM room_read_markers WHERE room_id = targetRoomID
	AND user_id NOT IN (SELECT user_id FROM haychat_log_state WHERE kind = 'member');
	DELETE FROM room_members WHERE room_id = targetRoomID
	AND user_id NOT IN (SELECT user_id FROM haychat_log_state WHERE kind = 'member');
	GET DIAGNOSTICS removedMembers = ROW_COUNT;
	INSERT INTO room_members (room_id, user_id)
	SELECT targetRoomID, s.user_id FROM haychat_log_state s JOIN users u ON u.id = s.user_id
	WHERE s.kind = 'member' ON CONFLICT DO NOTHING;
	GET DIAGNOSTICS addedMembers = ROW_COUNT;
	DELETE FROM room_log_managers WHERE room_id = targetRoomID
	AND user_id NOT IN (SELECT user_id FROM haychat_log_state WHERE kind = 'manager');
	INSERT INTO room_log_managers (room_id, user_id)
	SELECT targetRoomID, s.user_id FROM haychat_log_state s JOIN users u ON u.id = s.user_id
	WHERE s.kind = 'manager' ON CONFLICT DO NOTHING;
	DROP TABLE haychat_log_state;

	SELECT get_byte(entry, 139) INTO newAccess FROM room_log_entries
	WHERE room_id = targetRoomID AND version <= toVersion AND get_byte(entry, 49) IN (1, 7)
	ORDER BY version DESC LIMIT 1;
	UPDATE rooms SET log_version = toVersion, access = newAccess WHERE id = targetRoomID;

	RAISE NOTICE 'room %''s member log truncated to version %: deleted % entries, % room key '
		'envelopes, % sealed messages and % sealed edits; % members added and % removed. '
		'Restart the server.', targetRoomID, toVersion, deletedEntries, deletedEnvelopes,
		deletedMessages, deletedEdits, addedMembers, removedMembers;
END
$$;

COMMIT;
