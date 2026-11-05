-- Test fixture only. The server owns all schema creation and validation.

BEGIN;

INSERT INTO server_roles (name)
VALUES ('admin')
ON CONFLICT (name) DO NOTHING;

DELETE FROM users
WHERE (id = 1 AND nickname <> 'admin')
	OR (nickname = 'admin' AND id <> 1)
	OR (id = 2 AND nickname <> 'haypeer')
	OR (nickname = 'haypeer' AND id <> 2);

INSERT INTO users (id, nickname)
VALUES
	(1, 'admin'),
	(2, 'haypeer')
ON CONFLICT (id) DO UPDATE
SET nickname = EXCLUDED.nickname;

SELECT setval(
	pg_get_serial_sequence('users', 'id'),
	(SELECT MAX(id) FROM users),
	true
);

INSERT INTO user_server_roles (user_id, role_id)
SELECT 1, id
FROM server_roles
WHERE name = 'admin'
ON CONFLICT DO NOTHING;

INSERT INTO rooms (id, name, description, created_by_user_id)
VALUES (1, 'general', 'General discussion', 1)
ON CONFLICT (id) DO UPDATE
SET name = EXCLUDED.name,
	description = EXCLUDED.description;

-- Rooms are open: every account is a member of every room. Accounts created by the server
-- join existing rooms on their own; this covers the fixture users and any account that
-- connected before #general existed.
INSERT INTO room_members (room_id, user_id)
SELECT 1, id
FROM users
ON CONFLICT DO NOTHING;

COMMIT;

SELECT id, nickname
FROM users
WHERE id IN (1)
ORDER BY id;