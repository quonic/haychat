package server

import "../common"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "shared:pg"

// The edit, delete and edit fetch statements (protocol 30, #76, database_message_edits.odin)
// against a migrated schema of their own (HAYCHAT_DATABASE_SQL_TEST=1): every refusal, the
// From join readers, tombstones with their files (D8) and the removal log, the edit tables'
// reuse checks in both directions, the unread rules skipping deleted messages (D13), and
// history and the conversation list carrying the latest edit and the tombstone (D14).

// What a statement decided, with everything a test reads copied to the temp allocator.
@(private = "file")
MessageEditSQLTestResult :: struct {
	outcome:   common.MessageChangeOutcome,
	senderId:  int,
	editCount: int,
	edit:      common.MessageEdit,
	deletedAt: string,
	signature: common.SignatureBytes,
	readers:   string,
	blobs:     int,
	edits:     []string,
}

@(private = "file")
messageEditSQLTestRun :: proc(
	conn: pg.Conn,
	request: common.DatabaseMessageChangeRequest,
) -> MessageEditSQLTestResult {
	owned := request
	owned.content = strings.clone(request.content)
	if len(request.sealed) > 0 {
		owned.sealed = make([]u8, len(request.sealed))
		copy(owned.sealed, request.sealed)
	}
	defer IPC__database_query_request_deinit(owned)
	response := databaseExecuteRequest(conn, owned)
	defer IPC__database_query_response_deinit(response)
	assert(
		response.success,
		fmt.tprintf("expected %v to run: %s", request.action, response.message),
	)
	result, ok := response.result.(common.DatabaseMessageChangeResult)
	assert(ok, "expected a message change result")
	readers := strings.builder_make(context.temp_allocator)
	for userID, index in result.readerUserIds {
		if index > 0 {
			strings.write_byte(&readers, ',')
		}
		fmt.sbprintf(&readers, "%d", userID)
	}
	edits := make([]string, len(result.edits), context.temp_allocator)
	for edit, index in result.edits {
		edits[index] = strings.clone(edit.content, context.temp_allocator)
	}
	copied := MessageEditSQLTestResult {
		outcome   = result.outcome,
		senderId  = result.senderId,
		editCount = result.editCount,
		edit      = common.MessageEdit_clone(result.edit, context.temp_allocator),
		deletedAt = strings.clone(result.deletion.deletedAt, context.temp_allocator),
		signature = result.deletion.signature,
		readers   = strings.to_string(readers),
		blobs     = len(result.removedBlobs),
		edits     = edits,
	}
	return copied
}

@(private = "file")
messageEditSQLTestRoom :: proc(conn: pg.Conn, name: string, access := 2, history := 2) -> int {
	value := databaseAdminTestValue(
		conn,
		fmt.tprintf(
			"INSERT INTO rooms (name, access, history_visibility) VALUES ('%s', %d, %d) " +
			"RETURNING id::text",
			name,
			access,
			history,
		),
	)
	id, ok := databaseParseTestInt(value)
	assert(ok, fmt.tprintf("expected a room ID, got %q", value))
	return id
}

@(private = "file")
messageEditSQLTestJoin :: proc(conn: pg.Conn, roomID, userID: int) {
	databaseDefaultRoomTestExec(
		conn,
		"join a room",
		fmt.tprintf("INSERT INTO room_members (room_id, user_id) VALUES (%d, %d)", roomID, userID),
	)
}

// Posts a plaintext room message and returns its ID and client message ID.
@(private = "file")
messageEditSQLTestPost :: proc(
	conn: pg.Conn,
	roomID, senderID: int,
	content: string,
	clientMessageID := common.ClientMessageID{},
) -> (
	int,
	common.ClientMessageID,
) {
	request := databaseTestPlainRoomPost(roomID, senderID, content)
	if common.clientMessageIDIsSet(clientMessageID) {
		request.clientMessageId = clientMessageID
	}
	response := databaseExecuteRequest(conn, request)
	defer IPC__database_query_response_deinit(response)
	posted, ok := response.result.(common.DatabasePostRoomChatMessageResult)
	assert(response.success && ok, fmt.tprintf("expected the post to run: %s", response.message))
	return posted.storedMessage.id, request.clientMessageId
}

@(private = "file")
messageEditSQLTestEdit :: proc(
	conn: pg.Conn,
	actor, roomID, messageID: int,
	original: common.ClientMessageID,
	content: string,
	editID := common.ClientMessageID{},
) -> MessageEditSQLTestResult {
	edit := editID
	if !common.clientMessageIDIsSet(edit) {
		edit = databaseTestClientMessageID()
	}
	return messageEditSQLTestRun(
		conn,
		common.DatabaseMessageChangeRequest {
			action = .EditRoom,
			actorUserId = actor,
			roomId = roomID,
			messageId = messageID,
			originalClientMessageId = original,
			clientMessageId = edit,
			content = content,
			signature = DATABASE_TEST_SIGNATURE,
		},
	)
}

@(private = "file")
messageEditSQLTestDelete :: proc(
	conn: pg.Conn,
	actor, roomID, messageID: int,
	original: common.ClientMessageID,
	admin := false,
) -> MessageEditSQLTestResult {
	return messageEditSQLTestRun(
		conn,
		common.DatabaseMessageChangeRequest {
			action = .DeleteRoom,
			actorUserId = actor,
			roomId = roomID,
			messageId = messageID,
			originalClientMessageId = original,
			signature = admin ? {} : DATABASE_TEST_SIGNATURE,
			adminDelete = admin,
		},
	)
}

// A room history page for userID as "id:content:editCount:lastEdit:deleted:signed" entries.
@(private = "file")
messageEditSQLTestHistory :: proc(conn: pg.Conn, roomID, userID: int) -> string {
	response := databaseExecuteRequest(
		conn,
		common.DatabaseRoomHistoryRequest{roomId = roomID, userId = userID, limit = 50},
	)
	defer IPC__database_query_response_deinit(response)
	history, ok := response.result.(common.DatabaseRoomHistoryResult)
	assert(response.success && ok, "expected the history page")
	builder := strings.builder_make(context.temp_allocator)
	for message, index in history.messages {
		if index > 0 {
			strings.write_byte(&builder, ',')
		}
		fmt.sbprintf(
			&builder,
			"%d:%s:%d:%s:%v:%v:%d",
			message.id,
			message.content,
			message.editCount,
			message.lastEdit.content,
			message.deleted,
			message.deletion.signature != {},
			len(message.attachments),
		)
	}
	return strings.to_string(builder)
}

// The edit and delete statements in rooms: the author edits, every refusal, the cap, reuse of
// IDs across messages and edits, the edit list, From join readers, deletes by the author and by
// an admin, and the unread rule.
@(test)
testRoomMessageEditsAndDeletesAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "message_edits")
	alice := databaseAdminTestUser(conn, "edit-alice")
	bob := databaseAdminTestUser(conn, "edit-bob")
	carol := databaseAdminTestUser(conn, "edit-carol")
	admin := databaseAdminTestUser(conn, "edit-admin")
	databaseAdminTestGrant(conn, admin)
	room := messageEditSQLTestRoom(conn, "edit-room")
	for user in ([]int{alice, bob}) {
		messageEditSQLTestJoin(conn, room, user)
	}

	first, firstID := messageEditSQLTestPost(conn, room, alice, "first")
	second, secondID := messageEditSQLTestPost(conn, room, bob, "second")

	edited := messageEditSQLTestEdit(conn, alice, room, first, firstID, "first, edited")
	assert(
		edited.outcome == .Applied &&
		edited.senderId == alice &&
		edited.editCount == 1 &&
		edited.edit.id > 0 &&
		edited.edit.content == "first, edited" &&
		len(edited.edit.timestamp) > 0 &&
		edited.readers == fmt.tprintf("%d,%d", alice, bob),
		fmt.tprintf("expected alice's edit stored for both members, got %v", edited),
	)
	again := messageEditSQLTestEdit(conn, alice, room, first, firstID, "first, again")
	assert(again.outcome == .Applied && again.editCount == 2, "expected a second edit")
	history := messageEditSQLTestHistory(conn, room, bob)
	assert(
		history ==
		fmt.tprintf(
			"%d:first:2:first, again:false:false:0,%d:second:0::false:false:0",
			first,
			second,
		),
		fmt.tprintf("expected history to carry the latest edit and its count, got %s", history),
	)

	// Refusals, each checked in the statement.
	outcome := messageEditSQLTestEdit(conn, bob, room, first, firstID, "not mine").outcome
	assert(outcome == .NotAuthor, fmt.tprintf("expected not_author, got %v", outcome))
	outcome = messageEditSQLTestEdit(conn, carol, room, first, firstID, "outsider").outcome
	assert(outcome == .NotMember, fmt.tprintf("expected not_member, got %v", outcome))
	outcome = messageEditSQLTestEdit(conn, alice, room, first, secondID, "moved").outcome
	assert(outcome == .NotFound, fmt.tprintf("expected another ID refused, got %v", outcome))
	outcome = messageEditSQLTestEdit(conn, alice, room, second + 1000, firstID, "gone").outcome
	assert(outcome == .NotFound, fmt.tprintf("expected an unknown message, got %v", outcome))
	outcome = messageEditSQLTestEdit(conn, alice, room, first, firstID, "").outcome
	assert(
		outcome == .InvalidContent,
		fmt.tprintf("expected an empty edit refused, got %v", outcome),
	)
	// An edit ID used before, by a message or an edit, is refused, and so is a new message with
	// an edit's ID (the post statement checks the edit table).
	outcome =
		messageEditSQLTestEdit(conn, alice, room, first, firstID, "x", editID = firstID).outcome
	assert(outcome == .Duplicate, fmt.tprintf("expected a message's ID refused, got %v", outcome))
	editID := databaseTestClientMessageID()
	third := messageEditSQLTestEdit(conn, alice, room, first, firstID, "third", editID = editID)
	assert(third.outcome == .Applied, "expected the third edit")
	outcome =
		messageEditSQLTestEdit(conn, alice, room, first, firstID, "x", editID = editID).outcome
	assert(outcome == .Duplicate, fmt.tprintf("expected an edit's ID refused, got %v", outcome))
	reused, _ := messageEditSQLTestPost(conn, room, alice, "reused", clientMessageID = editID)
	assert(reused == 0, "expected a new message with an edit's ID refused")
	// D10: without SendMessages the author cannot edit; a voice-only room has no chat.
	databaseDefaultRoomTestExec(
		conn,
		"take Send away",
		fmt.tprintf("UPDATE rooms SET everyone_permissions = 2 WHERE id = %d", room),
	)
	outcome = messageEditSQLTestEdit(conn, alice, room, first, firstID, "muted").outcome
	assert(outcome == .SendDenied, fmt.tprintf("expected send_denied, got %v", outcome))
	databaseDefaultRoomTestExec(
		conn,
		"give Send back, make the room voice only",
		fmt.tprintf(
			"UPDATE rooms SET everyone_permissions = 19, room_type = 2 WHERE id = %d",
			room,
		),
	)
	outcome = messageEditSQLTestEdit(conn, alice, room, first, firstID, "voice").outcome
	assert(outcome == .ChatDisabled, fmt.tprintf("expected chat_disabled, got %v", outcome))
	databaseDefaultRoomTestExec(
		conn,
		"make it a chat room again",
		fmt.tprintf("UPDATE rooms SET room_type = 3 WHERE id = %d", room),
	)
	// D11: a sealed edit of a plaintext message is refused.
	sealedEdit := messageEditSQLTestRun(
		conn,
		common.DatabaseMessageChangeRequest {
			action = .EditRoom,
			actorUserId = alice,
			roomId = room,
			messageId = first,
			originalClientMessageId = firstID,
			clientMessageId = databaseTestClientMessageID(),
			sealed = []u8{1, 2, 3},
			epoch = 1,
			chainIndex = 0,
		},
	)
	assert(sealedEdit.outcome == .KindMismatch, "expected a sealed edit of plaintext refused")
	// D12: at most MESSAGE_EDITS_MAX edits.
	databaseDefaultRoomTestExec(
		conn,
		"reach the cap",
		fmt.tprintf("UPDATE chat_messages SET edit_count = 100 WHERE id = %d", first),
	)
	outcome = messageEditSQLTestEdit(conn, alice, room, first, firstID, "101").outcome
	assert(outcome == .EditLimit, fmt.tprintf("expected edit_limit, got %v", outcome))
	databaseDefaultRoomTestExec(
		conn,
		"back under the cap",
		fmt.tprintf("UPDATE chat_messages SET edit_count = 3 WHERE id = %d", first),
	)

	// The edit list, oldest first; a non-member gets nothing.
	fetched := messageEditSQLTestRun(
		conn,
		common.DatabaseMessageChangeRequest {
			action = .FetchRoomEdits,
			actorUserId = bob,
			roomId = room,
			messageId = first,
		},
	)
	assert(
		fetched.outcome == .Applied &&
		len(fetched.edits) == 3 &&
		fetched.edits[0] == "first, edited" &&
		fetched.edits[2] == "third",
		fmt.tprintf("expected three edits oldest first, got %v", fetched.edits),
	)
	notMember := messageEditSQLTestRun(
		conn,
		common.DatabaseMessageChangeRequest {
			action = .FetchRoomEdits,
			actorUserId = carol,
			roomId = room,
			messageId = first,
		},
	)
	assert(notMember.outcome == .NotMember, "expected a non-member's fetch refused")

	// From join: carol joins a From join room after a message; she is not one of its readers
	// and cannot fetch its edits, but she reads one sent after she joined.
	cut := messageEditSQLTestRoom(conn, "edit-cut", access = 2, history = 1)
	databaseDefaultRoomTestExec(
		conn,
		"alice joined long ago",
		fmt.tprintf(
			"INSERT INTO room_members (room_id, user_id, joined_at) VALUES " +
			"(%d, %d, clock_timestamp() - interval '1 hour')",
			cut,
			alice,
		),
	)
	early, earlyID := messageEditSQLTestPost(conn, cut, alice, "before carol")
	databaseDefaultRoomTestExec(
		conn,
		"carol joins later",
		fmt.tprintf(
			"INSERT INTO room_members (room_id, user_id, joined_at) VALUES " +
			"(%d, %d, clock_timestamp() + interval '1 second')",
			cut,
			carol,
		),
	)
	databaseDefaultRoomTestExec(
		conn,
		"date the early message before the join",
		fmt.tprintf(
			"UPDATE chat_messages SET created_at = clock_timestamp() - interval '1 minute' " +
			"WHERE id = %d",
			early,
		),
	)
	earlyEdit := messageEditSQLTestEdit(conn, alice, cut, early, earlyID, "before carol, edited")
	assert(
		earlyEdit.outcome == .Applied && earlyEdit.readers == fmt.tprintf("%d", alice),
		fmt.tprintf("expected only alice to read the early message, got %q", earlyEdit.readers),
	)
	hidden := messageEditSQLTestRun(
		conn,
		common.DatabaseMessageChangeRequest {
			action = .FetchRoomEdits,
			actorUserId = carol,
			roomId = cut,
			messageId = early,
		},
	)
	assert(hidden.outcome == .NotFound, "expected carol not to read the early message's edits")

	// Deletes: not by another member, by the author (signed), then never again or edited.
	outcome = messageEditSQLTestDelete(conn, bob, room, first, firstID).outcome
	assert(outcome == .NotAuthor, fmt.tprintf("expected bob's delete refused, got %v", outcome))
	outcome = messageEditSQLTestDelete(conn, bob, room, first, firstID, admin = true).outcome
	assert(
		outcome == .NotAdmin,
		fmt.tprintf("expected an unsigned delete refused, got %v", outcome),
	)
	deleted := messageEditSQLTestDelete(conn, alice, room, first, firstID)
	assert(
		deleted.outcome == .Applied &&
		len(deleted.deletedAt) > 0 &&
		deleted.signature == DATABASE_TEST_SIGNATURE &&
		deleted.readers == fmt.tprintf("%d,%d", alice, bob),
		fmt.tprintf("expected alice's delete, got %v", deleted),
	)
	outcome = messageEditSQLTestDelete(conn, alice, room, first, firstID).outcome
	assert(outcome == .Deleted, fmt.tprintf("expected a second delete refused, got %v", outcome))
	outcome = messageEditSQLTestEdit(conn, alice, room, first, firstID, "zombie").outcome
	assert(
		outcome == .Deleted,
		fmt.tprintf("expected an edit of a tombstone refused, got %v", outcome),
	)
	tombstone := databaseAdminTestValue(
		conn,
		fmt.tprintf(
			"SELECT content || '/' || (sealed IS NULL) || '/' || (signature IS NULL) || '/' || " +
			"(client_message_id IS NOT NULL) || '/' || edit_count || '/' || " +
			"deleted_by_user_id || " +
			"'/' || (SELECT count(*) FROM chat_message_edits WHERE message_id = %d) " +
			"FROM chat_messages WHERE id = %d",
			first,
			first,
		),
	)
	assert(
		tombstone == fmt.tprintf("/true/true/true/0/%d/0", alice),
		fmt.tprintf("expected a tombstone with its ID and no edits, got %s", tombstone),
	)
	// The tombstone's client message ID is still spent.
	spent, _ := messageEditSQLTestPost(conn, room, alice, "spent", clientMessageID = firstID)
	assert(spent == 0, "expected the tombstone's client message ID refused")
	history = messageEditSQLTestHistory(conn, room, bob)
	assert(
		strings.has_prefix(history, fmt.tprintf("%d::0::true:true:0,", first)),
		fmt.tprintf("expected history to carry the signed tombstone, got %s", history),
	)

	// An admin deletes another account's message without a signature, without being a member.
	moderated := messageEditSQLTestDelete(conn, admin, room, second, {}, admin = true)
	assert(
		moderated.outcome == .Applied &&
		moderated.senderId == bob &&
		moderated.signature == {} &&
		moderated.readers == fmt.tprintf("%d,%d", alice, bob),
		fmt.tprintf("expected the admin's delete, got %v", moderated),
	)

	// D13: deleted messages never count as unread. alice read up to her first message; bob's
	// second is deleted, his third and fourth are not.
	_, _ = messageEditSQLTestPost(conn, room, bob, "third")
	_, _ = messageEditSQLTestPost(conn, room, bob, "fourth")
	databaseDefaultRoomTestExec(
		conn,
		"alice's marker",
		fmt.tprintf(
			"INSERT INTO room_read_markers (user_id, room_id, last_read_message_id) " +
			"VALUES (%d, %d, %d)",
			alice,
			room,
			first,
		),
	)
	rule, _ := strings.replace_all(
		DATABASE_ROOMS_WITH_UNREAD_SQL,
		"$1::bigint",
		fmt.tprintf("%d", alice),
		context.temp_allocator,
	)
	capped, _ := strings.replace_all(rule, "$2::bigint", "100", context.temp_allocator)
	unread := databaseAdminTestValue(
		conn,
		fmt.tprintf("SELECT unread.n::text %s WHERE r.id = %d", capped, room),
	)
	assert(
		unread == "2",
		fmt.tprintf("expected only bob's two live messages unread, got %s", unread),
	)
}

// Files of a deleted message become Removed tombstones in the same statement (D8); only an
// admin's delete logs them.
@(test)
testMessageDeleteRemovesItsFilesAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "message_delete_files")
	alice := databaseAdminTestUser(conn, "files-alice")
	admin := databaseAdminTestUser(conn, "files-admin")
	databaseAdminTestGrant(conn, admin)
	room := messageEditSQLTestRoom(conn, "files-room")
	messageEditSQLTestJoin(conn, room, alice)
	own, ownID := messageEditSQLTestPost(conn, room, alice, "with a file")
	moderated, _ := messageEditSQLTestPost(conn, room, alice, "with another file")
	databaseDefaultRoomTestExec(
		conn,
		"bind a file to each message",
		fmt.tprintf(
			"INSERT INTO attachments (blob_id, owner_user_id, room_id, encrypted, state, size, " +
			"received, sha256, chat_message_id, completed_at, bound_at, position, name, " +
			"media_type) VALUES (decode(repeat('a1', 16), 'hex'), %d, %d, false, 2, 5, 5, " +
			"decode(repeat('0b', 32), 'hex'), %d, now(), now(), 0, 'a.txt', 'text/plain'), " +
			"(decode(repeat('b2', 16), 'hex'), %d, %d, false, 2, 5, 5, " +
			"decode(repeat('0c', 32), 'hex'), %d, now(), now(), 0, 'b.txt', 'text/plain'); " +
			"UPDATE chat_messages SET attachment_count = 1 WHERE id IN (%d, %d)",
			alice,
			room,
			own,
			alice,
			room,
			moderated,
			own,
			moderated,
		),
	)
	// A message with a file may lose its text in an edit (D9).
	assert(
		messageEditSQLTestEdit(conn, alice, room, own, ownID, "").outcome == .Applied,
		"expected an empty edit of a message with a file",
	)
	deleted := messageEditSQLTestDelete(conn, alice, room, own, ownID)
	assert(deleted.outcome == .Applied && deleted.blobs == 1, "expected the author's delete")
	removed := messageEditSQLTestDelete(conn, admin, room, moderated, {}, admin = true)
	assert(removed.outcome == .Applied && removed.blobs == 1, "expected the admin's delete")
	states := databaseAdminTestValue(
		conn,
		"SELECT string_agg(substr(encode(blob_id, 'hex'), 1, 2) || ':' || state || ':' || " +
		"removed_by_user_id, ',' ORDER BY blob_id) FROM attachments",
	)
	assert(
		states == fmt.tprintf("a1:3:%d,b2:3:%d", alice, admin),
		fmt.tprintf("expected both files Removed by their deleters, got %s", states),
	)
	logged := databaseAdminTestValue(
		conn,
		"SELECT COALESCE(string_agg(substr(encode(blob_id, 'hex'), 1, 2) || ':' || " +
		"removed_by_user_id || ':' || reason || ':' || name, ','), '') FROM attachment_removals",
	)
	assert(
		logged == fmt.tprintf("b2:%d:%s:b.txt", admin, DATABASE_MESSAGE_DELETED_REMOVAL_REASON),
		fmt.tprintf("expected only the admin's delete in the removal log, got %s", logged),
	)
	// The tombstone lists no files, and the download check refuses them.
	history := messageEditSQLTestHistory(conn, room, alice)
	assert(
		strings.contains(history, fmt.tprintf("%d::0::true:true:0", own)),
		fmt.tprintf("expected the tombstone without files, got %s", history),
	)
}

// Direct messages: the sender edits and deletes (signed), the recipient cannot, the
// conversation preview carries the latest edit and then the tombstone, and a deleted message
// is not unread.
@(test)
testDirectMessageEditsAndDeletesAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "direct_edits")
	alice := databaseSQLTestCreateUser(conn, "dme-alice")
	bob := databaseSQLTestCreateUser(conn, "dme-bob")
	carol := databaseSQLTestCreateUser(conn, "dme-carol")
	post := databaseSQLTestPost(conn, alice, bob, "hello bob")
	posted := post.result.(common.DatabasePostDirectMessageResult)
	messageID := posted.storedMessage.id
	original := posted.storedMessage.clientMessageId
	IPC__database_query_response_deinit(post)
	edit :: proc(
		conn: pg.Conn,
		actor, peer, messageID: int,
		original: common.ClientMessageID,
		content: string,
	) -> MessageEditSQLTestResult {
		return messageEditSQLTestRun(
			conn,
			common.DatabaseMessageChangeRequest {
				action = .EditDirect,
				actorUserId = actor,
				peerUserId = peer,
				messageId = messageID,
				originalClientMessageId = original,
				clientMessageId = databaseTestClientMessageID(),
				content = content,
				signature = DATABASE_TEST_SIGNATURE,
			},
		)
	}
	edited := edit(conn, alice, bob, messageID, original, "hello bob, edited")
	assert(
		edited.outcome == .Applied &&
		edited.editCount == 1 &&
		edited.readers == fmt.tprintf("%d,%d", alice, bob),
		fmt.tprintf("expected alice's DM edit for both sides, got %v", edited),
	)
	outcome := edit(conn, bob, alice, messageID, original, "not mine").outcome
	assert(outcome == .NotAuthor, fmt.tprintf("expected bob's edit refused, got %v", outcome))
	outcome = edit(conn, carol, alice, messageID, original, "outsider").outcome
	assert(outcome == .NotFound, fmt.tprintf("expected carol's edit refused, got %v", outcome))

	conversations := databaseExecuteRequest(
		conn,
		common.DatabaseDirectConversationListRequest{userId = bob},
	)
	list := conversations.result.(common.DatabaseDirectConversationListResult)
	assert(
		len(list.conversations) == 1 &&
		list.conversations[0].lastEditCount == 1 &&
		list.conversations[0].lastEdit.content == "hello bob, edited" &&
		list.conversations[0].unreadCount == 1,
		fmt.tprintf("expected the preview to carry the edit, got %v", list.conversations),
	)
	IPC__database_query_response_deinit(conversations)

	refused := messageEditSQLTestRun(
		conn,
		common.DatabaseMessageChangeRequest {
			action = .DeleteDirect,
			actorUserId = bob,
			peerUserId = alice,
			messageId = messageID,
			originalClientMessageId = original,
			signature = DATABASE_TEST_SIGNATURE,
		},
	)
	assert(refused.outcome == .NotAuthor, "expected the recipient's delete refused (D5)")
	deleted := messageEditSQLTestRun(
		conn,
		common.DatabaseMessageChangeRequest {
			action = .DeleteDirect,
			actorUserId = alice,
			peerUserId = bob,
			messageId = messageID,
			originalClientMessageId = original,
			signature = DATABASE_TEST_SIGNATURE,
		},
	)
	assert(
		deleted.outcome == .Applied && deleted.readers == fmt.tprintf("%d,%d", alice, bob),
		"expected alice's DM delete",
	)
	conversations = databaseExecuteRequest(
		conn,
		common.DatabaseDirectConversationListRequest{userId = bob},
	)
	list = conversations.result.(common.DatabaseDirectConversationListResult)
	assert(
		len(list.conversations) == 1 &&
		list.conversations[0].lastDeleted &&
		list.conversations[0].lastEditCount == 0 &&
		list.conversations[0].lastContent == "" &&
		list.conversations[0].lastDeletion.signature == DATABASE_TEST_SIGNATURE &&
		list.conversations[0].unreadCount == 0,
		fmt.tprintf(
			"expected the preview to be the tombstone, not unread, got %v",
			list.conversations,
		),
	)
	IPC__database_query_response_deinit(conversations)
	fetched := messageEditSQLTestRun(
		conn,
		common.DatabaseMessageChangeRequest {
			action = .FetchDirectEdits,
			actorUserId = bob,
			peerUserId = alice,
			messageId = messageID,
		},
	)
	assert(fetched.outcome == .Applied && len(fetched.edits) == 0, "expected no edits after it")
}
