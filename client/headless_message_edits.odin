package client

import "../common"
import "core:strings"

// The harness side of editing and deleting messages (protocol 30, message_edits.odin):
// msg-edit, msg-delete, dm-edit, dm-delete and msg-edits, and the message_edited,
// message_deleted and message_edits events, printed after State checked what arrived. Room and
// direct message events carry editCount, edited, editStatus, deleted and removedByServer, and
// their content is the latest verified version.

HEADLESS_EDIT_STATUS_NAMES := [MessageEditStatus]string {
	.None     = "none",
	.Verified = "verified",
	.Pending  = "pending",
	.Failed   = "failed",
}

// The text a message shows as its content: nothing for a tombstone, else the latest verified
// edit, else the original. Borrowed.
headlessEditedContent :: proc(content: string, view: MessageEditView, deleted: bool) -> string {
	if deleted {
		return ""
	}
	if view.shownEditID > 0 {
		return view.shownContent
	}
	return content
}

HeadlessMessageEditRequestJSON :: struct {
	ok:             bool,
	cmd:            string,
	serverID:       int,
	kind:           string,
	conversationID: int,
	messageID:      int,
}

// message_edited: an edit of a cached message, after the client checked it. editStatus is
// verified (content is the edit), pending (the author's key is still on its way, or a sealed
// edit this build does not open) or failed (the edit is not shown; content stays the last good
// version). found is false for a message this client has not loaded.
HeadlessMessageEditedJSON :: struct {
	event:          string,
	serverID:       int,
	kind:           string,
	conversationID: int,
	messageID:      int,
	senderID:       int,
	found:          bool,
	editCount:      int,
	editID:         int,
	editStatus:     string,
	content:        string,
}

// message_deleted: a tombstone; removedByServer is true unless the author's signature verified
// against the pin (D6).
HeadlessMessageDeletedJSON :: struct {
	event:           string,
	serverID:        int,
	kind:            string,
	conversationID:  int,
	messageID:       int,
	senderID:        int,
	found:           bool,
	deleted:         bool,
	removedByServer: bool,
}

HeadlessMessageEditJSON :: struct {
	id:        int,
	timestamp: string,
	status:    string,
	content:   string,
}

// message_edits: a message's edit history, oldest first; only verified edits print content.
HeadlessMessageEditsJSON :: struct {
	event:          string,
	serverID:       int,
	kind:           string,
	conversationID: int,
	messageID:      int,
	found:          bool,
	edits:          []HeadlessMessageEditJSON,
}

@(private = "file")
headlessEditKindName :: proc(kind: common.MessageEditsKind) -> string {
	return kind == .Room ? "room" : "dm"
}

// The conversation a notice names from this account's side: the room, or the DM's peer.
@(private = "file")
headlessEditConversation :: proc(
	state: ^State,
	event: ^ClientTransportRuntimeEvent,
) -> int {
	if event.editKind == .Room {
		return event.roomID
	}
	if event.kind == .MessageEditsReceived {
		return event.peerUserID
	}
	return directMessagePeerUserID(
		common.StoredDirectMessage{senderId = event.senderID, recipientId = event.peerUserID},
		State_selfUserID(state, event.serverID),
	)
}

// The cached message's view, edit count and author, when it is cached.
@(private = "file")
headlessEditEntry :: proc(
	state: ^State,
	serverID: int,
	kind: common.MessageEditsKind,
	conversationID, messageID: int,
) -> (
	view: ^MessageEditView,
	editCount: int,
	content: string,
	deleted: bool,
	found: bool,
) {
	if kind == .Room {
		entry := State_roomMessageEntry(state, serverID, conversationID, messageID)
		if entry == nil {
			return
		}
		return &entry.edit,
			entry.editCount,
			headlessRoomContent(entry^),
			entry.deleted,
			true
	}
	entry := State_directMessageEntry(state, serverID, conversationID, messageID)
	if entry == nil {
		return
	}
	return &entry.edit,
		entry.editCount,
		headlessDirectContent(
			entry.security,
			headlessEditedContent(entry.content, entry.edit, entry.deleted),
		),
		entry.deleted,
		true
}

// Prints message_edited, message_deleted or message_edits for an event State just applied.
headlessWriteMessageEditEvent :: proc(
	harness: ^HeadlessHarness,
	event: ^ClientTransportRuntimeEvent,
) {
	state := &harness.state
	conversationID := headlessEditConversation(state, event)
	view, editCount, content, deleted, found := headlessEditEntry(
		state,
		event.serverID,
		event.editKind,
		conversationID,
		event.messageID,
	)
	#partial switch event.kind {
	case .MessageEdited:
		line := HeadlessMessageEditedJSON {
			event          = HEADLESS_EVENT_NAMES[.MessageEdited],
			serverID       = event.serverID,
			kind           = headlessEditKindName(event.editKind),
			conversationID = conversationID,
			messageID      = event.messageID,
			senderID       = event.senderID,
			found          = found,
			editCount      = event.editCount,
		}
		if found {
			line.editCount = editCount
			line.editID = view.shownEditID
			line.editStatus = HEADLESS_EDIT_STATUS_NAMES[view.status]
			line.content = content
		}
		headlessWriteJSON(harness, line)
		headlessRecordEvent(harness, .MessageEdited)
	case .MessageDeleted:
		headlessWriteJSON(
			harness,
			HeadlessMessageDeletedJSON {
				event = HEADLESS_EVENT_NAMES[.MessageDeleted],
				serverID = event.serverID,
				kind = headlessEditKindName(event.editKind),
				conversationID = conversationID,
				messageID = event.messageID,
				senderID = event.senderID,
				found = found,
				deleted = found && deleted,
				removedByServer = found && deleted && view.deleteStatus != .Author,
			},
		)
		headlessRecordEvent(harness, .MessageDeleted)
	case .MessageEditsReceived:
		edits: []HeadlessMessageEditJSON
		if found {
			edits = make([]HeadlessMessageEditJSON, len(view.edits), context.temp_allocator)
			for edit, index in view.edits {
				status := view.editStatuses[index]
				edits[index] = HeadlessMessageEditJSON {
					id        = edit.id,
					timestamp = edit.timestamp,
					status    = HEADLESS_EDIT_STATUS_NAMES[status],
					content   = status == .Verified ? edit.content : "",
				}
			}
		}
		headlessWriteJSON(
			harness,
			HeadlessMessageEditsJSON {
				event = HEADLESS_EVENT_NAMES[.MessageEdits],
				serverID = event.serverID,
				kind = headlessEditKindName(event.editKind),
				conversationID = conversationID,
				messageID = event.messageID,
				found = found,
				edits = edits,
			},
		)
		headlessRecordEvent(harness, .MessageEdits)
	}
}

// Leading --forge and --unchecked options of an edit's text, and the rest.
@(private = "file")
headlessEditOptions :: proc(text: string) -> (forge: bool, unchecked: bool, rest: string) {
	rest = strings.trim_left(text, " \t")
	for {
		switch {
		case strings.has_prefix(rest, "--forge"):
			forge = true
			rest = strings.trim_left(rest[len("--forge"):], " \t")
		case strings.has_prefix(rest, "--unchecked"):
			unchecked = true
			rest = strings.trim_left(rest[len("--unchecked"):], " \t")
		case:
			return
		}
	}
}

@(private = "file")
headlessWriteEditRequest :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
	kind: common.MessageEditsKind,
	conversationID, messageID: int,
	failure: string,
) {
	if len(failure) > 0 {
		headlessWriteError(harness, command.name, failure)
		return
	}
	headlessWriteJSON(
		harness,
		HeadlessMessageEditRequestJSON {
			ok = true,
			cmd = command.name,
			serverID = harness.state.selected_server_id,
			kind = headlessEditKindName(kind),
			conversationID = conversationID,
			messageID = messageID,
		},
	)
}

headlessCommandMessageEdit :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	roomID, roomOK := headlessParseNumber(command.args[0])
	messageID, messageOK := headlessParseNumber(command.args[1])
	if !roomOK || !messageOK || roomID <= 0 || messageID <= 0 {
		headlessWriteError(harness, command.name, "usage: msg-edit ROOM_ID MESSAGE_ID TEXT...")
		return
	}
	forge, unchecked, text := headlessEditOptions(command.args[2])
	failure := State_editRoomMessage(
		&harness.state,
		harness.state.selected_server_id,
		roomID,
		messageID,
		text,
		forgeSignature = forge,
		checkRights = !unchecked,
	)
	headlessWriteEditRequest(harness, command, .Room, roomID, messageID, failure)
}

headlessCommandMessageDelete :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	roomID, roomOK := headlessParseNumber(command.args[0])
	messageID, messageOK := headlessParseNumber(command.args[1])
	mode := command.argCount > 2 ? command.args[2] : ""
	if !roomOK || !messageOK || roomID <= 0 || messageID <= 0 ||
	   (mode != "" && mode != "admin" && mode != "unchecked") {
		headlessWriteError(
			harness,
			command.name,
			"usage: msg-delete ROOM_ID MESSAGE_ID [admin|unchecked]",
		)
		return
	}
	failure := State_deleteRoomMessage(
		&harness.state,
		harness.state.selected_server_id,
		roomID,
		messageID,
		asAdmin = mode == "admin",
		checkRights = mode == "",
	)
	headlessWriteEditRequest(harness, command, .Room, roomID, messageID, failure)
}

headlessCommandDirectEdit :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	peerUserID, peerOK := headlessParseNumber(command.args[0])
	messageID, messageOK := headlessParseNumber(command.args[1])
	if !peerOK || !messageOK || peerUserID <= 0 || messageID <= 0 {
		headlessWriteError(harness, command.name, "usage: dm-edit USER_ID MESSAGE_ID TEXT...")
		return
	}
	forge, unchecked, text := headlessEditOptions(command.args[2])
	failure := State_editDirectMessage(
		&harness.state,
		harness.state.selected_server_id,
		peerUserID,
		messageID,
		text,
		forgeSignature = forge,
		checkRights = !unchecked,
	)
	headlessWriteEditRequest(harness, command, .Direct, peerUserID, messageID, failure)
}

headlessCommandDirectDelete :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	peerUserID, peerOK := headlessParseNumber(command.args[0])
	messageID, messageOK := headlessParseNumber(command.args[1])
	mode := command.argCount > 2 ? command.args[2] : ""
	if !peerOK || !messageOK || peerUserID <= 0 || messageID <= 0 ||
	   (mode != "" && mode != "unchecked") {
		headlessWriteError(harness, command.name, "usage: dm-delete USER_ID MESSAGE_ID [unchecked]")
		return
	}
	failure := State_deleteDirectMessage(
		&harness.state,
		harness.state.selected_server_id,
		peerUserID,
		messageID,
		checkRights = mode == "",
	)
	headlessWriteEditRequest(harness, command, .Direct, peerUserID, messageID, failure)
}

headlessCommandMessageEdits :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	kind := common.MessageEditsKind.None
	switch command.args[0] {
	case "room":
		kind = .Room
	case "dm":
		kind = .Direct
	}
	conversationID, conversationOK := headlessParseNumber(command.args[1])
	messageID, messageOK := headlessParseNumber(command.args[2])
	if kind == .None || !conversationOK || !messageOK || conversationID <= 0 || messageID <= 0 {
		headlessWriteError(harness, command.name, "usage: msg-edits room|dm ID MESSAGE_ID")
		return
	}
	// The harness always asks the server, so a proof sees every edit that arrived since.
	failure := State_fetchMessageEdits(
		&harness.state,
		harness.state.selected_server_id,
		kind,
		conversationID,
		messageID,
		force = true,
	)
	headlessWriteEditRequest(harness, command, kind, conversationID, messageID, failure)
}
