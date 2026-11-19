-- Sets the server's registration mode (protocol 25, #43, plan D7) without a client:
--
--   psql -v mode=invite -f set-registration-mode.sql
--
-- mode is one of
--   open      anyone may sign up (what a new or upgraded server starts as)
--   invite    a valid invite code is needed
--   approval  a valid code makes a sign-up request that an approver accepts or declines
--
-- New sign-ins follow it at once. Connected clients see the new mode on their next connection;
-- an admin who changes it from the client (Server settings, Admin) tells everyone at once.
-- The key in HAYCHAT_ADMIN_PUBLIC_KEY can always sign up, in every mode.

\set ON_ERROR_STOP on

BEGIN;

SELECT set_config('haychat.mode', :'mode', true) AS mode;

DO $$
DECLARE
	modeName TEXT := current_setting('haychat.mode');
	modeValue SMALLINT;
BEGIN
	modeValue := CASE modeName WHEN 'open' THEN 1 WHEN 'invite' THEN 2 WHEN 'approval' THEN 3 END;
	IF modeValue IS NULL THEN
		RAISE EXCEPTION 'mode must be open, invite or approval, not %', modeName;
	END IF;
	INSERT INTO server_settings (id, registration_mode) VALUES (1, modeValue)
	ON CONFLICT (id) DO UPDATE SET registration_mode = EXCLUDED.registration_mode;
	RAISE NOTICE 'registration mode is %', modeName;
END
$$;

COMMIT;
