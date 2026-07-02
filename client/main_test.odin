#+feature dynamic-literals
package client

import "../common"
import "core:encoding/cbor"
import "core:os"
import "core:sync"
import "core:testing"
import "shared:skald"

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
	roomChatSendBridgeTestContent = content
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
		clientIdentityPublicKey  = transport.clientIdentityPublicKey,
		clientEphemeralPublicKey = transport.clientEphemeralPublicKey,
	}
	serverHelloProof := common.buildServerHelloProof(
		sessionID,
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

testConfigWithServers :: proc(servers: [dynamic]Server) -> Config {
	privateKey, publicKey, ok := common.generateIdentityKeyPair()
	assert(ok, "expected identity key generation to succeed")

	return Config {
		private_key = common.identityPrivateKeyToHex(privateKey),
		public_key = common.identityPublicKeyToHex(publicKey),
		display_name = "Tester",
		servers = servers,
		friends = {},
	}
}

buildEstablishedTransportPair :: proc(server: Server, config: Config) -> (
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
	config := testConfigWithServers({server})
	state := State_initFromConfig(config)
	state.view_dms = false
	state.selected_server_id = server.id
	state.selected_transport_index = State_selectedTransportIndexForServerID(state, server.id)
	state.selected_channel_id = common.GENERAL_ROOM_ID
	state.chat_input_draft = "pending channel draft"
	state.dm_chat_draft = "pending dm draft"
	return state
}

testViewCtx :: proc(
	theme: ^skald.Theme,
	input: ^skald.Input,
	msgs: ^[dynamic]Msg,
	widgets: ^skald.Widget_Store,
) -> skald.Ctx(Msg) {
	return skald.Ctx(Msg){
		theme = theme,
		input = input,
		msgs = msgs,
		widgets = widgets,
	}
}

testRoomChatAreaView :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> (skald.View_Stack, bool) {
	rootView := view_server(s, ctx)
	root, rootOK := rootView.(skald.View_Stack)
	if !rootOK || len(root.children) != 1 {
		return {}, false
	}

	innerRow, innerRowOK := root.children[0].(skald.View_Stack)
	if !innerRowOK || len(innerRow.children) < 3 {
		return {}, false
	}

	chatArea, chatAreaOK := innerRow.children[2].(skald.View_Stack)
	if !chatAreaOK {
		return {}, false
	}

	return chatArea, true
}

@(test)
testUpdateSendChannelChatMessageDoesNotAppendVisibleChatOnSubmit :: proc(t: ^testing.T) {
	sync.mutex_lock(&roomChatSendBridgeTestMutex)
	defer sync.mutex_unlock(&roomChatSendBridgeTestMutex)

	server := Server {
		id = 501,
		name = "Reducer Server",
		short_name = getShortServerName("Reducer Server"),
		host = "localhost",
		port = common.DEFAULT_SERVER_PORT,
	}
	state := testUpdateStateForServer(server)

	originalRoomChatSendBridge := roomChatSendBridge
	roomChatSendBridgeTestServerID = 0
	roomChatSendBridgeTestRoomID = 0
	roomChatSendBridgeTestContent = ""
	roomChatSendBridgeTestReturnValue = true
	roomChatSendBridge = roomChatSendBridgeTestStub
	defer roomChatSendBridge = originalRoomChatSendBridge

	out, _ := update(state, Msg{kind = .SendChannelChatMessage, new_value = "hello haychat"})

	testing.expect(
		t,
		len(out.current_chat_messages) == 0,
		"expected channel submit to avoid locally appending visible chat",
	)
	testing.expect(
		t,
		out.chat_input_draft == "",
		"expected successful channel submit to clear the draft",
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
	testing.expect(
		t,
		roomChatSendBridgeTestContent == "hello haychat",
		"expected channel submit to forward the typed content to the transport bridge",
	)
	testing.expect(
		t,
		len(out.chat_status_message) == 0,
		"expected successful channel submit to keep the chat status clear",
	)

	_ = t
}

@(test)
testUpdateReceiveRoomChatAppendsOnlyOnAuthoritativeReceive :: proc(t: ^testing.T) {
	sync.mutex_lock(&roomChatSendBridgeTestMutex)
	defer sync.mutex_unlock(&roomChatSendBridgeTestMutex)

	server := Server {
		id = 502,
		name = "Authoritative Server",
		short_name = getShortServerName("Authoritative Server"),
		host = "localhost",
		port = common.DEFAULT_SERVER_PORT,
	}
	state := testUpdateStateForServer(server)
	state.serverTransports[state.selected_transport_index].authenticatedUserID = 77

	originalRoomChatSendBridge := roomChatSendBridge
	roomChatSendBridgeTestReturnValue = true
	roomChatSendBridge = roomChatSendBridgeTestStub
	defer roomChatSendBridge = originalRoomChatSendBridge

	afterSend, _ := update(
		state,
		Msg{kind = .SendChannelChatMessage, new_value = "should wait for echo"},
	)
	testing.expect(
		t,
		len(afterSend.current_chat_messages) == 0,
		"expected submit to keep chat empty until the server echo arrives",
	)

	afterSelfReceive, _ := update(
		afterSend,
		Msg {
			kind = .RecieveChannelChatMessage,
			id = server.id,
			channel_id = common.GENERAL_ROOM_ID,
			sender_id = 77,
			new_value = "self echo",
		},
	)
	testing.expect(
		t,
		len(afterSelfReceive.current_chat_messages) == 2,
		"expected authoritative self echo to append one visible room-chat line",
	)
	testing.expect(
		t,
		afterSelfReceive.current_chat_messages[0].str == "You: ",
		"expected self echoes to render with a self label",
	)
	testing.expect(
		t,
		afterSelfReceive.current_chat_messages[0].weight == .Bold,
		"expected self labels to keep the existing bold sender styling",
	)
	testing.expect(
		t,
		afterSelfReceive.current_chat_messages[0].color == skald.theme_dark().color.primary,
		"expected self echoes to render with distinct self styling",
	)
	testing.expect(
		t,
		afterSelfReceive.current_chat_messages[1].str == "self echo",
		"expected self echo content to be appended on authoritative receive",
	)

	afterOtherReceive, _ := update(
		afterSelfReceive,
		Msg {
			kind = .RecieveChannelChatMessage,
			id = server.id,
			channel_id = common.GENERAL_ROOM_ID,
			sender_id = 42,
			new_value = "other echo",
		},
	)
	testing.expect(
		t,
		len(afterOtherReceive.current_chat_messages) == 5,
		"expected a second authoritative receive to append a second visible room-chat line",
	)
	testing.expect(
		t,
		afterOtherReceive.current_chat_messages[3].str == "User 42: ",
		"expected non-self echoes to render with the sender ID label",
	)
	testing.expect(
		t,
		afterOtherReceive.current_chat_messages[3].weight == .Bold,
		"expected non-self echoes to keep the existing bold sender styling",
	)
	testing.expect(
		t,
		afterOtherReceive.current_chat_messages[3].color == skald.theme_dark().color.fg,
		"expected non-self echoes to render with the standard sender styling",
	)

	_ = t
}

@(test)
testUpdateSendChatMessageSurfacesUnsupportedDMWithoutLocalAppend :: proc(t: ^testing.T) {
	server := Server {
		id = 503,
		name = "DM Server",
		short_name = getShortServerName("DM Server"),
		host = "localhost",
		port = common.DEFAULT_SERVER_PORT,
	}
	state := testUpdateStateForServer(server)
	state.view_dms = true
	initialChatLen := len(state.current_dm_chat)
	initialPrompt := state.current_dm_chat[0].str

	out, _ := update(state, Msg{kind = .SendChatMessage, new_value = "hello dm"})

	testing.expect(
		t,
		len(out.current_dm_chat) == initialChatLen,
		"expected unsupported DM submit to avoid locally appending visible chat",
	)
	testing.expect(
		t,
		out.current_dm_chat[0].str == initialPrompt,
		"expected unsupported DM submit to leave the visible DM transcript unchanged",
	)
	testing.expect(
		t,
		out.dm_chat_draft == "pending dm draft",
		"expected unsupported DM submit to keep the draft intact",
	)
	testing.expect(
		t,
		out.chat_status_message == DIRECT_MESSAGES_UNSUPPORTED_STATUS,
		"expected unsupported DM submit to surface a visible status message",
	)

	_ = t
}

@(test)
testUpdateMismatchedReceiveAndProtocolErrorStayNarrow :: proc(t: ^testing.T) {
	server := Server {
		id = 504,
		name = "Narrow Server",
		short_name = getShortServerName("Narrow Server"),
		host = "localhost",
		port = common.DEFAULT_SERVER_PORT,
	}
	state := testUpdateStateForServer(server)

	mismatchedServer, _ := update(
		state,
		Msg {
			kind = .RecieveChannelChatMessage,
			id = server.id + 1,
			channel_id = common.GENERAL_ROOM_ID,
			sender_id = 42,
			new_value = "wrong server",
		},
	)
	testing.expect(
		t,
		len(mismatchedServer.current_chat_messages) == 0,
		"expected room chat from a different server to stay hidden",
	)

	mismatchedRoom, _ := update(
		state,
		Msg {
			kind = .RecieveChannelChatMessage,
			id = server.id,
			channel_id = common.GENERAL_ROOM_ID + 1,
			sender_id = 42,
			new_value = "wrong room",
		},
	)
	testing.expect(
		t,
		len(mismatchedRoom.current_chat_messages) == 0,
		"expected room chat from a different room to stay hidden",
	)

	protocolErrorState, _ := update(
		state,
		Msg{kind = .TransportProtocolError, new_value = "Unsupported roomId"},
	)
	testing.expect(
		t,
		len(protocolErrorState.current_chat_messages) == 0,
		"expected protocol errors to avoid mutating visible room chat",
	)
	testing.expect(
		t,
		protocolErrorState.chat_status_message == "Unsupported roomId",
		"expected protocol errors to surface through the chat status surface",
	)

	_ = t
}

@(test)
testUpdateClearsVisibleRoomTranscriptOnServerAndChannelSwitch :: proc(t: ^testing.T) {
	serverA := Server {
		id = 506,
		name = "First Server",
		short_name = getShortServerName("First Server"),
		host = "localhost",
		port = common.DEFAULT_SERVER_PORT,
	}
	serverB := Server {
		id = 507,
		name = "Second Server",
		short_name = getShortServerName("Second Server"),
		host = "localhost",
		port = common.DEFAULT_SERVER_PORT,
	}
	state := State_initFromConfig(testConfigWithServers({serverA, serverB}))
	state.view_dms = false
	state.selected_server_id = serverA.id
	state.selected_transport_index = State_selectedTransportIndexForServerID(state, serverA.id)
	state.selected_channel_id = common.GENERAL_ROOM_ID

	withTranscript, _ := update(
		state,
		Msg {
			kind = .RecieveChannelChatMessage,
			id = serverA.id,
			channel_id = common.GENERAL_ROOM_ID,
			sender_id = 42,
			new_value = "persisted room text",
		},
	)
	testing.expect(
		t,
		len(withTranscript.current_chat_messages) > 0,
		"expected authoritative receive to seed the visible room transcript before switching",
	)

	afterChannelSwitch, _ := update(
		withTranscript,
		Msg {
			kind = .SwitchToChannel,
			id = serverA.id,
			channel_id = common.GENERAL_ROOM_ID + 1,
		},
	)
	testing.expect(
		t,
		len(afterChannelSwitch.current_chat_messages) == 0,
		"expected switching channels to clear the previously visible room transcript",
	)

	restoredTranscript, _ := update(
		withTranscript,
		Msg {
			kind = .RecieveChannelChatMessage,
			id = serverA.id,
			channel_id = common.GENERAL_ROOM_ID,
			sender_id = 42,
			new_value = "server scoped room text",
		},
	)
	afterServerSwitch, _ := update(
		restoredTranscript,
		Msg {
			kind = .SwitchToServer,
			id = serverB.id,
		},
	)
	testing.expect(
		t,
		len(afterServerSwitch.current_chat_messages) == 0,
		"expected switching servers to clear the previously visible room transcript",
	)

	_ = t
}

@(test)
testViewServerRendersChatStatusInRoomChat :: proc(t: ^testing.T) {
	server := Server {
		id = 505,
		name = "Room View Server",
		short_name = getShortServerName("Room View Server"),
		host = "localhost",
		port = common.DEFAULT_SERVER_PORT,
	}
	state := testUpdateStateForServer(server)
	State_setChatStatus(&state, "Unsupported roomId")

	theme := skald.theme_dark()
	input: skald.Input
	msgs: [dynamic]Msg
	widgets: skald.Widget_Store
	ctx := testViewCtx(&theme, &input, &msgs, &widgets)
	chatArea, chatAreaOK := testRoomChatAreaView(state, &ctx)
	testing.expect(t, chatAreaOK, "expected room chat branch to expose a chat area stack")
	if !chatAreaOK {
		return
	}

	statusText, statusTextOK := chatArea.children[2].(skald.View_Text)
	testing.expect(t, statusTextOK, "expected room chat branch to render the chat status view")
	if !statusTextOK {
		return
	}

	testing.expect(
		t,
		statusText.str == "Unsupported roomId",
		"expected room chat status text to render the current chat status message",
	)

	_ = t
}

@(test)
testClientServerTransportBuildsEncryptedRoomChatPacketBytes :: proc(t: ^testing.T) {
	server := Server {
		id = 77,
		name = "Room Server",
		short_name = getShortServerName("Room Server"),
		host = "localhost",
		port = common.DEFAULT_SERVER_PORT,
	}
	config := testConfigWithServers({server})

	transport, serverTransport, ok := buildEstablishedTransportPair(server, config)
	assert(ok, "expected transport pair setup to succeed")

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
		id = 88,
		name = "Runtime Server",
		short_name = getShortServerName("Runtime Server"),
		host = "localhost",
		port = common.DEFAULT_SERVER_PORT,
	}
	config := testConfigWithServers({server})

	transport, serverTransport, ok := buildEstablishedTransportPair(server, config)
	assert(ok, "expected transport pair setup to succeed")

	sealedPacket, sealOK := common.sealPacketForSession(
		&serverTransport,
		.ServerChatMessage,
		common.ServerChatMessagePayload {
			senderId = 42,
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
	assert(
		runtimeEvent.senderID == 42,
		"expected room chat event to preserve senderId metadata",
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
		id = 99,
		name = "Protocol Server",
		short_name = getShortServerName("Protocol Server"),
		host = "localhost",
		port = common.DEFAULT_SERVER_PORT,
	}
	config := testConfigWithServers({server})

	transport, _, ok := buildEstablishedTransportPair(server, config)
	assert(ok, "expected transport pair setup to succeed")

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
				short_name = getShortServerName("Alpha Server"),
				host = "localhost",
				port = common.DEFAULT_SERVER_PORT,
			},
			Server {
				id = 22,
				name = "Bravo Server",
				short_name = getShortServerName("Bravo Server"),
				host = "localhost",
				port = common.DEFAULT_SERVER_PORT + 1,
			},
		},
	)

	state := State_initFromConfig(config)

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
				short_name = getShortServerName("Handshake Server"),
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

	state := State_initFromConfig(config)

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
				short_name = getShortServerName("Rejecting Server"),
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

	state := State_initFromConfig(config)
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
				short_name = getShortServerName("Broken Server"),
				host = "localhost",
				port = common.DEFAULT_SERVER_PORT,
			},
		},
		friends      = {},
	}

	state := State_initFromConfig(config)

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

@(test)
testClientServerTransportCanEstablishLiveStartupAuthOverENet :: proc(t: ^testing.T) {
	if os.get_env("HAYCHAT_LIVE_STARTUP_AUTH", context.allocator) != "1" {
		return
	}

	sync.mutex_lock(&startupAuthBridgeTestMutex)
	defer sync.mutex_unlock(&startupAuthBridgeTestMutex)

	config := testConfigWithServers(
		{
			Server {
				id = 66,
				name = "Live Server",
				short_name = getShortServerName("Live Server"),
				host = "127.0.0.1",
				port = 12345,
			},
		},
	)

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
