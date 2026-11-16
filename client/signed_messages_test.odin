package client

import "../common"
import crypto_hash "core:crypto/hash"
import "core:encoding/endian"
import "core:fmt"
import "core:strings"

// Every message must be signed by its sender (#82, #90): a client shows a room or direct message
// only when its signature verifies against the sender's pin (or this profile's own key). These
// helpers let tests deliver messages that verify, the way a real server would echo them.
//
// Each test user's identity key is derived from its user ID, so every test agrees on it.
// testMessageSigner gives the receiving State what it needs to check a signature on a server:
// a pinned server key (a fixed test key when the server has none), its own identity keys, and
// a pin of the sender's test identity (unless the sender is this profile, which signs with its
// own key). The key store lives in memory: tests have no keyStoreDir.

// The identity key pair a test user signs with.
testMessageIdentity :: proc(
	userID: int,
) -> (
	privateKey: common.IdentityPrivateKeyBytes,
	publicKey: common.IdentityPublicKeyBytes,
) {
	privateKey = testMessageLabelKey(fmt.tprintf("haychat-client-test-identity-%d", userID))
	ok: bool
	publicKey, ok = common.identityPublicKeyFromPrivateKey(privateKey)
	assert(ok, "expected a test identity key")
	return
}

// The fixed identity key of a test server that has none pinned.
testMessageServerIdentity :: proc() -> common.IdentityPublicKeyBytes {
	_, publicKey := testMessageIdentity(-1)
	return publicKey
}

@(private = "file")
testMessageLabelKey :: proc(label: string) -> common.IdentityPrivateKeyBytes {
	key: common.IdentityPrivateKeyBytes
	crypto_hash.hash_bytes_to_buffer(.SHA256, transmute([]u8)label, key[:])
	return key
}

// A client message ID that is set and unique per message ID (and per kind, 1 for direct and 2
// for room messages).
testMessageClientID :: proc(messageID: int, kind: u8) -> common.ClientMessageID {
	id: common.ClientMessageID
	endian.put_i64(id[:8], .Little, i64(messageID))
	id[15] = kind
	return id
}

// Prepares state on serverID to verify senderID's messages and returns the server key and the
// private key senderID signs with (this profile's own when senderID is its account).
testMessageSigner :: proc(
	state: ^State,
	serverID, senderID: int,
) -> (
	serverKey: common.IdentityPublicKeyBytes,
	senderPrivateKey: common.IdentityPrivateKeyBytes,
) {
	server, found := State_serverConfig(state, serverID)
	if !found {
		// A server the profile does not know: the message is dropped anyway.
		return
	}
	pinned, hasKey := common.identityPublicKeyFromHex(server.pinned_server_public_key)
	if hasKey {
		serverKey = pinned
	} else {
		serverKey = testMessageServerIdentity()
		delete(server.pinned_server_public_key)
		delete(server.pinned_server_fingerprint)
		server.pinned_server_public_key = common.identityPublicKeyToHex(serverKey)
		server.pinned_server_fingerprint = common.fingerprintToHex(
			common.fingerprintIdentityPublicKey(serverKey),
		)
		// The transport keeps its own copy; a mismatch would read as a changed server and
		// rebuild the session (settings.odin).
		for &transport in state.serverTransports {
			if transport.serverID == serverID {
				delete(transport.pinnedServerPublicKey)
				transport.pinnedServerPublicKey = strings.clone(server.pinned_server_public_key)
			}
		}
	}
	if len(state.config.public_key) == 0 || len(state.config.private_key) == 0 {
		ensureIdentityKeys(&state.config)
	}
	if senderID > 0 && senderID == State_selfUserID(state, serverID) {
		privateKey, ok := common.identityPrivateKeyFromHex(state.config.private_key)
		assert(ok, "expected this profile's identity key")
		return serverKey, privateKey
	}
	privateKey, publicKey := testMessageIdentity(senderID)
	e2ee, storeOK := State_e2eeEnsureStore(state, serverID)
	assert(storeOK && e2ee != nil, "expected a key store for the test server")
	if _, hasPin := KeyStore_pin(&e2ee.store, senderID); !hasPin {
		KeyStore_setPin(&e2ee.store, KeyPin{userID = senderID, identityPublicKey = publicKey})
	}
	return serverKey, privateKey
}

// Signs a plaintext direct message in place as its sender, setting a client message ID when it
// has none.
testSignDirectMessage :: proc(state: ^State, serverID: int, message: ^common.StoredDirectMessage) {
	serverKey, privateKey := testMessageSigner(state, serverID, message.senderId)
	if !common.clientMessageIDIsSet(message.clientMessageId) {
		message.clientMessageId = testMessageClientID(message.id, 1)
	}
	signature, ok := common.signPlaintextDirectMessage(
		common.PlaintextDirectMessageFields {
			serverIdentityPublicKey = serverKey,
			senderUserID = message.senderId,
			recipientUserID = message.recipientId,
			clientMessageID = message.clientMessageId,
		},
		message.content,
		privateKey,
	)
	assert(ok, "expected the test direct message to sign")
	message.signature = signature
}

// Signs a conversation summary's plaintext newest message in place as its sender.
testSignDirectPreview :: proc(
	state: ^State,
	serverID: int,
	summary: ^common.DirectConversationSummary,
) {
	recipientID := summary.peerUserId
	if summary.lastSenderId == summary.peerUserId {
		recipientID = State_selfUserID(state, serverID)
	}
	message := common.StoredDirectMessage {
		id              = summary.lastMessageID,
		senderId        = summary.lastSenderId,
		recipientId     = recipientID,
		content         = summary.lastContent,
		clientMessageId = summary.lastClientMessageId,
	}
	testSignDirectMessage(state, serverID, &message)
	summary.lastClientMessageId = message.clientMessageId
	summary.lastSignature = message.signature
}

// Signs a plaintext room message in place as its sender, setting a client message ID when it
// has none.
testSignRoomMessage :: proc(state: ^State, serverID: int, message: ^common.StoredChatMessage) {
	message.clientMessageId, message.signature = testRoomMessageSignature(
		state,
		serverID,
		message.roomId,
		message.senderId,
		message.id,
		message.content,
		message.clientMessageId,
	)
}

// The client message ID and signature of a plaintext room message from senderID.
testRoomMessageSignature :: proc(
	state: ^State,
	serverID, roomID, senderID, messageID: int,
	content: string,
	clientMessageID: common.ClientMessageID = {},
) -> (
	common.ClientMessageID,
	common.SignatureBytes,
) {
	serverKey, privateKey := testMessageSigner(state, serverID, senderID)
	id := clientMessageID
	if !common.clientMessageIDIsSet(id) {
		id = testMessageClientID(messageID, 2)
	}
	signature, ok := common.signPlaintextRoomMessage(
		common.PlaintextRoomMessageFields {
			serverIdentityPublicKey = serverKey,
			roomID = roomID,
			senderUserID = senderID,
			clientMessageID = id,
		},
		content,
		privateKey,
	)
	assert(ok, "expected the test room message to sign")
	return id, signature
}

// Signs this profile in on serverID as userID with a pinned server key, so it can sign what it
// sends (State_signRoomChat).
testPrepareRoomSend :: proc(state: ^State, serverID, userID: int) {
	testApplyConnected(state, serverID, userID)
	testMessageSigner(state, serverID, userID)
}

// Whether send carries this profile's valid signature for userID on serverID.
testRoomSendVerifies :: proc(state: ^State, serverID, userID: int, send: RoomChatSend) -> bool {
	serverKey, _ := testMessageSigner(state, serverID, userID)
	ownIdentity, ok := common.identityPublicKeyFromHex(state.config.public_key)
	return(
		ok &&
		common.verifyPlaintextRoomMessage(
			common.PlaintextRoomMessageFields {
				serverIdentityPublicKey = serverKey,
				roomID = send.roomID,
				senderUserID = userID,
				clientMessageID = send.clientMessageID,
			},
			send.content,
			ownIdentity,
			send.signature,
		) \
	)
}
