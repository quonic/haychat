package client

import "../common"
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
CLIENT_INVALID_NICKNAME_MESSAGE :: "client display name must be between 3 and 32 characters"
CLIENT_INVALID_IDENTITY_MESSAGE :: "client identity keys are missing or invalid"

ClientConnectionStatus :: enum u8 {
	Idle, // Never asked to connect
	Connecting, // Waiting for the ENet connection
	Handshaking, // ClientHello sent, waiting for the server to authenticate us
	Established,
	Failed, // Stopped: retrying cannot help until the user changes something
	Disconnected, // Waiting for the next attempt at nextAttemptAt
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
	case .None, .Unreachable, .Other:
		return true
	case .NameUnavailable, .ServerKeyChanged, .ProtocolMismatch, .InvalidName, .InvalidIdentity:
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

	// Name resolution blocks this worker pass; it is quick for IP addresses and local names.
	hostCString := strings.clone_to_cstring(transport.serverHost, context.temp_allocator)
	address := ENet.Address {
		port = u16(transport.serverPort),
	}
	if len(transport.serverHost) == 0 || ENet.address_set_host(&address, hostCString) != 0 {
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
			return ClientServerTransport_connectFailed(transport, now, transport.lastError)
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
	if len(transport.lastError) > 0 {
		delete(transport.lastError)
		transport.lastError = ""
	}
	event := ClientTransportRuntimeEvent {
		kind     = .Connected,
		serverID = transport.serverID,
		userID   = transport.authenticatedUserID,
		nickname = strings.clone(transport.nickname),
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
