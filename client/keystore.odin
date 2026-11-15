package client

import "../common"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// The per-server key store (e2ee-design.md 3.3): who this profile pinned on one server, and
// later (E2, E4) which conversations are encrypted and the room key material it holds.
//
// One file per server, keys/<server fingerprint>.json next to config.json (on Linux
// $XDG_CONFIG_HOME/haychat/keys/, on Windows %APPDATA%\haychat\keys\), mode 0600, written
// atomically (writeFileAtomically). The fingerprint is the server's pinned key's, so a server
// whose key changed and was trusted again gets a fresh store and its users are pinned again.
//
// Format 2, JSON (format 1 is the same without direct_conversations entries; a format 1 file
// loads as is and is written back as format 2, which an E1 build reads only read-only, so it
// never drops the flags):
//
//   {
//     "format": 2,
//     "server_public_key": "<hex identity key of the server>",
//     "users": [{"user_id": 2, "identity_public_key": "<hex>", "encryption_public_key": "<hex>",
//                "encryption_key_created_at": 1731600000, "verified": false,
//                "first_seen": 1731600000}],
//     "rooms": [],                 // reserved for E4: {"room_id": N, ...}
//     "direct_conversations": [{"peer_user_id": 2, "encrypted": true}]
//   }
//
// direct_conversations (E2, design 4.5) lists the peers with whom an encrypted message was
// sent or opened on this server. It only ever gains entries: once a conversation is encrypted
// the client never treats a plaintext message in it as normal (no silent downgrade).
//
// Pins are security state and are never overwritten silently: a file that does not parse, has
// an entry that does not validate, names another server, or has a newer format than this build
// knows is used read-only (KeyStore.writable false, KeyStore.loadError says why) and never
// written back, so a newer client's data and a damaged file both survive this build. A later
// package that adds data an older client would drop on rewrite bumps KEY_STORE_FORMAT.
//
// The GUI and the headless harness both write it (State.keyStoreDir); tests keep it in memory.

KEY_STORE_FORMAT :: 2
KEY_STORE_DIR_NAME :: "keys"

// One pinned account (design 3.4): first seen with these keys, verified by comparing safety
// numbers or not.
KeyPin :: struct {
	userID:              int,
	identityPublicKey:   common.IdentityPublicKeyBytes,
	encryptionPublicKey: common.EncryptionPublicKeyBytes,
	// The pinned bundle's createdAt; a bundle older than this is refused (no rollback).
	createdAt:           u64,
	verified:            bool,
	firstSeen:           i64, // Unix seconds
}

// The file's shape. Strings are hex; every value is owned while it is decoded.
KeyStoreFileUser :: struct {
	user_id:                   int,
	identity_public_key:       string,
	encryption_public_key:     string,
	encryption_key_created_at: u64,
	verified:                  bool,
	first_seen:                i64,
}

// Reserved for E4: the verified member log head and chain keys of a room.
KeyStoreFileRoom :: struct {
	room_id: int,
}

// Whether a direct conversation has been encrypted (no downgrade, design 4.5).
KeyStoreFileDirectConversation :: struct {
	peer_user_id: int,
	encrypted:    bool,
}

KeyStoreFile :: struct {
	format:               int,
	server_public_key:    string,
	users:                [dynamic]KeyStoreFileUser,
	rooms:                [dynamic]KeyStoreFileRoom,
	direct_conversations: [dynamic]KeyStoreFileDirectConversation,
}

KeyStoreFile_deinit :: proc(file: ^KeyStoreFile) {
	delete(file.server_public_key)
	for user in file.users {
		delete(user.identity_public_key)
		delete(user.encryption_public_key)
	}
	delete(file.users)
	delete(file.rooms)
	delete(file.direct_conversations)
	file^ = {}
}

// One server's key store in memory.
KeyStore :: struct {
	loaded:              bool,
	serverPublicKey:     common.IdentityPublicKeyBytes,
	// The file, or empty for a store that lives only in memory (tests, or no config dir).
	path:                string,
	// False when the file could not be used as is (see the top of this file); then it is never
	// written. loadError (owned) says why.
	writable:            bool,
	loadError:           string,
	pins:                [dynamic]KeyPin,
	rooms:               [dynamic]KeyStoreFileRoom,
	directConversations: [dynamic]KeyStoreFileDirectConversation,
}

KeyStore_deinit :: proc(store: ^KeyStore) {
	delete(store.path)
	delete(store.loadError)
	delete(store.pins)
	delete(store.rooms)
	delete(store.directConversations)
	store^ = {}
}

KeyStore_pinIndex :: proc(store: KeyStore, userID: int) -> int {
	for pin, index in store.pins {
		if pin.userID == userID {
			return index
		}
	}
	return -1
}

KeyStore_pin :: proc(store: ^KeyStore, userID: int) -> (^KeyPin, bool) {
	if index := KeyStore_pinIndex(store^, userID); index >= 0 {
		return &store.pins[index], true
	}
	return nil, false
}

// Adds or replaces userID's pin. Callers decide when a replacement is allowed (design 3.4);
// this only stores it.
KeyStore_setPin :: proc(store: ^KeyStore, pin: KeyPin) {
	if existing, ok := KeyStore_pin(store, pin.userID); ok {
		existing^ = pin
		return
	}
	append(&store.pins, pin)
}

// Whether an encrypted message was sent to or opened from peerUserID on this server.
KeyStore_conversationEncrypted :: proc(store: KeyStore, peerUserID: int) -> bool {
	for conversation in store.directConversations {
		if conversation.peer_user_id == peerUserID {
			return conversation.encrypted
		}
	}
	return false
}

// Marks the conversation with peerUserID encrypted. Returns true when that changed something
// (the caller saves the store then).
KeyStore_markConversationEncrypted :: proc(store: ^KeyStore, peerUserID: int) -> bool {
	if peerUserID <= 0 {
		return false
	}
	for &conversation in store.directConversations {
		if conversation.peer_user_id == peerUserID {
			if conversation.encrypted {
				return false
			}
			conversation.encrypted = true
			return true
		}
	}
	append(
		&store.directConversations,
		KeyStoreFileDirectConversation{peer_user_id = peerUserID, encrypted = true},
	)
	return true
}

// The key store file for a server fingerprint (64 hex characters) under dir, or "" when the
// fingerprint is not one, so nothing outside dir can be named.
keyStorePath :: proc(dir: string, fingerprint: string) -> string {
	if len(dir) == 0 || !keyStoreFingerprintIsValid(fingerprint) {
		return ""
	}
	when ODIN_OS == .Windows {
		return strings.concatenate({dir, "\\", fingerprint, ".json"})
	} else {
		return strings.concatenate({dir, "/", fingerprint, ".json"})
	}
}

keyStoreFingerprintIsValid :: proc(fingerprint: string) -> bool {
	if len(fingerprint) != 2 * common.FINGERPRINT_SIZE {
		return false
	}
	for character in transmute([]u8)fingerprint {
		isDigit := character >= '0' && character <= '9'
		isLower := character >= 'a' && character <= 'f'
		if !isDigit && !isLower {
			return false
		}
	}
	return true
}

// The key store directory next to config.json. The caller frees it.
keyStoreDefaultDir :: proc() -> string {
	configDir := getConfigDir()
	defer delete(configDir)
	if len(configDir) == 0 {
		return ""
	}
	when ODIN_OS == .Windows {
		return strings.concatenate({configDir, "\\", KEY_STORE_DIR_NAME})
	} else {
		return strings.concatenate({configDir, "/", KEY_STORE_DIR_NAME})
	}
}

// Parses a file's contents into a store for serverPublicKey. A problem makes the store
// read-only with loadError set; whatever validated is still used.
keyStoreParse :: proc(data: []u8, serverPublicKey: common.IdentityPublicKeyBytes) -> KeyStore {
	store := KeyStore {
		loaded          = true,
		serverPublicKey = serverPublicKey,
		writable        = true,
	}
	file: KeyStoreFile
	defer KeyStoreFile_deinit(&file)
	if json.unmarshal(data, &file) != nil {
		KeyStore_refuseWrites(&store, "the key store file is not valid JSON")
		return store
	}
	if file.format <= 0 || file.format > KEY_STORE_FORMAT {
		KeyStore_refuseWrites(
			&store,
			fmt.tprintf("the key store file has format %d; this build knows %d", file.format,
				KEY_STORE_FORMAT),
		)
		if file.format <= 0 {
			return store
		}
	}
	fileServerKey, serverKeyOK := common.identityPublicKeyFromHex(file.server_public_key)
	if !serverKeyOK || fileServerKey != serverPublicKey {
		KeyStore_refuseWrites(&store, "the key store file belongs to another server key")
		return store
	}
	for user in file.users {
		pin := KeyPin {
			userID    = user.user_id,
			createdAt = user.encryption_key_created_at,
			verified  = user.verified,
			firstSeen = user.first_seen,
		}
		identityOK := common.decodeHexIntoBuffer(user.identity_public_key, pin.identityPublicKey[:])
		encryptionOK := common.decodeHexIntoBuffer(
			user.encryption_public_key,
			pin.encryptionPublicKey[:],
		)
		if user.user_id <= 0 ||
		   !identityOK ||
		   !encryptionOK ||
		   KeyStore_pinIndex(store, user.user_id) >= 0 {
			KeyStore_refuseWrites(&store, "the key store file has an invalid user entry")
			continue
		}
		append(&store.pins, pin)
	}
	append(&store.rooms, ..file.rooms[:])
	for conversation in file.direct_conversations {
		if conversation.peer_user_id <= 0 {
			KeyStore_refuseWrites(&store, "the key store file has an invalid conversation entry")
			continue
		}
		if conversation.encrypted {
			KeyStore_markConversationEncrypted(&store, conversation.peer_user_id)
		}
	}
	return store
}

@(private = "file")
KeyStore_refuseWrites :: proc(store: ^KeyStore, reason: string) {
	store.writable = false
	if len(store.loadError) == 0 {
		store.loadError = strings.clone(reason)
	}
}

// Loads the store at path for serverPublicKey. A missing file is an empty, writable store;
// path "" is a store kept in memory only. Takes ownership of path.
keyStoreLoad :: proc(path: string, serverPublicKey: common.IdentityPublicKeyBytes) -> KeyStore {
	if len(path) == 0 || !os.exists(path) {
		return KeyStore {
			loaded = true,
			serverPublicKey = serverPublicKey,
			path = path,
			writable = true,
		}
	}
	data, readErr := os.read_entire_file_from_path(path, context.allocator)
	if readErr != nil {
		store := KeyStore {
			loaded          = true,
			serverPublicKey = serverPublicKey,
			path            = path,
		}
		KeyStore_refuseWrites(&store, "the key store file could not be read")
		return store
	}
	defer delete(data)
	store := keyStoreParse(data, serverPublicKey)
	store.path = path
	if !store.writable {
		fmt.printfln("[Warning] Key store %s is used read-only: %s", path, store.loadError)
	}
	return store
}

// The file's bytes for store. The caller frees them.
keyStoreEncode :: proc(store: KeyStore) -> ([]u8, bool) {
	serverKey := store.serverPublicKey
	file := KeyStoreFile {
		format               = KEY_STORE_FORMAT,
		server_public_key    = common.encodeBytesToHex(serverKey[:]),
		users                = make([dynamic]KeyStoreFileUser, 0, len(store.pins)),
		rooms                = make([dynamic]KeyStoreFileRoom, 0, len(store.rooms)),
		direct_conversations = make(
			[dynamic]KeyStoreFileDirectConversation,
			0,
			len(store.directConversations),
		),
	}
	defer KeyStoreFile_deinit(&file)
	for pin in store.pins {
		identity := pin.identityPublicKey
		encryption := pin.encryptionPublicKey
		append(
			&file.users,
			KeyStoreFileUser {
				user_id = pin.userID,
				identity_public_key = common.encodeBytesToHex(identity[:]),
				encryption_public_key = common.encodeBytesToHex(encryption[:]),
				encryption_key_created_at = pin.createdAt,
				verified = pin.verified,
				first_seen = pin.firstSeen,
			},
		)
	}
	append(&file.rooms, ..store.rooms[:])
	append(&file.direct_conversations, ..store.directConversations[:])
	data, err := json.marshal(file, {pretty = true})
	if err != nil {
		return nil, false
	}
	return data, true
}

// Writes the store to its file. A store kept in memory needs no write and returns true; a
// read-only one is never written and returns false with why.
KeyStore_save :: proc(store: ^KeyStore) -> (ok: bool, reason: string) {
	if len(store.path) == 0 {
		return true, ""
	}
	if !store.writable {
		return false, store.loadError
	}
	data, encodeOK := keyStoreEncode(store^)
	if !encodeOK {
		return false, "the key store could not be encoded"
	}
	defer delete(data)
	if !keyStoreEnsureDir(store.path) {
		return false, "the key store directory could not be created"
	}
	if err := writeFileAtomically(store.path, data); err != nil {
		fmt.println("[Error] Failed to write the key store:", err)
		return false, "the key store file could not be written"
	}
	return true, ""
}

// Creates the directory that holds path (mode 0700), if needed.
@(private = "file")
keyStoreEnsureDir :: proc(path: string) -> bool {
	separator := strings.last_index_any(path, "/\\")
	if separator <= 0 {
		return false
	}
	dir := path[:separator]
	if os.exists(dir) {
		return true
	}
	return os.make_directory(dir, os.perm(0o700)) == nil
}
