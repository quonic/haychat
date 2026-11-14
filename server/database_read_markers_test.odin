package server

import "../common"
import "core:fmt"
import "core:os"
import "core:testing"
import "shared:pg"

// Runs the read-state statements (the room and conversation lists and mark-read) against a
// real PostgreSQL when HAYCHAT_DATABASE_SQL_TEST=1. Each test migrates a schema of its own
// (databaseMigrationTestOpen) and drops it at the end, so only a throwaway database is touched.

// Opens a migrated schema with #general. The caller defers databaseMigrationTestClose.
databaseReadMarkerTestOpen :: proc(label: string) -> (pg.Conn, string) {
	conn, schema := databaseMigrationTestOpen(label)
	databaseMigrationTestMigrate(conn, DATABASE_MIGRATIONS[:])
	roomID, roomErr := databaseEnsureDefaultRoom(conn)
	assert(len(roomErr) == 0, roomErr)
	assert(
		roomID == common.GENERAL_ROOM_ID,
		fmt.tprintf("expected #general as room 1, got %d", roomID),
	)
	return conn, schema
}

databaseReadMarkerTestPostRoom :: proc(conn: pg.Conn, roomID, senderID: int) -> int {
	response := databaseExecuteRequest(
		conn,
		common.DatabasePostRoomChatMessageRequest {
			roomId = roomID,
			senderId = senderID,
			content = "read state",
		},
	)
	defer IPC__database_query_response_deinit(response)
	posted, postedOK := response.result.(common.DatabasePostRoomChatMessageResult)
	assert(
		response.success && postedOK && posted.isMember,
		fmt.tprintf("expected user %d to post in room %d: %v", senderID, roomID, response),
	)
	return posted.storedMessage.id
}

// The unread count and marker the room list reports for userID in roomID.
databaseReadMarkerTestRoom :: proc(conn: pg.Conn, userID, roomID: int) -> (unread, marker: int) {
	response := databaseExecuteRequest(conn, common.DatabaseRoomListRequest{userId = userID})
	defer IPC__database_query_response_deinit(response)
	list, listOK := response.result.(common.DatabaseRoomListResult)
	assert(response.success && listOK, fmt.tprintf("expected a room list: %v", response))
	for room in list.rooms {
		if room.id == roomID {
			return room.unreadCount, room.lastReadMessageId
		}
	}
	assert(false, fmt.tprintf("expected user %d's room list to hold room %d", userID, roomID))
	return
}

// The unread count and marker the conversation list reports for userID's conversation with
// peerUserID, or -1, -1 when it lists none.
databaseReadMarkerTestDirect :: proc(
	conn: pg.Conn,
	userID, peerUserID: int,
) -> (
	unread, marker: int,
) {
	response := databaseExecuteRequest(
		conn,
		common.DatabaseDirectConversationListRequest{userId = userID},
	)
	defer IPC__database_query_response_deinit(response)
	list, listOK := response.result.(common.DatabaseDirectConversationListResult)
	assert(response.success && listOK, fmt.tprintf("expected a conversation list: %v", response))
	for conversation in list.conversations {
		if conversation.peerUserId == peerUserID {
			return conversation.unreadCount, conversation.lastReadMessageId
		}
	}
	return -1, -1
}

databaseReadMarkerTestMark :: proc(
	conn: pg.Conn,
	userID: int,
	kind: common.ReadMarkerKind,
	conversationID, messageID: int,
) -> common.DatabaseMarkReadResult {
	response := databaseExecuteRequest(
		conn,
		common.DatabaseMarkReadRequest {
			userId = userID,
			kind = kind,
			conversationId = conversationID,
			messageId = messageID,
		},
	)
	defer IPC__database_query_response_deinit(response)
	marked, markedOK := response.result.(common.DatabaseMarkReadResult)
	assert(response.success && markedOK, fmt.tprintf("expected mark-read to run: %v", response))
	return marked
}

@(test)
testRoomUnreadRulesAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn, schema := databaseReadMarkerTestOpen("unread_rooms")
	defer databaseMigrationTestClose(conn, schema)
	room := common.GENERAL_ROOM_ID

	alice := databaseSQLTestCreateUser(conn, "read-alice")
	bob := databaseSQLTestCreateUser(conn, "read-bob")
	first := databaseReadMarkerTestPostRoom(conn, room, alice)
	second := databaseReadMarkerTestPostRoom(conn, room, alice)
	// carol's account, and so her membership, is newer than both messages.
	carol := databaseSQLTestCreateUser(conn, "read-carol")

	Expected :: struct {
		label:          string,
		userID, unread: int,
	}
	check :: proc(conn: pg.Conn, room: int, cases: []Expected) {
		for expected in cases {
			unread, marker := databaseReadMarkerTestRoom(conn, expected.userID, room)
			assert(
				unread == expected.unread && marker == 0,
				fmt.tprintf(
					"expected %s to have %d unread and no marker, got %d at %d",
					expected.label,
					expected.unread,
					unread,
					marker,
				),
			)
		}
	}
	// No markers yet, so membership time decides: bob joined before both messages, carol
	// after them, and alice's own messages never count.
	check(conn, room, {{"alice", alice, 0}, {"bob", bob, 2}, {"carol", carol, 0}})
	third := databaseReadMarkerTestPostRoom(conn, room, bob)
	check(conn, room, {{"alice", alice, 1}, {"bob", bob, 2}, {"carol", carol, 1}})

	// A marker replaces the joined_at rule: bob read the first message.
	marked := databaseReadMarkerTestMark(conn, bob, .Room, room, first)
	assert(
		marked == common.DatabaseMarkReadResult {
				allowed = true,
				changed = true,
				lastReadMessageId = first,
				unreadCount = 1,
			},
		fmt.tprintf("expected bob's marker at %d with 1 unread, got %v", first, marked),
	)
	unread, marker := databaseReadMarkerTestRoom(conn, bob, room)
	assert(
		unread == 1 && marker == first,
		fmt.tprintf("expected the list to agree, got %d at %d", unread, marker),
	)
	_ = second
	_ = third

	// The cap: 105 more messages from alice report as common.UNREAD_COUNT_CAP.
	databaseDefaultRoomTestExec(
		conn,
		"post many messages",
		fmt.tprintf(
			"INSERT INTO chat_messages (room_id, sender_user_id, content) " +
			"SELECT %d, %d, 'bulk' FROM generate_series(1, 105)",
			room,
			alice,
		),
	)
	unread, _ = databaseReadMarkerTestRoom(conn, bob, room)
	assert(
		unread == common.UNREAD_COUNT_CAP,
		fmt.tprintf("expected the count capped at %d, got %d", common.UNREAD_COUNT_CAP, unread),
	)
	unread, _ = databaseReadMarkerTestRoom(conn, carol, room)
	assert(unread == common.UNREAD_COUNT_CAP, "expected carol's fallback count capped too")

	// A newly created room starts with nothing unread for everyone, its creator included.
	created := databaseExecuteRequest(
		conn,
		common.DatabaseCreateRoomRequest {
			creatorUserId = alice,
			name = "read-new",
			roomType = .ChatAndVoice,
		},
	)
	defer IPC__database_query_response_deinit(created)
	mutation := created.result.(common.DatabaseRoomMutationResult)
	newRoom := mutation.room.id
	check(conn, newRoom, {{"alice", alice, 0}, {"bob", bob, 0}, {"carol", carol, 0}})

	// Deleting a room takes its markers with it.
	inNewRoom := databaseReadMarkerTestPostRoom(conn, newRoom, alice)
	databaseReadMarkerTestMark(conn, bob, .Room, newRoom, inNewRoom)
	databaseDefaultRoomTestExec(
		conn,
		"delete room",
		fmt.tprintf("DELETE FROM rooms WHERE id = %d", newRoom),
	)
	left := databaseMigrationTestValue(
		conn,
		fmt.tprintf("SELECT count(*)::text FROM room_read_markers WHERE room_id = %d", newRoom),
	)
	assert(left == "0", fmt.tprintf("expected the deleted room's markers gone, got %q", left))
}

@(test)
testMarkRoomReadMovesForwardClampsAndChecksMembershipAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn, schema := databaseReadMarkerTestOpen("mark_rooms")
	defer databaseMigrationTestClose(conn, schema)
	room := common.GENERAL_ROOM_ID

	alice := databaseSQLTestCreateUser(conn, "mark-alice")
	bob := databaseSQLTestCreateUser(conn, "mark-bob")
	// An empty room: nothing to mark, so nothing is stored and nothing changed.
	empty := databaseReadMarkerTestMark(conn, bob, .Room, room, 5)
	assert(
		empty == common.DatabaseMarkReadResult{allowed = true},
		fmt.tprintf("expected an empty room's mark-read to change nothing, got %v", empty),
	)

	first := databaseReadMarkerTestPostRoom(conn, room, alice)
	second := databaseReadMarkerTestPostRoom(conn, room, alice)
	third := databaseReadMarkerTestPostRoom(conn, room, alice)

	moved := databaseReadMarkerTestMark(conn, bob, .Room, room, second)
	assert(
		moved.changed && moved.lastReadMessageId == second && moved.unreadCount == 1,
		fmt.tprintf("expected the marker at %d with 1 unread, got %v", second, moved),
	)
	// The same ID again, and an older one, move nothing.
	again := databaseReadMarkerTestMark(conn, bob, .Room, room, second)
	noMove := common.DatabaseMarkReadResult {
		allowed = true,
	}
	assert(again == noMove, fmt.tprintf("expected a repeat to be a no-op, got %v", again))
	back := databaseReadMarkerTestMark(conn, bob, .Room, room, first)
	assert(back == noMove, fmt.tprintf("expected markers never to go back, got %v", back))
	_, marker := databaseReadMarkerTestRoom(conn, bob, room)
	assert(marker == second, fmt.tprintf("expected the marker to stay %d, got %d", second, marker))

	// An ID past the newest message is clamped to it.
	clamped := databaseReadMarkerTestMark(conn, bob, .Room, room, third + 1_000_000)
	assert(
		clamped.changed && clamped.lastReadMessageId == third && clamped.unreadCount == 0,
		fmt.tprintf("expected the marker clamped to %d, got %v", third, clamped),
	)
	stored := databaseMigrationTestValue(
		conn,
		fmt.tprintf(
			"SELECT last_read_message_id::text FROM room_read_markers " +
			"WHERE user_id = %d AND room_id = %d",
			bob,
			room,
		),
	)
	assert(
		stored == fmt.tprintf("%d", third),
		fmt.tprintf("expected %d stored, got %q", third, stored),
	)
	// A message in another room is not this room's newest.
	other := databaseExecuteRequest(
		conn,
		common.DatabaseCreateRoomRequest {
			creatorUserId = alice,
			name = "mark-other",
			roomType = .ChatAndVoice,
		},
	)
	defer IPC__database_query_response_deinit(other)
	otherRoom := other.result.(common.DatabaseRoomMutationResult).room.id
	elsewhere := databaseReadMarkerTestPostRoom(conn, otherRoom, alice)
	beyond := databaseReadMarkerTestMark(conn, bob, .Room, room, elsewhere)
	assert(
		beyond == common.DatabaseMarkReadResult{allowed = true},
		fmt.tprintf("expected a newer ID from another room to clamp to %d, got %v", third, beyond),
	)

	// Membership: a removed member and a room that does not exist are refused, untouched.
	databaseDefaultRoomTestExec(
		conn,
		"remove bob from the other room",
		fmt.tprintf("DELETE FROM room_members WHERE room_id = %d AND user_id = %d", otherRoom, bob),
	)
	refused := databaseReadMarkerTestMark(conn, bob, .Room, otherRoom, elsewhere)
	assert(refused == common.DatabaseMarkReadResult{}, "expected a non-member to be refused")
	missing := databaseReadMarkerTestMark(conn, bob, .Room, otherRoom + 100, 1)
	assert(missing == common.DatabaseMarkReadResult{}, "expected a missing room to be refused")
	count := databaseMigrationTestValue(
		conn,
		fmt.tprintf("SELECT count(*)::text FROM room_read_markers WHERE user_id = %d", bob),
	)
	assert(count == "1", fmt.tprintf("expected only bob's #general marker, got %q", count))
}

@(test)
testDirectUnreadAndMarkReadAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn, schema := databaseReadMarkerTestOpen("mark_direct")
	defer databaseMigrationTestClose(conn, schema)

	alice := databaseSQLTestCreateUser(conn, "dmread-alice")
	bob := databaseSQLTestCreateUser(conn, "dmread-bob")
	first := databaseSQLTestPostID(conn, alice, bob, "one")
	second := databaseSQLTestPostID(conn, alice, bob, "two")

	// No marker: every message from the peer is unread, and one's own never are.
	unread, marker := databaseReadMarkerTestDirect(conn, bob, alice)
	assert(
		unread == 2 && marker == 0,
		fmt.tprintf("expected bob 2 unread, got %d at %d", unread, marker),
	)
	unread, marker = databaseReadMarkerTestDirect(conn, alice, bob)
	assert(unread == 0 && marker == 0, fmt.tprintf("expected alice 0 unread, got %d", unread))

	moved := databaseReadMarkerTestMark(conn, bob, .Direct, alice, first)
	assert(
		moved == common.DatabaseMarkReadResult {
				allowed = true,
				changed = true,
				lastReadMessageId = first,
				unreadCount = 1,
			},
		fmt.tprintf("expected bob's marker at %d with 1 unread, got %v", first, moved),
	)
	unread, marker = databaseReadMarkerTestDirect(conn, bob, alice)
	assert(unread == 1 && marker == first, "expected the conversation list to agree")
	back := databaseReadMarkerTestMark(conn, bob, .Direct, alice, first)
	assert(
		back == common.DatabaseMarkReadResult{allowed = true},
		fmt.tprintf("expected a repeat to be a no-op, got %v", back),
	)

	// The conversation's newest message is in either direction: bob's own reply clamps too.
	reply := databaseSQLTestPostID(conn, bob, alice, "three")
	clamped := databaseReadMarkerTestMark(conn, bob, .Direct, alice, reply + 1_000_000)
	assert(
		clamped.changed && clamped.lastReadMessageId == reply && clamped.unreadCount == 0,
		fmt.tprintf("expected the marker clamped to %d, got %v", reply, clamped),
	)
	_ = second
	// A message from carol to alice is not part of bob's conversation with alice.
	carol := databaseSQLTestCreateUser(conn, "dmread-carol")
	elsewhere := databaseSQLTestPostID(conn, carol, alice, "four")
	beyond := databaseReadMarkerTestMark(conn, bob, .Direct, alice, elsewhere)
	assert(
		beyond == common.DatabaseMarkReadResult{allowed = true},
		"expected another conversation's newer message not to move bob's marker",
	)
	unread, _ = databaseReadMarkerTestDirect(conn, alice, carol)
	assert(unread == 1, fmt.tprintf("expected alice 1 unread from carol, got %d", unread))

	// Oneself and a missing account are refused.
	selfMark := databaseReadMarkerTestMark(conn, bob, .Direct, bob, reply)
	assert(selfMark == common.DatabaseMarkReadResult{}, "expected a self conversation refused")
	missing := databaseReadMarkerTestMark(conn, bob, .Direct, carol + 100, 1)
	assert(missing == common.DatabaseMarkReadResult{}, "expected an unknown peer refused")
	// A conversation with nothing in it stores nothing.
	empty := databaseReadMarkerTestMark(conn, bob, .Direct, carol, 5)
	assert(
		empty == common.DatabaseMarkReadResult{allowed = true},
		"expected an empty conversation to store nothing",
	)

	// Deleting an account takes the markers on both sides with it.
	databaseReadMarkerTestMark(conn, alice, .Direct, carol, elsewhere)
	databaseDefaultRoomTestExec(
		conn,
		"delete carol",
		fmt.tprintf(
			"DELETE FROM room_members WHERE user_id = %d; DELETE FROM users WHERE id = %d",
			carol,
			carol,
		),
	)
	left := databaseMigrationTestValue(
		conn,
		fmt.tprintf(
			"SELECT count(*)::text FROM direct_read_markers " +
			"WHERE user_id = %d OR peer_user_id = %d",
			carol,
			carol,
		),
	)
	assert(left == "0", fmt.tprintf("expected carol's markers gone, got %q", left))
}
