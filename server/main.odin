package server

import "../common"
import "base:runtime"
import "core:c/libc"
import "core:crypto/ecdh"
import "core:encoding/cbor"
import "core:fmt"
import "core:strings"
import "core:sync"

import "core:thread"
import "core:time"

PendingDBRequestType :: enum {
	AuthLookup,
	Generic,
}

PendingDBRequest :: struct {
	requestID:   u64,
	peerID:      u32,
	requestType: PendingDBRequestType,
}

RouterPeerSession :: struct {
	transport:                 common.TransportState,
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

RouterPeerSession_init :: proc() -> RouterPeerSession {
	return RouterPeerSession {
		transport = common.TransportState_init(.Server),
		allowRegistration = true,
	}
}

MainRouterState :: struct {
	connectedPeers:           map[u32]bool,
	peerSessions:             map[u32]RouterPeerSession,
	pendingDatabaseRequests:  map[u64]PendingDBRequest,
	nextRequestID:            u64,
	serverIdentityPrivateKey: common.IdentityPrivateKeyBytes,
	serverIdentityPublicKey:  common.IdentityPublicKeyBytes,
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

	return state
}

MainRouterState_deinit :: proc(state: ^MainRouterState) {
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
		session.transport.phase = .Failed
		session.isAuthenticated = false
		MainRouterState_setPeerSession(state, peerID, session)
	}
	MainRouterState_disconnectPeer(pm, peerID)
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
		case .AuthLookup:
			MainRouterState_sendPeerMessage(
				pm,
				state,
				request.peerID,
				common.MessageType.ServerAuthLookupResponse,
				common.ServerAuthLookupResult{success = false, message = message, result = ""},
			)
		case .Generic:
			MainRouterState_sendPeerMessage(
				pm,
				state,
				request.peerID,
				common.MessageType.ServerDatabaseQueryResponse,
				common.ServerDatabaseQueryResult{success = false, message = message, result = ""},
			)
		case:
		}
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

MainRouterState_handleClientAuthLookupPacket :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientAuthLookupRequest
	err := cbor.unmarshal(payload, &req)
	defer delete(req.nickname)
	if err != nil {
		MainRouterState_sendPeerMessage(
			pm,
			state,
			peerID,
			common.MessageType.ServerAuthLookupResponse,
			common.ServerAuthLookupResult {
				success = false,
				message = "invalid payload",
				result = "",
			},
		)
		return
	}

	if len(req.nickname) < 3 || len(req.nickname) > 32 {
		MainRouterState_sendPeerMessage(
			pm,
			state,
			peerID,
			common.MessageType.ServerAuthLookupResponse,
			common.ServerAuthLookupResult {
				success = false,
				message = "invalid nickname length",
				result = "",
			},
		)
		return
	}

	MainRouterState_sendDatabaseRequest(
		pm,
		state,
		peerID,
		.AuthLookup,
		common.DatabaseQueryRequest {
			queryType = .AuthLookupByNickname,
			authLookup = {nickname = strings.clone(req.nickname)},
		},
	)
}

MainRouterState_handleClientDatabaseQueryPacket :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientDatabaseQueryRequest
	err := cbor.unmarshal(payload, &req)
	defer delete(req.query)
	if err != nil {
		MainRouterState_sendPeerMessage(
			pm,
			state,
			peerID,
			common.MessageType.ServerDatabaseQueryResponse,
			common.ServerDatabaseQueryResult {
				success = false,
				message = "invalid payload",
				result = "",
			},
		)
		return
	}

	if len(req.query) == 0 {
		MainRouterState_sendPeerMessage(
			pm,
			state,
			peerID,
			common.MessageType.ServerDatabaseQueryResponse,
			common.ServerDatabaseQueryResult {
				success = false,
				message = "empty query",
				result = "",
			},
		)
		return
	}

	MainRouterState_sendDatabaseRequest(
		pm,
		state,
		peerID,
		.Generic,
		common.DatabaseQueryRequest {
			queryType = .RawSQL,
			rawSQL = {query = strings.clone(req.query)},
		},
	)
}

MainRouterState_authenticatedUserIDFromIdentity :: proc(
	publicKey: common.IdentityPublicKeyBytes,
) -> int {
	fingerprint := common.fingerprintIdentityPublicKey(publicKey)
	value: u32
	for i in 0 ..< 4 {
		value |= u32(fingerprint[i]) << u32(8 * i)
	}
	if value == 0 {
		return 1
	}
	return int(value)
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
	if req.version != common.protocolVersion {
		MainRouterState_protocolViolation(pm, state, peerID, "Unsupported protocol version")
		return
	}

	session := MainRouterState_ensurePeerSession(state, peerID)
	if session.isAuthenticated ||
	   (session.transport.phase != .Disconnected && session.transport.phase != .Failed) {
		MainRouterState_protocolViolation(pm, state, peerID, "Unexpected ClientHello")
		return
	}

	session = RouterPeerSession_init()
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
	session.isAuthenticated = true
	session.authenticatedUserID = MainRouterState_authenticatedUserIDFromIdentity(
		session.clientIdentityPublicKey,
	)
	MainRouterState_setPeerSession(state, peerID, session)

	if !MainRouterState_sendPeerMessage(
		pm,
		state,
		peerID,
		common.MessageType.ServerAuthSuccess,
		common.ServerAuthSuccessPayload{userId = session.authenticatedUserID, message = "ok"},
	) {
		MainRouterState_protocolViolation(pm, state, peerID, "Failed to send auth success")
		return
	}
}

MainRouterState_dispatchApplicationPacket :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	packet: common.Packet,
) {
	#partial switch packet.messageType {
	case .ClientAuthLookup:
		MainRouterState_handleClientAuthLookupPacket(pm, state, peerID, packet.payload)
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
	case .ClientDatabaseQuery:
		MainRouterState_handleClientDatabaseQueryPacket(pm, state, peerID, packet.payload)
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

MainRouterState_handleDatabaseResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	requestID: u64,
	response: common.DatabaseQueryResponse,
) {
	request, ok := MainRouterState_getDatabaseRequest(state, requestID)
	if !ok {
		fmt.printfln("[Main] Received database response for unknown request ID %d\n", requestID)
		return
	}

	switch request.requestType {
	case .AuthLookup:
		MainRouterState_sendPeerMessage(
			pm,
			state,
			request.peerID,
			common.MessageType.ServerAuthLookupResponse,
			common.ServerAuthLookupResult {
				success = response.success,
				message = response.message,
				result = response.result,
			},
		)
	case .Generic:
		MainRouterState_sendPeerMessage(
			pm,
			state,
			request.peerID,
			common.MessageType.ServerDatabaseQueryResponse,
			common.ServerDatabaseQueryResult {
				success = response.success,
				message = response.message,
				result = response.result,
			},
		)
	case:
	}
}

main :: proc() {

	fmt.println("=== HayChat Server - Threaded Architecture ===")

	config := loadConfig()
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
	if !spawnProcess(&pm, .Database) {
		fmt.println("[Database] Failed to start database service thread")
		pm.shouldShutdown = true
		shutdownAllProcesses(&pm)
		return
	}

	fmt.println("=== Server Running ===")
	fmt.println("Main thread is supervising network, web admin, and database threads")

	mainLoop(&pm)

	fmt.println("=== Server Shutdown Complete ===")
}

@(private)
mainLoop :: proc(pm: ^ProcessManager) {
	running := true
	routerState := MainRouterState_init(pm)
	defer MainRouterState_deinit(&routerState)

	for running {
		if mainInterruptRequested {
			queueMainInterruptShutdown(pm)
		}

		msg, err := IPC_Client_poll(pm.config.mainFd)
		if err == nil {
			switch m in msg {
			case NetworkSendData, NetworkBroadcast, NetworkDisconnectPeer:
			// Commands are generated by main and should not loop back here.
			case NetworkPeerConnected:
				routerState.connectedPeers[m.peerId] = true
				MainRouterState_setPeerSession(&routerState, m.peerId, RouterPeerSession_init())
			case NetworkPeerDisconnected:
				delete_key(&routerState.connectedPeers, m.peerId)
				MainRouterState_removePendingRequestsForPeer(&routerState, m.peerId)
				MainRouterState_removePeerSession(&routerState, m.peerId)
			case NetworkDataReceived:
				MainRouterState_handleNetworkDataReceived(pm, &routerState, m)
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
					session, ok := MainRouterState_getPeerSession(&routerState, peerID)
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
				MainRouterState_handleDatabaseResult(pm, &routerState, m.request_id, m.response)
			case DatabaseError:
				MainRouterState_handleDatabaseResult(
					pm,
					&routerState,
					m.request_id,
					common.DatabaseQueryResponse{success = false, message = m.error, result = ""},
				)
			case ProcessShutdown:
				sync.mutex_lock(&pm.processMutex)
				pm.shouldShutdown = true
				sync.mutex_unlock(&pm.processMutex)
				MainRouterState_failPendingDatabaseRequests(
					pm,
					&routerState,
					"server shutting down",
				)
				running = false
			case ProcessRestart:
				MainRouterState_prepareForProcessStop(
					pm,
					&routerState,
					.Database,
					"database restarting",
				)
				MainRouterState_prepareForProcessStop(
					pm,
					&routerState,
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

		thread.yield()
	}

	shutdownAllProcesses(pm)
}
