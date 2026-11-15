package server

import "../common"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"
import "shared:pg"

// Runs the direct message statements against a real PostgreSQL. It writes accounts and
// messages (and removes them afterwards), so it only runs when HAYCHAT_DATABASE_SQL_TEST=1 and
// must point at a throwaway database through the HAYCHAT_DATABASE_* variables.
// dev/live-proof.sh --all and --sql run it against their throwaway database.

DATABASE_SQL_TEST_ENV :: "HAYCHAT_DATABASE_SQL_TEST"

databaseSQLTestConfig :: proc() -> ServerConfig {
	env :: proc(key: string, fallback: string) -> string {
		value := os.get_env(key, context.temp_allocator)
		return len(value) > 0 ? value : fallback
	}
	port, portOK := strconv.parse_int(env("HAYCHAT_DATABASE_PORT", "5432"))
	return ServerConfig {
		databaseURL = env("HAYCHAT_DATABASE_URL", "localhost"),
		databasePort = portOK ? port : 5432,
		databaseUser = env("HAYCHAT_DATABASE_USER", "haychat"),
		databasePass = env("HAYCHAT_DATABASE_PASS", "haychat"),
		databaseName = env("HAYCHAT_DATABASE_NAME", "haychat"),
	}
}

databaseSQLTestCreateUser :: proc(conn: pg.Conn, nickname: string) -> int {
	_, publicKey, keyOK := common.generateIdentityKeyPair()
	assert(keyOK, "expected test identity key generation to succeed")
	response := databaseExecuteRequest(
		conn,
		common.DatabaseUserIdentityRequest{nickname = nickname, publicKey = publicKey},
	)
	defer IPC__database_query_response_deinit(response)
	identity, identityOK := response.result.(common.DatabaseUserIdentityResult)
	assert(
		response.success && identityOK && identity.userId > 0,
		fmt.tprintf("expected account %q to be created, got %v", nickname, response),
	)
	return identity.userId
}

databaseSQLTestPost :: proc(
	conn: pg.Conn,
	senderID: int,
	recipientID: int,
	content: string,
) -> common.DatabaseQueryResponse {
	response := databaseExecuteRequest(
		conn,
		common.DatabasePostDirectMessageRequest {
			senderId = senderID,
			recipientId = recipientID,
			content = content,
		},
	)
	assert(response.success, fmt.tprintf("expected the post to run: %s", response.message))
	return response
}

databaseSQLTestPostID :: proc(
	conn: pg.Conn,
	senderID: int,
	recipientID: int,
	content: string,
) -> int {
	response := databaseSQLTestPost(conn, senderID, recipientID, content)
	defer IPC__database_query_response_deinit(response)
	posted := response.result.(common.DatabasePostDirectMessageResult)
	assert(posted.outcome == .Stored, fmt.tprintf("expected %q to be stored", content))
	return posted.storedMessage.id
}

databaseSQLTestHistory :: proc(
	conn: pg.Conn,
	userID: int,
	peerUserID: int,
	beforeMessageID: int,
	limit: int,
) -> common.DatabaseQueryResponse {
	response := databaseExecuteRequest(
		conn,
		common.DatabaseDirectHistoryRequest {
			userId = userID,
			peerUserId = peerUserID,
			beforeMessageID = beforeMessageID,
			limit = limit,
		},
	)
	assert(
		response.success,
		fmt.tprintf("expected the history statement to run: %s", response.message),
	)
	return response
}

@(test)
testDirectMessageStatementsAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}

	conn, openErr := databaseOpenRuntimeConnection(databaseSQLTestConfig())
	assert(len(openErr) == 0, openErr)
	defer pg.finish(conn)
	// The running server already migrated this database, so this changes nothing.
	_, schemaErr := databaseMigrateSchema(conn, DATABASE_MIGRATIONS[:])
	assert(len(schemaErr) == 0, schemaErr)

	suffix := time.time_to_unix_nano(time.now()) % 1_000_000_000
	aliceName := fmt.tprintf("dm-alice-%d", suffix)
	bobName := fmt.tprintf("dm-bob-%d", suffix)
	carolName := fmt.tprintf("dm-carol-%d", suffix)
	alice := databaseSQLTestCreateUser(conn, aliceName)
	bob := databaseSQLTestCreateUser(conn, bobName)
	carol := databaseSQLTestCreateUser(conn, carolName)
	// Deleting the accounts cascades to their direct messages.
	defer {
		cleanup := fmt.ctprintf(
			"DELETE FROM users WHERE nickname IN ('%s', '%s', '%s')",
			aliceName,
			bobName,
			carolName,
		)
		cleanupErr := databaseMigrationExec(conn, "clean up direct message test", string(cleanup))
		assert(len(cleanupErr) == 0, cleanupErr)
	}

	// Post: the stored row comes back with its ID, timestamp, and both nicknames.
	{
		response := databaseSQLTestPost(conn, alice, bob, "one")
		defer IPC__database_query_response_deinit(response)
		posted := response.result.(common.DatabasePostDirectMessageResult)
		stored := posted.storedMessage
		assert(
			posted.outcome == .Stored &&
			stored.id > 0 &&
			stored.senderId == alice &&
			stored.recipientId == bob &&
			stored.senderNickname == aliceName &&
			stored.recipientNickname == bobName &&
			len(stored.timestamp) > 0 &&
			stored.content == "one",
			fmt.tprintf("expected the stored direct message, got %v", stored),
		)
	}
	two := databaseSQLTestPostID(conn, bob, alice, "two")
	three := databaseSQLTestPostID(conn, alice, bob, "three")
	four := databaseSQLTestPostID(conn, alice, carol, "four")
	assert(two < three && three < four, "expected message IDs to increase")

	// The post statement refuses the sender itself and an unknown account, storing nothing.
	for refusedRecipient in ([]int{alice, 2_000_000_000}) {
		response := databaseSQLTestPost(conn, alice, refusedRecipient, "nobody")
		defer IPC__database_query_response_deinit(response)
		posted := response.result.(common.DatabasePostDirectMessageResult)
		assert(
			posted.outcome == .UnknownRecipient && posted.storedMessage.id == 0,
			fmt.tprintf("expected recipient %d to be refused, got %v", refusedRecipient, posted),
		)
	}

	// History pages cover both directions, newest page first, each page oldest first.
	firstPageOldestID := 0
	{
		response := databaseSQLTestHistory(conn, alice, bob, 0, 2)
		defer IPC__database_query_response_deinit(response)
		page := response.result.(common.DatabaseDirectHistoryResult)
		assert(
			page.peerExists &&
			page.hasOlder &&
			len(page.messages) == 2 &&
			page.messages[0].content == "two" &&
			page.messages[0].senderNickname == bobName &&
			page.messages[0].recipientNickname == aliceName &&
			page.messages[1].content == "three",
			fmt.tprintf("expected the newest page [two, three] with older ones, got %v", page),
		)
		firstPageOldestID = page.messages[0].id
	}
	{
		response := databaseSQLTestHistory(conn, alice, bob, firstPageOldestID, 2)
		defer IPC__database_query_response_deinit(response)
		page := response.result.(common.DatabaseDirectHistoryResult)
		assert(
			page.peerExists &&
			!page.hasOlder &&
			len(page.messages) == 1 &&
			page.messages[0].content == "one",
			fmt.tprintf("expected the last page [one] without older ones, got %v", page),
		)
	}
	{
		response := databaseSQLTestHistory(conn, bob, alice, 0, 50)
		defer IPC__database_query_response_deinit(response)
		page := response.result.(common.DatabaseDirectHistoryResult)
		assert(
			len(page.messages) == 3 && !page.hasOlder,
			fmt.tprintf("expected the peer to see the same 3 messages, got %v", page),
		)
	}
	{
		response := databaseSQLTestHistory(conn, alice, 2_000_000_000, 0, 10)
		defer IPC__database_query_response_deinit(response)
		page := response.result.(common.DatabaseDirectHistoryResult)
		assert(!page.peerExists, "expected history with an unknown account to be refused")
	}

	// Conversations: one row per peer with its latest message, most recent first.
	{
		response := databaseExecuteRequest(
			conn,
			common.DatabaseDirectConversationListRequest{userId = alice},
		)
		defer IPC__database_query_response_deinit(response)
		assert(response.success, response.message)
		list := response.result.(common.DatabaseDirectConversationListResult)
		assert(
			len(list.conversations) == 2 &&
			list.conversations[0].peerUserId == carol &&
			list.conversations[0].peerNickname == carolName &&
			list.conversations[0].lastMessageID == four &&
			list.conversations[0].lastSenderId == alice &&
			list.conversations[1].peerUserId == bob &&
			list.conversations[1].lastMessageID == three &&
			list.conversations[1].lastContent == "three",
			fmt.tprintf("expected [carol: four, bob: three], got %v", list.conversations),
		)
	}
	{
		response := databaseExecuteRequest(
			conn,
			common.DatabaseDirectConversationListRequest{userId = bob},
		)
		defer IPC__database_query_response_deinit(response)
		list := response.result.(common.DatabaseDirectConversationListResult)
		assert(
			len(list.conversations) == 1 &&
			list.conversations[0].peerUserId == alice &&
			list.conversations[0].peerNickname == aliceName &&
			len(list.conversations[0].lastTimestamp) > 0,
			fmt.tprintf("expected bob's only conversation to be alice, got %v", list.conversations),
		)
	}

	// The user directory lists every account, with online flags left to the router.
	{
		response := databaseExecuteRequest(conn, common.DatabaseUserDirectoryRequest{})
		defer IPC__database_query_response_deinit(response)
		assert(response.success, response.message)
		directory := response.result.(common.DatabaseUserDirectoryResult)
		found := 0
		for user in directory.users {
			assert(!user.isOnline, "expected the database not to claim anyone is online")
			if user.id == alice || user.id == bob || user.id == carol {
				found += 1
				assert(strings.has_prefix(user.nickname, "dm-"), "expected joined nicknames")
			}
		}
		assert(found == 3, fmt.tprintf("expected all three accounts, found %d", found))
	}
}
