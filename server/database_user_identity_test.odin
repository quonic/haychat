package server

import "../common"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "shared:pg"

// Runs the user identity statement against a real PostgreSQL when HAYCHAT_DATABASE_SQL_TEST=1
// (dev/live-proof.sh --all and --sql). Like the default room test, everything happens inside
// one transaction in a schema of its own that is rolled back, so the running server's accounts
// and rooms in public are never touched.

databaseIdentityTestKey :: proc() -> common.IdentityPublicKeyBytes {
	_, publicKey, keyOK := common.generateIdentityKeyPair()
	assert(keyOK, "expected test identity key generation to succeed")
	return publicKey
}

// Resolves nickname for publicKey. The caller frees the result's previousNickname; the
// account's nickname and ban reason (protocol 14) are moved to the temp allocator.
databaseIdentityTestResolve :: proc(
	conn: pg.Conn,
	nickname: string,
	publicKey: common.IdentityPublicKeyBytes,
) -> common.DatabaseUserIdentityResult {
	response := databaseExecuteRequest(
		conn,
		common.DatabaseUserIdentityRequest{nickname = nickname, publicKey = publicKey},
	)
	identity, identityOK := response.result.(common.DatabaseUserIdentityResult)
	assert(
		response.success && identityOK,
		fmt.tprintf("expected the identity statement for %q to run: %s", nickname, response.message),
	)
	delete(response.message)
	accountNickname := identity.nickname
	identity.nickname = strings.clone(accountNickname, context.temp_allocator)
	delete(accountNickname)
	banReason := identity.banReason
	identity.banReason = strings.clone(banReason, context.temp_allocator)
	delete(banReason)
	return identity
}

databaseIdentityTestMemberships :: proc(conn: pg.Conn, userID: int) -> string {
	return databaseDefaultRoomTestValue(
		conn,
		fmt.ctprintf(
			"SELECT COALESCE(string_agg(r.name, ',' ORDER BY r.name), '') FROM rooms r " +
			"JOIN room_members m ON m.room_id = r.id WHERE m.user_id = %d",
			userID,
		),
	)
}

databaseIdentityTestNickname :: proc(conn: pg.Conn, userID: int) -> string {
	return databaseDefaultRoomTestValue(
		conn,
		fmt.ctprintf("SELECT COALESCE((SELECT nickname FROM users WHERE id = %d), '')", userID),
	)
}

@(test)
testUserIdentityStatementAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}

	conn := databaseSQLTestOpen(t)

	schema := fmt.tprintf("haychat_identity_test_%d", time.time_to_unix_nano(time.now()))
	databaseDefaultRoomTestExec(conn, "begin identity test", "BEGIN")
	defer databaseDefaultRoomTestExec(conn, "roll back identity test", "ROLLBACK")
	databaseDefaultRoomTestExec(
		conn,
		"isolate identity test",
		fmt.tprintf("CREATE SCHEMA %s; SET LOCAL search_path TO %s", schema, schema),
	)
	{
		_, migrateErr := databaseApplyMigrations(conn, DATABASE_MIGRATIONS[:])
		assert(len(migrateErr) == 0, migrateErr)
	}
	databaseDefaultRoomTestExec(
		conn,
		"create rooms",
		"INSERT INTO rooms (name) VALUES ('room-one'), ('room-two')",
	)

	aliceKey := databaseIdentityTestKey()
	bobKey := databaseIdentityTestKey()
	carolKey := databaseIdentityTestKey()

	// A key with no account and a free nickname creates an account that joins every room.
	alice := databaseIdentityTestResolve(conn, "id-alice", aliceKey)
	defer delete(alice.previousNickname)
	assert(
		alice.userId > 0 && !alice.renamed && alice.previousNickname == "",
		fmt.tprintf("expected a new account for id-alice, got %v", alice),
	)
	{
		rooms := databaseIdentityTestMemberships(conn, alice.userId)
		defer delete(rooms)
		assert(
			rooms == "room-one,room-two",
			fmt.tprintf("expected a new account in every room, got %q", rooms),
		)
	}

	// A room created without members (as an admin might later make a private one) proves that
	// returning and renamed accounts are not auto-joined.
	databaseDefaultRoomTestExec(
		conn,
		"create memberless room",
		"INSERT INTO rooms (name) VALUES ('room-three')",
	)

	// The same key and nickname resolve to the same account.
	{
		again := databaseIdentityTestResolve(conn, "id-alice", aliceKey)
		defer delete(again.previousNickname)
		assert(
			again.userId == alice.userId && !again.renamed && again.previousNickname == "",
			fmt.tprintf("expected id-alice to resolve to %d unchanged, got %v", alice.userId, again),
		)
	}

	// The statement reports the admin role: false for a new account, true once the account
	// holds the role (as make-admin.sql grants it), and true again on a rename.
	assert(!alice.isAdmin, fmt.tprintf("expected a new account not to be an admin: %v", alice))
	databaseDefaultRoomTestExec(
		conn,
		"make id-alice an admin",
		fmt.tprintf(
			"INSERT INTO server_roles (name) VALUES ('admin') ON CONFLICT DO NOTHING; " +
			"INSERT INTO server_roles (name) VALUES ('moderator') ON CONFLICT DO NOTHING; " +
			"INSERT INTO user_server_roles (user_id, role_id) " +
			"SELECT %d, id FROM server_roles WHERE name = 'admin'",
			alice.userId,
		),
	)
	{
		admin := databaseIdentityTestResolve(conn, "id-alice", aliceKey)
		defer delete(admin.previousNickname)
		assert(
			admin.userId == alice.userId && admin.isAdmin,
			fmt.tprintf("expected id-alice to resolve as an admin, got %v", admin),
		)
	}

	// The same key with a free nickname renames its account and reports the old name.
	{
		renamed := databaseIdentityTestResolve(conn, "id-alice-2", aliceKey)
		defer delete(renamed.previousNickname)
		assert(
			renamed.userId == alice.userId &&
			renamed.renamed &&
			renamed.previousNickname == "id-alice" &&
			renamed.isAdmin,
			fmt.tprintf("expected admin %d renamed from id-alice, got %v", alice.userId, renamed),
		)
		nickname := databaseIdentityTestNickname(conn, alice.userId)
		defer delete(nickname)
		assert(nickname == "id-alice-2", fmt.tprintf("expected the new name, got %q", nickname))
		rooms := databaseIdentityTestMemberships(conn, alice.userId)
		defer delete(rooms)
		assert(
			rooms == "room-one,room-two",
			fmt.tprintf("expected a rename to keep its rooms and join none, got %q", rooms),
		)
	}

	bob := databaseIdentityTestResolve(conn, "id-bob", bobKey)
	defer delete(bob.previousNickname)
	assert(bob.userId > 0 && bob.userId != alice.userId, "expected a new account for id-bob")
	// Holding some other role does not make an account an admin.
	databaseDefaultRoomTestExec(
		conn,
		"make id-bob a moderator",
		fmt.tprintf(
			"INSERT INTO user_server_roles (user_id, role_id) " +
			"SELECT %d, id FROM server_roles WHERE name = 'moderator'",
			bob.userId,
		),
	)
	{
		moderator := databaseIdentityTestResolve(conn, "id-bob", bobKey)
		defer delete(moderator.previousNickname)
		assert(
			moderator.userId == bob.userId && !moderator.isAdmin,
			fmt.tprintf("expected a moderator not to be an admin, got %v", moderator),
		)
	}
	{
		rooms := databaseIdentityTestMemberships(conn, bob.userId)
		defer delete(rooms)
		assert(
			rooms == "room-one,room-three,room-two",
			fmt.tprintf("expected a new account in every room, got %q", rooms),
		)
	}

	// The same key with a nickname another account holds is refused, and changes nothing.
	{
		refused := databaseIdentityTestResolve(conn, "id-bob", aliceKey)
		defer delete(refused.previousNickname)
		assert(
			refused.userId == 0 && !refused.renamed,
			fmt.tprintf("expected renaming to a taken name to be refused, got %v", refused),
		)
		aliceName := databaseIdentityTestNickname(conn, alice.userId)
		defer delete(aliceName)
		bobName := databaseIdentityTestNickname(conn, bob.userId)
		defer delete(bobName)
		assert(
			aliceName == "id-alice-2" && bobName == "id-bob",
			fmt.tprintf("expected both names unchanged, got %q and %q", aliceName, bobName),
		)
		bobOwnsName := databaseIdentityTestResolve(conn, "id-bob", bobKey)
		defer delete(bobOwnsName.previousNickname)
		assert(bobOwnsName.userId == bob.userId, "expected id-bob to still belong to bob's key")
	}

	// A new key cannot take a nickname another key holds, but the name a rename gave up is
	// free again and makes a brand-new account that joins every room.
	{
		taken := databaseIdentityTestResolve(conn, "id-alice-2", carolKey)
		defer delete(taken.previousNickname)
		assert(taken.userId == 0, fmt.tprintf("expected a bound name refused, got %v", taken))
		carol := databaseIdentityTestResolve(conn, "id-alice", carolKey)
		defer delete(carol.previousNickname)
		assert(
			carol.userId > 0 &&
			carol.userId != alice.userId &&
			carol.userId != bob.userId &&
			!carol.renamed,
			fmt.tprintf("expected a new account under the released name, got %v", carol),
		)
		rooms := databaseIdentityTestMemberships(conn, carol.userId)
		defer delete(rooms)
		assert(
			rooms == "room-one,room-three,room-two",
			fmt.tprintf("expected a new account in every room, got %q", rooms),
		)
	}
}
