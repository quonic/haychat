package server

import "../common"
import "core:fmt"
import "core:sync"
import "core:testing"

// Router tests for the account encryption keys (router_encryption_keys.odin, protocol 16), with
// stubbed database results; the statements run in database_encryption_keys_test.odin.

ROUTER_KEYS_TEST_ALICE :: 51
ROUTER_KEYS_TEST_BOB :: 52

// alice (peer 1) and bob (peer 2), with alice's identity private key, presence consumed.
@(private = "file")
routerKeysTestConnect :: proc(
	h: ^RouterTestHarness,
) -> (
	clients: [2]RouterVoiceTestClient,
	alicePrivateKey: common.IdentityPrivateKeyBytes,
) {
	clients = [2]RouterVoiceTestClient {
		{peerID = 1, userID = ROUTER_KEYS_TEST_ALICE},
		{peerID = 2, userID = ROUTER_KEYS_TEST_BOB},
	}
	for &client, index in clients {
		h.state.connectedPeers[client.peerID] = true
		client.transport = routerCompleteHandshake(
			h,
			client.peerID,
			client.userID,
			fmt.tprintf("keys-user-%d", client.userID),
			identityPrivateKeyOut = index == 0 ? &alicePrivateKey : nil,
		)
		drain := routerVoiceTestDrain(h, clients[:])
		RouterVoiceTestDrain_deinit(&drain)
	}
	return
}

// A heap copy of ids; the caller frees it.
@(private = "file")
routerKeysTestIDs :: proc(ids: ..int) -> [dynamic]int {
	list := make([dynamic]int, 0, len(ids))
	append(&list, ..ids)
	return list
}

@(private = "file")
routerKeysTestBundle :: proc(
	identityPrivateKey: common.IdentityPrivateKeyBytes,
	createdAt: u64 = 1_700_000_000,
) -> common.EncryptionKeyBundle {
	keyPair, keyOK := common.generateEncryptionKeyPair()
	assert(keyOK, "expected an encryption key pair")
	defer common.EncryptionKeyPair_wipe(&keyPair)
	bundle, signOK := common.signEncryptionKeyBundle(
		identityPrivateKey,
		keyPair.publicKey,
		createdAt,
	)
	assert(signOK, "expected the bundle to be signed")
	return bundle
}

@(private = "file")
routerKeysTestPublishPayload :: proc(
	bundle: common.EncryptionKeyBundle,
) -> common.ClientPublishEncryptionKeyPayload {
	return common.ClientPublishEncryptionKeyPayload {
		encryptionPublicKey = bundle.encryptionPublicKey,
		createdAt = bundle.createdAt,
		signature = bundle.signature,
	}
}

@(private = "file")
routerKeysTestExpectProtocolError :: proc(
	drain: ^RouterVoiceTestDrain,
	peerID: u32,
	message: string,
) {
	protocolError := routerAdminTestDecode(
		drain,
		peerID,
		.ServerProtocolError,
		common.ProtocolErrorResponse,
	)
	defer delete(protocolError.message)
	assert(
		protocolError.message == message,
		fmt.tprintf("expected %q, got %q", message, protocolError.message),
	)
}

@(test)
testMainRouterPublishEncryptionKeyStoresAVerifiedBundleAndAnnouncesIt :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients, alicePrivateKey := routerKeysTestConnect(&h)
	defer routerVoiceTestDisconnectAll(clients[:])

	bundle := routerKeysTestBundle(alicePrivateKey)
	routerTestSendSealed(
		&h,
		&clients[0].transport,
		1,
		.ClientPublishEncryptionKey,
		routerKeysTestPublishPayload(bundle),
	)
	query := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(query.request)
	request, ok := query.request.(common.DatabasePublishEncryptionKeyRequest)
	assert(ok, fmt.tprintf("expected one publish statement, got %v", query))
	assert(
		request.userId == ROUTER_KEYS_TEST_ALICE &&
		request.encryptionPublicKey == bundle.encryptionPublicKey &&
		request.createdAt == bundle.createdAt &&
		request.signature == bundle.signature,
		fmt.tprintf("expected alice's bundle under her own account, got %v", request),
	)

	stored := common.UserKeyBundle {
		userId              = ROUTER_KEYS_TEST_ALICE,
		identityPublicKey   = bundle.identityPublicKey,
		encryptionPublicKey = bundle.encryptionPublicKey,
		createdAt           = bundle.createdAt,
		signature           = bundle.signature,
	}
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabasePublishEncryptionKeyResult {
				stored = true,
				replaced = true,
				bundle = stored,
			},
		},
	)
	drain := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	for peerID in ([]u32{1, 2}) {
		changed := routerAdminTestDecode(
			&drain,
			peerID,
			.ServerUserKeyChanged,
			common.ServerUserKeyChangedPayload,
		)
		assert(
			changed.bundle == stored,
			fmt.tprintf("expected peer %d to get alice's new bundle, got %v", peerID, changed),
		)
	}
	assert(len(drain.packets) == 2, fmt.tprintf("expected 2 packets, got %d", len(drain.packets)))

	// The same bundle again: the statement stores nothing and nobody hears about it.
	routerTestSendSealed(
		&h,
		&clients[0].transport,
		1,
		.ClientPublishEncryptionKey,
		routerKeysTestPublishPayload(bundle),
	)
	repeat := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(repeat.request)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		repeat.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabasePublishEncryptionKeyResult{},
		},
	)
	quiet := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&quiet)
	assert(len(quiet.packets) == 0, "expected an identical bundle to be announced to nobody")
}

@(test)
testMainRouterPublishEncryptionKeyRefusesBundlesTheSessionDidNotSign :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients, alicePrivateKey := routerKeysTestConnect(&h)
	defer routerVoiceTestDisconnectAll(clients[:])

	otherPrivateKey, _, otherOK := common.generateIdentityKeyPair()
	assert(otherOK, "expected another identity key")
	valid := routerKeysTestBundle(alicePrivateKey)
	tampered := valid
	tampered.createdAt += 1
	smallOrder := valid
	smallOrder.encryptionPublicKey = {}
	tooLate := routerKeysTestBundle(alicePrivateKey, u64(max(i64)) + 1)
	cases := [?]common.EncryptionKeyBundle {
		// Signed by someone else: valid on its own, but not by this session's identity key.
		routerKeysTestBundle(otherPrivateKey),
		tampered,
		smallOrder,
		tooLate,
	}
	for bundle, index in cases {
		routerTestSendSealed(
			&h,
			&clients[0].transport,
			1,
			.ClientPublishEncryptionKey,
			routerKeysTestPublishPayload(bundle),
		)
		routerTestExpectNoDatabaseQuery(
			&h,
			fmt.tprintf("expected bad bundle %d to reach no statement", index),
		)
		drain := routerVoiceTestDrain(&h, clients[:])
		routerKeysTestExpectProtocolError(&drain, 1, common.ENCRYPTION_KEY_INVALID_MESSAGE)
		assert(
			routerAdminTestCount(&drain, 2, .ServerUserKeyChanged) == 0,
			"expected no announcement of a refused bundle",
		)
		RouterVoiceTestDrain_deinit(&drain)
	}
}

@(test)
testMainRouterFetchUserKeysAnswersOnlyTheRequester :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients, alicePrivateKey := routerKeysTestConnect(&h)
	defer routerVoiceTestDisconnectAll(clients[:])

	userIDs := routerKeysTestIDs(ROUTER_KEYS_TEST_ALICE, 99)
	defer delete(userIDs)
	routerTestSendSealed(
		&h,
		&clients[1].transport,
		2,
		.ClientFetchUserKeys,
		common.ClientFetchUserKeysPayload{userIds = userIDs},
	)
	query := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(query.request)
	request, ok := query.request.(common.DatabaseFetchUserKeysRequest)
	assert(
		ok &&
		len(request.userIds) == 2 &&
		request.userIds[0] == ROUTER_KEYS_TEST_ALICE &&
		request.userIds[1] == 99,
		fmt.tprintf("expected a fetch of alice and 99, got %v", query),
	)

	bundle := routerKeysTestBundle(alicePrivateKey)
	keys := make([dynamic]common.UserKeyBundle, 0, 1)
	append(
		&keys,
		common.UserKeyBundle {
			userId = ROUTER_KEYS_TEST_ALICE,
			identityPublicKey = bundle.identityPublicKey,
			encryptionPublicKey = bundle.encryptionPublicKey,
			createdAt = bundle.createdAt,
			signature = bundle.signature,
		},
	)
	missing := make([dynamic]int, 0, 1)
	append(&missing, 99)
	response := common.DatabaseQueryResponse {
		success = true,
		result = common.DatabaseFetchUserKeysResult{keys = keys, missingUserIds = missing},
	}
	expected := keys[0]
	// handleDatabaseResult frees the response.
	MainRouterState_handleDatabaseResult(&h.pm, &h.state, query.request_id, response)

	drain := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	answer := routerAdminTestDecode(&drain, 2, .ServerUserKeys, common.ServerUserKeysPayload)
	defer common.ServerUserKeysPayload_deinit(&answer)
	assert(
		len(answer.keys) == 1 &&
		answer.keys[0] == expected &&
		len(answer.missingUserIds) == 1 &&
		answer.missingUserIds[0] == 99,
		fmt.tprintf("expected alice's bundle and 99 missing, got %v", answer),
	)
	assert(len(drain.packets) == 1, "expected the answer only for the session that asked")
}

@(test)
testMainRouterFetchUserKeysRefusesInvalidLists :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients, _ := routerKeysTestConnect(&h)
	defer routerVoiceTestDisconnectAll(clients[:])

	tooMany := make([dynamic]int, 0, common.USER_KEYS_FETCH_MAX + 1)
	defer delete(tooMany)
	for index in 0 ..= common.USER_KEYS_FETCH_MAX {
		append(&tooMany, index + 1)
	}
	empty: [dynamic]int
	duplicate := routerKeysTestIDs(3, 4, 3)
	defer delete(duplicate)
	zero := routerKeysTestIDs(3, 0)
	defer delete(zero)
	negative := routerKeysTestIDs(-1)
	defer delete(negative)
	cases := [?][dynamic]int{empty, tooMany, duplicate, zero, negative}
	for userIDs, index in cases {
		routerTestSendSealed(
			&h,
			&clients[0].transport,
			1,
			.ClientFetchUserKeys,
			common.ClientFetchUserKeysPayload{userIds = userIDs},
		)
		routerTestExpectNoDatabaseQuery(
			&h,
			fmt.tprintf("expected invalid list %d to reach no statement", index),
		)
		drain := routerVoiceTestDrain(&h, clients[:])
		routerKeysTestExpectProtocolError(&drain, 1, common.USER_KEYS_INVALID_REQUEST_MESSAGE)
		RouterVoiceTestDrain_deinit(&drain)
	}

	// Exactly USER_KEYS_FETCH_MAX IDs is allowed.
	resize(&tooMany, common.USER_KEYS_FETCH_MAX)
	routerTestSendSealed(
		&h,
		&clients[0].transport,
		1,
		.ClientFetchUserKeys,
		common.ClientFetchUserKeysPayload{userIds = tooMany},
	)
	query := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(query.request)
	request, ok := query.request.(common.DatabaseFetchUserKeysRequest)
	assert(
		ok && len(request.userIds) == common.USER_KEYS_FETCH_MAX,
		fmt.tprintf("expected a fetch of %d IDs, got %v", common.USER_KEYS_FETCH_MAX, query),
	)
}
