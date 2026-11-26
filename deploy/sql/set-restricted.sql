-- Restricts one account, or lifts its restriction (protocol 25, #43 D11), without a client:
--
--   psql -v account=NICKNAME -v restricted=true -f set-restricted.sql
--   psql -v account=NICKNAME -v restricted=false -f set-restricted.sql
--
-- A restricted account sees, is seen by and exchanges direct messages with only the accounts it
-- shares a room with, and admins (docs/rooms-and-accounts.md, Restricted Accounts). Lifting the
-- restriction adds the account to every Public room, as an admin's change from a client does;
-- restricting removes no room membership (remove it from rooms with an admin's client).
-- Admins cannot be restricted.
--
-- No restart is needed (#116, migration 18): a running server hears of the change from the
-- database at once, and the account's sessions and everyone's user lists follow it, exactly
-- as after an admin's change from a client. A plain UPDATE users SET restricted = ... reaches
-- a running server the same way; this helper also joins the Public rooms while the server is
-- stopped, which a plain UPDATE then does not.
--
-- Safe to run again. It fails without changing anything when no account has that name.

\set ON_ERROR_STOP on

BEGIN;

SELECT set_config('haychat.account', :'account', true) AS account,
	set_config('haychat.restricted', :'restricted', true) AS restricted;

DO $$
DECLARE
	targetNickname TEXT := current_setting('haychat.account');
	restrictedText TEXT := lower(current_setting('haychat.restricted'));
	makeRestricted BOOLEAN;
	targetID BIGINT;
BEGIN
	makeRestricted := CASE restrictedText WHEN 'true' THEN true WHEN 'false' THEN false END;
	IF makeRestricted IS NULL THEN
		RAISE EXCEPTION 'restricted must be true or false, not %', restrictedText;
	END IF;
	SELECT id INTO targetID FROM users WHERE nickname = targetNickname;
	IF targetID IS NULL THEN
		RAISE EXCEPTION 'no account is named %', targetNickname;
	END IF;
	IF makeRestricted AND EXISTS (SELECT 1 FROM user_server_roles usr
		JOIN server_roles sr ON sr.id = usr.role_id
		WHERE usr.user_id = targetID AND sr.name = 'admin') THEN
		RAISE EXCEPTION '% is an admin; admins cannot be restricted', targetNickname;
	END IF;

	UPDATE users SET restricted = makeRestricted
	WHERE id = targetID AND restricted <> makeRestricted;
	IF NOT makeRestricted THEN
		INSERT INTO room_members (room_id, user_id)
		SELECT r.id, targetID FROM rooms r WHERE r.access = 1
		ON CONFLICT DO NOTHING;
	END IF;

	RAISE NOTICE '% is %', targetNickname,
		CASE WHEN makeRestricted THEN 'restricted' ELSE 'no longer restricted' END;
END
$$;

COMMIT;
