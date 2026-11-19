package client

import "../common"
import "core:encoding/cbor"
import "core:math/rand"
import "core:strings"
import "core:sync"
import "core:time"
import "vendor:ENet"

// The connect state machine. The network worker drives it through
// ClientServerTransport_serviceRuntime, so connecting, authenticating, and reconnecting never
// block the UI thread. Every proc here runs with the worker mutex held (or before the worker
// starts), and reports progress as runtime events that State mirrors for the view.
//
//   Idle ──requestConnect──▶ Disconnected (waits for nextAttemptAt)
//   Disconnected ──attempt──▶ Connecting ──ENet CONNECT──▶ Handshaking ──auth──▶ Established
//   Connecting/Handshaking ──retryable failure──▶ Disconnected (backoff)
//   Connecting/Handshaking ──permanent failure──▶ Failed (until requestConnect)
//   Established ──disconnect / session error──▶ Disconnected (backoff)
//   Handshaking ──ServerRegistrationRequired──▶ Registering ──Created──▶ Established
//   Registering ──Declined / the server ends the session──▶ Failed (until requestConnect)

// How long ENet may take to establish the UDP connection.
CONNECT_TIMEOUT :: 5 * time.Second
// How long the server may take to finish the handshake once connected.
HANDSHAKE_TIMEOUT :: 10 * time.Second
RECONNECT_BASE_DELAY :: 1 * time.Second
RECONNECT_MAX_DELAY :: 30 * time.Second
// Each delay is shortened by up to this fraction, so clients that lost the same server do not
// all come back at the same instant.
RECONNECT_JITTER_FRACTION :: 0.2

SERVER_KEY_CHANGED_MESSAGE :: "server identity key changed"
NOT_CONNECTED_MESSAGE :: "Not connected to the server"
// The server's replies for failures that retrying cannot fix (see server/main.odin).
SERVER_IDENTITY_UNAVAILABLE_MESSAGE :: "user identity is unavailable"
SERVER_UNSUPPORTED_VERSION_MESSAGE :: "Unsupported protocol version"
SERVER_INVALID_NICKNAME_MESSAGE :: "Invalid nickname length"
CLIENT_INVALID_NICKNAME_MESSAGE :: "client display name must be between 3 and 32 bytes"
CLIENT_INVALID_IDENTITY_MESSAGE :: "client identity keys are missing or invalid"
// Protocol 14. The server refuses a banned account's sign-in with this message, followed by
// ": reason" when the ban has one (server/router_admin.odin), and the client builds the same
// text from ServerSessionEnded{Banned}. A kick only ever arrives as ServerSessionEnded{Kicked},
// which the client turns into CLIENT_KICKED_MESSAGE (and ": reason").
SERVER_BANNED_MESSAGE :: "This account is banned from this server"
CLIENT_KICKED_MESSAGE :: "You were kicked from this server"
// Protocol 25 (#43 G2): a registering session the server ended (after a refusal such as "Sign-up
// took too long", or without one) fails with this, then ": " and the reason; it is not
// retried, and the sign-up screen offers to start again. A session that ended while its
// request was pending fails with common.REGISTRATION_PENDING_MESSAGE, which the waiting screen
// shows (Check again), and a declined one with the server's sentence, which starts with
// common.REGISTRATION_DECLINED_MESSAGE and is shown like a ban (D16).
CLIENT_REGISTRATION_ENDED_MESSAGE :: "Sign-up ended"
CLIENT_REGISTRATION_CLOSED_REASON :: "the server closed the connection"

ClientConnectionStatus :: enum u8 {
	Idle, // Never asked to connect
	Connecting, // Waiting for the ENet connection
	Handshaking, // ClientHello sent, waiting for the server to authenticate us
	Established,
	Failed, // Stopped: retrying cannot help until the user changes something
	Disconnected, // Waiting for the next attempt at nextAttemptAt
	// Protocol 25 (#43 G2): the server answered ServerRegistrationRequired; the transport is
	// active and only ClientRegister may be sent until the account is created.
	Registering,
}

ClientConnectFailureKind :: enum u8 {
	None,
	Unreachable, // Timeouts, resolution failures, dropped connections: retried
	Other, // Any other server or transport error: retried
	NameUnavailable, // The nickname is bound to another key on this server
	ServerKeyChanged, // The server's identity key does not match the pin
	ProtocolMismatch, // Client and server speak different protocol versions
	InvalidName, // The display name is too short or too long
	InvalidIdentity, // The local identity keys are missing or corrupt
	Kicked, // An admin ended the session (protocol 14); waits for the user to retry
	Banned, // The account is banned on this server (protocol 14)
	RegistrationRequired, // Protocol 25: the sign-up session ended before an account existed
	RegistrationPending, // The sign-up request waits for approval; Check again reconnects
	RegistrationDeclined, // An approver declined the request (shown like a ban, D16)
	RegistrationBusy, // Too many sign-ups at once on the server: retried
}

ClientConnection :: struct {
	status:         ClientConnectionStatus,
	// Consecutive failed attempts; picks the next backoff delay and resets on success.
	failedAttempts: int,
	nextAttemptAt:  time.Tick,
	// When the current Connecting or Handshaking step times out.
	deadline:       time.Tick,
	// The server key was pinned on first use during this handshake; Connected reports it.
	newlyPinned:    bool,
	// The server address for the next attempt, resolved by the network worker before it takes
	// its mutex (see ClientNetworkWorker_resolveDueAddresses). startConnect consumes it.
	resolved:       ClientResolvedAddress,
}

ClientResolvedAddress :: struct {
	address: ENet.Address,
	ok:      bool, // The host name resolved
	ready:   bool, // A lookup ran for the next attempt
}

// Delay before reconnect attempt `failedAttempts` (1 for the first retry): 1 s, 2 s, 4 s, …
// capped at RECONNECT_MAX_DELAY, then shortened by jitter * RECONNECT_JITTER_FRACTION.
// jitter is in [0, 1).
reconnectDelay :: proc(failedAttempts: int, jitter: f64) -> time.Duration {
	delay := RECONNECT_BASE_DELAY
	for _ in 1 ..< max(failedAttempts, 1) {
		if delay >= RECONNECT_MAX_DELAY {
			break
		}
		delay *= 2
	}
	delay = min(delay, RECONNECT_MAX_DELAY)
	jitterFraction := clamp(jitter, 0, 1) * RECONNECT_JITTER_FRACTION
	return delay - time.Duration(f64(delay) * jitterFraction)
}

// Sorts a raw failure message (from the server or the transport) into a kind the UI can
// explain.
classifyConnectFailure :: proc(message: string) -> ClientConnectFailureKind {
	switch message {
	case "":
		return .None
	case SERVER_IDENTITY_UNAVAILABLE_MESSAGE:
		return .NameUnavailable
	case SERVER_KEY_CHANGED_MESSAGE:
		return .ServerKeyChanged
	case SERVER_UNSUPPORTED_VERSION_MESSAGE:
		return .ProtocolMismatch
	case SERVER_INVALID_NICKNAME_MESSAGE, CLIENT_INVALID_NICKNAME_MESSAGE:
		return .InvalidName
	case CLIENT_INVALID_IDENTITY_MESSAGE:
		return .InvalidIdentity
	}
	if strings.has_prefix(message, SERVER_BANNED_MESSAGE) {
		return .Banned
	}
	if strings.has_prefix(message, CLIENT_KICKED_MESSAGE) {
		return .Kicked
	}
	if strings.has_prefix(message, CLIENT_REGISTRATION_ENDED_MESSAGE) {
		return .RegistrationRequired
	}
	if strings.has_prefix(message, common.REGISTRATION_PENDING_MESSAGE) {
		return .RegistrationPending
	}
	if strings.has_prefix(message, common.REGISTRATION_DECLINED_MESSAGE) {
		return .RegistrationDeclined
	}
	if message == common.REGISTRATION_BUSY_MESSAGE {
		return .RegistrationBusy
	}
	if strings.has_prefix(message, "timed out") ||
	   strings.has_prefix(message, "could not reach") ||
	   strings.has_prefix(message, "failed to resolve") {
		return .Unreachable
	}
	return .Other
}

// Retrying helps only when the cause can go away on its own (server down, network blip).
connectFailureIsRetryable :: proc(kind: ClientConnectFailureKind) -> bool {
	switch kind {
	case .None, .Unreachable, .Other, .RegistrationBusy:
		return true
	case .NameUnavailable,
	     .ServerKeyChanged,
	     .ProtocolMismatch,
	     .InvalidName,
	     .InvalidIdentity,
	     .Kicked,
	     .Banned,
	     .RegistrationRequired,
	     .RegistrationPending,
	     .RegistrationDeclined:
		// A kick is not undone by the next automatic reconnect a second later (D5): the
		// client waits until the user asks to connect again.
		return false
	}
	return true
}

// Compares a server identity key with a pin. An empty pin means the server was never seen.
classifyServerIdentity :: proc(
	pinnedPublicKey, pinnedFingerprint: string,
	serverPublicKey: common.IdentityPublicKeyBytes,
) -> common.PeerTrustState {
	if len(pinnedPublicKey) == 0 && len(pinnedFingerprint) == 0 {
		return .Unknown
	}
	serverPublicKeyHex := common.identityPublicKeyToHex(serverPublicKey)
	defer delete(serverPublicKeyHex)
	serverFingerprintHex := common.fingerprintToHex(
		common.fingerprintIdentityPublicKey(serverPublicKey),
	)
	defer delete(serverFingerprintHex)
	if pinnedPublicKey == serverPublicKeyHex && pinnedFingerprint == serverFingerprintHex {
		return .Trusted
	}
	return .Changed
}

// Pins the key on first use. Returns false when the key contradicts the existing pin.
ClientServerTransport_pinServerIdentity :: proc(
	transport: ^ClientServerTransport,
	serverPublicKey: common.IdentityPublicKeyBytes,
) -> bool {
	switch classifyServerIdentity(
		transport.pinnedServerPublicKey,
		transport.pinnedServerFingerprint,
		serverPublicKey,
	) {
	case .Unknown:
		delete(transport.pinnedServerPublicKey)
		delete(transport.pinnedServerFingerprint)
		transport.pinnedServerPublicKey = common.identityPublicKeyToHex(serverPublicKey)
		transport.pinnedServerFingerprint = common.fingerprintToHex(
			common.fingerprintIdentityPublicKey(serverPublicKey),
		)
		transport.connection.newlyPinned = true
		transport.transport.peerTrustState = .Trusted
		return true
	case .Trusted:
		transport.transport.peerTrustState = .Trusted
		return true
	case .Changed:
		transport.transport.peerTrustState = .Changed
		transport.rejectedServerPublicKey = serverPublicKey
		transport.hasRejectedServerKey = true
		return false
	}
	return false
}

// Replaces the transport's pins, e.g. after the user trusted a changed key. The strings are
// borrowed and cloned.
ClientServerTransport_setPins :: proc(
	transport: ^ClientServerTransport,
	publicKey, fingerprint: string,
) {
	delete(transport.pinnedServerPublicKey)
	delete(transport.pinnedServerFingerprint)
	transport.pinnedServerPublicKey = strings.clone(publicKey)
	transport.pinnedServerFingerprint = strings.clone(fingerprint)
	transport.hasRejectedServerKey = false
	transport.rejectedServerPublicKey = {}
}

ClientServerTransport_isConnected :: proc(transport: ^ClientServerTransport) -> bool {
	return(
		transport.connection.status == .Established &&
		transport.transport.phase == .Established &&
		ClientServerTransport_hasLiveENetSession(transport) \
	)
}

// Asks the worker to connect at `at` (a zero tick means as soon as possible). Any session in
// progress is dropped. Transports whose config cannot work stay failed.
ClientServerTransport_requestConnect :: proc(transport: ^ClientServerTransport, at: time.Tick) {
	if transport.configInvalid {
		return
	}
	if transport.connection.status != .Disconnected && transport.connection.status != .Idle &&
	   transport.connection.status != .Failed {
		ClientServerTransport_clearSessionRuntimeState(transport)
	}
	transport.connection.status = .Disconnected
	transport.connection.nextAttemptAt = at
}

// True when the next connect attempt is due, so it needs the server address.
ClientServerTransport_attemptIsDue :: proc(
	transport: ^ClientServerTransport,
	now: time.Tick,
) -> bool {
	return transport.connection.status == .Disconnected &&
		time.tick_diff(transport.connection.nextAttemptAt, now) >= 0
}

// Resolves host (a name or an IP address). The lookup can block for as long as the system
// resolver takes, so the network worker runs it without holding its mutex.
clientResolveServerAddress :: proc(host: string, port: i32) -> (address: ENet.Address, ok: bool) {
	address.port = u16(port)
	if len(host) == 0 || !clientEnsureENetInitialized() {
		return address, false
	}
	hostCString := strings.clone_to_cstring(host, context.temp_allocator)
	// Not folded into the return: its operands are evaluated left to right, so address would
	// be copied before the lookup fills in its host.
	ok = ENet.address_set_host(&address, hostCString) == 0
	return address, ok
}

// Advances the state machine by one non-blocking step.
ClientServerTransport_serviceConnection :: proc(
	transport: ^ClientServerTransport,
	now: time.Tick,
) -> (
	ClientTransportRuntimeEvent,
	bool,
) {
	switch transport.connection.status {
	case .Idle, .Failed:
		return {}, false
	case .Disconnected:
		if time.tick_diff(transport.connection.nextAttemptAt, now) < 0 {
			return {}, false
		}
		return ClientServerTransport_startConnect(transport, now)
	case .Connecting, .Handshaking:
		return ClientServerTransport_serviceHandshake(transport, now)
	case .Established:
		// A failed send or an undecryptable packet tears the session down from inside the
		// transport; notice it here and reconnect.
		if !ClientServerTransport_isConnected(transport) {
			reason := len(transport.lastError) > 0 ? transport.lastError : "connection lost"
			return ClientServerTransport_lostConnection(transport, now, reason)
		}
		return ClientServerTransport_serviceEstablishedSession(transport, now)
	case .Registering:
		return ClientServerTransport_serviceRegisteringSession(transport, now)
	}
	return {}, false
}

@(private = "file")
ClientServerTransport_startConnect :: proc(
	transport: ^ClientServerTransport,
	now: time.Tick,
) -> (
	ClientTransportRuntimeEvent,
	bool,
) {
	ClientServerTransport_clearSessionRuntimeState(transport)
	transport.connection.newlyPinned = false
	transport.hasRejectedServerKey = false

	// A fresh ephemeral key per attempt keeps sessions independent.
	ephemeralPrivate, ephemeralPublic, ephemeralOK := common.generateKeyExchangeKeyPair()
	if !ephemeralOK {
		return ClientServerTransport_connectFailed(
			transport,
			now,
			"failed to generate client ephemeral key pair",
		)
	}
	transport.clientEphemeralPrivateKey = ephemeralPrivate
	transport.clientEphemeralPublicKey = ephemeralPublic

	if !clientEnsureENetInitialized() {
		return ClientServerTransport_connectFailed(transport, now, "failed to initialize ENet")
	}
	transport.enetHost = ENet.host_create(nil, 1, STARTUP_AUTH_CHANNEL_COUNT, 0, 0)
	if transport.enetHost == nil {
		return ClientServerTransport_connectFailed(
			transport,
			now,
			"failed to create ENet client host",
		)
	}

	// The worker resolves the address before it takes its mutex. Without it (tests driving the
	// state machine directly) the lookup runs here.
	resolved := transport.connection.resolved
	transport.connection.resolved = {}
	if !resolved.ready {
		resolved.address, resolved.ok = clientResolveServerAddress(
			transport.serverHost,
			transport.serverPort,
		)
	}
	address := resolved.address
	if !resolved.ok {
		return ClientServerTransport_connectFailed(
			transport,
			now,
			"failed to resolve the server address",
		)
	}

	transport.enetPeer = ENet.host_connect(
		transport.enetHost,
		&address,
		STARTUP_AUTH_CHANNEL_COUNT,
		0,
	)
	if transport.enetPeer == nil {
		return ClientServerTransport_connectFailed(
			transport,
			now,
			"failed to start the ENet connection",
		)
	}

	transport.connection.status = .Connecting
	transport.connection.deadline = time.tick_add(now, CONNECT_TIMEOUT)
	return ClientTransportRuntimeEvent{kind = .Connecting, serverID = transport.serverID}, true
}

@(private = "file")
ClientServerTransport_serviceHandshake :: proc(
	transport: ^ClientServerTransport,
	now: time.Tick,
) -> (
	ClientTransportRuntimeEvent,
	bool,
) {
	event: ENet.Event
	eventResult := ENet.host_service(transport.enetHost, &event, 0)
	if eventResult < 0 {
		return ClientServerTransport_connectFailed(
			transport,
			now,
			"could not reach the server: network error",
		)
	}
	if eventResult == 0 {
		if time.tick_diff(transport.connection.deadline, now) >= 0 {
			reason := "timed out waiting for the server to sign in"
			if transport.connection.status == .Connecting {
				reason = "timed out connecting to the server"
			}
			return ClientServerTransport_connectFailed(transport, now, reason)
		}
		return {}, false
	}

	switch event.type {
	case .CONNECT:
		if transport.connection.status != .Connecting {
			return {}, false
		}
		helloBytes, helloOK := ClientServerTransport_beginHandshake(transport)
		defer delete(helloBytes)
		if !helloOK ||
		   !ClientServerTransport_sendENetPacket(
				   transport.enetHost,
				   transport.enetPeer,
				   STARTUP_AUTH_CHANNEL_CHAT,
				   helloBytes,
			   ) {
			return ClientServerTransport_connectFailed(
				transport,
				now,
				"failed to send the client hello",
			)
		}
		transport.connection.status = .Handshaking
		transport.connection.deadline = time.tick_add(now, HANDSHAKE_TIMEOUT)
		return {}, false

	case .RECEIVE:
		if !ClientServerTransport_acceptReceiveChannel(transport, event.channelID) {
			ENet.packet_destroy(event.packet)
			return {}, false
		}
		packetBytes := ClientServerTransport_copyENetPacket(event.packet)
		result, _ := ClientServerTransport_handleIncomingPacket(transport, packetBytes)
		delete(packetBytes)
		if result.hasOpenedPacket {
			delete(result.openedPacket.payload)
		}
		if result.hasResponse {
			sent :=
				ClientServerTransport_hasLiveENetSession(transport) &&
				ClientServerTransport_sendENetPacket(
					transport.enetHost,
					transport.enetPeer,
					STARTUP_AUTH_CHANNEL_CHAT,
					result.responsePacketBytes,
				)
			delete(result.responsePacketBytes)
			if !sent && transport.transport.phase != .Failed {
				return ClientServerTransport_connectFailed(
					transport,
					now,
					"failed to send the auth response",
				)
			}
		}
		if transport.transport.phase == .Failed {
			common.ServerRegistrationRequiredPayload_deinit(&result.registration)
			return ClientServerTransport_connectFailed(transport, now, transport.lastError)
		}
		if result.hasRegistration {
			// Protocol 25 (D12): registering from here on. There is no handshake deadline any
			// more; the server allows REGISTER_SESSION_SECONDS and then ends the session.
			transport.connection.status = .Registering
			event := ClientTransportRuntimeEvent {
				kind                      = .RegistrationRequired,
				serverID                  = transport.serverID,
				registrationMode          = result.registration.mode,
				registrationRequestStatus = result.registration.status,
				message                   = result.registration.message,
			}
			// A key pinned on first use is kept now, as on Connected: the server proved it
			// in ServerHello, and an invite link for this address must find the pin.
			if transport.connection.newlyPinned {
				event.serverPublicKey = strings.clone(transport.pinnedServerPublicKey)
				event.serverFingerprint = strings.clone(transport.pinnedServerFingerprint)
				transport.connection.newlyPinned = false
			}
			return event, true
		}
		if transport.transport.phase == .Established {
			return ClientServerTransport_connected(transport), true
		}
		return {}, false

	case .DISCONNECT:
		reason := "the server closed the connection during sign-in"
		if transport.connection.status == .Connecting {
			reason = "could not reach the server"
		}
		return ClientServerTransport_connectFailed(transport, now, reason)

	case .NONE:
	}
	return {}, false
}

@(private = "file")
ClientServerTransport_connected :: proc(
	transport: ^ClientServerTransport,
) -> ClientTransportRuntimeEvent {
	transport.connection.status = .Established
	transport.connection.failedAttempts = 0
	// A new session: any voice binding from the previous one is dead from here on.
	transport.sessionGeneration += 1
	if len(transport.lastError) > 0 {
		delete(transport.lastError)
		transport.lastError = ""
	}
	// The account's name as the server has it: an admin may have locked it to another one
	// than the display name the client asked for (protocol 14).
	nickname := transport.authenticatedNickname
	if len(nickname) == 0 {
		nickname = transport.nickname
	}
	event := ClientTransportRuntimeEvent {
		kind              = .Connected,
		serverID          = transport.serverID,
		userID            = transport.authenticatedUserID,
		nickname          = strings.clone(nickname),
		isAdmin           = transport.authenticatedIsAdmin,
		nicknameLocked    = transport.authenticatedNicknameLocked,
		permissions       = transport.authenticatedPermissions,
		sessionGeneration = transport.sessionGeneration,
		registrationMode  = transport.authenticatedRegistrationMode,
		isRestricted      = transport.authenticatedIsRestricted,
		attachmentLimits  = transport.authenticatedAttachments,
	}
	if transport.connection.newlyPinned {
		event.serverPublicKey = strings.clone(transport.pinnedServerPublicKey)
		event.serverFingerprint = strings.clone(transport.pinnedServerFingerprint)
		transport.connection.newlyPinned = false
	}
	return event
}

// Ends a connect attempt. message is borrowed (it may be transport.lastError itself).
ClientServerTransport_connectFailed :: proc(
	transport: ^ClientServerTransport,
	now: time.Tick,
	message: string,
) -> (
	ClientTransportRuntimeEvent,
	bool,
) {
	event := ClientTransportRuntimeEvent {
		kind     = .ConnectFailed,
		serverID = transport.serverID,
		message  = strings.clone(message),
	}
	ClientServerTransport_setLastError(transport, event.message)
	ClientServerTransport_clearSessionRuntimeState(transport)
	transport.transport.phase = .Failed

	event.failureKind = classifyConnectFailure(event.message)
	if event.failureKind == .None {
		event.failureKind = .Other
	}
	event.retryable = connectFailureIsRetryable(event.failureKind)
	if event.failureKind == .ServerKeyChanged && transport.hasRejectedServerKey {
		event.serverPublicKey = common.identityPublicKeyToHex(transport.rejectedServerPublicKey)
		event.serverFingerprint = common.fingerprintToHex(
			common.fingerprintIdentityPublicKey(transport.rejectedServerPublicKey),
		)
	}

	if event.retryable {
		transport.connection.failedAttempts += 1
		ClientServerTransport_scheduleRetry(transport, now)
		event.retryAt = transport.connection.nextAttemptAt
	} else {
		transport.connection.status = .Failed
	}
	return event, true
}

// ServerSessionEnded (protocol 14): an admin kicked or banned this account, and the server is
// about to disconnect. The session ends here as a failure that is not retried, so the next
// automatic reconnect does not undo a kick; the user's Retry (requestConnect) connects again.
// reason is the admin's, borrowed; the event's message is the sentence classifyConnectFailure
// recognises, with the reason after it, and detail the bare reason.
ClientServerTransport_sessionEnded :: proc(
	transport: ^ClientServerTransport,
	now: time.Tick,
	kind: common.SessionEndedKind,
	reason: string,
) -> (
	ClientTransportRuntimeEvent,
	bool,
) {
	prefix := kind == .Banned ? SERVER_BANNED_MESSAGE : CLIENT_KICKED_MESSAGE
	message := len(reason) > 0 ? strings.concatenate({prefix, ": ", reason}) : strings.clone(prefix)
	defer delete(message)
	event, _ := ClientServerTransport_connectFailed(transport, now, message)
	event.kind = .SessionEnded
	event.detail = strings.clone(reason)
	return event, true
}

// Ends an established session and schedules a reconnect. reason is borrowed.
ClientServerTransport_lostConnection :: proc(
	transport: ^ClientServerTransport,
	now: time.Tick,
	reason: string,
) -> (
	ClientTransportRuntimeEvent,
	bool,
) {
	event := ClientTransportRuntimeEvent {
		kind      = .Disconnected,
		serverID  = transport.serverID,
		message   = strings.clone(reason),
		retryable = true,
	}
	ClientServerTransport_handleDisconnect(transport)
	transport.connection.failedAttempts = 1
	ClientServerTransport_scheduleRetry(transport, now)
	event.retryAt = transport.connection.nextAttemptAt
	return event, true
}

// Ends a connect attempt or a registering session with a failure that is never retried, of the
// given kind. message is borrowed.
ClientServerTransport_failStopped :: proc(
	transport: ^ClientServerTransport,
	now: time.Tick,
	message: string,
	kind: ClientConnectFailureKind,
) -> ClientTransportRuntimeEvent {
	event := ClientTransportRuntimeEvent {
		kind        = .ConnectFailed,
		serverID    = transport.serverID,
		message     = strings.clone(message),
		failureKind = kind,
	}
	ClientServerTransport_setLastError(transport, event.message)
	ClientServerTransport_clearSessionRuntimeState(transport)
	transport.transport.phase = .Failed
	transport.connection.status = .Failed
	return event
}

// Services a registering session (protocol 25, D12-D16): only ServerRegisterResponse and a
// sealed ServerProtocolError are expected. Voice datagrams are dropped like during the
// handshake. A session the server ends is a failure that is not retried: pending sessions wait
// for Check again, others show why the sign-up ended.
@(private = "file")
ClientServerTransport_serviceRegisteringSession :: proc(
	transport: ^ClientServerTransport,
	now: time.Tick,
) -> (
	ClientTransportRuntimeEvent,
	bool,
) {
	for {
		event: ENet.Event
		eventResult := ENet.host_service(transport.enetHost, &event, 0)
		if eventResult < 0 {
			return ClientServerTransport_registrationEnded(transport, now, "network error"), true
		}
		if eventResult == 0 {
			return {}, false
		}
		switch event.type {
		case .RECEIVE:
			if !ClientServerTransport_acceptReceiveChannel(transport, event.channelID) {
				ENet.packet_destroy(event.packet)
				continue
			}
			packetBytes := ClientServerTransport_copyENetPacket(event.packet)
			defer delete(packetBytes)
			return ClientServerTransport_handleRegisteringPacketBytes(transport, now, packetBytes)
		case .DISCONNECT:
			return ClientServerTransport_registrationEnded(
					transport,
					now,
					CLIENT_REGISTRATION_CLOSED_REASON,
				),
				true
		case .CONNECT, .NONE:
			return {}, false
		}
	}
}

// The server ended a registering session. reason is borrowed and used only when no refusal
// came before.
ClientServerTransport_registrationEnded :: proc(
	transport: ^ClientServerTransport,
	now: time.Tick,
	reason: string,
) -> ClientTransportRuntimeEvent {
	if transport.registrationPending {
		return ClientServerTransport_failStopped(
			transport,
			now,
			common.REGISTRATION_PENDING_MESSAGE,
			.RegistrationPending,
		)
	}
	why := len(transport.registrationRefusal) > 0 ? transport.registrationRefusal : reason
	message := strings.concatenate({CLIENT_REGISTRATION_ENDED_MESSAGE, ": ", why})
	defer delete(message)
	return ClientServerTransport_failStopped(transport, now, message, .RegistrationRequired)
}

// One control packet of a registering session. Created takes the account and becomes the
// normal Connected event (the transport is already active: no second activation).
ClientServerTransport_handleRegisteringPacketBytes :: proc(
	transport: ^ClientServerTransport,
	now: time.Tick,
	packetBytes: []u8,
) -> (
	ClientTransportRuntimeEvent,
	bool,
) {
	outerPacket: common.Packet
	if cbor.unmarshal(packetBytes, &outerPacket) != nil {
		delete(outerPacket.payload)
		return ClientServerTransport_registrationEnded(transport, now, "invalid outer packet"),
			true
	}
	defer delete(outerPacket.payload)
	if outerPacket.messageType == .ServerProtocolError {
		protocolError: common.ProtocolErrorResponse
		_ = cbor.unmarshal(outerPacket.payload, &protocolError)
		defer delete(protocolError.message)
		return ClientServerTransport_registrationProtocolError(transport, protocolError.message),
			true
	}
	if outerPacket.messageType != .EncryptedPacket ||
	   !common.TransportState_canEncrypt(&transport.transport) {
		return ClientServerTransport_registrationEnded(
				transport,
				now,
				"unexpected packet during sign-up",
			),
			true
	}
	innerPacket, openOK := common.openPacketForSession(&transport.transport, outerPacket)
	if !openOK {
		return ClientServerTransport_registrationEnded(
				transport,
				now,
				"failed to open encrypted packet",
			),
			true
	}
	defer delete(innerPacket.payload)

	#partial switch innerPacket.messageType {
	case .ServerRegisterResponse:
		payload: common.ServerRegisterResponsePayload
		decodeOK := cbor.unmarshal(innerPacket.payload, &payload) == nil
		defer common.ServerRegisterResponsePayload_deinit(&payload)
		transport.registerInFlight = false
		if !decodeOK || int(payload.status) > int(max(common.RegisterStatus)) {
			return ClientServerTransport_registrationProtocolError(
					transport,
					"invalid sign-up answer",
				),
				true
		}
		switch payload.status {
		case .Created:
			if payload.auth.userId <= 0 {
				return ClientServerTransport_registrationEnded(
						transport,
						now,
						"invalid sign-up answer",
					),
					true
			}
			ClientServerTransport_takeAuthSuccess(transport, &payload.auth)
			delete(transport.registrationRefusal)
			transport.registrationRefusal = ""
			transport.registrationPending = false
			event := ClientServerTransport_connected(transport)
			event.registered = true
			return event, true
		case .Pending, .Refused:
			if payload.status == .Pending {
				transport.registrationPending = true
			} else {
				delete(transport.registrationRefusal)
				transport.registrationRefusal = strings.clone(payload.message)
			}
			event := ClientTransportRuntimeEvent {
				kind           = .RegistrationResult,
				serverID       = transport.serverID,
				registerStatus = payload.status,
				message        = payload.message,
			}
			payload.message = ""
			return event, true
		case .Declined:
			message := payload.message
			if !strings.has_prefix(message, common.REGISTRATION_DECLINED_MESSAGE) {
				message = common.REGISTRATION_DECLINED_MESSAGE
			}
			event := ClientServerTransport_failStopped(
				transport,
				now,
				message,
				.RegistrationDeclined,
			)
			event.kind = .RegistrationResult
			event.registerStatus = .Declined
			return event, true
		}
	case .ServerProtocolError:
		protocolError: common.ProtocolErrorResponse
		_ = cbor.unmarshal(innerPacket.payload, &protocolError)
		defer delete(protocolError.message)
		transport.registerInFlight = false
		return ClientServerTransport_registrationProtocolError(transport, protocolError.message),
			true
	}
	// A registering session receives nothing else; ignore it rather than end the sign-up.
	return {}, false
}

// A ServerProtocolError while registering: the server ends the session right after it, so it
// is remembered as the reason the sign-up ended. message is borrowed.
@(private = "file")
ClientServerTransport_registrationProtocolError :: proc(
	transport: ^ClientServerTransport,
	message: string,
) -> ClientTransportRuntimeEvent {
	text := len(message) > 0 ? message : "server protocol error"
	delete(transport.registrationRefusal)
	transport.registrationRefusal = strings.clone(text)
	ClientServerTransport_runtimeProtocolError(transport, text)
	return ClientServerTransport_makeRuntimeEvent(transport, .ProtocolError, text)
}

// Sends one sealed ClientRegister (protocol 25). Only while registering and with no answer
// outstanding (the server takes one at a time). code and reason are borrowed; the sealed copy
// is the only one this sends.
ClientServerTransport_sendRegister :: proc(
	transport: ^ClientServerTransport,
	code, reason: string,
) -> bool {
	if transport.connection.status != .Registering ||
	   !common.TransportState_canEncrypt(&transport.transport) ||
	   !ClientServerTransport_hasLiveENetSession(transport) {
		ClientServerTransport_setLastError(transport, NOT_CONNECTED_MESSAGE)
		return false
	}
	if transport.registerInFlight {
		return false
	}
	sealedPacket, sealOK := common.sealPacketForSession(
		&transport.transport,
		.ClientRegister,
		common.ClientRegisterRequest{inviteCode = code, reason = reason},
	)
	if !sealOK {
		ClientServerTransport_setLastError(transport, "failed to seal the sign-up request")
		return false
	}
	defer delete(sealedPacket.payload)
	packetBytes, packetErr := cbor.marshal(sealedPacket)
	if packetErr != nil {
		ClientServerTransport_setLastError(transport, "failed to encode the sign-up request")
		return false
	}
	defer delete(packetBytes)
	if !ClientServerTransport_sendENetPacket(
		transport.enetHost,
		transport.enetPeer,
		STARTUP_AUTH_CHANNEL_CHAT,
		packetBytes,
	) {
		ClientServerTransport_setLastError(transport, "failed to send the sign-up request")
		return false
	}
	transport.registerInFlight = true
	return true
}

// Sets ClientAuthRequestPayload.registering for the next attempts. Under the worker lock.
ClientServerTransport_setRegistering :: proc(transport: ^ClientServerTransport, registering: bool) {
	transport.registering = registering
}

@(private = "file")
ClientServerTransport_scheduleRetry :: proc(transport: ^ClientServerTransport, now: time.Tick) {
	delay := reconnectDelay(transport.connection.failedAttempts, rand.float64())
	transport.connection.status = .Disconnected
	transport.connection.nextAttemptAt = time.tick_add(now, delay)
}

// ENet keeps process-wide state (WSAStartup on Windows), so it is initialised once, the first
// time any connection starts, and left for the OS to clean up at exit.
@(private = "file")
clientENetMutex: sync.Mutex
@(private = "file")
clientENetReady: bool

clientEnsureENetInitialized :: proc() -> bool {
	sync.mutex_lock(&clientENetMutex)
	defer sync.mutex_unlock(&clientENetMutex)
	if !clientENetReady {
		clientENetReady = ENet.initialize() == 0
	}
	return clientENetReady
}
