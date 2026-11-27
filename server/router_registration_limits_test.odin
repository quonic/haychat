package server

import "../common"
import "core:encoding/cbor"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import ENet "vendor:ENet"

// Per-address sign-up limits (#105, router_registration_limits.odin). The router test harness
// zeroes ServerConfig, which turns every per-address limit off; each test sets the ones it
// checks. Two addresses: one goes over the limit, the other is not affected.

@(private = "file")
LIMITS_TEST_ADDRESS_A :: [4]u8{192, 0, 2, 10}
@(private = "file")
LIMITS_TEST_ADDRESS_B :: [4]u8{198, 51, 100, 20}

// Makes peerID a connected session from octets, as NetworkPeerConnected does.
@(private = "file")
routerLimitsTestConnect :: proc(h: ^RouterTestHarness, peerID: u32, octets: [4]u8) {
	address := registrationAddressFromENet(ENet.Address{host = transmute(u32)octets})
	h.state.connectedPeers[peerID] = true
	if session, ok := &h.state.peerSessions[peerID]; ok {
		session.peerAddress = address
		return
	}
	session := RouterPeerSession_init()
	session.peerAddress = address
	MainRouterState_setPeerSession(&h.state, peerID, session)
}

// Reads the plaintext ServerAuthFailure that refused peerID and its disconnect.
@(private = "file")
routerLimitsTestExpectAuthFailure :: proc(h: ^RouterTestHarness, peerID: u32, message: string) {
	send := routerPollNetworkSend(h)
	defer delete(send.data)
	packet := routerDecodePacketBytes(send.data)
	defer delete(packet.payload)
	failure: common.ServerAuthFailurePayload
	assert(cbor.unmarshal(packet.payload, &failure) == nil, "expected an auth failure payload")
	defer delete(failure.message)
	assert(
		packet.messageType == .ServerAuthFailure && failure.message == message,
		fmt.tprintf("expected ServerAuthFailure %q, got %v %q", message, packet.messageType,
			failure.message),
	)
	assert(routerPollDisconnect(h).peerId == peerID, "expected the refused session disconnected")
}

// Sends a code that does not parse and expects the answer, which never reaches the database.
@(private = "file")
routerLimitsTestBadCode :: proc(
	h: ^RouterTestHarness,
	client: ^RouterRegistrationTestClient,
	expected: string,
) {
	routerRegistrationTestRegister(h, client, "not-a-code")
	response := routerRegistrationTestResponse(h, client)
	defer common.ServerRegisterResponsePayload_deinit(&response)
	assert(
		response.status == .Refused && response.message == expected,
		fmt.tprintf("expected Refused %q, got %v", expected, response),
	)
	routerTestExpectNoDatabaseQuery(h, "a refused ClientRegister")
}

// IPv4 and IPv4-mapped IPv6 are one address; other IPv6 addresses group by /64.
@(test)
testRegistrationAddressNormalisesIPv4MappedAndGroupsIPv6 :: proc(t: ^testing.T) {
	_ = t
	ipv4 := registrationAddressFromENet(ENet.Address{host = transmute(u32)LIMITS_TEST_ADDRESS_A})
	mapped := registrationAddressFromIPv6(
		{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 192, 0, 2, 10},
	)
	assert(ipv4 == mapped, fmt.tprintf("expected ::ffff:192.0.2.10 as 192.0.2.10, got %v", mapped))
	buffer: [64]u8
	text := registrationAddressText(ipv4, buffer[:])
	assert(text == "192.0.2.10", fmt.tprintf("expected the dotted address, got %q", text))
	other := registrationAddressFromIPv4(LIMITS_TEST_ADDRESS_B)
	assert(ipv4 != other, "expected two IPv4 addresses kept apart")

	// 2001:db8:1:2::1 and 2001:db8:1:2:ffff::9 share a /64; 2001:db8:1:3::1 does not.
	first := registrationAddressFromIPv6(
		{0x20, 0x01, 0x0d, 0xb8, 0, 1, 0, 2, 0, 0, 0, 0, 0, 0, 0, 1},
	)
	sameNetwork := registrationAddressFromIPv6(
		{0x20, 0x01, 0x0d, 0xb8, 0, 1, 0, 2, 0xff, 0xff, 0, 0, 0, 0, 0, 9},
	)
	nextNetwork := registrationAddressFromIPv6(
		{0x20, 0x01, 0x0d, 0xb8, 0, 1, 0, 3, 0, 0, 0, 0, 0, 0, 0, 1},
	)
	assert(first == sameNetwork, "expected one /64 to be one address")
	assert(first != nextNetwork, "expected another /64 to be another address")
	text = registrationAddressText(first, buffer[:])
	assert(text == "2001:db8:1:2::/64", fmt.tprintf("expected the /64, got %q", text))
	// An address that only looks mapped in its last bytes is an ordinary IPv6 one.
	notMapped := registrationAddressFromIPv6(
		{0x20, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 192, 0, 2, 10},
	)
	assert(notMapped != ipv4, "expected a non-mapped prefix not taken for IPv4")
}

// One address may hold only its share of the registering sessions; another is not affected.
@(test)
testRegistrationAddressShareOfRegisteringSessions :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	h.pm.config.registrationIPSessions = 2

	routerLimitsTestConnect(&h, 1, LIMITS_TEST_ADDRESS_A)
	first := routerRegistrationTestBegin(&h, 1)
	defer common.TransportState_deinit(&first.transport)
	routerLimitsTestConnect(&h, 2, LIMITS_TEST_ADDRESS_A)
	second := routerRegistrationTestBegin(&h, 2)
	defer common.TransportState_deinit(&second.transport)
	routerLimitsTestConnect(&h, 3, LIMITS_TEST_ADDRESS_A)
	third := routerRegistrationTestBegin(&h, 3, expectRequired = false)
	routerLimitsTestExpectAuthFailure(&h, third.peerID, common.REGISTRATION_ADDRESS_BUSY_MESSAGE)
	session, _ := MainRouterState_getPeerSession(&h.state, 3)
	assert(!session.isRegistering, "expected the third session from one address not registering")

	routerLimitsTestConnect(&h, 4, LIMITS_TEST_ADDRESS_B)
	other := routerRegistrationTestBegin(&h, 4)
	defer common.TransportState_deinit(&other.transport)

	// A session that ends frees its place in the share.
	MainRouterState_handlePeerDisconnected(&h.pm, &h.state, 1)
	routerLimitsTestConnect(&h, 5, LIMITS_TEST_ADDRESS_A)
	again := routerRegistrationTestBegin(&h, 5)
	defer common.TransportState_deinit(&again.transport)
}

// Starting to sign up and every ClientRegister take a token from the address's bucket; an
// empty bucket refuses both, refusals take nothing, another address keeps its own bucket, and
// the bucket refills with time.
@(test)
testRegistrationAddressAttemptBucket :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	h.pm.config.registrationIPAttemptsBurst = 3
	h.pm.config.registrationIPAttemptsPerMinute = 1

	routerLimitsTestConnect(&h, 1, LIMITS_TEST_ADDRESS_A)
	client := routerRegistrationTestBegin(&h, 1)
	defer common.TransportState_deinit(&client.transport)
	routerLimitsTestBadCode(&h, &client, common.INVITE_CODE_INVALID_MESSAGE)
	routerLimitsTestBadCode(&h, &client, common.INVITE_CODE_INVALID_MESSAGE)
	// The bucket is empty: the next ClientRegister is refused before the code is read.
	_, text := routerRegistrationTestCode()
	defer delete(text)
	routerRegistrationTestRegister(&h, &client, text, "hello")
	limited := routerRegistrationTestResponse(&h, &client)
	defer common.ServerRegisterResponsePayload_deinit(&limited)
	assert(
		limited.status == .Refused &&
		limited.message == common.REGISTRATION_ADDRESS_RATE_MESSAGE,
		fmt.tprintf("expected the attempt refused for the address, got %v", limited),
	)
	routerTestExpectNoDatabaseQuery(&h, "a ClientRegister past the address's attempts")
	still, _ := MainRouterState_getPeerSession(&h.state, 1)
	assert(still.isRegistering, "expected the limited session to stay registering")

	// A new session from the same address cannot start signing up.
	routerLimitsTestConnect(&h, 2, LIMITS_TEST_ADDRESS_A)
	refused := routerRegistrationTestBegin(&h, 2, expectRequired = false)
	routerLimitsTestExpectAuthFailure(&h, refused.peerID, common.REGISTRATION_ADDRESS_RATE_MESSAGE)

	// Another address starts and registers as usual.
	routerLimitsTestConnect(&h, 3, LIMITS_TEST_ADDRESS_B)
	other := routerRegistrationTestBegin(&h, 3)
	defer common.TransportState_deinit(&other.transport)
	routerLimitsTestBadCode(&h, &other, common.INVITE_CODE_INVALID_MESSAGE)

	// Refusals took nothing, and a minute brings one token back (1 per minute).
	limits := registrationLimitsFromConfig(h.pm.config)
	addressA := registrationAddressFromIPv4(LIMITS_TEST_ADDRESS_A)
	entry, tracked := h.state.registrationAddresses[addressA]
	assert(tracked && entry.attemptTokens < 1, "expected address A's bucket empty")
	later := time.tick_add(time.tick_now(), 61 * time.Second)
	assert(
		MainRouterState_registrationTakeAttempt(&h.state, limits, addressA, later),
		"expected a token back after a minute",
	)
	assert(
		!MainRouterState_registrationTakeAttempt(&h.state, limits, addressA, later),
		"expected only one token back after a minute",
	)
}

// In Invite + approval mode one address may make only so many sign-up requests in an hour; an
// answer that made no request gives its token back, another address is not affected, and the
// limit does not apply outside that mode.
@(test)
testRegistrationAddressRequestBucket :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	h.pm.config.registrationIPRequestsPerHour = 1
	addressB := registrationAddressFromIPv4(LIMITS_TEST_ADDRESS_B)

	routerLimitsTestConnect(&h, 1, LIMITS_TEST_ADDRESS_A)
	first := routerRegistrationTestBegin(&h, 1, mode = .InviteApproval)
	defer common.TransportState_deinit(&first.transport)
	_, text := routerRegistrationTestCode()
	defer delete(text)
	routerRegistrationTestRegister(&h, &first, text, "a friend sent me")
	query := routerPollDatabaseQuery(&h)
	IPC__database_query_request_deinit(query.request)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRegisterResult {
				outcome = .Pending,
				request = common.RegistrationRequestSummary {
					id = 9,
					nickname = strings.clone("applicant"),
					reason = strings.clone("a friend sent me"),
					status = .Pending,
				},
				pendingCount = 1,
			},
		},
	)
	pending := routerRegistrationTestResponse(&h, &first)
	defer common.ServerRegisterResponsePayload_deinit(&pending)
	assert(pending.status == .Pending, "expected the first request to wait")

	// A second request from the same address within the hour is refused before the database.
	routerLimitsTestConnect(&h, 2, LIMITS_TEST_ADDRESS_A)
	second := routerRegistrationTestBegin(&h, 2, mode = .InviteApproval)
	defer common.TransportState_deinit(&second.transport)
	routerRegistrationTestRegister(&h, &second, text, "me too")
	limited := routerRegistrationTestResponse(&h, &second)
	defer common.ServerRegisterResponsePayload_deinit(&limited)
	assert(
		limited.status == .Refused &&
		limited.message == common.REGISTRATION_ADDRESS_REQUESTS_MESSAGE,
		fmt.tprintf("expected the request refused for the address, got %v", limited),
	)
	routerTestExpectNoDatabaseQuery(&h, "a request past the address's limit")

	// Outside Invite + approval mode the same address still reaches the database.
	routerLimitsTestConnect(&h, 3, LIMITS_TEST_ADDRESS_A)
	inviteOnly := routerRegistrationTestBegin(&h, 3, mode = .InviteOnly)
	defer common.TransportState_deinit(&inviteOnly.transport)
	routerRegistrationTestRegister(&h, &inviteOnly, text)
	inviteQuery := routerPollDatabaseQuery(&h)
	IPC__database_query_request_deinit(inviteQuery.request)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		inviteQuery.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRegisterResult{outcome = .InvalidCode},
		},
	)
	invalid := routerRegistrationTestResponse(&h, &inviteOnly)
	defer common.ServerRegisterResponsePayload_deinit(&invalid)
	assert(invalid.message == common.INVITE_CODE_INVALID_MESSAGE, "expected the usual refusal")

	// Another address makes its request; an answer that made none gives the token back.
	routerLimitsTestConnect(&h, 4, LIMITS_TEST_ADDRESS_B)
	other := routerRegistrationTestBegin(&h, 4, mode = .InviteApproval)
	defer common.TransportState_deinit(&other.transport)
	routerRegistrationTestRegister(&h, &other, text, "hello")
	otherQuery := routerPollDatabaseQuery(&h)
	IPC__database_query_request_deinit(otherQuery.request)
	reservedEntry := h.state.registrationAddresses[addressB]
	assert(reservedEntry.requestTokens < 1, "expected address B's token reserved in flight")
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		otherQuery.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRegisterResult{outcome = .InvalidCode},
		},
	)
	otherInvalid := routerRegistrationTestResponse(&h, &other)
	defer common.ServerRegisterResponsePayload_deinit(&otherInvalid)
	assert(
		otherInvalid.message == common.INVITE_CODE_INVALID_MESSAGE,
		"expected address B's answer from the database",
	)
	refunded := h.state.registrationAddresses[addressB]
	assert(refunded.requestTokens >= 1, "expected address B's token given back")
}

// The table forgets addresses whose buckets are full again and never grows past its cap.
@(test)
testRegistrationAddressTableIsBounded :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	h.pm.config.registrationIPAttemptsBurst = 2
	h.pm.config.registrationIPAttemptsPerMinute = 60
	limits := registrationLimitsFromConfig(h.pm.config)

	now := time.tick_now()
	for index in 0 ..< REGISTRATION_ADDRESS_TABLE_MAX + 10 {
		octets := [4]u8{10, u8(index >> 16), u8(index >> 8), u8(index)}
		address := registrationAddressFromIPv4(octets)
		// Each address a nanosecond after the last, so the oldest is the first.
		at := time.tick_add(now, time.Duration(index))
		assert(
			MainRouterState_registrationTakeAttempt(&h.state, limits, address, at),
			"expected a new address to start with tokens",
		)
		assert(
			len(h.state.registrationAddresses) <= REGISTRATION_ADDRESS_TABLE_MAX,
			fmt.tprintf("expected at most %d addresses, got %d", REGISTRATION_ADDRESS_TABLE_MAX,
				len(h.state.registrationAddresses)),
		)
	}
	// The newest address is tracked; the oldest was forgotten for it.
	newest := registrationAddressFromIPv4({10, 0, 0x10, 0x09})
	oldest := registrationAddressFromIPv4({10, 0, 0, 0})
	_, newestTracked := h.state.registrationAddresses[newest]
	_, oldestTracked := h.state.registrationAddresses[oldest]
	assert(newestTracked && !oldestTracked, "expected the oldest address evicted, not the newest")

	// Not yet refilled: nothing is pruned. Two seconds later every bucket is full and all go.
	MainRouterState_pruneRegistrationAddresses(
		&h.state,
		limits,
		time.tick_add(now, REGISTRATION_ADDRESS_TABLE_MAX + 10),
	)
	assert(
		len(h.state.registrationAddresses) == REGISTRATION_ADDRESS_TABLE_MAX,
		"expected used addresses kept",
	)
	MainRouterState_pruneRegistrationAddresses(
		&h.state,
		limits,
		time.tick_add(now, 2 * time.Second),
	)
	assert(len(h.state.registrationAddresses) == 0, "expected idle addresses forgotten")
}

// A ClientRegister whose database request fails (MainRouterState_failPendingDatabaseRequests)
// made no sign-up request, so the address gets its reserved request token back.
@(test)
testRegistrationAddressRequestTokenReturnsOnDatabaseFailure :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	h.pm.config.registrationIPRequestsPerHour = 1
	address := registrationAddressFromIPv4(LIMITS_TEST_ADDRESS_A)

	routerLimitsTestConnect(&h, 1, LIMITS_TEST_ADDRESS_A)
	client := routerRegistrationTestBegin(&h, 1, mode = .InviteApproval)
	defer common.TransportState_deinit(&client.transport)
	_, text := routerRegistrationTestCode()
	defer delete(text)
	routerRegistrationTestRegister(&h, &client, text, "a friend sent me")
	query := routerPollDatabaseQuery(&h)
	IPC__database_query_request_deinit(query.request)
	reserved := h.state.registrationAddresses[address]
	assert(reserved.requestTokens < 1, "expected the token reserved while in flight")

	MainRouterState_failPendingDatabaseRequests(&h.pm, &h.state, "Database unavailable")
	refused := routerRegistrationTestResponse(&h, &client)
	defer common.ServerRegisterResponsePayload_deinit(&refused)
	assert(refused.status == .Refused, fmt.tprintf("expected Refused, got %v", refused))
	refunded := h.state.registrationAddresses[address]
	assert(
		refunded.requestTokens >= 1,
		fmt.tprintf("expected the token back, got %v", refunded.requestTokens),
	)
}
