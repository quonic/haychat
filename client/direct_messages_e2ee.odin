package client

import "../common"
import "core:crypto"
import "core:strings"

// Encrypted direct messages on the client (protocol 17, e2ee-design.md 4.5, 4.6, 7.2-7.4).
//
// Rules:
//
// - Only pinned keys are used (e2ee_state.odin): a message is encrypted to the peer's pinned
//   encryption key and bound to both pinned identity keys; an incoming envelope or signed
//   plaintext is checked against the sender's pin (this profile's own key for its own
//   messages). A key the server sent is never used directly.
// - Sending: encrypt whenever State_e2eePeerKeyInfo.canEncrypt. While the peer's key is still
//   being fetched (blockReason Pending) a message waits in DirectConversationCache.queued
//   ("Setting up encryption…", design 7.2) and goes out when encryption becomes possible, or
//   back into the draft when it does not. Otherwise sending is refused unless the user turned
//   on the per-conversation "Send without encryption" switch (design 4.6), which sends a
//   signed plaintext message. A sent message still appears only through the server's echo.
// - No silent downgrade: a conversation is marked encrypted in the key store after the first
//   encrypted message sent or opened (KeyStore_markConversationEncrypted); plaintext then goes
//   out only through the switch, like in any other conversation that cannot be encrypted.
// - Receiving: every envelope and every signed plaintext message is opened or checked once,
//   with the keys of its pins. A message whose pin is not there yet waits (Pending) for the
//   fetch the client starts; every other failure is final, shown ("This message could not be
//   decrypted", "Unencrypted, sender not verified"), and never retried with other keys.
// - Plaintext of encrypted messages is never logged, and wiped from memory when it is freed.

DIRECT_SETTING_UP_TEXT :: "Setting up encryption…"
DIRECT_UNDECRYPTABLE_TEXT :: "This message could not be decrypted"
DIRECT_OPENING_TEXT :: "Opening encrypted message…"
DIRECT_FALLBACK_LABEL :: "Unencrypted: the server can read this"
DIRECT_FALLBACK_SEND_LABEL :: "Send unencrypted"
DIRECT_FALLBACK_SWITCH_LABEL :: "Send without encryption"
DIRECT_FALLBACK_CONFIRM_TEXT ::
	"Messages you send without encryption can be read by the server and its operator. They " +
	"are still signed, so nobody can change them or send them in your name. The switch turns " +
	"off when you close this conversation, restart HayChat, or encryption works again."

// The keys a batch of messages is opened with. Wipe it with DirectOpenKeys_wipe.
DirectOpenKeys :: struct {
	// The server's pinned key is known (it is part of every AAD) and this account is signed in.
	ready:                   bool,
	serverIdentityPublicKey: common.IdentityPublicKeyBytes,
	ownUserID:               int,
	ownIdentityPublicKey:    common.IdentityPublicKeyBytes,
	ownKeyPair:              common.EncryptionKeyPair,
	hasOwnKeyPair:           bool,
}

DirectOpenKeys_wipe :: proc(keys: ^DirectOpenKeys) {
	common.EncryptionKeyPair_wipe(&keys.ownKeyPair)
	keys^ = {}
}

State_directOpenKeys :: proc(state: ^State, serverID: int) -> (keys: DirectOpenKeys) {
	e2ee, storeOK := State_e2eeEnsureStore(state, serverID)
	selfUserID := State_selfUserID(state, serverID)
	ownIdentity, ownOK := common.identityPublicKeyFromHex(state.config.public_key)
	if !storeOK || e2ee == nil || selfUserID <= 0 || !ownOK {
		return
	}
	keys.ready = true
	keys.serverIdentityPublicKey = e2ee.store.serverPublicKey
	keys.ownUserID = selfUserID
	keys.ownIdentityPublicKey = ownIdentity
	keyPair, _, keyOK := Config_encryptionKey(state.config)
	keys.ownKeyPair = keyPair
	keys.hasOwnKeyPair = keyOK
	return
}

// The identity key a message from or to userID is checked against: this profile's own for
// itself, otherwise the pin. nil without a pin.
State_directIdentityFor :: proc(
	state: ^State,
	serverID: int,
	keys: DirectOpenKeys,
	userID: int,
) -> Maybe(common.IdentityPublicKeyBytes) {
	if userID <= 0 {
		return nil
	}
	if userID == keys.ownUserID {
		return keys.ownIdentityPublicKey
	}
	index := State_e2eeServerIndex(state^, serverID)
	if index < 0 {
		return nil
	}
	if pin, ok := KeyStore_pin(&state.e2ee[index].store, userID); ok {
		return pin.identityPublicKey
	}
	return nil
}

// Opens or checks one message (pure). content is owned (allocator): the opened plaintext of an
// envelope (empty unless Encrypted), or a copy of a plaintext message's content.
openDirectMessageContent :: proc(
	keys: DirectOpenKeys,
	senderIdentity, recipientIdentity: Maybe(common.IdentityPublicKeyBytes),
	message: common.StoredDirectMessage,
	allocator := context.allocator,
) -> (
	content: string,
	security: DirectMessageSecurity,
) {
	sender, hasSender := senderIdentity.?
	if len(message.envelope) > 0 {
		recipient, hasRecipient := recipientIdentity.?
		if !keys.ready || !hasSender || !hasRecipient {
			return "", {protection = .Pending}
		}
		if !keys.hasOwnKeyPair {
			return "", {protection = .Failed, failure = .OwnKey}
		}
		plaintext, err := common.openDirectMessage(
			message.envelope,
			common.DirectMessageAADFields {
				serverIdentityPublicKey = keys.serverIdentityPublicKey,
				senderUserID = message.senderId,
				recipientUserID = message.recipientId,
				senderIdentityPublicKey = sender,
				recipientIdentityPublicKey = recipient,
				clientMessageID = message.clientMessageId,
			},
			keys.ownUserID,
			keys.ownKeyPair,
			allocator,
		)
		if err != .None {
			return "", {protection = .Failed, failure = .Envelope, envelopeError = err}
		}
		return plaintext.content, {protection = .Encrypted}
	}
	content = strings.clone(message.content, allocator)
	if message.signature == {} {
		return content, {protection = .Plain}
	}
	if !keys.ready || !hasSender {
		return content, {protection = .Pending}
	}
	verified := common.verifyPlaintextDirectMessage(
		common.PlaintextDirectMessageFields {
			serverIdentityPublicKey = keys.serverIdentityPublicKey,
			senderUserID = message.senderId,
			recipientUserID = message.recipientId,
			clientMessageID = message.clientMessageId,
		},
		message.content,
		sender,
		message.signature,
	)
	return content, {protection = verified ? .Signed : .Unverified}
}

// A cache entry for a borrowed message, opened with keys.
State_openDirectEntry :: proc(
	state: ^State,
	serverID: int,
	keys: DirectOpenKeys,
	message: common.StoredDirectMessage,
) -> DirectMessageEntry {
	withoutContent := message
	withoutContent.content = ""
	entry := DirectMessageEntry {
		message = StoredDirectMessage_clone(withoutContent),
	}
	delete(entry.content)
	entry.content, entry.security = openDirectMessageContent(
		keys,
		State_directIdentityFor(state, serverID, keys, message.senderId),
		State_directIdentityFor(state, serverID, keys, message.recipientId),
		message,
	)
	return entry
}

// Opens a conversation entry's newest message in place: lastContent becomes its preview.
State_openDirectPreview :: proc(
	state: ^State,
	serverID: int,
	keys: DirectOpenKeys,
	entry: ^DirectConversationEntry,
) {
	selfUserID := keys.ownUserID
	recipientID := entry.peerUserId
	if entry.lastSenderId == entry.peerUserId {
		recipientID = selfUserID
	}
	message := common.StoredDirectMessage {
		id              = entry.lastMessageID,
		senderId        = entry.lastSenderId,
		recipientId     = recipientID,
		content         = entry.lastContent,
		clientMessageId = entry.lastClientMessageId,
		envelope        = entry.lastEnvelope,
		signature       = entry.lastSignature,
	}
	content, security := openDirectMessageContent(
		keys,
		State_directIdentityFor(state, serverID, keys, message.senderId),
		State_directIdentityFor(state, serverID, keys, message.recipientId),
		message,
	)
	wipeString(entry.lastContent)
	delete(entry.lastContent)
	entry.lastContent = content
	entry.security = security
}

// What follows from a message just opened: an encrypted one marks the conversation encrypted,
// one that waits for a key asks for it (or, when no key can come, is settled at once).
State_directEntryOpened :: proc(
	state: ^State,
	serverID, peerUserID: int,
	security: DirectMessageSecurity,
) {
	#partial switch security.protection {
	case .Encrypted:
		State_directMarkEncrypted(state, serverID, peerUserID)
	case .Pending:
		info := State_e2eePeerKeyInfo(state, serverID, peerUserID)
		if info.state == .Unknown {
			ids := [1]int{peerUserID}
			State_e2eeRequestUserKeys(state, serverID, ids[:])
		} else if !info.hasPin {
			State_directReopenPending(state, serverID)
		}
	}
}

// Whether the conversation with peerUserID was ever encrypted (the no-downgrade flag).
State_directConversationEncrypted :: proc(state: ^State, serverID, peerUserID: int) -> bool {
	index := State_e2eeServerIndex(state^, serverID)
	return index >= 0 && KeyStore_conversationEncrypted(state.e2ee[index].store, peerUserID)
}

State_directMarkEncrypted :: proc(state: ^State, serverID, peerUserID: int) {
	e2ee, ok := State_e2eeEnsureStore(state, serverID)
	if !ok || peerUserID == State_selfUserID(state, serverID) {
		return
	}
	if KeyStore_markConversationEncrypted(&e2ee.store, peerUserID) {
		State_e2eeSaveStore(state, e2ee)
	}
}

// Opens every message still waiting for a key (after keys arrived). A message whose key can
// no longer come (the server has none and none was ever pinned) is settled: an envelope
// cannot be opened, and a signed plaintext message cannot be checked.
State_directReopenPending :: proc(state: ^State, serverID: int) {
	cacheIndex := State_serverDirectCacheIndex(state^, serverID)
	if cacheIndex < 0 {
		return
	}
	keys := State_directOpenKeys(state, serverID)
	defer DirectOpenKeys_wipe(&keys)
	for conversationIndex in 0 ..< len(state.serverDirectCaches[cacheIndex].caches) {
		conversation := &state.serverDirectCaches[cacheIndex].caches[conversationIndex]
		peerUserID := conversation.peerUserID
		for entryIndex in 0 ..< len(conversation.messages) {
			entry := &conversation.messages[entryIndex]
			if entry.security.protection != .Pending {
				continue
			}
			content, security := openDirectMessageContent(
				keys,
				State_directIdentityFor(state, serverID, keys, entry.senderId),
				State_directIdentityFor(state, serverID, keys, entry.recipientId),
				entry.message,
			)
			if security.protection == .Pending &&
			   !State_directKeyMayArrive(state, serverID, peerUserID) {
				security = directSettleWithoutKey(entry.message)
				if security.protection == .Failed {
					wipeString(content)
					delete(content)
					content = ""
				}
			}
			if security.protection == .Pending {
				wipeString(content)
				delete(content)
				continue
			}
			wipeString(entry.content)
			delete(entry.content)
			entry.content = content
			entry.security = security
			DirectConversationCache_checkReplay(conversation, entryIndex)
			State_directNote(state, .Opened, serverID, peerUserID, entry.id)
			if security.protection == .Encrypted {
				State_directMarkEncrypted(state, serverID, peerUserID)
			}
		}
	}
	for &entry in state.serverDirectCaches[cacheIndex].conversations {
		if entry.security.protection != .Pending {
			continue
		}
		State_openDirectPreview(state, serverID, keys, &entry)
		if entry.security.protection == .Pending &&
		   !State_directKeyMayArrive(state, serverID, entry.peerUserId) {
			message := common.StoredDirectMessage {
				envelope  = entry.lastEnvelope,
				signature = entry.lastSignature,
			}
			entry.security = directSettleWithoutKey(message)
		}
		if entry.security.protection == .Encrypted {
			State_directMarkEncrypted(state, serverID, entry.peerUserId)
		}
	}
}

// What a message is when its sender's key can never be checked.
@(private = "file")
directSettleWithoutKey :: proc(message: common.StoredDirectMessage) -> DirectMessageSecurity {
	if len(message.envelope) > 0 {
		return {protection = .Failed, failure = .NoKey}
	}
	return {protection = .Unverified}
}

// Whether a pin for userID may still arrive: the client has none and has not heard from the
// server that there is no valid key.
State_directKeyMayArrive :: proc(state: ^State, serverID, userID: int) -> bool {
	info := State_e2eePeerKeyInfo(state, serverID, userID)
	return info.hasPin || info.state == .Unknown
}

// After the key state of any user on serverID changed (keys fetched or pushed, a key trusted,
// a new session): opens what waited for a key, sends or gives back queued messages, and turns
// the plaintext switch off wherever encryption works again.
State_directKeysChanged :: proc(state: ^State, serverID: int) {
	State_directReopenPending(state, serverID)
	State_directFlushQueued(state, serverID)
	// Encrypted rooms (room_log.odin): verified logs are checked against the new pins, and
	// changes and creates that waited for a key go out.
	State_roomLogsPinsChanged(state, serverID)
	cacheIndex := State_serverDirectCacheIndex(state^, serverID)
	if cacheIndex < 0 {
		return
	}
	for &conversation in state.serverDirectCaches[cacheIndex].caches {
		if !conversation.fallbackOn && !conversation.fallbackConfirmOpen {
			continue
		}
		if State_e2eePeerKeyInfo(state, serverID, conversation.peerUserID).canEncrypt {
			conversation.fallbackOn = false
			conversation.fallbackConfirmOpen = false
		}
	}
}

// ── Sending ───────────────────────────────────────────────────────

// How a message to a peer goes out now (pure).
DirectSendMode :: enum u8 {
	Encrypt,
	Queue, // The peer's key is still being fetched
	Plaintext, // Encryption is not possible and the user turned the switch on
	Blocked, // Encryption is not possible; the composer says why
}

directSendMode :: proc(info: E2EEPeerKeyInfo, fallbackOn: bool) -> DirectSendMode {
	if info.canEncrypt {
		return .Encrypt
	}
	if info.blockReason == .Pending {
		return .Queue
	}
	return fallbackOn ? .Plaintext : .Blocked
}

// Sends the draft of the conversation with peerUserID on serverID: encrypted when possible,
// queued while the peer's key is fetched, as a signed plaintext message only through the
// switch. The draft is cleared (and wiped) once the message went out or was queued; nothing
// is added to the transcript, which shows the message when the server echoes it.
State_sendDirectMessageTo :: proc(state: ^State, serverID, peerUserID: int) {
	if peerUserID <= 0 {
		State_setChatStatus(state, "No conversation selected")
		return
	}
	if peerUserID == State_selfUserID(state, serverID) {
		State_setChatStatus(state, "Cannot send a direct message to yourself")
		return
	}
	if State_selectedTransportIndexForServerID(state^, serverID) < 0 {
		State_setChatStatus(state, "No server transport selected")
		return
	}
	cache := State_serverDirectCache(state, serverID)
	conversation := ServerDirectCache_conversationCache(cache, peerUserID)
	content := normalizeTabs(string(conversation.draft[:]))
	defer {
		wipeString(content)
		delete(content)
	}
	if len(strings.trim_space(content)) == 0 {
		State_setChatStatus(state, "Cannot send an empty message")
		return
	}
	if len(content) > common.CHAT_MESSAGE_MAX_BYTES {
		State_setChatStatus(state, "Message is too long")
		return
	}

	info := State_e2eePeerKeyInfo(state, serverID, peerUserID)
	switch directSendMode(info, conversation.fallbackOn) {
	case .Queue:
		append(&conversation.queued, strings.clone(content))
		wipeBytes(conversation.draft[:])
		clear(&conversation.draft)
		State_clearChatStatus(state)
		ids := [1]int{peerUserID}
		State_e2eeRequestUserKeys(state, serverID, ids[:])
		State_directNote(state, .Queued, serverID, peerUserID, 0)
	case .Blocked:
		name := State_e2eeUserName(state, serverID, peerUserID)
		State_setChatStatus(state, e2eeKeyStateText(info, name))
	case .Encrypt, .Plaintext:
		sent, sendError := State_directSend(state, serverID, peerUserID, content, info)
		if !sent {
			State_setChatStatus(state, sendError)
			return
		}
		cache = State_serverDirectCache(state, serverID)
		conversation = ServerDirectCache_conversationCache(cache, peerUserID)
		wipeBytes(conversation.draft[:])
		clear(&conversation.draft)
		State_clearChatStatus(state)
	}
}

// Seals (canEncrypt) or signs content and sends it. sendError (temp) says why it failed.
State_directSend :: proc(
	state: ^State,
	serverID, peerUserID: int,
	content: string,
	info: E2EEPeerKeyInfo,
) -> (
	sent: bool,
	sendError: string,
) {
	transportIndex := State_selectedTransportIndexForServerID(state^, serverID)
	selfUserID := State_selfUserID(state, serverID)
	e2ee, storeOK := State_e2eeEnsureStore(state, serverID)
	if transportIndex < 0 || selfUserID <= 0 || !storeOK {
		return false, NOT_CONNECTED_MESSAGE
	}
	identityPrivateKey, privateOK := common.identityPrivateKeyFromHex(state.config.private_key)
	defer crypto.zero_explicit(&identityPrivateKey, size_of(identityPrivateKey))
	ownIdentity, publicOK := common.identityPublicKeyFromHex(state.config.public_key)
	if !privateOK || !publicOK {
		return false, "This profile has no valid identity key"
	}
	send := DirectMessageSend {
		recipientUserID = peerUserID,
	}
	if !common.generateRandomBytes(send.clientMessageID[:]) {
		return false, "Could not prepare the message"
	}
	envelope: [common.SEALED_ENVELOPE_MAX_BYTES]u8
	defer crypto.zero_explicit(&envelope, size_of(envelope))
	if info.canEncrypt {
		keyPair, _, keyOK := Config_encryptionKey(state.config)
		defer common.EncryptionKeyPair_wipe(&keyPair)
		if !keyOK {
			return false, "This profile has no valid encryption key"
		}
		n, err := common.sealDirectMessage(
			common.DirectMessageAADFields {
				serverIdentityPublicKey = e2ee.store.serverPublicKey,
				senderUserID = selfUserID,
				recipientUserID = peerUserID,
				senderIdentityPublicKey = ownIdentity,
				recipientIdentityPublicKey = info.identityPublicKey,
				clientMessageID = send.clientMessageID,
			},
			content,
			keyPair.publicKey,
			info.encryptionPublicKey,
			identityPrivateKey,
			envelope[:],
		)
		if err != .None {
			return false, "Could not encrypt the message"
		}
		send.envelope = envelope[:n]
	} else {
		signature, signOK := common.signPlaintextDirectMessage(
			common.PlaintextDirectMessageFields {
				serverIdentityPublicKey = e2ee.store.serverPublicKey,
				senderUserID = selfUserID,
				recipientUserID = peerUserID,
				clientMessageID = send.clientMessageID,
			},
			content,
			identityPrivateKey,
		)
		if !signOK {
			return false, "Could not sign the message"
		}
		send.content = content
		send.signature = signature
	}

	transport := &state.serverTransports[transportIndex]
	// The worker may replace lastError at any time, so copy it while holding the lock.
	ClientNetworkWorker_lock(state.networkWorker)
	sent = directMessageSendBridge(transport, send)
	if !sent {
		sendError = strings.clone(transport.lastError, context.temp_allocator)
	}
	ClientNetworkWorker_unlock(state.networkWorker)
	if !sent {
		if len(sendError) == 0 {
			sendError = "Failed to send direct message"
		}
		return false, sendError
	}
	if info.canEncrypt {
		State_directMarkEncrypted(state, serverID, peerUserID)
	}
	return true, ""
}

// Sends the queued messages of every conversation on serverID whose peer can now be encrypted
// to, in order; gives them back to the draft when encryption turned out not to be possible
// (never as plaintext: the switch applies only to messages sent with it on).
State_directFlushQueued :: proc(state: ^State, serverID: int) {
	cacheIndex := State_serverDirectCacheIndex(state^, serverID)
	if cacheIndex < 0 {
		return
	}
	for conversationIndex := 0;
	    conversationIndex < len(state.serverDirectCaches[cacheIndex].caches);
	    conversationIndex += 1 {
		conversation := &state.serverDirectCaches[cacheIndex].caches[conversationIndex]
		if len(conversation.queued) == 0 {
			continue
		}
		peerUserID := conversation.peerUserID
		info := State_e2eePeerKeyInfo(state, serverID, peerUserID)
		switch directSendMode(info, false) {
		case .Queue:
			continue
		case .Encrypt:
			sentCount := 0
			for sentCount < len(conversation.queued) {
				sent, sendError := State_directSend(
					state,
					serverID,
					peerUserID,
					conversation.queued[sentCount],
					info,
				)
				conversation = &state.serverDirectCaches[cacheIndex].caches[conversationIndex]
				if !sent {
					State_setChatStatus(state, sendError)
					break
				}
				sentCount += 1
			}
			for index in 0 ..< sentCount {
				wipeString(conversation.queued[index])
				delete(conversation.queued[index])
			}
			remove_range(&conversation.queued, 0, sentCount)
			State_directNote(state, .QueueSent, serverID, peerUserID, sentCount)
			if len(conversation.queued) > 0 {
				State_directRestoreQueued(conversation)
				State_directNote(state, .QueueRefused, serverID, peerUserID, 0)
			}
		case .Blocked, .Plaintext:
			State_directRestoreQueued(conversation)
			name := State_e2eeUserName(state, serverID, peerUserID)
			State_setChatStatus(state, e2eeKeyStateText(info, name))
			State_directNote(state, .QueueRefused, serverID, peerUserID, 0)
		}
	}
}

// Puts queued messages back in front of the draft, one per line, so nothing typed is lost.
State_directRestoreQueued :: proc(conversation: ^DirectConversationCache) {
	if len(conversation.queued) == 0 {
		return
	}
	restored := make([dynamic]u8, 0, len(conversation.draft) + 64)
	for text, index in conversation.queued {
		if index > 0 {
			append(&restored, '\n')
		}
		append(&restored, ..transmute([]u8)text)
		wipeString(text)
		delete(text)
	}
	clear(&conversation.queued)
	if len(conversation.draft) > 0 {
		append(&restored, '\n')
		append(&restored, ..conversation.draft[:])
	}
	wipeBytes(conversation.draft[:])
	delete(conversation.draft)
	conversation.draft = restored
}

// After a new session: queued messages wait for keys again (the fetch died with the session).
State_directRequestQueuedKeys :: proc(state: ^State, serverID: int) {
	cacheIndex := State_serverDirectCacheIndex(state^, serverID)
	if cacheIndex < 0 {
		return
	}
	peers := make([dynamic]int, 0, 4)
	defer delete(peers)
	for conversation in state.serverDirectCaches[cacheIndex].caches {
		if len(conversation.queued) > 0 {
			append(&peers, conversation.peerUserID)
		}
	}
	if len(peers) > 0 {
		State_e2eeRequestUserKeys(state, serverID, peers[:])
	}
	State_directKeysChanged(state, serverID)
}

// ── The plaintext fallback switch (design 4.6) ────────────────────

DirectFallbackResult :: enum u8 {
	Unavailable, // Encryption is possible, or not known yet: the switch is not offered
	NeedsConfirmation, // First time in this conversation: the confirmation is showing
	On,
	Off,
}

// Whether the switch is offered: only while encryption is not possible for a known reason.
directFallbackAvailable :: proc(info: E2EEPeerKeyInfo) -> bool {
	return !info.canEncrypt && info.blockReason != .Pending
}

// Turns the conversation's "Send without encryption" switch on or off. The first time in a
// conversation turning it on shows the confirmation instead.
State_setDirectFallback :: proc(
	state: ^State,
	serverID, peerUserID: int,
	on: bool,
) -> DirectFallbackResult {
	if peerUserID <= 0 || peerUserID == State_selfUserID(state, serverID) {
		return .Unavailable
	}
	conversation := ServerDirectCache_conversationCache(
		State_serverDirectCache(state, serverID),
		peerUserID,
	)
	if !on {
		conversation.fallbackOn = false
		conversation.fallbackConfirmOpen = false
		return .Off
	}
	if !directFallbackAvailable(State_e2eePeerKeyInfo(state, serverID, peerUserID)) {
		conversation.fallbackOn = false
		return .Unavailable
	}
	if !conversation.fallbackConfirmed {
		conversation.fallbackConfirmOpen = true
		return .NeedsConfirmation
	}
	conversation.fallbackOn = true
	return .On
}

// The confirmation's "Turn on": the switch goes on, and later times in this conversation (this
// run) need no confirmation.
State_confirmDirectFallback :: proc(state: ^State, serverID, peerUserID: int) -> bool {
	conversation := ServerDirectCache_conversationCache(
		State_serverDirectCache(state, serverID),
		peerUserID,
	)
	if !conversation.fallbackConfirmOpen ||
	   !directFallbackAvailable(State_e2eePeerKeyInfo(state, serverID, peerUserID)) {
		conversation.fallbackConfirmOpen = false
		return false
	}
	conversation.fallbackConfirmOpen = false
	conversation.fallbackConfirmed = true
	conversation.fallbackOn = true
	return true
}

State_cancelDirectFallback :: proc(state: ^State, serverID, peerUserID: int) {
	if index := State_serverDirectCacheIndex(state^, serverID); index >= 0 {
		cache := &state.serverDirectCaches[index]
		if conversationIndex := ServerDirectCache_conversationCacheIndex(cache^, peerUserID);
		   conversationIndex >= 0 {
			cache.caches[conversationIndex].fallbackConfirmOpen = false
		}
	}
}

// Closes the open conversation (selected_dm_peer_id back to 0): its plaintext switch turns off.
State_closeDirectConversation :: proc(state: ^State) {
	peerUserID := state.selected_dm_peer_id
	state.selected_dm_peer_id = 0
	if peerUserID == 0 {
		return
	}
	if index := State_serverDirectCacheIndex(state^, state.selected_server_id); index >= 0 {
		cache := &state.serverDirectCaches[index]
		if conversationIndex := ServerDirectCache_conversationCacheIndex(cache^, peerUserID);
		   conversationIndex >= 0 {
			cache.caches[conversationIndex].fallbackOn = false
			cache.caches[conversationIndex].fallbackConfirmOpen = false
		}
	}
}

// ── Notes for the headless harness ────────────────────────────────

// Changes that happen after the event that caused them (a message opened once its key arrived,
// queued messages sent or given back), recorded only while State.recordDirectNotes is set so
// the harness can print them. The GUI shows them through the view models instead.
DirectNoteKind :: enum u8 {
	Opened, // messageID was waiting for a key and is now opened or settled
	Queued, // A message was queued for the key
	QueueSent, // messageID holds how many queued messages went out
	QueueRefused, // Queued messages went back into the draft
}

DirectNote :: struct {
	kind:       DirectNoteKind,
	serverID:   int,
	peerUserID: int,
	messageID:  int,
}

State_directNote :: proc(
	state: ^State,
	kind: DirectNoteKind,
	serverID, peerUserID, messageID: int,
) {
	if state.recordDirectNotes {
		append(&state.directNotes, DirectNote{kind, serverID, peerUserID, messageID})
	}
}
