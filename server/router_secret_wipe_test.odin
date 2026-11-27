package server

import "../common"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// The router wipes what it decrypts and decodes before it frees it (#189): the payload
// openPacketForSession returns, and the invite code and reason of a ClientRegister. The tests
// run the router over an allocator that looks at every block given back to it.

// A pass-through allocator over the test's context allocator (so ownership and the leak check
// stay as they are) that looks at every block given back before passing it on: it counts the
// blocks that still hold one of the secrets, and the sized frees of zeroLength bytes that are
// all zero. A resize may move the block and free the old one, so it is looked at too.
@(private = "file")
SecretFreeRecorder :: struct {
	backing:           mem.Allocator,
	secrets:           []string,
	zeroLength:        int,
	frees:             int,
	givenBackSecret:   int,
	freedZeroOfLength: int,
}

@(private = "file")
secretFreeRecorderLook :: proc(recorder: ^SecretFreeRecorder, memory: rawptr, size: int) {
	if memory == nil || size <= 0 {
		return
	}
	block := ([^]u8)(memory)[:size]
	for secret in recorder.secrets {
		if strings.contains(string(block), secret) {
			recorder.givenBackSecret += 1
			break
		}
	}
	if size == recorder.zeroLength {
		for b in block {
			if b != 0 {
				return
			}
		}
		recorder.freedZeroOfLength += 1
	}
}

@(private = "file")
secretFreeRecorderProc :: proc(
	allocatorData: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	oldMemory: rawptr,
	oldSize: int,
	loc := #caller_location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	recorder := (^SecretFreeRecorder)(allocatorData)
	#partial switch mode {
	case .Free:
		recorder.frees += 1
		secretFreeRecorderLook(recorder, oldMemory, oldSize)
	case .Resize, .Resize_Non_Zeroed:
		secretFreeRecorderLook(recorder, oldMemory, oldSize)
	}
	backing := recorder.backing
	return backing.procedure(backing.data, mode, size, alignment, oldMemory, oldSize, loc)
}

@(private = "file")
secretFreeRecorderAllocator :: proc(recorder: ^SecretFreeRecorder) -> mem.Allocator {
	return mem.Allocator{procedure = secretFreeRecorderProc, data = recorder}
}

// A session on peerID with an active transport, registering or authenticated, and the
// client's side of it (the caller deinits it).
@(private = "file")
routerSecretWipeTestSession :: proc(
	h: ^RouterTestHarness,
	peerID: u32,
	registering: bool,
) -> common.TransportState {
	sessionID: common.SessionID
	sessionID[0] = u8(peerID)
	sharedSecret: common.SharedSecretBytes
	for i in 0 ..< len(sharedSecret) {
		sharedSecret[i] = u8(0x40 + i)
	}
	transcriptHash: common.FingerprintBytes
	clientKeys := common.deriveDirectionalTransportKeys(
		.Client,
		sessionID,
		sharedSecret,
		transcriptHash,
	)
	serverKeys := common.deriveDirectionalTransportKeys(
		.Server,
		sessionID,
		sharedSecret,
		transcriptHash,
	)
	defer common.DirectionalTransportKeys_wipe(&clientKeys)
	defer common.DirectionalTransportKeys_wipe(&serverKeys)
	client := common.TransportState_init(.Client)
	common.TransportState_activate(&client, sessionID, clientKeys, .Trusted)

	session := RouterPeerSession_init()
	common.TransportState_activate(&session.transport, sessionID, serverKeys, .Trusted)
	session.clientNickname = strings.clone("applicant")
	if registering {
		session.isRegistering = true
		session.registeringSince = time.tick_now()
	} else {
		session.isAuthenticated = true
		session.authenticatedUserID = 41
	}
	h.state.connectedPeers[peerID] = true
	MainRouterState_setPeerSession(&h.state, peerID, session)
	return client
}

// Seals payload as messageType for the session on peerID and hands it to the router as the
// network thread would.
@(private = "file")
routerSecretWipeTestReceive :: proc(
	h: ^RouterTestHarness,
	client: ^common.TransportState,
	peerID: u32,
	messageType: common.MessageType,
	payload: any,
	recorder: ^SecretFreeRecorder,
) {
	sealed, sealOK := common.sealPacketForSession(client, messageType, payload)
	assert(sealOK, fmt.tprintf("expected %v to seal", messageType))
	defer delete(sealed.payload)
	sealedBytes := routerEncodePacketBytes(sealed)
	defer delete(sealedBytes)
	recorder.backing = context.allocator
	context.allocator = secretFreeRecorderAllocator(recorder)
	MainRouterState_handleNetworkDataReceived(
		&h.pm,
		&h.state,
		NetworkDataReceived{peerId = peerID, channel = .Chat, data = sealedBytes},
	)
	// The deferred frees above pass through the recorder to the test's allocator.
}

// #189 acceptance: when MainRouterState_handleClientRegister returns, the invite code's decoded
// bytes are zero (and the reason's), and nothing it gave back held either; the database still
// gets the code's hash.
@(test)
testClientRegisterWipesTheDecodedInviteCode :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	client := routerSecretWipeTestSession(&h, 1, registering = true)
	defer common.TransportState_deinit(&client)
	code, ok := common.generateInviteCode()
	assert(ok, "expected a random code")
	text := common.formatInviteCode(code)
	defer common.wipeAndDeleteString(&text)
	reason := "a reason only the approvers should read"
	packet, buildOK := common.buildPacket(
		.ClientRegister,
		common.ClientRegisterRequest{inviteCode = text, reason = reason},
	)
	assert(buildOK, "expected ClientRegister to encode")
	defer delete(packet.payload)

	secrets := []string{text, reason}
	recorder := SecretFreeRecorder {
		backing    = context.allocator,
		secrets    = secrets,
		zeroLength = len(text),
	}
	{
		context.allocator = secretFreeRecorderAllocator(&recorder)
		MainRouterState_handleClientRegister(&h.pm, &h.state, 1, packet.payload)
	}
	assert(
		recorder.freedZeroOfLength >= 1,
		fmt.tprintf(
			"expected the decoded %d-byte invite code freed as zeros, got %d such frees of %d",
			len(text),
			recorder.freedZeroOfLength,
			recorder.frees,
		),
	)
	assert(
		recorder.givenBackSecret == 0,
		fmt.tprintf(
			"expected no block given back holding the code or reason, got %d",
			recorder.givenBackSecret,
		),
	)

	query := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(query.request)
	register, registerOK := query.request.(common.DatabaseRegisterRequest)
	assert(
		registerOK &&
		register.hasCode &&
		register.codeHash == common.inviteCodeHash(code) &&
		register.reason == reason,
		fmt.tprintf("expected the sign-up with the code's hash, got %v", query.request),
	)
}

// #189: the payload openPacketForSession returns is wiped once its handler is done, through the
// registering session's dispatch (a whole ClientRegister) and the authenticated one's (a Ping,
// which no handler decodes, so only the opened payload holds the marker).
@(test)
testRouterWipesTheOpenedPayload :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	registering := routerSecretWipeTestSession(&h, 1, registering = true)
	defer common.TransportState_deinit(&registering)
	code, ok := common.generateInviteCode()
	assert(ok, "expected a random code")
	text := common.formatInviteCode(code)
	defer common.wipeAndDeleteString(&text)
	reason := "a sign-up reason sealed for the server"
	signUp := SecretFreeRecorder {
		secrets = []string{text, reason},
	}
	routerSecretWipeTestReceive(
		&h,
		&registering,
		1,
		.ClientRegister,
		common.ClientRegisterRequest{inviteCode = text, reason = reason},
		&signUp,
	)
	assert(signUp.frees > 0, "expected the dispatch to free through the recorder")
	assert(
		signUp.givenBackSecret == 0,
		fmt.tprintf(
			"expected no block given back holding the code or reason, got %d",
			signUp.givenBackSecret,
		),
	)
	query := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(query.request)
	_, registerOK := query.request.(common.DatabaseRegisterRequest)
	assert(registerOK, fmt.tprintf("expected the sign-up queued, got %v", query.request))

	authenticated := routerSecretWipeTestSession(&h, 2, registering = false)
	defer common.TransportState_deinit(&authenticated)
	marker := "opened payload marker 7f3a"
	ping := SecretFreeRecorder {
		secrets = []string{marker},
	}
	routerSecretWipeTestReceive(
		&h,
		&authenticated,
		2,
		.Ping,
		common.ClientRegisterRequest{reason = marker},
		&ping,
	)
	assert(ping.frees > 0, "expected the dispatch to free through the recorder")
	assert(
		ping.givenBackSecret == 0,
		fmt.tprintf(
			"expected the opened Ping payload wiped, %d blocks held it",
			ping.givenBackSecret,
		),
	)
	routerTestExpectNoNetworkMessage(&h, "a Ping")
	routerTestExpectNoDatabaseQuery(&h, "a Ping")
}
