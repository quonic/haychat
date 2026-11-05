package server

import "../common"
import "base:runtime"
import "core:c/libc"
import "core:crypto/ecdh"
import "core:encoding/cbor"
import "core:fmt"
import "core:strings"
import "core:sync"

import "core:time"

PendingDBRequestType :: enum {
	ResolveUserIdentity,
	ListRooms,
	PostChatMessage,
	GetRoomHistory,
	CheckAdminCreateRoom,
	CreateRoom,
	CheckAdminEditRoom,
	EditRoom,
	ListEditRoomRecipients,
	CheckAdminDeleteRoom,
	ListDeleteRoomRecipients,
	DeleteRoom,
	CheckAdminAddRoomMember,
	AddRoomMember,
	CheckAdminRemoveRoomMember,
	RemoveRoomMember,
	PostDirectMessage,
	GetDirectHistory,
	ListDirectConversations,
	ListUsers,
}

PendingDBRequest :: struct {
	requestID:        u64,
	peerID:           u32,
	requestType:      PendingDBRequestType,
	roomID:           int,
	name:             string,
	description:      string,
	// Room member mutations: the member. Direct messages and history: the peer account.
	targetUserID:     int,
	recipientUserIDs: [dynamic]int,
}

PendingDBRequest_deinit :: proc(request: PendingDBRequest) {
	delete(request.name)
	delete(request.description)
	delete(request.recipientUserIDs)
}

RouterPeerSession :: struct {
	transport:                 common.TransportState,
	clientNickname:            string,
	clientIdentityPublicKey:   common.IdentityPublicKeyBytes,
	clientEphemeralPublicKey:  common.KeyExchangePublicKeyBytes,
	serverIdentityPublicKey:   common.IdentityPublicKeyBytes,
	serverEphemeralPrivateKey: ecdh.Private_Key,
	serverEphemeralPublicKey:  common.KeyExchangePublicKeyBytes,
	sessionID:                 common.SessionID,
	authChallenge:             common.AuthChallengeBytes,
	allowRegistration:         bool,
	isAuthenticated:           bool,
	authenticatedUserID:       int,
}

@(private)
mainInterruptContext: runtime.Context

@(private)
mainInterruptRequested := false

@(private)
mainInterruptShutdownQueued := false

registerMainInterruptHandler :: proc() {
	mainInterruptContext = context
	libc.signal(libc.SIGINT, proc "cdecl" (_: i32) {
		context = mainInterruptContext
		mainInterruptRequested = true
		fmt.println("[Main] SIGINT received, requesting shutdown")
	})
}

queueMainInterruptShutdown :: proc(pm: ^ProcessManager) {
	if mainInterruptShutdownQueued {
		return
	}

	mainInterruptRequested = false
	mainInterruptShutdownQueued = true
	fmt.println("[Main] Received SIGINT (Ctrl+C), starting graceful shutdown")

	mainContext := IPC_Server_Context{}
	IPC_Server_send(&mainContext, pm.config.mainFd, ProcessShutdown{})
}

DATABASE_STARTUP_ACK_TIMEOUT :: 6 * time.Second

RouterPeerSession_init :: proc() -> RouterPeerSession {
	return RouterPeerSession {
		transport = common.TransportState_init(.Server),
		allowRegistration = true,
	}
}

RouterPeerSession_deinit :: proc(session: ^RouterPeerSession) {
	delete(session.clientNickname)
	session^ = {}
}

MainRouterState :: struct {
	connectedPeers:           map[u32]bool,
	peerSessions:             map[u32]RouterPeerSession,
	pendingDatabaseRequests:  map[u64]PendingDBRequest,
	nextRequestID:            u64,
	serverIdentityPrivateKey: common.IdentityPrivateKeyBytes,
	serverIdentityPublicKey:  common.IdentityPublicKeyBytes,
	adminPublicKey:           common.IdentityPublicKeyBytes,
	hasAdminPublicKey:        bool,
}

MainRouterState_init :: proc(pm: ^ProcessManager) -> MainRouterState {
	state := MainRouterState {
		connectedPeers          = make(map[u32]bool),
		peerSessions            = make(map[u32]RouterPeerSession),
		pendingDatabaseRequests = make(map[u64]PendingDBRequest),
		nextRequestID           = 1,
	}

	serverPrivateKey, privateKeyOK := common.identityPrivateKeyFromHex(pm.config.serverPrivateKey)
	if privateKeyOK {
		state.serverIdentityPrivateKey = serverPrivateKey
	}

	serverPublicKey, publicKeyOK := common.identityPublicKeyFromHex(pm.config.serverPublicKey)
	if publicKeyOK {
		state.serverIdentityPublicKey = serverPublicKey
	}

	if len(pm.config.adminPublicKey) > 0 {
		state.adminPublicKey, state.hasAdminPublicKey = common.identityPublicKeyFromHex(
			pm.config.adminPublicKey,
		)
	}

	return state
}

MainRouterState_deinit :: proc(state: ^MainRouterState) {
	for _, session in state.peerSessions {
		delete(session.clientNickname)
	}
	for _, request in state.pendingDatabaseRequests {
		PendingDBRequest_deinit(request)
	}
	delete(state.connectedPeers)
	delete(state.peerSessions)
	delete(state.pendingDatabaseRequests)
}

MainRouterState_generateRequestID :: proc(state: ^MainRouterState) -> u64 {
	id := state.nextRequestID
	state.nextRequestID += 1
	return id
}

MainRouterState_setPeerSession :: proc(
	state: ^MainRouterState,
	peerID: u32,
	session: RouterPeerSession,
) {
	state.peerSessions[peerID] = session
}

MainRouterState_getPeerSession :: proc(
	state: ^MainRouterState,
	peerID: u32,
) -> (
	RouterPeerSession,
	bool,
) {
	session, ok := state.peerSessions[peerID]
	return session, ok
}

MainRouterState_ensurePeerSession :: proc(
	state: ^MainRouterState,
	peerID: u32,
) -> RouterPeerSession {
	session, ok := MainRouterState_getPeerSession(state, peerID)
	if ok {
		return session
	}

	session = RouterPeerSession_init()
	MainRouterState_setPeerSession(state, peerID, session)
	return session
}

MainRouterState_removePeerSession :: proc(state: ^MainRouterState, peerID: u32) {
	if session, ok := MainRouterState_getPeerSession(state, peerID); ok {
		RouterPeerSession_deinit(&session)
	}
	delete_key(&state.peerSessions, peerID)
}

MainRouterState_removePendingRequestsForPeer :: proc(state: ^MainRouterState, peerID: u32) {
	requestIDs := make([dynamic]u64)
	defer delete(requestIDs)

	for requestID, request in state.pendingDatabaseRequests {
		if request.peerID == peerID {
			append(&requestIDs, requestID)
		}
	}

	for requestID in requestIDs {
		request := state.pendingDatabaseRequests[requestID]
		PendingDBRequest_deinit(request)
		delete_key(&state.pendingDatabaseRequests, requestID)
	}
}

MainRouterState_isPlaintextHandshakeResponse :: proc(messageType: common.MessageType) -> bool {
	#partial switch messageType {
	case .ServerHello,
	     .ServerRegisterResponse,
	     .ServerAuthChallenge,
	     .ServerAuthSuccess,
	     .ServerAuthFailure:
		return true
	case:
		return false
	}
}

MainRouterState_sendPeerPacket :: proc(pm: ^ProcessManager, peerID: u32, packetBytes: []u8) {
	IPC_Server_send(
		&pm.config.networkSocket,
		pm.config.networkFd,
		NetworkSendData{peerId = peerID, channel = .Chat, data = packetBytes},
	)
}

MainRouterState_sendPeerMessage :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	messageType: common.MessageType,
	payload: any,
) -> bool {
	if session, ok := MainRouterState_getPeerSession(state, peerID);
	   ok &&
	   session.isAuthenticated &&
	   !MainRouterState_isPlaintextHandshakeResponse(messageType) {
		sealedPacket, sealOK := common.sealPacketForSession(
			&session.transport,
			messageType,
			payload,
		)
		if !sealOK {
			fmt.printfln("[Main] Failed to seal packet for peer %d\n", peerID)
			return false
		}
		defer delete(sealedPacket.payload)

		packetBytes, packetErr := cbor.marshal(sealedPacket)
		if packetErr != nil {
			fmt.printfln(
				"[Main] Failed to encode sealed packet for peer %d: %v\n",
				peerID,
				packetErr,
			)
			return false
		}

		MainRouterState_setPeerSession(state, peerID, session)
		MainRouterState_sendPeerPacket(pm, peerID, packetBytes)
		return true
	}

	payloadBytes, payloadErr := cbor.marshal(payload)
	if payloadErr != nil {
		fmt.printfln("[Main] Failed to encode payload for peer %d: %v\n", peerID, payloadErr)
		return false
	}
	defer delete(payloadBytes)

	packet := common.Packet {
		messageType = messageType,
		payload     = payloadBytes,
	}

	packetBytes, packetErr := cbor.marshal(packet)
	if packetErr != nil {
		fmt.printfln("[Main] Failed to encode packet for peer %d: %v\n", peerID, packetErr)
		return false
	}

	MainRouterState_sendPeerPacket(pm, peerID, packetBytes)
	return true
}

MainRouterState_sendProtocolError :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	message: string,
) {
	MainRouterState_sendPeerMessage(
		pm,
		state,
		peerID,
		common.MessageType.ServerProtocolError,
		common.ProtocolErrorResponse{message = message},
	)
}

MainRouterState_disconnectPeer :: proc(pm: ^ProcessManager, peerID: u32) {
	IPC_Server_send(
		&pm.config.networkSocket,
		pm.config.networkFd,
		NetworkDisconnectPeer{peerId = peerID},
	)
}

MainRouterState_protocolViolation :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	message: string,
) {
	MainRouterState_sendProtocolError(pm, state, peerID, message)
	if session, ok := MainRouterState_getPeerSession(state, peerID); ok {
		wasAuthenticated := session.isAuthenticated
		session.transport.phase = .Failed
		session.isAuthenticated = false
		MainRouterState_setPeerSession(state, peerID, session)
		// The session no longer counts as online, and its later disconnect event will not
		// see it as authenticated, so presence must be settled here.
		if wasAuthenticated {
			MainRouterState_noteSessionEnded(
				pm,
				state,
				peerID,
				session.authenticatedUserID,
				session.clientNickname,
			)
		}
	}
	MainRouterState_disconnectPeer(pm, peerID)
}

MainRouterAuthSuccessSender :: #type proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	userID: int,
) -> bool

MainRouterState_sendAuthSuccess :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	userID: int,
) -> bool {
	return MainRouterState_sendPeerMessage(
		pm,
		state,
		peerID,
		common.MessageType.ServerAuthSuccess,
		common.ServerAuthSuccessPayload{userId = userID, message = "ok"},
	)
}

// Finishes a handshake whose identity resolved to userID. The session counts as authenticated
// only once ServerAuthSuccess is out (it is a plaintext handshake response, so it does not need
// the flag). Marking it first would let a failed send reach MainRouterState_protocolViolation
// as an authenticated session, which announces offline a user nobody heard come online.
// sendAuthSuccess exists so router tests can make the send fail.
MainRouterState_completeAuthentication :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	userID: int,
	sendAuthSuccess: MainRouterAuthSuccessSender = MainRouterState_sendAuthSuccess,
) {
	if session, sessionOK := MainRouterState_getPeerSession(state, peerID);
	   !sessionOK || session.isAuthenticated {
		return
	}
	if !sendAuthSuccess(pm, state, peerID, userID) {
		MainRouterState_protocolViolation(pm, state, peerID, "Failed to send auth success")
		return
	}

	session, _ := MainRouterState_getPeerSession(state, peerID)
	// Counted before this session joins, so only a user's first session announces them.
	wasOnline := MainRouterState_isUserOnline(state, userID)
	session.isAuthenticated = true
	session.authenticatedUserID = userID
	MainRouterState_setPeerSession(state, peerID, session)
	if !wasOnline {
		MainRouterState_broadcastPresence(
			pm,
			state,
			userID,
			session.clientNickname,
			true,
			peerID,
		)
	}
}

MainRouterState_sendAuthFailure :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	message: string,
) {
	MainRouterState_sendPeerMessage(
		pm,
		state,
		peerID,
		common.MessageType.ServerAuthFailure,
		common.ServerAuthFailurePayload{message = message},
	)
}

MainRouterState_enqueueDatabaseRequest :: proc(
	state: ^MainRouterState,
	requestID: u64,
	peerID: u32,
	requestType: PendingDBRequestType,
) {
	state.pendingDatabaseRequests[requestID] = PendingDBRequest {
		requestID   = requestID,
		peerID      = peerID,
		requestType = requestType,
	}
}

MainRouterState_enqueueChannelDatabaseRequest :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	request: common.DatabaseQueryRequest,
	pending: PendingDBRequest,
) {
	pendingRequest := pending
	pendingRequest.requestID = MainRouterState_generateRequestID(state)
	pendingRequest.peerID = peerID
	state.pendingDatabaseRequests[pendingRequest.requestID] = pendingRequest
	IPC_Server_send(
		&pm.config.databaseSocket,
		pm.config.databaseFd,
		DatabaseQuery{request_id = pendingRequest.requestID, request = request},
	)
}

MainRouterState_getDatabaseRequest :: proc(
	state: ^MainRouterState,
	requestID: u64,
) -> (
	PendingDBRequest,
	bool,
) {
	request, ok := state.pendingDatabaseRequests[requestID]
	if ok {
		delete_key(&state.pendingDatabaseRequests, requestID)
	}
	return request, ok
}

MainRouterState_clearTransientRuntimeState :: proc(state: ^MainRouterState) {
	for _, request in state.pendingDatabaseRequests {
		PendingDBRequest_deinit(request)
	}
	for _, session in state.peerSessions {
		delete(session.clientNickname)
	}
	delete(state.connectedPeers)
	delete(state.peerSessions)
	delete(state.pendingDatabaseRequests)
	state.connectedPeers = make(map[u32]bool)
	state.peerSessions = make(map[u32]RouterPeerSession)
	state.pendingDatabaseRequests = make(map[u64]PendingDBRequest)
}

MainRouterState_failPendingDatabaseRequests :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	message: string,
) {
	requestIDs := make([dynamic]u64)
	defer delete(requestIDs)

	for requestID in state.pendingDatabaseRequests {
		append(&requestIDs, requestID)
	}

	for requestID in requestIDs {
		request, ok := MainRouterState_getDatabaseRequest(state, requestID)
		if !ok {
			continue
		}

		switch request.requestType {
		case .ResolveUserIdentity:
			MainRouterState_sendAuthFailure(pm, state, request.peerID, message)
			MainRouterState_disconnectPeer(pm, request.peerID)
		case .ListRooms,
		     .PostChatMessage,
		     .GetRoomHistory,
		     .CheckAdminCreateRoom,
		     .CreateRoom,
		     .CheckAdminEditRoom,
		     .EditRoom,
		     .ListEditRoomRecipients,
		     .CheckAdminDeleteRoom,
		     .ListDeleteRoomRecipients,
		     .DeleteRoom,
		     .CheckAdminAddRoomMember,
		     .AddRoomMember,
		     .CheckAdminRemoveRoomMember,
		     .RemoveRoomMember,
		     .PostDirectMessage,
		     .GetDirectHistory,
		     .ListDirectConversations,
		     .ListUsers:
			MainRouterState_sendProtocolError(pm, state, request.peerID, message)
		case:
		}
		PendingDBRequest_deinit(request)
	}
}

MainRouterState_prepareForProcessStop :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	procType: ProcessType,
	message: string,
) {
	switch procType {
	case .Network:
		MainRouterState_failPendingDatabaseRequests(pm, state, message)
		MainRouterState_clearTransientRuntimeState(state)
	case .Database:
		MainRouterState_failPendingDatabaseRequests(pm, state, message)
	case .WebAdmin:
	case:
	}
}

MainRouterState_sendDatabaseRequest :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	requestType: PendingDBRequestType,
	request: common.DatabaseQueryRequest,
) {
	requestID := MainRouterState_generateRequestID(state)
	MainRouterState_enqueueDatabaseRequest(state, requestID, peerID, requestType)
	IPC_Server_send(
		&pm.config.databaseSocket,
		pm.config.databaseFd,
		DatabaseQuery{request_id = requestID, request = request},
	)
}

MainRouterState_handleClientHello :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientHello
	if cbor.unmarshal(payload, &req) != nil {
		MainRouterState_protocolViolation(pm, state, peerID, "Invalid ClientHello payload")
		return
	}
	defer delete(req.nickname)
	if req.version != common.protocolVersion {
		MainRouterState_protocolViolation(pm, state, peerID, "Unsupported protocol version")
		return
	}
	if len(req.nickname) < 3 || len(req.nickname) > 32 {
		MainRouterState_protocolViolation(pm, state, peerID, "Invalid nickname length")
		return
	}

	session := MainRouterState_ensurePeerSession(state, peerID)
	if session.isAuthenticated ||
	   (session.transport.phase != .Disconnected && session.transport.phase != .Failed) {
		MainRouterState_protocolViolation(pm, state, peerID, "Unexpected ClientHello")
		return
	}

	RouterPeerSession_deinit(&session)
	session = RouterPeerSession_init()
	session.clientNickname = strings.clone(req.nickname)
	session.clientIdentityPublicKey = req.clientIdentityPublicKey
	session.clientEphemeralPublicKey = req.clientEphemeralPublicKey
	session.serverIdentityPublicKey = state.serverIdentityPublicKey

	sessionID, sessionIDOK := common.generateSessionID()
	if !sessionIDOK {
		MainRouterState_protocolViolation(pm, state, peerID, "Failed to generate session ID")
		return
	}
	session.sessionID = sessionID

	challenge, challengeOK := common.generateAuthChallenge()
	if !challengeOK {
		MainRouterState_protocolViolation(pm, state, peerID, "Failed to generate auth challenge")
		return
	}
	session.authChallenge = challenge

	serverEphemeralPrivateKey, serverEphemeralPublicKey, ephemeralOK :=
		common.generateKeyExchangeKeyPair()
	if !ephemeralOK {
		MainRouterState_protocolViolation(
			pm,
			state,
			peerID,
			"Failed to generate server key exchange",
		)
		return
	}
	session.serverEphemeralPrivateKey = serverEphemeralPrivateKey
	session.serverEphemeralPublicKey = serverEphemeralPublicKey
	session.transport.phase = .AwaitingChallengeResponse

	serverHelloProof := common.buildServerHelloProof(
		session.sessionID,
		session.clientNickname,
		session.clientIdentityPublicKey,
		session.clientEphemeralPublicKey,
		session.serverIdentityPublicKey,
		session.serverEphemeralPublicKey,
	)
	serverHello, serverHelloOK := common.signServerHello(
		state.serverIdentityPrivateKey,
		serverHelloProof,
	)
	if !serverHelloOK {
		MainRouterState_protocolViolation(pm, state, peerID, "Failed to sign ServerHello")
		return
	}

	MainRouterState_setPeerSession(state, peerID, session)
	if !MainRouterState_sendPeerMessage(
		pm,
		state,
		peerID,
		common.MessageType.ServerHello,
		serverHello,
	) {
		MainRouterState_protocolViolation(pm, state, peerID, "Failed to send ServerHello")
		return
	}

	if !MainRouterState_sendPeerMessage(
		pm,
		state,
		peerID,
		common.MessageType.ServerAuthChallenge,
		common.ServerAuthChallengePayload {
			sessionID = session.sessionID,
			challenge = session.authChallenge,
		},
	) {
		MainRouterState_protocolViolation(pm, state, peerID, "Failed to send auth challenge")
		return
	}
}

MainRouterState_handleClientRegister :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientRegisterRequest
	if cbor.unmarshal(payload, &req) != nil {
		MainRouterState_protocolViolation(pm, state, peerID, "Invalid ClientRegister payload")
		return
	}

	session, ok := MainRouterState_getPeerSession(state, peerID)
	if !ok || session.transport.phase != .AwaitingChallengeResponse || !session.allowRegistration {
		MainRouterState_protocolViolation(pm, state, peerID, "Unexpected ClientRegister")
		return
	}

	MainRouterState_sendPeerMessage(
		pm,
		state,
		peerID,
		common.MessageType.ServerRegisterResponse,
		common.ServerRegisterResponsePayload {
			success = false,
			message = "registration not implemented",
			userId = 0,
		},
	)
}

MainRouterState_handleClientAuthRequest :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientAuthRequestPayload
	if cbor.unmarshal(payload, &req) != nil {
		MainRouterState_protocolViolation(pm, state, peerID, "Invalid ClientAuthRequest payload")
		return
	}

	session, ok := MainRouterState_getPeerSession(state, peerID)
	if !ok || session.transport.phase != .AwaitingChallengeResponse || session.isAuthenticated {
		MainRouterState_protocolViolation(pm, state, peerID, "Unexpected ClientAuthRequest")
		return
	}

	clientAuthProof := common.buildClientAuthProof(
		session.sessionID,
		session.authChallenge,
		session.clientNickname,
		session.clientIdentityPublicKey,
		session.clientEphemeralPublicKey,
		session.serverIdentityPublicKey,
		session.serverEphemeralPublicKey,
	)
	if !common.verifyClientAuthRequestSignature(
		session.clientIdentityPublicKey,
		clientAuthProof,
		req,
	) {
		MainRouterState_sendAuthFailure(pm, state, peerID, "invalid client auth signature")
		MainRouterState_disconnectPeer(pm, peerID)
		return
	}

	sharedSecret, sharedSecretOK := common.deriveSharedSecret(
		&session.serverEphemeralPrivateKey,
		session.clientEphemeralPublicKey,
	)
	if !sharedSecretOK {
		MainRouterState_sendAuthFailure(pm, state, peerID, "failed to derive transport keys")
		MainRouterState_disconnectPeer(pm, peerID)
		return
	}

	serverHelloProof := common.buildServerHelloProof(
		session.sessionID,
		session.clientNickname,
		session.clientIdentityPublicKey,
		session.clientEphemeralPublicKey,
		session.serverIdentityPublicKey,
		session.serverEphemeralPublicKey,
	)
	transcriptHash, transcriptHashOK := common.deriveHandshakeTranscriptHash(
		serverHelloProof,
		clientAuthProof,
	)
	if !transcriptHashOK {
		MainRouterState_sendAuthFailure(pm, state, peerID, "failed to derive transcript hash")
		MainRouterState_disconnectPeer(pm, peerID)
		return
	}

	keys := common.deriveDirectionalTransportKeys(
		.Server,
		session.sessionID,
		sharedSecret,
		transcriptHash,
	)
	common.TransportState_activate(&session.transport, session.sessionID, keys, .Trusted)
	MainRouterState_setPeerSession(state, peerID, session)
	MainRouterState_sendDatabaseRequest(
		pm,
		state,
		peerID,
		.ResolveUserIdentity,
		common.DatabaseUserIdentityRequest {
			nickname = strings.clone(session.clientNickname),
			publicKey = session.clientIdentityPublicKey,
			adminPublicKey = state.adminPublicKey,
			hasAdminPublicKey = state.hasAdminPublicKey,
		},
	)
}

MainRouterState_handleClientChatMessage :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientChatMessagePayload
	err := cbor.unmarshal(payload, &req)
	defer delete(req.content)
	if err != nil {
		MainRouterState_sendProtocolError(pm, state, peerID, "Invalid ClientChatMessage payload")
		return
	}

	if req.roomId <= 0 ||
	   len(req.content) == 0 ||
	   len(req.content) > common.CHAT_MESSAGE_MAX_BYTES {
		MainRouterState_sendProtocolError(pm, state, peerID, "Invalid room chat message")
		return
	}

	session, ok := MainRouterState_getPeerSession(state, peerID)
	if !ok || !session.isAuthenticated {
		MainRouterState_sendProtocolError(pm, state, peerID, "Unauthenticated chat message")
		return
	}

	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabasePostRoomChatMessageRequest {
			roomId = req.roomId,
			senderId = session.authenticatedUserID,
			content = strings.clone(req.content),
		},
		PendingDBRequest{requestType = .PostChatMessage, roomID = req.roomId},
	)
}

MainRouterState_handleClientListRooms :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientListRoomsPayload
	if cbor.unmarshal(payload, &req) != nil {
		MainRouterState_sendProtocolError(pm, state, peerID, "Invalid ClientListRooms payload")
		return
	}
	session, ok := MainRouterState_getPeerSession(state, peerID)
	if !ok || !session.isAuthenticated {
		MainRouterState_sendProtocolError(pm, state, peerID, "Unauthenticated room list request")
		return
	}
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseRoomListRequest{userId = session.authenticatedUserID},
		PendingDBRequest{requestType = .ListRooms},
	)
}

MainRouterState_handleClientFetchRoomHistory :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientFetchRoomHistoryPayload
	if cbor.unmarshal(payload, &req) != nil ||
	   req.roomId <= 0 ||
	   req.beforeMessageID < 0 ||
	   req.limit < 1 ||
	   req.limit > common.HISTORY_PAGE_MAX_MESSAGES {
		MainRouterState_sendProtocolError(pm, state, peerID, "Invalid room history request")
		return
	}
	session, ok := MainRouterState_getPeerSession(state, peerID)
	if !ok || !session.isAuthenticated {
		MainRouterState_sendProtocolError(
			pm,
			state,
			peerID,
			"Unauthenticated room history request",
		)
		return
	}
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseRoomHistoryRequest {
			roomId = req.roomId,
			userId = session.authenticatedUserID,
			beforeMessageID = req.beforeMessageID,
			limit = req.limit,
		},
		PendingDBRequest{requestType = .GetRoomHistory, roomID = req.roomId},
	)
}

MainRouterState_enqueueAdminCheck :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	userID: int,
	pending: PendingDBRequest,
) {
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseUserServerAdminRequest{userId = userID},
		pending,
	)
}

MainRouterState_authenticatedUserForAdminRequest :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
) -> (
	int,
	bool,
) {
	session, ok := MainRouterState_getPeerSession(state, peerID)
	if !ok || !session.isAuthenticated {
		MainRouterState_sendProtocolError(pm, state, peerID, "Unauthenticated admin request")
		return 0, false
	}
	return session.authenticatedUserID, true
}

MainRouterState_hasValidRoomMetadata :: proc(name: string, description: string) -> bool {
	return len(name) >= 1 && len(name) <= 64 && len(description) <= 256
}

MainRouterState_handleClientCreateRoom :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientCreateRoomPayload
	if cbor.unmarshal(payload, &req) != nil ||
	   !MainRouterState_hasValidRoomMetadata(req.name, req.description) {
		delete(req.name)
		delete(req.description)
		MainRouterState_sendProtocolError(pm, state, peerID, "Invalid room metadata")
		return
	}
	defer delete(req.name)
	defer delete(req.description)
	userID, ok := MainRouterState_authenticatedUserForAdminRequest(pm, state, peerID)
	if !ok {
		return
	}
	MainRouterState_enqueueAdminCheck(
		pm,
		state,
		peerID,
		userID,
		PendingDBRequest {
			requestType = .CheckAdminCreateRoom,
			name = strings.clone(req.name),
			description = strings.clone(req.description),
		},
	)
}

MainRouterState_handleClientEditRoom :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientEditRoomPayload
	if cbor.unmarshal(payload, &req) != nil ||
	   req.roomId <= 0 ||
	   !MainRouterState_hasValidRoomMetadata(req.name, req.description) {
		delete(req.name)
		delete(req.description)
		MainRouterState_sendProtocolError(pm, state, peerID, "Invalid room edit")
		return
	}
	defer delete(req.name)
	defer delete(req.description)
	userID, ok := MainRouterState_authenticatedUserForAdminRequest(pm, state, peerID)
	if !ok {
		return
	}
	MainRouterState_enqueueAdminCheck(
		pm,
		state,
		peerID,
		userID,
		PendingDBRequest {
			requestType = .CheckAdminEditRoom,
			roomID = req.roomId,
			name = strings.clone(req.name),
			description = strings.clone(req.description),
		},
	)
}

MainRouterState_handleClientDeleteRoom :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientDeleteRoomPayload
	if cbor.unmarshal(payload, &req) != nil || req.roomId <= 0 {
		MainRouterState_sendProtocolError(pm, state, peerID, "Invalid room delete")
		return
	}
	userID, ok := MainRouterState_authenticatedUserForAdminRequest(pm, state, peerID)
	if !ok {
		return
	}
	MainRouterState_enqueueAdminCheck(
		pm,
		state,
		peerID,
		userID,
		PendingDBRequest{requestType = .CheckAdminDeleteRoom, roomID = req.roomId},
	)
}

MainRouterState_handleClientRoomMembershipMutation :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
	requestType: PendingDBRequestType,
) {
	req: common.ClientRoomMembershipPayload
	if cbor.unmarshal(payload, &req) != nil || req.roomId <= 0 || req.userId <= 0 {
		MainRouterState_sendProtocolError(pm, state, peerID, "Invalid room membership request")
		return
	}
	userID, ok := MainRouterState_authenticatedUserForAdminRequest(pm, state, peerID)
	if !ok {
		return
	}
	MainRouterState_enqueueAdminCheck(
		pm,
		state,
		peerID,
		userID,
		PendingDBRequest {
			requestType = requestType,
			roomID = req.roomId,
			targetUserID = req.userId,
		},
	)
}

MainRouterState_hasRecipientUserID :: proc(userIDs: []int, userID: int) -> bool {
	for candidateUserID in userIDs {
		if candidateUserID == userID {
			return true
		}
	}
	return false
}

MainRouterState_sendMessageToUserID :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	userID: int,
	messageType: common.MessageType,
	payload: any,
) {
	for recipientPeerID, recipientSession in state.peerSessions {
		if recipientSession.isAuthenticated && recipientSession.authenticatedUserID == userID {
			MainRouterState_sendPeerMessage(pm, state, recipientPeerID, messageType, payload)
		}
	}
}

MainRouterState_dispatchApplicationPacket :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	packet: common.Packet,
) {
	#partial switch packet.messageType {
	case .ClientChatMessage:
		MainRouterState_handleClientChatMessage(pm, state, peerID, packet.payload)
	case .ClientListRooms:
		MainRouterState_handleClientListRooms(pm, state, peerID, packet.payload)
	case .ClientFetchRoomHistory:
		MainRouterState_handleClientFetchRoomHistory(pm, state, peerID, packet.payload)
	case .ClientCreateRoom:
		MainRouterState_handleClientCreateRoom(pm, state, peerID, packet.payload)
	case .ClientEditRoom:
		MainRouterState_handleClientEditRoom(pm, state, peerID, packet.payload)
	case .ClientDeleteRoom:
		MainRouterState_handleClientDeleteRoom(pm, state, peerID, packet.payload)
	case .ClientAddRoomMember:
		MainRouterState_handleClientRoomMembershipMutation(
			pm,
			state,
			peerID,
			packet.payload,
			.CheckAdminAddRoomMember,
		)
	case .ClientRemoveRoomMember:
		MainRouterState_handleClientRoomMembershipMutation(
			pm,
			state,
			peerID,
			packet.payload,
			.CheckAdminRemoveRoomMember,
		)
	case .ClientDirectMessage:
		MainRouterState_handleClientDirectMessage(pm, state, peerID, packet.payload)
	case .ClientFetchDirectHistory:
		MainRouterState_handleClientFetchDirectHistory(pm, state, peerID, packet.payload)
	case .ClientListDirectConversations:
		MainRouterState_handleClientListDirectConversations(pm, state, peerID, packet.payload)
	case .ClientUserList:
		MainRouterState_handleClientListUsers(pm, state, peerID, packet.payload)
	case .ClientStoreFile:
		req: common.ClientStoreFileRequest
		err := cbor.unmarshal(packet.payload, &req)
		defer delete(req.filename)
		defer delete(req.content)
		if err != nil || len(req.filename) == 0 || len(req.content) == 0 {
			MainRouterState_sendPeerMessage(
				pm,
				state,
				peerID,
				common.MessageType.ServerStoreFileResponse,
				common.ServerStoreFileResult {
					success = false,
					message = "invalid payload",
					hashedFilename = "",
				},
			)
			return
		}

		hashedName, storeMessage, ok := saveFile(pm.config, req.content, req.filename, int(peerID))
		if !ok {
			MainRouterState_sendPeerMessage(
				pm,
				state,
				peerID,
				common.MessageType.ServerStoreFileResponse,
				common.ServerStoreFileResult {
					success = false,
					message = storeMessage,
					hashedFilename = "",
				},
			)
			return
		}
		defer delete(hashedName)

		MainRouterState_sendPeerMessage(
			pm,
			state,
			peerID,
			common.MessageType.ServerStoreFileResponse,
			common.ServerStoreFileResult {
				success = true,
				message = storeMessage,
				hashedFilename = strings.clone(hashedName),
			},
		)
	case:
		MainRouterState_sendProtocolError(pm, state, peerID, "Unsupported message type")
	}
}

MainRouterState_handleEncryptedPacket :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	packet: common.Packet,
) {
	if packet.messageType != .EncryptedPacket {
		MainRouterState_protocolViolation(
			pm,
			state,
			peerID,
			"Encrypted transport required after authentication",
		)
		return
	}

	session, ok := MainRouterState_getPeerSession(state, peerID)
	if !ok || !session.isAuthenticated || !common.TransportState_canEncrypt(&session.transport) {
		MainRouterState_protocolViolation(pm, state, peerID, "Unauthenticated encrypted packet")
		return
	}

	innerPacket, openOK := common.openPacketForSession(&session.transport, packet)
	if !openOK {
		MainRouterState_protocolViolation(pm, state, peerID, "Failed to open encrypted packet")
		return
	}
	defer delete(innerPacket.payload)

	MainRouterState_setPeerSession(state, peerID, session)
	MainRouterState_dispatchApplicationPacket(pm, state, peerID, innerPacket)
}

MainRouterState_handlePlaintextPacket :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	packet: common.Packet,
) {
	#partial switch packet.messageType {
	case .ClientHello:
		MainRouterState_handleClientHello(pm, state, peerID, packet.payload)
	case .ClientRegister:
		MainRouterState_handleClientRegister(pm, state, peerID, packet.payload)
	case .ClientAuthRequest:
		MainRouterState_handleClientAuthRequest(pm, state, peerID, packet.payload)
	case .EncryptedPacket:
		MainRouterState_protocolViolation(
			pm,
			state,
			peerID,
			"Encrypted packet received before auth",
		)
	case:
		MainRouterState_protocolViolation(pm, state, peerID, "Unexpected plaintext message")
	}
}

MainRouterState_handleNetworkDataReceived :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	msg: NetworkDataReceived,
) {
	if msg.channel != .Chat {
		return
	}
	if len(msg.data) == 0 {
		return
	}

	packet: common.Packet
	packetErr := cbor.unmarshal(msg.data, &packet)
	if packetErr != nil {
		MainRouterState_protocolViolation(pm, state, msg.peerId, "Invalid CBOR packet")
		return
	}
	defer delete(packet.payload)

	session, ok := MainRouterState_getPeerSession(state, msg.peerId)
	if !ok {
		session = MainRouterState_ensurePeerSession(state, msg.peerId)
	}

	if session.isAuthenticated {
		MainRouterState_handleEncryptedPacket(pm, state, msg.peerId, packet)
		return
	}

	MainRouterState_handlePlaintextPacket(pm, state, msg.peerId, packet)
}

// Reports a failed database response to the peer and returns true. A successful response with
// the wrong result variant is a router bug, reported the same way rather than crashing.
MainRouterState_databaseFailed :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	response: common.DatabaseQueryResponse,
	resultOK: bool,
) -> bool {
	if !response.success {
		MainRouterState_sendProtocolError(pm, state, peerID, response.message)
		return true
	}
	if !resultOK {
		MainRouterState_sendProtocolError(pm, state, peerID, "Unexpected database result")
		return true
	}
	return false
}

MainRouterState_isAdminResponse :: proc(response: common.DatabaseQueryResponse) -> bool {
	result, ok := response.result.(common.DatabaseUserServerAdminResult)
	return response.success && ok && result.isAdmin
}

MainRouterState_sendAdminRequired :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
) {
	MainRouterState_sendProtocolError(pm, state, peerID, "Admin permission required")
}

MainRouterState_handleDatabaseResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	requestID: u64,
	response: common.DatabaseQueryResponse,
) {
	defer IPC__database_query_response_deinit(response)
	request, ok := MainRouterState_getDatabaseRequest(state, requestID)
	if !ok {
		fmt.printfln("[Main] Received database response for unknown request ID %d", requestID)
		return
	}
	defer PendingDBRequest_deinit(request)

	switch request.requestType {
	case .ResolveUserIdentity:
		identity, identityOK := response.result.(common.DatabaseUserIdentityResult)
		if !response.success || !identityOK || identity.userId <= 0 {
			MainRouterState_sendAuthFailure(
				pm,
				state,
				request.peerID,
				"user identity is unavailable",
			)
			if session, sessionOK := MainRouterState_getPeerSession(state, request.peerID);
			   sessionOK {
				session.transport.phase = .Failed
				MainRouterState_setPeerSession(state, request.peerID, session)
			}
			MainRouterState_disconnectPeer(pm, request.peerID)
			return
		}

		MainRouterState_completeAuthentication(pm, state, request.peerID, identity.userId)
	case .ListRooms:
		roomList, roomListOK := response.result.(common.DatabaseRoomListResult)
		if MainRouterState_databaseFailed(pm, state, request.peerID, response, roomListOK) {
			return
		}
		MainRouterState_sendPeerMessage(
			pm,
			state,
			request.peerID,
			.ServerListRooms,
			common.ServerListRoomsPayload{rooms = roomList.rooms},
		)
	case .PostChatMessage:
		posted, postedOK := response.result.(common.DatabasePostRoomChatMessageResult)
		if MainRouterState_databaseFailed(pm, state, request.peerID, response, postedOK) {
			return
		}
		if !posted.isMember {
			MainRouterState_sendProtocolError(pm, state, request.peerID, "Not a room member")
			return
		}
		chatPayload := common.ServerChatMessagePayload {
			id             = posted.storedMessage.id,
			senderId       = posted.storedMessage.senderId,
			senderNickname = posted.storedMessage.senderNickname,
			roomId         = posted.storedMessage.roomId,
			timestamp      = posted.storedMessage.timestamp,
			content        = posted.storedMessage.content,
		}
		for recipientPeerID, recipientSession in state.peerSessions {
			if recipientSession.isAuthenticated &&
			   MainRouterState_hasRecipientUserID(
				   posted.recipientUserIDs[:],
				   recipientSession.authenticatedUserID,
			   ) {
				MainRouterState_sendPeerMessage(
					pm,
					state,
					recipientPeerID,
					.ServerChatMessage,
					chatPayload,
				)
			}
		}
	case .GetRoomHistory:
		history, historyOK := response.result.(common.DatabaseRoomHistoryResult)
		if MainRouterState_databaseFailed(pm, state, request.peerID, response, historyOK) {
			return
		}
		if !history.isMember {
			MainRouterState_sendProtocolError(pm, state, request.peerID, "Not a room member")
			return
		}
		MainRouterState_sendPeerMessage(
			pm,
			state,
			request.peerID,
			.ServerRoomHistory,
			common.ServerRoomHistoryPayload {
				roomId = request.roomID,
				messages = history.messages,
				hasOlder = history.hasOlder,
			},
		)
	case .CheckAdminCreateRoom:
		if !MainRouterState_isAdminResponse(response) {
			MainRouterState_sendAdminRequired(pm, state, request.peerID)
			return
		}
		creatorSession, creatorOK := MainRouterState_getPeerSession(state, request.peerID)
		if !creatorOK || !creatorSession.isAuthenticated {
			MainRouterState_sendProtocolError(pm, state, request.peerID, "Admin session expired")
			return
		}
		MainRouterState_enqueueChannelDatabaseRequest(
			pm,
			state,
			request.peerID,
			common.DatabaseCreateRoomRequest {
				creatorUserId = creatorSession.authenticatedUserID,
				name = strings.clone(request.name),
				description = strings.clone(request.description),
			},
			PendingDBRequest {
				requestType = .CreateRoom,
				targetUserID = creatorSession.authenticatedUserID,
			},
		)
	case .CreateRoom:
		mutation, mutationOK := response.result.(common.DatabaseRoomMutationResult)
		if MainRouterState_databaseFailed(pm, state, request.peerID, response, mutationOK) {
			return
		}
		MainRouterState_sendPeerMessage(
			pm,
			state,
			request.peerID,
			.ServerCreateRoom,
			common.ServerRoomMutationPayload {
				room = mutation.room,
				roomId = mutation.room.id,
				userId = request.targetUserID,
				changed = mutation.changed,
			},
		)
		// The create statement made every account a member, so every connected session must
		// refresh its room list, not only the creator's.
		for recipientPeerID, recipientSession in state.peerSessions {
			if recipientSession.isAuthenticated {
				MainRouterState_sendPeerMessage(
					pm,
					state,
					recipientPeerID,
					.ServerRoomMembershipChanged,
					common.ServerRoomMembershipChangedPayload {
						roomId = mutation.room.id,
						joined = true,
					},
				)
			}
		}
	case .CheckAdminEditRoom:
		if !MainRouterState_isAdminResponse(response) {
			MainRouterState_sendAdminRequired(pm, state, request.peerID)
			return
		}
		MainRouterState_enqueueChannelDatabaseRequest(
			pm,
			state,
			request.peerID,
			common.DatabaseEditRoomRequest {
				roomId = request.roomID,
				name = strings.clone(request.name),
				description = strings.clone(request.description),
			},
			PendingDBRequest{requestType = .EditRoom, roomID = request.roomID},
		)
	case .EditRoom:
		mutation, mutationOK := response.result.(common.DatabaseRoomMutationResult)
		if MainRouterState_databaseFailed(pm, state, request.peerID, response, mutationOK) {
			return
		}
		if !mutation.changed {
			MainRouterState_sendProtocolError(pm, state, request.peerID, "Room not found")
			return
		}
		MainRouterState_sendPeerMessage(
			pm,
			state,
			request.peerID,
			.ServerEditRoom,
			common.ServerRoomMutationPayload {
				room = mutation.room,
				roomId = request.roomID,
				changed = true,
			},
		)
		MainRouterState_enqueueChannelDatabaseRequest(
			pm,
			state,
			request.peerID,
			common.DatabaseRoomMemberListRequest{roomId = request.roomID},
			PendingDBRequest {
				requestType = .ListEditRoomRecipients,
				roomID = request.roomID,
				name = strings.clone(mutation.room.name),
				description = strings.clone(mutation.room.description),
			},
		)
	case .ListEditRoomRecipients:
		members, membersOK := response.result.(common.DatabaseRoomMemberListResult)
		if MainRouterState_databaseFailed(pm, state, request.peerID, response, membersOK) {
			return
		}
		editPayload := common.ServerRoomMutationPayload {
			room = {id = request.roomID, name = request.name, description = request.description},
			roomId = request.roomID,
			changed = true,
		}
		for recipientPeerID, recipientSession in state.peerSessions {
			if recipientSession.isAuthenticated &&
			   recipientPeerID != request.peerID &&
			   MainRouterState_hasRecipientUserID(
				   members.userIDs[:],
				   recipientSession.authenticatedUserID,
			   ) {
				MainRouterState_sendPeerMessage(
					pm,
					state,
					recipientPeerID,
					.ServerEditRoom,
					editPayload,
				)
			}
		}
	case .CheckAdminDeleteRoom:
		if !MainRouterState_isAdminResponse(response) {
			MainRouterState_sendAdminRequired(pm, state, request.peerID)
			return
		}
		MainRouterState_enqueueChannelDatabaseRequest(
			pm,
			state,
			request.peerID,
			common.DatabaseRoomMemberListRequest{roomId = request.roomID},
			PendingDBRequest{requestType = .ListDeleteRoomRecipients, roomID = request.roomID},
		)
	case .ListDeleteRoomRecipients:
		members, membersOK := response.result.(common.DatabaseRoomMemberListResult)
		if MainRouterState_databaseFailed(pm, state, request.peerID, response, membersOK) {
			return
		}
		// Capture recipients before the delete cascades their memberships away.
		memberUserIDs := make([dynamic]int, 0, len(members.userIDs))
		append(&memberUserIDs, ..members.userIDs[:])
		MainRouterState_enqueueChannelDatabaseRequest(
			pm,
			state,
			request.peerID,
			common.DatabaseDeleteRoomRequest{roomId = request.roomID},
			PendingDBRequest {
				requestType = .DeleteRoom,
				roomID = request.roomID,
				recipientUserIDs = memberUserIDs,
			},
		)
	case .DeleteRoom:
		mutation, mutationOK := response.result.(common.DatabaseRoomMutationResult)
		if MainRouterState_databaseFailed(pm, state, request.peerID, response, mutationOK) {
			return
		}
		if !mutation.changed {
			MainRouterState_sendProtocolError(pm, state, request.peerID, "Room not found")
			return
		}
		deletePayload := common.ServerRoomMutationPayload {
			roomId  = request.roomID,
			changed = true,
		}
		for recipientPeerID, recipientSession in state.peerSessions {
			if recipientSession.isAuthenticated &&
			   (recipientPeerID == request.peerID ||
					   MainRouterState_hasRecipientUserID(
						   request.recipientUserIDs[:],
						   recipientSession.authenticatedUserID,
					   )) {
				MainRouterState_sendPeerMessage(
					pm,
					state,
					recipientPeerID,
					.ServerDeleteRoom,
					deletePayload,
				)
			}
		}
	case .CheckAdminAddRoomMember:
		if !MainRouterState_isAdminResponse(response) {
			MainRouterState_sendAdminRequired(pm, state, request.peerID)
			return
		}
		MainRouterState_enqueueChannelDatabaseRequest(
			pm,
			state,
			request.peerID,
			common.DatabaseAddRoomMemberRequest {
				roomId = request.roomID,
				userId = request.targetUserID,
			},
			PendingDBRequest {
				requestType = .AddRoomMember,
				roomID = request.roomID,
				targetUserID = request.targetUserID,
			},
		)
	case .AddRoomMember:
		mutation, mutationOK := response.result.(common.DatabaseRoomMutationResult)
		if MainRouterState_databaseFailed(pm, state, request.peerID, response, mutationOK) {
			return
		}
		MainRouterState_sendPeerMessage(
			pm,
			state,
			request.peerID,
			.ServerRoomMemberAdded,
			common.ServerRoomMutationPayload {
				roomId = request.roomID,
				userId = request.targetUserID,
				changed = mutation.changed,
			},
		)
		if mutation.changed {
			MainRouterState_sendMessageToUserID(
				pm,
				state,
				request.targetUserID,
				.ServerRoomMembershipChanged,
				common.ServerRoomMembershipChangedPayload{roomId = request.roomID, joined = true},
			)
		}
	case .CheckAdminRemoveRoomMember:
		if !MainRouterState_isAdminResponse(response) {
			MainRouterState_sendAdminRequired(pm, state, request.peerID)
			return
		}
		MainRouterState_enqueueChannelDatabaseRequest(
			pm,
			state,
			request.peerID,
			common.DatabaseRemoveRoomMemberRequest {
				roomId = request.roomID,
				userId = request.targetUserID,
			},
			PendingDBRequest {
				requestType = .RemoveRoomMember,
				roomID = request.roomID,
				targetUserID = request.targetUserID,
			},
		)
	case .RemoveRoomMember:
		mutation, mutationOK := response.result.(common.DatabaseRoomMutationResult)
		if MainRouterState_databaseFailed(pm, state, request.peerID, response, mutationOK) {
			return
		}
		MainRouterState_sendPeerMessage(
			pm,
			state,
			request.peerID,
			.ServerRoomMemberRemoved,
			common.ServerRoomMutationPayload {
				roomId = request.roomID,
				userId = request.targetUserID,
				changed = mutation.changed,
			},
		)
		if mutation.changed {
			MainRouterState_sendMessageToUserID(
				pm,
				state,
				request.targetUserID,
				.ServerRoomMembershipChanged,
				common.ServerRoomMembershipChangedPayload{roomId = request.roomID, joined = false},
			)
		}
	case .PostDirectMessage:
		MainRouterState_handlePostDirectMessageResult(pm, state, request, response)
	case .GetDirectHistory:
		MainRouterState_handleDirectHistoryResult(pm, state, request, response)
	case .ListDirectConversations:
		MainRouterState_handleDirectConversationListResult(pm, state, request, response)
	case .ListUsers:
		MainRouterState_handleUserDirectoryResult(pm, state, request, response)
	}
}

main :: proc() {

	fmt.println("=== HayChat Server - Threaded Architecture ===")

	config, configErr := loadConfig()
	if len(configErr) > 0 {
		fmt.eprintfln("[Startup] %s", configErr)
		delete(configErr)
		return
	}
	fmt.println("Configuration loaded:")
	fmt.printfln("  Web Admin: %s:%d", config.webAdminHost, config.webAdminPort)
	fmt.printfln(
		"  Database: %s@%s:%d/%s",
		config.databaseUser,
		config.databaseURL,
		config.databasePort,
		config.databaseName,
	)
	fmt.printfln(
		"  Max Restarts: %d (backoff: %v-%v)",
		config.maxRestarts,
		config.restartBackoffMin,
		config.restartBackoffMax,
	)

	config.networkSocketName = fmt.aprintf("%s_network", SERVER_SOCKET)
	config.webAdminSocketName = fmt.aprintf("%s_webadmin", SERVER_SOCKET)
	config.databaseSocketName = fmt.aprintf("%s_database", SERVER_SOCKET)

	pm := initProcessManager(&config)

	mainInterruptRequested = false
	mainInterruptShutdownQueued = false
	registerMainInterruptHandler()

	fmt.println("=== Starting Service Threads ===")
	if !spawnProcess(&pm, .Database) {
		fmt.println("[Database] Failed to start database service thread")
		pm.shouldShutdown = true
		shutdownAllProcesses(&pm)
		return
	}
	if databaseStartupErr := waitForDatabaseStartupAck(&pm); len(databaseStartupErr) > 0 {
		fmt.eprintfln("[Startup] %s", databaseStartupErr)
		pm.shouldShutdown = true
		shutdownAllProcesses(&pm)
		delete(databaseStartupErr)
		return
	}
	if !spawnProcess(&pm, .Network) {
		fmt.println("[Network] Failed to start network service thread")
		pm.shouldShutdown = true
		shutdownAllProcesses(&pm)
		return
	}
	if !spawnProcess(&pm, .WebAdmin) {
		fmt.println("[WebAdmin] Failed to start web admin service thread")
		pm.shouldShutdown = true
		shutdownAllProcesses(&pm)
		return
	}

	fmt.println("=== Server Running ===")
	fmt.println("Main thread is supervising network, web admin, and database threads")

	mainLoop(&pm)

	fmt.println("=== Server Shutdown Complete ===")
}

waitForDatabaseStartupAck :: proc(pm: ^ProcessManager) -> string {
	return waitForDatabaseStartupAckWithTimeout(pm, DATABASE_STARTUP_ACK_TIMEOUT)
}

waitForDatabaseStartupAckWithTimeout :: proc(
	pm: ^ProcessManager,
	timeout: time.Duration,
) -> string {
	start := time.now()
	for time.since(start) < timeout {
		if mainInterruptRequested {
			return strings.clone("startup interrupted before database became ready")
		}

		msg, err := IPC_Client_poll(pm.config.mainFd)
		if err != nil {
			sync.mutex_lock(&pm.processMutex)
			databaseRunning := pm.databaseProcess.isRunning
			sync.mutex_unlock(&pm.processMutex)
			if !databaseRunning {
				return fmt.aprintf(
					"database startup failed: worker exited before reporting readiness for %s@%s:%d/%s",
					pm.config.databaseUser,
					pm.config.databaseURL,
					pm.config.databasePort,
					pm.config.databaseName,
				)
			}

			IPC_Client_wait(pm.config.mainFd, MAIN_IDLE_WAIT)
			continue
		}

		#partial switch m in msg {
		case DatabaseStartupReady:
			return ""
		case DatabaseStartupFailed:
			return m.error
		case ProcessError:
			return m.error
		case ProcessShutdown:
			return strings.clone("database startup interrupted by shutdown")
		case Wake:
		case:
		}
	}

	return fmt.aprintf(
		"database startup timed out after %v waiting for readiness from %s@%s:%d/%s",
		timeout,
		pm.config.databaseUser,
		pm.config.databaseURL,
		pm.config.databasePort,
		pm.config.databaseName,
	)
}

// Each mainLoop pass handles at most this many IPC messages before it runs the supervisor
// checks, and waits at most MAIN_IDLE_WAIT for a message when the queue was empty.
MAIN_IPC_DRAIN_LIMIT :: 1024
MAIN_IDLE_WAIT :: 5 * time.Millisecond

@(private)
mainLoop :: proc(pm: ^ProcessManager) {
	running := true
	routerState := MainRouterState_init(pm)
	defer MainRouterState_deinit(&routerState)

	for running {
		if mainInterruptRequested {
			queueMainInterruptShutdown(pm)
		}

		// Handle everything that is queued: one message per pass let fan-out and database
		// results back up behind the supervisor checks and the yield.
		processed := 0
		for running && processed < MAIN_IPC_DRAIN_LIMIT {
			msg, err := IPC_Client_poll(pm.config.mainFd)
			if err != nil {
				break
			}
			processed += 1
			running = mainLoopHandleMessage(pm, &routerState, msg)
		}

		if !pm.shouldShutdown {
			if ProcessManager_shouldScheduleRestart(pm, .Network) {
				MainRouterState_prepareForProcessStop(
					pm,
					&routerState,
					.Network,
					"network service restarted",
				)
				restartProcess(pm, .Network)
			}
			if ProcessManager_shouldScheduleRestart(pm, .WebAdmin) {
				restartProcess(pm, .WebAdmin)
			}
			if ProcessManager_shouldScheduleRestart(pm, .Database) {
				MainRouterState_prepareForProcessStop(
					pm,
					&routerState,
					.Database,
					"database service restarted",
				)
				restartProcess(pm, .Database)
			}
			ProcessManager_pumpRestarts(pm)
		}

		// Sleep on the queue instead of spinning; a push wakes the wait at once.
		if running && processed == 0 {
			IPC_Client_wait(pm.config.mainFd, MAIN_IDLE_WAIT)
		}
	}

	shutdownAllProcesses(pm)
}

// mainLoopHandleMessage routes one message popped from the main queue. It returns false when
// the main loop should stop.
mainLoopHandleMessage :: proc(
	pm: ^ProcessManager,
	routerState: ^MainRouterState,
	msg: Message,
) -> bool {
	switch m in msg {
	case NetworkSendData, NetworkBroadcast, NetworkDisconnectPeer:
	// Commands are generated by main and should not loop back here.
	case NetworkPeerConnected:
		routerState.connectedPeers[m.peerId] = true
		MainRouterState_setPeerSession(routerState, m.peerId, RouterPeerSession_init())
	case NetworkPeerDisconnected:
		MainRouterState_handlePeerDisconnected(pm, routerState, m.peerId)
	case NetworkDataReceived:
		MainRouterState_handleNetworkDataReceived(pm, routerState, m)
		delete(m.data)
	case AdminQueryStatus:
		uptime := i64(time.duration_seconds(time.since(pm.startTime)))
		sync.mutex_lock(&pm.processMutex)
		response := AdminQueryStatusResponse {
			uptime                 = uptime,
			connectedPeers         = len(routerState.connectedPeers),
			networkRunning         = pm.networkProcess.isRunning,
			webAdminRunning        = pm.webAdminProcess.isRunning,
			databaseRunning        = pm.databaseProcess.isRunning,
			networkRestartPending  = pm.networkProcess.restartPending,
			webAdminRestartPending = pm.webAdminProcess.restartPending,
			databaseRestartPending = pm.databaseProcess.restartPending,
			shutdownRequested      = pm.shouldShutdown,
		}
		sync.mutex_unlock(&pm.processMutex)
		IPC_Server_send(&pm.config.webAdminSocket, pm.config.webAdminFd, response)
	case AdminQueryStatusResponse, AdminGetPeersResponse, AdminGetLogsResponse:
	// Responses are consumed by web admin.
	case AdminGetPeers:
		peerSnapshots := make([dynamic]AdminPeerInfo, 0, len(routerState.connectedPeers))
		for peerID in routerState.connectedPeers {
			session, ok := MainRouterState_getPeerSession(routerState, peerID)
			if !ok {
				append(&peerSnapshots, AdminPeerInfo{peerId = peerID})
				continue
			}
			append(
				&peerSnapshots,
				AdminPeerInfo {
					peerId = peerID,
					isAuthenticated = session.isAuthenticated,
					authenticatedId = session.authenticatedUserID,
				},
			)
		}
		IPC_Server_send(
			&pm.config.webAdminSocket,
			pm.config.webAdminFd,
			AdminGetPeersResponse{peers = peerSnapshots[:]},
		)
	case AdminGetLogs:
		sync.mutex_lock(&pm.processMutex)
		logs := make([dynamic]string, 0, 4)
		append(
			&logs,
			fmt.aprintf(
				"network running=%v restart_pending=%v",
				pm.networkProcess.isRunning,
				pm.networkProcess.restartPending,
			),
		)
		append(
			&logs,
			fmt.aprintf(
				"web_admin running=%v restart_pending=%v",
				pm.webAdminProcess.isRunning,
				pm.webAdminProcess.restartPending,
			),
		)
		append(
			&logs,
			fmt.aprintf(
				"database running=%v restart_pending=%v",
				pm.databaseProcess.isRunning,
				pm.databaseProcess.restartPending,
			),
		)
		append(&logs, fmt.aprintf("shutdown_requested=%v", pm.shouldShutdown))
		sync.mutex_unlock(&pm.processMutex)
		IPC_Server_send(
			&pm.config.webAdminSocket,
			pm.config.webAdminFd,
			AdminGetLogsResponse{logs = logs[:]},
		)
	case DatabaseQuery:
		IPC_Server_send(&pm.config.databaseSocket, pm.config.databaseFd, m)
	case DatabaseQueryResult:
		MainRouterState_handleDatabaseResult(pm, routerState, m.request_id, m.response)
	case DatabaseError:
		MainRouterState_handleDatabaseResult(
			pm,
			routerState,
			m.request_id,
			common.DatabaseQueryResponse{success = false, message = m.error},
		)
	case DatabaseStartupReady, DatabaseStartupFailed:
	// Startup-only coordination messages are consumed before the main loop starts.
	case ProcessShutdown:
		sync.mutex_lock(&pm.processMutex)
		pm.shouldShutdown = true
		sync.mutex_unlock(&pm.processMutex)
		MainRouterState_failPendingDatabaseRequests(
			pm,
			routerState,
			"server shutting down",
		)
		return false
	case ProcessRestart:
		MainRouterState_prepareForProcessStop(
			pm,
			routerState,
			.Database,
			"database restarting",
		)
		MainRouterState_prepareForProcessStop(
			pm,
			routerState,
			.Network,
			"server restarting",
		)
		restartProcess(pm, .Network)
		restartProcess(pm, .WebAdmin)
		restartProcess(pm, .Database)
	case Wake:
		IPC_Server_send(&pm.config.webAdminSocket, pm.config.webAdminFd, Wake{})
	case ProcessError:
		fmt.printfln("[Main] Process error: %s\n", m.error)
	case:
	}
	return true
}
