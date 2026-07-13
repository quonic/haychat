-- HC-205: seed test identities

BEGIN;

CREATE TABLE IF NOT EXISTS users (
	id BIGINT PRIMARY KEY,
	nickname VARCHAR(32) NOT NULL UNIQUE,
	CHECK (char_length(nickname) BETWEEN 3 AND 32)
);

DELETE FROM users
WHERE (id = 1 AND nickname <> 'hayseed')
	OR (nickname = 'hayseed' AND id <> 1)
	OR (id = 2 AND nickname <> 'haypeer')
	OR (nickname = 'haypeer' AND id <> 2);

INSERT INTO users (id, nickname)
VALUES
	(1, 'hayseed'),
	(2, 'haypeer')
ON CONFLICT (id) DO UPDATE
SET nickname = EXCLUDED.nickname;

COMMIT;

SELECT id, nickname
FROM users
WHERE id IN (1, 2)
ORDER BY id;