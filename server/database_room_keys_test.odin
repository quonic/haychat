package server

import "../common"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "shared:pg"

// Runs the protocol 19 statements against a real PostgreSQL when HAYCHAT_DATABASE_SQL_TEST=1
// (dev/live-proof.sh --all and --sql): sealed room messages (only in encrypted rooms, only at
// the room's log version, never a reused client message ID or chain index, byte for byte in
// history), key envelopes (only from members, to members, at the log version or as a re-seal of
// a stored chain), the fetch that returns only envelopes with a wrap for the requester, the
// key request check, and migration 8 from a version 7 database with rows. Each test runs in
// one transaction in a schema of its own that is rolled back. The statements do not look
// inside the sealed bytes (the router checked them), so made-up bytes stand in for them.

@(private = "file")
roomKeysTestRoom :: proc(conn: pg.Conn, name: string, encrypted: bool, members: []int) -> int {
	value := databaseAdminTestValue(
		conn,
		fmt.tprintf(
			"INSERT INTO rooms (name, access, history_visibility, encrypted, log_version) " +
			"VALUES ('%s', 3, 2, %v, %d) RETURNING id::text",
			name,
			encrypted,
			encrypted ? 2 : 0,
		),
	)
	roomID, ok := databaseParseTestInt(value)
	assert(ok, fmt.tprintf("expected room %s created, got %q", name, value))
	for userID in members {
		databaseAdminTestValue(
			conn,
			fmt.tprintf(
				"INSERT INTO room_members (room_id, user_id) VALUES (%d, %d) " +
				"RETURNING user_id::text",
				roomID,
				userID,
			),
		)
	}
	return roomID
}

@(private = "file")
roomKeysTestFill :: proc(fill: u8) -> (id: [16]u8) {
	for index in 0 ..< len(id) {
		id[index] = fill + u8(index)
	}
	return
}

@(private = "file")
roomKeysTestPost :: proc(
	conn: pg.Conn,
	roomID, senderID: int,
	content: string,
	sealed: []u8 = nil,
	clientMessageID := common.ClientMessageID{},
	epoch := 0,
	chainID := common.ChainID{},
	chainIndex := 0,
) -> common.DatabasePostRoomChatMessageResult {
	owned: []u8
	if len(sealed) > 0 {
		owned = make([]u8, len(sealed))
		copy(owned, sealed)
	}
	request := common.DatabasePostRoomChatMessageRequest {
		roomId          = roomID,
		senderId        = senderID,
		content         = strings.clone(content),
		clientMessageId = clientMessageID,
		sealed          = owned,
		epoch           = epoch,
		chainId         = chainID,
		chainIndex      = chainIndex,
	}
	defer IPC__database_query_request_deinit(request)
	response := databaseExecuteRequest(conn, request)
	defer IPC__database_query_response_deinit(response)
	posted, ok := response.result.(common.DatabasePostRoomChatMessageResult)
	assert(response.success && ok, fmt.tprintf("expected the post to run: %s", response.message))
	result := posted
	result.storedMessage = {
		id              = posted.storedMessage.id,
		clientMessageId = posted.storedMessage.clientMessageId,
	}
	result.recipientUserIDs = nil
	return result
}

@(private = "file")
roomKeysTestStore :: proc(
	conn: pg.Conn,
	roomID, senderID, epoch: int,
	chainID: common.ChainID,
	recipients: []int,
	envelope: []u8,
) -> (
	outcome: common.RoomKeyEnvelopeOutcome,
	storedID: int,
) {
	owned := make([]u8, len(envelope))
	copy(owned, envelope)
	ids := make([dynamic]int, 0, len(recipients))
	append(&ids, ..recipients)
	request := common.DatabaseStoreRoomKeyEnvelopeRequest {
		senderId         = senderID,
		roomId           = roomID,
		epoch            = epoch,
		chainId          = chainID,
		envelope         = owned,
		recipientUserIDs = ids,
	}
	defer IPC__database_query_request_deinit(request)
	response := databaseExecuteRequest(conn, request)
	defer IPC__database_query_response_deinit(response)
	result, ok := response.result.(common.DatabaseStoreRoomKeyEnvelopeResult)
	assert(response.success && ok, fmt.tprintf("expected the store to run: %s", response.message))
	if result.outcome == .Stored {
		assert(
			string(result.stored.envelope) == string(envelope) &&
			len(result.recipientUserIDs) == len(recipients),
			"expected the stored envelope and its recipients back",
		)
	}
	return result.outcome, result.stored.id
}

// The IDs of the envelopes userID fetches, "id:epoch:sender,…", or "refused".
@(private = "file")
roomKeysTestFetch :: proc(conn: pg.Conn, userID, roomID: int, sinceEpoch := 0) -> string {
	response := databaseExecuteRequest(
		conn,
		common.DatabaseFetchRoomKeysRequest {
			userId = userID,
			roomId = roomID,
			sinceEpoch = sinceEpoch,
		},
	)
	defer IPC__database_query_response_deinit(response)
	result, ok := response.result.(common.DatabaseFetchRoomKeysResult)
	assert(response.success && ok, fmt.tprintf("expected the fetch to run: %s", response.message))
	if !result.isMember {
		return "refused"
	}
	builder := strings.builder_make(context.temp_allocator)
	for envelope, index in result.envelopes {
		if index > 0 {
			strings.write_byte(&builder, ',')
		}
		fmt.sbprintf(&builder, "%d:%d:%d", envelope.id, envelope.epoch, envelope.senderId)
	}
	return strings.to_string(builder)
}

@(private = "file")
roomKeysTestRequestAllowed :: proc(
	conn: pg.Conn,
	requesterID, roomID, epoch, senderID: int,
	chainID: common.ChainID,
) -> bool {
	response := databaseExecuteRequest(
		conn,
		common.DatabaseRoomKeyRequestCheckRequest {
			requesterId = requesterID,
			roomId = roomID,
			epoch = epoch,
			senderId = senderID,
			chainId = chainID,
		},
	)
	defer IPC__database_query_response_deinit(response)
	result, ok := response.result.(common.DatabaseRoomKeyRequestCheckResult)
	assert(response.success && ok, fmt.tprintf("expected the check to run: %s", response.message))
	return result.allowed
}

@(test)
testRoomSenderChainStatementsAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen("room_keys")
	defer databaseAdminTestClose(conn)
	alice := databaseAdminTestUser(conn, "keys-alice")
	bob := databaseAdminTestUser(conn, "keys-bob")
	carol := databaseAdminTestUser(conn, "keys-carol")
	dave := databaseAdminTestUser(conn, "keys-dave")
	secret := roomKeysTestRoom(conn, "keys-secret", true, {alice, bob})
	plain := roomKeysTestRoom(conn, "keys-plain", false, {alice, bob})
	sealed := []u8{1, 2, 3, 4, 5, 6, 7, 8}
	idOne := common.ClientMessageID(roomKeysTestFill(1))
	idTwo := common.ClientMessageID(roomKeysTestFill(2))
	idThree := common.ClientMessageID(roomKeysTestFill(3))
	chain := common.ChainID(roomKeysTestFill(40))

	// Messages: plaintext is refused in the encrypted room and sealed bytes in the other; a
	// stale epoch and a non-member are refused; the first sealed message at the log version
	// is stored.
	refusedPlain := roomKeysTestPost(conn, secret, alice, "readable")
	assert(refusedPlain.encryptedRoom, "expected plaintext refused in the encrypted room")
	refusedSealed := roomKeysTestPost(conn, plain, alice, "", sealed, idOne, 2, chain, 0)
	assert(refusedSealed.notEncrypted, "expected sealed bytes refused in an unencrypted room")
	stale := roomKeysTestPost(conn, secret, alice, "", sealed, idOne, 1, chain, 0)
	assert(stale.isMember && stale.staleEpoch, "expected epoch 1 refused at log version 2")
	ahead := roomKeysTestPost(conn, secret, alice, "", sealed, idOne, 3, chain, 0)
	assert(ahead.staleEpoch, "expected epoch 3 refused at log version 2")
	outsider := roomKeysTestPost(conn, secret, carol, "", sealed, idOne, 2, chain, 0)
	assert(!outsider.isMember, "expected carol, not a member, refused")
	stored := roomKeysTestPost(conn, secret, alice, "", sealed, idOne, 2, chain, 0)
	assert(
		stored.isMember &&
		!stored.staleEpoch &&
		!stored.duplicate &&
		stored.storedMessage.id > 0 &&
		stored.storedMessage.clientMessageId == idOne,
		fmt.tprintf("expected the sealed message stored, got %v", stored),
	)
	// A reused client message ID, and a reused chain index under a new ID, store nothing.
	again := roomKeysTestPost(conn, secret, alice, "", sealed, idOne, 2, chain, 1)
	assert(again.duplicate, "expected a reused client message ID refused")
	reused := roomKeysTestPost(conn, secret, alice, "", sealed, idTwo, 2, chain, 0)
	assert(reused.duplicate, "expected a reused chain index refused")
	// bob's index 0 of his own chain with the same chain ID is his own, not alice's.
	bobs := roomKeysTestPost(conn, secret, bob, "", sealed, idTwo, 2, chain, 0)
	assert(bobs.storedMessage.id > 0, "expected bob's message stored")
	next := roomKeysTestPost(conn, secret, alice, "", sealed, idThree, 2, chain, 1)
	assert(next.storedMessage.id > 0, "expected alice's next index stored")
	row := databaseAdminTestValue(
		conn,
		fmt.tprintf(
			"SELECT content || '|' || encode(sealed, 'hex') || '|' || epoch || '|' || " +
			"chain_index FROM chat_messages WHERE id = %d",
			stored.storedMessage.id,
		),
	)
	assert(row == "|0102030405060708|2|0", fmt.tprintf("expected the row as sent, got %q", row))

	// History returns the sealed bytes and the client message ID unchanged.
	{
		response := databaseExecuteRequest(
			conn,
			common.DatabaseRoomHistoryRequest{roomId = secret, userId = bob, limit = 50},
		)
		defer IPC__database_query_response_deinit(response)
		history, ok := response.result.(common.DatabaseRoomHistoryResult)
		assert(response.success && ok && history.isMember, "expected bob's history")
		assert(len(history.messages) == 3, fmt.tprintf("expected 3, got %d", len(history.messages)))
		first := history.messages[0]
		assert(
			first.id == stored.storedMessage.id &&
			first.content == "" &&
			first.clientMessageId == idOne &&
			string(first.sealed) == string(sealed),
			fmt.tprintf("expected the sealed message unchanged in history, got %v", first),
		)
	}
	// Plaintext rows in other rooms carry neither.
	plainStored := roomKeysTestPost(conn, plain, bob, "hello")
	assert(plainStored.storedMessage.id > 0, "expected a plaintext message stored")
	{
		response := databaseExecuteRequest(
			conn,
			common.DatabaseRoomHistoryRequest{roomId = plain, userId = bob, limit = 50},
		)
		defer IPC__database_query_response_deinit(response)
		history, _ := response.result.(common.DatabaseRoomHistoryResult)
		assert(
			len(history.messages) == 1 &&
			history.messages[0].content == "hello" &&
			history.messages[0].sealed == nil &&
			history.messages[0].clientMessageId == {},
			"expected the plaintext message without sealed fields",
		)
	}

	// Envelopes: alice's chain to both members at the log version is stored; a wrap for carol,
	// an older or newer epoch for a new chain, a non-member sender and an unencrypted room are
	// refused.
	envelope := []u8{9, 8, 7, 6}
	outcome, first := roomKeysTestStore(conn, secret, alice, 2, chain, {alice, bob}, envelope)
	assert(outcome == .Stored && first > 0, fmt.tprintf("expected stored, got %v", outcome))
	outcome, _ = roomKeysTestStore(conn, secret, alice, 2, chain, {alice, carol}, envelope)
	assert(outcome == .WrongRecipients, fmt.tprintf("expected a wrap for carol refused, got %v",
		outcome))
	otherChain := common.ChainID(roomKeysTestFill(41))
	outcome, _ = roomKeysTestStore(conn, secret, alice, 1, otherChain, {alice, bob}, envelope)
	assert(outcome == .StaleEpoch, fmt.tprintf("expected epoch 1 refused, got %v", outcome))
	outcome, _ = roomKeysTestStore(conn, secret, alice, 3, otherChain, {alice, bob}, envelope)
	assert(outcome == .StaleEpoch, fmt.tprintf("expected epoch 3 refused, got %v", outcome))
	outcome, _ = roomKeysTestStore(conn, secret, carol, 2, otherChain, {alice, bob}, envelope)
	assert(outcome == .NotMember, fmt.tprintf("expected carol refused, got %v", outcome))
	outcome, _ = roomKeysTestStore(conn, plain, alice, 2, otherChain, {alice, bob}, envelope)
	assert(outcome == .NotEncrypted, fmt.tprintf("expected the plain room refused, got %v",
		outcome))
	outcome, _ = roomKeysTestStore(conn, 999999, alice, 2, otherChain, {alice}, envelope)
	assert(outcome == .NotMember, fmt.tprintf("expected an unknown room refused, got %v", outcome))

	// The log moves on: a re-seal of the stored epoch 2 chain for bob is accepted, a new chain
	// at epoch 2 is not, and messages at epoch 2 are now stale.
	databaseAdminTestValue(
		conn,
		fmt.tprintf("UPDATE rooms SET log_version = 3 WHERE id = %d RETURNING id::text", secret),
	)
	reseal: int
	outcome, reseal = roomKeysTestStore(conn, secret, alice, 2, chain, {bob}, envelope)
	assert(outcome == .Stored, fmt.tprintf("expected the re-seal stored, got %v", outcome))
	outcome, _ = roomKeysTestStore(conn, secret, alice, 2, otherChain, {bob}, envelope)
	assert(outcome == .StaleEpoch, fmt.tprintf("expected an unknown old chain refused, got %v",
		outcome))
	late := roomKeysTestPost(
		conn,
		secret,
		alice,
		"",
		sealed,
		common.ClientMessageID(roomKeysTestFill(4)),
		2,
		chain,
		2,
	)
	assert(late.staleEpoch, "expected an epoch 2 message refused at log version 3")

	// Fetch: each member gets the envelopes with a wrap for it, sinceEpoch filters, carol is
	// refused until a row behind the server's back makes her a member, and then gets nothing.
	expectedBob := fmt.tprintf("%d:2:%d,%d:2:%d", first, alice, reseal, alice)
	got := roomKeysTestFetch(conn, bob, secret)
	assert(got == expectedBob, fmt.tprintf("expected bob's %q, got %q", expectedBob, got))
	expectedAlice := fmt.tprintf("%d:2:%d", first, alice)
	got = roomKeysTestFetch(conn, alice, secret)
	assert(got == expectedAlice, fmt.tprintf("expected alice's %q, got %q", expectedAlice, got))
	got = roomKeysTestFetch(conn, bob, secret, 3)
	assert(got == "", fmt.tprintf("expected nothing from epoch 3, got %q", got))
	got = roomKeysTestFetch(conn, carol, secret)
	assert(got == "refused", fmt.tprintf("expected carol refused, got %q", got))
	databaseAdminTestValue(
		conn,
		fmt.tprintf(
			"INSERT INTO room_members (room_id, user_id) VALUES (%d, %d) RETURNING user_id::text",
			secret,
			carol,
		),
	)
	got = roomKeysTestFetch(conn, carol, secret)
	assert(got == "", fmt.tprintf("expected no envelope for carol, got %q", got))

	// Key requests: allowed for members about a stored chain of a member.
	assert(
		roomKeysTestRequestAllowed(conn, bob, secret, 2, alice, chain),
		"expected bob's request allowed",
	)
	assert(
		!roomKeysTestRequestAllowed(conn, bob, secret, 2, alice, otherChain),
		"expected a request for an unknown chain refused",
	)
	assert(
		!roomKeysTestRequestAllowed(conn, bob, secret, 1, alice, chain),
		"expected a request naming the wrong epoch refused",
	)
	assert(
		!roomKeysTestRequestAllowed(conn, dave, secret, 2, alice, chain),
		"expected dave, not a member, refused",
	)
	assert(
		!roomKeysTestRequestAllowed(conn, bob, plain, 2, alice, chain),
		"expected a request in an unencrypted room refused",
	)
	// Deleting the room takes its envelopes and messages with it.
	databaseAdminTestValue(
		conn,
		fmt.tprintf("DELETE FROM rooms WHERE id = %d RETURNING id::text", secret),
	)
	left := databaseAdminTestValue(
		conn,
		fmt.tprintf(
			"SELECT ((SELECT count(*) FROM room_key_envelopes WHERE room_id = %d) + " +
			"(SELECT count(*) FROM chat_messages WHERE room_id = %d))::text",
			secret,
			secret,
		),
	)
	assert(left == "0", fmt.tprintf("expected the room's rows gone, got %q", left))
}

@(test)
testRoomSenderChainsMigrationUpgradesVersion7AgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn, schema := databaseMigrationTestOpen("room_keys_v7")
	defer databaseMigrationTestClose(conn, schema)

	// A database a version 7 server migrated and used.
	databaseMigrationTestMigrate(conn, DATABASE_MIGRATIONS[:7])
	databaseDefaultRoomTestExec(conn, "fill version 7 schema", DATABASE_MIGRATION_TEST_RC1_ROWS_SQL)
	databaseDefaultRoomTestExec(
		conn,
		"an encrypted room",
		"UPDATE rooms SET access = 3, history_visibility = 1, encrypted = true, " +
		"log_version = 1 WHERE id = 2",
	)
	before := databaseMigrationTestValue(conn, DATABASE_MIGRATION_TEST_FINGERPRINT_SQL)
	markersBefore := databaseMigrationTestValue(conn, DATABASE_MIGRATION_TEST_MARKERS_SQL)

	outcome := databaseMigrationTestMigrate(conn, DATABASE_MIGRATIONS[:8])
	assert(
		outcome == DatabaseMigrationOutcome{previousVersion = 7, version = 8},
		fmt.tprintf("expected only migration 8 to run, got %v", outcome),
	)
	databaseMigrationTestValidationPassesFor(conn, DATABASE_MIGRATIONS[:8])
	after := databaseMigrationTestValue(conn, DATABASE_MIGRATION_TEST_FINGERPRINT_SQL)
	assert(
		after == before,
		fmt.tprintf("expected every row intact:\nbefore %q\nafter  %q", before, after),
	)
	assert(
		databaseMigrationTestValue(conn, DATABASE_MIGRATION_TEST_MARKERS_SQL) == markersBefore,
		"expected the read markers intact",
	)
	plain := databaseMigrationTestValue(
		conn,
		"SELECT count(*)::text FROM chat_messages WHERE sealed IS NULL AND " +
		"client_message_id IS NULL AND epoch IS NULL AND chain_id IS NULL " +
		"AND chain_index IS NULL",
	)
	assert(plain == "2", fmt.tprintf("expected both old messages plaintext, got %q", plain))
	empty := databaseMigrationTestValue(conn, "SELECT count(*)::text FROM room_key_envelopes")
	assert(empty == "0", "expected no envelopes yet")
	// The checks hold: a sealed row needs its fields and an empty content, a plaintext row its
	// content, and an envelope a positive epoch.
	probes := [?]string {
		"INSERT INTO chat_messages (room_id, sender_user_id, content, sealed) " +
		"VALUES (2, 1, '', '\\x01')",
		"INSERT INTO chat_messages (room_id, sender_user_id, content) VALUES (2, 1, '')",
		"INSERT INTO chat_messages (room_id, sender_user_id, content, sealed, " +
		"client_message_id, epoch, chain_id, chain_index) VALUES (2, 1, 'text', '\\x01', " +
		"'\\x00112233445566778899aabbccddeeff', 1, '\\x00112233445566778899aabbccddeeff', 0)",
		"INSERT INTO room_key_envelopes (room_id, epoch, sender_user_id, chain_id, " +
		"recipient_user_ids, envelope) VALUES (2, 0, 1, " +
		"'\\x00112233445566778899aabbccddeeff', '{1}', '\\x01')",
	}
	for probe in probes {
		refused := databaseMigrationTestValue(
			conn,
			fmt.tprintf(
				"DO $$ BEGIN %s; RAISE EXCEPTION 'accepted'; EXCEPTION WHEN check_violation " +
				"THEN NULL; END $$; SELECT 'refused'",
				probe,
			),
		)
		assert(refused == "refused", fmt.tprintf("expected the checks to refuse %q", probe))
	}
	accepted := databaseMigrationTestValue(
		conn,
		"INSERT INTO chat_messages (room_id, sender_user_id, content, sealed, " +
		"client_message_id, epoch, chain_id, chain_index) VALUES (2, 1, '', '\\x01', " +
		"'\\x00112233445566778899aabbccddeeff', 1, '\\x00112233445566778899aabbccddeeff', 0) " +
		"RETURNING 'stored'",
	)
	assert(accepted == "stored", "expected a complete sealed row accepted")
}

@(test)
testRoomSenderChainsMigrationKeepsItsShape :: proc(t: ^testing.T) {
	_ = t
	migration := DATABASE_MIGRATIONS[7]
	assert(
		migration.version == 8 && migration.name == "room sender chains",
		fmt.tprintf("expected migration 8 to be the room sender chains, got %v", migration),
	)
	for required in ([]string {
			"ADD COLUMN client_message_id BYTEA NULL",
			"ADD COLUMN sealed BYTEA NULL",
			"chat_messages_sender_client_message_id",
			"chat_messages_sender_chain_index",
			"CREATE TABLE room_key_envelopes",
			"room_key_envelopes_by_room_id_and_epoch",
		}) {
		assert(
			strings.contains(migration.sql, required),
			fmt.tprintf("expected migration 8 to contain %q", required),
		)
	}
	assert(
		!strings.contains(migration.sql, "DROP TABLE") &&
		!strings.contains(migration.sql, "DROP COLUMN"),
		"expected migration 8 to drop no table or column",
	)
}
