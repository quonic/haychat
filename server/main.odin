package server

import "../common"
import "base:runtime"
import "core:c/libc"
import "core:crypto"
import "core:crypto/ecdh"
import "core:encoding/cbor"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"

import "core:time"

PendingDBRequestType :: enum {
	ResolveUserIdentity,
	ListRooms,
	PostChatMessage,
	GetRoomHistory,
	// Room management: each statement checks ManageRooms itself (protocol 23).
	CreateRoom,
	EditRoom,
	ListEditRoomRecipients,
	DeleteRoom,
	PostDirectMessage,
	GetDirectHistory,
	ListDirectConversations,
	ListUsers,
	JoinVoiceMemberCheck,
	MarkRead,
	// An admin action on an account (router_admin.odin); one statement checks the role too.
	AdminUserAction,
	// Protocol 15 (router_room_access.odin): an add, remove, leave or member fetch, whose one
	// statement checks the requester and the room's mode, and the admin's room list.
	RoomMemberAction,
	AdminListRooms,
	// Account encryption keys (router_encryption_keys.odin, protocol 16).
	PublishEncryptionKey,
	FetchUserKeys,
	// Encrypted rooms' member logs (router_room_log.odin, protocol 18).
	AppendRoomLog,
	FetchRoomLog,
	// Sender chains in encrypted rooms (router_room_keys.odin, protocol 19).
	StoreRoomKeyEnvelope,
	FetchRoomKeys,
	RoomKeyRequestCheck,
	// Roles (router_roles.odin, protocol 23): the role list, and an admin's role change whose
	// one statement checks the role and the guards.
	ListRoles,
	RoleAction,
	// Room permissions (router_room_permissions.odin, protocol 24): a fetch or a set of a room's
	// grants, whose one statement checks ManageRooms or the room's EditRoom.
	RoomPermissions,
	// Registration (router_registration.odin, protocol 25): a message about an account waiting
	// for the database to say who may see it (no peer), the restricted accounts loaded at start
	// (no peer), a ClientRegister, an invite create, list or revoke, a request list or
	// decision, and the registration mode.
	VisibleRecipients,
	LoadRestrictedUsers,
	Register,
	InviteAction,
	RegistrationRequests,
	RegistrationMode,
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
	// Mark-read: which kind of conversation roomID or targetUserID names.
	readMarkerKind:   common.ReadMarkerKind,
	recipientUserIDs: [dynamic]int,
	// ClientJoinVoice: the flags the joiner asked for, applied once the membership check passes,
	// whether it is the client's automatic re-join, and its parsed device ID (protocol 13).
	voiceMuted:       bool,
	voiceDeafened:    bool,
	voiceRejoin:      bool,
	voiceDeviceID:    common.VoiceDeviceID,
	// Room create and edit: the room type asked for (protocol 14), and the access mode, the
	// history setting and whether the creator joins (protocol 15).
	roomType:         common.RoomType,
	roomAccess:       common.RoomAccess,
	roomHistory:      common.RoomHistoryVisibility,
	creatorJoins:     bool,
	// Room create and edit (protocol 18): the encrypted flag asked for.
	roomEncrypted:    bool,
	// RoomMemberAction: which one.
	roomMemberAction: common.RoomMemberAction,
	// Admin actions (protocol 14): which one, and its flag (isAdmin, locked, or banned). name
	// holds a rename's nickname and description a kick or ban reason.
	adminAction:      common.AdminAction,
	adminFlag:        bool,
	// RoleAction (protocol 23): which role statement, and the role it names (0 for a create).
	roleAction:       common.DatabaseRoleAction,
	roleID:           int,
	// RoomPermissions (protocol 24): a fetch or a set of a room's grants.
	roomPermissionsAction: common.DatabaseRoomPermissionsAction,
	// VisibleRecipients (protocol 25): the message (owned) and the session it skips.
	visibility:            MainRouterVisibilityPayload,
	excludePeerID:         u32,
	// Register (protocol 25): the applicant's identity key. The request outlives a disconnect
	// and ENet reuses peer IDs, so its answer applies only to a session with this key.
	identityPublicKey:     common.IdentityPublicKeyBytes,
}

PendingDBRequest_deinit :: proc(request: PendingDBRequest) {
	delete(request.name)
	delete(request.description)
	delete(request.recipientUserIDs)
	visibility := request.visibility
	MainRouterVisibilityPayload_deinit(&visibility)
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
	isAuthenticated:           bool,
	authenticatedUserID:       int,
	// The account's effective server permissions (protocol 25 reads ApproveRegistrations for
	// D17 and D18), kept current with ServerAccountUpdated.
	permissions:               common.ServerPermissions,
	// Registration (protocol 25, router_registration.odin): the session got
	// ServerRegistrationRequired and may send only ClientRegister and Ping; when it started,
	// how many ClientRegisters it sent, and whether one is in the database now.
	isRegistering:             bool,
	registeringSince:          time.Tick,
	registerAttempts:          int,
	registerInFlight:          bool,
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
	return RouterPeerSession{transport = common.TransportState_init(.Server)}
}

RouterPeerSession_deinit :: proc(session: ^RouterPeerSession) {
	delete(session.clientNickname)
	common.TransportState_deinit(&session.transport)
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
	// Voice control plane (voice.odin): roomID -> its voice session, removed when empty, and
	// peerID -> the room that session is in.
	voiceRooms:               map[int]VoiceRoomState,
	peerVoiceRoom:            map[u32]int,
	// roomID -> the newest member log version the router has seen applied (ServerRoomLog
	// fan-out), kept whether or not the room has a voice session. A room's first voice join
	// seeds its log version from the larger of this and the join check's, so an append that
	// lands while that check is in the database is not lost (#77). Removed when a room is
	// deleted.
	roomLogVersions:          map[int]int,
	// Voice datagrams that reached the router. The network thread's relay consumes channel 2,
	// so this stays 0 unless something routes voice here by mistake.
	unexpectedVoiceDatagrams: u64,
	// Protocol 25 (router_registration.odin): every restricted account (loaded at start, kept
	// current by the router), and the invite code each pending ClientCreateInvite generated,
	// by request ID, wiped once answered.
	restrictedUserIDs:        map[int]bool,
	pendingInviteCodes:       map[u64]common.InviteCodeBytes,
}

MainRouterState_init :: proc(pm: ^ProcessManager) -> MainRouterState {
	state := MainRouterState {
		connectedPeers          = make(map[u32]bool),
		peerSessions            = make(map[u32]RouterPeerSession),
		pendingDatabaseRequests = make(map[u64]PendingDBRequest),
		nextRequestID           = 1,
		voiceRooms              = make(map[int]VoiceRoomState),
		peerVoiceRoom           = make(map[u32]int),
		roomLogVersions         = make(map[int]int),
		restrictedUserIDs       = make(map[int]bool),
		pendingInviteCodes      = make(map[u64]common.InviteCodeBytes),
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
	// By reference, so each stored transport is wiped, not a copy of it.
	for _, &session in state.peerSessions {
		RouterPeerSession_deinit(&session)
	}
	for _, request in state.pendingDatabaseRequests {
		PendingDBRequest_deinit(request)
	}
	delete(state.connectedPeers)
	delete(state.peerSessions)
	delete(state.pendingDatabaseRequests)
	delete(state.roomLogVersions)
	delete(state.restrictedUserIDs)
	MainRouterState_wipeInviteCodes(state)
	delete(state.pendingInviteCodes)
	MainRouterState_voiceFreeState(state)
}

// Wipes and forgets every pending invite code.
MainRouterState_wipeInviteCodes :: proc(state: ^MainRouterState) {
	for _, &code in state.pendingInviteCodes {
		crypto.zero_explicit(&code, size_of(code))
	}
	clear(&state.pendingInviteCodes)
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
	// Deinit the stored entry in place: deinit on a copy would leave the entry's transport
	// keys in the map's memory after delete_key.
	if session, ok := &state.peerSessions[peerID]; ok {
		RouterPeerSession_deinit(session)
	}
	delete_key(&state.peerSessions, peerID)
}

MainRouterState_removePendingRequestsForPeer :: proc(state: ^MainRouterState, peerID: u32) {
	requestIDs := make([dynamic]u64)
	defer delete(requestIDs)

	for requestID, request in state.pendingDatabaseRequests {
		// A ClientRegister stays: its answer still tells the approvers of a new request.
		if request.peerID == peerID && request.requestType != .Register {
			append(&requestIDs, requestID)
		}
	}

	for requestID in requestIDs {
		request := state.pendingDatabaseRequests[requestID]
		PendingDBRequest_deinit(request)
		delete_key(&state.pendingDatabaseRequests, requestID)
		MainRouterState_forgetInviteCode(state, requestID)
	}
}

MainRouterState_isPlaintextHandshakeResponse :: proc(messageType: common.MessageType) -> bool {
	#partial switch messageType {
	case .ServerHello,
	     .ServerRegistrationRequired,
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
	// Registering sessions (protocol 25) have an active transport too.
	if session, ok := MainRouterState_getPeerSession(state, peerID);
	   ok &&
	   (session.isAuthenticated || session.isRegistering) &&
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
		session.isRegistering = false
		MainRouterState_setPeerSession(state, peerID, session)
		// The session no longer counts as online, and its later disconnect event will not
		// see it as authenticated, so presence and voice must be settled here.
		MainRouterState_voiceLeave(pm, state, peerID, skipSelf = true)
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
	payload: common.ServerAuthSuccessPayload,
) -> bool

MainRouterState_sendAuthSuccess :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: common.ServerAuthSuccessPayload,
) -> bool {
	return MainRouterState_sendPeerMessage(
		pm,
		state,
		peerID,
		common.MessageType.ServerAuthSuccess,
		payload,
	)
}

// Finishes a handshake whose identity resolved to userID. The session counts as authenticated
// only once ServerAuthSuccess is out (it is a plaintext handshake response, so it does not need
// the flag). Marking it first would let a failed send reach MainRouterState_protocolViolation
// as an authenticated session, which announces offline a user nobody heard come online.
// sendAuthSuccess exists so router tests can make the send fail.
//
// renamed means this login gave the account a new nickname. Presence normally goes out only
// for a user's first session, but a rename must reach everyone who already sees the user
// online, so it is announced even when another session of the user is authenticated.
//
// isAdmin comes from the identity statement and only tells the client to offer room
// management; every admin request still checks the role in the database.
//
// nickname (borrowed) is the account's name after this login (protocol 14). It differs from
// the session's requested nickname when an admin locked the name; the session takes the
// account's name then, so presence, voice lists, and ServerAuthSuccess carry it. Empty keeps
// the requested one.
MainRouterState_completeAuthentication :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	userID: int,
	renamed := false,
	isAdmin := false,
	nickname := "",
	nicknameLocked := false,
	permissions := common.ServerPermissions{},
	registrationMode := common.RegistrationMode.Open,
	isRestricted := false,
	sendAuthSuccess: MainRouterAuthSuccessSender = MainRouterState_sendAuthSuccess,
) {
	if session, sessionOK := &state.peerSessions[peerID]; !sessionOK || session.isAuthenticated {
		return
	} else if len(nickname) > 0 && session.clientNickname != nickname {
		delete(session.clientNickname)
		session.clientNickname = strings.clone(nickname)
	}
	stored, _ := MainRouterState_getPeerSession(state, peerID)
	if !sendAuthSuccess(
		pm,
		state,
		peerID,
		common.ServerAuthSuccessPayload {
			userId = userID,
			message = "ok",
			isAdmin = isAdmin,
			nickname = stored.clientNickname,
			nicknameLocked = nicknameLocked,
			permissions = permissions,
			registrationMode = registrationMode,
			isRestricted = isRestricted,
		},
	) {
		MainRouterState_protocolViolation(pm, state, peerID, "Failed to send auth success")
		return
	}
	MainRouterState_setUserRestricted(state, userID, isRestricted)

	session, _ := MainRouterState_getPeerSession(state, peerID)
	// Counted before this session joins, so only a user's first session announces them.
	wasOnline := MainRouterState_isUserOnline(state, userID)
	session.isAuthenticated = true
	session.authenticatedUserID = userID
	session.permissions = permissions
	// The voice halves move to the network thread's relay (Q8). Taken from this copy before it
	// is stored, so the stored session holds zeros and the router never touches voice crypto.
	voiceSend, voiceReceive := common.TransportState_takeVoiceState(&session.transport)
	MainRouterState_setPeerSession(state, peerID, session)
	MainRouterState_sendVoiceSessionOpen(
		pm,
		peerID,
		userID,
		session.transport.sessionID,
		&voiceSend,
		&voiceReceive,
	)
	if renamed {
		MainRouterState_renameUserSessions(state, userID, session.clientNickname)
	}
	if !wasOnline || renamed {
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

// Gives every authenticated session of userID the account's new nickname, so the offline
// notice sent when the last of them ends carries the current name rather than the old one.
MainRouterState_renameUserSessions :: proc(
	state: ^MainRouterState,
	userID: int,
	nickname: string,
) {
	for _, &session in state.peerSessions {
		if session.isAuthenticated &&
		   session.authenticatedUserID == userID &&
		   session.clientNickname != nickname {
			delete(session.clientNickname)
			session.clientNickname = strings.clone(nickname)
		}
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
	// By reference, so each stored transport is wiped, not a copy of it.
	for _, &session in state.peerSessions {
		RouterPeerSession_deinit(&session)
	}
	delete(state.connectedPeers)
	delete(state.peerSessions)
	delete(state.pendingDatabaseRequests)
	MainRouterState_wipeInviteCodes(state)
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
		     .CreateRoom,
		     .EditRoom,
		     .ListEditRoomRecipients,
		     .DeleteRoom,
		     .ListRoles,
		     .RoleAction,
		     .RoomPermissions,
		     .RoomMemberAction,
		     .AdminListRooms,
		     .PostDirectMessage,
		     .GetDirectHistory,
		     .ListDirectConversations,
		     .ListUsers,
		     .MarkRead,
		     .AdminUserAction,
		     .PublishEncryptionKey,
		     .FetchUserKeys,
		     .AppendRoomLog,
		     .FetchRoomLog,
		     .StoreRoomKeyEnvelope,
		     .FetchRoomKeys,
		     .InviteAction,
		     .RegistrationRequests,
		     .RegistrationMode:
			MainRouterState_sendProtocolError(pm, state, request.peerID, message)
			MainRouterState_forgetInviteCode(state, requestID)
		case .Register:
			if session, sessionOK := &state.peerSessions[request.peerID];
			   sessionOK && session.isRegistering {
				session.registerInFlight = false
				MainRouterState_sendRegisterResponse(
					pm,
					state,
					request.peerID,
					.Refused,
					message,
				)
			}
		case .VisibleRecipients, .LoadRestrictedUsers:
		case .RoomKeyRequestCheck:
		// Never answered (router_room_keys.odin).
		case .JoinVoiceMemberCheck:
			MainRouterState_sendVoiceJoinRejected(
				pm,
				state,
				request.peerID,
				request.roomID,
				message,
			)
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
		MainRouterState_voiceReset(pm, state)
	case .Database:
		MainRouterState_failPendingDatabaseRequests(pm, state, message)
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

	// Reset the stored entry in place, so its keys are wiped and it never keeps a pointer to
	// the nickname freed here if the handshake stops below.
	if stored, storedOK := &state.peerSessions[peerID]; storedOK {
		RouterPeerSession_deinit(stored)
		stored^ = RouterPeerSession_init()
	}
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
	common.DirectionalTransportKeys_wipe(&keys)
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
			registering = req.registering,
		},
	)
}

// The refusal for a chat message to a voice-only room (protocol 14). The post statement checks
// the room type in the same statement as membership and the insert.
CHAT_DISABLED_MESSAGE :: "Chat is disabled in this room"

// Protocol 22 (#90): a plaintext message must carry a set client message ID and a signature by
// the session's identity key over this server, the room, the session's account, that ID and
// the content (ROOM_MESSAGE_SIGNATURE_INVALID_MESSAGE otherwise); the database refuses a reused
// ID.
//
// Protocol 19 (e2ee-design.md 6.5): a sealed message is checked here for what needs no database:
// its shape, its structure (decodeSealedRoomMessage) and its signature against the session's
// identity key, which is the account's users.public_key, with every AAD field known (this
// server, the room, the session's account, the chain position and the client message ID). The
// database statement then checks membership, that the room is encrypted and that the epoch is
// its current log version, and stores the bytes unchanged. Fixed-size byte fields decode through
// CBOR's temporary allocator, so it is the heap here.
MainRouterState_handleClientChatMessage :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientChatMessagePayload
	err := cbor.unmarshal(payload, &req, temp_allocator = context.allocator)
	defer common.ClientChatMessagePayload_deinit(&req)
	if err != nil {
		MainRouterState_sendProtocolError(pm, state, peerID, "Invalid ClientChatMessage payload")
		return
	}

	session, ok := MainRouterState_getPeerSession(state, peerID)
	if !ok || !session.isAuthenticated {
		MainRouterState_sendProtocolError(pm, state, peerID, "Unauthenticated chat message")
		return
	}

	if len(req.sealed) > 0 {
		message, valid := MainRouterState_checkSealedRoomMessage(
			state,
			req,
			session.authenticatedUserID,
			session.clientIdentityPublicKey,
		)
		if !valid {
			MainRouterState_sendProtocolError(
				pm,
				state,
				peerID,
				common.SEALED_ROOM_MESSAGE_INVALID_MESSAGE,
			)
			return
		}
		request := common.DatabasePostRoomChatMessageRequest {
			roomId          = req.roomId,
			senderId        = session.authenticatedUserID,
			content         = strings.clone(""),
			clientMessageId = req.clientMessageId,
			sealed          = req.sealed,
			epoch           = message.header.epoch,
			chainId         = message.header.chainID,
			chainIndex      = int(message.header.index),
		}
		// The request takes the decoded bytes; the database side frees them.
		req.sealed = nil
		MainRouterState_enqueueChannelDatabaseRequest(
			pm,
			state,
			peerID,
			request,
			PendingDBRequest{requestType = .PostChatMessage, roomID = req.roomId},
		)
		return
	}

	if req.roomId <= 0 ||
	   len(req.content) == 0 ||
	   len(req.content) > common.CHAT_MESSAGE_MAX_BYTES {
		MainRouterState_sendProtocolError(pm, state, peerID, "Invalid room chat message")
		return
	}
	// Protocol 22 (#90): a plaintext message is signed by the session's identity key, so no
	// one, the server included, can write one in another account's name.
	if !common.verifyPlaintextRoomMessage(
		common.PlaintextRoomMessageFields {
			serverIdentityPublicKey = state.serverIdentityPublicKey,
			roomID = req.roomId,
			senderUserID = session.authenticatedUserID,
			clientMessageID = req.clientMessageId,
		},
		req.content,
		session.clientIdentityPublicKey,
		req.signature,
	) {
		MainRouterState_sendProtocolError(
			pm,
			state,
			peerID,
			common.ROOM_MESSAGE_SIGNATURE_INVALID_MESSAGE,
		)
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
			clientMessageId = req.clientMessageId,
			signature = req.signature,
		},
		PendingDBRequest{requestType = .PostChatMessage, roomID = req.roomId},
	)
}

// The router's check of a sealed room message (pure but for the server key): no content, a
// set client message ID, at most SEALED_ROOM_MESSAGE_MAX_BYTES of valid structure, and a
// signature by senderIdentityPublicKey over this server, the room, senderUserID, its chain
// position and the client message ID. The result borrows req.sealed.
MainRouterState_checkSealedRoomMessage :: proc(
	state: ^MainRouterState,
	req: common.ClientChatMessagePayload,
	senderUserID: int,
	senderIdentityPublicKey: common.IdentityPublicKeyBytes,
) -> (
	message: common.SealedRoomMessage,
	valid: bool,
) {
	if req.roomId <= 0 ||
	   len(req.content) != 0 ||
	   !common.clientMessageIDIsSet(req.clientMessageId) ||
	   len(req.sealed) > common.SEALED_ROOM_MESSAGE_MAX_BYTES {
		return {}, false
	}
	decoded, decodeErr := common.decodeSealedRoomMessage(req.sealed)
	if decodeErr != .None {
		return {}, false
	}
	verifyErr := common.verifyRoomMessageSignature(
		decoded,
		common.RoomMessageContext {
			serverIdentityPublicKey = state.serverIdentityPublicKey,
			roomID = req.roomId,
			senderUserID = senderUserID,
			clientMessageID = req.clientMessageId,
		},
		senderIdentityPublicKey,
	)
	return decoded, verifyErr == .None
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
	return(
		len(name) >= 1 &&
		len(name) <= common.ROOM_NAME_MAX_BYTES &&
		len(description) <= common.ROOM_DESCRIPTION_MAX_BYTES \
	)
}

MainRouterState_handleClientCreateRoom :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientCreateRoomPayload
	defer common.ClientCreateRoomPayload_deinit(&req)
	if cbor.unmarshal(payload, &req) != nil ||
	   !MainRouterState_hasValidRoomMetadata(req.name, req.description) ||
	   !common.roomTypeIsSupported(req.roomType) ||
	   !common.roomAccessIsSupported(req.access) ||
	   !common.roomHistoryVisibilityIsSupported(req.historyVisibility) ||
	   !common.roomAccessRolesAreValid(req.access, req.accessRoleIds[:]) {
		MainRouterState_sendProtocolError(pm, state, peerID, "Invalid room metadata")
		return
	}
	// Protocol 18: encrypting a room anyone joins protects nothing (e2ee-design.md 6.1).
	if req.encrypted && req.access == .Public {
		MainRouterState_sendProtocolError(pm, state, peerID, common.ENCRYPTED_ROOM_PUBLIC_MESSAGE)
		return
	}
	// Protocol 24: an encrypted room's adds must be signed in its member log, which a role
	// change cannot do.
	if req.encrypted && req.access == .Role {
		MainRouterState_sendProtocolError(pm, state, peerID, common.ROOM_ENCRYPTED_ROLE_MESSAGE)
		return
	}
	userID, ok := MainRouterState_authenticatedUserForAdminRequest(pm, state, peerID)
	if !ok {
		return
	}
	// The statement checks ManageRooms itself (protocol 23).
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseCreateRoomRequest {
			creatorUserId = userID,
			name = strings.clone(req.name),
			description = strings.clone(req.description),
			roomType = req.roomType,
			access = req.access,
			historyVisibility = req.historyVisibility,
			creatorJoins = req.creatorJoins,
			encrypted = req.encrypted,
			accessRoleIds = MainRouterState_sortedRoleIDs(req.accessRoleIds[:]),
		},
		PendingDBRequest{requestType = .CreateRoom, targetUserID = userID},
	)
}

MainRouterState_handleClientEditRoom :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientEditRoomPayload
	defer common.ClientEditRoomPayload_deinit(&req)
	if cbor.unmarshal(payload, &req) != nil ||
	   req.roomId <= 0 ||
	   !MainRouterState_hasValidRoomMetadata(req.name, req.description) ||
	   !common.roomTypeIsSupported(req.roomType) ||
	   !common.roomAccessIsSupported(req.access) ||
	   !common.roomAccessRolesAreValid(req.access, req.accessRoleIds[:]) {
		MainRouterState_sendProtocolError(pm, state, peerID, "Invalid room edit")
		return
	}
	userID, ok := MainRouterState_authenticatedUserForAdminRequest(pm, state, peerID)
	if !ok {
		return
	}
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseEditRoomRequest {
			actorUserId = userID,
			roomId = req.roomId,
			name = strings.clone(req.name),
			description = strings.clone(req.description),
			roomType = req.roomType,
			access = req.access,
			encrypted = req.encrypted,
			accessRoleIds = MainRouterState_sortedRoleIDs(req.accessRoleIds[:]),
		},
		PendingDBRequest{requestType = .EditRoom, roomID = req.roomId},
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
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseDeleteRoomRequest{actorUserId = userID, roomId = req.roomId},
		PendingDBRequest{requestType = .DeleteRoom, roomID = req.roomId},
	)
}

// An owned, ascending copy of role IDs, the order the edit statement compares a room's access
// roles in.
MainRouterState_sortedRoleIDs :: proc(roleIDs: []int) -> [dynamic]int {
	sorted := make([dynamic]int, 0, len(roleIDs))
	append(&sorted, ..roleIDs)
	slice.sort(sorted[:])
	return sorted
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
		MainRouterState_handleClientRoomMembershipMutation(pm, state, peerID, packet.payload, .Add)
	case .ClientRemoveRoomMember:
		MainRouterState_handleClientRoomMembershipMutation(
			pm,
			state,
			peerID,
			packet.payload,
			.Remove,
		)
	case .ClientLeaveRoom:
		MainRouterState_handleClientLeaveRoom(pm, state, peerID, packet.payload)
	case .ClientFetchRoomMembers:
		MainRouterState_handleClientFetchRoomMembers(pm, state, peerID, packet.payload)
	case .ClientAdminListRooms:
		MainRouterState_handleClientAdminListRooms(pm, state, peerID, packet.payload)
	case .ClientDirectMessage:
		MainRouterState_handleClientDirectMessage(pm, state, peerID, packet.payload)
	case .ClientSealedDirectMessage:
		MainRouterState_handleClientSealedDirectMessage(pm, state, peerID, packet.payload)
	case .ClientFetchDirectHistory:
		MainRouterState_handleClientFetchDirectHistory(pm, state, peerID, packet.payload)
	case .ClientListDirectConversations:
		MainRouterState_handleClientListDirectConversations(pm, state, peerID, packet.payload)
	case .ClientUserList:
		MainRouterState_handleClientListUsers(pm, state, peerID, packet.payload)
	case .ClientJoinVoice:
		MainRouterState_handleClientJoinVoice(pm, state, peerID, packet.payload)
	case .ClientLeaveVoice:
		MainRouterState_handleClientLeaveVoice(pm, state, peerID, packet.payload)
	case .ClientVoiceState:
		MainRouterState_handleClientVoiceState(pm, state, peerID, packet.payload)
	case .ClientMarkRead:
		MainRouterState_handleClientMarkRead(pm, state, peerID, packet.payload)
	case .ClientAdminSetRole:
		MainRouterState_handleClientAdminSetRole(pm, state, peerID, packet.payload)
	case .ClientAdminRenameUser:
		MainRouterState_handleClientAdminRenameUser(pm, state, peerID, packet.payload)
	case .ClientAdminKickUser:
		MainRouterState_handleClientAdminKickUser(pm, state, peerID, packet.payload)
	case .ClientAdminBanUser:
		MainRouterState_handleClientAdminBanUser(pm, state, peerID, packet.payload)
	case .ClientAdminListRoles:
		MainRouterState_handleClientAdminListRoles(pm, state, peerID, packet.payload)
	case .ClientAdminSaveRole:
		MainRouterState_handleClientAdminSaveRole(pm, state, peerID, packet.payload)
	case .ClientAdminDeleteRole:
		MainRouterState_handleClientAdminDeleteRole(pm, state, peerID, packet.payload)
	case .ClientAdminSetRoomPermissions:
		MainRouterState_handleClientAdminSetRoomPermissions(pm, state, peerID, packet.payload)
	case .ClientAdminFetchRoomPermissions:
		MainRouterState_handleClientAdminFetchRoomPermissions(pm, state, peerID, packet.payload)
	case .ClientAdminSetUserRoles:
		MainRouterState_handleClientAdminSetUserRoles(pm, state, peerID, packet.payload)
	case .ClientPublishEncryptionKey:
		MainRouterState_handleClientPublishEncryptionKey(pm, state, peerID, packet.payload)
	case .ClientFetchUserKeys:
		MainRouterState_handleClientFetchUserKeys(pm, state, peerID, packet.payload)
	case .ClientAppendRoomLog:
		MainRouterState_handleClientAppendRoomLog(pm, state, peerID, packet.payload)
	case .ClientFetchRoomLog:
		MainRouterState_handleClientFetchRoomLog(pm, state, peerID, packet.payload)
	case .ClientRoomKeyEnvelope:
		MainRouterState_handleClientRoomKeyEnvelope(pm, state, peerID, packet.payload)
	case .ClientFetchRoomKeys:
		MainRouterState_handleClientFetchRoomKeys(pm, state, peerID, packet.payload)
	case .ClientRequestRoomKey:
		MainRouterState_handleClientRequestRoomKey(pm, state, peerID, packet.payload)
	case .ClientVoiceKey:
		MainRouterState_handleClientVoiceKey(pm, state, peerID, packet.payload)
	case .ClientRequestVoiceKey:
		MainRouterState_handleClientRequestVoiceKey(pm, state, peerID, packet.payload)
	case .ClientAdminSetRegistrationMode:
		MainRouterState_handleClientAdminSetRegistrationMode(pm, state, peerID, packet.payload)
	case .ClientCreateInvite:
		MainRouterState_handleClientCreateInvite(pm, state, peerID, packet.payload)
	case .ClientListInvites:
		MainRouterState_handleClientListInvites(pm, state, peerID, packet.payload)
	case .ClientRevokeInvite:
		MainRouterState_handleClientRevokeInvite(pm, state, peerID, packet.payload)
	case .ClientListRegistrationRequests:
		MainRouterState_handleClientListRegistrationRequests(pm, state, peerID, packet.payload)
	case .ClientDecideRegistration:
		MainRouterState_handleClientDecideRegistration(pm, state, peerID, packet.payload)
	case .ClientAdminSetRestricted:
		MainRouterState_handleClientAdminSetRestricted(pm, state, peerID, packet.payload)
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
		// Protocol 25 (D12): only encrypted, from a registering session.
		MainRouterState_protocolViolation(pm, state, peerID, "Unexpected ClientRegister")
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
	// Only the control channel reaches the router. Anything else is dropped without a protocol
	// violation: datagrams on other channels (voice is channel 2) are not authenticated by
	// ENet, so letting them end a session would hand any spoofer a way to disconnect people.
	switch msg.channel {
	case .Chat:
	case .Voice:
		// The network thread's VoiceRelay consumes channel 2; count anything that slips by.
		state.unexpectedVoiceDatagrams += 1
		return
	case .None, .Video, .Screenshare, .FileTransfer:
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
	if session.isRegistering {
		MainRouterState_handleRegisteringPacket(pm, state, msg.peerId, packet)
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

// The refusal of a room create, edit or delete by an account without ManageRooms (protocol 23).
ROOM_MANAGEMENT_REQUIRED_MESSAGE :: "Room management permission required"

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
		if session, sessionOK := MainRouterState_getPeerSession(state, request.peerID);
		   sessionOK && session.isRegistering {
			// An approval re-ran the statement for a registering session (D14).
			MainRouterState_handleRegisteringIdentityResult(pm, state, request.peerID, response)
			return
		}
		if response.success && identityOK && identity.userId <= 0 && identity.needsRegistration {
			MainRouterState_beginRegistration(pm, state, request.peerID, identity)
			return
		}
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

		if identity.banned {
			MainRouterState_refuseBannedSignIn(pm, state, request.peerID, identity.banReason)
			return
		}
		if identity.renamed {
			fmt.printfln(
				"[Main] User %d renamed from %q on peer %d",
				identity.userId,
				identity.previousNickname,
				request.peerID,
			)
		}
		MainRouterState_completeAuthentication(
			pm,
			state,
			request.peerID,
			identity.userId,
			identity.renamed,
			identity.isAdmin,
			identity.nickname,
			identity.nicknameLocked,
			identity.permissions,
			identity.registrationMode,
			identity.isRestricted,
		)
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
		// Protocol 24: the account's voice sessions follow its SpeakInVoice in each room.
		if session, sessionOK := MainRouterState_getPeerSession(state, request.peerID);
		   sessionOK && session.isAuthenticated {
			MainRouterState_voiceUpdateSpeakPermissions(
				pm,
				state,
				session.authenticatedUserID,
				roomList.rooms[:],
			)
		}
		MainRouterState_voiceSendActiveParticipants(
			pm,
			state,
			request.peerID,
			roomList.rooms[:],
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
		if posted.encryptedRoom {
			MainRouterState_sendProtocolError(
				pm,
				state,
				request.peerID,
				common.ENCRYPTED_ROOM_CHAT_MESSAGE,
			)
			return
		}
		if posted.chatDisabled {
			MainRouterState_sendProtocolError(pm, state, request.peerID, CHAT_DISABLED_MESSAGE)
			return
		}
		if posted.sendDenied {
			MainRouterState_sendProtocolError(
				pm,
				state,
				request.peerID,
				common.ROOM_SEND_NOT_PERMITTED_MESSAGE,
			)
			return
		}
		refusal := ""
		switch {
		case posted.notEncrypted:
			refusal = common.SEALED_ROOM_MESSAGE_NOT_ENCRYPTED_MESSAGE
		case posted.staleEpoch:
			refusal = common.ROOM_KEY_OUT_OF_DATE_MESSAGE
		case posted.duplicate:
			refusal = common.ROOM_MESSAGE_DUPLICATE_MESSAGE
		}
		if len(refusal) > 0 {
			MainRouterState_sendProtocolError(pm, state, request.peerID, refusal)
			return
		}
		chatPayload := common.ServerChatMessagePayload {
			id              = posted.storedMessage.id,
			senderId        = posted.storedMessage.senderId,
			senderNickname  = posted.storedMessage.senderNickname,
			roomId          = posted.storedMessage.roomId,
			timestamp       = posted.storedMessage.timestamp,
			content         = posted.storedMessage.content,
			clientMessageId = posted.storedMessage.clientMessageId,
			sealed          = posted.storedMessage.sealed,
			signature       = posted.storedMessage.signature,
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
	case .CreateRoom:
		mutation, mutationOK := response.result.(common.DatabaseRoomMutationResult)
		if MainRouterState_databaseFailed(pm, state, request.peerID, response, mutationOK) {
			return
		}
		if mutation.notPermitted {
			MainRouterState_sendProtocolError(
				pm,
				state,
				request.peerID,
				ROOM_MANAGEMENT_REQUIRED_MESSAGE,
			)
			return
		}
		if mutation.refusal == .UnknownAccessRole {
			MainRouterState_sendProtocolError(
				pm,
				state,
				request.peerID,
				common.ROOM_ACCESS_ROLE_UNKNOWN_MESSAGE,
			)
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
				isMember = mutation.isMember,
			},
		)
		// A Public room includes every account, so every connected session must refresh its
		// room list; an invite room only the creator's, and only when they joined; a Role room
		// (protocol 24) its access roles' holders.
		for recipientPeerID, recipientSession in state.peerSessions {
			if !recipientSession.isAuthenticated {
				continue
			}
			recipientUserID := recipientSession.authenticatedUserID
			if mutation.room.access != .Public &&
			   !(mutation.isMember && recipientUserID == request.targetUserID) &&
			   !MainRouterState_hasRecipientUserID(mutation.addedUserIDs[:], recipientUserID) {
				continue
			}
			MainRouterState_sendPeerMessage(
				pm,
				state,
				recipientPeerID,
				.ServerRoomMembershipChanged,
				common.ServerRoomMembershipChangedPayload {
					roomId = mutation.room.id,
					joined = true,
					userId = recipientUserID,
				},
			)
		}
	case .EditRoom:
		mutation, mutationOK := response.result.(common.DatabaseRoomMutationResult)
		if MainRouterState_databaseFailed(pm, state, request.peerID, response, mutationOK) {
			return
		}
		if mutation.notPermitted {
			MainRouterState_sendProtocolError(
				pm,
				state,
				request.peerID,
				ROOM_MANAGEMENT_REQUIRED_MESSAGE,
			)
			return
		}
		if !mutation.changed {
			message := "Room not found"
			switch mutation.refusal {
			case .EncryptionFlag:
				message = common.ENCRYPTED_ROOM_FLAG_MESSAGE
			case .EncryptedAccess:
				message = common.ENCRYPTED_ROOM_ACCESS_MESSAGE
			case .UnknownAccessRole:
				message = common.ROOM_ACCESS_ROLE_UNKNOWN_MESSAGE
			case .None:
			}
			MainRouterState_sendProtocolError(pm, state, request.peerID, message)
			return
		}
		// Voice first, as for a deletion, so clients leave the room's voice before they see it
		// become text-only.
		if !common.roomTypeAllowsVoice(mutation.room.roomType) {
			MainRouterState_voiceDisableRoom(pm, state, request.roomID, VOICE_LEFT_TEXT_ONLY)
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
		// A switch to Public added these accounts: each refreshes its room list. So does a Role
		// room's new holder (protocol 24), and its former members leave, voice first.
		MainRouterState_roomMembersAdded(pm, state, request.roomID, mutation.addedUserIDs[:])
		for removedUserID in mutation.removedUserIDs {
			MainRouterState_voiceEvictUser(
				pm,
				state,
				request.roomID,
				removedUserID,
				VOICE_LEFT_REMOVED_FROM_ROOM,
			)
			MainRouterState_sendRoomMembershipChange(
				pm,
				state,
				request.roomID,
				removedUserID,
				false,
				nil,
				request.peerID,
			)
		}
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
				roomType = mutation.room.roomType,
				roomAccess = mutation.room.access,
				roomHistory = mutation.room.historyVisibility,
				roomEncrypted = mutation.room.encrypted,
				// The room's log version travels in targetUserID's place.
				targetUserID = mutation.room.logVersion,
			},
		)
	case .ListEditRoomRecipients:
		members, membersOK := response.result.(common.DatabaseRoomMemberListResult)
		if MainRouterState_databaseFailed(pm, state, request.peerID, response, membersOK) {
			return
		}
		editPayload := common.ServerRoomMutationPayload {
			room = {
				id = request.roomID,
				name = request.name,
				description = request.description,
				roomType = request.roomType,
				access = request.roomAccess,
				historyVisibility = request.roomHistory,
				encrypted = request.roomEncrypted,
				logVersion = request.targetUserID,
			},
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
	case .DeleteRoom:
		mutation, mutationOK := response.result.(common.DatabaseRoomMutationResult)
		if MainRouterState_databaseFailed(pm, state, request.peerID, response, mutationOK) {
			return
		}
		if mutation.notPermitted {
			MainRouterState_sendProtocolError(
				pm,
				state,
				request.peerID,
				ROOM_MANAGEMENT_REQUIRED_MESSAGE,
			)
			return
		}
		if !mutation.changed {
			MainRouterState_sendProtocolError(pm, state, request.peerID, "Room not found")
			return
		}
		// Voice first, so a client leaves the room's voice session before it drops the room.
		MainRouterState_voiceEvictRoom(pm, state, request.roomID, VOICE_LEFT_ROOM_DELETED)
		delete_key(&state.roomLogVersions, request.roomID)
		deletePayload := common.ServerRoomMutationPayload {
			roomId  = request.roomID,
			changed = true,
		}
		for recipientPeerID, recipientSession in state.peerSessions {
			if recipientSession.isAuthenticated &&
			   (recipientPeerID == request.peerID ||
					   MainRouterState_hasRecipientUserID(
						   mutation.memberUserIDs[:],
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
	case .RoomMemberAction:
		MainRouterState_handleRoomMemberActionResult(pm, state, request, response)
	case .AdminListRooms:
		MainRouterState_handleAdminRoomListResult(pm, state, request, response)
	case .PostDirectMessage:
		MainRouterState_handlePostDirectMessageResult(pm, state, request, response)
	case .GetDirectHistory:
		MainRouterState_handleDirectHistoryResult(pm, state, request, response)
	case .ListDirectConversations:
		MainRouterState_handleDirectConversationListResult(pm, state, request, response)
	case .ListUsers:
		MainRouterState_handleUserDirectoryResult(pm, state, request, response)
	case .JoinVoiceMemberCheck:
		MainRouterState_handleJoinVoiceMemberCheckResult(pm, state, request, response)
	case .MarkRead:
		MainRouterState_handleMarkReadResult(pm, state, request, response)
	case .AdminUserAction:
		MainRouterState_handleAdminUserResult(pm, state, request, response)
	case .ListRoles:
		MainRouterState_handleRoleListResult(pm, state, request, response)
	case .RoleAction:
		MainRouterState_handleRoleActionResult(pm, state, request, response)
	case .RoomPermissions:
		MainRouterState_handleRoomPermissionsResult(pm, state, request, response)
	case .PublishEncryptionKey:
		MainRouterState_handlePublishEncryptionKeyResult(pm, state, request, response)
	case .FetchUserKeys:
		MainRouterState_handleFetchUserKeysResult(pm, state, request, response)
	case .AppendRoomLog:
		MainRouterState_handleAppendRoomLogResult(pm, state, request, response)
	case .FetchRoomLog:
		MainRouterState_handleFetchRoomLogResult(pm, state, request, response)
	case .StoreRoomKeyEnvelope:
		MainRouterState_handleStoreRoomKeyEnvelopeResult(pm, state, request, response)
	case .FetchRoomKeys:
		MainRouterState_handleFetchRoomKeysResult(pm, state, request, response)
	case .RoomKeyRequestCheck:
		MainRouterState_handleRoomKeyRequestCheckResult(pm, state, request, response)
	case .VisibleRecipients:
		MainRouterState_handleVisibleRecipientsResult(pm, state, request, response)
	case .LoadRestrictedUsers:
		MainRouterState_handleRestrictedUsersResult(state, response)
	case .Register:
		MainRouterState_handleRegisterResult(pm, state, request, response)
	case .InviteAction:
		MainRouterState_handleInviteResult(pm, state, request, response)
	case .RegistrationRequests:
		MainRouterState_handleRegistrationRequestsResult(pm, state, request, response)
	case .RegistrationMode:
		MainRouterState_handleRegistrationModeResult(pm, state, request, response)
	}
}

// Exit status for a server that could not start: non-zero, so a service manager
// (systemd Restart=on-failure) or a script can tell a failed start from a clean shutdown.
MAIN_STARTUP_FAILURE_EXIT_CODE :: 1

// Ends a failed startup after the caller has printed why and released what it started.
mainExitStartupFailure :: proc() -> ! {
	os.exit(MAIN_STARTUP_FAILURE_EXIT_CODE)
}

main :: proc() {

	fmt.println("=== HayChat Server - Threaded Architecture ===")

	config, configErr := loadConfig()
	if len(configErr) > 0 {
		fmt.eprintfln("[Startup] %s", configErr)
		delete(configErr)
		mainExitStartupFailure()
	}
	fmt.println("Configuration loaded:")
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
	retiredVariables := retiredConfigVariablesSet()
	for key in retiredVariables {
		fmt.eprintfln("[Startup] %s is no longer used and is ignored (#31)", key)
	}
	delete(retiredVariables)

	config.networkSocketName = fmt.aprintf("%s_network", SERVER_SOCKET)
	config.databaseSocketName = fmt.aprintf("%s_database", SERVER_SOCKET)

	pm := initProcessManager(&config)

	mainInterruptRequested = false
	mainInterruptShutdownQueued = false
	registerMainInterruptHandler()

	fmt.println("=== Starting Service Threads ===")
	if !spawnProcess(&pm, .Database) {
		fmt.eprintln("[Startup] failed to start the database service thread")
		pm.shouldShutdown = true
		shutdownAllProcesses(&pm)
		mainExitStartupFailure()
	}
	if databaseStartupErr := waitForDatabaseStartupAck(&pm); len(databaseStartupErr) > 0 {
		fmt.eprintfln("[Startup] %s", databaseStartupErr)
		pm.shouldShutdown = true
		shutdownAllProcesses(&pm)
		delete(databaseStartupErr)
		mainExitStartupFailure()
	}
	if !spawnProcess(&pm, .Network) {
		fmt.eprintln("[Startup] failed to start the network service thread")
		pm.shouldShutdown = true
		shutdownAllProcesses(&pm)
		mainExitStartupFailure()
	}

	fmt.println("=== Server Running ===")
	fmt.println("Main thread is supervising network and database threads")

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
	// Protocol 25 (D17): which accounts are restricted, before presence goes out.
	MainRouterState_loadRestrictedUsers(pm, &routerState)

	lastStatusLog := time.now()
	lastRegistrationSweep := time.tick_now()
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

		// D13: registering sessions have REGISTER_SESSION_SECONDS; checked once a second.
		if time.tick_since(lastRegistrationSweep) >= time.Second {
			lastRegistrationSweep = time.tick_now()
			MainRouterState_expireRegisteringSessions(pm, &routerState, lastRegistrationSweep)
		}

		if time.since(lastStatusLog) >= SERVER_STATUS_LOG_INTERVAL {
			mainLogStatus(pm, &routerState)
			lastStatusLog = time.now()
		}

		// Sleep on the queue instead of spinning; a push wakes the wait at once.
		if running && processed == 0 {
			IPC_Client_wait(pm.config.mainFd, MAIN_IDLE_WAIT)
		}
	}

	mainLogStatus(pm, &routerState)
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
	case NetworkSendData,
	     NetworkBroadcast,
	     NetworkDisconnectPeer,
	     NetworkVoiceRoute,
	     NetworkVoiceReset:
	// Commands are generated by main and should not loop back here.
	case NetworkVoiceSessionOpen:
		// Never addressed to main; wipe the keys rather than drop them as they are.
		stray := msg
		IPC__message_deinit(&stray)
	case NetworkPeerConnected:
		routerState.connectedPeers[m.peerId] = true
		MainRouterState_setPeerSession(routerState, m.peerId, RouterPeerSession_init())
	case NetworkPeerDisconnected:
		MainRouterState_handlePeerDisconnected(pm, routerState, m.peerId)
	case NetworkDataReceived:
		MainRouterState_handleNetworkDataReceived(pm, routerState, m)
		delete(m.data)
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
	case ProcessRestart, Wake:
	// Main sends ProcessRestart to the services (restartProcess) and never receives one; a Wake
	// only ends IPC_Client_wait early.
	case ProcessError:
		fmt.printfln("[Main] Process error: %s\n", m.error)
	case:
	}
	return true
}
