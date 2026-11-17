package server

import "../common"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "shared:pg"

// Runs the protocol 17 direct message statements against a real PostgreSQL when
// HAYCHAT_DATABASE_SQL_TEST=1 (dev/live-proof.sh --all and --sql): an envelope stored byte for
// byte and returned by history and the conversation list, envelopes that do not verify, a
// reused client message ID, the plaintext fallback's signature column, the table's checks, and
// migration 6 from a version 5 database with rows. Each runs in a schema of its own that is
// rolled back. The pure check (databaseCheckSealedDirectMessage) has a test without a database.

// One account with real keys, so its envelopes verify.
@(private = "file")
SealedTestAccount :: struct {
	userID:             int,
	identityPrivateKey: common.IdentityPrivateKeyBytes,
	identityPublicKey:  common.IdentityPublicKeyBytes,
	encryption:         common.EncryptionKeyPair,
}

@(private = "file")
sealedTestAccount :: proc() -> SealedTestAccount {
	privateKey, publicKey, ok := common.generateIdentityKeyPair()
	assert(ok, "expected test identity key generation to succeed")
	encryption, encryptionOK := common.generateEncryptionKeyPair()
	assert(encryptionOK, "expected test encryption key generation to succeed")
	return SealedTestAccount {
		identityPrivateKey = privateKey,
		identityPublicKey = publicKey,
		encryption = encryption,
	}
}

@(private = "file")
sealedTestClientMessageID :: proc(fill: u8) -> common.ClientMessageID {
	id: common.ClientMessageID
	for index in 0 ..< len(id) {
		id[index] = fill + u8(index)
	}
	return id
}

// Seals content from sender to recipient on serverKey. The caller frees the envelope.
@(private = "file")
sealedTestEnvelope :: proc(
	serverKey: common.IdentityPublicKeyBytes,
	sender, recipient: SealedTestAccount,
	clientMessageID: common.ClientMessageID,
	content: string,
) -> []u8 {
	buffer: [common.SEALED_ENVELOPE_MAX_BYTES]u8
	n, err := common.sealDirectMessage(
		common.DirectMessageAADFields {
			serverIdentityPublicKey = serverKey,
			senderUserID = sender.userID,
			recipientUserID = recipient.userID,
			senderIdentityPublicKey = sender.identityPublicKey,
			recipientIdentityPublicKey = recipient.identityPublicKey,
			clientMessageID = clientMessageID,
		},
		content,
		sender.encryption.publicKey,
		recipient.encryption.publicKey,
		sender.identityPrivateKey,
		buffer[:],
	)
	assert(err == .None, fmt.tprintf("expected sealing to succeed, got %v", err))
	envelope := make([]u8, n)
	copy(envelope, buffer[:n])
	return envelope
}

@(private = "file")
sealedTestRequest :: proc(
	serverKey: common.IdentityPublicKeyBytes,
	sender, recipient: SealedTestAccount,
	clientMessageID: common.ClientMessageID,
	envelope: []u8,
) -> common.DatabasePostDirectMessageRequest {
	return common.DatabasePostDirectMessageRequest {
		senderId = sender.userID,
		recipientId = recipient.userID,
		clientMessageId = clientMessageID,
		envelope = envelope,
		serverIdentityPublicKey = serverKey,
		senderIdentityPublicKey = sender.identityPublicKey,
	}
}

// Runs a post and returns its result; the caller frees it with
// IPC__stored_direct_message_deinit(result.storedMessage).
@(private = "file")
sealedTestPost :: proc(
	conn: pg.Conn,
	request: common.DatabasePostDirectMessageRequest,
) -> common.DatabasePostDirectMessageResult {
	response := databaseExecuteRequest(conn, request)
	defer delete(response.message)
	result, ok := response.result.(common.DatabasePostDirectMessageResult)
	assert(
		response.success && ok,
		fmt.tprintf("expected the post statement to run: %s", response.message),
	)
	return result
}

@(test)
testSealedDirectMessageCheckIsPure :: proc(t: ^testing.T) {
	_ = t
	_, serverKey, serverOK := common.generateIdentityKeyPair()
	assert(serverOK, "expected server key generation to succeed")
	alice := sealedTestAccount()
	alice.userID = 11
	bob := sealedTestAccount()
	bob.userID = 12
	mallory := sealedTestAccount()
	mallory.userID = 13
	id := sealedTestClientMessageID(1)
	envelope := sealedTestEnvelope(serverKey, alice, bob, id, "pure check")
	defer delete(envelope)
	request := sealedTestRequest(serverKey, alice, bob, id, envelope)
	assert(
		databaseCheckSealedDirectMessage(request, bob.identityPublicKey) == .Stored,
		"expected a valid envelope to pass",
	)
	assert(
		databaseCheckSealedDirectMessage(request, mallory.identityPublicKey) == .InvalidEnvelope,
		"expected an envelope for another recipient key to fail",
	)
	assert(
		databaseCheckSealedDirectMessage(request, {}) == .InvalidEnvelope,
		"expected a recipient without an identity key to fail",
	)
	{
		changed := request
		changed.clientMessageId = sealedTestClientMessageID(2)
		assert(
			databaseCheckSealedDirectMessage(changed, bob.identityPublicKey) == .InvalidEnvelope,
			"expected another client message ID to fail",
		)
	}
	{
		changed := request
		changed.serverIdentityPublicKey = mallory.identityPublicKey
		assert(
			databaseCheckSealedDirectMessage(changed, bob.identityPublicKey) == .InvalidEnvelope,
			"expected another server's key to fail",
		)
	}
	{
		// The sender must be the session's account: mallory cannot post alice's envelope.
		changed := request
		changed.senderId = mallory.userID
		changed.senderIdentityPublicKey = mallory.identityPublicKey
		assert(
			databaseCheckSealedDirectMessage(changed, bob.identityPublicKey) == .InvalidEnvelope,
			"expected another sender to fail",
		)
	}
	{
		changed := request
		changed.recipientId = 99
		assert(
			databaseCheckSealedDirectMessage(changed, bob.identityPublicKey) == .InvalidEnvelope,
			"expected another recipient ID to fail",
		)
	}
	{
		flipped := make([]u8, len(envelope))
		defer delete(flipped)
		copy(flipped, envelope)
		flipped[len(flipped) / 2] ~= 0x01
		changed := request
		changed.envelope = flipped
		assert(
			databaseCheckSealedDirectMessage(changed, bob.identityPublicKey) == .InvalidEnvelope,
			"expected a flipped bit to fail",
		)
	}
	{
		changed := request
		changed.clientMessageId = {}
		assert(
			databaseCheckSealedDirectMessage(changed, bob.identityPublicKey) == .InvalidEnvelope,
			"expected a zero client message ID to fail",
		)
	}
}

@(test)
testEncryptedDirectMessageStatementsAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "sealed_dm")
	_, serverKey, serverOK := common.generateIdentityKeyPair()
	assert(serverOK, "expected server key generation to succeed")

	alice := sealedTestAccount()
	bob := sealedTestAccount()
	{
		identity := databaseIdentityTestResolve(conn, "sealed-alice", alice.identityPublicKey)
		delete(identity.previousNickname)
		alice.userID = identity.userId
		identity = databaseIdentityTestResolve(conn, "sealed-bob", bob.identityPublicKey)
		delete(identity.previousNickname)
		bob.userID = identity.userId
	}
	keyless := databaseAdminTestUser(conn, "sealed-keyless")

	// An envelope is stored byte for byte with an empty content, and echoed as stored.
	firstID := sealedTestClientMessageID(10)
	envelope := sealedTestEnvelope(serverKey, alice, bob, firstID, "sealed hello")
	defer delete(envelope)
	stored := sealedTestPost(conn, sealedTestRequest(serverKey, alice, bob, firstID, envelope))
	defer IPC__stored_direct_message_deinit(stored.storedMessage)
	assert(
		stored.outcome == .Stored &&
		stored.storedMessage.id > 0 &&
		stored.storedMessage.content == "" &&
		string(stored.storedMessage.envelope) == string(envelope) &&
		stored.storedMessage.clientMessageId == firstID &&
		stored.storedMessage.signature == {} &&
		stored.storedMessage.senderNickname == "sealed-alice",
		fmt.tprintf("expected the envelope stored as sent, got %v", stored),
	)
	inDatabase := databaseAdminTestValue(
		conn,
		fmt.tprintf(
			"SELECT encode(envelope, 'hex') || '/' || content || '/' || " +
			"encode(client_message_id, 'hex') || '/' || (signature IS NULL)::text " +
			"FROM direct_messages WHERE id = %d",
			stored.storedMessage.id,
		),
	)
	envelopeHex := common.encodeBytesToHex(envelope)
	defer delete(envelopeHex)
	firstIDHex := common.encodeBytesToHex(firstID[:])
	defer delete(firstIDHex)
	expected := fmt.tprintf("%s//%s/true", envelopeHex, firstIDHex)
	assert(
		inDatabase == expected,
		fmt.tprintf("expected %q in the row, got %q", expected, inDatabase),
	)
	assert(
		!strings.contains(inDatabase, "sealed hello"),
		"expected no plaintext in the stored row",
	)

	// The same client message ID again is refused, whatever the envelope.
	{
		again := sealedTestEnvelope(serverKey, alice, bob, firstID, "replayed")
		defer delete(again)
		result := sealedTestPost(conn, sealedTestRequest(serverKey, alice, bob, firstID, again))
		defer IPC__stored_direct_message_deinit(result.storedMessage)
		assert(result.outcome == .Duplicate, fmt.tprintf("expected a duplicate, got %v", result))
	}
	// An envelope for another conversation, another server or with a flipped bit is refused.
	{
		otherServer := alice.identityPublicKey
		wrongServer := sealedTestEnvelope(
			otherServer,
			alice,
			bob,
			sealedTestClientMessageID(20),
			"x",
		)
		defer delete(wrongServer)
		result := sealedTestPost(
			conn,
			sealedTestRequest(serverKey, alice, bob, sealedTestClientMessageID(20), wrongServer),
		)
		assert(
			result.outcome == .InvalidEnvelope,
			fmt.tprintf("expected another server's envelope to be refused, got %v", result),
		)
	}
	{
		flipped := sealedTestEnvelope(serverKey, alice, bob, sealedTestClientMessageID(30), "x")
		defer delete(flipped)
		flipped[40] ~= 0x80
		result := sealedTestPost(
			conn,
			sealedTestRequest(serverKey, alice, bob, sealedTestClientMessageID(30), flipped),
		)
		assert(
			result.outcome == .InvalidEnvelope,
			fmt.tprintf("expected a tampered envelope to be refused, got %v", result),
		)
	}
	{
		// An envelope naming bob's ID but sealed with another identity key for him.
		impostor := bob
		impostor.identityPublicKey = alice.identityPublicKey
		wrongKey := sealedTestEnvelope(
			serverKey,
			alice,
			impostor,
			sealedTestClientMessageID(40),
			"x",
		)
		defer delete(wrongKey)
		result := sealedTestPost(
			conn,
			sealedTestRequest(serverKey, alice, bob, sealedTestClientMessageID(40), wrongKey),
		)
		assert(
			result.outcome == .InvalidEnvelope,
			fmt.tprintf("expected an envelope for another key to be refused, got %v", result),
		)
	}
	{
		// No envelope can name an account without an identity key; an unknown one is unknown.
		target := bob
		target.userID = keyless
		toKeyless := sealedTestEnvelope(
			serverKey,
			alice,
			target,
			sealedTestClientMessageID(50),
			"x",
		)
		defer delete(toKeyless)
		result := sealedTestPost(
			conn,
			sealedTestRequest(serverKey, alice, target, sealedTestClientMessageID(50), toKeyless),
		)
		assert(
			result.outcome == .InvalidEnvelope,
			fmt.tprintf("expected a keyless recipient to be refused, got %v", result),
		)
		target.userID = 2_000_000_000
		unknown := sealedTestPost(
			conn,
			sealedTestRequest(serverKey, alice, target, sealedTestClientMessageID(51), toKeyless),
		)
		assert(
			unknown.outcome == .UnknownRecipient,
			fmt.tprintf("expected an unknown recipient, got %v", unknown),
		)
	}
	refused := databaseAdminTestValue(conn, "SELECT count(*)::text FROM direct_messages")
	assert(refused == "1", fmt.tprintf("expected only the first envelope stored, got %s", refused))

	// A signed plaintext fallback stores its ID and signature; a reused ID is refused.
	plainID := sealedTestClientMessageID(60)
	signature, signOK := common.signPlaintextDirectMessage(
		{serverKey, bob.userID, alice.userID, plainID},
		"plain reply",
		bob.identityPrivateKey,
	)
	assert(signOK, "expected signing to succeed")
	plain := sealedTestPost(
		conn,
		common.DatabasePostDirectMessageRequest {
			senderId = bob.userID,
			recipientId = alice.userID,
			content = "plain reply",
			clientMessageId = plainID,
			signature = signature,
		},
	)
	defer IPC__stored_direct_message_deinit(plain.storedMessage)
	assert(
		plain.outcome == .Stored &&
		plain.storedMessage.content == "plain reply" &&
		plain.storedMessage.signature == signature &&
		plain.storedMessage.clientMessageId == plainID &&
		len(plain.storedMessage.envelope) == 0,
		fmt.tprintf("expected the signed plaintext stored, got %v", plain),
	)
	{
		again := sealedTestPost(
			conn,
			common.DatabasePostDirectMessageRequest {
				senderId = bob.userID,
				recipientId = alice.userID,
				content = "plain again",
				clientMessageId = plainID,
				signature = signature,
			},
		)
		assert(again.outcome == .Duplicate, fmt.tprintf("expected a duplicate, got %v", again))
	}
	// The client message ID is unique per sender: alice may use bob's.
	{
		envelopeWithBobsID := sealedTestEnvelope(serverKey, alice, bob, plainID, "same id")
		defer delete(envelopeWithBobsID)
		result := sealedTestPost(
			conn,
			sealedTestRequest(serverKey, alice, bob, plainID, envelopeWithBobsID),
		)
		defer IPC__stored_direct_message_deinit(result.storedMessage)
		assert(
			result.outcome == .Stored,
			fmt.tprintf("expected another sender's ID to be free, got %v", result),
		)
	}

	// History returns both kinds with their fields; the envelope byte for byte.
	{
		response := databaseExecuteRequest(
			conn,
			common.DatabaseDirectHistoryRequest {
				userId = bob.userID,
				peerUserId = alice.userID,
				limit = 10,
			},
		)
		defer IPC__database_query_response_deinit(response)
		page := response.result.(common.DatabaseDirectHistoryResult)
		assert(
			response.success &&
			len(page.messages) == 3 &&
			string(page.messages[0].envelope) == string(envelope) &&
			page.messages[0].content == "" &&
			page.messages[0].clientMessageId == firstID &&
			page.messages[1].content == "plain reply" &&
			page.messages[1].signature == signature &&
			len(page.messages[1].envelope) == 0,
			fmt.tprintf("expected [sealed, plain, sealed] with their fields, got %v", page),
		)
	}
	// The conversation list carries the newest message's envelope for the preview.
	{
		response := databaseExecuteRequest(
			conn,
			common.DatabaseDirectConversationListRequest{userId = bob.userID},
		)
		defer IPC__database_query_response_deinit(response)
		list := response.result.(common.DatabaseDirectConversationListResult)
		assert(
			response.success &&
			len(list.conversations) == 1 &&
			list.conversations[0].lastContent == "" &&
			len(list.conversations[0].lastEnvelope) > 0 &&
			list.conversations[0].lastClientMessageId == plainID &&
			list.conversations[0].lastSignature == {},
			fmt.tprintf("expected the newest envelope as the preview, got %v", list),
		)
	}

	// The checks: never both or neither of content and envelope, an envelope needs an ID, and
	// the sizes.
	for values in ([]string {
			"'both', decode('01', 'hex'), decode(repeat('aa', 16), 'hex'), NULL",
			"'', NULL, NULL, NULL",
			"'', decode('01', 'hex'), NULL, NULL",
			"'', decode(repeat('01', 8193), 'hex'), decode(repeat('aa', 16), 'hex'), NULL",
			"'x', NULL, decode(repeat('aa', 15), 'hex'), NULL",
			"'x', NULL, decode(repeat('ab', 16), 'hex'), decode(repeat('bb', 63), 'hex')",
			"'', decode('01', 'hex'), decode(repeat('ac', 16), 'hex'), " +
			"decode(repeat('bb', 64), 'hex')",
			"'x', NULL, NULL, decode(repeat('bb', 64), 'hex')",
		}) {
		databaseDefaultRoomTestExec(
			conn,
			"probe the direct_messages checks",
			fmt.tprintf(
				"DO $$ BEGIN INSERT INTO direct_messages (sender_user_id, recipient_user_id, " +
				"content, envelope, client_message_id, signature) VALUES (%d, %d, %s); " +
				"RAISE EXCEPTION 'bad direct message accepted'; " +
				"EXCEPTION WHEN check_violation THEN NULL; END $$",
				alice.userID,
				bob.userID,
				values,
			),
		)
	}
}

@(test)
testEncryptedDirectMessagesMigrationUpgradesVersion5AgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn, schema := databaseMigrationTestOpen(t, "sealed_dm_v5")

	// A database a version 5 server migrated and used.
	databaseMigrationTestMigrate(conn, DATABASE_MIGRATIONS[:5])
	databaseDefaultRoomTestExec(conn, "fill version 5 schema", DATABASE_MIGRATION_TEST_RC1_ROWS_SQL)
	before := databaseMigrationTestValue(conn, DATABASE_MIGRATION_TEST_FINGERPRINT_SQL)

	outcome := databaseMigrationTestMigrate(conn, DATABASE_MIGRATIONS[:6])
	assert(
		outcome == DatabaseMigrationOutcome{previousVersion = 5, version = 6},
		fmt.tprintf("expected only migration 6 to run, got %v", outcome),
	)
	assert(
		databaseMigrationTestRecorded(conn) ==
		"1:baseline,2:read markers,3:admin,4:room access,5:user encryption keys," +
		"6:encrypted direct messages",
		"expected version 6 recorded",
	)
	databaseMigrationTestValidationPassesFor(conn, DATABASE_MIGRATIONS[:6])
	after := databaseMigrationTestValue(conn, DATABASE_MIGRATION_TEST_FINGERPRINT_SQL)
	assert(
		after == before,
		fmt.tprintf("expected every row intact:\nbefore %q\nafter  %q", before, after),
	)
	// The old rows are plaintext from before protocol 17: no ID, no envelope, no signature.
	old := databaseMigrationTestValue(
		conn,
		"SELECT count(*)::text FROM direct_messages WHERE client_message_id IS NULL " +
		"AND envelope IS NULL AND signature IS NULL AND content <> ''",
	)
	assert(old == "2", fmt.tprintf("expected both old messages as plaintext, got %s", old))
	// Empty content is allowed now, with an envelope; the old length rule still holds without.
	databaseDefaultRoomTestExec(
		conn,
		"store an envelope after migration 6",
		"INSERT INTO direct_messages (sender_user_id, recipient_user_id, content, envelope, " +
		"client_message_id) VALUES (1, 2, '', decode('0102', 'hex'), " +
		"decode(repeat('aa', 16), 'hex'))",
	)
	databaseDefaultRoomTestExec(
		conn,
		"probe the content length after migration 6",
		"DO $$ BEGIN INSERT INTO direct_messages (sender_user_id, recipient_user_id, content) " +
		"VALUES (1, 2, repeat('x', 4001)); RAISE EXCEPTION 'long content accepted'; " +
		"EXCEPTION WHEN check_violation THEN NULL; END $$",
	)
	databaseDefaultRoomTestExec(
		conn,
		"probe the unique client message ID after migration 6",
		"DO $$ BEGIN INSERT INTO direct_messages (sender_user_id, recipient_user_id, content, " +
		"envelope, client_message_id) VALUES (1, 2, '', decode('03', 'hex'), " +
		"decode(repeat('aa', 16), 'hex')); RAISE EXCEPTION 'duplicate ID accepted'; " +
		"EXCEPTION WHEN unique_violation THEN NULL; END $$",
	)
}

@(test)
testEncryptedDirectMessagesMigrationKeepsItsShape :: proc(t: ^testing.T) {
	_ = t
	migration := DATABASE_MIGRATIONS[5]
	assert(
		migration.version == 6 && migration.name == "encrypted direct messages",
		fmt.tprintf("expected migration 6 to be encrypted direct messages, got %v", migration),
	)
	for required in ([]string {
			"ADD COLUMN client_message_id BYTEA NULL",
			"ADD COLUMN envelope BYTEA NULL",
			"ADD COLUMN signature BYTEA NULL",
			"octet_length(envelope) BETWEEN 1 AND 8192",
			"octet_length(client_message_id) = 16",
			"octet_length(signature) = 64",
			"ON direct_messages (sender_user_id, client_message_id)",
			"WHERE client_message_id IS NOT NULL",
		}) {
		assert(
			strings.contains(migration.sql, required),
			fmt.tprintf("expected migration 6 to contain %q", required),
		)
	}
	assert(
		!strings.contains(migration.sql, "DROP TABLE") &&
		!strings.contains(migration.sql, "DROP COLUMN"),
		"expected migration 6 to drop no table or column",
	)
	assert(
		common.SEALED_ENVELOPE_MAX_BYTES == 8192 && common.CLIENT_MESSAGE_ID_SIZE == 16,
		"expected the column checks to match the envelope and ID sizes",
	)
	assert(
		strings.contains(DATABASE_SCHEMA_VALIDATION_SQL, "direct messages e2ee checks"),
		"expected schema validation to require migration 6's checks",
	)
}
