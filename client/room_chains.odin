package client

import "../common"
import "core:crypto"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

// Sender chains in encrypted rooms (protocol 19, e2ee-design.md 6.3-6.6, 7.2, 7.3): sealed room
// messages, the SenderKey distributions that carry each chain to the room's members, fetching
// them again, and key requests. Protocol 20 (design 6.6): Full history rooms forward older
// chains to new members as RoomKeyForward envelopes.
//
// Rules:
//
// - Only the verified member log (room_log.odin) decides who gets keys: a distribution is
//   sealed to every member of the current epoch as State_roomLogVerified shows them, each to
//   the encryption key the client pinned (E1, State_e2eePeerKeyInfo), the sender included. A
//   member whose key cannot be used gets no wrap and can ask for the chain later.
// - Sending: a chain is started lazily per room and epoch on the first send, distributed, and
//   used only once the server stored the distribution (its ServerRoomKeyEnvelope echo); until
//   then the message waits in RoomChainRoom.queued ("Setting up encryption…", design 7.2). A
//   chain ends with its epoch, after SENDER_CHAIN_MAX_MESSAGES messages or
//   SENDER_CHAIN_MAX_AGE (SenderChain_needsReplacement), and with the session that started it
//   when its distribution was not acknowledged.
// - A message index is never used twice: the sending side of a chain lives only in memory and
//   every run of the client starts new chains, so a crash, a restart, or a copy of the profile
//   running elsewhere can never seal two messages under one index (design 6.3, the E0 review).
//   The server refuses a reused (sender, chain, index) as well. Its start key is kept like any
//   received chain, so the sender reads its own messages after a restart.
// - "Room key is out of date": the epoch moved on at the server. The messages in flight go back
//   to the front of the queue, the log is fetched, and a new chain in the new epoch sends them
//   again. Every other refusal of a sealed message gives the text back to the draft.
// - Receiving: a distribution is opened only when the verified log shows its sender as a member
//   of its epoch, with the sender's pinned identity key (this profile's own for itself, else the
//   pin, else the identity the verified log names) and this profile's encryption key; its chain
//   key goes into the key store (a cache, format 4). A failure is dropped and never retried.
// - Opening a message: decode, the chain from the key store, the message key at its index,
//   the signature against the sender's pin, then the body. A missing chain waits ("Waiting for
//   this message's key from <sender>"): the client fetches its envelopes once per session and
//   then asks the sender (ClientRequestRoomKey). Every other failure is final, shown ("This
//   message could not be decrypted"), and never retried with other keys. A later message with
//   the same sender and client message ID, or the same chain index, is a replay.
// - From join rooms: a key request is answered only by the chain's sender, only for its own
//   chain, and only when the requester was a member of that epoch in the verified log, so
//   nobody gets a chain from before they joined. Forwards are never sent, and never accepted.
// - Full history rooms (the VERIFIED log's historyVisibility decides, never the server's
//   flag): the member who signs an Add forwards every chain it holds from before the addition
//   to the newcomer right after the Add verifies (State_roomChainsForwardHistory), one
//   envelope per chain; and any member answers a key request (the server relays it to every
//   member) for any chain it holds, when the requester is a current member of its verified log.
//   Its own chain goes as a SenderKey re-seal, anyone else's as a RoomKeyForward (one wrap, the
//   requester's pinned key, which must be the identity the log names). The server keeps the
//   first copy per chain and recipient. A forward is accepted only in a Full history room,
//   from a forwarder who was a member at the same time as this account, for a chain whose
//   sender was a member of its epoch, signed by the forwarder (its pin, else the log's
//   identity). Messages still verify against their real senders, so a forwarder can give
//   access but never forge. A chain no online member holds keeps waiting; the requests go out
//   again when a member of the room comes online.
// - Plaintext is never logged, and wiped from memory when it is freed.

ROOM_WAITING_FOR_KEY_FORMAT :: "Waiting for this message's key from %s"
ROOM_NOT_A_LOG_MEMBER_NOTE :: "You are not a member of this room's member list"
ROOM_NO_ENCRYPTION_KEY_NOTE :: "This profile has no valid encryption key"

// Every room message must be signed by its sender (#90): one whose signature was not verified
// against the sender's pin (or this profile's own key, or for a sealed message the identity
// the verified log names) is Hidden and never shown. Failed is shown ("This message could not
// be decrypted") only for a sealed message whose signature verified.
RoomMessageProtection :: enum u8 {
	Plain, // An unencrypted room's message, its signature verified (protocol 22)
	// Waiting for the log (wait Log), the chain's key (wait Key) or the sender's pin (wait
	// Sender); just merged and not looked at yet (wait None). Never shown with its content.
	Pending,
	Encrypted, // Opened and verified
	Failed, // Final, its signature verified: failure says why
	Hidden, // Final and not shown: failure says why
}

RoomMessageWait :: enum u8 {
	None,
	Log, // The verified log has not reached the message's epoch yet
	Key, // No chain key for it yet
	Sender, // A plaintext message whose sender's identity key is being fetched
}

RoomMessageFailure :: enum u8 {
	None,
	Sealed, // The sealed message did not decode, verify or open (sealedError)
	NotSealed, // Plaintext in an encrypted room
	NotMember, // The sender was not a member of the message's epoch
	BadIndex, // The index is before the chain's start or past its end
	LogFailed, // The room's member log failed verification
	Replayed, // A copy of an earlier message
	// Protocol 22: a plaintext message without a signature or client message ID, one whose
	// signature does not verify against the pin, and one whose sender has no key to check.
	Unsigned,
	BadSignature,
	NoKey,
}

RoomMessageSecurity :: struct {
	protection:  RoomMessageProtection,
	wait:        RoomMessageWait,
	failure:     RoomMessageFailure,
	sealedError: common.E2EEError,
	// The chain position, once decoded.
	header:      common.RoomMessageHeader,
}

// A cached room message: the stored message (content holds the opened text of a sealed one,
// wiped before it is freed) and what the client concluded about it.
RoomMessageEntry :: struct {
	using message: common.StoredChatMessage,
	security:      RoomMessageSecurity,
	// Protocol 27 (attachments.odin): the files the client checked, and whether a sealed
	// message's attachment list was changed on the server.
	files:         [dynamic]MessageFile,
	filesChanged:  bool,
	// Protocol 30 (message_edits.odin): the latest edit shown, the tombstone's verdict and the
	// cached edit list.
	edit:          MessageEditView,
}

RoomMessageEntry_deinit :: proc(entry: ^RoomMessageEntry) {
	if len(entry.sealed) > 0 {
		wipeString(entry.content)
	}
	common.StoredChatMessage_deinit(&entry.message)
	MessageFiles_deinit(&entry.files)
	MessageEditView_deinit(&entry.edit)
	entry^ = {}
}

// ── State ────────────────────────────────────────────────────────

RoomChainDistribution :: enum u8 {
	None, // Not sent for the current chain
	Sent, // Sent; the server's echo has not arrived
	Stored, // The server stored it: messages may use the chain
}

// A message waiting for the chain: its text (owned, wiped) and (protocol 27) the files it
// lists, sealed inside it (owned: names and media types; the file keys are wiped).
//
// #76 M2: an edit of message editMessageID (its client message ID editOriginal) waits in the
// same queue and takes the chain's next index like a message; it has no files. forge (a test
// hook for the live proof) spoils its seal so the server refuses it.
RoomChainQueued :: struct {
	content:       string,
	attachments:   [dynamic]common.SealedAttachment,
	editMessageID: int,
	editOriginal:  common.ClientMessageID,
	forge:         bool,
}

RoomChainQueued_deinit :: proc(item: ^RoomChainQueued) {
	wipeString(item.content)
	delete(item.content)
	sealedAttachments_deinit(&item.attachments)
	item^ = {}
}

// Owned copies of borrowed sealed entries (nil for none).
sealedAttachments_clone :: proc(
	entries: []common.SealedAttachment,
) -> [dynamic]common.SealedAttachment {
	if len(entries) == 0 {
		return nil
	}
	cloned := make([dynamic]common.SealedAttachment, 0, len(entries))
	for entry in entries {
		copied := entry
		copied.name = strings.clone(entry.name)
		copied.mediaType = strings.clone(entry.mediaType)
		append(&cloned, copied)
	}
	return cloned
}

sealedAttachments_deinit :: proc(entries: ^[dynamic]common.SealedAttachment) {
	for &entry in entries {
		crypto.zero_explicit(&entry.key, size_of(entry.key))
		delete(entry.name)
		delete(entry.mediaType)
	}
	delete(entries^)
	entries^ = nil
}

RoomChainInFlight :: struct {
	clientMessageID: common.ClientMessageID,
	using item:      RoomChainQueued,
}

RoomChainRef :: struct {
	epoch:        int,
	senderUserID: int,
	chainID:      common.ChainID,
}

// A chain to seal to one requester: an answer to a key request, or (Full history) one chain
// the inviter forwards to a newcomer. senderUserID is the chain's sender.
RoomChainAnswer :: struct {
	epoch:           int,
	senderUserID:    int,
	chainID:         common.ChainID,
	requesterUserID: int,
}

RoomChainRoom :: struct {
	roomID:           int,
	// The chain this session sends with (never stored, see the top of this file).
	sending:          common.SenderChain,
	hasSending:       bool,
	sendingEpoch:     int,
	distribution:     RoomChainDistribution,
	// Messages waiting for the chain (owned, wiped), oldest first, and the ones sent whose
	// echo has not arrived.
	queued:           [dynamic]RoomChainQueued,
	inFlight:         [dynamic]RoomChainInFlight,
	// This session's fetch of the room's envelopes, and the chains it asked senders for.
	keysFetching:     bool,
	keysFetched:      bool,
	requested:        [dynamic]RoomChainRef,
	// Envelopes that arrived before the verified log reached their epoch (owned).
	pendingEnvelopes: [dynamic]common.RoomKeyEnvelope,
	// Key requests waiting for the requester's key, and the ones answered this session.
	pendingAnswers:   [dynamic]RoomChainAnswer,
	answered:         [dynamic]RoomChainAnswer,
}

RoomChainRoom_dropSending :: proc(room: ^RoomChainRoom) {
	common.SenderChain_wipe(&room.sending)
	room.hasSending = false
	room.sendingEpoch = 0
	room.distribution = .None
}

RoomChainRoom_clearInFlight :: proc(room: ^RoomChainRoom) {
	for &entry in room.inFlight {
		RoomChainQueued_deinit(&entry.item)
	}
	clear(&room.inFlight)
}

RoomChainRoom_deinit :: proc(room: ^RoomChainRoom) {
	RoomChainRoom_dropSending(room)
	for &item in room.queued {
		RoomChainQueued_deinit(&item)
	}
	delete(room.queued)
	RoomChainRoom_clearInFlight(room)
	delete(room.inFlight)
	delete(room.requested)
	for &envelope in room.pendingEnvelopes {
		common.RoomKeyEnvelope_deinit(&envelope)
	}
	delete(room.pendingEnvelopes)
	delete(room.pendingAnswers)
	delete(room.answered)
	room^ = {}
}

ServerRoomChains :: struct {
	serverID: int,
	rooms:    [dynamic]RoomChainRoom,
}

ServerRoomChains_deinit :: proc(chains: ^ServerRoomChains) {
	for &room in chains.rooms {
		RoomChainRoom_deinit(&room)
	}
	delete(chains.rooms)
	chains^ = {}
}

State_roomChainsDeinit :: proc(state: ^State) {
	for &chains in state.roomChains {
		ServerRoomChains_deinit(&chains)
	}
	delete(state.roomChains)
	state.roomChains = nil
	delete(state.roomChainNotes)
	state.roomChainNotes = nil
}

State_removeServerRoomChains :: proc(state: ^State, serverID: int) {
	for index in 0 ..< len(state.roomChains) {
		if state.roomChains[index].serverID == serverID {
			ServerRoomChains_deinit(&state.roomChains[index])
			ordered_remove(&state.roomChains, index)
			return
		}
	}
}

@(private = "file")
State_findRoomChains :: proc(state: ^State, serverID, roomID: int) -> ^RoomChainRoom {
	for &chains in state.roomChains {
		if chains.serverID != serverID {
			continue
		}
		for &room in chains.rooms {
			if room.roomID == roomID {
				return &room
			}
		}
	}
	return nil
}

// The room's chain state, created when missing. Valid until the next room is added.
State_roomChainRoom :: proc(state: ^State, serverID, roomID: int) -> ^RoomChainRoom {
	if room := State_findRoomChains(state, serverID, roomID); room != nil {
		return room
	}
	for &chains in state.roomChains {
		if chains.serverID == serverID {
			append(&chains.rooms, RoomChainRoom{roomID = roomID})
			return &chains.rooms[len(chains.rooms) - 1]
		}
	}
	append(&state.roomChains, ServerRoomChains{serverID = serverID})
	chains := &state.roomChains[len(state.roomChains) - 1]
	append(&chains.rooms, RoomChainRoom{roomID = roomID})
	return &chains.rooms[0]
}

// ── Notes for the headless harness ────────────────────────────────

// Changes that happen after the event or command that caused them, recorded only while
// State.recordRoomChainNotes is set so the harness can print them.
RoomChainNoteKind :: enum u8 {
	Opened, // messageID waited and is now opened or settled
	Key, // An envelope was handled: outcome says how
	Answered, // A key request was answered (or refused: outcome)
	QueueSent, // count queued messages went out
	QueueRefused, // Queued messages went back into the draft (reason in the chat status)
}

RoomChainKeyOutcome :: enum u8 {
	Stored,
	Duplicate,
	NotForMe, // No wrap for this account
	Pending, // Waiting for the verified log to reach its epoch
	NotMember, // The sender was not a member of the epoch
	Failed, // Did not open (error)
	Refused, // A key request that is not answered
	// Protocol 20.
	NotAllowed, // A forward in a room without Full history, or from a forwarder who may not
	NotHeld, // A key request (Full history) for a chain this profile does not hold
}

RoomChainNote :: struct {
	kind:      RoomChainNoteKind,
	serverID:  int,
	roomID:    int,
	messageID: int,
	count:     int,
	ref:       RoomChainRef,
	peerID:    int, // Answered: the requester
	outcome:   RoomChainKeyOutcome,
	error:     common.E2EEError,
	// Key: the envelope's forwarder; Answered: this account when it forwarded (0: SenderKey).
	forwarderID: int,
}

@(private = "file")
State_roomChainNote :: proc(state: ^State, note: RoomChainNote) {
	if state.recordRoomChainNotes {
		append(&state.roomChainNotes, note)
	}
}

// ── Sending through the transport ─────────────────────────────────

RoomChainRequestKind :: enum u8 {
	SealedMessage,
	KeyEnvelope,
	FetchKeys,
	RequestKey,
	SealedEdit, // #76 M2: ClientEditRoomMessage with sealed bytes
}

RoomChainRequest :: struct {
	kind:            RoomChainRequestKind,
	roomID:          int,
	epoch:           int,
	// RequestKey: the chain's sender. KeyEnvelope: the chain's sender of a RoomKeyForward (0
	// for this account's own SenderKey envelope).
	senderUserID:    int,
	afterID:         int, // FetchKeys
	clientMessageID: common.ClientMessageID, // SealedMessage
	chainID:         common.ChainID, // KeyEnvelope, RequestKey
	bytes:           []u8, // SealedMessage, KeyEnvelope; borrowed for the call
	// SealedMessage (protocol 27): the outer list, blob IDs and stored sizes; borrowed.
	attachments:     []common.AttachmentRef,
	// SealedEdit (#76 M2): the edited message and its client message ID; clientMessageID is
	// the edit's own.
	messageID:       int,
	originalID:      common.ClientMessageID,
}

RoomChainSendBridge :: #type proc(
	transport: ^ClientServerTransport,
	request: RoomChainRequest,
) -> bool

// Tests swap it under roomChainSendBridgeTestMutex.
roomChainSendBridge: RoomChainSendBridge = ClientServerTransport_sendRoomChainRequest

ClientServerTransport_sendRoomChainRequest :: proc(
	transport: ^ClientServerTransport,
	request: RoomChainRequest,
) -> bool {
	switch request.kind {
	case .SealedMessage:
		return ClientServerTransport_sendEncryptedRuntimeMessage(
			transport,
			.ClientChatMessage,
			common.ClientChatMessagePayload {
				roomId = request.roomID,
				clientMessageId = request.clientMessageID,
				sealed = request.bytes,
				attachments = attachmentRefsPayload(request.attachments),
			},
		)
	case .SealedEdit:
		return ClientServerTransport_sendEncryptedRuntimeMessage(
			transport,
			.ClientEditRoomMessage,
			common.ClientEditRoomMessagePayload {
				roomId = request.roomID,
				messageId = request.messageID,
				originalClientMessageId = request.originalID,
				clientMessageId = request.clientMessageID,
				sealed = request.bytes,
			},
		)
	case .KeyEnvelope:
		return ClientServerTransport_sendEncryptedRuntimeMessage(
			transport,
			.ClientRoomKeyEnvelope,
			common.ClientRoomKeyEnvelopePayload {
				roomId = request.roomID,
				epoch = request.epoch,
				chainId = request.chainID,
				envelope = request.bytes,
				senderId = request.senderUserID,
			},
		)
	case .FetchKeys:
		return ClientServerTransport_sendEncryptedRuntimeMessage(
			transport,
			.ClientFetchRoomKeys,
			common.ClientFetchRoomKeysPayload {
				roomId = request.roomID,
				afterId = request.afterID,
			},
		)
	case .RequestKey:
		return ClientServerTransport_sendEncryptedRuntimeMessage(
			transport,
			.ClientRequestRoomKey,
			common.ClientRequestRoomKeyPayload {
				roomId = request.roomID,
				epoch = request.epoch,
				senderId = request.senderUserID,
				chainId = request.chainID,
			},
		)
	}
	return false
}

// Sends one request; "" when it went out, else why not (temp).
@(private = "file")
State_sendRoomChainRequest :: proc(
	state: ^State,
	serverID: int,
	request: RoomChainRequest,
) -> string {
	transportIndex := State_selectedTransportIndexForServerID(state^, serverID)
	if transportIndex < 0 {
		return "No server transport selected"
	}
	if !State_isServerConnected(state, serverID) {
		return NOT_CONNECTED_MESSAGE
	}
	transport := &state.serverTransports[transportIndex]
	ClientNetworkWorker_lock(state.networkWorker)
	sent := roomChainSendBridge(transport, request)
	sendError := sent ? "" : strings.clone(transport.lastError, context.temp_allocator)
	ClientNetworkWorker_unlock(state.networkWorker)
	if sent {
		return ""
	}
	if len(sendError) > 0 {
		return sendError
	}
	return "Failed to send the encrypted room request"
}

// ── Keys ─────────────────────────────────────────────────────────

// The keys messages and distributions are opened and sealed with. Wipe with RoomChainKeys_wipe.
RoomChainKeys :: struct {
	ready:                   bool, // The server key is pinned and this account is signed in
	serverIdentityPublicKey: common.IdentityPublicKeyBytes,
	ownUserID:               int,
	ownIdentityPublicKey:    common.IdentityPublicKeyBytes,
	ownKeyPair:              common.EncryptionKeyPair,
	hasOwnKeyPair:           bool,
}

RoomChainKeys_wipe :: proc(keys: ^RoomChainKeys) {
	common.EncryptionKeyPair_wipe(&keys.ownKeyPair)
	keys^ = {}
}

State_roomChainKeys :: proc(state: ^State, serverID: int) -> (keys: RoomChainKeys) {
	direct := State_directOpenKeys(state, serverID)
	keys = RoomChainKeys {
		ready                   = direct.ready,
		serverIdentityPublicKey = direct.serverIdentityPublicKey,
		ownUserID               = direct.ownUserID,
		ownIdentityPublicKey    = direct.ownIdentityPublicKey,
		ownKeyPair              = direct.ownKeyPair,
		hasOwnKeyPair           = direct.hasOwnKeyPair,
	}
	direct.ownKeyPair = {}
	DirectOpenKeys_wipe(&direct)
	return
}

// The identity key a room member's messages and distributions are checked against: this
// profile's own for itself, else the pin, else the key the verified log names for the user
// (an account that never published a bundle is held by the log's consistency, room_log.odin).
@(private = "file")
State_roomChainIdentityFor :: proc(
	state: ^State,
	serverID, roomID: int,
	keys: RoomChainKeys,
	userID: int,
) -> (
	common.IdentityPublicKeyBytes,
	bool,
) {
	if userID == keys.ownUserID {
		return keys.ownIdentityPublicKey, true
	}
	if identity, ok := State_directIdentityFor(
		state,
		serverID,
		DirectOpenKeys{ownUserID = keys.ownUserID},
		userID,
	).?; ok {
		return identity, true
	}
	if verified := State_roomLogVerified(state, serverID, roomID); verified != nil {
		if identity, ok := verified.identities[userID]; ok {
			return identity, true
		}
	}
	return {}, false
}

@(private = "file")
State_roomChainStore :: proc(state: ^State, serverID: int) -> ^KeyStore {
	e2ee, ok := State_e2eeEnsureStore(state, serverID)
	if !ok || e2ee == nil {
		return nil
	}
	return &e2ee.store
}

@(private = "file")
State_roomChainSaveStore :: proc(state: ^State, serverID: int) {
	if e2ee, ok := State_e2eeEnsureStore(state, serverID); ok && e2ee != nil {
		State_e2eeSaveStore(state, e2ee)
	}
}

// ── Opening messages ─────────────────────────────────────────────

// Opens or settles one cached message of roomID with keys. A sealed message that opens gets
// its text in entry.content; one that waits stays Pending with why.
State_roomOpenEntry :: proc(
	state: ^State,
	serverID, roomID: int,
	keys: RoomChainKeys,
	entry: ^RoomMessageEntry,
) {
	// Protocol 30 (D6, D7): a tombstone is shown as one whatever it held; nothing of it is
	// opened. Otherwise the latest edit is checked once the message itself is.
	if entry.deleted {
		entry.security = {protection = .Plain}
		if State_roomIsEncrypted(state, serverID, roomID) {
			entry.security = {protection = .Encrypted}
		}
		State_roomEntrySettleEdits(state, serverID, roomID, entry)
		return
	}
	State_roomOpenEntryContent(state, serverID, roomID, keys, entry)
	State_roomEntrySettleEdits(state, serverID, roomID, entry)
}

@(private = "file")
State_roomOpenEntryContent :: proc(
	state: ^State,
	serverID, roomID: int,
	keys: RoomChainKeys,
	entry: ^RoomMessageEntry,
) {
	encrypted := State_roomIsEncrypted(state, serverID, roomID)
	if len(entry.sealed) == 0 {
		if encrypted {
			// Only sealed messages are stored in an encrypted room; anything else is the server's.
			roomEntryHide(entry, {protection = .Hidden, failure = .NotSealed})
			return
		}
		entry.security = State_roomCheckPlain(state, serverID, roomID, keys, entry^)
		if entry.security.protection == .Hidden {
			roomEntryHide(entry, entry.security)
		} else if entry.security.protection == .Plain {
			// Protocol 27: the v2 signature covered every reference.
			MessageFiles_deinit(&entry.files)
			entry.files = messageFilesFromPlain(entry.attachments[:])
		}
		return
	}
	decoded, decodeErr := common.decodeSealedRoomMessage(entry.sealed)
	if decodeErr != .None {
		roomEntryHide(
			entry,
			{protection = .Hidden, failure = .Sealed, sealedError = decodeErr},
		)
		return
	}
	security := RoomMessageSecurity {
		header = decoded.header,
	}
	header := decoded.header
	log := State_findRoomLog(state, serverID, roomID)
	switch {
	case log != nil && log.status == .Failed:
		security.protection = .Failed
		security.failure = .LogFailed
	case !keys.ready || log == nil || log.status != .Verified || header.epoch > log.state.version:
		security.protection = .Pending
		security.wait = .Log
	case !roomLogMembershipsInclude(log.memberships[:], entry.senderId, header.epoch):
		security.protection = .Failed
		security.failure = .NotMember
	}
	if security.protection == .Failed {
		// Failed before the signature was checked: shown only when the sender signed it.
		State_roomSettleSealed(state, serverID, roomID, keys, entry, decoded, security)
		return
	}
	if security.protection != .Plain {
		entry.security = security
		return
	}
	senderIdentity, identityOK := State_roomChainIdentityFor(
		state,
		serverID,
		roomID,
		keys,
		entry.senderId,
	)
	store := State_roomChainStore(state, serverID)
	chain: ^KeyStoreRoomChain
	chainOK := false
	if store != nil {
		chain, chainOK = KeyStore_roomChain(
			store,
			roomID,
			header.epoch,
			entry.senderId,
			header.chainID,
		)
	}
	if !identityOK {
		// No identity to check the signature with: nobody is known to have sent it.
		roomEntryHide(entry, {protection = .Hidden, failure = .NoKey, header = header})
		return
	}
	// The signature needs no chain key: a message its sender did not sign is not shown, and
	// never waits for (or asks anyone for) a key.
	roomContext := common.RoomMessageContext {
		serverIdentityPublicKey = keys.serverIdentityPublicKey,
		roomID                  = roomID,
		senderUserID            = entry.senderId,
		clientMessageID         = entry.clientMessageId,
	}
	if verifyErr := common.verifyRoomMessageSignature(decoded, roomContext, senderIdentity);
	   verifyErr != .None {
		roomEntryHide(
			entry,
			{protection = .Hidden, failure = .Sealed, sealedError = verifyErr, header = header},
		)
		return
	}
	if !chainOK {
		entry.security = {protection = .Pending, wait = .Key, header = header}
		return
	}
	messageKey, indexOK := common.deriveSenderChainMessageKey(
		chain.chainKey,
		chain.startIndex,
		header.index,
	)
	defer crypto.zero_explicit(&messageKey, size_of(messageKey))
	if !indexOK {
		State_roomSettleSealed(
			state,
			serverID,
			roomID,
			keys,
			entry,
			decoded,
			{protection = .Failed, failure = .BadIndex, header = header},
		)
		return
	}
	buffer: [common.SEALED_ROOM_MESSAGE_MAX_BYTES]u8
	defer crypto.zero_explicit(&buffer, size_of(buffer))
	plaintext, openErr := common.openRoomMessage(
		decoded,
		roomContext,
		senderIdentity,
		messageKey,
		buffer[:],
	)
	if openErr != .None {
		// openRoomMessage checks the signature before the body: a failure at or before it is
		// not shown, one after it (the body or its padding) is.
		protection := RoomMessageProtection.Hidden
		#partial switch openErr {
		case .BadCiphertext, .BadPadding:
			protection = .Failed
		}
		entry.security = {
			protection  = protection,
			failure     = .Sealed,
			sealedError = openErr,
			header      = header,
		}
		if protection == .Hidden {
			roomEntryHide(entry, entry.security)
		}
		return
	}
	opened, plainErr := common.decodeSealedDirectMessagePlaintext(plaintext)
	if plainErr == .None && opened.hasReplaces {
		// #76 M2: an edit's plaintext presented as a new message (the server replaying an
		// edit under its own client message ID) is not a message.
		wipeString(opened.content)
		common.SealedDirectMessagePlaintext_deinit(&opened)
		plainErr = .BadPlaintext
	}
	if plainErr != .None {
		entry.security = {
			protection  = .Failed,
			failure     = .Sealed,
			sealedError = plainErr,
			header      = header,
		}
		return
	}
	delete(entry.content)
	entry.content = opened.content
	opened.content = ""
	// Protocol 27: the files inside the seal, checked against what the server bound.
	MessageFiles_deinit(&entry.files)
	entry.files, entry.filesChanged = messageFilesFromSealed(
		entry.attachments[:],
		opened.attachments[:],
	)
	common.SealedDirectMessagePlaintext_deinit(&opened)
	entry.security = {protection = .Encrypted, header = header}
}

// Opens a sealed room edit (#76 M2) like a new sealed message of the message's sender
// (check.senderUserID): the verified log must reach its epoch (Pending), the sender must have
// been a member of it, the seal must be signed by the sender's identity (check.senderIdentity:
// own key, pin or the verified log's) over the edit's client message ID before any key is
// looked for, then the chain key (Pending until it arrives), the index, the body and the
// plaintext's checks (messageEditCheckOpened). Every other failure is final.
State_roomSealedEditOpen :: proc(
	state: ^State,
	serverID: int,
	check: MessageChangeCheck,
	edit: common.MessageEdit,
) -> MessageEditVerdict {
	roomID := check.conversationID
	decoded, decodeErr := common.decodeSealedRoomMessage(edit.sealed)
	if decodeErr != .None {
		return {status = .Failed, failure = .Sealed, sealedError = decodeErr}
	}
	header := decoded.header
	keys := State_roomChainKeys(state, serverID)
	defer RoomChainKeys_wipe(&keys)
	log := State_findRoomLog(state, serverID, roomID)
	switch {
	case log != nil && log.status == .Failed:
		return {status = .Failed, failure = .LogFailed, header = header}
	case !keys.ready || log == nil || log.status != .Verified || header.epoch > log.state.version:
		return {status = .Pending, header = header}
	case !roomLogMembershipsInclude(log.memberships[:], check.senderUserID, header.epoch):
		return {status = .Failed, failure = .NotMember, header = header}
	}
	identity, hasIdentity := check.senderIdentity.?
	if !hasIdentity {
		if check.identityMayArrive {
			return {status = .Pending, header = header}
		}
		return {status = .Failed, failure = .NoKey, header = header}
	}
	roomContext := common.RoomMessageContext {
		serverIdentityPublicKey = keys.serverIdentityPublicKey,
		roomID                  = roomID,
		senderUserID            = check.senderUserID,
		clientMessageID         = edit.clientMessageId,
	}
	if verifyErr := common.verifyRoomMessageSignature(decoded, roomContext, identity);
	   verifyErr != .None {
		return {status = .Failed, failure = .Signature, sealedError = verifyErr, header = header}
	}
	store := State_roomChainStore(state, serverID)
	if store == nil {
		return {status = .Pending, header = header}
	}
	chain, chainOK := KeyStore_roomChain(
		store,
		roomID,
		header.epoch,
		check.senderUserID,
		header.chainID,
	)
	if !chainOK {
		return {status = .Pending, header = header}
	}
	messageKey, indexOK := common.deriveSenderChainMessageKey(
		chain.chainKey,
		chain.startIndex,
		header.index,
	)
	defer crypto.zero_explicit(&messageKey, size_of(messageKey))
	if !indexOK {
		return {status = .Failed, failure = .BadIndex, header = header}
	}
	buffer: [common.SEALED_ROOM_MESSAGE_MAX_BYTES]u8
	defer crypto.zero_explicit(&buffer, size_of(buffer))
	plaintext, openErr := common.openRoomMessage(
		decoded,
		roomContext,
		identity,
		messageKey,
		buffer[:],
	)
	if openErr != .None {
		return {status = .Failed, failure = .Sealed, sealedError = openErr, header = header}
	}
	opened, plainErr := common.decodeSealedDirectMessagePlaintext(plaintext)
	defer {
		wipeString(opened.content)
		common.SealedDirectMessagePlaintext_deinit(&opened)
	}
	if plainErr != .None {
		return {status = .Failed, failure = .Sealed, sealedError = plainErr, header = header}
	}
	verdict := messageEditCheckOpened(check, edit, &opened)
	verdict.header = header
	return verdict
}

// Marks the later of two opened messages from one sender with the same client message ID or
// the same chain index a replay (the server refuses both; this catches one that did not).
//
// Protocol 22: a verified plaintext message with the same sender and client message ID as an
// earlier one is a replay too (a server repeating a signed message).
RoomCache_checkReplay :: proc(cache: ^RoomCache, index: int) {
	entry := &cache.messages[index]
	if entry.security.protection != .Encrypted && entry.security.protection != .Plain {
		return
	}
	for &other, otherIndex in cache.messages {
		if otherIndex == index ||
		   other.security.protection != entry.security.protection ||
		   other.senderId != entry.senderId {
			continue
		}
		sameID := other.clientMessageId == entry.clientMessageId
		samePosition :=
			entry.security.protection == .Encrypted &&
			other.security.header.chainID == entry.security.header.chainID &&
			other.security.header.epoch == entry.security.header.epoch &&
			other.security.header.index == entry.security.header.index
		if !sameID && !samePosition {
			continue
		}
		later := entry
		if other.id > entry.id {
			later = &other
		}
		wipeString(later.content)
		delete(later.content)
		later.content = ""
		later.security.protection = .Failed
		later.security.failure = .Replayed
		return
	}
}

@(private = "file")
State_roomCache :: proc(state: ^State, serverID, roomID: int) -> ^RoomCache {
	cacheIndex := State_serverRoomCacheIndex(state^, serverID)
	if cacheIndex < 0 {
		return nil
	}
	cache := &state.server_room_caches[cacheIndex]
	roomIndex := ServerRoomCache_roomCacheIndex(cache^, roomID)
	if roomIndex < 0 {
		return nil
	}
	return &cache.roomCaches[roomIndex]
}

// Opens the cached message messageID of roomID (just merged) and follows up on it.
State_roomChainsOpenMessage :: proc(state: ^State, serverID, roomID, messageID: int) {
	cache := State_roomCache(state, serverID, roomID)
	if cache == nil {
		return
	}
	keys := State_roomChainKeys(state, serverID)
	defer RoomChainKeys_wipe(&keys)
	for index in 0 ..< len(cache.messages) {
		if cache.messages[index].id == messageID {
			State_roomOpenEntry(state, serverID, roomID, keys, &cache.messages[index])
			RoomCache_checkReplay(cache, index)
			break
		}
	}
	State_roomChainsFollowUp(state, serverID, roomID)
}

// Opens every cached message of roomID that has not been looked at (a history page just merged
// them as Pending with no reason).
State_roomChainsOpenNew :: proc(state: ^State, serverID, roomID: int) {
	cache := State_roomCache(state, serverID, roomID)
	if cache == nil {
		return
	}
	keys := State_roomChainKeys(state, serverID)
	defer RoomChainKeys_wipe(&keys)
	encrypted := State_roomIsEncrypted(state, serverID, roomID)
	for index in 0 ..< len(cache.messages) {
		entry := &cache.messages[index]
		unopened := entry.security.protection == .Pending && entry.security.wait == .None
		if unopened || (encrypted && entry.security.protection == .Plain) {
			State_roomOpenEntry(state, serverID, roomID, keys, entry)
			RoomCache_checkReplay(cache, index)
		}
	}
	State_roomChainsFollowUp(state, serverID, roomID)
}

// Opens again what waited in roomID (keys or the log arrived). Failures are never reopened.
State_roomChainsReopenPending :: proc(state: ^State, serverID, roomID: int) {
	cache := State_roomCache(state, serverID, roomID)
	if cache == nil {
		return
	}
	keys := State_roomChainKeys(state, serverID)
	defer RoomChainKeys_wipe(&keys)
	for index in 0 ..< len(cache.messages) {
		entry := &cache.messages[index]
		if entry.security.protection != .Pending {
			// #76 M2: an opened message's sealed edits that waited for a chain or the log.
			if !entry.deleted && messageEditViewHasPending(entry.edit) {
				State_roomEntrySettleEdits(state, serverID, roomID, entry)
			}
			continue
		}
		State_roomOpenEntry(state, serverID, roomID, keys, entry)
		RoomCache_checkReplay(cache, index)
		if entry.security.protection != .Pending {
			State_roomChainNote(
				state,
				{kind = .Opened, serverID = serverID, roomID = roomID, messageID = entry.id},
			)
		}
	}
	// What still waits: the log, the room's envelopes, or the senders.
	State_roomChainsFollowUp(state, serverID, roomID)
}

// The follow-up after a sealed edit was checked (#76 M2): what State_roomChainsFollowUp does
// for messages, for the edits that wait.
State_roomChainsEditsFollowUp :: proc(state: ^State, serverID, roomID: int) {
	if State_roomIsEncrypted(state, serverID, roomID) {
		State_roomChainsFollowUp(state, serverID, roomID)
	}
}

// What one opened message's pending sealed edits wait for (#76 M2): the log when it is behind
// an edit's epoch, the sender's pin, else the edit's chain (appended to chains).
@(private = "file")
State_roomChainsEditWaits :: proc(
	state: ^State,
	serverID, roomID: int,
	entry: RoomMessageEntry,
	waitsForLog, waitsForSender: ^bool,
	chains: ^[dynamic]RoomChainRef,
) {
	if entry.deleted || !messageEditViewHasPending(entry.edit) {
		return
	}
	log := State_findRoomLog(state, serverID, roomID)
	store := State_roomChainStore(state, serverID)
	consider := proc(
		edit: common.MessageEdit,
		entry: RoomMessageEntry,
		roomID: int,
		log: ^RoomLogRoom,
		store: ^KeyStore,
		waitsForLog, waitsForSender: ^bool,
		chains: ^[dynamic]RoomChainRef,
	) {
		decoded, err := common.decodeSealedRoomMessage(edit.sealed)
		if err != .None {
			return
		}
		header := decoded.header
		if log == nil || log.status != .Verified || header.epoch > log.state.version {
			waitsForLog^ = true
			return
		}
		if store == nil {
			return
		}
		_, held := KeyStore_roomChain(
			store,
			roomID,
			header.epoch,
			entry.senderId,
			header.chainID,
		)
		if held {
			// Held: what it waits for is the sender's pin.
			waitsForSender^ = true
			return
		}
		ref := RoomChainRef{header.epoch, entry.senderId, header.chainID}
		if !slice.contains(chains[:], ref) {
			append(chains, ref)
		}
	}
	if entry.edit.status == .Pending && len(entry.lastEdit.sealed) > 0 {
		consider(entry.lastEdit, entry, roomID, log, store, waitsForLog, waitsForSender, chains)
	}
	for edit, index in entry.edit.edits {
		status := entry.edit.editStatuses[index]
		if (status == .Pending || status == .None) && len(edit.sealed) > 0 {
			consider(edit, entry, roomID, log, store, waitsForLog, waitsForSender, chains)
		}
	}
}

// After messages were opened: fetch the log when it is behind them, the room's envelopes once
// per session when a chain is missing, and then ask the senders of the chains still missing.
// #76 M2: sealed edits that wait count too.
@(private = "file")
State_roomChainsFollowUp :: proc(state: ^State, serverID, roomID: int) {
	cache := State_roomCache(state, serverID, roomID)
	if cache == nil {
		return
	}
	waitsForLog, waitsForKey := false, false
	senders := make([dynamic]int, 0, 4, context.temp_allocator)
	editChains := make([dynamic]RoomChainRef, 0, 4, context.temp_allocator)
	for entry in cache.messages {
		editWaitsForSender := false
		State_roomChainsEditWaits(
			state,
			serverID,
			roomID,
			entry,
			&waitsForLog,
			&editWaitsForSender,
			&editChains,
		)
		if editWaitsForSender && !slice.contains(senders[:], entry.senderId) {
			append(&senders, entry.senderId)
		}
		if entry.security.protection != .Pending {
			continue
		}
		waitsForLog = waitsForLog || entry.security.wait == .Log
		waitsForKey = waitsForKey || entry.security.wait == .Key
		if entry.security.wait == .Sender && !slice.contains(senders[:], entry.senderId) {
			append(&senders, entry.senderId)
		}
	}
	waitsForKey = waitsForKey || len(editChains) > 0
	// Plaintext messages whose senders' identity keys are not pinned yet (protocol 22).
	if len(senders) > 0 {
		State_e2eeRequestUserKeys(state, serverID, senders[:])
	}
	if waitsForLog {
		State_requestRoomLog(state, serverID, roomID)
	}
	if !waitsForKey {
		return
	}
	room := State_roomChainRoom(state, serverID, roomID)
	if room.keysFetching {
		return
	}
	if !room.keysFetched {
		State_roomChainsFetchKeys(state, serverID, roomID, 0)
		return
	}
	for ref in editChains {
		State_roomChainsRequestKey(state, serverID, roomID, ref)
	}
	cache = State_roomCache(state, serverID, roomID)
	for entry in cache.messages {
		if entry.security.protection != .Pending || entry.security.wait != .Key {
			continue
		}
		State_roomChainsRequestKey(
			state,
			serverID,
			roomID,
			RoomChainRef {
				epoch = entry.security.header.epoch,
				senderUserID = entry.senderId,
				chainID = entry.security.header.chainID,
			},
		)
	}
}

// Fetches roomID's envelopes again from the start (the harness's `room-keys ROOM_ID fetch`).
// "" when the request went out, else why not (temp).
State_roomChainsFetchKeysNow :: proc(state: ^State, serverID, roomID: int) -> string {
	room := State_roomChainRoom(state, serverID, roomID)
	room.keysFetched = false
	errorMessage := State_sendRoomChainRequest(state, serverID, {kind = .FetchKeys, roomID = roomID})
	room = State_roomChainRoom(state, serverID, roomID)
	room.keysFetching = len(errorMessage) == 0
	return errorMessage
}

@(private = "file")
State_roomChainsFetchKeys :: proc(state: ^State, serverID, roomID, afterID: int) {
	room := State_roomChainRoom(state, serverID, roomID)
	errorMessage := State_sendRoomChainRequest(
		state,
		serverID,
		{kind = .FetchKeys, roomID = roomID, afterID = afterID},
	)
	room = State_roomChainRoom(state, serverID, roomID)
	room.keysFetching = len(errorMessage) == 0
}

// Asks ref's sender to re-seal its chain, once per session.
@(private = "file")
State_roomChainsRequestKey :: proc(state: ^State, serverID, roomID: int, ref: RoomChainRef) {
	if ref.senderUserID == State_selfUserID(state, serverID) {
		return
	}
	room := State_roomChainRoom(state, serverID, roomID)
	for requested in room.requested {
		if requested == ref {
			return
		}
	}
	errorMessage := State_sendRoomChainRequest(
		state,
		serverID,
		{
			kind = .RequestKey,
			roomID = roomID,
			epoch = ref.epoch,
			senderUserID = ref.senderUserID,
			chainID = ref.chainID,
		},
	)
	if len(errorMessage) == 0 {
		room = State_roomChainRoom(state, serverID, roomID)
		append(&room.requested, ref)
	}
}

// ── Receiving distributions ──────────────────────────────────────

// Handles one envelope: opens and keeps its chain, or says why not. Takes ownership of
// envelope when it waits for the log (Pending).
@(private = "file")
State_roomChainsTakeEnvelope :: proc(
	state: ^State,
	serverID: int,
	keys: RoomChainKeys,
	envelope: ^common.RoomKeyEnvelope,
) -> (
	outcome: RoomChainKeyOutcome,
	openErr: common.E2EEError,
) {
	roomID := envelope.roomId
	log := State_findRoomLog(state, serverID, roomID)
	if log != nil && log.status == .Failed {
		return .Failed, .None
	}
	if !keys.ready ||
	   log == nil ||
	   log.status != .Verified ||
	   envelope.epoch > log.state.version {
		room := State_roomChainRoom(state, serverID, roomID)
		append(&room.pendingEnvelopes, envelope^)
		envelope^ = {}
		State_requestRoomLog(state, serverID, roomID)
		return .Pending, .None
	}
	store := State_roomChainStore(state, serverID)
	if store == nil {
		return .Failed, .None
	}
	if _, found := KeyStore_roomChain(
		store,
		roomID,
		envelope.epoch,
		envelope.senderId,
		envelope.chainId,
	); found {
		return .Duplicate, .None
	}
	forward := envelope.forwarderId != 0
	if forward &&
	   (log.state.historyVisibility != .Full ||
			   envelope.forwarderId <= 0 ||
			   envelope.forwarderId == envelope.senderId ||
			   !roomLogMembershipsOverlap(
				   log.memberships[:],
				   envelope.forwarderId,
				   keys.ownUserID,
			   )) {
		// From join rooms never take forwards; in Full history rooms only from someone who was
		// a member while this account was.
		return .NotAllowed, .None
	}
	if !roomLogMembershipsInclude(log.memberships[:], envelope.senderId, envelope.epoch) {
		return .NotMember, .None
	}
	// Signed by the chain's sender, or (a forward) by the forwarder.
	signerID := forward ? envelope.forwarderId : envelope.senderId
	signerIdentity, identityOK := State_roomChainIdentityFor(
		state,
		serverID,
		roomID,
		keys,
		signerID,
	)
	if !identityOK {
		return .NotMember, .None
	}
	if !keys.hasOwnKeyPair {
		return .Failed, .NoWrapForRecipient
	}
	distribution: common.SenderKeyDistribution
	err: common.E2EEError
	if forward {
		distribution, err = common.openRoomKeyForward(
			envelope.envelope,
			common.RoomKeyForwardAADFields {
				serverIdentityPublicKey = keys.serverIdentityPublicKey,
				roomID = roomID,
				epoch = envelope.epoch,
				senderUserID = envelope.senderId,
				chainID = envelope.chainId,
				forwarderUserID = envelope.forwarderId,
				recipientUserID = keys.ownUserID,
			},
			signerIdentity,
			keys.ownKeyPair,
		)
	} else {
		distribution, err = common.openSenderKeyDistribution(
			envelope.envelope,
			common.RoomKeyAADFields {
				serverIdentityPublicKey = keys.serverIdentityPublicKey,
				roomID = roomID,
				epoch = envelope.epoch,
				senderUserID = envelope.senderId,
				chainID = envelope.chainId,
			},
			signerIdentity,
			keys.ownUserID,
			keys.ownKeyPair,
		)
	}
	defer crypto.zero_explicit(&distribution, size_of(distribution))
	if err == .NoWrapForRecipient {
		return .NotForMe, .None
	}
	if err != .None {
		return .Failed, err
	}
	chain := KeyStoreRoomChain {
		roomID       = roomID,
		epoch        = envelope.epoch,
		senderUserID = envelope.senderId,
		chainID      = envelope.chainId,
		startIndex   = distribution.startIndex,
		chainKey     = distribution.chainKey,
	}
	defer crypto.zero_explicit(&chain, size_of(chain))
	store = State_roomChainStore(state, serverID)
	if store == nil || !KeyStore_addRoomChain(store, chain) {
		return .Duplicate, .None
	}
	return .Stored, .None
}

// ServerRoomKeyEnvelope (live) or one page of ServerRoomKeys: takes the envelopes and clears
// the event's array. A page that says more follow fetches the next.
State_receiveRoomKeys :: proc(state: ^State, event: ^ClientTransportRuntimeEvent) {
	if State_selectedTransportIndexForServerID(state^, event.serverID) < 0 {
		return
	}
	serverID := event.serverID
	page := event.kind == .RoomKeysReceived
	State_roomChainsTakeEnvelopes(state, serverID, event.roomKeyEnvelopes[:])
	for &envelope in event.roomKeyEnvelopes {
		common.RoomKeyEnvelope_deinit(&envelope)
	}
	lastID := 0
	if len(event.roomKeyEnvelopes) > 0 {
		lastID = event.roomKeyEnvelopes[len(event.roomKeyEnvelopes) - 1].id
	}
	clear(&event.roomKeyEnvelopes)
	if !page {
		return
	}
	roomID := event.roomID
	room := State_roomChainRoom(state, serverID, roomID)
	room.keysFetching = false
	if event.hasOlder && lastID > 0 {
		State_roomChainsFetchKeys(state, serverID, roomID, lastID)
		return
	}
	room.keysFetched = true
	State_roomChainsFollowUp(state, serverID, roomID)
}

// Opens envelopes (borrowed; one that waits for the log is moved out) and follows up: the
// store is saved once, waiting messages reopen, and an acknowledged distribution of this
// session's own chain lets its queue go out.
@(private = "file")
State_roomChainsTakeEnvelopes :: proc(
	state: ^State,
	serverID: int,
	envelopes: []common.RoomKeyEnvelope,
) {
	keys := State_roomChainKeys(state, serverID)
	defer RoomChainKeys_wipe(&keys)
	stored := false
	rooms := make([dynamic]int, 0, 4, context.temp_allocator)
	for &envelope in envelopes {
		roomID := envelope.roomId
		ref := RoomChainRef{envelope.epoch, envelope.senderId, envelope.chainId}
		forwarderID := envelope.forwarderId
		if envelope.senderId == keys.ownUserID && forwarderID == 0 {
			// The server's echo of this session's distribution: the chain may be used.
			if room := State_findRoomChains(state, serverID, roomID);
			   room != nil &&
			   room.hasSending &&
			   room.distribution == .Sent &&
			   room.sendingEpoch == envelope.epoch &&
			   room.sending.chainID == envelope.chainId {
				room.distribution = .Stored
			}
		}
		outcome, openErr := State_roomChainsTakeEnvelope(state, serverID, keys, &envelope)
		stored = stored || outcome == .Stored
		State_roomChainNote(
			state,
			{
				kind = .Key,
				serverID = serverID,
				roomID = roomID,
				ref = ref,
				outcome = outcome,
				error = openErr,
				forwarderID = forwarderID,
			},
		)
		if !slice.contains(rooms[:], roomID) {
			append(&rooms, roomID)
		}
	}
	if stored {
		State_roomChainSaveStore(state, serverID)
	}
	for roomID in rooms {
		State_roomChainsReopenPending(state, serverID, roomID)
		State_roomChainsPump(state, serverID, roomID)
	}
}

// The verified log of roomID changed (or failed): envelopes and messages that waited for it
// are looked at again, and sends continue (a new epoch starts a new chain).
State_roomChainsLogChanged :: proc(state: ^State, serverID, roomID: int) {
	// Encrypted voice (protocol 21) follows the same verified log.
	defer State_voiceE2EELogChanged(state, serverID, roomID)
	room := State_findRoomChains(state, serverID, roomID)
	if room != nil && len(room.pendingEnvelopes) > 0 {
		waiting := room.pendingEnvelopes
		room.pendingEnvelopes = nil
		State_roomChainsTakeEnvelopes(state, serverID, waiting[:])
		for &envelope in waiting {
			common.RoomKeyEnvelope_deinit(&envelope)
		}
		delete(waiting)
	}
	State_roomChainsReopenPending(state, serverID, roomID)
	State_roomChainsAnswerPending(state, serverID, roomID)
	State_roomChainsPump(state, serverID, roomID)
}

// ── Answering key requests ───────────────────────────────────────

// ServerRoomKeyRequest: requesterUserID met a message of senderUserID's chain chainID in epoch
// without its key. From join rooms: re-sealed (to the requester only) when that chain is this
// account's and the verified log shows the requester as a member of that epoch. Full history
// rooms (protocol 20): any chain this profile holds, to a current member (State_roomChainsAnswer).
State_receiveRoomKeyRequest :: proc(
	state: ^State,
	serverID, roomID, epoch, senderUserID, requesterUserID: int,
	chainID: common.ChainID,
) {
	if State_selectedTransportIndexForServerID(state^, serverID) < 0 {
		return
	}
	State_roomChainsAnswer(
		state,
		serverID,
		roomID,
		RoomChainAnswer {
			epoch = epoch,
			senderUserID = senderUserID,
			chainID = chainID,
			requesterUserID = requesterUserID,
		},
	)
}

// Full history (design 6.6): this account signed the Add of newcomerUserID, which made
// joinedEpoch. Every chain this profile holds from before it is sealed to the newcomer, one
// envelope per chain (its own as SenderKey, the others as RoomKeyForward). Nothing happens in a
// From join room, or when the newcomer is no longer a member.
State_roomChainsForwardHistory :: proc(
	state: ^State,
	serverID, roomID, newcomerUserID, joinedEpoch: int,
) {
	log := State_findRoomLog(state, serverID, roomID)
	if log == nil ||
	   log.status != .Verified ||
	   log.state.historyVisibility != .Full ||
	   !common.RoomLogState_isMember(log.state, newcomerUserID) ||
	   newcomerUserID == State_selfUserID(state, serverID) {
		return
	}
	store := State_roomChainStore(state, serverID)
	if store == nil {
		return
	}
	refs := make([dynamic]RoomChainRef, 0, 8)
	defer delete(refs)
	for chain in store.roomChains {
		if chain.roomID == roomID && chain.epoch < joinedEpoch {
			append(&refs, RoomChainRef{chain.epoch, chain.senderUserID, chain.chainID})
		}
	}
	slice.sort_by(refs[:], proc(a, b: RoomChainRef) -> bool {
		if a.epoch != b.epoch {
			return a.epoch < b.epoch
		}
		return a.senderUserID < b.senderUserID
	})
	for ref in refs {
		State_roomChainsAnswer(
			state,
			serverID,
			roomID,
			RoomChainAnswer {
				epoch = ref.epoch,
				senderUserID = ref.senderUserID,
				chainID = ref.chainID,
				requesterUserID = newcomerUserID,
			},
		)
	}
}

// A member of serverID's Full history rooms came online (presence): the chains this session
// still waits for are asked for again, since that member may hold them.
State_roomChainsPeerOnline :: proc(state: ^State, serverID, userID: int) {
	if userID <= 0 || userID == State_selfUserID(state, serverID) {
		return
	}
	rooms := make([dynamic]int, 0, 4)
	defer delete(rooms)
	for &chains in state.roomChains {
		if chains.serverID != serverID {
			continue
		}
		for &room in chains.rooms {
			if len(room.requested) == 0 {
				continue
			}
			log := State_findRoomLog(state, serverID, room.roomID)
			if log == nil ||
			   log.status != .Verified ||
			   log.state.historyVisibility != .Full ||
			   !common.RoomLogState_isMember(log.state, userID) {
				continue
			}
			clear(&room.requested)
			append(&rooms, room.roomID)
		}
	}
	for roomID in rooms {
		State_roomChainsFollowUp(state, serverID, roomID)
	}
}

// Seals answer's chain to its requester, or records why not. See the top of this file for
// who may get what.
@(private = "file")
State_roomChainsAnswer :: proc(state: ^State, serverID, roomID: int, answer: RoomChainAnswer) {
	selfUserID := State_selfUserID(state, serverID)
	note := RoomChainNote {
		kind = .Answered,
		serverID = serverID,
		roomID = roomID,
		ref = {answer.epoch, answer.senderUserID, answer.chainID},
		peerID = answer.requesterUserID,
		outcome = .Refused,
	}
	room := State_roomChainRoom(state, serverID, roomID)
	for done in room.answered {
		if done == answer {
			return
		}
	}
	store := State_roomChainStore(state, serverID)
	log := State_findRoomLog(state, serverID, roomID)
	if store == nil ||
	   log == nil ||
	   log.status != .Verified ||
	   answer.requesterUserID == selfUserID ||
	   answer.senderUserID <= 0 {
		State_roomChainNote(state, note)
		return
	}
	own := answer.senderUserID == selfUserID
	allowed := false
	if log.state.historyVisibility == .Full {
		// Any chain whose sender was a member of its epoch, to any current member.
		allowed =
			common.RoomLogState_isMember(log.state, answer.requesterUserID) &&
			roomLogMembershipsInclude(log.memberships[:], answer.senderUserID, answer.epoch)
	} else {
		// From join: only this account's own chain, to a member of that epoch.
		allowed =
			own &&
			roomLogMembershipsInclude(log.memberships[:], answer.requesterUserID, answer.epoch)
	}
	if !allowed {
		State_roomChainNote(state, note)
		return
	}
	held, found := KeyStore_roomChain(
		store,
		roomID,
		answer.epoch,
		answer.senderUserID,
		answer.chainID,
	)
	if !found {
		note.outcome = .NotHeld
		State_roomChainNote(state, note)
		return
	}
	startIndex := held.startIndex
	chainKey := held.chainKey
	defer crypto.zero_explicit(&chainKey, size_of(chainKey))
	info := State_e2eePeerKeyInfo(state, serverID, answer.requesterUserID)
	if !info.canEncrypt {
		if info.blockReason == .Pending {
			ids := [1]int{answer.requesterUserID}
			State_e2eeRequestUserKeys(state, serverID, ids[:])
			room = State_roomChainRoom(state, serverID, roomID)
			append(&room.pendingAnswers, answer)
			return
		}
		State_roomChainNote(state, note)
		return
	}
	// The pin must be the identity the verified log names for the requester.
	log = State_findRoomLog(state, serverID, roomID)
	if logIdentity, named := log.state.identities[answer.requesterUserID];
	   !named || logIdentity != info.identityPublicKey {
		State_roomChainNote(state, note)
		return
	}
	identityPrivateKey, privateOK := common.identityPrivateKeyFromHex(state.config.private_key)
	defer crypto.zero_explicit(&identityPrivateKey, size_of(identityPrivateKey))
	e2ee, storeOK := State_e2eeEnsureStore(state, serverID)
	if !privateOK || !storeOK {
		State_roomChainNote(state, note)
		return
	}
	buffer: [common.SEALED_ENVELOPE_MAX_BYTES]u8
	n: int
	err: common.E2EEError
	if own {
		recipients := [1]common.EnvelopeRecipient {
			{answer.requesterUserID, info.encryptionPublicKey},
		}
		n, err = common.sealSenderKeyDistribution(
			common.RoomKeyAADFields {
				serverIdentityPublicKey = e2ee.store.serverPublicKey,
				roomID = roomID,
				epoch = answer.epoch,
				senderUserID = selfUserID,
				chainID = answer.chainID,
			},
			startIndex,
			chainKey,
			recipients[:],
			identityPrivateKey,
			buffer[:],
		)
	} else {
		n, err = common.sealRoomKeyForward(
			common.RoomKeyForwardAADFields {
				serverIdentityPublicKey = e2ee.store.serverPublicKey,
				roomID = roomID,
				epoch = answer.epoch,
				senderUserID = answer.senderUserID,
				chainID = answer.chainID,
				forwarderUserID = selfUserID,
				recipientUserID = answer.requesterUserID,
			},
			startIndex,
			chainKey,
			info.encryptionPublicKey,
			identityPrivateKey,
			buffer[:],
		)
		note.forwarderID = selfUserID
	}
	defer crypto.zero_explicit(&buffer, size_of(buffer))
	if err != .None {
		note.error = err
		State_roomChainNote(state, note)
		return
	}
	sendError := State_sendRoomChainRequest(
		state,
		serverID,
		{
			kind = .KeyEnvelope,
			roomID = roomID,
			epoch = answer.epoch,
			senderUserID = own ? 0 : answer.senderUserID,
			chainID = answer.chainID,
			bytes = buffer[:n],
		},
	)
	if len(sendError) > 0 {
		State_roomChainNote(state, note)
		return
	}
	room = State_roomChainRoom(state, serverID, roomID)
	append(&room.answered, answer)
	note.outcome = .Stored
	State_roomChainNote(state, note)
}

// Requests that waited for a requester's key (after keys arrived, or the log changed).
@(private = "file")
State_roomChainsAnswerPending :: proc(state: ^State, serverID, roomID: int) {
	room := State_findRoomChains(state, serverID, roomID)
	if room == nil || len(room.pendingAnswers) == 0 {
		return
	}
	waiting := room.pendingAnswers
	room.pendingAnswers = nil
	defer delete(waiting)
	for answer in waiting {
		if State_e2eePeerKeyInfo(state, serverID, answer.requesterUserID).blockReason ==
		   .Pending {
			room = State_roomChainRoom(state, serverID, roomID)
			append(&room.pendingAnswers, answer)
			continue
		}
		State_roomChainsAnswer(state, serverID, roomID, answer)
	}
}

// ── Sending ──────────────────────────────────────────────────────

// Why roomID's composer cannot send, or "" when it can (now or once encryption is set up).
State_roomChainsComposerNote :: proc(state: ^State, serverID, roomID: int) -> string {
	log := State_findRoomLog(state, serverID, roomID)
	if log == nil {
		return ""
	}
	switch log.status {
	case .Failed:
		return ROOM_LOG_CHANGED_WARNING
	case .Unknown, .Loading:
		return ""
	case .Verified:
	}
	if log.state.version == 0 {
		return ROOM_LOG_NOT_SET_UP_NOTE
	}
	if !common.RoomLogState_isMember(log.state, State_selfUserID(state, serverID)) {
		return ROOM_NOT_A_LOG_MEMBER_NOTE
	}
	return ""
}

// Queues content (borrowed) for roomID and sends what can go. Returns whether it is queued
// (waiting for the chain) rather than sent already. The text is cleared from the caller's
// draft by the caller once this returns true for ok. attachments (protocol 27, borrowed) are
// the sealed entries of the files it lists (State_attachmentsForMessage).
State_roomChainsSend :: proc(
	state: ^State,
	serverID, roomID: int,
	content: string,
	attachments: []common.SealedAttachment = nil,
) -> (
	ok: bool,
	queued: bool,
	errorMessage: string,
) {
	if note := State_roomChainsComposerNote(state, serverID, roomID); len(note) > 0 {
		return false, false, note
	}
	room := State_roomChainRoom(state, serverID, roomID)
	append(
		&room.queued,
		RoomChainQueued {
			content = strings.clone(content),
			attachments = sealedAttachments_clone(attachments),
		},
	)
	State_roomChainsPump(state, serverID, roomID)
	room = State_roomChainRoom(state, serverID, roomID)
	queued = len(room.queued) > 0
	if queued {
		State_setChatStatus(state, DIRECT_SETTING_UP_TEXT)
	}
	return true, queued, ""
}

// Queues an edit of messageID (its client message ID original) to content (borrowed) for
// roomID (#76 M2) and sends what can go: the edit takes the next index of this session's
// current chain, which is started and distributed first when needed, exactly as for a new
// message. "" when it is queued or sent, else why not (static).
State_roomChainsSendEdit :: proc(
	state: ^State,
	serverID, roomID, messageID: int,
	original: common.ClientMessageID,
	content: string,
	forge := false,
) -> string {
	if note := State_roomChainsComposerNote(state, serverID, roomID); len(note) > 0 {
		return note
	}
	room := State_roomChainRoom(state, serverID, roomID)
	append(
		&room.queued,
		RoomChainQueued {
			content = strings.clone(content),
			editMessageID = messageID,
			editOriginal = original,
			forge = forge,
		},
	)
	State_roomChainsPump(state, serverID, roomID)
	if room = State_roomChainRoom(state, serverID, roomID); len(room.queued) > 0 {
		State_setChatStatus(state, DIRECT_SETTING_UP_TEXT)
	}
	return ""
}

// Moves what is queued for roomID along: starts and distributes a chain when needed, sends the
// queue once the distribution is stored, and gives the queue back to the draft when sending is
// not possible at all.
State_roomChainsPump :: proc(state: ^State, serverID, roomID: int) {
	room := State_findRoomChains(state, serverID, roomID)
	if room == nil || len(room.queued) == 0 || !State_isServerConnected(state, serverID) {
		return
	}
	log := State_findRoomLog(state, serverID, roomID)
	if log == nil || log.status == .Unknown {
		State_requestRoomLog(state, serverID, roomID)
		return
	}
	if log.status == .Loading {
		return
	}
	if note := State_roomChainsComposerNote(state, serverID, roomID); len(note) > 0 {
		State_roomChainsRefuseQueue(state, serverID, roomID, note)
		return
	}
	epoch := log.state.version
	now := time.time_to_unix(time.now())
	room = State_findRoomChains(state, serverID, roomID)
	if room.hasSending &&
	   (room.sendingEpoch != epoch || common.SenderChain_needsReplacement(room.sending, now)) {
		RoomChainRoom_dropSending(room)
	}
	if !room.hasSending {
		if errorMessage := State_roomChainsStartChain(state, serverID, roomID, epoch, now);
		   len(errorMessage) > 0 {
			State_roomChainsRefuseQueue(state, serverID, roomID, errorMessage)
			return
		}
		room = State_findRoomChains(state, serverID, roomID)
	}
	switch room.distribution {
	case .None:
		State_roomChainsDistribute(state, serverID, roomID)
		return
	case .Sent:
		return
	case .Stored:
	}
	State_roomChainsSendQueued(state, serverID, roomID, now)
}

// A new chain for this session in epoch; its start key is kept like a received chain so this
// profile reads its own messages later.
@(private = "file")
State_roomChainsStartChain :: proc(state: ^State, serverID, roomID, epoch: int, now: i64) -> string {
	chain, ok := common.SenderChain_create(now)
	if !ok {
		return "Could not prepare encryption"
	}
	defer common.SenderChain_wipe(&chain)
	store := State_roomChainStore(state, serverID)
	selfUserID := State_selfUserID(state, serverID)
	if store == nil || selfUserID <= 0 {
		return NOT_CONNECTED_MESSAGE
	}
	kept := KeyStoreRoomChain {
		roomID       = roomID,
		epoch        = epoch,
		senderUserID = selfUserID,
		chainID      = chain.chainID,
		chainKey     = chain.startKey,
	}
	defer crypto.zero_explicit(&kept, size_of(kept))
	if KeyStore_addRoomChain(store, kept) {
		State_roomChainSaveStore(state, serverID)
	}
	room := State_roomChainRoom(state, serverID, roomID)
	room.sending = chain
	room.hasSending = true
	room.sendingEpoch = epoch
	room.distribution = .None
	return ""
}

// Seals the current chain to every member of its epoch the verified log shows, each to the
// pinned encryption key, and sends it. Members whose key is still being fetched hold it back.
@(private = "file")
State_roomChainsDistribute :: proc(state: ^State, serverID, roomID: int) {
	verified := State_roomLogVerified(state, serverID, roomID)
	room := State_findRoomChains(state, serverID, roomID)
	if verified == nil || room == nil || !room.hasSending {
		return
	}
	selfUserID := State_selfUserID(state, serverID)
	keyPair, _, keyOK := Config_encryptionKey(state.config)
	defer common.EncryptionKeyPair_wipe(&keyPair)
	identityPrivateKey, privateOK := common.identityPrivateKeyFromHex(state.config.private_key)
	defer crypto.zero_explicit(&identityPrivateKey, size_of(identityPrivateKey))
	e2ee, storeOK := State_e2eeEnsureStore(state, serverID)
	if !keyOK || !privateOK || !storeOK {
		State_roomChainsRefuseQueue(state, serverID, roomID, ROOM_NO_ENCRYPTION_KEY_NOTE)
		return
	}
	members := make([dynamic]int, 0, len(verified.members), context.temp_allocator)
	for userID in verified.members {
		append(&members, userID)
	}
	slice.sort(members[:])
	recipients := make([dynamic]common.EnvelopeRecipient, 0, len(members))
	defer delete(recipients)
	fetch := make([dynamic]int, 0, 4, context.temp_allocator)
	for userID in members {
		if userID == selfUserID {
			append(&recipients, common.EnvelopeRecipient{userID, keyPair.publicKey})
			continue
		}
		info := State_e2eePeerKeyInfo(state, serverID, userID)
		if info.canEncrypt && info.identityPublicKey == verified.members[userID] {
			append(&recipients, common.EnvelopeRecipient{userID, info.encryptionPublicKey})
		} else if info.blockReason == .Pending {
			append(&fetch, userID)
		}
		// Anyone else (no key, a changed key) gets no wrap and can ask for the chain later.
	}
	if len(fetch) > 0 {
		State_e2eeRequestUserKeys(state, serverID, fetch[:])
		return
	}
	room = State_findRoomChains(state, serverID, roomID)
	buffer: [common.SEALED_ENVELOPE_MAX_BYTES]u8
	n, err := common.sealSenderKeyDistribution(
		common.RoomKeyAADFields {
			serverIdentityPublicKey = e2ee.store.serverPublicKey,
			roomID = roomID,
			epoch = room.sendingEpoch,
			senderUserID = selfUserID,
			chainID = room.sending.chainID,
		},
		0,
		room.sending.startKey,
		recipients[:],
		identityPrivateKey,
		buffer[:],
	)
	if err != .None {
		State_roomChainsRefuseQueue(state, serverID, roomID, "Could not encrypt the room key")
		return
	}
	sendError := State_sendRoomChainRequest(
		state,
		serverID,
		{
			kind = .KeyEnvelope,
			roomID = roomID,
			epoch = room.sendingEpoch,
			chainID = room.sending.chainID,
			bytes = buffer[:n],
		},
	)
	if len(sendError) > 0 {
		// Not connected: the chain stays and the next session distributes it again (a chain
		// whose distribution was never acknowledged is dropped with its session).
		return
	}
	room = State_findRoomChains(state, serverID, roomID)
	room.distribution = .Sent
}

// Seals and sends the queue with the current chain, in order. Each message takes the chain's
// next index before it is sealed, so a failure never gives an index back.
@(private = "file")
State_roomChainsSendQueued :: proc(state: ^State, serverID, roomID: int, now: i64) {
	room := State_findRoomChains(state, serverID, roomID)
	selfUserID := State_selfUserID(state, serverID)
	identityPrivateKey, privateOK := common.identityPrivateKeyFromHex(state.config.private_key)
	defer crypto.zero_explicit(&identityPrivateKey, size_of(identityPrivateKey))
	e2ee, storeOK := State_e2eeEnsureStore(state, serverID)
	if !privateOK || !storeOK || selfUserID <= 0 {
		return
	}
	serverKey := e2ee.store.serverPublicKey
	sent := 0
	for len(room.queued) > 0 {
		if common.SenderChain_needsReplacement(room.sending, now) {
			// Used up: a new chain is distributed and the rest waits for it.
			RoomChainRoom_dropSending(room)
			State_roomChainsPump(state, serverID, roomID)
			break
		}
		item := room.queued[0]
		content := item.content
		send := RoomChainRequest {
			kind   = .SealedMessage,
			roomID = roomID,
		}
		// #76 M2: an edit is a sealed message whose plaintext names the original.
		replaces: Maybe(common.ClientMessageID)
		if item.editMessageID > 0 {
			send.kind = .SealedEdit
			send.messageID = item.editMessageID
			send.originalID = item.editOriginal
			replaces = item.editOriginal
		}
		// Protocol 27: outside the seal, only each file's blob ID and stored size.
		outer := make([]common.AttachmentRef, len(item.attachments), context.temp_allocator)
		for attachment, attachmentIndex in item.attachments {
			layout, _ := common.attachmentEncryptedLayout(attachment.size)
			outer[attachmentIndex] = {
				blobId = attachment.blobId,
				size   = layout.storedSize,
			}
		}
		send.attachments = outer
		if !common.generateRandomBytes(send.clientMessageID[:]) {
			break
		}
		index, messageKey, indexOK := common.SenderChain_nextMessageKey(&room.sending)
		if !indexOK {
			RoomChainRoom_dropSending(room)
			State_roomChainsPump(state, serverID, roomID)
			break
		}
		plaintext: [common.DIRECT_MESSAGE_PLAINTEXT_MAX_SIZE]u8
		plaintextSize, encodeOK := common.encodeSealedMessagePlaintext(
			content,
			item.attachments[:],
			plaintext[:],
			replaces,
		)
		buffer: [common.SEALED_ROOM_MESSAGE_MAX_BYTES]u8
		n := 0
		sealErr := common.E2EEError.BadPlaintext
		if encodeOK {
			n, sealErr = common.sealRoomMessage(
				common.RoomMessageContext {
					serverIdentityPublicKey = serverKey,
					roomID = roomID,
					senderUserID = selfUserID,
					clientMessageID = send.clientMessageID,
				},
				common.RoomMessageHeader {
					epoch = room.sendingEpoch,
					chainID = room.sending.chainID,
					index = index,
				},
				messageKey,
				plaintext[:plaintextSize],
				identityPrivateKey,
				buffer[:],
			)
		}
		crypto.zero_explicit(&messageKey, size_of(messageKey))
		crypto.zero_explicit(&plaintext, size_of(plaintext))
		if sealErr != .None {
			State_roomChainsRefuseQueue(state, serverID, roomID, "Could not encrypt the message")
			break
		}
		if item.forge {
			// The live proof's forged edit: a signature the server must refuse.
			buffer[n - 1] ~= 0x01
		}
		send.bytes = buffer[:n]
		sendError := State_sendRoomChainRequest(state, serverID, send)
		room = State_findRoomChains(state, serverID, roomID)
		if len(sendError) > 0 {
			State_setChatStatus(state, sendError)
			break
		}
		append(
			&room.inFlight,
			RoomChainInFlight{clientMessageID = send.clientMessageID, item = item},
		)
		ordered_remove(&room.queued, 0)
		sent += 1
	}
	if sent > 0 {
		State_roomChainNote(
			state,
			{kind = .QueueSent, serverID = serverID, roomID = roomID, count = sent},
		)
		room = State_findRoomChains(state, serverID, roomID)
		if room != nil && len(room.queued) == 0 {
			State_clearChatStatus(state)
		}
	}
}

// Gives every queued and in-flight message of roomID back to the room's draft, one per line in
// front of what is typed there, with why in the chat status. The chain is dropped.
@(private = "file")
State_roomChainsRefuseQueue :: proc(state: ^State, serverID, roomID: int, reason: string) {
	room := State_findRoomChains(state, serverID, roomID)
	if room == nil {
		return
	}
	RoomChainRoom_dropSending(room)
	// The text goes back to the draft; files listed with it stay uploaded and can be attached
	// again (State.attachmentUploads).
	texts := make([dynamic]string, 0, len(room.inFlight) + len(room.queued))
	defer delete(texts)
	// #76 M2: an edit's text is not a new message, so it never goes into the draft.
	droppedEdits := 0
	for &entry in room.inFlight {
		if entry.editMessageID > 0 {
			RoomChainQueued_deinit(&entry.item)
			droppedEdits += 1
			continue
		}
		append(&texts, entry.content)
		sealedAttachments_deinit(&entry.attachments)
	}
	clear(&room.inFlight)
	for &item in room.queued {
		if item.editMessageID > 0 {
			RoomChainQueued_deinit(&item)
			droppedEdits += 1
			continue
		}
		append(&texts, item.content)
		sealedAttachments_deinit(&item.attachments)
	}
	clear(&room.queued)
	if len(texts) == 0 {
		if droppedEdits > 0 {
			State_setChatStatus(state, reason)
			State_roomChainNote(
				state,
				{kind = .QueueRefused, serverID = serverID, roomID = roomID},
			)
		}
		return
	}
	cache := State_serverRoomCache(state, serverID)
	roomCache := ServerRoomCache_roomCache(cache, roomID)
	restored := make([dynamic]u8, 0, len(roomCache.draft) + 64)
	for text, index in texts {
		if index > 0 {
			append(&restored, '\n')
		}
		append(&restored, ..transmute([]u8)text)
		wipeString(text)
		delete(text)
	}
	if len(roomCache.draft) > 0 {
		append(&restored, '\n')
		append(&restored, ..roomCache.draft[:])
	}
	wipeBytes(roomCache.draft[:])
	delete(roomCache.draft)
	roomCache.draft = restored
	State_setChatStatus(state, reason)
	State_roomChainNote(state, {kind = .QueueRefused, serverID = serverID, roomID = roomID})
}

// The server's echo of a room message: one this session sent leaves the in-flight list.
State_roomChainsMessageEchoed :: proc(
	state: ^State,
	serverID, roomID, senderID: int,
	clientMessageID: common.ClientMessageID,
) {
	if senderID != State_selfUserID(state, serverID) {
		return
	}
	room := State_findRoomChains(state, serverID, roomID)
	if room == nil {
		return
	}
	for &entry, index in room.inFlight {
		if entry.clientMessageID == clientMessageID {
			RoomChainQueued_deinit(&entry.item)
			ordered_remove(&room.inFlight, index)
			return
		}
	}
}

// A ServerProtocolError on serverID. Protocol errors do not say which request they answer,
// so they apply to the rooms with requests outstanding.
State_roomChainsProtocolError :: proc(state: ^State, serverID: int, message: string) {
	// #76 M2: a refusal of a sealed edit names its message (common.messageRefusal).
	if messageID, base, named := messageRefusalParse(message); named {
		State_roomChainsEditRefused(state, serverID, messageID, base)
		return
	}
	staleKey := message == common.ROOM_KEY_OUT_OF_DATE_MESSAGE
	refused :=
		message == common.SEALED_ROOM_MESSAGE_INVALID_MESSAGE ||
		message == common.ROOM_MESSAGE_DUPLICATE_MESSAGE ||
		message == common.ROOM_KEY_ENVELOPE_INVALID_MESSAGE ||
		message == common.SEALED_ROOM_MESSAGE_NOT_ENCRYPTED_MESSAGE ||
		// Protocol 27: the files a message listed were refused; its text goes back to the
		// draft and the uploads can be attached again.
		message == common.ATTACHMENT_BIND_REFUSED_MESSAGE ||
		message == common.ATTACHMENT_SEND_NOT_PERMITTED_MESSAGE ||
		message == common.ATTACHMENT_REFS_INVALID_MESSAGE
	affected := make([dynamic]int, 0, 4, context.temp_allocator)
	for &chains in state.roomChains {
		if chains.serverID != serverID {
			continue
		}
		for &room in chains.rooms {
			// A fetch may be what was refused ("Not a room member").
			room.keysFetching = false
			if room.distribution == .Sent || len(room.inFlight) > 0 {
				append(&affected, room.roomID)
			}
		}
	}
	for roomID in affected {
		room := State_findRoomChains(state, serverID, roomID)
		switch {
		case staleKey:
			// The epoch moved on: what was in flight goes again, first, with a new chain.
			resend := make([dynamic]RoomChainQueued, 0, len(room.inFlight) + len(room.queued))
			for entry in room.inFlight {
				append(&resend, entry.item)
			}
			clear(&room.inFlight)
			append(&resend, ..room.queued[:])
			delete(room.queued)
			room.queued = resend
			RoomChainRoom_dropSending(room)
			State_requestRoomLog(state, serverID, roomID)
		case refused:
			State_roomChainsRefuseQueue(state, serverID, roomID, message)
		}
	}
}

// Splits a refusal that names its message ("… (message N)", common.messageRefusal) into the
// message ID and the base sentence (borrowed).
messageRefusalParse :: proc(message: string) -> (messageID: int, base: string, ok: bool) {
	if !strings.has_suffix(message, ")") {
		return 0, "", false
	}
	open := strings.last_index(message, " (message ")
	if open < 0 {
		return 0, "", false
	}
	digits := message[open + len(" (message "):len(message) - 1]
	value, parsed := strconv.parse_int(digits, 10)
	if !parsed || value <= 0 {
		return 0, "", false
	}
	return value, message[:open], true
}

// The server refused a change of messageID (#76 M2). An edit of it in flight goes again first
// with a new chain when the room's key was out of date (the epoch moved on); any other refusal
// drops it, with the reason in the chat status (already set by the caller).
@(private = "file")
State_roomChainsEditRefused :: proc(state: ^State, serverID, messageID: int, base: string) {
	for &chains in state.roomChains {
		if chains.serverID != serverID {
			continue
		}
		for &room in chains.rooms {
			for index := 0; index < len(room.inFlight); {
				entry := &room.inFlight[index]
				if entry.editMessageID != messageID {
					index += 1
					continue
				}
				if base == common.ROOM_KEY_OUT_OF_DATE_MESSAGE {
					inject_at(&room.queued, 0, entry.item)
					ordered_remove(&room.inFlight, index)
					RoomChainRoom_dropSending(&room)
					roomID := room.roomID
					State_requestRoomLog(state, serverID, roomID)
					return
				}
				RoomChainQueued_deinit(&entry.item)
				ordered_remove(&room.inFlight, index)
			}
		}
	}
}

// Requests in flight died with the session: fetches and requests start over, a distribution
// that was never acknowledged takes its chain with it, and messages in flight are dropped (they
// may have been stored; the next history page shows them).
State_roomChainsConnectionReset :: proc(state: ^State, serverID: int) {
	for &chains in state.roomChains {
		if chains.serverID != serverID {
			continue
		}
		for &room in chains.rooms {
			room.keysFetching = false
			room.keysFetched = false
			clear(&room.requested)
			clear(&room.answered)
			RoomChainRoom_clearInFlight(&room)
			if room.distribution == .Sent {
				RoomChainRoom_dropSending(&room)
			}
		}
	}
}

// Keys of users changed (fetched, pushed, trusted): distributions and answers that waited for
// them go on.
State_roomChainsKeysChanged :: proc(state: ^State, serverID: int) {
	rooms := make([dynamic]int, 0, 4, context.temp_allocator)
	for chains in state.roomChains {
		if chains.serverID != serverID {
			continue
		}
		for room in chains.rooms {
			append(&rooms, room.roomID)
		}
	}
	for roomID in rooms {
		State_roomChainsAnswerPending(state, serverID, roomID)
		State_roomChainsPump(state, serverID, roomID)
	}
}

// After Connected (the key store is loaded): queued messages go out once their chain is set up.
State_roomChainsConnected :: proc(state: ^State, serverID: int) {
	State_roomChainsKeysChanged(state, serverID)
}

// ── View ─────────────────────────────────────────────────────────

// The text a transcript shows for a room message, whether it is a placeholder, and its badge
// (static strings or allocator).
roomMessageDisplay :: proc(
	state: ^State,
	serverID: int,
	entry: RoomMessageEntry,
	allocator := context.temp_allocator,
) -> (
	text: string,
	placeholder: bool,
	badge: string,
) {
	// Protocol 30: a tombstone (D6) and the latest verified edit (message_edits.odin).
	if entry.deleted {
		return messageDeletedText(entry.edit), true, ""
	}
	switch entry.security.protection {
	case .Plain:
		return messageEditShownText(entry.content, entry.edit, entry.editCount, allocator),
			false,
			""
	case .Encrypted:
		return messageEditShownText(entry.content, entry.edit, entry.editCount, allocator),
			false,
			"🔒"
	case .Failed:
		return DIRECT_UNDECRYPTABLE_TEXT, true, ""
	case .Hidden:
		// Never drawn (roomMessageShown); nothing of it is shown if it were.
		return "", true, ""
	case .Pending:
		if len(entry.sealed) == 0 {
			return DIRECT_CHECKING_TEXT, true, ""
		}
		if entry.security.wait == .Key {
			name := entry.senderNickname
			if len(name) == 0 {
				name = State_e2eeUserName(state, serverID, entry.senderId)
			}
			return fmt.aprintf(ROOM_WAITING_FOR_KEY_FORMAT, name, allocator = allocator), true, ""
		}
		return DIRECT_OPENING_TEXT, true, ""
	}
	return entry.content, false, ""
}

// Unix seconds of a PostgreSQL timestamptz text ("2026-11-14 21:10:51.123456+00", with an
// optional ":MM" on the offset), or false. Used to place member list changes among messages.
parseServerTimestampUnix :: proc(text: string) -> (seconds: i64, ok: bool) {
	digits :: proc(text: string, start, count: int) -> (value: int, ok: bool) {
		if start + count > len(text) {
			return 0, false
		}
		for index in start ..< start + count {
			character := text[index]
			if character < '0' || character > '9' {
				return 0, false
			}
			value = value * 10 + int(character - '0')
		}
		return value, true
	}
	if len(text) < 19 || text[4] != '-' || text[7] != '-' || (text[10] != ' ' && text[10] != 'T') {
		return 0, false
	}
	year := digits(text, 0, 4) or_return
	month := digits(text, 5, 2) or_return
	day := digits(text, 8, 2) or_return
	hour := digits(text, 11, 2) or_return
	minute := digits(text, 14, 2) or_return
	second := digits(text, 17, 2) or_return
	position := 19
	if position < len(text) && text[position] == '.' {
		position += 1
		for position < len(text) && text[position] >= '0' && text[position] <= '9' {
			position += 1
		}
	}
	offset := 0
	if position < len(text) {
		sign := text[position]
		if sign != '+' && sign != '-' {
			return 0, false
		}
		offsetHours := digits(text, position + 1, 2) or_return
		offsetMinutes := 0
		if position + 3 < len(text) && text[position + 3] == ':' {
			offsetMinutes = digits(text, position + 4, 2) or_return
		}
		offset = (offsetHours * 60 + offsetMinutes) * 60
		if sign == '-' {
			offset = -offset
		}
	}
	// Days from the civil date (Howard Hinnant's algorithm).
	y := year
	if month <= 2 {
		y -= 1
	}
	era := (y >= 0 ? y : y - 399) / 400
	yearOfEra := y - era * 400
	shiftedMonth := month > 2 ? month - 3 : month + 9
	dayOfYear := (153 * shiftedMonth + 2) / 5 + day - 1
	dayOfEra := yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
	days := era * 146097 + dayOfEra - 719468
	return i64(days * 86400 + hour * 3600 + minute * 60 + second - offset), true
}

// A sealed message that failed before its signature was checked (log failed, sender not a
// member, index out of range): shown as "could not be decrypted" only when its signature
// verifies against the sender's identity (#90), otherwise not shown at all.
@(private = "file")
State_roomSettleSealed :: proc(
	state: ^State,
	serverID, roomID: int,
	keys: RoomChainKeys,
	entry: ^RoomMessageEntry,
	decoded: common.SealedRoomMessage,
	security: RoomMessageSecurity,
) {
	identity, identityOK := State_roomChainIdentityFor(
		state,
		serverID,
		roomID,
		keys,
		entry.senderId,
	)
	verified :=
		keys.ready &&
		identityOK &&
		common.verifyRoomMessageSignature(
			decoded,
			common.RoomMessageContext {
				serverIdentityPublicKey = keys.serverIdentityPublicKey,
				roomID = roomID,
				senderUserID = entry.senderId,
				clientMessageID = entry.clientMessageId,
			},
			identity,
		) ==
			.None
	settled := security
	if !verified {
		settled.protection = .Hidden
		roomEntryHide(entry, settled)
		return
	}
	entry.security = settled
}
