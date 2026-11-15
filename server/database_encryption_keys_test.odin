package server

import "../common"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "shared:pg"

// Runs the protocol 16 statements against a real PostgreSQL when HAYCHAT_DATABASE_SQL_TEST=1
// (dev/live-proof.sh --all and --sql): publishing, replacing and fetching encryption key
// bundles, the key columns of the user list and the admin statements, and migration 5 from a
// version 4 database with rows. Each runs in a schema of its own that is rolled back.

// A publish request with recognisable bytes; nothing here checks signatures.
@(private = "file")
databaseKeysTestRequest :: proc(
	userID: int,
	fill: u8,
	createdAt: u64,
) -> common.DatabasePublishEncryptionKeyRequest {
	request := common.DatabasePublishEncryptionKeyRequest {
		userId    = userID,
		createdAt = createdAt,
	}
	for index in 0 ..< len(request.encryptionPublicKey) {
		request.encryptionPublicKey[index] = fill
	}
	for index in 0 ..< len(request.signature) {
		request.signature[index] = fill + 1
	}
	return request
}

@(private = "file")
databaseKeysTestPublish :: proc(
	conn: pg.Conn,
	request: common.DatabasePublishEncryptionKeyRequest,
) -> common.DatabasePublishEncryptionKeyResult {
	response := databaseExecuteRequest(conn, request)
	defer delete(response.message)
	result, ok := response.result.(common.DatabasePublishEncryptionKeyResult)
	assert(
		response.success && ok,
		fmt.tprintf("expected the publish statement to run: %s", response.message),
	)
	return result
}

// Runs the fetch; the caller frees the result with IPC__database_query_response_deinit.
@(private = "file")
databaseKeysTestFetch :: proc(conn: pg.Conn, userIDs: ..int) -> common.DatabaseQueryResponse {
	ids := make([dynamic]int, 0, len(userIDs))
	defer delete(ids)
	append(&ids, ..userIDs)
	response := databaseExecuteRequest(conn, common.DatabaseFetchUserKeysRequest{userIds = ids})
	_, ok := response.result.(common.DatabaseFetchUserKeysResult)
	assert(
		response.success && ok,
		fmt.tprintf("expected the fetch statement to run: %s", response.message),
	)
	return response
}

@(test)
testUserEncryptionKeyStatementsAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen("encryption_keys")
	defer databaseAdminTestClose(conn)

	aliceKey := databaseIdentityTestKey()
	alice := databaseIdentityTestResolve(conn, "keys-alice", aliceKey)
	defer delete(alice.previousNickname)
	bobKey := databaseIdentityTestKey()
	bob := databaseIdentityTestResolve(conn, "keys-bob", bobKey)
	defer delete(bob.previousNickname)
	keyless := databaseAdminTestUser(conn, "keys-keyless")
	assert(alice.userId > 0 && bob.userId > 0, "expected two accounts")

	// A first publish stores the bundle and returns it with the account's identity key.
	first := databaseKeysTestRequest(alice.userId, 0x11, 1_700_000_000)
	stored := databaseKeysTestPublish(conn, first)
	assert(
		stored.stored &&
		!stored.replaced &&
		stored.bundle.userId == alice.userId &&
		stored.bundle.identityPublicKey == aliceKey &&
		stored.bundle.encryptionPublicKey == first.encryptionPublicKey &&
		stored.bundle.createdAt == first.createdAt &&
		stored.bundle.signature == first.signature,
		fmt.tprintf("expected alice's first bundle stored, got %v", stored),
	)
	// The identical bundle again changes nothing.
	again := databaseKeysTestPublish(conn, first)
	assert(!again.stored, fmt.tprintf("expected an identical bundle to be a no-op, got %v", again))
	// A different bundle replaces it.
	second := databaseKeysTestRequest(alice.userId, 0x21, 1_700_000_100)
	replaced := databaseKeysTestPublish(conn, second)
	assert(
		replaced.stored &&
		replaced.replaced &&
		replaced.bundle.encryptionPublicKey == second.encryptionPublicKey &&
		replaced.bundle.createdAt == second.createdAt,
		fmt.tprintf("expected the new bundle to replace the old one, got %v", replaced),
	)
	count := databaseAdminTestValue(
		conn,
		"SELECT count(*)::text FROM user_encryption_keys",
	)
	assert(count == "1", fmt.tprintf("expected one row per account, got %s", count))

	// A keyless account's row (a seeded account) is never served: it has no identity key.
	databaseDefaultRoomTestExec(
		conn,
		"insert a keyless account's bundle",
		fmt.tprintf(
			"INSERT INTO user_encryption_keys (user_id, encryption_public_key, " +
			"created_at_unix, signature) VALUES (%d, decode(repeat('aa', 32), 'hex'), 1, " +
			"decode(repeat('bb', 64), 'hex'))",
			keyless,
		),
	)

	response := databaseKeysTestFetch(conn, bob.userId, 999_999, alice.userId, keyless)
	defer IPC__database_query_response_deinit(response)
	fetched := response.result.(common.DatabaseFetchUserKeysResult)
	assert(
		len(fetched.keys) == 1 &&
		fetched.keys[0].userId == alice.userId &&
		fetched.keys[0].identityPublicKey == aliceKey &&
		fetched.keys[0].encryptionPublicKey == second.encryptionPublicKey &&
		fetched.keys[0].createdAt == second.createdAt &&
		fetched.keys[0].signature == second.signature,
		fmt.tprintf("expected only alice's current bundle, got %v", fetched.keys),
	)
	assert(
		len(fetched.missingUserIds) == 3 &&
		fetched.missingUserIds[0] == bob.userId &&
		fetched.missingUserIds[1] == 999_999 &&
		fetched.missingUserIds[2] == keyless,
		fmt.tprintf("expected bob, the unknown ID and the keyless account missing, got %v",
			fetched.missingUserIds),
	)

	// The directory carries each account's identity key and whether it has a bundle.
	list := databaseExecuteRequest(conn, common.DatabaseUserDirectoryRequest{})
	defer IPC__database_query_response_deinit(list)
	directory, listOK := list.result.(common.DatabaseUserDirectoryResult)
	assert(list.success && listOK, fmt.tprintf("expected the user list: %s", list.message))
	seen := 0
	for user in directory.users {
		switch user.id {
		case alice.userId:
			assert(
				user.identityPublicKey == aliceKey && user.hasEncryptionKey,
				fmt.tprintf("expected alice's key and a bundle, got %v", user),
			)
			seen += 1
		case bob.userId:
			assert(
				user.identityPublicKey == bobKey && !user.hasEncryptionKey,
				fmt.tprintf("expected bob's key and no bundle, got %v", user),
			)
			seen += 1
		case keyless:
			assert(
				user.identityPublicKey == {} && !user.hasEncryptionKey,
				fmt.tprintf("expected the keyless account with a zero key, got %v", user),
			)
			seen += 1
		}
	}
	assert(seen == 3, fmt.tprintf("expected the three accounts listed, saw %d", seen))

	// The admin statements return the same columns for ServerUserUpdated.
	databaseAdminTestGrant(conn, bob.userId)
	renamed := databaseAdminTestExpect(
		conn,
		common.DatabaseAdminUserRequest {
			action = .Rename,
			actorUserId = bob.userId,
			targetUserId = alice.userId,
			nickname = "keys-alice2",
			locked = true,
		},
		.Applied,
		"a rename of alice",
	)
	assert(
		renamed.user.identityPublicKey == aliceKey && renamed.user.hasEncryptionKey,
		fmt.tprintf("expected the rename to report alice's key and bundle, got %v", renamed.user),
	)
	kicked := databaseAdminTestExpect(
		conn,
		common.DatabaseAdminUserRequest {
			action = .Kick,
			actorUserId = bob.userId,
			targetUserId = keyless,
		},
		.Applied,
		"a kick of the keyless account",
	)
	assert(
		kicked.user.identityPublicKey == {} && !kicked.user.hasEncryptionKey,
		fmt.tprintf("expected a zero key for the keyless account, got %v", kicked.user),
	)

	// Deleting an account deletes its bundle.
	databaseDefaultRoomTestExec(
		conn,
		"delete alice",
		fmt.tprintf("DELETE FROM users WHERE id = %d", alice.userId),
	)
	left := databaseAdminTestValue(
		conn,
		fmt.tprintf("SELECT count(*)::text FROM user_encryption_keys WHERE user_id = %d",
			alice.userId),
	)
	assert(left == "0", "expected the bundle to go with the account")
}

@(test)
testUserEncryptionKeysMigrationUpgradesVersion4AgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn, schema := databaseMigrationTestOpen("keys_v4")
	defer databaseMigrationTestClose(conn, schema)

	// A database a version 4 server migrated and used.
	databaseMigrationTestMigrate(conn, DATABASE_MIGRATIONS[:4])
	databaseDefaultRoomTestExec(conn, "fill version 4 schema", DATABASE_MIGRATION_TEST_RC1_ROWS_SQL)
	before := databaseMigrationTestValue(conn, DATABASE_MIGRATION_TEST_FINGERPRINT_SQL)

	outcome := databaseMigrationTestMigrate(conn, DATABASE_MIGRATIONS[:5])
	assert(
		outcome == DatabaseMigrationOutcome{previousVersion = 4, version = 5},
		fmt.tprintf("expected only migration 5 to run, got %v", outcome),
	)
	assert(
		databaseMigrationTestRecorded(conn) ==
		"1:baseline,2:read markers,3:admin,4:room access,5:user encryption keys",
		"expected version 5 recorded",
	)
	databaseMigrationTestValidationPassesFor(conn, DATABASE_MIGRATIONS[:5])
	after := databaseMigrationTestValue(conn, DATABASE_MIGRATION_TEST_FINGERPRINT_SQL)
	assert(
		after == before,
		fmt.tprintf("expected every row intact:\nbefore %q\nafter  %q", before, after),
	)
	empty := databaseMigrationTestValue(conn, "SELECT count(*)::text FROM user_encryption_keys")
	assert(empty == "0", "expected every existing account to start without a bundle")

	// The size checks refuse a key or signature of the wrong length and a negative createdAt.
	for values in ([]string {
			"1, decode(repeat('aa', 31), 'hex'), 1, decode(repeat('bb', 64), 'hex')",
			"1, decode(repeat('aa', 32), 'hex'), 1, decode(repeat('bb', 63), 'hex')",
			"1, decode(repeat('aa', 32), 'hex'), -1, decode(repeat('bb', 64), 'hex')",
		}) {
		databaseDefaultRoomTestExec(
			conn,
			"probe the user_encryption_keys checks",
			fmt.tprintf(
				"DO $$ BEGIN INSERT INTO user_encryption_keys (user_id, " +
				"encryption_public_key, created_at_unix, signature) VALUES (%s); " +
				"RAISE EXCEPTION 'bad bundle accepted'; " +
				"EXCEPTION WHEN check_violation THEN NULL; END $$",
				values,
			),
		)
	}
}

@(test)
testUserEncryptionKeysMigrationKeepsItsShape :: proc(t: ^testing.T) {
	_ = t
	migration := DATABASE_MIGRATIONS[4]
	assert(
		migration.version == 5 && migration.name == "user encryption keys",
		fmt.tprintf("expected migration 5 to be user encryption keys, got %v", migration),
	)
	for required in ([]string {
			"CREATE TABLE user_encryption_keys (",
			"user_id BIGINT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE",
			"encryption_public_key BYTEA NOT NULL",
			"created_at_unix BIGINT NOT NULL",
			"signature BYTEA NOT NULL",
			"updated_at TIMESTAMPTZ NOT NULL DEFAULT now()",
			"octet_length(encryption_public_key) = 32",
			"octet_length(signature) = 64",
		}) {
		assert(
			strings.contains(migration.sql, required),
			fmt.tprintf("expected migration 5 to contain %q", required),
		)
	}
	assert(!strings.contains(migration.sql, "DROP "), "expected migration 5 to drop nothing")
	assert(
		strings.contains(DATABASE_SCHEMA_VALIDATION_SQL, "user_encryption_keys table"),
		"expected schema validation to require migration 5's table",
	)
	assert(
		common.ENCRYPTION_PUBLIC_KEY_SIZE == 32 && common.AUTH_SIGNATURE_SIZE == 64,
		"expected the column checks to match the key and signature sizes",
	)
}
