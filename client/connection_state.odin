package client

import "../common"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:time"

// The UI thread's copy of one server's connection state. It changes only through runtime
// events (and the State actions below), so the view can read it without the worker lock.
// Every string is owned.
ServerConnection :: struct {
	serverID:                 int,
	status:                   ClientConnectionStatus,
	failureKind:              ClientConnectFailureKind,
	retryable:                bool,
	// When the worker retries, for the countdown. Meaningful while status is Disconnected.
	retryAt:                  time.Tick,
	// True when the last attempt failed before signing in (as opposed to a lost session).
	lastAttemptFailed:        bool,
	userID:                   int,
	nickname:                 string,
	// Whether the server says this account is an admin: from sign-in, then from
	// ServerAccountUpdated when an admin changes the role from a client (protocol 14, #41). A
	// role changed directly in the database shows up on the next connection.
	isAdmin:                  bool,
	// The account's effective server permissions (protocol 23): from ServerAuthSuccess, then
	// from ServerAccountUpdated whenever an admin changes a role it holds or the roles it holds.
	// Like isAdmin it only decides which controls are drawn (State_hasPermission).
	permissions:              common.ServerPermissions,
	// Whether an admin set this account's name and locked it (protocol 14): the server keeps
	// nickname whatever display name the client connects with.
	nicknameLocked:           bool,
	// The transport's session counter from Connected, so a voice engine binds to this
	// session and no later one (ClientTransportVoiceBinding).
	sessionGeneration:        u64,
	// The raw reason from the transport or server.
	detail:                   string,
	// The key a server offered that did not match the pin, for "Trust the new key".
	offeredServerPublicKey:   string,
	offeredServerFingerprint: string,
	// Protocol 25 (#43 G2, registration.odin). The server's registration mode (from sign-in,
	// ServerRegistrationRequired and ServerRegistrationMode) and whether this account is
	// restricted (sign-in and ServerAccountUpdated).
	registrationMode:         common.RegistrationMode,
	isRestricted:             bool,
	// Protocol 27 (D18): the server's attachment limits and this account's stored bytes from
	// sign-in, the stored bytes then counted up by this client's own uploads
	// (State_attachmentLimits, attachments.odin).
	attachmentLimits:         common.AttachmentLimits,
	// The sign-up screen: its phase, the server's sentence for it (owned), and the request's
	// state from ServerRegistrationRequired.
	signUp:                   SignUpPhase,
	signUpMessage:            string,
	signUpRequestStatus:      common.RegistrationRequestStatus,
}

ServerConnection_deinit :: proc(connection: ^ServerConnection) {
	delete(connection.signUpMessage)
	delete(connection.nickname)
	delete(connection.detail)
	delete(connection.offeredServerPublicKey)
	delete(connection.offeredServerFingerprint)
	connection^ = {}
}

@(private = "file")
ServerConnection_setDetail :: proc(connection: ^ServerConnection, detail: ^string) {
	delete(connection.detail)
	connection.detail = detail^
	detail^ = ""
}

@(private = "file")
ServerConnection_clearOfferedKey :: proc(connection: ^ServerConnection) {
	delete(connection.offeredServerPublicKey)
	delete(connection.offeredServerFingerprint)
	connection.offeredServerPublicKey = ""
	connection.offeredServerFingerprint = ""
}

State_serverConnectionIndex :: proc(state: State, serverID: int) -> int {
	for index in 0 ..< len(state.serverConnections) {
		if state.serverConnections[index].serverID == serverID {
			return index
		}
	}
	return -1
}

// Returns the connection entry for serverID, creating an idle one. The pointer is valid until
// the next entry is added or removed.
State_serverConnection :: proc(state: ^State, serverID: int) -> ^ServerConnection {
	if index := State_serverConnectionIndex(state^, serverID); index >= 0 {
		return &state.serverConnections[index]
	}
	append(&state.serverConnections, ServerConnection{serverID = serverID})
	return &state.serverConnections[len(state.serverConnections) - 1]
}

State_removeServerConnection :: proc(state: ^State, serverID: int) {
	if index := State_serverConnectionIndex(state^, serverID); index >= 0 {
		ServerConnection_deinit(&state.serverConnections[index])
		ordered_remove(&state.serverConnections, index)
	}
}

// Sets the mirror from a transport that the worker is not running yet: either queued to
// connect, or failed because its config cannot work.
State_resetServerConnection :: proc(state: ^State, transport: ^ClientServerTransport) {
	connection := State_serverConnection(state, transport.serverID)
	serverID := transport.serverID
	ServerConnection_deinit(connection)
	connection.serverID = serverID
	if transport.connection.status == .Failed {
		connection.status = .Failed
		connection.failureKind = classifyConnectFailure(transport.lastError)
		connection.retryable = false
		connection.lastAttemptFailed = true
		connection.detail = strings.clone(transport.lastError)
	} else {
		connection.status = .Connecting
	}
}

State_isServerConnected :: proc(state: ^State, serverID: int) -> bool {
	index := State_serverConnectionIndex(state^, serverID)
	return index >= 0 && state.serverConnections[index].status == .Established
}

// The signed-in user ID on serverID, or 0 while not signed in.
State_selfUserID :: proc(state: ^State, serverID: int) -> int {
	index := State_serverConnectionIndex(state^, serverID)
	if index < 0 || state.serverConnections[index].status != .Established {
		return 0
	}
	return state.serverConnections[index].userID
}

// Whether the account signed in on serverID is an admin there, per its ServerAuthSuccess.
// False while not signed in. Only decides which controls the view offers.
State_isServerAdmin :: proc(state: ^State, serverID: int) -> bool {
	index := State_serverConnectionIndex(state^, serverID)
	return(
		index >= 0 &&
		state.serverConnections[index].status == .Established &&
		state.serverConnections[index].isAdmin \
	)
}

// The effective server permissions of the account signed in on serverID (protocol 23): every
// permission for an admin, the union of its roles' otherwise. Empty while not signed in. Only
// decides which controls the view offers; the server checks every request.
State_serverPermissions :: proc(state: ^State, serverID: int) -> common.ServerPermissions {
	index := State_serverConnectionIndex(state^, serverID)
	if index < 0 || state.serverConnections[index].status != .Established {
		return {}
	}
	connection := state.serverConnections[index]
	if connection.isAdmin {
		return common.SERVER_PERMISSIONS_ALL
	}
	return connection.permissions
}

// Whether the account signed in on serverID holds permission there (State_serverPermissions).
State_hasPermission :: proc(
	state: ^State,
	serverID: int,
	permission: common.ServerPermission,
) -> bool {
	return permission in State_serverPermissions(state, serverID)
}

// Whether the account may see the Admin section on serverID: an admin, or a holder of any
// delegated permission.
State_hasAdminSection :: proc(state: ^State, serverID: int) -> bool {
	return State_serverPermissions(state, serverID) & common.SERVER_PERMISSIONS_ASSIGNABLE != {} ||
		State_isServerAdmin(state, serverID)
}

State_serverConfig :: proc(state: ^State, serverID: int) -> (^Server, bool) {
	for index in 0 ..< len(state.config.servers) {
		if state.config.servers[index].id == serverID {
			return &state.config.servers[index], true
		}
	}
	return nil, false
}

// Writes the config file, but only for the real app (see State.persistConfig).
State_saveConfig :: proc(state: ^State) {
	if state.persistConfig {
		saveConfig(state.config)
	}
}

// Requests in flight died with the session, so their loading flags must not block new ones.
@(private = "file")
State_resetPendingRequests :: proc(state: ^State, serverID: int, reloadHistory: bool) {
	State_resetDirectRequests(state, serverID, reloadHistory)
	State_e2eeConnectionReset(state, serverID)
	State_resetReadMarkerSends(state, serverID)
	State_roomEditorConnectionReset(state, serverID)
	State_roomMembersConnectionReset(state, serverID)
	State_roomLogsConnectionReset(state, serverID)
	State_roomLogPendingConnectionReset(state, serverID)
	State_roomChainsConnectionReset(state, serverID)
	State_adminConnectionReset(state, serverID)
	State_registrationConnectionReset(state, serverID)
	cacheIndex := State_serverRoomCacheIndex(state^, serverID)
	if cacheIndex < 0 {
		return
	}
	cache := &state.server_room_caches[cacheIndex]
	cache.roomsLoading = false
	for index in 0 ..< len(cache.roomCaches) {
		roomCache := &cache.roomCaches[index]
		roomCache.isLoadingHistory = false
		// Messages may have arrived while disconnected; fetch the newest page again. Merging
		// by message ID keeps what is already loaded.
		if reloadHistory {
			roomCache.initialHistoryLoaded = false
		}
	}
}

// Keeps the previous failure's detail, so a retry still shows why the last attempt failed.
State_connectionStarted :: proc(state: ^State, event: ^ClientTransportRuntimeEvent) {
	connection := State_serverConnection(state, event.serverID)
	connection.status = .Connecting
}

// Takes ownership of the event's nickname and newly pinned key.
State_connectionEstablished :: proc(state: ^State, event: ^ClientTransportRuntimeEvent) {
	connection := State_serverConnection(state, event.serverID)
	connection.status = .Established
	connection.failureKind = .None
	connection.retryable = false
	connection.lastAttemptFailed = false
	connection.userID = event.userID
	connection.isAdmin = event.isAdmin
	connection.permissions = event.permissions
	connection.nicknameLocked = event.nicknameLocked
	connection.sessionGeneration = event.sessionGeneration
	delete(connection.nickname)
	connection.nickname = event.nickname
	event.nickname = ""
	delete(connection.detail)
	connection.detail = ""
	ServerConnection_clearOfferedKey(connection)

	// The worker pinned the server's key on first use; remember it for the next start.
	if len(event.serverPublicKey) > 0 {
		if server, ok := State_serverConfig(state, event.serverID); ok {
			Server_setPins(server, event.serverPublicKey, event.serverFingerprint)
			State_saveConfig(state)
		}
	}

	State_resetPendingRequests(state, event.serverID, true)
	State_requestRoomList(state, event.serverID)
	State_requestDirectStateAfterConnect(state, event.serverID)
	State_e2eeConnected(state, event.serverID)
	// After the key store is loaded: messages queued for a key fetch again (protocol 17).
	State_directRequestQueuedKeys(state, event.serverID)
	State_roomChainsConnected(state, event.serverID)
	State_voiceConnected(state, event.serverID)
	State_rolesConnected(state, event.serverID)
	State_registrationConnectionChanged(state, event)
	State_registrationConnected(state, event.serverID)
}

// Takes ownership of the event's message and offered key.
State_connectionFailed :: proc(state: ^State, event: ^ClientTransportRuntimeEvent) {
	connection := State_serverConnection(state, event.serverID)
	connection.status = event.retryable ? .Disconnected : .Failed
	connection.failureKind = event.failureKind
	connection.retryable = event.retryable
	connection.retryAt = event.retryAt
	connection.lastAttemptFailed = true
	connection.userID = 0
	connection.isAdmin = false
	connection.permissions = {}
	connection.nicknameLocked = false
	ServerConnection_setDetail(connection, &event.message)
	ServerConnection_clearOfferedKey(connection)
	if event.failureKind == .ServerKeyChanged {
		connection.offeredServerPublicKey = event.serverPublicKey
		connection.offeredServerFingerprint = event.serverFingerprint
		event.serverPublicKey = ""
		event.serverFingerprint = ""
	}
	State_resetPendingRequests(state, event.serverID, false)
	State_voiceConnectionLost(state, event.serverID)
	// A kick or ban is not undone by Retry's reconnect, and neither is the voice it ended.
	// A declined sign-up is shown like a ban (D16).
	if event.failureKind == .Kicked || event.failureKind == .Banned {
		State_voiceEndedByAdmin(state, event.serverID)
	}
	State_registrationConnectionChanged(state, event)
}

// Takes ownership of the event's message.
State_connectionLost :: proc(state: ^State, event: ^ClientTransportRuntimeEvent) {
	connection := State_serverConnection(state, event.serverID)
	connection.status = .Disconnected
	connection.failureKind = .None
	connection.retryable = true
	connection.retryAt = event.retryAt
	connection.lastAttemptFailed = false
	connection.userID = 0
	connection.isAdmin = false
	connection.permissions = {}
	connection.nicknameLocked = false
	ServerConnection_setDetail(connection, &event.message)
	State_resetPendingRequests(state, event.serverID, false)
	State_voiceConnectionLost(state, event.serverID)
	State_registrationConnectionChanged(state, event)
}

// ServerAccountUpdated (protocol 14, #41): an admin changed this account's role or name while
// it is connected. The admin flag and the name in the connection mirror change at once, so the
// admin controls appear or go without a reconnect. Takes ownership of the event's nickname.
State_accountUpdated :: proc(state: ^State, event: ^ClientTransportRuntimeEvent) {
	index := State_serverConnectionIndex(state^, event.serverID)
	if index < 0 || state.serverConnections[index].status != .Established {
		return
	}
	connection := &state.serverConnections[index]
	wasAdmin := connection.isAdmin
	hadApprove := State_hasPermission(state, event.serverID, .ApproveRegistrations)
	hadInvites := State_hasPermission(state, event.serverID, .CreateInvites)
	connection.isAdmin = event.isAdmin
	connection.permissions = event.permissions
	connection.nicknameLocked = event.nicknameLocked
	connection.isRestricted = event.isRestricted
	if len(event.nickname) > 0 {
		delete(connection.nickname)
		connection.nickname = event.nickname
		event.nickname = ""
	}
	// A room form for a server where room management just went away would only be refused;
	// close it. The Members page follows its own rights (State_roomEditorRoomChanged).
	if !State_hasPermission(state, event.serverID, .ManageRooms) &&
	   (state.roomEditor.mode == .Create || state.roomEditor.mode == .Edit) {
		State_closeRoomEditorForServer(state, event.serverID)
	}
	if wasAdmin && !connection.isAdmin {
		State_rolesAdminLost(state, event.serverID)
	}
	// An admin may have handed this account the room permissions: the Admin section's room list
	// needs every room.
	if State_hasPermission(state, event.serverID, .ManageRooms) ||
	   State_hasPermission(state, event.serverID, .ManageRoomMembers) {
		State_noteRoomManagementGained(state, event.serverID)
	}
	State_registrationAccountUpdated(state, event.serverID, hadApprove, hadInvites)
}

// "Retry now": connect immediately instead of waiting for the backoff (or after a failure
// that stopped retrying).
State_retryConnection :: proc(state: ^State, serverID: int) {
	transportIndex := State_selectedTransportIndexForServerID(state^, serverID)
	if transportIndex < 0 {
		return
	}
	transport := &state.serverTransports[transportIndex]
	ClientNetworkWorker_lock(state.networkWorker)
	configInvalid := transport.configInvalid
	ClientServerTransport_requestConnect(transport, {})
	ClientNetworkWorker_unlock(state.networkWorker)
	if !configInvalid {
		State_serverConnection(state, serverID).status = .Connecting
	}
}

// "Trust the new key": replaces the pin with the key the server offered, saves the config,
// and reconnects.
State_trustNewServerKey :: proc(state: ^State, serverID: int) {
	connectionIndex := State_serverConnectionIndex(state^, serverID)
	if connectionIndex < 0 {
		return
	}
	connection := &state.serverConnections[connectionIndex]
	if connection.failureKind != .ServerKeyChanged ||
	   len(connection.offeredServerPublicKey) == 0 {
		return
	}
	server, serverOK := State_serverConfig(state, serverID)
	transportIndex := State_selectedTransportIndexForServerID(state^, serverID)
	if !serverOK || transportIndex < 0 {
		return
	}
	Server_setPins(
		server,
		connection.offeredServerPublicKey,
		connection.offeredServerFingerprint,
	)
	State_saveConfig(state)

	transport := &state.serverTransports[transportIndex]
	ClientNetworkWorker_lock(state.networkWorker)
	ClientServerTransport_setPins(
		transport,
		server.pinned_server_public_key,
		server.pinned_server_fingerprint,
	)
	ClientServerTransport_requestConnect(transport, {})
	ClientNetworkWorker_unlock(state.networkWorker)

	ServerConnection_clearOfferedKey(connection)
	connection.status = .Connecting
	connection.failureKind = .None
}

ConnectionBannerTone :: enum u8 {
	Quiet, // Connected: shown only as a muted status line
	Progress, // Connecting or waiting to reconnect
	Error, // Stopped until the user acts
}

// What the view shows about the selected server's connection. Strings are allocated with the
// view model's allocator.
ConnectionBanner :: struct {
	hasServer:    bool,
	tone:         ConnectionBannerTone,
	// One-line status, e.g. "Connected as alice" or "Reconnecting in 4 s".
	summary:      string,
	// The longer explanation shown above the room while not connected; empty when connected.
	text:         string,
	showRetry:    bool,
	showTrustKey: bool,
	showSettings: bool,
	// How long until the countdown text changes; 0 when nothing is counting down.
	refreshIn:    time.Duration,
}

// Explains a failure in words a tester can act on.
describeConnectFailure :: proc(
	kind: ClientConnectFailureKind,
	detail, nickname, fingerprint: string,
	allocator := context.temp_allocator,
) -> string {
	switch kind {
	case .NameUnavailable:
		return fmt.aprintf(
			"The name %s is already in use on this server (or bound to another device's " +
			"key). Choose another name in Settings, or one for this server only in its " +
			"Server settings.",
			nickname,
			allocator = allocator,
		)
	case .ServerKeyChanged:
		return fmt.aprintf(
			"The server's identity key does not match the one pinned for it. That is " +
			"expected after the server was reset or reinstalled, but it can also mean " +
			"someone is impersonating it. Trust the new key only if you expected this. " +
			"New key fingerprint: %s",
			len(fingerprint) > 0 ? fingerprint : "unknown",
			allocator = allocator,
		)
	case .ProtocolMismatch:
		return strings.clone(
			"This client and the server speak different protocol versions. Update the " +
			"client or the server so they match.",
			allocator,
		)
	case .InvalidName:
		return strings.clone(
			"Display names must be 3 to 32 bytes long (accented letters and emoji count as " +
			"2 to 4). Choose another name in Settings.",
			allocator,
		)
	case .InvalidIdentity:
		return strings.clone(
			"The identity key in your config file is missing or corrupt.",
			allocator,
		)
	case .Kicked:
		return adminEndedSessionText(
			"An admin removed you from this server",
			detail,
			CLIENT_KICKED_MESSAGE,
			". Press Retry to connect again.",
			allocator,
		)
	case .Banned:
		return adminEndedSessionText(
			"This account is banned from this server",
			detail,
			SERVER_BANNED_MESSAGE,
			". An admin has to lift the ban before you can connect again.",
			allocator,
		)
	case .RegistrationRequired:
		return strings.clone(
			len(detail) > 0 ? detail : CLIENT_REGISTRATION_ENDED_MESSAGE,
			allocator,
		)
	case .RegistrationPending:
		return strings.clone(
			"Your sign-up request is waiting for approval. Press Check again later.",
			allocator,
		)
	case .RegistrationDeclined:
		return strings.clone(
			len(detail) > 0 ? detail : common.REGISTRATION_DECLINED_MESSAGE,
			allocator,
		)
	case .RegistrationBusy:
		return strings.clone(
			"Too many people are signing up on this server right now; HayChat tries again.",
			allocator,
		)
	case .None, .Unreachable, .Other:
	}
	if len(detail) == 0 {
		return strings.clone("unknown error", allocator)
	}
	return strings.clone(detail, allocator)
}

// "<lead>: <reason><tail>" for a kick or ban, or "<lead><tail>" without a reason. detail is the
// raw failure, which starts with prefix (the sentence classifyConnectFailure matched) and may
// carry ": reason" after it.
@(private = "file")
adminEndedSessionText :: proc(
	lead, detail, prefix, tail: string,
	allocator: mem.Allocator,
) -> string {
	reason := strings.trim_prefix(detail, prefix)
	reason = strings.trim_prefix(reason, ": ")
	reason = strings.trim_space(reason)
	if len(reason) == 0 {
		return strings.concatenate({lead, tail}, allocator)
	}
	return strings.concatenate({lead, " (reason: ", reason, ")", tail}, allocator)
}

// Whole seconds left until `at`, rounded up, and how long until that number changes.
@(private = "file")
secondsUntil :: proc(at, now: time.Tick) -> (seconds: int, changesIn: time.Duration) {
	remaining := time.tick_diff(now, at)
	if remaining <= 0 {
		return 0, 0
	}
	seconds = int((remaining + time.Second - 1) / time.Second)
	changesIn = remaining - time.Duration(seconds - 1) * time.Second
	return
}

// Builds the selected server's connection status for drawing at `now`.
buildConnectionBanner :: proc(
	state: ^State,
	now: time.Tick,
	allocator := context.temp_allocator,
) -> (
	banner: ConnectionBanner,
) {
	server, serverOK := State_serverConfig(state, state.selected_server_id)
	connectionIndex := State_serverConnectionIndex(state^, state.selected_server_id)
	if !serverOK || connectionIndex < 0 {
		return
	}
	connection := &state.serverConnections[connectionIndex]
	banner.hasServer = true
	serverName := server.name
	// The name this client signs in with here: the server's own, or the global one.
	nickname := Server_displayName(server^, state.config)

	switch connection.status {
	case .Established:
		banner.tone = .Quiet
		banner.summary = fmt.aprintf("Connected as %s", connection.nickname, allocator = allocator)
	case .Registering:
		// The sign-up screen explains itself (view_registration.odin).
		banner.tone = .Progress
		summary := "Sign-up needed"
		if connection.signUp == .Pending {
			summary = "Waiting for approval"
		}
		banner.summary = strings.clone(summary, allocator)
	case .Connecting, .Handshaking:
		banner.tone = .Progress
		banner.summary = strings.clone("Connecting…", allocator)
		switch {
		case connection.lastAttemptFailed && len(connection.detail) > 0:
			reason := describeConnectFailure(
				connection.failureKind,
				connection.detail,
				nickname,
				"",
			)
			banner.text = fmt.aprintf(
				"Connecting to %s… The last attempt failed: %s",
				serverName,
				reason,
				allocator = allocator,
			)
		case len(connection.detail) > 0:
			// The detail of a lost session: this is a reconnect.
			banner.text = fmt.aprintf("Reconnecting to %s…", serverName, allocator = allocator)
		case:
			banner.text = fmt.aprintf("Connecting to %s…", serverName, allocator = allocator)
		}
	case .Disconnected:
		banner.tone = .Progress
		banner.showRetry = true
		seconds, changesIn := secondsUntil(connection.retryAt, now)
		banner.refreshIn = changesIn
		countdown := "Reconnecting…"
		if seconds > 0 {
			countdown = fmt.tprintf("Reconnecting in %d s", seconds)
		}
		banner.summary = strings.clone(countdown, allocator)
		if connection.lastAttemptFailed {
			reason := describeConnectFailure(
				connection.failureKind,
				connection.detail,
				nickname,
				"",
			)
			banner.text = fmt.aprintf(
				"Could not connect to %s: %s. %s",
				serverName,
				reason,
				countdown,
				allocator = allocator,
			)
		} else {
			banner.text = fmt.aprintf(
				"Disconnected from %s. %s",
				serverName,
				countdown,
				allocator = allocator,
			)
		}
	case .Failed:
		banner.tone = .Error
		banner.summary = strings.clone("Not connected", allocator)
		reason := describeConnectFailure(
			connection.failureKind,
			connection.detail,
			nickname,
			connection.offeredServerFingerprint,
		)
		switch connection.failureKind {
		case .Kicked, .Banned:
			// Not a failure to connect: an admin ended the session (D4, D5).
			banner.summary = strings.clone(
				connection.failureKind == .Banned ? "Banned" : "Kicked",
				allocator,
			)
			banner.text = fmt.aprintf("%s: %s", serverName, reason, allocator = allocator)
		case .RegistrationRequired, .RegistrationPending, .RegistrationDeclined:
			// The sign-up screen shows these with its own buttons (Check again, Start again).
			summary := "Sign-up ended"
			if connection.failureKind == .RegistrationPending {
				summary = "Waiting for approval"
			} else if connection.failureKind == .RegistrationDeclined {
				summary = "Sign-up declined"
			}
			banner.summary = strings.clone(summary, allocator)
			banner.text = fmt.aprintf("%s: %s", serverName, reason, allocator = allocator)
		case .None,
		     .Unreachable,
		     .Other,
		     .NameUnavailable,
		     .ServerKeyChanged,
		     .ProtocolMismatch,
		     .InvalidName,
		     .InvalidIdentity,
		     .RegistrationBusy:
			banner.text = fmt.aprintf(
				"Could not connect to %s: %s",
				serverName,
				reason,
				allocator = allocator,
			)
		}
		banner.showTrustKey =
			connection.failureKind == .ServerKeyChanged &&
			len(connection.offeredServerPublicKey) > 0
		banner.showSettings =
			connection.failureKind == .NameUnavailable || connection.failureKind == .InvalidName
		// Retrying cannot fix these on its own, but the button still lets the user try again
		// after fixing the server side. A local config problem needs Settings instead.
		banner.showRetry =
			connection.failureKind != .InvalidIdentity && connection.failureKind != .InvalidName
	case .Idle:
		banner.tone = .Progress
		banner.showRetry = true
		banner.summary = strings.clone("Not connected", allocator)
		banner.text = fmt.aprintf("Not connected to %s", serverName, allocator = allocator)
	}
	return
}
