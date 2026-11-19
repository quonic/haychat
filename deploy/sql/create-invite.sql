-- Prints a new invite code (protocol 25, #43), for an operator who has no admin account yet
-- or does not want to open a client. Sign up with it in the client, or hand it on.
--
--   psql -v uses=1 -v days=7 -v note='first admin' -f create-invite.sql
--
-- Every variable is optional: uses (default 1, 0 for no limit), days until it expires (default
-- 7, 0 for never), note (shown in the Admin section's code list), and skip_approval (default
-- false; true lets the code sign up without approval when the server is in Invite + approval
-- mode). The code is a plain one: no roles, no room. To give its account the admin role
-- afterwards, run make-admin.sql with the name it signed up under.
--
-- Like the server's codes it is 20 random bytes shown as grouped Crockford base32, and only
-- sha256 of the bytes is stored, so the code is printed once and cannot be read back. The
-- bytes come from PostgreSQL's strong random source through gen_random_uuid() (the first 16
-- bytes of one UUID and 4 of another, about 154 random bits), because pgcrypto may not be
-- installed.

\set ON_ERROR_STOP on
\if :{?uses}
\else
\set uses 1
\endif
\if :{?days}
\else
\set days 7
\endif
\if :{?note}
\else
\set note 'operator code'
\endif
\if :{?skip_approval}
\else
\set skip_approval false
\endif

\pset tuples_only on
\pset format unaligned

WITH raw AS (
	SELECT substring(decode(replace(gen_random_uuid()::text, '-', '') ||
		replace(gen_random_uuid()::text, '-', ''), 'hex') FROM 1 FOR 20) AS code
),
stored AS (
	INSERT INTO invites (code_hash, note, expires_at, max_uses, skip_approval)
	SELECT sha256(code), :'note',
		CASE WHEN :days::integer > 0 THEN CURRENT_TIMESTAMP + :days::integer * interval '1 day' END,
		NULLIF(:uses::integer, 0), :'skip_approval'::boolean
	FROM raw
	RETURNING id
),
symbols AS (
	SELECT g, (get_bit(code, (g * 5) / 8 * 8 + 7 - (g * 5) % 8) << 4)
		| (get_bit(code, (g * 5 + 1) / 8 * 8 + 7 - (g * 5 + 1) % 8) << 3)
		| (get_bit(code, (g * 5 + 2) / 8 * 8 + 7 - (g * 5 + 2) % 8) << 2)
		| (get_bit(code, (g * 5 + 3) / 8 * 8 + 7 - (g * 5 + 3) % 8) << 1)
		| get_bit(code, (g * 5 + 4) / 8 * 8 + 7 - (g * 5 + 4) % 8) AS v
	FROM raw, generate_series(0, 31) AS g
)
SELECT string_agg(substr('0123456789ABCDEFGHJKMNPQRSTVWXYZ', v + 1, 1) ||
	CASE WHEN g % 4 = 3 AND g < 31 THEN '-' ELSE '' END, '' ORDER BY g)
FROM symbols, stored;
