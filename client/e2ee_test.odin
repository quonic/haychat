package client

import "../common"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

// Client tests for the account encryption keys (e2ee-design.md 12.3): the key store file, the
// pins (first use, a changed identity key blocking, a new encryption key accepted with a
// notice, rollback and bad signatures refused), publishing once per session, batched fetches,
// verification, and the view models.

E2EE_TEST_SERVER :: 971
E2EE_TEST_SELF :: 1
E2EE_TEST_BOB :: 2
E2EE_TEST_CAROL :: 3

// What the stubbed bridges saw. Guarded by e2eeSendBridgeTestMutex.
@(private = "file")
e2eeTestPublished: [dynamic]common.EncryptionKeyBundle
@(private = "file")
e2eeTestFetches: [dynamic][dynamic]int

@(private = "file")
e2eeTestPublishBridge :: proc(
	transport: ^ClientServerTransport,
	bundle: common.EncryptionKeyBundle,
) -> bool {
	// Tests run in parallel and every Connected publishes: only this file's server is recorded,
	// and the others get what the real bridge gives a transport that is not connected.
	if transport.serverID != E2EE_TEST_SERVER {
		return false
	}
	append(&e2eeTestPublished, bundle)
	return true
}

@(private = "file")
e2eeTestFetchBridge :: proc(transport: ^ClientServerTransport, userIDs: []int) -> bool {
	if transport.serverID != E2EE_TEST_SERVER {
		return false
	}
	ids := make([dynamic]int, 0, len(userIDs))
	append(&ids, ..userIDs)
	append(&e2eeTestFetches, ids)
	return true
}

// Swaps the bridges in; call the returned cleanup (deferred) to restore them.
@(private = "file")
e2eeTestBridgesBegin :: proc() {
	sync.mutex_lock(&e2eeSendBridgeTestMutex)
	e2eePublishBridge = e2eeTestPublishBridge
	e2eeFetchBridge = e2eeTestFetchBridge
}

@(private = "file")
e2eeTestBridgesEnd :: proc() {
	e2eeTestFetchesClear()
	delete(e2eeTestFetches)
	e2eeTestFetches = nil
	delete(e2eeTestPublished)
	e2eeTestPublished = nil
	e2eePublishBridge = ClientServerTransport_publishEncryptionKey
	e2eeFetchBridge = ClientServerTransport_fetchUserKeys
	sync.mutex_unlock(&e2eeSendBridgeTestMutex)
}

@(private = "file")
e2eeTestFetchesClear :: proc() {
	for ids in e2eeTestFetches {
		delete(ids)
	}
	clear(&e2eeTestFetches)
}

E2EETestPeer :: struct {
	userID:     int,
	privateKey: common.IdentityPrivateKeyBytes,
	publicKey:  common.IdentityPublicKeyBytes,
}

@(private = "file")
e2eeTestPeer :: proc(userID: int) -> E2EETestPeer {
	privateKey, publicKey, ok := common.generateIdentityKeyPair()
	assert(ok, "expected a peer identity key")
	return E2EETestPeer{userID = userID, privateKey = privateKey, publicKey = publicKey}
}

// A signed bundle for peer with a fresh encryption key.
@(private = "file")
e2eeTestBundle :: proc(peer: E2EETestPeer, createdAt: u64 = 1_700_000_000) -> common.UserKeyBundle {
	keyPair, keyOK := common.generateEncryptionKeyPair()
	assert(keyOK, "expected an encryption key pair")
	defer common.EncryptionKeyPair_wipe(&keyPair)
	bundle, signOK := common.signEncryptionKeyBundle(peer.privateKey, keyPair.publicKey, createdAt)
	assert(signOK, "expected the bundle to be signed")
	return common.UserKeyBundle {
		userId = peer.userID,
		identityPublicKey = bundle.identityPublicKey,
		encryptionPublicKey = bundle.encryptionPublicKey,
		createdAt = bundle.createdAt,
		signature = bundle.signature,
	}
}

// A connected state on E2EE_TEST_SERVER with a pinned server key, signed in as SELF, with bob
// and carol in the directory (bob and carol with bundles). The key store lives in memory.
@(private = "file")
e2eeTestState :: proc(bob, carol: E2EETestPeer) -> State {
	_, serverKey, _ := common.generateIdentityKeyPair()
	server := testDirectServer(E2EE_TEST_SERVER)
	serverHex := common.identityPublicKeyToHex(serverKey)
	defer delete(serverHex)
	fingerprintHex := common.fingerprintToHex(common.fingerprintIdentityPublicKey(serverKey))
	defer delete(fingerprintHex)
	server.pinned_server_public_key = serverHex
	server.pinned_server_fingerprint = fingerprintHex
	state := testUpdateStateForServer(server)
	testApplyConnectedAs(&state, E2EE_TEST_SERVER, E2EE_TEST_SELF, false)
	e2eeTestFetchesClear()
	testApplyUserList(
		&state,
		E2EE_TEST_SERVER,
		{id = E2EE_TEST_SELF, nickname = "self", isOnline = true},
		{
			id = E2EE_TEST_BOB,
			nickname = "bob",
			isOnline = true,
			identityPublicKey = bob.publicKey,
			hasEncryptionKey = true,
		},
		{
			id = E2EE_TEST_CAROL,
			nickname = "carol",
			identityPublicKey = carol.publicKey,
			hasEncryptionKey = true,
		},
	)
	return state
}

@(private = "file")
e2eeTestReceive :: proc(state: ^State, keys: []common.UserKeyBundle, missing: []int = nil) {
	event := ClientTransportRuntimeEvent {
		kind     = .UserKeysReceived,
		serverID = E2EE_TEST_SERVER,
	}
	append(&event.userKeys, ..keys)
	append(&event.missingUserIDs, ..missing)
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

@(private = "file")
e2eeTestInfo :: proc(state: ^State, userID: int) -> E2EEPeerKeyInfo {
	return State_e2eePeerKeyInfo(state, E2EE_TEST_SERVER, userID)
}

@(test)
testKeyStoreRoundTripsAndRefusesToOverwriteWhatItCannotRead :: proc(t: ^testing.T) {
	_ = t
	_, serverKey, _ := common.generateIdentityKeyPair()
	_, otherServerKey, _ := common.generateIdentityKeyPair()
	bob := e2eeTestPeer(E2EE_TEST_BOB)
	bundle := e2eeTestBundle(bob)

	store := KeyStore {
		loaded          = true,
		serverPublicKey = serverKey,
		writable        = true,
	}
	defer KeyStore_deinit(&store)
	KeyStore_setPin(
		&store,
		KeyPin {
			userID = E2EE_TEST_BOB,
			identityPublicKey = bob.publicKey,
			encryptionPublicKey = bundle.encryptionPublicKey,
			createdAt = bundle.createdAt,
			verified = true,
			firstSeen = 1_731_600_000,
		},
	)
	append(&store.directConversations, KeyStoreFileDirectConversation{E2EE_TEST_BOB, true})
	data, ok := keyStoreEncode(store)
	assert(ok, "expected the store to encode")
	defer delete(data)
	assert(
		strings.contains(string(data), `"format": 2`) &&
		strings.contains(string(data), `"users"`) &&
		strings.contains(string(data), `"rooms"`) &&
		strings.contains(string(data), `"direct_conversations"`),
		fmt.tprintf("expected the format and every section, got %s", string(data)),
	)

	parsed := keyStoreParse(data, serverKey)
	defer KeyStore_deinit(&parsed)
	assert(parsed.writable, fmt.tprintf("expected a writable store, got %q", parsed.loadError))
	assert(
		len(parsed.pins) == 1 && parsed.pins[0] == store.pins[0],
		fmt.tprintf("expected bob's pin to survive, got %v", parsed.pins),
	)
	assert(
		len(parsed.directConversations) == 1 && parsed.directConversations[0].encrypted,
		"expected the reserved sections to survive",
	)
	// A format 1 file (E1) loads as is and stays writable.
	formatOne, _ := strings.replace(
		string(data),
		`"format": 2`,
		`"format": 1`,
		1,
		context.temp_allocator,
	)
	older := keyStoreParse(transmute([]u8)formatOne, serverKey)
	defer KeyStore_deinit(&older)
	assert(
		older.writable && KeyStore_conversationEncrypted(older, E2EE_TEST_BOB),
		fmt.tprintf("expected a format 1 store to load writable, got %q", older.loadError),
	)

	// A store for another server key, a newer format, bad JSON, and a damaged entry are all
	// used read-only and never written back.
	text := string(data)
	newer, _ := strings.replace(text, `"format": 2`, `"format": 3`, 1, context.temp_allocator)
	damaged, _ := strings.replace(
		text,
		`"user_id": 2`,
		`"user_id": -2`,
		1,
		context.temp_allocator,
	)
	Case :: struct {
		label:     string,
		data:      string,
		serverKey: common.IdentityPublicKeyBytes,
		pins:      int,
	}
	cases := [?]Case {
		{"another server's store", text, otherServerKey, 0},
		{"a newer format", newer, serverKey, 1},
		{"invalid JSON", "{not json", serverKey, 0},
		{"a damaged entry", damaged, serverKey, 0},
	}
	for testCase in cases {
		readOnly := keyStoreParse(transmute([]u8)testCase.data, testCase.serverKey)
		defer KeyStore_deinit(&readOnly)
		assert(
			!readOnly.writable && len(readOnly.loadError) > 0,
			fmt.tprintf("expected %s to be read-only", testCase.label),
		)
		assert(
			len(readOnly.pins) == testCase.pins,
			fmt.tprintf("expected %d pins from %s, got %d", testCase.pins, testCase.label,
				len(readOnly.pins)),
		)
		readOnly.path = strings.clone("/nonexistent/never-written.json")
		saved, _ := KeyStore_save(&readOnly)
		assert(!saved, fmt.tprintf("expected %s never to be saved", testCase.label))
	}

	// Only a fingerprint names a file, so nothing outside the directory can be named.
	assert(keyStorePath("/keys", "../../etc/passwd") == "", "expected a bad fingerprint refused")
	assert(keyStorePath("", strings.repeat("a", 64, context.temp_allocator)) == "",
		"expected no path without a directory")
	path := keyStorePath("/keys", strings.repeat("ab", 32, context.temp_allocator))
	defer delete(path)
	assert(
		path == fmt.tprintf("/keys/%s.json", strings.repeat("ab", 32, context.temp_allocator)),
		fmt.tprintf("expected the fingerprint's file, got %q", path),
	)
}

// The store on disk: a save writes a 0600 file atomically, a load reads it back, and a file the
// client cannot read is left exactly as it was.
@(test)
testKeyStoreFileIsWrittenAtomicallyAndNeverOverwrittenWhenUnreadable :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux {
		_ = t
		return
	}
	tempDir := configTestCreateTempDir("hc_client_key_store")
	defer configTestRemovePathIfExists(tempDir)
	dir := configTestJoinPath({tempDir, "keys"})
	fingerprint := strings.repeat("cd", 32, context.temp_allocator)
	_, serverKey, _ := common.generateIdentityKeyPair()
	bob := e2eeTestPeer(E2EE_TEST_BOB)

	store := keyStoreLoad(keyStorePath(dir, fingerprint), serverKey)
	defer KeyStore_deinit(&store)
	assert(store.writable && len(store.pins) == 0, "expected a missing file to be an empty store")
	KeyStore_setPin(&store, KeyPin{userID = E2EE_TEST_BOB, identityPublicKey = bob.publicKey})
	saved, reason := KeyStore_save(&store)
	assert(saved, fmt.tprintf("expected the store saved, got %q", reason))
	info, statErr := os.stat(store.path, context.temp_allocator)
	assert(statErr == nil, "expected the key store file")
	assert(info.mode & os.perm(0o077) == {}, fmt.tprintf("expected 0600, got %v", info.mode))
	assert(!os.exists(fmt.tprintf("%s.tmp", store.path)), "expected no temporary file left")

	loaded := keyStoreLoad(keyStorePath(dir, fingerprint), serverKey)
	defer KeyStore_deinit(&loaded)
	assert(
		loaded.writable &&
		len(loaded.pins) == 1 &&
		loaded.pins[0].identityPublicKey == bob.publicKey,
		"expected bob's pin back from the file",
	)

	// A damaged file is never overwritten, whatever happens to the pins in memory.
	damaged := "{\"format\": 1, \"users\": [ broken"
	assert(
		os.write_entire_file_from_bytes(store.path, transmute([]u8)damaged) == nil,
		"expected the damaged file written",
	)
	readOnly := keyStoreLoad(keyStorePath(dir, fingerprint), serverKey)
	defer KeyStore_deinit(&readOnly)
	KeyStore_setPin(&readOnly, KeyPin{userID = E2EE_TEST_CAROL})
	refused, _ := KeyStore_save(&readOnly)
	after, _ := os.read_entire_file_from_path(store.path, context.temp_allocator)
	assert(!refused && string(after) == damaged, "expected the damaged file left as it was")
}

@(test)
testBundleVerdictsFollowTheTrustRules :: proc(t: ^testing.T) {
	_ = t
	bob := e2eeTestPeer(E2EE_TEST_BOB)
	mallory := e2eeTestPeer(E2EE_TEST_BOB)
	first := e2eeTestBundle(bob, 100)
	pin := KeyPin {
		userID              = E2EE_TEST_BOB,
		identityPublicKey   = bob.publicKey,
		encryptionPublicKey = first.encryptionPublicKey,
		createdAt           = first.createdAt,
	}
	tampered := first
	tampered.createdAt += 1
	smallOrder := first
	smallOrder.encryptionPublicKey = {}
	noIdentity := first
	noIdentity.identityPublicKey = {}
	Case :: struct {
		label:     string,
		pin:       Maybe(KeyPin),
		directory: common.IdentityPublicKeyBytes,
		bundle:    common.UserKeyBundle,
		verdict:   E2EEBundleVerdict,
	}
	cases := [?]Case {
		{"a first bundle", nil, bob.publicKey, first, .FirstUse},
		{"a first bundle without a directory key", nil, {}, first, .FirstUse},
		{"a first bundle under another directory key", nil, mallory.publicKey, first,
			.Inconsistent},
		{"the pinned bundle", pin, bob.publicKey, first, .Same},
		{"a newer encryption key", pin, bob.publicKey, e2eeTestBundle(bob, 200),
			.NewEncryptionKey},
		{"an older encryption key", pin, bob.publicKey, e2eeTestBundle(bob, 50), .Rollback},
		{"another identity key", pin, bob.publicKey, e2eeTestBundle(mallory, 300),
			.IdentityChanged},
		{"a bad signature", pin, bob.publicKey, tampered, .Invalid},
		{"a bad signature on first use", nil, bob.publicKey, tampered, .Invalid},
		{"a small-order key", nil, bob.publicKey, smallOrder, .Invalid},
		{"no identity key", nil, {}, noIdentity, .Invalid},
	}
	for testCase in cases {
		verdict := e2eeEvaluateBundle(testCase.pin, testCase.directory, testCase.bundle)
		assert(
			verdict == testCase.verdict,
			fmt.tprintf("expected %s to be %v, got %v", testCase.label, testCase.verdict, verdict),
		)
	}
}

// Connected publishes this profile's bundle once per session and fetches every pinned user.
@(test)
testE2EEPublishesOncePerSessionAndRefetchesPins :: proc(t: ^testing.T) {
	_ = t
	e2eeTestBridgesBegin()
	defer e2eeTestBridgesEnd()
	bob := e2eeTestPeer(E2EE_TEST_BOB)
	carol := e2eeTestPeer(E2EE_TEST_CAROL)
	state := e2eeTestState(bob, carol)
	defer State_deinit(&state)

	assert(len(e2eeTestPublished) == 1, fmt.tprintf("expected one publish, got %d",
		len(e2eeTestPublished)))
	published := e2eeTestPublished[0]
	selfKey, _ := common.identityPublicKeyFromHex(state.config.public_key)
	assert(
		published.identityPublicKey == selfKey && common.verifyEncryptionKeyBundle(published),
		"expected this profile's own signed bundle",
	)
	assert(State_e2eePublish(&state, E2EE_TEST_SERVER), "expected the publish to count as done")
	assert(len(e2eeTestPublished) == 1, "expected no second publish in the same session")
	assert(len(e2eeTestFetches) == 0, "expected no fetch without pins")

	bobBundle := e2eeTestBundle(bob)
	e2eeTestReceive(&state, {bobBundle})
	testApplyConnectedAs(&state, E2EE_TEST_SERVER, E2EE_TEST_SELF, false)
	assert(len(e2eeTestPublished) == 2, "expected the next session to publish again")
	assert(
		len(e2eeTestFetches) == 1 &&
		len(e2eeTestFetches[0]) == 1 &&
		e2eeTestFetches[0][0] == E2EE_TEST_BOB,
		fmt.tprintf("expected the new session to fetch bob's pin again, got %v", e2eeTestFetches),
	)
}

@(test)
testE2EEPinsOnFirstUseAndBlocksAChangedIdentityUntilTrusted :: proc(t: ^testing.T) {
	_ = t
	e2eeTestBridgesBegin()
	defer e2eeTestBridgesEnd()
	bob := e2eeTestPeer(E2EE_TEST_BOB)
	carol := e2eeTestPeer(E2EE_TEST_CAROL)
	state := e2eeTestState(bob, carol)
	defer State_deinit(&state)

	assert(e2eeTestInfo(&state, E2EE_TEST_BOB).state == .Unknown, "expected bob unknown first")
	assert(
		e2eeTestInfo(&state, E2EE_TEST_BOB).blockReason == .Pending,
		"expected an unknown key to wait",
	)
	// Opening the conversation fetches bob's key.
	State_openDirectConversation(&state, E2EE_TEST_SERVER, E2EE_TEST_BOB)
	assert(
		len(e2eeTestFetches) == 1 && e2eeTestFetches[0][0] == E2EE_TEST_BOB,
		"expected opening the conversation to fetch bob's key",
	)
	// A second request while it is on its way sends nothing.
	ids := [1]int{E2EE_TEST_BOB}
	assert(State_e2eeRequestUserKeys(&state, E2EE_TEST_SERVER, ids[:]) == 0,
		"expected no second fetch in flight")

	first := e2eeTestBundle(bob, 100)
	e2eeTestReceive(&state, {first})
	info := e2eeTestInfo(&state, E2EE_TEST_BOB)
	assert(
		info.state == .Unverified &&
		info.canEncrypt &&
		info.hasPin &&
		!info.verified &&
		info.identityPublicKey == bob.publicKey &&
		info.encryptionPublicKey == first.encryptionPublicKey,
		fmt.tprintf("expected bob pinned on first use, unverified, got %v", info),
	)

	// The server swaps bob's identity key: sending is blocked until the user decides.
	mallory := e2eeTestPeer(E2EE_TEST_BOB)
	swapped := e2eeTestBundle(mallory, 200)
	e2eeTestReceive(&state, {swapped})
	info = e2eeTestInfo(&state, E2EE_TEST_BOB)
	assert(
		info.state == .KeyChanged &&
		!info.canEncrypt &&
		info.blockReason == .KeyChanged &&
		info.hasOfferedKey &&
		info.identityPublicKey == bob.publicKey,
		fmt.tprintf("expected a hard key change keeping the old pin, got %v", info),
	)
	banner := buildE2EEKeyBanner(&state, E2EE_TEST_SERVER, E2EE_TEST_BOB)
	assert(
		banner.visible && banner.tone == .Warning && banner.showVerify && banner.showTrust &&
		strings.contains(banner.text, "bob's key changed"),
		fmt.tprintf("expected the key-changed banner, got %v", banner),
	)
	rows := buildSidebarRows(&state)
	sawBob := false
	for row in rows {
		if row.kind == .Member && row.id == E2EE_TEST_BOB {
			sawBob = row.keyState == .KeyChanged
		}
	}
	assert(sawBob, "expected bob's member row to show the key change")
	// A plain verify of the old pin is not possible; Mark as verified trusts the shown key.
	assert(State_e2eeTrustNewKey(&state, E2EE_TEST_SERVER, E2EE_TEST_BOB), "expected trust")
	info = e2eeTestInfo(&state, E2EE_TEST_BOB)
	assert(
		info.state == .Unverified &&
		info.canEncrypt &&
		info.identityPublicKey == mallory.publicKey &&
		info.encryptionPublicKey == swapped.encryptionPublicKey,
		fmt.tprintf("expected the new key pinned, unverified, got %v", info),
	)
}

@(test)
testE2EEAcceptsANewEncryptionKeyWithANoticeAndRefusesBadOnes :: proc(t: ^testing.T) {
	_ = t
	e2eeTestBridgesBegin()
	defer e2eeTestBridgesEnd()
	bob := e2eeTestPeer(E2EE_TEST_BOB)
	carol := e2eeTestPeer(E2EE_TEST_CAROL)
	state := e2eeTestState(bob, carol)
	defer State_deinit(&state)

	first := e2eeTestBundle(bob, 100)
	e2eeTestReceive(&state, {first})
	assert(State_e2eeMarkVerified(&state, E2EE_TEST_SERVER, E2EE_TEST_BOB), "expected verify")
	assert(e2eeTestInfo(&state, E2EE_TEST_BOB).state == .Verified, "expected bob verified")

	// A newer key under the same identity key is accepted, clears verified, and says so.
	second := e2eeTestBundle(bob, 200)
	changed := ClientTransportRuntimeEvent {
		kind     = .UserKeyChanged,
		serverID = E2EE_TEST_SERVER,
		userKey  = second,
	}
	State_applyRuntimeEvent(&state, &changed)
	ClientTransportRuntimeEvent_deinit(&changed)
	info := e2eeTestInfo(&state, E2EE_TEST_BOB)
	assert(
		info.state == .Unverified &&
		info.canEncrypt &&
		info.notice == .KeySetUpAgain &&
		info.encryptionPublicKey == second.encryptionPublicKey,
		fmt.tprintf("expected the new key accepted with a notice, got %v", info),
	)
	assert(
		e2eeKeyStateText(info, "bob") == "bob set up encryption again",
		"expected the notice sentence",
	)
	notice := buildE2EEKeyBanner(&state, E2EE_TEST_SERVER, E2EE_TEST_BOB)
	assert(notice.visible && notice.tone == .Notice && notice.showDismiss, "expected the notice")
	State_e2eeDismissNotice(&state, E2EE_TEST_SERVER, E2EE_TEST_BOB)
	assert(
		!buildE2EEKeyBanner(&state, E2EE_TEST_SERVER, E2EE_TEST_BOB).visible,
		"expected the notice dismissed",
	)

	// The old key again (a rollback) and a bad signature are refused, and the pin stays.
	tampered := e2eeTestBundle(bob, 300)
	tampered.createdAt += 1
	for bad in ([]common.UserKeyBundle{first, tampered}) {
		e2eeTestReceive(&state, {bad})
		info = e2eeTestInfo(&state, E2EE_TEST_BOB)
		assert(
			info.state == .InvalidKey &&
			!info.canEncrypt &&
			info.encryptionPublicKey == second.encryptionPublicKey,
			fmt.tprintf("expected the bundle refused and the pin kept, got %v", info),
		)
		assert(
			!State_e2eeMarkVerified(&state, E2EE_TEST_SERVER, E2EE_TEST_BOB),
			"expected no verify of an invalid key",
		)
	}
	// The pinned bundle again clears it.
	e2eeTestReceive(&state, {second})
	assert(e2eeTestInfo(&state, E2EE_TEST_BOB).state == .Unverified, "expected the pin to match")
}

@(test)
testE2EEMissingBundlesAndDirectoryKeyChanges :: proc(t: ^testing.T) {
	_ = t
	e2eeTestBridgesBegin()
	defer e2eeTestBridgesEnd()
	bob := e2eeTestPeer(E2EE_TEST_BOB)
	carol := e2eeTestPeer(E2EE_TEST_CAROL)
	state := e2eeTestState(bob, carol)
	defer State_deinit(&state)

	// Never pinned and no bundle: not set up yet. Pinned and then no bundle: not provided.
	e2eeTestReceive(&state, {e2eeTestBundle(bob)}, {E2EE_TEST_CAROL})
	assert(e2eeTestInfo(&state, E2EE_TEST_CAROL).state == .NotSetUp, "expected carol not set up")
	assert(
		e2eeKeyStateText(e2eeTestInfo(&state, E2EE_TEST_CAROL), "carol") ==
		"carol has not set up encryption yet",
		"expected the not-set-up sentence",
	)
	e2eeTestReceive(&state, nil, {E2EE_TEST_BOB})
	info := e2eeTestInfo(&state, E2EE_TEST_BOB)
	assert(
		info.state == .NotProvided && info.blockReason == .NotProvided && info.hasPin,
		fmt.tprintf("expected bob's key not provided, got %v", info),
	)
	assert(
		e2eeKeyStateText(info, "bob") == "The server is not providing bob's key",
		"expected the not-provided sentence",
	)

	// A directory that names another identity key for bob is a key change, and asks for the
	// bundle; one without a bundle for a pinned user is "not provided".
	mallory := e2eeTestPeer(E2EE_TEST_BOB)
	e2eeTestFetchesClear()
	testApplyUserList(
		&state,
		E2EE_TEST_SERVER,
		{id = E2EE_TEST_SELF, nickname = "self"},
		{
			id = E2EE_TEST_BOB,
			nickname = "bob",
			identityPublicKey = mallory.publicKey,
			hasEncryptionKey = true,
		},
		{id = E2EE_TEST_CAROL, nickname = "carol", identityPublicKey = carol.publicKey},
	)
	info = e2eeTestInfo(&state, E2EE_TEST_BOB)
	assert(
		info.state == .KeyChanged && !info.hasOfferedKey,
		fmt.tprintf("expected a key change from the directory, got %v", info),
	)
	assert(
		len(e2eeTestFetches) == 1 && e2eeTestFetches[0][0] == E2EE_TEST_BOB,
		"expected the changed key to be fetched",
	)
	// Trust needs the new bundle first.
	assert(
		!State_e2eeTrustNewKey(&state, E2EE_TEST_SERVER, E2EE_TEST_BOB),
		"expected no trust without the new bundle",
	)
	dialog := State_openVerifyDialog(&state, E2EE_TEST_SERVER, E2EE_TEST_BOB)
	assert(dialog, "expected the dialog to open")
	view := buildVerifyDialogView(&state)
	assert(
		view.visible && !view.markEnabled && len(view.safetyNumber) == 0 &&
		view.stateTone == .Warning,
		fmt.tprintf("expected the dialog to wait for the new key, got %v", view),
	)
}

// The safety number is the same on both sides, the dialog shows it in three rows, and Mark as
// verified persists.
@(test)
testVerifyDialogShowsTheSafetyNumberBothSidesSee :: proc(t: ^testing.T) {
	_ = t
	e2eeTestBridgesBegin()
	defer e2eeTestBridgesEnd()
	bob := e2eeTestPeer(E2EE_TEST_BOB)
	carol := e2eeTestPeer(E2EE_TEST_CAROL)
	state := e2eeTestState(bob, carol)
	defer State_deinit(&state)

	assert(
		!State_openVerifyDialog(&state, E2EE_TEST_SERVER, E2EE_TEST_SELF),
		"expected no dialog for yourself",
	)
	assert(State_openVerifyDialog(&state, E2EE_TEST_SERVER, E2EE_TEST_BOB), "expected a dialog")
	empty := buildVerifyDialogView(&state)
	assert(empty.visible && len(empty.safetyNumber) == 0, "expected no number before a key")
	e2eeTestReceive(&state, {e2eeTestBundle(bob)})

	view := buildVerifyDialogView(&state)
	selfKey, _ := common.identityPublicKeyFromHex(state.config.public_key)
	bobSide := common.formatSafetyNumber(common.computeSafetyNumber(bob.publicKey, selfKey))
	assert(
		view.safetyNumber == string(bobSide[:]),
		fmt.tprintf("expected bob's number %q, got %q", string(bobSide[:]), view.safetyNumber),
	)
	joined := strings.join(view.safetyNumberRows[:], " ", context.temp_allocator)
	assert(joined == view.safetyNumber, "expected the three rows to make up the number")
	for row in view.safetyNumberRows {
		assert(len(row) == 23, fmt.tprintf("expected four groups per row, got %q", row))
	}
	assert(
		view.markEnabled &&
		view.markLabel == "Mark as verified" &&
		strings.contains(view.title, "bob"),
		fmt.tprintf("expected Mark as verified for bob, got %v", view),
	)
	assert(State_verifyDialogMarkVerified(&state), "expected Mark as verified")
	verified := buildVerifyDialogView(&state)
	assert(
		!verified.markEnabled && verified.markLabel == "Verified",
		"expected the dialog to show Verified",
	)
	index := State_e2eeServerIndex(state, E2EE_TEST_SERVER)
	pin, _ := KeyStore_pin(&state.e2ee[index].store, E2EE_TEST_BOB)
	assert(pin.verified, "expected the pin to be marked verified")
	State_closeVerifyDialog(&state)
	assert(!buildVerifyDialogView(&state).visible, "expected the dialog closed")
}

// More than USER_KEYS_FETCH_MAX users go out in batches, without this account or repeats.
@(test)
testE2EEFetchesInBatches :: proc(t: ^testing.T) {
	_ = t
	e2eeTestBridgesBegin()
	defer e2eeTestBridgesEnd()
	bob := e2eeTestPeer(E2EE_TEST_BOB)
	carol := e2eeTestPeer(E2EE_TEST_CAROL)
	state := e2eeTestState(bob, carol)
	defer State_deinit(&state)

	ids := make([dynamic]int, 0, 140)
	defer delete(ids)
	append(&ids, E2EE_TEST_SELF, 0, E2EE_TEST_BOB, E2EE_TEST_BOB)
	for userID in 100 ..< 230 {
		append(&ids, userID)
	}
	requested := State_e2eeRequestUserKeys(&state, E2EE_TEST_SERVER, ids[:])
	assert(requested == 131, fmt.tprintf("expected 131 IDs requested, got %d", requested))
	assert(
		len(e2eeTestFetches) == 3 &&
		len(e2eeTestFetches[0]) == common.USER_KEYS_FETCH_MAX &&
		len(e2eeTestFetches[1]) == common.USER_KEYS_FETCH_MAX &&
		len(e2eeTestFetches[2]) == 3,
		fmt.tprintf("expected batches of 64, 64 and 3, got %d batches", len(e2eeTestFetches)),
	)
	for batch in e2eeTestFetches {
		assert(common.userKeysFetchIsValid(batch[:]), "expected every batch to be valid")
		for userID in batch {
			assert(userID != E2EE_TEST_SELF, "expected this account never fetched")
		}
	}
}
