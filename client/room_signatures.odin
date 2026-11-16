package client

import "../common"
import "core:crypto"

// Signed plaintext room messages (protocol 22, #90). Every message in an unencrypted room is
// signed by its sender: State_signRoomChat signs what this profile sends, and
// State_roomCheckPlain checks every message that arrives against the sender's pinned identity
// key (this profile's own for itself), never a key the server sent. A message without a
// signature, with one that does not verify, or from a sender who has no key to check it with
// is Hidden: it is never shown, counted as unread, or printed with its content by the harness.
// One whose sender is not pinned yet waits (Pending, wait Sender) without showing its text
// while the sender's bundle is fetched, and is checked once it arrives
// (State_roomMessagesKeysChanged). Sealed messages in encrypted rooms (room_chains.odin)
// follow the same rule: one that fails at or before its signature check is Hidden.

// Whether a room message is shown at all.
roomMessageShown :: proc(security: RoomMessageSecurity) -> bool {
	return security.protection != .Hidden
}

// Whether the cached message messageID of roomID is shown (false when it is not cached).
State_roomMessageShown :: proc(state: ^State, serverID, roomID, messageID: int) -> bool {
	cacheIndex := State_serverRoomCacheIndex(state^, serverID)
	if cacheIndex < 0 {
		return false
	}
	cache := &state.server_room_caches[cacheIndex]
	roomIndex := ServerRoomCache_roomCacheIndex(cache^, roomID)
	if roomIndex < 0 {
		return false
	}
	for entry in cache.roomCaches[roomIndex].messages {
		if entry.id == messageID {
			return roomMessageShown(entry.security)
		}
	}
	return false
}

// Settles entry as not shown: its text is wiped and freed, and it is never opened again.
roomEntryHide :: proc(entry: ^RoomMessageEntry, security: RoomMessageSecurity) {
	wipeString(entry.content)
	delete(entry.content)
	entry.content = ""
	entry.security = security
	entry.security.protection = .Hidden
}

// What a plaintext message of an unencrypted room is (pure but for the key store): Plain when
// its sender's signature verifies, Pending (wait Sender) while the sender's key may still be
// pinned, Hidden otherwise. The caller hides a Hidden entry.
State_roomCheckPlain :: proc(
	state: ^State,
	serverID, roomID: int,
	keys: RoomChainKeys,
	entry: RoomMessageEntry,
) -> RoomMessageSecurity {
	if entry.signature == {} || !common.clientMessageIDIsSet(entry.clientMessageId) {
		return {protection = .Hidden, failure = .Unsigned}
	}
	if !keys.ready {
		return {protection = .Pending, wait = .Sender}
	}
	identity, hasIdentity := State_directIdentityFor(
		state,
		serverID,
		DirectOpenKeys {
			ownUserID = keys.ownUserID,
			ownIdentityPublicKey = keys.ownIdentityPublicKey,
		},
		entry.senderId,
	).?
	if !hasIdentity {
		if State_directKeyMayArrive(state, serverID, entry.senderId) {
			return {protection = .Pending, wait = .Sender}
		}
		return {protection = .Hidden, failure = .NoKey}
	}
	verified := common.verifyPlaintextRoomMessage(
		common.PlaintextRoomMessageFields {
			serverIdentityPublicKey = keys.serverIdentityPublicKey,
			roomID = roomID,
			senderUserID = entry.senderId,
			clientMessageID = entry.clientMessageId,
		},
		entry.content,
		identity,
		entry.signature,
	)
	if !verified {
		return {protection = .Hidden, failure = .BadSignature}
	}
	return {protection = .Plain}
}

// Keys of users on serverID changed (fetched, pushed, trusted, or reported missing): checks
// again every cached plaintext message that waited for its sender's key.
State_roomMessagesKeysChanged :: proc(state: ^State, serverID: int) {
	cacheIndex := State_serverRoomCacheIndex(state^, serverID)
	if cacheIndex < 0 {
		return
	}
	waiting := make([dynamic]int, 0, 4, context.temp_allocator)
	for roomCache in state.server_room_caches[cacheIndex].roomCaches {
		for entry in roomCache.messages {
			if entry.security.protection == .Pending && entry.security.wait == .Sender {
				append(&waiting, roomCache.roomID)
				break
			}
		}
	}
	for roomID in waiting {
		State_roomChainsReopenPending(state, serverID, roomID)
	}
}

// Signs content for roomID as this profile (protocol 22). errorMessage (static) says why it
// cannot be sent.
State_signRoomChat :: proc(
	state: ^State,
	serverID, roomID: int,
	content: string,
) -> (
	send: RoomChatSend,
	errorMessage: string,
) {
	if len(content) == 0 {
		return {}, "Cannot send an empty message"
	}
	if len(content) > common.CHAT_MESSAGE_MAX_BYTES {
		return {}, "Message is too long"
	}
	selfUserID := State_selfUserID(state, serverID)
	e2ee, storeOK := State_e2eeEnsureStore(state, serverID)
	if selfUserID <= 0 || !storeOK || e2ee == nil {
		return {}, NOT_CONNECTED_MESSAGE
	}
	identityPrivateKey, privateOK := common.identityPrivateKeyFromHex(state.config.private_key)
	defer crypto.zero_explicit(&identityPrivateKey, size_of(identityPrivateKey))
	if !privateOK {
		return {}, "This profile has no valid identity key"
	}
	send = RoomChatSend {
		roomID  = ClientServerTransport_runtimeRoomID(roomID),
		content = content,
	}
	if !common.generateRandomBytes(send.clientMessageID[:]) {
		return {}, "Could not prepare the message"
	}
	// A random ID of all zeros would read as none.
	send.clientMessageID[0] |= 1
	signature, signOK := common.signPlaintextRoomMessage(
		common.PlaintextRoomMessageFields {
			serverIdentityPublicKey = e2ee.store.serverPublicKey,
			roomID = send.roomID,
			senderUserID = selfUserID,
			clientMessageID = send.clientMessageID,
		},
		content,
		identityPrivateKey,
	)
	if !signOK {
		return {}, "Could not sign the message"
	}
	send.signature = signature
	return send, ""
}
