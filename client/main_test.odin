#+feature dynamic-literals
package client

import "../common"
import "core:encoding/cbor"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

roomChatSendBridgeTestMutex: sync.Mutex
roomChatSendBridgeTestServerID: int
roomChatSendBridgeTestRoomID: int
roomChatSendBridgeTestContent: string
roomChatSendBridgeTestReturnValue: bool

// The last send's client message ID and signature (protocol 22).
roomChatSendBridgeTestSend: RoomChatSend

roomChatSendBridgeTestStub :: proc(transport: ^ClientServerTransport, send: RoomChatSend) -> bool {
	roomChatSendBridgeTestServerID = transport.serverID
	roomChatSendBridgeTestRoomID = send.roomID
	// The sender frees the message after sending, so keep a copy for assertions.
	delete(roomChatSendBridgeTestContent)
	roomChatSendBridgeTestContent = strings.clone(send.content)
	roomChatSendBridgeTestSend = send
	roomChatSendBridgeTestSend.content = ""
	return roomChatSendBridgeTestReturnValue
}

buildServerHelloPacketBytes :: proc(
	transport: ^ClientServerTransport,
	serverIdentityPrivateKey: common.IdentityPrivateKeyBytes,
	serverIdentityPublicKey: common.IdentityPublicKeyBytes,
	serverEphemeralPublicKey: common.KeyExchangePublicKeyBytes,
	sessionID: common.SessionID,
) -> (
	[]u8,
	bool,
) {
	clientHello := common.ClientHello {
		version                  = common.protocolVersion,
		nickname                 = transport.nickname,
		clientIdentityPublicKey  = transport.clientIdentityPublicKey,
		clientEphemeralPublicKey = transport.clientEphemeralPublicKey,
	}
	serverHelloProof := common.buildServerHelloProof(
		sessionID,
		clientHello.nickname,
		clientHello.clientIdentityPublicKey,
		clientHello.clientEphemeralPublicKey,
		serverIdentityPublicKey,
		serverEphemeralPublicKey,
	)
	serverHello, signOK := common.signServerHello(serverIdentityPrivateKey, serverHelloProof)
	if !signOK {
		return nil, false
	}
	return common.buildPacketBytes(.ServerHello, serverHello)
}

// Returns a fully owned config (free it with Config_deinit). The servers array is consumed;
// its entries may use string literals because each one is cloned.
testConfigWithServers :: proc(servers: [dynamic]Server) -> Config {
	defer delete(servers)
	privateKey, publicKey, ok := common.generateIdentityKeyPair()
	assert(ok, "expected identity key generation to succeed")

	config := Config {
		private_key  = common.identityPrivateKeyToHex(privateKey),
		public_key   = common.identityPublicKeyToHex(publicKey),
		display_name = strings.clone("Tester"),
	}
	for server in servers {
		owned := Server_clone(server)
		if len(owned.short_name) == 0 {
			delete(owned.short_name)
			owned.short_name = getShortServerName(owned.name)
		}
		append(&config.servers, owned)
	}
	return config
}

// Builds a state that owns all of its memory; free it with State_deinit.
testStateWithServers :: proc(servers: [dynamic]Server) -> State {
	config := testConfigWithServers(servers)
	defer Config_deinit(&config)
	return State_initFromConfig(config)
}

buildEstablishedTransportPair :: proc(
	server: Server,
	config: Config,
) -> (
	ClientServerTransport,
	common.TransportState,
	bool,
) {
	transport, message, ok := ClientServerTransport_init(server, config)
	assert(ok, message)

	serverEphemeralPrivateKey, serverEphemeralPublicKey, serverEphemeralOK :=
		common.generateKeyExchangeKeyPair()
	assert(serverEphemeralOK, "expected server ephemeral key generation to succeed")

	clientSharedSecret, clientSharedSecretOK := common.deriveSharedSecret(
		&transport.clientEphemeralPrivateKey,
		serverEphemeralPublicKey,
	)
	assert(clientSharedSecretOK, "expected client shared secret derivation to succeed")

	serverSharedSecret, serverSharedSecretOK := common.deriveSharedSecret(
		&serverEphemeralPrivateKey,
		transport.clientEphemeralPublicKey,
	)
	assert(serverSharedSecretOK, "expected server shared secret derivation to succeed")

	sessionID, sessionIDOK := common.generateSessionID()
	assert(sessionIDOK, "expected session ID generation to succeed")

	transcriptText := "client-runtime-transport"
	transcriptHash := common.hashBytes(transmute([]u8)(transcriptText))
	clientKeys := common.deriveDirectionalTransportKeys(
		.Client,
		sessionID,
		clientSharedSecret,
		transcriptHash,
	)
	serverKeys := common.deriveDirectionalTransportKeys(
		.Server,
		sessionID,
		serverSharedSecret,
		transcriptHash,
	)

	transport.sessionID = sessionID
	transport.serverEphemeralPublicKey = serverEphemeralPublicKey
	common.TransportState_activate(&transport.transport, sessionID, clientKeys, .Trusted)
	transport.authenticatedUserID = 77

	serverTransport := common.TransportState_init(.Server)
	common.TransportState_activate(&serverTransport, sessionID, serverKeys, .Trusted)

	return transport, serverTransport, true
}

testUpdateStateForServer :: proc(server: Server) -> State {
	state := testStateWithServers({server})
	state.selected_server_id = server.id
	state.selected_transport_index = State_selectedTransportIndexForServerID(state, server.id)
	state.selected_channel_id = common.GENERAL_ROOM_ID
	append(State_selectedRoomDraft(&state), "pending channel draft")
	return state
}

// Applies a room chat event the way the frame loop does, including the event cleanup, so tests
// exercise the real ownership path.
testApplyRoomChat :: proc(
	state: ^State,
	serverID, roomID, senderID, messageID: int,
	content: string,
	senderNickname := "",
) {
	event := ClientTransportRuntimeEvent {
		kind           = .RoomChatReceived,
		serverID       = serverID,
		roomID         = roomID,
		senderID       = senderID,
		senderNickname = strings.clone(senderNickname),
		messageID      = messageID,
		timestamp      = strings.clone("t"),
		message        = strings.clone(content),
	}
	// Signed by its sender, as every plaintext room message is (protocol 22); the state pins
	// the sender's test identity.
	event.clientMessageID, event.signature = testRoomMessageSignature(
		state,
		serverID,
		roomID,
		senderID,
		messageID,
		content,
	)
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

testSetDraft :: proc(draft: ^[dynamic]u8, value: string) {
	clear(draft)
	append(draft, value)
}

// Marks a server as signed in the way the worker's Connected event does.
testApplyConnected :: proc(state: ^State, serverID, userID: int) {
	event := ClientTransportRuntimeEvent {
		kind     = .Connected,
		serverID = serverID,
		userID   = userID,
		nickname = strings.clone(state.config.display_name),
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

liveTestConnectionStatus :: proc(state: ^State, serverID: int) -> string {
	connection := State_serverConnection(state, serverID)
	return fmt.tprintf(
		"status=%v failure=%v detail=%q",
		connection.status,
		connection.failureKind,
		connection.detail,
	)
}

// Pumps the state's network worker the way the frame loop does, until an event of `kind`
// arrives or the timeout passes. Other events are applied to the state; the matching event is
// returned unapplied and the caller owns it.
liveTestWaitForEvent :: proc(
	state: ^State,
	kind: ClientTransportRuntimeEventKind,
	timeout: time.Duration,
) -> (
	ClientTransportRuntimeEvent,
	bool,
) {
	start := time.tick_now()
	for time.tick_since(start) < timeout {
		event, hasEvent := ClientNetworkWorker_popEvent(state.networkWorker)
		if !hasEvent {
			time.sleep(5 * time.Millisecond)
			continue
		}
		if event.kind == kind {
			return event, true
		}
		State_applyRuntimeEvent(state, &event)
		ClientTransportRuntimeEvent_deinit(&event)
	}
	return {}, false
}

// Starts the worker and waits until the server has signed the client in, then applies the
// Connected event (which also requests the room list).
liveTestConnect :: proc(
	t: ^testing.T,
	state: ^State,
	label: string,
	timeout: time.Duration = 10 * time.Second,
) -> bool {
	State_startNetwork(state)
	serverID := state.selected_server_id
	event, connected := liveTestWaitForEvent(state, .Connected, timeout)
	if !connected {
		testing.expectf(
			t,
			false,
			"expected %s to connect and sign in, got %s",
			label,
			liveTestConnectionStatus(state, serverID),
		)
		return false
	}
	testing.expectf(t, event.userID != 0, "expected %s to get a non-zero user ID", label)
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
	testing.expectf(
		t,
		State_isServerConnected(state, serverID),
		"expected %s to show as connected, got %s",
		label,
		liveTestConnectionStatus(state, serverID),
	)
	return true
}

@(test)
testStateInitFromConfigStartsInServerChatForFirstRelease :: proc(t: ^testing.T) {
	server := Server {
		id         = 500,
		name       = "First Release Server",
		host       = "localhost",
		port       = common.DEFAULT_SERVER_PORT,
	}
	state := testStateWithServers({server})
	defer State_deinit(&state)

	testing.expect(
		t,
		state.selected_dm_peer_id == 0,
		"expected startup to open the selected server's room instead of a conversation",
	)
	testing.expect(
		t,
		state.selected_server_id == server.id,
		"expected first-release startup to select the first configured server",
	)
	testing.expect(
		t,
		state.selected_channel_id == common.GENERAL_ROOM_ID,
		"expected first-release startup to select the General room",
	)

	_ = t
}

@(test)
testSendChannelChatDoesNotAppendVisibleChatOnSubmit :: proc(t: ^testing.T) {
	sync.mutex_lock(&roomChatSendBridgeTestMutex)
	defer sync.mutex_unlock(&roomChatSendBridgeTestMutex)

	server := Server {
		id         = 501,
		name       = "Reducer Server",
		host       = "localhost",
		port       = common.DEFAULT_SERVER_PORT,
	}
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)
	testPrepareRoomSend(&state, server.id, 70)
	testSetDraft(State_selectedRoomDraft(&state), "hello\thaychat")

	originalRoomChatSendBridge := roomChatSendBridge
	roomChatSendBridgeTestServerID = 0
	roomChatSendBridgeTestRoomID = 0
	delete(roomChatSendBridgeTestContent)
	roomChatSendBridgeTestContent = ""
	roomChatSendBridgeTestReturnValue = true
	roomChatSendBridge = roomChatSendBridgeTestStub
	defer roomChatSendBridge = originalRoomChatSendBridge

	State_sendChannelChat(&state)

	view := buildRoomView(&state)
	testing.expect(
		t,
		len(view.lines) == 0,
		"expected channel submit to avoid locally appending visible chat",
	)
	testing.expect(
		t,
		len(State_selectedRoomDraft(&state)) == 0,
		"expected successful channel submit to clear the room draft",
	)
	testing.expect(
		t,
		roomChatSendBridgeTestServerID == server.id,
		"expected channel submit to target the selected transport",
	)
	testing.expect(
		t,
		roomChatSendBridgeTestRoomID == common.GENERAL_ROOM_ID,
		"expected channel submit to target the General room",
	)
	testing.expectf(
		t,
		roomChatSendBridgeTestContent == "hello    haychat",
		"expected the tab-normalized draft to reach the transport bridge, got %q",
		roomChatSendBridgeTestContent,
	)
	signedSend := roomChatSendBridgeTestSend
	signedSend.content = roomChatSendBridgeTestContent
	testing.expect(
		t,
		common.clientMessageIDIsSet(signedSend.clientMessageID) &&
		testRoomSendVerifies(&state, server.id, 70, signedSend),
		"expected the message signed by this profile (protocol 22)",
	)
	testing.expect(
		t,
		len(state.chat_status_message) == 0,
		"expected successful channel submit to keep the chat status clear",
	)

	delete(roomChatSendBridgeTestContent)
	roomChatSendBridgeTestContent = ""
}

@(test)
testSendChannelChatKeepsDraftWhenTransportRejects :: proc(t: ^testing.T) {
	sync.mutex_lock(&roomChatSendBridgeTestMutex)
	defer sync.mutex_unlock(&roomChatSendBridgeTestMutex)

	server := Server {
		id   = 508,
		name = "Rejecting Server",
		host = "localhost",
		port = common.DEFAULT_SERVER_PORT,
	}
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)
	testPrepareRoomSend(&state, server.id, 70)

	originalRoomChatSendBridge := roomChatSendBridge
	roomChatSendBridgeTestReturnValue = false
	roomChatSendBridge = roomChatSendBridgeTestStub
	defer roomChatSendBridge = originalRoomChatSendBridge

	State_sendChannelChat(&state)

	testing.expectf(
		t,
		string(State_selectedRoomDraft(&state)[:]) == "pending channel draft",
		"expected a rejected send to keep the draft, got %q",
		string(State_selectedRoomDraft(&state)[:]),
	)
	testing.expect(
		t,
		len(state.chat_status_message) > 0,
		"expected a rejected send to surface a chat status",
	)

	delete(roomChatSendBridgeTestContent)
	roomChatSendBridgeTestContent = ""
}

@(test)
testReceiveRoomChatAppendsOnlyOnAuthoritativeReceive :: proc(t: ^testing.T) {
	sync.mutex_lock(&roomChatSendBridgeTestMutex)
	defer sync.mutex_unlock(&roomChatSendBridgeTestMutex)

	server := Server {
		id         = 502,
		name       = "Authoritative Server",
		host       = "localhost",
		port       = common.DEFAULT_SERVER_PORT,
	}
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)
	testApplyConnected(&state, server.id, 77)

	originalRoomChatSendBridge := roomChatSendBridge
	roomChatSendBridgeTestReturnValue = true
	roomChatSendBridge = roomChatSendBridgeTestStub
	defer roomChatSendBridge = originalRoomChatSendBridge

	testSetDraft(State_selectedRoomDraft(&state), "should wait for echo")
	State_sendChannelChat(&state)
	testing.expect(
		t,
		len(buildRoomView(&state).lines) == 0,
		"expected submit to keep chat empty until the server echo arrives",
	)

	testApplyRoomChat(&state, server.id, common.GENERAL_ROOM_ID, 77, 1, "self echo")
	afterSelf := buildRoomView(&state)
	testing.expectf(
		t,
		len(afterSelf.lines) == 1,
		"expected authoritative self echo to append one line, got %d",
		len(afterSelf.lines),
	)
	if len(afterSelf.lines) == 1 {
		testing.expect(
			t,
			afterSelf.lines[0].senderLabel == "You",
			"expected self echoes to use the self label",
		)
		testing.expect(t, afterSelf.lines[0].isSelf, "expected self echoes to be marked as self")
		testing.expect(
			t,
			afterSelf.lines[0].content == "self echo",
			"expected self echo content to appear on authoritative receive",
		)
	}

	testApplyRoomChat(&state, server.id, common.GENERAL_ROOM_ID, 42, 2, "other echo")
	afterOther := buildRoomView(&state)
	testing.expectf(
		t,
		len(afterOther.lines) == 2,
		"expected a second authoritative receive to append a second line, got %d",
		len(afterOther.lines),
	)
	if len(afterOther.lines) == 2 {
		testing.expect(
			t,
			afterOther.lines[1].senderLabel == "User 42",
			"expected non-self echoes without a nickname to fall back to the sender ID label",
		)
		testing.expect(
			t,
			!afterOther.lines[1].isSelf,
			"expected non-self echoes to use the standard sender styling",
		)
	}

	testApplyRoomChat(&state, server.id, common.GENERAL_ROOM_ID, 43, 3, "named", "hay-user")
	testApplyRoomChat(&state, server.id, common.GENERAL_ROOM_ID, 77, 4, "self named", "me")
	afterNamed := buildRoomView(&state)
	testing.expectf(
		t,
		len(afterNamed.lines) == 4,
		"expected named receives to append two more lines, got %d",
		len(afterNamed.lines),
	)
	if len(afterNamed.lines) == 4 {
		testing.expectf(
			t,
			afterNamed.lines[2].senderLabel == "hay-user",
			"expected non-self lines to show the sender nickname, got %q",
			afterNamed.lines[2].senderLabel,
		)
		testing.expectf(
			t,
			afterNamed.lines[3].senderLabel == "You",
			"expected self lines to keep the self label over the nickname, got %q",
			afterNamed.lines[3].senderLabel,
		)
	}

	delete(roomChatSendBridgeTestContent)
	roomChatSendBridgeTestContent = ""
}

@(test)
testMismatchedReceiveAndProtocolErrorStayNarrow :: proc(t: ^testing.T) {
	server := Server {
		id         = 504,
		name       = "Narrow Server",
		host       = "localhost",
		port       = common.DEFAULT_SERVER_PORT,
	}
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)

	testApplyRoomChat(&state, server.id + 1, common.GENERAL_ROOM_ID, 42, 1, "wrong server")
	testing.expect(
		t,
		len(buildRoomView(&state).lines) == 0,
		"expected room chat from a different server to stay hidden",
	)

	testApplyRoomChat(&state, server.id, common.GENERAL_ROOM_ID + 1, 42, 2, "wrong room")
	testing.expect(
		t,
		len(buildRoomView(&state).lines) == 0,
		"expected room chat from a different room to stay hidden",
	)
	otherRoom := ServerRoomCache_roomCache(
		State_serverRoomCache(&state, server.id),
		common.GENERAL_ROOM_ID + 1,
	)
	testing.expect(
		t,
		len(otherRoom.messages) == 1 && otherRoom.messages[0].content == "wrong room",
		"expected room chat for an inactive room to land in that room's cache",
	)

	event := ClientTransportRuntimeEvent {
		kind     = .ProtocolError,
		serverID = server.id,
		message  = strings.clone("Unsupported roomId"),
	}
	State_applyRuntimeEvent(&state, &event)
	ClientTransportRuntimeEvent_deinit(&event)

	view := buildRoomView(&state)
	testing.expect(
		t,
		len(view.lines) == 0,
		"expected protocol errors to avoid mutating visible room chat",
	)
	testing.expect(
		t,
		view.status == "Unsupported roomId",
		"expected protocol errors to surface through the chat status",
	)
}

@(test)
testRoomCachesAreScopedByServerAndRoom :: proc(t: ^testing.T) {
	serverA := Server {
		id         = 601,
		name       = "Cache A",
		short_name = "A",
		host       = "localhost",
		port       = 1,
	}
	serverB := Server {
		id         = 602,
		name       = "Cache B",
		short_name = "B",
		host       = "localhost",
		port       = 1,
	}
	state := testStateWithServers({serverA, serverB})
	defer State_deinit(&state)
	state.selected_server_id = serverA.id
	state.selected_transport_index = State_selectedTransportIndexForServerID(state, serverA.id)
	state.selected_channel_id = 10

	testApplyRoomChat(&state, serverA.id, 10, 42, 101, "from A")
	testApplyRoomChat(&state, serverB.id, 10, 43, 101, "from B")

	cacheA := State_serverRoomCache(&state, serverA.id)
	cacheB := State_serverRoomCache(&state, serverB.id)
	roomA := ServerRoomCache_roomCache(cacheA, 10)
	roomB := ServerRoomCache_roomCache(cacheB, 10)
	testing.expect(t, len(roomA.messages) == 1, "expected server A to retain its room message")
	testing.expect(t, len(roomB.messages) == 1, "expected server B to retain its room message")
	testing.expect(t, roomA.messages[0].content == "from A", "expected server A cache isolation")
	testing.expect(t, roomB.messages[0].content == "from B", "expected server B cache isolation")
}

@(test)
testRoomDraftsAreScopedByRoom :: proc(t: ^testing.T) {
	sync.mutex_lock(&roomChatSendBridgeTestMutex)
	defer sync.mutex_unlock(&roomChatSendBridgeTestMutex)

	server := Server {
		id   = 605,
		name = "Drafts",
		host = "localhost",
		port = 1,
	}
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)
	testPrepareRoomSend(&state, server.id, 70)

	otherRoomID := common.GENERAL_ROOM_ID + 1
	State_switchToChannel(&state, server.id, otherRoomID)
	testing.expect(
		t,
		len(State_selectedRoomDraft(&state)) == 0,
		"expected a newly selected room to start with an empty draft",
	)
	testSetDraft(State_selectedRoomDraft(&state), "other room draft")

	State_switchToChannel(&state, server.id, common.GENERAL_ROOM_ID)
	testing.expect(
		t,
		string(State_selectedRoomDraft(&state)[:]) == "pending channel draft",
		"expected switching back to restore the General room draft",
	)

	originalRoomChatSendBridge := roomChatSendBridge
	roomChatSendBridgeTestReturnValue = true
	roomChatSendBridge = roomChatSendBridgeTestStub
	defer roomChatSendBridge = originalRoomChatSendBridge
	State_sendChannelChat(&state)

	State_switchToChannel(&state, server.id, otherRoomID)
	testing.expect(
		t,
		string(State_selectedRoomDraft(&state)[:]) == "other room draft",
		"expected sending in one room to leave other room drafts untouched",
	)

	delete(roomChatSendBridgeTestContent)
	roomChatSendBridgeTestContent = ""
}

@(test)
testRoomHistoryMergesPagesByMessageID :: proc(t: ^testing.T) {
	server := Server {
		id         = 603,
		name       = "History",
		short_name = "H",
		host       = "localhost",
		port       = 1,
	}
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)
	state.selected_channel_id = 12

	firstPage := ClientTransportRuntimeEvent {
		kind     = .RoomHistoryReceived,
		serverID = server.id,
		roomID   = 12,
		hasOlder = true,
	}
	append(
		&firstPage.messages,
		common.StoredChatMessage {
			id = 2,
			senderNickname = strings.clone("page-one"),
			roomId = 12,
			timestamp = strings.clone("t2"),
			content = strings.clone("two"),
		},
	)
	append(
		&firstPage.messages,
		common.StoredChatMessage {
			id = 3,
			roomId = 12,
			timestamp = strings.clone("t3"),
			content = strings.clone("three"),
		},
	)
	State_applyRuntimeEvent(&state, &firstPage)
	ClientTransportRuntimeEvent_deinit(&firstPage)

	olderPage := ClientTransportRuntimeEvent {
		kind     = .RoomHistoryReceived,
		serverID = server.id,
		roomID   = 12,
		hasOlder = false,
	}
	append(
		&olderPage.messages,
		common.StoredChatMessage {
			id = 1,
			roomId = 12,
			timestamp = strings.clone("t1"),
			content = strings.clone("one"),
		},
	)
	append(
		&olderPage.messages,
		common.StoredChatMessage {
			id = 2,
			roomId = 12,
			timestamp = strings.clone("t2"),
			content = strings.clone("two"),
		},
	)
	State_applyRuntimeEvent(&state, &olderPage)
	ClientTransportRuntimeEvent_deinit(&olderPage)

	cache := State_serverRoomCache(&state, server.id)
	room := ServerRoomCache_roomCache(cache, 12)
	testing.expect(t, len(room.messages) == 3, "expected overlapping history pages to deduplicate")
	testing.expect(t, room.messages[0].id == 1, "expected older messages to prepend in ID order")
	testing.expect(t, room.messages[2].id == 3, "expected newest messages to remain after merge")
	testing.expectf(
		t,
		room.messages[1].senderNickname == "page-one",
		"expected the first page's copy of message 2 to keep its nickname, got %q",
		room.messages[1].senderNickname,
	)
	testing.expect(
		t,
		room.oldestMessageID == 1,
		"expected pagination cursor to track oldest loaded message",
	)
	testing.expect(
		t,
		!room.hasOlder,
		"expected latest history response to update pagination state",
	)
}

testRoomListEvent :: proc(serverID: int, roomIDs: ..int) -> ClientTransportRuntimeEvent {
	event := ClientTransportRuntimeEvent {
		kind     = .RoomListReceived,
		serverID = serverID,
	}
	for roomID in roomIDs {
		append(
			&event.rooms,
			common.RoomSummary {
				id = roomID,
				name = fmt.aprintf("Room %d", roomID),
				description = strings.clone(""),
			},
		)
	}
	return event
}

@(test)
testRoomDeletionFallsBackToAnotherJoinedRoom :: proc(t: ^testing.T) {
	server := Server {
		id         = 604,
		name       = "Fallback",
		short_name = "F",
		host       = "localhost",
		port       = 1,
	}
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)

	roomList := testRoomListEvent(server.id, 20, 21)
	State_applyRuntimeEvent(&state, &roomList)
	testing.expect(t, len(roomList.rooms) == 0, "expected the room list to move into State")
	ClientTransportRuntimeEvent_deinit(&roomList)
	state.selected_channel_id = 20

	deleted := ClientTransportRuntimeEvent {
		kind     = .RoomDeleted,
		serverID = server.id,
		roomID   = 20,
	}
	State_applyRuntimeEvent(&state, &deleted)
	ClientTransportRuntimeEvent_deinit(&deleted)

	cache := State_serverRoomCache(&state, server.id)
	testing.expect(
		t,
		state.selected_channel_id == 21,
		"expected selected deletion to choose another joined room",
	)
	testing.expect(
		t,
		!ServerRoomCache_roomIsJoined(cache, 20),
		"expected deleted room to leave room list",
	)
	testing.expect(
		t,
		ServerRoomCache_roomIsJoined(cache, 21),
		"expected remaining joined room to stay available",
	)
}

@(test)
testRoomEditedReplacesJoinedRoomOrLeavesEventOwned :: proc(t: ^testing.T) {
	server := Server {
		id   = 606,
		name = "Edits",
		host = "localhost",
		port = 1,
	}
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)

	roomList := testRoomListEvent(server.id, 30)
	State_applyRuntimeEvent(&state, &roomList)
	ClientTransportRuntimeEvent_deinit(&roomList)

	edited := ClientTransportRuntimeEvent {
		kind = .RoomEdited,
		serverID = server.id,
		roomID = 30,
		room = common.RoomSummary {
			id = 30,
			name = strings.clone("Renamed"),
			description = strings.clone("new"),
		},
	}
	State_applyRuntimeEvent(&state, &edited)
	testing.expect(t, len(edited.room.name) == 0, "expected a matching edit to move the room")
	ClientTransportRuntimeEvent_deinit(&edited)
	cache := State_serverRoomCache(&state, server.id)
	testing.expect(t, cache.rooms[0].name == "Renamed", "expected the joined room to be renamed")

	// An edit for a room we have not joined stays owned by the event, which frees it.
	unknown := ClientTransportRuntimeEvent {
		kind = .RoomEdited,
		serverID = server.id,
		roomID = 99,
		room = common.RoomSummary {
			id = 99,
			name = strings.clone("Unknown"),
			description = strings.clone(""),
		},
	}
	State_applyRuntimeEvent(&state, &unknown)
	testing.expect(t, unknown.room.name == "Unknown", "expected an unmatched edit to stay owned")
	ClientTransportRuntimeEvent_deinit(&unknown)
	testing.expect(t, len(cache.rooms) == 1, "expected an unmatched edit to add no room")
}

@(test)
testRoomViewFollowsSelectedRoomAcrossSwitches :: proc(t: ^testing.T) {
	serverA := Server {
		id         = 506,
		name       = "First Server",
		host       = "localhost",
		port       = common.DEFAULT_SERVER_PORT,
	}
	serverB := Server {
		id         = 507,
		name       = "Second Server",
		host       = "localhost",
		port       = common.DEFAULT_SERVER_PORT,
	}
	state := testStateWithServers({serverA, serverB})
	defer State_deinit(&state)
	state.selected_server_id = serverA.id
	state.selected_transport_index = State_selectedTransportIndexForServerID(state, serverA.id)
	state.selected_channel_id = common.GENERAL_ROOM_ID

	testApplyRoomChat(&state, serverA.id, common.GENERAL_ROOM_ID, 42, 1, "persisted room text")
	testing.expect(
		t,
		len(buildRoomView(&state).lines) == 1,
		"expected authoritative receive to show in the selected room",
	)

	State_switchToChannel(&state, serverA.id, common.GENERAL_ROOM_ID + 1)
	testing.expect(
		t,
		len(buildRoomView(&state).lines) == 0,
		"expected switching channels to show only the new room's messages",
	)

	State_switchToChannel(&state, serverA.id, common.GENERAL_ROOM_ID)
	testing.expect(
		t,
		len(buildRoomView(&state).lines) == 1,
		"expected switching back to restore the room's cached messages",
	)

	State_switchToServer(&state, serverB.id)
	testing.expect(
		t,
		len(buildRoomView(&state).lines) == 0,
		"expected switching servers to hide the previous server's room messages",
	)
}

@(test)
testRoomViewExposesChatStatus :: proc(t: ^testing.T) {
	server := Server {
		id         = 505,
		name       = "Room View Server",
		host       = "localhost",
		port       = common.DEFAULT_SERVER_PORT,
	}
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)
	State_setChatStatus(&state, "Unsupported roomId")

	testing.expect(
		t,
		buildRoomView(&state).status == "Unsupported roomId",
		"expected the room view to expose the current chat status message",
	)
}

@(test)
testClientServerTransportBuildsEncryptedRoomChatPacketBytes :: proc(t: ^testing.T) {
	server := Server {
		id         = 77,
		name       = "Room Server",
		host       = "localhost",
		port       = common.DEFAULT_SERVER_PORT,
	}
	config := testConfigWithServers({server})
	defer Config_deinit(&config)

	transport, serverTransport, ok := buildEstablishedTransportPair(server, config)
	assert(ok, "expected transport pair setup to succeed")
	defer ClientServerTransport_deinit(&transport)

	clientMessageID := common.ClientMessageID{0 = 5}
	signature := common.SignatureBytes{0 = 1, 63 = 2}
	packetBytes, packetOK := ClientServerTransport_buildRoomChatPacketBytes(
		&transport,
		RoomChatSend {
			roomID = common.GENERAL_ROOM_ID,
			content = "hello haychat",
			clientMessageID = clientMessageID,
			signature = signature,
		},
	)
	assert(packetOK, "expected established transport to build room chat packet bytes")
	defer delete(packetBytes)

	outerPacket: common.Packet
	outerPacketErr := cbor.unmarshal(packetBytes, &outerPacket)
	assert(outerPacketErr == nil, "expected room chat packet bytes to decode as Packet")
	defer delete(outerPacket.payload)
	assert(
		outerPacket.messageType == .EncryptedPacket,
		"expected room chat packet bytes to use encrypted packet transport",
	)

	innerPacket, openOK := common.openPacketForSession(&serverTransport, outerPacket)
	assert(openOK, "expected server transport to decrypt room chat packet")
	defer delete(innerPacket.payload)
	assert(
		innerPacket.messageType == .ClientChatMessage,
		"expected room chat packet to carry ClientChatMessage payload",
	)

	chatPayload: common.ClientChatMessagePayload
	chatPayloadErr := cbor.unmarshal(innerPacket.payload, &chatPayload)
	assert(chatPayloadErr == nil, "expected room chat payload decode to succeed")
	defer common.ClientChatMessagePayload_deinit(&chatPayload)
	assert(
		chatPayload.roomId == common.GENERAL_ROOM_ID,
		"expected room chat payload roomId to match the shared room contract",
	)
	assert(
		chatPayload.content == "hello haychat",
		"expected room chat payload content to remain intact",
	)
	assert(
		chatPayload.clientMessageId == clientMessageID && chatPayload.signature == signature,
		"expected the client message ID and signature carried (protocol 22)",
	)

	_ = t
}

@(test)
testClientServerTransportTranslatesEncryptedServerChatIntoRuntimeEvent :: proc(t: ^testing.T) {
	server := Server {
		id         = 88,
		name       = "Runtime Server",
		host       = "localhost",
		port       = common.DEFAULT_SERVER_PORT,
	}
	config := testConfigWithServers({server})
	defer Config_deinit(&config)

	transport, serverTransport, ok := buildEstablishedTransportPair(server, config)
	assert(ok, "expected transport pair setup to succeed")
	defer ClientServerTransport_deinit(&transport)

	sealedPacket, sealOK := common.sealPacketForSession(
		&serverTransport,
		.ServerChatMessage,
		common.ServerChatMessagePayload {
			senderId = 42,
			senderNickname = "hay-user",
			roomId = common.GENERAL_ROOM_ID,
			content = "authoritative chat",
		},
	)
	assert(sealOK, "expected server transport to seal room chat packet")
	defer delete(sealedPacket.payload)

	sealedPacketBytes, sealedPacketBytesOK := common.marshalPacket(sealedPacket)
	assert(sealedPacketBytesOK, "expected sealed room chat packet bytes to marshal")
	defer delete(sealedPacketBytes)

	runtimeEvent, eventOK := ClientServerTransport_handleRuntimePacketBytes(
		&transport,
		sealedPacketBytes,
	)
	assert(eventOK, "expected runtime packet handler to surface room chat event")
	defer ClientTransportRuntimeEvent_deinit(&runtimeEvent)
	assert(
		runtimeEvent.kind == .RoomChatReceived,
		"expected runtime packet handler to classify room chat events",
	)
	assert(
		runtimeEvent.serverID == server.id,
		"expected room chat event to include the selected server ID",
	)
	assert(
		runtimeEvent.roomID == common.GENERAL_ROOM_ID,
		"expected room chat event to preserve roomId metadata",
	)
	assert(runtimeEvent.senderID == 42, "expected room chat event to preserve senderId metadata")
	assert(
		runtimeEvent.senderNickname == "hay-user",
		"expected room chat event to carry the sender nickname",
	)
	assert(
		runtimeEvent.message == "authoritative chat",
		"expected room chat event to preserve chat content",
	)

	_ = t
}

// Seals one server control message for the client and runs it through the runtime packet
// handler. The caller owns the returned event.
testDeliverServerControl :: proc(
	transport: ^ClientServerTransport,
	serverTransport: ^common.TransportState,
	messageType: common.MessageType,
	payload: any,
) -> ClientTransportRuntimeEvent {
	sealedPacket, sealOK := common.sealPacketForSession(serverTransport, messageType, payload)
	assert(sealOK, fmt.tprintf("expected the server to seal %v", messageType))
	defer delete(sealedPacket.payload)
	sealedPacketBytes, bytesOK := common.marshalPacket(sealedPacket)
	assert(bytesOK, "expected the sealed control packet to marshal")
	defer delete(sealedPacketBytes)

	runtimeEvent, eventOK := ClientServerTransport_handleRuntimePacketBytes(
		transport,
		sealedPacketBytes,
	)
	assert(eventOK, fmt.tprintf("expected the packet handler to report %v", messageType))
	return runtimeEvent
}

// The three voice control messages become runtime events that own their payloads; the leak
// checker covers the nicknames and reasons through ClientTransportRuntimeEvent_deinit. A
// malformed participant list is a ProtocolError that keeps the session.
@(test)
testClientServerTransportDecodesVoiceControlIntoRuntimeEvents :: proc(t: ^testing.T) {
	server := Server {
		id   = 77,
		name = "Voice Server",
		host = "localhost",
		port = common.DEFAULT_SERVER_PORT,
	}
	config := testConfigWithServers({server})
	defer Config_deinit(&config)

	transport, serverTransport, ok := buildEstablishedTransportPair(server, config)
	assert(ok, "expected transport pair setup to succeed")
	defer ClientServerTransport_deinit(&transport)

	participants := make([dynamic]common.VoiceParticipant, context.temp_allocator)
	append(&participants, common.VoiceParticipant{userId = 3, nickname = "alice", muted = true})
	append(&participants, common.VoiceParticipant{userId = 4, nickname = "bob", deafened = true})
	event := testDeliverServerControl(
		&transport,
		&serverTransport,
		.ServerVoiceParticipants,
		common.ServerVoiceParticipantsPayload{roomId = 5, participants = participants},
	)
	testing.expectf(
		t,
		event.kind == .VoiceParticipants && event.serverID == 77 && event.roomID == 5,
		"expected VoiceParticipants for server 77 room 5, got %v %d %d",
		event.kind,
		event.serverID,
		event.roomID,
	)
	testing.expect(
		t,
		len(event.voiceParticipants) == 2 &&
		event.voiceParticipants[0].userId == 3 &&
		event.voiceParticipants[0].nickname == "alice" &&
		event.voiceParticipants[0].muted &&
		event.voiceParticipants[1].nickname == "bob" &&
		event.voiceParticipants[1].deafened,
		"expected both participants with their nicknames and flags",
	)
	ClientTransportRuntimeEvent_deinit(&event)

	event = testDeliverServerControl(
		&transport,
		&serverTransport,
		.ServerVoiceJoinRejected,
		common.ServerVoiceJoinRejectedPayload{roomId = 5, reason = "voice room is full"},
	)
	testing.expectf(
		t,
		event.kind == .VoiceJoinRejected &&
		event.roomID == 5 &&
		event.message == "voice room is full",
		"expected VoiceJoinRejected with the reason, got %v %d %q",
		event.kind,
		event.roomID,
		event.message,
	)
	ClientTransportRuntimeEvent_deinit(&event)

	event = testDeliverServerControl(
		&transport,
		&serverTransport,
		.ServerVoiceLeft,
		common.ServerVoiceLeftPayload{roomId = 5, reason = "the room was deleted"},
	)
	testing.expectf(
		t,
		event.kind == .VoiceLeft && event.roomID == 5 && event.message == "the room was deleted",
		"expected VoiceLeft with the reason, got %v %d %q",
		event.kind,
		event.roomID,
		event.message,
	)
	ClientTransportRuntimeEvent_deinit(&event)

	// Room 0 is never a voice room: the decoded participants are freed and reported.
	event = testDeliverServerControl(
		&transport,
		&serverTransport,
		.ServerVoiceParticipants,
		common.ServerVoiceParticipantsPayload{roomId = 0, participants = participants},
	)
	testing.expectf(
		t,
		event.kind == .ProtocolError && len(event.voiceParticipants) == 0,
		"expected an invalid participant list to be a protocol error, got %v",
		event.kind,
	)
	ClientTransportRuntimeEvent_deinit(&event)
	testing.expect(
		t,
		transport.transport.phase == .Established,
		"expected voice control messages never to end the session",
	)
}

@(test)
testClientServerTransportTranslatesProtocolErrorIntoRuntimeEvent :: proc(t: ^testing.T) {
	server := Server {
		id         = 99,
		name       = "Protocol Server",
		host       = "localhost",
		port       = common.DEFAULT_SERVER_PORT,
	}
	config := testConfigWithServers({server})
	defer Config_deinit(&config)

	transport, _, ok := buildEstablishedTransportPair(server, config)
	assert(ok, "expected transport pair setup to succeed")
	defer ClientServerTransport_deinit(&transport)

	packetBytes, packetOK := common.buildPacketBytes(
		.ServerProtocolError,
		common.ProtocolErrorResponse{message = "Unsupported roomId"},
	)
	assert(packetOK, "expected protocol error packet encoding to succeed")
	defer delete(packetBytes)

	runtimeEvent, eventOK := ClientServerTransport_handleRuntimePacketBytes(
		&transport,
		packetBytes,
	)
	assert(eventOK, "expected runtime packet handler to surface protocol error events")
	defer ClientTransportRuntimeEvent_deinit(&runtimeEvent)
	assert(
		runtimeEvent.kind == .ProtocolError,
		"expected runtime packet handler to classify protocol errors",
	)
	assert(
		runtimeEvent.serverID == server.id,
		"expected protocol error event to include the selected server ID",
	)
	assert(
		runtimeEvent.message == "Unsupported roomId",
		"expected protocol error event to preserve the server error message",
	)
	assert(
		transport.transport.phase == .Established,
		"expected protocol error handling to preserve the authenticated transport",
	)
	assert(
		common.TransportState_canEncrypt(&transport.transport),
		"expected protocol error handling to keep the authenticated session usable",
	)
	assert(
		transport.authenticatedUserID == 77,
		"expected protocol error handling to preserve the authenticated user identity",
	)

	_ = t
}

// Rewritten from testStateInitFromConfigAttemptsOnlySelectedDefaultServer: startup no longer
// begins a handshake synchronously. Every server is queued for the network worker instead.
@(test)
testStateInitFromConfigQueuesEveryServerToConnect :: proc(t: ^testing.T) {
	config := testConfigWithServers(
		{
			Server {
				id = 11,
				name = "Alpha Server",
				host = "localhost",
				port = common.DEFAULT_SERVER_PORT,
			},
			Server {
				id = 22,
				name = "Bravo Server",
				host = "localhost",
				port = common.DEFAULT_SERVER_PORT + 1,
			},
		},
	)
	defer Config_deinit(&config)
	state := State_initFromConfig(config)
	defer State_deinit(&state)

	testing.expect(t, state.selected_server_id == 11, "expected the first server to be selected")
	testing.expect(
		t,
		state.selected_transport_index == 0,
		"expected selected transport index to point at the selected server",
	)
	testing.expect(t, len(state.serverTransports) == 2, "expected a transport entry per server")
	testing.expect(t, !state.settingsOpen, "expected a complete config to skip first-run setup")
	for index in 0 ..< len(state.serverTransports) {
		transport := &state.serverTransports[index]
		testing.expectf(
			t,
			transport.connection.status == .Disconnected &&
			transport.connection.nextAttemptAt == {},
			"expected server %d to be queued for an immediate attempt, got %v",
			transport.serverID,
			transport.connection.status,
		)
		testing.expect(
			t,
			!ClientServerTransport_hasLiveENetSession(transport),
			"expected no network I/O before the worker starts",
		)
		testing.expect(t, len(transport.lastError) == 0, "expected no error before connecting")
		testing.expect(
			t,
			State_serverConnection(&state, transport.serverID).status == .Connecting,
			"expected the UI to show every queued server as connecting",
		)
	}
}

// Feeds a server handshake through the transport the way the worker does, using a fresh
// server identity. Returns that identity's public key.
testRunHandshake :: proc(
	transport: ^ClientServerTransport,
	serverIdentityPrivateKey: common.IdentityPrivateKeyBytes,
	serverIdentityPublicKey: common.IdentityPublicKeyBytes,
	userID: int,
) -> bool {
	helloBytes, helloOK := ClientServerTransport_beginHandshake(transport)
	delete(helloBytes)
	if !helloOK {
		return false
	}
	_, serverEphemeralPublicKey, ephemeralOK := common.generateKeyExchangeKeyPair()
	assert(ephemeralOK, "expected server ephemeral key generation to succeed")
	sessionID, sessionIDOK := common.generateSessionID()
	assert(sessionIDOK, "expected session ID generation to succeed")

	serverHelloBytes, serverHelloOK := buildServerHelloPacketBytes(
		transport,
		serverIdentityPrivateKey,
		serverIdentityPublicKey,
		serverEphemeralPublicKey,
		sessionID,
	)
	assert(serverHelloOK, "expected ServerHello packet encoding to succeed")
	defer delete(serverHelloBytes)
	if _, ok := ClientServerTransport_handleIncomingPacket(transport, serverHelloBytes); !ok {
		return false
	}

	authChallenge, authChallengeOK := common.generateAuthChallenge()
	assert(authChallengeOK, "expected auth challenge generation to succeed")
	challengeBytes, challengeBytesOK := common.buildPacketBytes(
		.ServerAuthChallenge,
		common.ServerAuthChallengePayload {
			sessionID = transport.sessionID,
			challenge = authChallenge,
		},
	)
	assert(challengeBytesOK, "expected auth challenge packet encoding to succeed")
	defer delete(challengeBytes)
	challengeResult, challengeOK := ClientServerTransport_handleIncomingPacket(
		transport,
		challengeBytes,
	)
	if challengeResult.hasResponse {
		delete(challengeResult.responsePacketBytes)
	}
	if !challengeOK || !challengeResult.hasResponse {
		return false
	}

	successBytes, successBytesOK := common.buildPacketBytes(
		.ServerAuthSuccess,
		common.ServerAuthSuccessPayload{userId = userID, message = "ok"},
	)
	assert(successBytesOK, "expected auth success packet encoding to succeed")
	defer delete(successBytes)
	_, successOK := ClientServerTransport_handleIncomingPacket(transport, successBytes)
	return successOK
}

// Rewritten from testStateInitFromConfigCanEstablishSelectedTransportViaStartupBridge: the
// handshake packets now go straight to the transport, as the worker feeds them.
@(test)
testHandshakePacketsEstablishTransportAndPinServerKeyOnFirstUse :: proc(t: ^testing.T) {
	server := Server {
		id   = 44,
		name = "Handshake Server",
		host = "localhost",
		port = common.DEFAULT_SERVER_PORT,
	}
	config := testConfigWithServers({server})
	defer Config_deinit(&config)
	transport, message, ok := ClientServerTransport_init(config.servers[0], config)
	assert(ok, message)
	defer ClientServerTransport_deinit(&transport)

	serverPrivateKey, serverPublicKey, identityOK := common.generateIdentityKeyPair()
	assert(identityOK, "expected server identity key generation to succeed")
	testing.expect(
		t,
		testRunHandshake(&transport, serverPrivateKey, serverPublicKey, 77),
		"expected the handshake to succeed",
	)
	testing.expect(
		t,
		transport.transport.phase == .Established,
		"expected the handshake to establish the transport",
	)
	testing.expect(t, transport.authenticatedUserID == 77, "expected the server's user ID")
	expectedKey := common.identityPublicKeyToHex(serverPublicKey)
	defer delete(expectedKey)
	testing.expect(
		t,
		transport.pinnedServerPublicKey == expectedKey && transport.connection.newlyPinned,
		"expected an unpinned server's key to be pinned on first use",
	)
}

@(test)
testAuthFailureThenDisconnectClearsPendingAuthState :: proc(t: ^testing.T) {
	server := Server {
		id   = 55,
		name = "Rejecting Server",
		host = "localhost",
		port = common.DEFAULT_SERVER_PORT,
	}
	config := testConfigWithServers({server})
	defer Config_deinit(&config)
	transport, message, ok := ClientServerTransport_init(config.servers[0], config)
	assert(ok, message)
	defer ClientServerTransport_deinit(&transport)

	helloBytes, helloOK := ClientServerTransport_beginHandshake(&transport)
	assert(helloOK, "expected ClientHello encoding to succeed")
	delete(helloBytes)
	serverPrivateKey, serverPublicKey, identityOK := common.generateIdentityKeyPair()
	assert(identityOK, "expected server identity key generation to succeed")
	_, serverEphemeralPublicKey, ephemeralOK := common.generateKeyExchangeKeyPair()
	assert(ephemeralOK, "expected server ephemeral key generation to succeed")
	sessionID, sessionIDOK := common.generateSessionID()
	assert(sessionIDOK, "expected session ID generation to succeed")
	serverHelloBytes, serverHelloOK := buildServerHelloPacketBytes(
		&transport,
		serverPrivateKey,
		serverPublicKey,
		serverEphemeralPublicKey,
		sessionID,
	)
	assert(serverHelloOK, "expected ServerHello packet encoding to succeed")
	defer delete(serverHelloBytes)
	_, serverHelloHandled := ClientServerTransport_handleIncomingPacket(
		&transport,
		serverHelloBytes,
	)
	assert(serverHelloHandled, "expected the transport to accept ServerHello")

	authFailureBytes, authFailureBytesOK := common.buildPacketBytes(
		.ServerAuthFailure,
		common.ServerAuthFailurePayload{message = "invalid client auth signature"},
	)
	assert(authFailureBytesOK, "expected auth failure packet encoding to succeed")
	defer delete(authFailureBytes)
	_, authFailureHandled := ClientServerTransport_handleIncomingPacket(
		&transport,
		authFailureBytes,
	)
	testing.expect(t, !authFailureHandled, "expected auth failure to fail the transport")
	ClientServerTransport_handleDisconnect(&transport)

	testing.expect(
		t,
		transport.transport.phase == .Failed,
		"expected transport to remain failed after disconnect",
	)
	testing.expect(t, !transport.pendingKeysReady, "expected pending auth keys to be cleared")
	testing.expect(
		t,
		!common.TransportState_canEncrypt(&transport.transport),
		"expected transport to stay non-established",
	)
	testing.expect(
		t,
		transport.authenticatedUserID == 0,
		"expected authenticated user ID to be cleared",
	)
	testing.expect(
		t,
		transport.sessionID == common.SessionID{},
		"expected session ID to be cleared",
	)
	testing.expect(
		t,
		transport.lastError == "invalid client auth signature",
		"expected auth failure message to remain visible after disconnect cleanup",
	)
}

@(test)
testStateInitFromConfigSurfacesSelectedTransportInitFailure :: proc(t: ^testing.T) {
	config := Config {
		private_key  = "invalid-private-key",
		public_key   = "invalid-public-key",
		display_name = "Tester",
		servers      = {
			Server {
				id = 33,
				name = "Broken Server",
				host = "localhost",
				port = common.DEFAULT_SERVER_PORT,
			},
		},
	}
	defer delete(config.servers)

	state := State_initFromConfig(config)
	defer State_deinit(&state)

	testing.expect(
		t,
		len(state.serverTransports) == 1,
		"expected selected server failure to stay visible",
	)
	testing.expect(
		t,
		state.selected_transport_index == 0,
		"expected the failed selected server to keep a transport slot",
	)
	testing.expect(
		t,
		state.serverTransports[0].transport.phase == .Failed &&
		state.serverTransports[0].connection.status == .Failed,
		"expected selected/default transport init failures to surface as failed state",
	)
	testing.expect(
		t,
		state.serverTransports[0].lastError == CLIENT_INVALID_IDENTITY_MESSAGE,
		"expected selected/default transport init failures to keep a visible error message",
	)
	connection := State_serverConnection(&state, 33)
	testing.expect(
		t,
		connection.status == .Failed && connection.failureKind == .InvalidIdentity,
		"expected the UI to show the identity failure without retrying",
	)
}

// The server binds a nickname to the first identity key it sees, and live tests generate a
// fresh key every run, so each run needs nicknames the database has not seen before.
liveTestUniqueNickname :: proc(prefix: string) -> string {
	return fmt.aprintf("%s-%x", prefix, time.time_to_unix_nano(time.now()))
}

// Live proofs. They run the real connect flow: State_initFromConfig queues the server, the
// network worker connects and signs in, and the test pumps events like the frame loop.

@(test)
testClientServerTransportCanEstablishLiveStartupAuthOverENet :: proc(t: ^testing.T) {
	if os.get_env("HAYCHAT_LIVE_STARTUP_AUTH", context.temp_allocator) != "1" {
		return
	}

	config := testConfigWithServers(
		{Server{id = 66, name = "Live Server", host = "127.0.0.1", port = 12345}},
	)
	defer Config_deinit(&config)
	delete(config.display_name)
	config.display_name = liveTestUniqueNickname("live")

	state := State_initFromConfig(config)
	defer State_deinit(&state)
	if !liveTestConnect(t, &state, "the live client") {
		return
	}
	connection := State_serverConnection(&state, 66)
	testing.expectf(
		t,
		connection.nickname == config.display_name,
		"expected the connection to report nickname %q, got %q",
		config.display_name,
		connection.nickname,
	)
	testing.expect(
		t,
		len(state.config.servers[0].pinned_server_public_key) > 0,
		"expected the first connect to pin the server's identity key",
	)

	// Connected requested the room list; the worker must deliver the server's reply.
	roomList, roomListReceived := liveTestWaitForEvent(&state, .RoomListReceived, 3 * time.Second)
	defer if roomListReceived do ClientTransportRuntimeEvent_deinit(&roomList)
	testing.expect(
		t,
		roomListReceived,
		"expected the network worker to deliver the room list from a live server",
	)

	ClientNetworkWorker_lock(state.networkWorker)
	transport := &state.serverTransports[0]
	postAuthProbeSent :=
		ClientServerTransport_isConnected(transport) &&
		ClientServerTransport_sendENetPacket(
			transport.enetHost,
			transport.enetPeer,
			STARTUP_AUTH_CHANNEL_CHAT,
			{0x01},
		)
	ClientNetworkWorker_unlock(state.networkWorker)
	testing.expect(
		t,
		postAuthProbeSent,
		"expected the established session to allow a post-auth outbound send",
	)
}

@(test)
testClientServerTransportCanSendLiveRoomChatBetweenTwoAuthenticatedClients :: proc(t: ^testing.T) {
	if os.get_env("HAYCHAT_LIVE_STARTUP_AUTH", context.temp_allocator) != "1" {
		return
	}

	liveServer := Server {
		id   = 67,
		name = "Live Chat Server",
		host = "127.0.0.1",
		port = 12345,
	}
	configA := testConfigWithServers({liveServer})
	defer Config_deinit(&configA)
	configB := testConfigWithServers({liveServer})
	defer Config_deinit(&configB)
	delete(configA.display_name)
	configA.display_name = liveTestUniqueNickname("live-a")
	delete(configB.display_name)
	configB.display_name = liveTestUniqueNickname("live-b")

	stateA := State_initFromConfig(configA)
	defer State_deinit(&stateA)
	stateB := State_initFromConfig(configB)
	defer State_deinit(&stateB)
	if !liveTestConnect(t, &stateA, "client A") || !liveTestConnect(t, &stateB, "client B") {
		return
	}
	senderUserID := State_selfUserID(&stateA, liveServer.id)

	messageContent := "live two-client room chat proof"
	// Signed by A (protocol 22): the server refuses unsigned room messages.
	send, signError := State_signRoomChat(
		&stateA,
		liveServer.id,
		common.GENERAL_ROOM_ID,
		messageContent,
	)
	testing.expectf(t, len(signError) == 0, "expected client A to sign: %q", signError)
	ClientNetworkWorker_lock(stateA.networkWorker)
	sendOK := ClientServerTransport_sendRoomChatMessage(&stateA.serverTransports[0], send)
	sendError := strings.clone(stateA.serverTransports[0].lastError, context.temp_allocator)
	ClientNetworkWorker_unlock(stateA.networkWorker)
	testing.expectf(t, sendOK, "expected client A to send a live room chat message: %q", sendError)

	// Room lists and other events reach B first; liveTestWaitForEvent applies and skips them.
	runtimeEvent, hasEvent := liveTestWaitForEvent(&stateB, .RoomChatReceived, 3 * time.Second)
	defer if hasEvent do ClientTransportRuntimeEvent_deinit(&runtimeEvent)
	testing.expectf(
		t,
		hasEvent,
		"expected client B to receive a live room chat message before timeout, got %s",
		liveTestConnectionStatus(&stateB, liveServer.id),
	)
	if !hasEvent {
		return
	}
	testing.expectf(
		t,
		runtimeEvent.roomID == common.GENERAL_ROOM_ID,
		"expected client B runtime event to preserve the General room ID, got %v",
		runtimeEvent.roomID,
	)
	testing.expectf(
		t,
		runtimeEvent.senderID == senderUserID,
		"expected the sender to be client A (user %v), got %v",
		senderUserID,
		runtimeEvent.senderID,
	)
	testing.expectf(
		t,
		runtimeEvent.senderNickname == configA.display_name,
		"expected client B runtime event to name the sender %q, got %q",
		configA.display_name,
		runtimeEvent.senderNickname,
	)
	testing.expectf(
		t,
		runtimeEvent.message == messageContent,
		"expected client B runtime event to preserve chat content %q, got %q",
		messageContent,
		runtimeEvent.message,
	)

	// History must label the stored message with the same nickname as the live fan-out. A
	// history page requested at connect time may still be in flight, so skip pages without
	// the message.
	ClientNetworkWorker_lock(stateB.networkWorker)
	historyOK := ClientServerTransport_requestRoomHistory(
		&stateB.serverTransports[0],
		common.GENERAL_ROOM_ID,
		0,
		50,
	)
	ClientNetworkWorker_unlock(stateB.networkWorker)
	testing.expect(t, historyOK, "expected client B to request General room history")
	foundInHistory := false
	historyDeadline := time.tick_now()
	for !foundInHistory && time.tick_since(historyDeadline) < 3 * time.Second {
		historyEvent, hasHistory := liveTestWaitForEvent(
			&stateB,
			.RoomHistoryReceived,
			3 * time.Second - time.tick_since(historyDeadline),
		)
		if !hasHistory {
			break
		}
		for message in historyEvent.messages {
			if message.id == runtimeEvent.messageID {
				foundInHistory = true
				testing.expectf(
					t,
					message.senderNickname == configA.display_name,
					"expected history to name the sender %q, got %q",
					configA.display_name,
					message.senderNickname,
				)
			}
		}
		ClientTransportRuntimeEvent_deinit(&historyEvent)
	}
	testing.expectf(
		t,
		foundInHistory,
		"expected General room history to contain message %d",
		runtimeEvent.messageID,
	)
}

// Waits for an event of `kind` that `matches` accepts, applying every other event (including
// non-matching ones of the same kind) the way the frame loop does. The returned event is
// unapplied and owned by the caller.
liveTestWaitForMatchingEvent :: proc(
	state: ^State,
	kind: ClientTransportRuntimeEventKind,
	timeout: time.Duration,
	matches: proc(event: ^ClientTransportRuntimeEvent, wanted: int) -> bool,
	wanted: int,
) -> (
	ClientTransportRuntimeEvent,
	bool,
) {
	start := time.tick_now()
	for time.tick_since(start) < timeout {
		event, ok := liveTestWaitForEvent(state, kind, timeout - time.tick_since(start))
		if !ok {
			break
		}
		if matches(&event, wanted) {
			return event, true
		}
		State_applyRuntimeEvent(state, &event)
		ClientTransportRuntimeEvent_deinit(&event)
	}
	return {}, false
}

@(test)
testClientServerTransportCanExchangeLiveDirectMessagesBetweenTwoClients :: proc(t: ^testing.T) {
	if os.get_env("HAYCHAT_LIVE_STARTUP_AUTH", context.temp_allocator) != "1" {
		return
	}
	sync.mutex_lock(&directMessageSendBridgeTestMutex)
	defer sync.mutex_unlock(&directMessageSendBridgeTestMutex)

	liveServer := Server {
		id   = 68,
		name = "Live DM Server",
		host = "127.0.0.1",
		port = 12345,
	}
	configA := testConfigWithServers({liveServer})
	defer Config_deinit(&configA)
	configB := testConfigWithServers({liveServer})
	defer Config_deinit(&configB)
	delete(configA.display_name)
	configA.display_name = liveTestUniqueNickname("live-dm-a")
	delete(configB.display_name)
	configB.display_name = liveTestUniqueNickname("live-dm-b")

	stateA := State_initFromConfig(configA)
	defer State_deinit(&stateA)
	stateB := State_initFromConfig(configB)
	defer State_deinit(&stateB)
	if !liveTestConnect(t, &stateA, "client A") || !liveTestConnect(t, &stateB, "client B") {
		return
	}
	serverID := liveServer.id
	userA := State_selfUserID(&stateA, serverID)
	userB := State_selfUserID(&stateB, serverID)

	// B's first session going online is announced to A.
	presenceFor :: proc(event: ^ClientTransportRuntimeEvent, userID: int) -> bool {
		return event.user.id == userID
	}
	presence, hasPresence := liveTestWaitForMatchingEvent(
		&stateA,
		.UserPresenceChanged,
		3 * time.Second,
		presenceFor,
		userB,
	)
	testing.expectf(t, hasPresence, "expected client A to see user %d come online", userB)
	if !hasPresence {
		return
	}
	testing.expectf(
		t,
		presence.user.isOnline && presence.user.nickname == configB.display_name,
		"expected an online presence for %q, got %v",
		configB.display_name,
		presence.user,
	)
	State_applyRuntimeEvent(&stateA, &presence)
	ClientTransportRuntimeEvent_deinit(&presence)

	// A sends through the same actions as the GUI composer. Protocol 17: B's key is fetched
	// first (the message waits for it), then the message goes out encrypted.
	content := "live two-client direct message proof"
	State_openDirectConversation(&stateA, serverID, userB)
	testSetDraft(State_selectedDirectDraft(&stateA), content)
	State_sendDirectMessage(&stateA)
	testing.expectf(
		t,
		len(State_selectedDirectDraft(&stateA)) == 0,
		"expected the accepted send to clear A's draft, status %q",
		stateA.chat_status_message,
	)
	// A may fetch other accounts' keys too (the senders of #general's history, protocol 22).
	for attempt := 0;
	    attempt < 8 && len(testDirectCache(&stateA, serverID, userB).queued) > 0;
	    attempt += 1 {
		keys, hasKeys := liveTestWaitForEvent(&stateA, .UserKeysReceived, 3 * time.Second)
		testing.expect(t, hasKeys, "expected client A to get B's key")
		if !hasKeys {
			return
		}
		State_applyRuntimeEvent(&stateA, &keys)
		ClientTransportRuntimeEvent_deinit(&keys)
	}
	testing.expectf(
		t,
		len(testDirectCache(&stateA, serverID, userB).queued) == 0,
		"expected A's message to go out once B's key arrived, status %q",
		stateA.chat_status_message,
	)

	encryptedFrom :: proc(event: ^ClientTransportRuntimeEvent, senderID: int) -> bool {
		return event.directMessage.senderId == senderID && len(event.directMessage.envelope) > 0
	}
	received, hasReceived := liveTestWaitForMatchingEvent(
		&stateB,
		.DirectMessageReceived,
		3 * time.Second,
		encryptedFrom,
		userA,
	)
	testing.expectf(
		t,
		hasReceived,
		"expected client B to receive the encrypted direct message, got %s",
		liveTestConnectionStatus(&stateB, serverID),
	)
	if !hasReceived {
		return
	}
	messageID := received.directMessage.id
	testing.expectf(
		t,
		received.directMessage.senderId == userA &&
		received.directMessage.recipientId == userB &&
		received.directMessage.senderNickname == configA.display_name &&
		received.directMessage.recipientNickname == configB.display_name &&
		received.directMessage.content == "" &&
		messageID > 0,
		"expected the message from %d (%q) to %d (%q), got %v",
		userA,
		configA.display_name,
		userB,
		configB.display_name,
		received.directMessage,
	)
	State_applyRuntimeEvent(&stateB, &received)
	ClientTransportRuntimeEvent_deinit(&received)
	// B has not pinned A yet: the message waits for A's key, then opens. B may fetch other
	// accounts' keys too (the senders of #general's history, protocol 22), so it applies key
	// answers until A's message is settled.
	for attempt := 0; attempt < 8; attempt += 1 {
		conversationB := testDirectCache(&stateB, serverID, userA)
		entry := DirectConversationCache_entry(conversationB, messageID)
		if entry == nil || entry.security.protection != .Pending {
			break
		}
		keys, hasKeys := liveTestWaitForEvent(&stateB, .UserKeysReceived, 3 * time.Second)
		testing.expect(t, hasKeys, "expected client B to get A's key")
		if !hasKeys {
			return
		}
		State_applyRuntimeEvent(&stateB, &keys)
		ClientTransportRuntimeEvent_deinit(&keys)
	}
	conversationB := testDirectCache(&stateB, serverID, userA)
	openedB := DirectConversationCache_entry(conversationB, messageID)
	testing.expectf(
		t,
		openedB != nil && openedB.security.protection == .Encrypted && openedB.content == content,
		"expected B to open A's message, got %v",
		openedB,
	)
	cacheB := State_serverDirectCache(&stateB, serverID)
	testing.expect(
		t,
		len(cacheB.conversations) > 0 && cacheB.conversations[0].peerUserId == userA,
		"expected A's conversation at the top of B's list",
	)
	testing.expect(
		t,
		len(conversationB.messages) == 1 &&
		len(cacheB.conversations) > 0 &&
		cacheB.conversations[0].unreadCount == 1,
		"expected B's conversation with A to hold the message as unread",
	)

	// The sender sees its own message only through the server's echo, and opens it with its
	// own wrap.
	echo, hasEcho := liveTestWaitForMatchingEvent(
		&stateA,
		.DirectMessageReceived,
		3 * time.Second,
		encryptedFrom,
		userA,
	)
	testing.expect(t, hasEcho, "expected client A to receive the echo of its own message")
	if hasEcho {
		testing.expect(t, echo.directMessage.id == messageID, "expected the echo's ID to match")
		State_applyRuntimeEvent(&stateA, &echo)
		ClientTransportRuntimeEvent_deinit(&echo)
		conversationA := testDirectCache(&stateA, serverID, userB)
		summaryA := State_directSummary(&stateA, serverID, userB)
		openedA := DirectConversationCache_entry(conversationA, messageID)
		testing.expect(
			t,
			len(conversationA.messages) == 1 && summaryA != nil && summaryA.unreadCount == 0,
			"expected A's own message never to count as unread",
		)
		testing.expectf(
			t,
			openedA != nil && openedA.security.protection == .Encrypted && openedA.content == content,
			"expected A to open its own message, got %v",
			openedA,
		)
	}

	// History pages include the stored message.
	historyHas :: proc(event: ^ClientTransportRuntimeEvent, messageID: int) -> bool {
		for message in event.directMessages {
			if message.id == messageID {
				return true
			}
		}
		return false
	}
	testDirectCache(&stateB, serverID, userA).isLoadingHistory = false
	State_requestDirectHistory(&stateB, serverID, userA, 0)
	history, hasHistory := liveTestWaitForMatchingEvent(
		&stateB,
		.DirectHistoryReceived,
		3 * time.Second,
		historyHas,
		messageID,
	)
	testing.expectf(t, hasHistory, "expected B's history with A to contain %d", messageID)
	if hasHistory {
		testing.expect(t, history.peerUserID == userA, "expected the page to name peer A")
		ClientTransportRuntimeEvent_deinit(&history)
	}

	// The conversation list names A with the message as the latest one.
	conversationHas :: proc(event: ^ClientTransportRuntimeEvent, messageID: int) -> bool {
		return len(event.conversations) > 0 && event.conversations[0].lastMessageID == messageID
	}
	State_serverDirectCache(&stateB, serverID).conversationsLoading = false
	State_requestDirectConversations(&stateB, serverID)
	conversations, hasConversations := liveTestWaitForMatchingEvent(
		&stateB,
		.DirectConversationsReceived,
		3 * time.Second,
		conversationHas,
		messageID,
	)
	testing.expect(t, hasConversations, "expected B's conversation list to lead with A")
	if hasConversations {
		testing.expectf(
			t,
			conversations.conversations[0].peerUserId == userA &&
			conversations.conversations[0].peerNickname == configA.display_name,
			"expected the latest conversation to be with %q, got %v",
			configA.display_name,
			conversations.conversations[0],
		)
		ClientTransportRuntimeEvent_deinit(&conversations)
	}

	// The directory B fetched at connect lists A as online.
	cacheB = State_serverDirectCache(&stateB, serverID)
	userIndex := ServerDirectCache_userIndex(cacheB^, userA)
	testing.expect(
		t,
		cacheB.usersLoaded && userIndex >= 0 && cacheB.users[userIndex].isOnline,
		"expected B's directory to list A as online",
	)
}
