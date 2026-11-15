package client

import "../common"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"

// Account encryption keys on the client (e2ee-design.md 3.1-3.5): publishing this profile's
// bundle, fetching and verifying other accounts' bundles, pinning them on first use in the
// per-server key store (keystore.odin), key changes, and verification.
//
// Rules:
//
// - The pin is the trust anchor. A bundle from the server is used only after its signature
//   verifies against its own identity key and that identity key equals the pin (or, on first
//   use, the directory's identity key, and is then pinned). Callers that encrypt or verify use
//   E2EEPeerKeyInfo's pinned keys, never a bundle the server sent.
// - Every failed check is final for that bundle: it is never retried with another key, and the
//   pin is never changed by it. Only the user changes a pin to another identity key (Trust the
//   new key, or Mark as verified in the key-changed state).
// - A new encryption key under the pinned identity key, correctly signed and newer than the
//   pinned one, replaces the pinned encryption key, clears verified and shows a notice ("<name>
//   set up encryption again"). An older one is refused (no rollback).
// - This account itself is never pinned or fetched; its own keys come from config.json.

// What the client knows about a peer's key on one server.
E2EEKeyState :: enum u8 {
	Unknown, // No pin, and the server has not said yet: fetch first
	NotSetUp, // No pin, and the server has no bundle: "<name> has not set up encryption yet"
	Unverified, // Pinned on first use; the server's bundle matches the pin
	Verified, // Pinned and verified by safety number
	KeyChanged, // The server names another identity key than the pin: sending is blocked
	NotProvided, // Pinned, but the server now says there is no bundle: sending is blocked
	InvalidKey, // The server sent a bundle that does not verify or is older than the pin
}

// Why encryption to a peer is not possible now (design 4.6, plus Pending and InvalidKey).
E2EEBlockReason :: enum u8 {
	None,
	Pending, // Not known yet; a fetch is on its way or needed (State_e2eeRequestUserKeys)
	NotSetUp,
	KeyChanged,
	NotProvided,
	InvalidKey,
}

// A notice the conversation shows once, then the user dismisses it.
E2EEKeyNotice :: enum u8 {
	None,
	// A new encryption key under the same identity key: "<name> set up encryption again".
	KeySetUpAgain,
}

// The server's side of a peer's key, from this session's answers.
E2EEServerKeyStatus :: enum u8 {
	Unknown,
	Matches, // The last bundle matched (or was) the pin
	NoBundle, // The server has no bundle for the account
	Changed, // The server named another identity key than the pin
	Invalid, // The last bundle failed a check
}

// The query E2 builds on. The keys are the pin's (zero without one).
E2EEPeerKeyInfo :: struct {
	state:               E2EEKeyState,
	canEncrypt:          bool,
	blockReason:         E2EEBlockReason,
	hasPin:              bool,
	identityPublicKey:   common.IdentityPublicKeyBytes,
	encryptionPublicKey: common.EncryptionPublicKeyBytes,
	createdAt:           u64,
	verified:            bool,
	notice:              E2EEKeyNotice,
	// KeyChanged: whether the server sent a valid bundle under the new identity key, which
	// Trust the new key would pin.
	hasOfferedKey:       bool,
}

E2EEUser :: struct {
	userID:     int,
	status:     E2EEServerKeyStatus,
	// Changed: the server's verified bundle under the new identity key, when it sent one.
	offered:    common.UserKeyBundle,
	hasOffered: bool,
	notice:     E2EEKeyNotice,
	// A ClientFetchUserKeys for this user is on its way.
	fetching:   bool,
}

ServerE2EEState :: struct {
	serverID:  int,
	store:     KeyStore,
	users:     [dynamic]E2EEUser,
	// This session's bundle went out (once per session, design 3.1).
	published: bool,
}

ServerE2EEState_deinit :: proc(server: ^ServerE2EEState) {
	KeyStore_deinit(&server.store)
	delete(server.users)
	server^ = {}
}

// Sends go through these; tests swap them under e2eeSendBridgeTestMutex.
E2EEPublishBridge :: proc(
	transport: ^ClientServerTransport,
	bundle: common.EncryptionKeyBundle,
) -> bool
E2EEFetchBridge :: proc(transport: ^ClientServerTransport, userIDs: []int) -> bool

e2eePublishBridge: E2EEPublishBridge = ClientServerTransport_publishEncryptionKey
e2eeFetchBridge: E2EEFetchBridge = ClientServerTransport_fetchUserKeys
e2eeSendBridgeTestMutex: sync.Mutex

State_e2eeServerIndex :: proc(state: State, serverID: int) -> int {
	for server, index in state.e2ee {
		if server.serverID == serverID {
			return index
		}
	}
	return -1
}

// The server's E2EE state, created when missing. Valid until the next server is added.
State_e2eeServer :: proc(state: ^State, serverID: int) -> ^ServerE2EEState {
	if index := State_e2eeServerIndex(state^, serverID); index >= 0 {
		return &state.e2ee[index]
	}
	append(&state.e2ee, ServerE2EEState{serverID = serverID})
	return &state.e2ee[len(state.e2ee) - 1]
}

State_removeServerE2EE :: proc(state: ^State, serverID: int) {
	if index := State_e2eeServerIndex(state^, serverID); index >= 0 {
		ServerE2EEState_deinit(&state.e2ee[index])
		ordered_remove(&state.e2ee, index)
	}
	if state.verifyDialog.serverID == serverID {
		State_closeVerifyDialog(state)
	}
}

ServerE2EEState_user :: proc(server: ^ServerE2EEState, userID: int) -> ^E2EEUser {
	for &user in server.users {
		if user.userID == userID {
			return &user
		}
	}
	append(&server.users, E2EEUser{userID = userID})
	return &server.users[len(server.users) - 1]
}

@(private = "file")
ServerE2EEState_findUser :: proc(server: ^ServerE2EEState, userID: int) -> (^E2EEUser, bool) {
	for &user in server.users {
		if user.userID == userID {
			return &user, true
		}
	}
	return nil, false
}

// Loads the server's key store for its pinned key, or reloads it when the pin changed (the
// server key was trusted again: a fresh store, design 3.3). False while the server has no pin.
State_e2eeEnsureStore :: proc(state: ^State, serverID: int) -> (^ServerE2EEState, bool) {
	server, configOK := State_serverConfig(state, serverID)
	if !configOK {
		return nil, false
	}
	serverKey, keyOK := common.identityPublicKeyFromHex(server.pinned_server_public_key)
	fingerprint := server.pinned_server_fingerprint
	e2ee := State_e2eeServer(state, serverID)
	if !keyOK {
		return e2ee, false
	}
	if e2ee.store.loaded && e2ee.store.serverPublicKey == serverKey {
		return e2ee, true
	}
	KeyStore_deinit(&e2ee.store)
	delete(e2ee.users)
	e2ee.users = nil
	e2ee.store = keyStoreLoad(keyStorePath(state.keyStoreDir, fingerprint), serverKey)
	if !e2ee.store.writable {
		State_setChatStatus(
			state,
			fmt.tprintf(
				"Encryption pins are read-only on this server: %s",
				e2ee.store.loadError,
			),
		)
	}
	return e2ee, true
}

State_e2eeSaveStore :: proc(state: ^State, e2ee: ^ServerE2EEState) {
	if ok, reason := KeyStore_save(&e2ee.store); !ok {
		State_setChatStatus(state, fmt.tprintf("Could not save encryption pins: %s", reason))
	}
}

// Called on Connected: loads the key store, publishes this profile's bundle once for the
// session, and fetches the bundle of every pinned user again, so a key the server changed
// behind the client's back shows as soon as possible.
State_e2eeConnected :: proc(state: ^State, serverID: int) {
	e2ee, ok := State_e2eeEnsureStore(state, serverID)
	if e2ee == nil {
		return
	}
	State_e2eeConnectionReset(state, serverID)
	State_e2eePublish(state, serverID)
	if !ok {
		return
	}
	pinned := make([dynamic]int, 0, len(e2ee.store.pins))
	defer delete(pinned)
	for pin in e2ee.store.pins {
		append(&pinned, pin.userID)
	}
	State_e2eeRequestUserKeys(state, serverID, pinned[:])
}

// Requests in flight died with the session; the next one publishes again.
State_e2eeConnectionReset :: proc(state: ^State, serverID: int) {
	index := State_e2eeServerIndex(state^, serverID)
	if index < 0 {
		return
	}
	e2ee := &state.e2ee[index]
	e2ee.published = false
	for &user in e2ee.users {
		user.fetching = false
	}
}

// Protocol errors do not say which request failed, so fetches in flight are forgotten and the
// next request for those users goes out again. The publish is not repeated: a refused bundle
// ("Invalid encryption key") would be refused again.
State_e2eeProtocolError :: proc(state: ^State, serverID: int) {
	index := State_e2eeServerIndex(state^, serverID)
	if index < 0 {
		return
	}
	for &user in state.e2ee[index].users {
		user.fetching = false
	}
}

// Sends this profile's bundle once per session. Returns whether it went out (now or before).
State_e2eePublish :: proc(state: ^State, serverID: int) -> bool {
	transportIndex := State_selectedTransportIndexForServerID(state^, serverID)
	if transportIndex < 0 || !State_isServerConnected(state, serverID) {
		return false
	}
	e2ee := State_e2eeServer(state, serverID)
	if e2ee.published {
		return true
	}
	keyPair, bundle, ok := Config_encryptionKey(state.config)
	common.EncryptionKeyPair_wipe(&keyPair)
	if !ok {
		State_setChatStatus(state, "This profile has no valid encryption key")
		return false
	}
	transport := &state.serverTransports[transportIndex]
	ClientNetworkWorker_lock(state.networkWorker)
	defer ClientNetworkWorker_unlock(state.networkWorker)
	e2ee.published = e2eePublishBridge(transport, bundle)
	return e2ee.published
}

// Fetches the bundles of userIDs (in batches of USER_KEYS_FETCH_MAX), skipping this account,
// invalid IDs, repeats, and users whose fetch is already on its way. Answers arrive as
// ServerUserKeys (State_e2eeReceiveUserKeys). Returns how many IDs were requested.
State_e2eeRequestUserKeys :: proc(state: ^State, serverID: int, userIDs: []int) -> int {
	transportIndex := State_selectedTransportIndexForServerID(state^, serverID)
	if transportIndex < 0 || !State_isServerConnected(state, serverID) {
		return 0
	}
	selfUserID := State_selfUserID(state, serverID)
	e2ee := State_e2eeServer(state, serverID)
	wanted := make([dynamic]int, 0, len(userIDs))
	defer delete(wanted)
	for userID, index in userIDs {
		if userID <= 0 || userID == selfUserID {
			continue
		}
		repeated := false
		for earlier in userIDs[:index] {
			repeated ||= earlier == userID
		}
		if repeated {
			continue
		}
		if user, found := ServerE2EEState_findUser(e2ee, userID); found && user.fetching {
			continue
		}
		append(&wanted, userID)
	}

	transport := &state.serverTransports[transportIndex]
	requested := 0
	ClientNetworkWorker_lock(state.networkWorker)
	for start := 0; start < len(wanted); start += common.USER_KEYS_FETCH_MAX {
		batch := wanted[start:min(start + common.USER_KEYS_FETCH_MAX, len(wanted))]
		if !e2eeFetchBridge(transport, batch) {
			break
		}
		for userID in batch {
			ServerE2EEState_user(e2ee, userID).fetching = true
		}
		requested += len(batch)
	}
	ClientNetworkWorker_unlock(state.networkWorker)
	return requested
}

// What a bundle from the server means against the pin (pure; design 3.4).
E2EEBundleVerdict :: enum u8 {
	Invalid, // The signature does not verify against the bundle's own identity key, or the key is
	         // unusable
	Rollback, // A different encryption key under the pinned identity key, not newer than the pin
	Inconsistent, // No pin, and the bundle's identity key is not the directory's
	FirstUse, // No pin: pin it, unverified
	Same, // The pinned keys
	NewEncryptionKey, // A newer encryption key under the pinned identity key
	IdentityChanged, // Another identity key than the pin
}

// directoryIdentity is the directory's identity key for the account, zero when unknown.
e2eeEvaluateBundle :: proc(
	pin: Maybe(KeyPin),
	directoryIdentity: common.IdentityPublicKeyBytes,
	bundle: common.UserKeyBundle,
) -> E2EEBundleVerdict {
	if bundle.identityPublicKey == {} ||
	   !common.verifyEncryptionKeyBundle(common.UserKeyBundle_toEncryptionKeyBundle(bundle)) {
		return .Invalid
	}
	if pinned, hasPin := pin.?; hasPin {
		if bundle.identityPublicKey != pinned.identityPublicKey {
			return .IdentityChanged
		}
		if bundle.encryptionPublicKey == pinned.encryptionPublicKey {
			return .Same
		}
		if bundle.createdAt <= pinned.createdAt {
			return .Rollback
		}
		return .NewEncryptionKey
	}
	if directoryIdentity != {} && directoryIdentity != bundle.identityPublicKey {
		return .Inconsistent
	}
	return .FirstUse
}

@(private = "file")
State_e2eeDirectoryIdentity :: proc(
	state: ^State,
	serverID, userID: int,
) -> common.IdentityPublicKeyBytes {
	index := State_serverDirectCacheIndex(state^, serverID)
	if index < 0 {
		return {}
	}
	cache := &state.serverDirectCaches[index]
	if userIndex := ServerDirectCache_userIndex(cache^, userID); userIndex >= 0 {
		return cache.users[userIndex].identityPublicKey
	}
	return {}
}

@(private = "file")
e2eeNowUnix :: proc() -> i64 {
	return time.time_to_unix(time.now())
}

// Applies one bundle the server sent (fetched or pushed). Returns the verdict.
State_e2eeApplyBundle :: proc(
	state: ^State,
	serverID: int,
	bundle: common.UserKeyBundle,
) -> E2EEBundleVerdict {
	e2ee, ok := State_e2eeEnsureStore(state, serverID)
	if !ok || bundle.userId <= 0 || bundle.userId == State_selfUserID(state, serverID) {
		return .Invalid
	}
	user := ServerE2EEState_user(e2ee, bundle.userId)
	user.fetching = false
	pin: Maybe(KeyPin)
	if pinned, hasPin := KeyStore_pin(&e2ee.store, bundle.userId); hasPin {
		pin = pinned^
	}
	verdict := e2eeEvaluateBundle(
		pin,
		State_e2eeDirectoryIdentity(state, serverID, bundle.userId),
		bundle,
	)
	switch verdict {
	case .Invalid, .Rollback, .Inconsistent:
		user.status = .Invalid
	case .FirstUse:
		KeyStore_setPin(
			&e2ee.store,
			KeyPin {
				userID = bundle.userId,
				identityPublicKey = bundle.identityPublicKey,
				encryptionPublicKey = bundle.encryptionPublicKey,
				createdAt = bundle.createdAt,
				firstSeen = e2eeNowUnix(),
			},
		)
		State_e2eeSaveStore(state, e2ee)
		user.status = .Matches
		user.hasOffered = false
	case .Same:
		user.status = .Matches
		user.hasOffered = false
	case .NewEncryptionKey:
		pinned, _ := KeyStore_pin(&e2ee.store, bundle.userId)
		pinned.encryptionPublicKey = bundle.encryptionPublicKey
		pinned.createdAt = bundle.createdAt
		pinned.verified = false
		State_e2eeSaveStore(state, e2ee)
		user.status = .Matches
		user.hasOffered = false
		user.notice = .KeySetUpAgain
	case .IdentityChanged:
		user.status = .Changed
		user.offered = bundle
		user.hasOffered = true
	}
	return verdict
}

// ServerUserKeys: applies every bundle, and marks the requested users without one.
State_e2eeReceiveUserKeys :: proc(
	state: ^State,
	serverID: int,
	keys: []common.UserKeyBundle,
	missingUserIDs: []int,
) {
	if State_selectedTransportIndexForServerID(state^, serverID) < 0 {
		return
	}
	for bundle in keys {
		State_e2eeApplyBundle(state, serverID, bundle)
	}
	e2ee, ok := State_e2eeEnsureStore(state, serverID)
	if !ok {
		return
	}
	selfUserID := State_selfUserID(state, serverID)
	for userID in missingUserIDs {
		if userID <= 0 || userID == selfUserID {
			continue
		}
		user := ServerE2EEState_user(e2ee, userID)
		user.fetching = false
		user.status = .NoBundle
		user.hasOffered = false
	}
}

// ServerUserKeyChanged: an account stored a new bundle. The directory learns it has one; a
// pinned user's bundle is checked against the pin at once, and an unpinned user is only marked
// for a fetch when someone needs the key (it is not pinned from a broadcast).
State_e2eeUserKeyChanged :: proc(state: ^State, serverID: int, bundle: common.UserKeyBundle) {
	if State_selectedTransportIndexForServerID(state^, serverID) < 0 || bundle.userId <= 0 {
		return
	}
	if index := State_serverDirectCacheIndex(state^, serverID); index >= 0 {
		cache := &state.serverDirectCaches[index]
		if userIndex := ServerDirectCache_userIndex(cache^, bundle.userId); userIndex >= 0 {
			cache.users[userIndex].hasEncryptionKey = true
		}
	}
	e2ee, ok := State_e2eeEnsureStore(state, serverID)
	if !ok || bundle.userId == State_selfUserID(state, serverID) {
		return
	}
	if KeyStore_pinIndex(e2ee.store, bundle.userId) >= 0 {
		State_e2eeApplyBundle(state, serverID, bundle)
		return
	}
	if user, found := ServerE2EEState_findUser(e2ee, bundle.userId); found {
		user.status = .Unknown
	}
}

// Checks one directory entry (from ServerUserList or ServerUserUpdated, which carry the
// account's identity key and bundle flag) against the pin: another identity key than the pin
// is a key change and asks for the bundle; no bundle for a pinned user is "the server is not
// providing the key".
State_e2eeCheckDirectoryEntry :: proc(state: ^State, serverID: int, user: common.UserSummary) {
	if user.id <= 0 || user.id == State_selfUserID(state, serverID) {
		return
	}
	e2ee, ok := State_e2eeEnsureStore(state, serverID)
	if !ok {
		return
	}
	pin, hasPin := KeyStore_pin(&e2ee.store, user.id)
	if !hasPin {
		if !user.hasEncryptionKey {
			entry := ServerE2EEState_user(e2ee, user.id)
			entry.status = .NoBundle
		} else if entry, found := ServerE2EEState_findUser(e2ee, user.id);
		   found && entry.status == .NoBundle {
			entry.status = .Unknown
		}
		return
	}
	entry := ServerE2EEState_user(e2ee, user.id)
	if user.identityPublicKey != {} && user.identityPublicKey != pin.identityPublicKey {
		if !entry.hasOffered || entry.offered.identityPublicKey != user.identityPublicKey {
			entry.hasOffered = false
		}
		entry.status = .Changed
		ids := [1]int{user.id}
		State_e2eeRequestUserKeys(state, serverID, ids[:])
		return
	}
	if !user.hasEncryptionKey {
		entry.status = .NoBundle
		entry.hasOffered = false
	}
}

// After ServerUserList replaced the directory.
State_e2eeDirectoryReceived :: proc(state: ^State, serverID: int) {
	index := State_serverDirectCacheIndex(state^, serverID)
	if index < 0 {
		return
	}
	// By index: a check may request keys, which never touches the directory.
	for userIndex in 0 ..< len(state.serverDirectCaches[index].users) {
		user := state.serverDirectCaches[index].users[userIndex]
		State_e2eeCheckDirectoryEntry(state, serverID, user)
	}
}

e2eeKeyStateFor :: proc(hasPin: bool, verified: bool, status: E2EEServerKeyStatus) -> E2EEKeyState {
	if hasPin {
		switch status {
		case .Unknown, .Matches:
			return verified ? .Verified : .Unverified
		case .NoBundle:
			return .NotProvided
		case .Changed:
			return .KeyChanged
		case .Invalid:
			return .InvalidKey
		}
	}
	#partial switch status {
	case .NoBundle:
		return .NotSetUp
	case .Invalid:
		return .InvalidKey
	}
	return .Unknown
}

e2eeBlockReasonFor :: proc(keyState: E2EEKeyState) -> E2EEBlockReason {
	switch keyState {
	case .Unverified, .Verified:
		return .None
	case .Unknown:
		return .Pending
	case .NotSetUp:
		return .NotSetUp
	case .KeyChanged:
		return .KeyChanged
	case .NotProvided:
		return .NotProvided
	case .InvalidKey:
		return .InvalidKey
	}
	return .Pending
}

// Whether encryption to userID on serverID is possible, why not, and the pinned keys (E2's
// entry point). Pure: never fetches; a Pending peer needs State_e2eeRequestUserKeys.
State_e2eePeerKeyInfo :: proc(state: ^State, serverID, userID: int) -> (info: E2EEPeerKeyInfo) {
	status := E2EEServerKeyStatus.Unknown
	index := State_e2eeServerIndex(state^, serverID)
	if index >= 0 {
		e2ee := &state.e2ee[index]
		if pin, hasPin := KeyStore_pin(&e2ee.store, userID); hasPin {
			info.hasPin = true
			info.identityPublicKey = pin.identityPublicKey
			info.encryptionPublicKey = pin.encryptionPublicKey
			info.createdAt = pin.createdAt
			info.verified = pin.verified
		}
		if user, found := ServerE2EEState_findUser(e2ee, userID); found {
			status = user.status
			info.notice = user.notice
			info.hasOfferedKey = user.status == .Changed && user.hasOffered
		}
	}
	info.state = e2eeKeyStateFor(info.hasPin, info.verified, status)
	info.blockReason = e2eeBlockReasonFor(info.state)
	info.canEncrypt = info.blockReason == .None
	return
}

// The sentence for a peer's key state or notice, for banners and the harness; "" when there is
// nothing to say (Unverified, Verified). name is the peer's display name.
e2eeKeyStateText :: proc(
	info: E2EEPeerKeyInfo,
	name: string,
	allocator := context.temp_allocator,
) -> string {
	switch info.state {
	case .Unknown:
		return fmt.aprintf("Checking %s's encryption key…", name, allocator = allocator)
	case .NotSetUp:
		return fmt.aprintf("%s has not set up encryption yet", name, allocator = allocator)
	case .KeyChanged:
		return fmt.aprintf("%s's key changed", name, allocator = allocator)
	case .NotProvided:
		return fmt.aprintf("The server is not providing %s's key", name, allocator = allocator)
	case .InvalidKey:
		return fmt.aprintf("The server sent an invalid key for %s", name, allocator = allocator)
	case .Unverified, .Verified:
		if info.notice == .KeySetUpAgain {
			return fmt.aprintf("%s set up encryption again", name, allocator = allocator)
		}
	}
	return ""
}

// The harness's and the logs' name for a state.
e2eeKeyStateName :: proc(keyState: E2EEKeyState) -> string {
	switch keyState {
	case .Unknown:
		return "unknown"
	case .NotSetUp:
		return "not_set_up"
	case .Unverified:
		return "unverified"
	case .Verified:
		return "verified"
	case .KeyChanged:
		return "key_changed"
	case .NotProvided:
		return "not_provided"
	case .InvalidKey:
		return "invalid_key"
	}
	return "unknown"
}

// Trust the new key (design 3.4): pins the bundle the server sent under the new identity key,
// unverified. Only in KeyChanged with a valid offered bundle; otherwise it asks the server for
// the bundle and returns false.
State_e2eeTrustNewKey :: proc(state: ^State, serverID, userID: int, verified := false) -> bool {
	e2ee, ok := State_e2eeEnsureStore(state, serverID)
	if !ok {
		return false
	}
	user, found := ServerE2EEState_findUser(e2ee, userID)
	if !found || user.status != .Changed {
		return false
	}
	if !user.hasOffered {
		ids := [1]int{userID}
		State_e2eeRequestUserKeys(state, serverID, ids[:])
		return false
	}
	KeyStore_setPin(
		&e2ee.store,
		KeyPin {
			userID = userID,
			identityPublicKey = user.offered.identityPublicKey,
			encryptionPublicKey = user.offered.encryptionPublicKey,
			createdAt = user.offered.createdAt,
			verified = verified,
			firstSeen = e2eeNowUnix(),
		},
	)
	user.status = .Matches
	user.hasOffered = false
	user.notice = .None
	State_e2eeSaveStore(state, e2ee)
	// Messages that waited for a key open with the new pin; ones already opened or refused
	// under the old one stay as they are (never retried with another key).
	State_directKeysChanged(state, serverID)
	return true
}

// Mark as verified: the user compared safety numbers. For a matching pin it sets verified; in
// KeyChanged it trusts the offered key and marks it verified, because the number shown was the
// new key's. Refused while the server's key is invalid or missing.
State_e2eeMarkVerified :: proc(state: ^State, serverID, userID: int) -> bool {
	info := State_e2eePeerKeyInfo(state, serverID, userID)
	switch info.state {
	case .KeyChanged:
		return State_e2eeTrustNewKey(state, serverID, userID, verified = true)
	case .Unverified, .Verified:
		e2ee, ok := State_e2eeEnsureStore(state, serverID)
		if !ok {
			return false
		}
		pin, _ := KeyStore_pin(&e2ee.store, userID)
		if !pin.verified {
			pin.verified = true
			State_e2eeSaveStore(state, e2ee)
		}
		if user, found := ServerE2EEState_findUser(e2ee, userID); found {
			user.notice = .None
		}
		return true
	case .Unknown, .NotSetUp, .NotProvided, .InvalidKey:
	}
	return false
}

State_e2eeDismissNotice :: proc(state: ^State, serverID, userID: int) {
	index := State_e2eeServerIndex(state^, serverID)
	if index < 0 {
		return
	}
	if user, found := ServerE2EEState_findUser(&state.e2ee[index], userID); found {
		user.notice = .None
	}
}

// The safety number between this profile and userID (design 3.5), as "12345 67890 ...", for
// the pinned identity key, or in KeyChanged for the key the server now offers (what Mark as
// verified would trust). ok is false without a key to compare.
State_e2eeSafetyNumber :: proc(
	state: ^State,
	serverID, userID: int,
	allocator := context.temp_allocator,
) -> (
	text: string,
	ok: bool,
) {
	ownKey, ownOK := common.identityPublicKeyFromHex(state.config.public_key)
	if !ownOK {
		return "", false
	}
	info := State_e2eePeerKeyInfo(state, serverID, userID)
	peerKey := info.identityPublicKey
	if info.state == .KeyChanged {
		if !info.hasOfferedKey {
			return "", false
		}
		e2ee := &state.e2ee[State_e2eeServerIndex(state^, serverID)]
		user, _ := ServerE2EEState_findUser(e2ee, userID)
		peerKey = user.offered.identityPublicKey
	} else if !info.hasPin {
		return "", false
	}
	formatted := common.formatSafetyNumber(common.computeSafetyNumber(ownKey, peerKey))
	return strings.clone(string(formatted[:]), allocator), true
}

// The store holds only public keys, so there is nothing to wipe.
State_e2eeDeinit :: proc(state: ^State) {
	for index in 0 ..< len(state.e2ee) {
		ServerE2EEState_deinit(&state.e2ee[index])
	}
	delete(state.e2ee)
	state.e2ee = nil
	delete(state.keyStoreDir)
	state.keyStoreDir = ""
}
