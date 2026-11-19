package client

import "../common"
import "core:fmt"
import "core:strings"
import "ui"

// The GUI for editing and deleting messages (#76 M3, docs/plan/2026-11-19-message-edit-delete.md):
// the State behind the inline edit bar, the delete confirmation and the edit history popover,
// and the pure view models view_message_edits.odin draws. Sending, verification and the
// server's notices are message_edits.odin's; nothing here changes a message locally.
//
// - Rights (messageChangeRights): Edit message and Delete message… on your own room and direct
//   messages that are not tombstones; Edit needs a message that opened (a sealed one that
//   failed cannot be edited) and, in a room, what a new message needs (D10: a chat room with
//   SendMessages). Admins also get Delete message… on others' ROOM messages (D5, the admin
//   path, no signature). Nothing is offered while the server is not connected.
// - Editing (MessageEditComposer): one message at a time. Its text lives in its own buffer, so
//   the conversation's draft is never touched and is there again after a save or a cancel.
//   Enter saves (unchanged text just closes), Esc or × cancels, an empty edit of a message
//   without files is refused locally. A save closes the bar once the edit went out or was
//   queued (a sealed room edit waits on the sender chain and appears with the server's
//   notice); an encrypted DM whose peer key is still being fetched keeps the bar open with
//   "Setting up encryption…" and sends by itself once the key can be encrypted to
//   (State_messageEditPoll), or when the user presses Enter again. Other refusals stay in the
//   bar; the server's refusals arrive as protocol errors naming the message and go to the
//   chat status like every protocol error.
// - Deleting (MessageDeleteDialog): a confirmation that says the files and the edit history go
//   too (D7, D8), and for an admin's delete that members see "Removed by the server" (D6). It
//   closes when the tombstone arrives; a protocol error naming its message stays in it.
// - The edit history (EditHistoryPopover): opened by resting on "(edited)" for
//   MESSAGE_EDIT_HISTORY_HOVER_MS or clicking it, fetched once (State_fetchMessageEdits, D14)
//   and rebuilt from State every frame, so a sealed edit that opens later shows up without an
//   event of its own.

MESSAGE_EDIT_HISTORY_HOVER_MS :: 400
MESSAGE_EDIT_BAR_TITLE :: "Editing message"
MESSAGE_EDIT_BAR_HINT :: "Enter to save · Esc to cancel"
MESSAGE_EDIT_PLACEHOLDER :: "Edit message (Enter to save, Esc to cancel)"
MESSAGE_EDIT_EMPTY_TEXT :: "Cannot send an empty message"
MESSAGE_EDIT_MARKER :: "(edited)"
MESSAGE_EDIT_PENDING_MARKER :: "(edited, not verified yet)"
MESSAGE_EDIT_FAILED_MARKER :: "(edited) · An edit could not be verified"
MESSAGE_EDIT_FAILED_NOTE :: "An edit could not be verified"
MESSAGE_EDIT_HISTORY_TITLE :: "Edit history"
MESSAGE_EDIT_HISTORY_LOADING :: "Loading edits…"
MESSAGE_EDIT_HISTORY_ORIGINAL :: "Original"
MESSAGE_EDIT_WAITING_TEXT :: "Waiting for key…"
MESSAGE_EDIT_UNVERIFIED_TEXT :: "This edit could not be verified"
MESSAGE_DELETE_TITLE :: "Delete message"
MESSAGE_DELETE_WAITING_TEXT :: "Waiting for the server…"

// The kind of a conversation as the edit protocol names it.
messageEditsKindOf :: proc(kind: common.ReadMarkerKind) -> common.MessageEditsKind {
	return kind == .Direct ? .Direct : .Room
}

// ── Rights ────────────────────────────────────────────────────────

// What this account may do with one cached message, for the menu and the Up arrow.
MessageChangeRights :: struct {
	found:          bool,
	own:            bool,
	deleted:        bool,
	canEdit:        bool,
	canDelete:      bool, // The author's own, signed delete
	// An admin's moderation delete of someone else's room message (D5).
	canAdminDelete: bool,
}

// The facts about a message that decide its rights. Pure inputs, so the rules are tested
// without a State.
MessageChangeFacts :: struct {
	kind:      common.ReadMarkerKind,
	own:       bool,
	deleted:   bool,
	// The message is shown opened: a plaintext one whose signature verified, or a sealed one
	// that opened (a failed one cannot be edited, D11).
	opened:    bool,
	connected: bool,
	isAdmin:   bool,
	// Rooms: the room takes chat and this account may send there (D10).
	roomSends: bool,
}

messageChangeRightsFor :: proc(facts: MessageChangeFacts) -> (rights: MessageChangeRights) {
	rights.found = true
	rights.own = facts.own
	rights.deleted = facts.deleted
	if facts.deleted || !facts.connected {
		return
	}
	if facts.own {
		rights.canDelete = true
		rights.canEdit = facts.opened && (facts.kind == .Direct || facts.roomSends)
		return
	}
	rights.canAdminDelete = facts.kind == .Room && facts.isAdmin
	return
}

// The facts of a cached message, and whether it is cached.
State_messageChangeFacts :: proc(
	state: ^State,
	serverID: int,
	kind: common.ReadMarkerKind,
	conversationID, messageID: int,
) -> (
	facts: MessageChangeFacts,
	found: bool,
) {
	facts.kind = kind
	facts.connected = State_isServerConnected(state, serverID)
	facts.isAdmin = State_isServerAdmin(state, serverID)
	selfUserID := State_selfUserID(state, serverID)
	switch kind {
	case .Room:
		entry := State_roomMessageEntry(state, serverID, conversationID, messageID)
		if entry == nil {
			return
		}
		found = true
		facts.own = selfUserID != 0 && entry.senderId == selfUserID
		facts.deleted = entry.deleted
		if len(entry.sealed) > 0 {
			facts.opened = entry.security.protection == .Encrypted
		} else {
			facts.opened =
				entry.security.protection == .Plain &&
				!State_roomIsEncrypted(state, serverID, conversationID)
		}
		facts.roomSends =
			State_roomAllowsChat(state, serverID, conversationID) &&
			State_hasRoomPermission(state, serverID, conversationID, .SendMessages)
	case .Direct:
		entry := State_directMessageEntry(state, serverID, conversationID, messageID)
		if entry == nil {
			return
		}
		found = true
		facts.own = selfUserID != 0 && entry.senderId == selfUserID
		facts.deleted = entry.deleted
		if len(entry.envelope) > 0 {
			facts.opened = entry.security.protection == .Encrypted
		} else {
			facts.opened = entry.security.protection == .Signed
		}
	}
	return
}

State_messageChangeRights :: proc(
	state: ^State,
	serverID: int,
	kind: common.ReadMarkerKind,
	conversationID, messageID: int,
) -> MessageChangeRights {
	facts, found := State_messageChangeFacts(state, serverID, kind, conversationID, messageID)
	if !found {
		return {}
	}
	return messageChangeRightsFor(facts)
}

// The text a message shows now: its latest verified edit, else the original. Borrowed.
messageEditCurrentText :: proc(content: string, view: MessageEditView) -> string {
	if len(view.shownContent) > 0 || view.shownEditID > 0 {
		return view.shownContent
	}
	return content
}

// The current text of a cached message and whether it has files. Borrowed.
State_messageCurrentText :: proc(
	state: ^State,
	serverID: int,
	kind: common.ReadMarkerKind,
	conversationID, messageID: int,
) -> (
	text: string,
	hasFiles: bool,
	found: bool,
) {
	switch kind {
	case .Room:
		if entry := State_roomMessageEntry(state, serverID, conversationID, messageID);
		   entry != nil {
			return messageEditCurrentText(entry.content, entry.edit), len(entry.attachments) > 0,
				true
		}
	case .Direct:
		if entry := State_directMessageEntry(state, serverID, conversationID, messageID);
		   entry != nil {
			return messageEditCurrentText(entry.content, entry.edit), len(entry.attachments) > 0,
				true
		}
	}
	return "", false, false
}

// ── The edit marker ──────────────────────────────────────────────

// What follows a message's text: "(edited)" once an edit verified, "(edited, not verified
// yet)" while one waits, and the failed note when the latest edit did not verify (the last
// good version is shown). "" for a message never edited and for a tombstone. failed asks for
// the warning colour.
messageEditMarker :: proc(
	view: MessageEditView,
	editCount: int,
	deleted: bool,
) -> (
	marker: string,
	failed: bool,
) {
	if deleted {
		return "", false
	}
	switch view.status {
	case .Verified:
		return MESSAGE_EDIT_MARKER, false
	case .Pending:
		return MESSAGE_EDIT_PENDING_MARKER, false
	case .Failed:
		return MESSAGE_EDIT_FAILED_MARKER, true
	case .None:
	}
	if editCount > 0 && view.shownEditID > 0 {
		return MESSAGE_EDIT_MARKER, false
	}
	return "", false
}

// Why an edit failed, as a short sentence for the history (static).
messageEditFailureText :: proc(failure: MessageEditFailure) -> string {
	switch failure {
	case .None:
		return ""
	case .Signature:
		return "Not signed by the author over this message"
	case .NoKey:
		return "No key to check it with"
	case .Kind:
		return "Its encryption does not match the message's"
	case .Sealed:
		return "The encrypted edit did not open"
	case .NotEdit:
		return "It is not an edit"
	case .Moved:
		return "It belongs to another message"
	case .Attachments:
		return "It carries files"
	case .Empty:
		return "It is empty"
	case .Replayed:
		return "It repeats an earlier edit"
	case .NotMember:
		return "The author was not a member then"
	case .BadIndex:
		return "Its key position is invalid"
	case .LogFailed:
		return "The room's member list failed verification"
	}
	return ""
}

// ── Editing ──────────────────────────────────────────────────────

// The message being edited inline. text is the edit's own buffer (wiped before it is freed);
// status is owned.
MessageEditComposer :: struct {
	active:          bool,
	serverID:        int,
	kind:            common.ReadMarkerKind,
	conversationID:  int,
	messageID:       int,
	text:            [dynamic]u8,
	status:          string,
	// The status is a refusal (danger) rather than a wait (muted).
	statusError:     bool,
	// An encrypted DM's save waits for the peer's key: State_messageEditPoll sends it then.
	waitingForKey:   bool,
	// The view gives the edit field the keyboard on its next frame.
	focusPending:    bool,
	// The view gives the conversation's composer the keyboard back on its next frame (after a
	// save or a cancel).
	refocusComposer: bool,
}

@(private = "file")
MessageEditComposer_setStatus :: proc(editor: ^MessageEditComposer, status: string, isError: bool) {
	delete(editor.status)
	editor.status = strings.clone(status)
	editor.statusError = isError
}

MessageEditComposer_deinit :: proc(editor: ^MessageEditComposer) {
	if len(editor.text) > 0 {
		wipeString(string(editor.text[:]))
	}
	delete(editor.text)
	delete(editor.status)
	editor^ = {}
}

// The inline edit open in a conversation, or nil.
State_messageEditIn :: proc(
	state: ^State,
	serverID: int,
	kind: common.ReadMarkerKind,
	conversationID: int,
) -> ^MessageEditComposer {
	editor := &state.messageEditComposer
	if !editor.active ||
	   editor.serverID != serverID ||
	   editor.kind != kind ||
	   editor.conversationID != conversationID {
		return nil
	}
	return editor
}

// Starts editing messageID inline with its current text. "" on success, else why (static).
State_beginMessageEdit :: proc(
	state: ^State,
	serverID: int,
	kind: common.ReadMarkerKind,
	conversationID, messageID: int,
) -> string {
	rights := State_messageChangeRights(state, serverID, kind, conversationID, messageID)
	switch {
	case !rights.found:
		return MESSAGE_NOT_LOADED_MESSAGE
	case rights.deleted:
		return MESSAGE_ALREADY_DELETED_TEXT
	case !rights.own:
		return MESSAGE_EDIT_NOT_OWN_MESSAGE
	case !State_isServerConnected(state, serverID):
		return NOT_CONNECTED_MESSAGE
	case !rights.canEdit:
		facts, _ := State_messageChangeFacts(state, serverID, kind, conversationID, messageID)
		if !facts.opened {
			return MESSAGE_EDIT_NOT_OPENED_MESSAGE
		}
		return ROOM_SEND_NOT_PERMITTED_NOTE
	}
	text, _, _ := State_messageCurrentText(state, serverID, kind, conversationID, messageID)
	MessageEditComposer_deinit(&state.messageEditComposer)
	editor := &state.messageEditComposer
	editor^ = MessageEditComposer {
		active          = true,
		serverID        = serverID,
		kind            = kind,
		conversationID  = conversationID,
		messageID       = messageID,
		focusPending    = true,
	}
	append(&editor.text, text)
	return ""
}

// Closes the inline edit without sending; the conversation's draft was never touched.
State_cancelMessageEdit :: proc(state: ^State) {
	if !state.messageEditComposer.active {
		return
	}
	MessageEditComposer_deinit(&state.messageEditComposer)
	state.messageEditComposer.refocusComposer = true
}

// Up in an empty composer: edits this account's newest message in the conversation that can
// still be edited. "" when one opened, else why (static).
State_editNewestOwnMessage :: proc(
	state: ^State,
	serverID: int,
	kind: common.ReadMarkerKind,
	conversationID: int,
) -> string {
	ids := make([dynamic]int, 0, 32, context.temp_allocator)
	switch kind {
	case .Room:
		cache := State_serverRoomCache(state, serverID)
		for message in ServerRoomCache_roomCache(cache, conversationID).messages {
			append(&ids, message.id)
		}
	case .Direct:
		cache := State_serverDirectCache(state, serverID)
		for message in ServerDirectCache_conversationCache(cache, conversationID).messages {
			append(&ids, message.id)
		}
	}
	#reverse for id in ids {
		rights := State_messageChangeRights(state, serverID, kind, conversationID, id)
		if rights.canEdit {
			return State_beginMessageEdit(state, serverID, kind, conversationID, id)
		}
	}
	return "No message of yours to edit here"
}

// Enter in the edit field. Closes the bar once the edit went out or was queued (or the text did
// not change); otherwise keeps it open with the reason, and an encrypted DM waiting for its
// peer's key sends by itself once the key is there (State_messageEditPoll).
State_submitMessageEdit :: proc(state: ^State) {
	editor := &state.messageEditComposer
	if !editor.active {
		return
	}
	editor.waitingForKey = false
	current, hasFiles, found := State_messageCurrentText(
		state,
		editor.serverID,
		editor.kind,
		editor.conversationID,
		editor.messageID,
	)
	if !found {
		MessageEditComposer_setStatus(editor, MESSAGE_NOT_LOADED_MESSAGE, true)
		return
	}
	// Blank text is empty text (D9: allowed only for a message with files).
	text := string(editor.text[:])
	if len(strings.trim_space(text)) == 0 {
		if !hasFiles {
			MessageEditComposer_setStatus(editor, MESSAGE_EDIT_EMPTY_TEXT, true)
			return
		}
		text = ""
	}
	if text == current {
		State_cancelMessageEdit(state)
		return
	}
	failure: string
	switch editor.kind {
	case .Room:
		failure = State_editRoomMessage(
			state,
			editor.serverID,
			editor.conversationID,
			editor.messageID,
			text,
		)
	case .Direct:
		failure = State_editDirectMessage(
			state,
			editor.serverID,
			editor.conversationID,
			editor.messageID,
			text,
		)
	}
	if len(failure) == 0 {
		State_cancelMessageEdit(state)
		return
	}
	if editor.kind == .Direct && failure == DIRECT_SETTING_UP_TEXT {
		MessageEditComposer_setStatus(editor, failure, false)
		editor.waitingForKey = true
		return
	}
	MessageEditComposer_setStatus(editor, failure, true)
}

// Every frame the edit bar is drawn: sends an encrypted DM edit that waited for its peer's key
// once the key can be encrypted to, and closes the bar when its message became a tombstone or
// left the cache.
State_messageEditPoll :: proc(state: ^State) {
	editor := &state.messageEditComposer
	if !editor.active {
		return
	}
	rights := State_messageChangeRights(
		state,
		editor.serverID,
		editor.kind,
		editor.conversationID,
		editor.messageID,
	)
	if !rights.found || rights.deleted {
		State_cancelMessageEdit(state)
		return
	}
	if editor.waitingForKey && editor.kind == .Direct {
		info := State_e2eePeerKeyInfo(state, editor.serverID, editor.conversationID)
		if info.canEncrypt {
			State_submitMessageEdit(state)
		} else if info.blockReason != .Pending {
			// The key will not come: say why, and let the user cancel.
			editor.waitingForKey = false
			MessageEditComposer_setStatus(
				editor,
				e2eeKeyStateText(
					info,
					State_e2eeUserName(state, editor.serverID, editor.conversationID),
				),
				true,
			)
		}
	}
}

// ── Deleting ─────────────────────────────────────────────────────

// The open Delete message… confirmation. error is owned.
MessageDeleteDialog :: struct {
	open:           bool,
	serverID:       int,
	kind:           common.ReadMarkerKind,
	conversationID: int,
	messageID:      int,
	asAdmin:        bool,
	sent:           bool,
	error:          string,
}

MessageDeleteDialog_deinit :: proc(dialog: ^MessageDeleteDialog) {
	delete(dialog.error)
	dialog^ = {}
}

// Opens the confirmation for a message this account may delete: its own, or (asAdmin) someone
// else's room message as an admin. false when it may not.
State_openMessageDeleteDialog :: proc(
	state: ^State,
	serverID: int,
	kind: common.ReadMarkerKind,
	conversationID, messageID: int,
	asAdmin: bool,
) -> bool {
	rights := State_messageChangeRights(state, serverID, kind, conversationID, messageID)
	if asAdmin ? !rights.canAdminDelete : !rights.canDelete {
		return false
	}
	MessageDeleteDialog_deinit(&state.messageDeleteDialog)
	state.messageDeleteDialog = MessageDeleteDialog {
		open           = true,
		serverID       = serverID,
		kind           = kind,
		conversationID = conversationID,
		messageID      = messageID,
		asAdmin        = asAdmin,
	}
	return true
}

State_closeMessageDeleteDialog :: proc(state: ^State) {
	MessageDeleteDialog_deinit(&state.messageDeleteDialog)
}

// Delete: sends the delete. The dialog stays open with "Waiting for the server…" until the
// tombstone arrives (buildMessageDeleteDialogView.done) or the server refuses.
State_submitMessageDeleteDialog :: proc(state: ^State) {
	dialog := &state.messageDeleteDialog
	if !dialog.open || dialog.sent {
		return
	}
	delete(dialog.error)
	dialog.error = ""
	failure: string
	switch dialog.kind {
	case .Room:
		failure = State_deleteRoomMessage(
			state,
			dialog.serverID,
			dialog.conversationID,
			dialog.messageID,
			asAdmin = dialog.asAdmin,
		)
	case .Direct:
		failure = State_deleteDirectMessage(
			state,
			dialog.serverID,
			dialog.conversationID,
			dialog.messageID,
		)
	}
	if len(failure) > 0 {
		dialog.error = strings.clone(failure)
		return
	}
	dialog.sent = true
}

// Whether a protocol error names messageID (common.messageRefusal's " (message N)").
messageRefusalNames :: proc(message: string, messageID: int) -> bool {
	suffix := fmt.tprintf(" (message %d)", messageID)
	return strings.has_suffix(message, suffix)
}

// A ServerProtocolError on serverID: one naming the message the open delete confirmation sent
// stays in the confirmation (the chat status has it too).
State_messageChangeProtocolError :: proc(state: ^State, serverID: int, message: string) {
	dialog := &state.messageDeleteDialog
	if dialog.open && dialog.sent && dialog.serverID == serverID &&
	   messageRefusalNames(message, dialog.messageID) {
		delete(dialog.error)
		dialog.error = strings.clone(message)
		dialog.sent = false
	}
}

MessageDeleteDialogView :: struct {
	visible:     bool,
	serverID:    int,
	title:       string,
	text:        string,
	status:      string,
	statusError: bool,
	busy:        bool, // Waiting for the server: Delete does nothing
	done:        bool, // The message is a tombstone (or gone): the view closes the dialog
}

// The confirmation's text: what goes with the message (D7, D8), and for an admin's delete what
// members see (D6). Static or in allocator.
messageDeleteDialogText :: proc(
	asAdmin: bool,
	hasFiles: bool,
	allocator := context.temp_allocator,
) -> string {
	what := hasFiles ? "Its text, its files and its edit history" : "Its text and its edit history"
	if asAdmin {
		return fmt.aprintf(
			"Delete this message for everyone? %s are erased from the server, and members " +
			"see \"%s\" in its place. Copies other people already have are not recalled.",
			what,
			MESSAGE_REMOVED_BY_SERVER_TEXT,
			allocator = allocator,
		)
	}
	return fmt.aprintf(
		"Delete this message for everyone? %s are erased from the server, and it reads " +
		"\"%s\" in its place. Copies other people already have are not recalled.",
		what,
		MESSAGE_DELETED_TEXT,
		allocator = allocator,
	)
}

buildMessageDeleteDialogView :: proc(
	state: ^State,
	allocator := context.temp_allocator,
) -> (
	view: MessageDeleteDialogView,
) {
	dialog := &state.messageDeleteDialog
	if !dialog.open {
		return
	}
	rights := State_messageChangeRights(
		state,
		dialog.serverID,
		dialog.kind,
		dialog.conversationID,
		dialog.messageID,
	)
	if !rights.found || rights.deleted {
		view.done = true
		return
	}
	_, hasFiles, _ := State_messageCurrentText(
		state,
		dialog.serverID,
		dialog.kind,
		dialog.conversationID,
		dialog.messageID,
	)
	view.visible = true
	view.serverID = dialog.serverID
	view.title = MESSAGE_DELETE_TITLE
	view.text = messageDeleteDialogText(dialog.asAdmin, hasFiles, allocator)
	switch {
	case len(dialog.error) > 0:
		view.status = dialog.error
		view.statusError = true
	case dialog.sent:
		view.status = MESSAGE_DELETE_WAITING_TEXT
		view.busy = true
	}
	return
}

// ── Edit history ─────────────────────────────────────────────────

// The open edit history popover. anchor is the marker's rect (render pixels) and rect the
// popover's last drawn rect, so the pointer can move from one to the other.
EditHistoryPopover :: struct {
	open:           bool,
	// Opened by a click: stays until a press outside or Esc. Otherwise it closes when the
	// pointer leaves the marker and the popover.
	pinned:         bool,
	serverID:       int,
	kind:           common.ReadMarkerKind,
	conversationID: int,
	messageID:      int,
	anchor:         ui.Rect,
	rect:           ui.Rect,
	// The frame its conversation's transcript was last drawn in: it is drawn only on top of
	// that transcript, and closes on any other screen.
	seenFrame:      u64,
}

// Opens the history of messageID at anchor and asks for its edits (once per session, D14).
State_openEditHistory :: proc(
	state: ^State,
	serverID: int,
	kind: common.ReadMarkerKind,
	conversationID, messageID: int,
	anchor: ui.Rect,
	pinned: bool,
) {
	popover := &state.editHistory
	same :=
		popover.open &&
		popover.serverID == serverID &&
		popover.kind == kind &&
		popover.conversationID == conversationID &&
		popover.messageID == messageID
	if !same {
		popover^ = EditHistoryPopover {
			serverID       = serverID,
			kind           = kind,
			conversationID = conversationID,
			messageID      = messageID,
		}
	}
	popover.open = true
	popover.pinned ||= pinned
	popover.anchor = anchor
	_ = State_fetchMessageEdits(
		state,
		serverID,
		messageEditsKindOf(kind),
		conversationID,
		messageID,
	)
}

State_closeEditHistory :: proc(state: ^State) {
	state.editHistory = {}
}

// One version in the history, oldest first.
EditHistoryRow :: struct {
	label:   string, // "Original" or "Edit N"; static or in the allocator
	time:    string, // "YYYY-MM-DD HH:MM UTC"; in the allocator
	content: string, // Borrowed from State; empty while it waits or failed
	note:    string, // "Waiting for key…" or "This edit could not be verified"; static
	detail:  string, // Why it failed, when the client knows; static
	failed:  bool,
	shown:   bool, // The version the transcript shows
}

EditHistoryView :: struct {
	visible:    bool,
	loading:    bool,
	// The shown version is not the latest edit: it did not verify.
	failedNote: string,
	rows:       []EditHistoryRow,
}

// The history popover's content from the cached message and its edit list. Pure; borrowed
// until State changes.
buildEditHistoryView :: proc(
	state: ^State,
	popover: EditHistoryPopover,
	allocator := context.temp_allocator,
) -> (
	view: EditHistoryView,
) {
	if !popover.open {
		return
	}
	content, timestamp: string
	edit: MessageEditView
	deleted: bool
	switch popover.kind {
	case .Room:
		entry := State_roomMessageEntry(
			state,
			popover.serverID,
			popover.conversationID,
			popover.messageID,
		)
		if entry == nil {
			return
		}
		content, timestamp, edit, deleted =
			entry.content, entry.timestamp, entry.edit, entry.deleted
	case .Direct:
		entry := State_directMessageEntry(
			state,
			popover.serverID,
			popover.conversationID,
			popover.messageID,
		)
		if entry == nil {
			return
		}
		content, timestamp, edit, deleted =
			entry.content, entry.timestamp, entry.edit, entry.deleted
	}
	if deleted {
		// A tombstone has no history (D7).
		return
	}
	view.visible = true
	if edit.status == .Failed {
		view.failedNote = MESSAGE_EDIT_FAILED_NOTE
	}
	edits, statuses, loaded := State_messageEdits(
		state,
		popover.serverID,
		messageEditsKindOf(popover.kind),
		popover.conversationID,
		popover.messageID,
	)
	if !loaded {
		view.loading = true
		return
	}
	rows := make([dynamic]EditHistoryRow, 0, len(edits) + 1, allocator)
	append(
		&rows,
		EditHistoryRow {
			label = MESSAGE_EDIT_HISTORY_ORIGINAL,
			time = attachmentRemovalTimeText(timestamp, allocator),
			content = content,
			shown = edit.shownEditID == 0,
		},
	)
	for item, index in edits {
		row := EditHistoryRow {
			label = fmt.aprintf("Edit %d", index + 1, allocator = allocator),
			time  = attachmentRemovalTimeText(item.timestamp, allocator),
			shown = edit.shownEditID == item.id,
		}
		status := index < len(statuses) ? statuses[index] : MessageEditStatus.None
		switch status {
		case .Verified:
			row.content = item.content
		case .Pending, .None:
			row.note = MESSAGE_EDIT_WAITING_TEXT
		case .Failed:
			row.note = MESSAGE_EDIT_UNVERIFIED_TEXT
			row.failed = true
			// The view knows why only for the latest edit.
			if edit.checkedEditID == item.id {
				row.detail = messageEditFailureText(edit.failure)
			}
		}
		append(&rows, row)
	}
	view.rows = rows[:]
	return
}

// ── Cleanup ──────────────────────────────────────────────────────

State_messageEditUIDeinit :: proc(state: ^State) {
	MessageEditComposer_deinit(&state.messageEditComposer)
	MessageDeleteDialog_deinit(&state.messageDeleteDialog)
	state.editHistory = {}
}

// ── Conversation preview ─────────────────────────────────────────

DIRECT_PREVIEW_MAX_BYTES :: 80
DIRECT_PREVIEW_FILE_TEXT :: "Sent a file"

// What a direct conversation's newest message reads as in the conversation list (the row's
// tooltip): its latest verified version (State_directPreviewSettleEdits keeps lastContent at
// it), "Message deleted" or "Removed by the server" for a tombstone (D6, checked against the
// sender's pin), or the transcript's placeholder. Cut to DIRECT_PREVIEW_MAX_BYTES at a
// character boundary. Static, borrowed or in allocator.
State_directPreviewText :: proc(
	state: ^State,
	serverID: int,
	conversation: DirectConversationEntry,
	allocator := context.temp_allocator,
) -> string {
	if conversation.lastMessageID == 0 {
		return ""
	}
	if conversation.lastDeleted {
		keys := State_directOpenKeys(state, serverID)
		defer DirectOpenKeys_wipe(&keys)
		recipientID := conversation.peerUserId
		if conversation.lastSenderId == conversation.peerUserId {
			recipientID = keys.ownUserID
		}
		check := MessageChangeCheck {
			kind                    = .Direct,
			serverIdentityPublicKey = keys.serverIdentityPublicKey,
			conversationID          = recipientID,
			senderUserID            = conversation.lastSenderId,
			original                = conversation.lastClientMessageId,
			senderIdentity          = State_directIdentityFor(
				state,
				serverID,
				keys,
				conversation.lastSenderId,
			),
		}
		verdict := messageDeleteCheck(check, conversation.lastDeletion)
		return messageDeletedText(MessageEditView{deleteStatus = verdict})
	}
	switch conversation.security.protection {
	case .Pending:
		return len(conversation.lastEnvelope) > 0 ? DIRECT_OPENING_TEXT : DIRECT_CHECKING_TEXT
	case .Failed:
		return DIRECT_UNDECRYPTABLE_TEXT
	case .Hidden:
		return ""
	case .Signed, .Encrypted:
	}
	text := conversation.lastContent
	if len(strings.trim_space(text)) == 0 {
		return len(conversation.lastAttachments) > 0 ? DIRECT_PREVIEW_FILE_TEXT : ""
	}
	if newline := strings.index_any(text, "\r\n"); newline >= 0 {
		text = text[:newline]
	}
	if len(text) > DIRECT_PREVIEW_MAX_BYTES {
		cut := ui.prevGraphemeBoundary(text, DIRECT_PREVIEW_MAX_BYTES + 1)
		return fmt.aprintf("%s…", text[:cut], allocator = allocator)
	}
	return text
}
