package client

import "../common"
import "core:slice"

// The harness side of sender chains in encrypted rooms (protocol 19, room_chains.odin): room
// messages are printed after State opened them (room_chat, room_history), a live message that
// waits for its key or the log is owed and printed as room_chat when it opens, a history one as
// room_opened; key envelopes print room_key, key requests room_key_request, and queued messages
// room_queue. `room-keys` shows the chains a profile holds, never a key.

HEADLESS_ROOM_PROTECTION_NAMES := [RoomMessageProtection]string {
	.Plain     = "plain",
	.Pending   = "pending",
	.Encrypted = "encrypted",
	.Failed    = "failed",
	.Hidden    = "hidden",
}

HeadlessRoomSecurityFields :: struct {
	encrypted:    bool,
	decryptError: string,
	epoch:        int,
	protection:   string,
}

// What the client concluded about a room message, for the JSON. Strings are static.
headlessRoomSecurity :: proc(
	security: RoomMessageSecurity,
	sealed: bool,
) -> HeadlessRoomSecurityFields {
	fields := HeadlessRoomSecurityFields {
		encrypted  = sealed,
		epoch      = security.header.epoch,
		protection = HEADLESS_ROOM_PROTECTION_NAMES[security.protection],
	}
	switch security.protection {
	case .Pending:
		switch security.wait {
		case .Key:
			fields.decryptError = "no_key"
		case .Log:
			fields.decryptError = "log"
		case .Sender:
			fields.decryptError = "sender_key"
		case .None:
		}
	case .Failed, .Hidden:
		switch security.failure {
		case .Sealed, .None:
			fields.decryptError = headlessE2EEErrorName(security.sealedError)
		case .NotSealed:
			fields.decryptError = "not_sealed"
		case .NotMember:
			fields.decryptError = "not_member"
		case .BadIndex:
			fields.decryptError = "bad_index"
		case .LogFailed:
			fields.decryptError = "log_failed"
		case .Replayed:
			fields.decryptError = "replayed"
		case .Unsigned:
			fields.decryptError = "unsigned"
		case .BadSignature:
			fields.decryptError = "bad_signature"
		case .NoKey:
			fields.decryptError = "no_sender_key"
		}
	case .Plain, .Encrypted:
	}
	return fields
}

// The text the harness prints for a room message: only what the window shows as content.
headlessRoomContent :: proc(entry: RoomMessageEntry) -> string {
	#partial switch entry.security.protection {
	case .Plain, .Encrypted:
		return entry.content
	}
	return ""
}

// The cached entry of message, or nil.
@(private = "file")
headlessCachedRoomEntry :: proc(
	state: ^State,
	serverID: int,
	message: common.StoredChatMessage,
) -> ^RoomMessageEntry {
	if state == nil {
		return nil
	}
	cacheIndex := State_serverRoomCacheIndex(state^, serverID)
	if cacheIndex < 0 {
		return nil
	}
	cache := &state.server_room_caches[cacheIndex]
	roomIndex := ServerRoomCache_roomCacheIndex(cache^, message.roomId)
	if roomIndex < 0 {
		return nil
	}
	for &entry in cache.roomCaches[roomIndex].messages {
		if entry.id == message.id {
			return &entry
		}
	}
	return nil
}

// The JSON of a room message as State holds it (the cached entry: opened content and what
// was checked), otherwise as it came. Strings stay borrowed.
headlessRoomMessageFields :: proc(
	state: ^State,
	serverID: int,
	message: common.StoredChatMessage,
) -> HeadlessHistoryMessageJSON {
	// Not cached: nothing was checked, so nothing of it is printed as content.
	entry := RoomMessageEntry {
		message = message,
		security = {protection = .Pending},
	}
	if cached := headlessCachedRoomEntry(state, serverID, message); cached != nil {
		entry = cached^
	}
	fields := headlessRoomSecurity(entry.security, len(entry.sealed) > 0)
	return HeadlessHistoryMessageJSON {
		id = entry.id,
		senderID = entry.senderId,
		senderNickname = entry.senderNickname,
		timestamp = entry.timestamp,
		encrypted = fields.encrypted,
		decryptError = fields.decryptError,
		epoch = fields.epoch,
		protection = fields.protection,
		content = headlessRoomContent(entry),
		attachments = headlessAttachmentsJSON(entry.files[:]),
		attachmentsChanged = entry.filesChanged,
	}
}

headlessWriteRoomChatLine :: proc(
	harness: ^HeadlessHarness,
	kind: HeadlessEventKind,
	serverID: int,
	message: common.StoredChatMessage,
) {
	fields := headlessRoomMessageFields(&harness.state, serverID, message)
	headlessWriteJSON(
		harness,
		HeadlessRoomChatJSON {
			event = HEADLESS_EVENT_NAMES[kind],
			serverID = serverID,
			roomID = message.roomId,
			messageID = fields.id,
			senderID = fields.senderID,
			senderNickname = fields.senderNickname,
			timestamp = fields.timestamp,
			encrypted = fields.encrypted,
			decryptError = fields.decryptError,
			epoch = fields.epoch,
			protection = fields.protection,
			content = fields.content,
			attachments = fields.attachments,
			attachmentsChanged = fields.attachmentsChanged,
		},
	)
	headlessRecordEvent(harness, kind)
}

// A live room message, once State applied it; one that waits is owed until it opens.
headlessWriteRoomChat :: proc(harness: ^HeadlessHarness, event: ^ClientTransportRuntimeEvent) {
	message := common.StoredChatMessage {
		id              = event.messageID,
		senderId        = event.senderID,
		senderNickname  = event.senderNickname,
		roomId          = event.roomID,
		timestamp       = event.timestamp,
		content         = event.message,
		clientMessageId = event.clientMessageID,
		sealed          = event.sealed,
		signature       = event.signature,
	}
	if cached := headlessCachedRoomEntry(&harness.state, event.serverID, message);
	   cached != nil && cached.security.protection == .Pending {
		harness.owedRoomMessages[{event.serverID, message.id}] = true
		return
	}
	headlessWriteRoomChatLine(harness, .RoomChat, event.serverID, message)
}

headlessWriteRoomHistory :: proc(harness: ^HeadlessHarness, event: ^ClientTransportRuntimeEvent) {
	messages := make([]HeadlessHistoryMessageJSON, len(event.messages))
	defer delete(messages)
	for message, index in event.messages {
		messages[index] = headlessRoomMessageFields(&harness.state, event.serverID, message)
	}
	headlessWriteJSON(
		harness,
		HeadlessRoomHistoryJSON {
			event = HEADLESS_EVENT_NAMES[.RoomHistory],
			serverID = event.serverID,
			roomID = event.roomID,
			hasOlder = event.hasOlder,
			messages = messages,
		},
	)
	headlessRecordEvent(harness, .RoomHistory)
}

HEADLESS_ROOM_KEY_OUTCOME_NAMES := [RoomChainKeyOutcome]string {
	.Stored     = "stored",
	.Duplicate  = "duplicate",
	.NotForMe   = "not_for_me",
	.Pending    = "pending",
	.NotMember  = "not_member",
	.Failed     = "failed",
	.Refused    = "refused",
	.NotAllowed = "not_allowed",
	.NotHeld    = "not_held",
}

// room_key: an envelope this client handled. room_key_request: a request it answered
// (outcome stored), refused, or could not answer (not_held), and (Full history) each chain an
// inviter forwards. forwarderID: who forwarded a RoomKeyForward envelope (room_key), or this
// account when it forwarded one (room_key_request); 0 for a SenderKey envelope.
HeadlessRoomKeyJSON :: struct {
	event:       string,
	serverID:    int,
	roomID:      int,
	epoch:       int,
	senderID:    int,
	chainID:     string,
	requesterID: int,
	outcome:     string,
	error:       string,
	forwarderID: int,
}

HeadlessRoomQueueJSON :: struct {
	event:    string,
	serverID: int,
	roomID:   int,
	state:    string, // "sent" or "refused"
	count:    int,
	reason:   string,
}

// Prints what State recorded after the event or command that caused it.
headlessWriteRoomChainNotes :: proc(harness: ^HeadlessHarness) {
	state := &harness.state
	for note in state.roomChainNotes {
		switch note.kind {
		case .Opened:
			entry := headlessRoomNoteEntry(state, note)
			if entry == nil {
				continue
			}
			kind := HeadlessEventKind.RoomOpened
			if harness.owedRoomMessages[{note.serverID, note.messageID}] {
				delete_key(&harness.owedRoomMessages, [2]int{note.serverID, note.messageID})
				kind = .RoomChat
			}
			headlessWriteRoomChatLine(harness, kind, note.serverID, entry.message)
		case .Key, .Answered:
			kind := note.kind == .Key ? HeadlessEventKind.RoomKey : .RoomKeyRequest
			chainID := note.ref.chainID
			value := HeadlessRoomKeyJSON {
				event       = HEADLESS_EVENT_NAMES[kind],
				serverID    = note.serverID,
				roomID      = note.roomID,
				epoch       = note.ref.epoch,
				senderID    = note.ref.senderUserID,
				chainID     = headlessTempHex(chainID[:]),
				requesterID = note.peerID,
				outcome     = HEADLESS_ROOM_KEY_OUTCOME_NAMES[note.outcome],
				forwarderID = note.forwarderID,
			}
			if note.error != .None {
				value.error = headlessE2EEErrorName(note.error)
			}
			headlessWriteJSON(harness, value)
			headlessRecordEvent(harness, kind)
		case .QueueSent, .QueueRefused:
			value := HeadlessRoomQueueJSON {
				event    = HEADLESS_EVENT_NAMES[.RoomQueue],
				serverID = note.serverID,
				roomID   = note.roomID,
				state    = "sent",
				count    = note.count,
			}
			if note.kind == .QueueRefused {
				value.state = "refused"
				value.reason = state.chat_status_message
			}
			headlessWriteJSON(harness, value)
			headlessRecordEvent(harness, .RoomQueue)
		}
	}
	clear(&state.roomChainNotes)
}

@(private = "file")
headlessRoomNoteEntry :: proc(state: ^State, note: RoomChainNote) -> ^RoomMessageEntry {
	return headlessCachedRoomEntry(
		state,
		note.serverID,
		common.StoredChatMessage{id = note.messageID, roomId = note.roomID},
	)
}

HeadlessRoomChainJSON :: struct {
	epoch:      int,
	senderID:   int,
	chainID:    string,
	startIndex: u32,
}

// `room-keys`: never a key, only which chains are held and how sending stands.
HeadlessRoomKeysJSON :: struct {
	ok:           bool,
	cmd:          string,
	serverID:     int,
	roomID:       int,
	epoch:        int, // The verified log's
	chains:       []HeadlessRoomChainJSON,
	sending:      bool,
	sendingEpoch: int,
	sendingChain: string,
	nextIndex:    u32,
	distribution: string,
	queued:       int,
	inFlight:     int,
	keysFetched:  bool,
}

HEADLESS_ROOM_DISTRIBUTION_NAMES := [RoomChainDistribution]string {
	.None   = "none",
	.Sent   = "sent",
	.Stored = "stored",
}

headlessCommandRoomKeys :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	roomID, ok := headlessParseNumber(command.args[0])
	if !ok || roomID <= 0 {
		headlessWriteError(harness, command.name, "usage: room-keys ROOM_ID")
		return
	}
	state := &harness.state
	serverID := state.selected_server_id
	if len(command.args) > 1 && len(command.args[1]) > 0 {
		if command.args[1] != "fetch" {
			headlessWriteError(harness, command.name, "usage: room-keys ROOM_ID [fetch]")
			return
		}
		if errorMessage := State_roomChainsFetchKeysNow(state, serverID, roomID);
		   len(errorMessage) > 0 {
			headlessWriteError(harness, command.name, errorMessage)
			return
		}
	}
	chains := make([dynamic]HeadlessRoomChainJSON, 0, 8, context.temp_allocator)
	if e2ee, storeOK := State_e2eeEnsureStore(state, serverID); storeOK && e2ee != nil {
		for chain in e2ee.store.roomChains {
			if chain.roomID != roomID {
				continue
			}
			chainID := chain.chainID
			append(
				&chains,
				HeadlessRoomChainJSON {
					epoch = chain.epoch,
					senderID = chain.senderUserID,
					chainID = headlessTempHex(chainID[:]),
					startIndex = chain.startIndex,
				},
			)
		}
	}
	slice.sort_by(chains[:], proc(a, b: HeadlessRoomChainJSON) -> bool {
		if a.epoch != b.epoch {
			return a.epoch < b.epoch
		}
		return a.senderID < b.senderID
	})
	room := State_roomChainRoom(state, serverID, roomID)
	sendingChain := room.sending.chainID
	value := HeadlessRoomKeysJSON {
		ok           = true,
		cmd          = command.name,
		serverID     = serverID,
		roomID       = roomID,
		epoch        = State_roomLogEpoch(state, serverID, roomID),
		chains       = chains[:],
		sending      = room.hasSending,
		sendingEpoch = room.sendingEpoch,
		nextIndex    = room.sending.nextIndex,
		distribution = HEADLESS_ROOM_DISTRIBUTION_NAMES[room.distribution],
		queued       = len(room.queued),
		inFlight     = len(room.inFlight),
		keysFetched  = room.keysFetched,
	}
	if room.hasSending {
		value.sendingChain = headlessTempHex(sendingChain[:])
	}
	headlessWriteJSON(harness, value)
}

// Hex of data in the temp allocator.
@(private = "file")
headlessTempHex :: proc(data: []u8) -> string {
	context.allocator = context.temp_allocator
	return common.encodeBytesToHex(data)
}
