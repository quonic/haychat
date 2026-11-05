-- Gives one existing account the server's admin role.
--
-- The server creates #general by itself on first start, so a fresh server needs no SQL to be
-- usable. An admin can create, rename, and delete rooms and manage members through the
-- protocol (the client has no UI for that yet). Connect once with the client, using the
-- display name that should own the server, then run (see deploy/README.md):
--
--   psql -v owner=NICKNAME -f make-admin.sql
--
-- Safe to run again. It fails without changing anything when no account has that name.

\set ON_ERROR_STOP on

BEGIN;

SELECT set_config('haychat.owner', :'owner', true) AS owner;

DO $$
DECLARE
	ownerNickname TEXT := current_setting('haychat.owner');
	ownerID BIGINT;
BEGIN
	SELECT id INTO ownerID FROM users WHERE nickname = ownerNickname;
	IF ownerID IS NULL THEN
		RAISE EXCEPTION 'no account is named %: connect once with that display name first',
			ownerNickname;
	END IF;

	INSERT INTO server_roles (name) VALUES ('admin') ON CONFLICT (name) DO NOTHING;
	INSERT INTO user_server_roles (user_id, role_id)
	SELECT ownerID, id FROM server_roles WHERE name = 'admin'
	ON CONFLICT DO NOTHING;

	RAISE NOTICE '% is an admin', ownerNickname;
END
$$;

COMMIT;
