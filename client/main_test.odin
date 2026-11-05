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

startupAuthBridgeTestMutex: sync.Mutex
roomChatSendBridgeTestMutex: sync.Mutex
roomChatSendBridgeTestServerID: int
roomChatSendBridgeTestRoomID: int
roomChatSendBridgeTestContent: string
roomChatSendBridgeTestReturnValue: bool

roomChatSendBridgeTestStub :: proc(
	transport: ^ClientServerTransport,
	roomID: int,
	content: string,
) -> bool {
	roomChatSendBridgeTestServerID = transport.serverID
	roomChatSendBridgeTestRoomID = roomID
	// The sender frees the message after sending, so keep a copy for assertions.
	delete(roomChatSendBridgeTestContent)
	roomChatSendBridgeTestContent = strings.clone(content)
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
	state.view_dms = false
	state.selected_server_id = server.id
	state.selected_transport_index = State_selectedTransportIndexForServerID(state, server.id)
	state.selected_channel_id = common.GENERAL_ROOM_ID
	append(State_selectedRoomDraft(&state), "pending channel draft")
	append(&state.dm_chat_draft, "pending dm draft")
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
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

testSetDraft :: proc(draft: ^[dynamic]u8, value: string) {
	clear(draft)
	append(draft, value)
}

liveTestTransportStatus :: proc(transport: ^ClientServerTransport) -> string {
	return fmt.aprintf("phase=%v lastError=%q", transport.transport.phase, transport.lastError)
}

liveTestExpectEstablishedTransport :: proc(
	t: ^testing.T,
	transport: ^ClientServerTransport,
	label: string,
) {
	status := liveTestTransportStatus(transport)
	defer delete(status)

	testing.expect(
		t,
		transport.transport.phase == .Established,
		fmt.aprintf("expected %s to complete live connect/auth, got %s", label, status),
	)
	testing.expect(
		t,
		transport.authenticatedUserID != 0,
		fmt.aprintf(
			"expected %s to report a non-zero authenticated user ID, got %s",
			label,
			status,
		),
	)
	testing.expect(
		t,
		len(transport.lastError) == 0,
		fmt.aprintf("expected %s to finish live auth without an error, got %s", label, status),
	)
	testing.expect(
		t,
		ClientServerTransport_hasLiveENetSession(transport),
		fmt.aprintf("expected %s to retain a live ENet session, got %s", label, status),
	)
}

// Services the transport until an event of the wanted kind arrives. Other events, such as the
// room list that startup requested, are freed and skipped, so the result does not depend on
// the order the server's replies arrive in.
liveTestWaitForRuntimeEvent :: proc(
	transport: ^ClientServerTransport,
	kind: ClientTransportRuntimeEventKind,
	timeout: time.Duration,
) -> (
	ClientTransportRuntimeEvent,
	bool,
) {
	start := time.now()
	for time.since(start) < timeout {
		runtimeEvent, hasEvent := ClientServerTransport_serviceRuntime(transport)
		if !hasEvent {
			time.sleep(1 * time.Millisecond)
			continue
		}
		if runtimeEvent.kind == kind {
			return runtimeEvent, true
		}
		ClientTransportRuntimeEvent_deinit(&runtimeEvent)
	}

	return {}, false
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
		!state.view_dms,
		"expected first-release startup to open the selected server chat instead of DMs",
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
	state.serverTransports[state.selected_transport_index].authenticatedUserID = 77

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
testSendDirectMessageSurfacesUnsupportedStatusWithoutLocalAppend :: proc(t: ^testing.T) {
	server := Server {
		id         = 503,
		name       = "DM Server",
		host       = "localhost",
		port       = common.DEFAULT_SERVER_PORT,
	}
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)
	State_showDMs(&state)

	State_sendDirectMessage(&state)

	testing.expect(
		t,
		len(state.current_dm_chat) == 0,
		"expected unsupported DM submit to avoid locally appending visible chat",
	)
	testing.expect(
		t,
		string(state.dm_chat_draft[:]) == "pending dm draft",
		"expected unsupported DM submit to keep the draft intact",
	)
	testing.expect(
		t,
		state.chat_status_message == DIRECT_MESSAGES_UNSUPPORTED_STATUS,
		"expected unsupported DM submit to surface a visible status message",
	)
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
	state.view_dms = false
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
testRailTogglesBetweenDMsAndServers :: proc(t: ^testing.T) {
	server := Server {
		id   = 509,
		name = "Rail",
		host = "localhost",
		port = 1,
	}
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)
	State_setChatStatus(&state, "stale status")

	State_showDMs(&state)
	testing.expect(t, state.view_dms, "expected the DM toggle to open direct messages")
	testing.expect(t, len(state.chat_status_message) == 0, "expected switching to clear status")

	State_switchToServer(&state, server.id)
	testing.expect(t, !state.view_dms, "expected selecting a server to leave direct messages")
	testing.expect(
		t,
		state.selected_server_id == server.id,
		"expected selecting a server to select it",
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

	packetBytes, packetOK := ClientServerTransport_buildRoomChatPacketBytes(
		&transport,
		common.GENERAL_ROOM_ID,
		"hello haychat",
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
	defer delete(chatPayload.content)
	assert(
		chatPayload.roomId == common.GENERAL_ROOM_ID,
		"expected room chat payload roomId to match the shared room contract",
	)
	assert(
		chatPayload.content == "hello haychat",
		"expected room chat payload content to remain intact",
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

@(test)
testStateInitFromConfigAttemptsOnlySelectedDefaultServer :: proc(t: ^testing.T) {
	sync.mutex_lock(&startupAuthBridgeTestMutex)
	defer sync.mutex_unlock(&startupAuthBridgeTestMutex)

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

	testing.expect(
		t,
		state.selected_server_id == 11,
		"expected first configured server to be selected",
	)
	testing.expect(
		t,
		state.selected_transport_index == 0,
		"expected selected transport index to point at the selected server",
	)
	testing.expect(t, len(state.serverTransports) == 2, "expected a transport entry per server")
	testing.expect(
		t,
		state.serverTransports[0].transport.phase == .ClientHelloSent,
		"expected selected/default server startup attempt to begin the handshake",
	)
	testing.expect(
		t,
		state.serverTransports[1].transport.phase == .Disconnected,
		"expected non-selected servers to remain idle",
	)
	testing.expect(
		t,
		len(state.serverTransports[0].lastError) == 0,
		"expected selected/default startup attempt to avoid setting an error on success",
	)
}

@(test)
testStateInitFromConfigCanEstablishSelectedTransportViaStartupBridge :: proc(t: ^testing.T) {
	sync.mutex_lock(&startupAuthBridgeTestMutex)
	defer sync.mutex_unlock(&startupAuthBridgeTestMutex)

	config := testConfigWithServers(
		{
			Server {
				id = 44,
				name = "Handshake Server",
				host = "localhost",
				port = common.DEFAULT_SERVER_PORT,
			},
		},
	)

	originalBridge := startupAuthBridge
	startupAuthBridge = proc(
		transport: ^ClientServerTransport,
		server: ^Server,
		bridgeConfig: ^Config,
		clientHelloPacketBytes: []u8,
	) -> ClientStartupAuthSession {
		_ = clientHelloPacketBytes

		serverIdentityPrivateKey, serverIdentityPublicKey, identityOK :=
			common.generateIdentityKeyPair()
		assert(identityOK, "expected server identity key generation to succeed")

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

		_, serverHelloHandleOK := ClientServerTransport_handleIncomingPacket(
			transport,
			server,
			bridgeConfig,
			serverHelloBytes,
		)
		assert(serverHelloHandleOK, "expected selected startup bridge to accept ServerHello")

		authChallenge, authChallengeOK := common.generateAuthChallenge()
		assert(authChallengeOK, "expected auth challenge generation to succeed")

		authChallengeBytes, authChallengeBytesOK := common.buildPacketBytes(
			.ServerAuthChallenge,
			common.ServerAuthChallengePayload {
				sessionID = transport.sessionID,
				challenge = authChallenge,
			},
		)
		assert(authChallengeBytesOK, "expected auth challenge packet encoding to succeed")
		defer delete(authChallengeBytes)

		authChallengeResult, authChallengeHandleOK := ClientServerTransport_handleIncomingPacket(
			transport,
			server,
			bridgeConfig,
			authChallengeBytes,
		)
		assert(authChallengeHandleOK, "expected selected startup bridge to accept auth challenge")
		defer if authChallengeResult.hasResponse do delete(authChallengeResult.responsePacketBytes)
		assert(
			authChallengeResult.hasResponse,
			"expected auth challenge handling to emit ClientAuthRequest bytes",
		)

		authSuccessBytes, authSuccessBytesOK := common.buildPacketBytes(
			.ServerAuthSuccess,
			common.ServerAuthSuccessPayload{userId = 77, message = "ok"},
		)
		assert(authSuccessBytesOK, "expected auth success packet encoding to succeed")
		defer delete(authSuccessBytes)

		_, authSuccessHandleOK := ClientServerTransport_handleIncomingPacket(
			transport,
			server,
			bridgeConfig,
			authSuccessBytes,
		)
		assert(authSuccessHandleOK, "expected selected startup bridge to accept auth success")

		return {}
	}
	defer startupAuthBridge = originalBridge

	defer Config_deinit(&config)
	state := State_initFromConfig(config)
	defer State_deinit(&state)

	testing.expect(t, len(state.serverTransports) == 1, "expected a single transport")
	testing.expect(
		t,
		state.serverTransports[0].transport.phase == .Established,
		"expected startup bridge to be able to establish the selected transport",
	)
	testing.expect(
		t,
		state.serverTransports[0].authenticatedUserID == 77,
		"expected startup bridge to capture the authenticated user ID",
	)
}

@(test)
testStateInitFromConfigClearsPendingAuthStateAfterFailureAndDisconnect :: proc(t: ^testing.T) {
	sync.mutex_lock(&startupAuthBridgeTestMutex)
	defer sync.mutex_unlock(&startupAuthBridgeTestMutex)

	config := testConfigWithServers(
		{
			Server {
				id = 55,
				name = "Rejecting Server",
				host = "localhost",
				port = common.DEFAULT_SERVER_PORT,
			},
		},
	)

	originalBridge := startupAuthBridge
	startupAuthBridge = proc(
		transport: ^ClientServerTransport,
		server: ^Server,
		bridgeConfig: ^Config,
		clientHelloPacketBytes: []u8,
	) -> ClientStartupAuthSession {
		_ = clientHelloPacketBytes

		serverIdentityPrivateKey, serverIdentityPublicKey, identityOK :=
			common.generateIdentityKeyPair()
		assert(identityOK, "expected server identity key generation to succeed")

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

		_, serverHelloHandleOK := ClientServerTransport_handleIncomingPacket(
			transport,
			server,
			bridgeConfig,
			serverHelloBytes,
		)
		assert(serverHelloHandleOK, "expected selected startup bridge to accept ServerHello")

		authFailureBytes, authFailureBytesOK := common.buildPacketBytes(
			.ServerAuthFailure,
			common.ServerAuthFailurePayload{message = "invalid client auth signature"},
		)
		assert(authFailureBytesOK, "expected auth failure packet encoding to succeed")
		defer delete(authFailureBytes)

		_, authFailureHandleOK := ClientServerTransport_handleIncomingPacket(
			transport,
			server,
			bridgeConfig,
			authFailureBytes,
		)
		assert(!authFailureHandleOK, "expected auth failure to fail the selected transport")

		ClientServerTransport_handleDisconnect(transport)
		return {}
	}
	defer startupAuthBridge = originalBridge

	defer Config_deinit(&config)
	state := State_initFromConfig(config)
	defer State_deinit(&state)
	transport := state.serverTransports[0]

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
	sync.mutex_lock(&startupAuthBridgeTestMutex)
	defer sync.mutex_unlock(&startupAuthBridgeTestMutex)

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
		state.serverTransports[0].transport.phase == .Failed,
		"expected selected/default transport init failures to surface as failed state",
	)
	testing.expect(
		t,
		state.serverTransports[0].lastError == "client identity keys are missing or invalid",
		"expected selected/default transport init failures to keep a visible error message",
	)
}

// The server binds a nickname to the first identity key it sees, and live tests generate a
// fresh key every run, so each run needs nicknames the database has not seen before.
liveTestUniqueNickname :: proc(prefix: string) -> string {
	return fmt.aprintf("%s-%x", prefix, time.time_to_unix_nano(time.now()))
}

@(test)
testClientServerTransportCanEstablishLiveStartupAuthOverENet :: proc(t: ^testing.T) {
	if os.get_env("HAYCHAT_LIVE_STARTUP_AUTH", context.temp_allocator) != "1" {
		return
	}

	sync.mutex_lock(&startupAuthBridgeTestMutex)
	defer sync.mutex_unlock(&startupAuthBridgeTestMutex)

	config := testConfigWithServers(
		{
			Server {
				id = 66,
				name = "Live Server",
				host = "127.0.0.1",
				port = 12345,
			},
		},
	)

	delete(config.display_name)
	config.display_name = liveTestUniqueNickname("live")

	originalBridge := startupAuthBridge
	startupAuthBridge = startupAuthBridge_real
	defer startupAuthBridge = originalBridge

	state := State_initFromConfig(config)
	transport := &state.serverTransports[0]
	defer ClientServerTransport_handleDisconnect(transport)

	testing.expect(
		t,
		transport.transport.phase == .Established,
		"expected live startup auth bridge to establish the transport",
	)
	testing.expect(
		t,
		transport.authenticatedUserID != 0,
		"expected live startup auth bridge to report a non-zero authenticated user ID",
	)
	testing.expect(
		t,
		len(transport.lastError) == 0,
		"expected live startup auth bridge to succeed without setting an error",
	)
	testing.expect(
		t,
		ClientServerTransport_hasLiveENetSession(transport),
		"expected startup return to retain the live ENet session",
	)

	// Startup requested the room list; the background worker must service the session and
	// queue the server's reply without the UI polling ENet.
	state.networkWorker = ClientNetworkWorker_start(state.serverTransports[:])
	roomListReceived := false
	deadline := time.tick_now()
	for !roomListReceived && time.tick_since(deadline) < 3 * time.Second {
		event, hasEvent := ClientNetworkWorker_popEvent(state.networkWorker)
		if hasEvent {
			roomListReceived = event.kind == .RoomListReceived
			ClientTransportRuntimeEvent_deinit(&event)
		} else {
			time.sleep(10 * time.Millisecond)
		}
	}
	ClientNetworkWorker_stop(state.networkWorker)
	state.networkWorker = nil
	testing.expect(
		t,
		roomListReceived,
		"expected the network worker to deliver the startup room list from a live server",
	)

	postAuthProbeSent := ClientServerTransport_sendENetPacket(
		transport.enetHost,
		transport.enetPeer,
		STARTUP_AUTH_CHANNEL_CHAT,
		{0x01},
	)
	testing.expect(
		t,
		postAuthProbeSent,
		"expected retained ENet session to allow a post-auth outbound send",
	)
}

@(test)
testClientServerTransportCanSendLiveRoomChatBetweenTwoAuthenticatedClients :: proc(t: ^testing.T) {
	if os.get_env("HAYCHAT_LIVE_STARTUP_AUTH", context.temp_allocator) != "1" {
		return
	}

	sync.mutex_lock(&startupAuthBridgeTestMutex)
	defer sync.mutex_unlock(&startupAuthBridgeTestMutex)

	configA := testConfigWithServers(
		{
			Server {
				id = 67,
				name = "Live Chat Server",
				host = "127.0.0.1",
				port = 12345,
			},
		},
	)
	configB := testConfigWithServers(
		{
			Server {
				id = 67,
				name = "Live Chat Server",
				host = "127.0.0.1",
				port = 12345,
			},
		},
	)

	delete(configA.display_name)
	configA.display_name = liveTestUniqueNickname("live-a")
	delete(configB.display_name)
	configB.display_name = liveTestUniqueNickname("live-b")

	originalBridge := startupAuthBridge
	startupAuthBridge = startupAuthBridge_real
	defer startupAuthBridge = originalBridge

	stateA := State_initFromConfig(configA)
	stateB := State_initFromConfig(configB)
	transportA := &stateA.serverTransports[0]
	transportB := &stateB.serverTransports[0]
	defer ClientServerTransport_handleDisconnect(transportA)
	defer ClientServerTransport_handleDisconnect(transportB)

	liveTestExpectEstablishedTransport(t, transportA, "client A")
	liveTestExpectEstablishedTransport(t, transportB, "client B")

	messageContent := "live two-client room chat proof"
	sendOK := ClientServerTransport_sendRoomChatMessage(
		transportA,
		common.GENERAL_ROOM_ID,
		messageContent,
	)
	sendStatus := liveTestTransportStatus(transportA)
	defer delete(sendStatus)
	testing.expect(
		t,
		sendOK,
		fmt.aprintf("expected client A to send a live room chat message, got %s", sendStatus),
	)

	runtimeEvent, hasEvent := liveTestWaitForRuntimeEvent(
		transportB,
		.RoomChatReceived,
		2 * time.Second,
	)
	defer if hasEvent do ClientTransportRuntimeEvent_deinit(&runtimeEvent)
	receiverStatus := liveTestTransportStatus(transportB)
	defer delete(receiverStatus)
	testing.expectf(
		t,
		hasEvent,
		"expected client B to receive a live room chat message before timeout, got %s",
		receiverStatus,
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
		runtimeEvent.senderID == transportA.authenticatedUserID,
		"expected client B runtime event sender to match client A, got sender=%v auth=%v",
		runtimeEvent.senderID,
		transportA.authenticatedUserID,
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

	// History must label the stored message with the same nickname as the live fan-out.
	historyOK := ClientServerTransport_requestRoomHistory(
		transportB,
		common.GENERAL_ROOM_ID,
		0,
		50,
	)
	testing.expect(t, historyOK, "expected client B to request General room history")
	historyEvent, hasHistory := liveTestWaitForRuntimeEvent(
		transportB,
		.RoomHistoryReceived,
		2 * time.Second,
	)
	defer if hasHistory do ClientTransportRuntimeEvent_deinit(&historyEvent)
	testing.expect(t, hasHistory, "expected client B to receive General room history")
	if !hasHistory {
		return
	}
	foundInHistory := false
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
	testing.expectf(
		t,
		foundInHistory,
		"expected General room history to contain message %d",
		runtimeEvent.messageID,
	)
}
