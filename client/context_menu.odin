package client

import "../common"
import "core:fmt"
import "core:strings"
import "core:time"
import "ui"

// Context menus (right-click). State.contextMenu holds what the open menu is about, as a
// target with IDs only; buildContextMenu turns it into entries from State each frame, so the
// entries and their enabled state are testable without a window, and a target that no longer
// exists (a deleted room, a removed server, a message that left the cache) closes the menu.
// view_context_menu.odin draws it in a ui overlay and calls State_runContextMenuAction for the
// chosen entry (State_setContextMenuVolume for the voice participant's volume slider). The
// menus offer only actions the client already has. Admin entries are shown to admins only:
// Edit room… and Delete room… on channels, and Rename…, Make admin / Remove admin, Kick… and
// Ban… / Unban on accounts (admin_ui.odin), disabled where the server refuses them (D6).

ChannelMenuTarget :: struct {
	serverID: int,
	roomID:   int,
}

// A row in the sidebar's Direct Messages section.
ConversationMenuTarget :: struct {
	serverID:   int,
	peerUserID: int,
}

// A row in the sidebar's Members section.
MemberMenuTarget :: struct {
	serverID: int,
	userID:   int,
}

VoiceParticipantMenuTarget :: struct {
	serverID: int,
	roomID:   int,
	userID:   int,
}

// A message in a room (kind .Room, conversationID the room) or in a direct conversation
// (kind .Direct, conversationID the peer).
MessageMenuTarget :: struct {
	serverID:       int,
	kind:           common.ReadMarkerKind,
	conversationID: int,
	messageID:      int,
}

// The sender name above a message: the member entries for whoever sent it.
SenderMenuTarget :: struct {
	serverID:       int,
	kind:           common.ReadMarkerKind,
	conversationID: int,
	messageID:      int,
}

// A file card under a message (attachments plan F4): file index of messageID.
AttachmentMenuTarget :: struct {
	serverID:       int,
	kind:           common.ReadMarkerKind,
	conversationID: int,
	messageID:      int,
	index:          int,
}

// A server's button in the rail.
ServerMenuTarget :: struct {
	serverID: int,
}

// Any text input: the composer or a settings field.
TextFieldMenuTarget :: struct {
	inputID: ui.ID,
}

ContextMenuTarget :: union {
	ChannelMenuTarget,
	ConversationMenuTarget,
	MemberMenuTarget,
	VoiceParticipantMenuTarget,
	MessageMenuTarget,
	SenderMenuTarget,
	ServerMenuTarget,
	TextFieldMenuTarget,
	AttachmentMenuTarget,
}

ContextMenuState :: struct {
	target:          ContextMenuTarget, // nil while no menu is open
	position:        ui.Vec2, // Where the right press was, in render pixels
	// The transcript's selected text when a message menu opened (owned), for "Copy selected
	// text"; "" when nothing was selected.
	selectionText:   string,
	// "Remove server…" was clicked once: the entry now reads "Click again to remove".
	confirmRemove:   bool,
	// "Leave room…" was clicked once: the entry now reads "Click again to leave".
	confirmLeave:    bool,
	// "Invite to room…" was clicked: the user menu lists the rooms to invite to instead.
	inviteOpen:      bool,
	// Each menu opened gets a new number, so the toolkit treats it as a new menu (no carried
	// highlight, and the press that opened it never counts as a press outside it).
	serial:          int,
	// Requested by a widget this frame; viewContextMenu opens it after drawing. The selection
	// is temp-allocated.
	pending:         ContextMenuTarget,
	pendingPosition: ui.Vec2,
	pendingSelection: string,
}

ContextMenuState_deinit :: proc(menu: ^ContextMenuState) {
	delete(menu.selectionText)
	menu^ = {}
}

// Records a right-click for viewContextMenu to open once the frame is drawn. A later request
// in the same frame replaces an earlier one.
State_requestContextMenu :: proc(
	state: ^State,
	target: ContextMenuTarget,
	position: ui.Vec2,
	selectionText := "",
) {
	state.contextMenu.pending = target
	state.contextMenu.pendingPosition = position
	state.contextMenu.pendingSelection = selectionText
}

// Opens a menu on target, replacing any open one.
State_openContextMenu :: proc(
	state: ^State,
	target: ContextMenuTarget,
	position: ui.Vec2,
	selectionText := "",
) {
	State_closeContextMenu(state)
	menu := &state.contextMenu
	menu.target = target
	menu.position = position
	menu.selectionText = strings.clone(selectionText)
	menu.serial += 1
}

State_closeContextMenu :: proc(state: ^State) {
	menu := &state.contextMenu
	delete(menu.selectionText)
	menu.selectionText = ""
	menu.target = nil
	menu.confirmRemove = false
	menu.confirmLeave = false
	menu.inviteOpen = false
}

// What a menu entry does. The values name the entries' widget IDs (idOf("menu-item", value)),
// so new actions go at the end.
ContextMenuAction :: enum u8 {
	None,
	MarkRead,
	JoinVoice,
	LeaveVoice,
	CopyRoomName,
	EditRoom,
	DeleteRoom,
	SendMessage,
	CopyName,
	CopyMessage,
	CopySelection,
	Quote,
	RetryConnection,
	CopyAddress,
	RemoveServer,
	ConfirmRemoveServer,
	Cut,
	Copy,
	Paste,
	SelectAll,
	ServerSettings,
	AdminRename,
	MakeAdmin,
	RemoveAdmin,
	AdminKick,
	AdminBan,
	AdminUnban,
	MuteForMe,
	UnmuteForMe,
	Volume,
	// Room access modes (protocol 15).
	RoomMembers,
	LeaveRoom,
	ConfirmLeaveRoom,
	InviteToRoom,
	InviteToRoomPick, // One per room: ContextMenuEntry.roomID names it
	VerifyEncryption,
	// Roles (protocol 23): the account's roles, shown disabled to everyone, and an admin's
	// Roles… (the role picker in Server settings → Admin).
	RoleNames,
	MemberRoles,
	// Attachments (F4): a file card's Save…, Copy file name, and an admin's Remove
	// attachment… (D22).
	SaveAttachment,
	CopyFileName,
	RemoveAttachment,
}

// Item keys of the Invite to room… list: this plus the room ID, above every action's value.
CONTEXT_MENU_ROOM_KEY_BASE :: 1 << 20

ContextMenuEntry :: struct {
	action:          ContextMenuAction,
	label:           string, // Static, or in the view allocator
	enabled:         bool,
	danger:          bool,
	separatorBefore: bool,
	// A slider row instead of an item (Volume): value is the current linear volume.
	slider:          bool,
	value:           f32,
	// InviteToRoomPick: the room.
	roomID:          int,
}

// What the view knows that State does not: a right-clicked text input's facts (from the ui
// context) and whether the clipboard holds text.
ContextMenuFacts :: struct {
	textField:        ui.TextFieldFacts,
	textFieldDrawn:   bool,
	clipboardHasText: bool,
}

ContextMenuView :: struct {
	visible: bool, // false when nothing is open or the target is gone
	entries: []ContextMenuEntry,
}

CONTEXT_MENU_CONFIRM_REMOVE_TEXT :: "Click again to remove"
CONTEXT_MENU_CONFIRM_LEAVE_TEXT :: "Click again to leave"

// Marking a conversation read whose newest messages are not loaded sends this as the message
// ID: the server clamps a mark-read to the conversation's newest message.
CONTEXT_MENU_MARK_ALL_READ_ID :: max(i64)

// Builds the open menu's entries from State. Pure: nothing changes, and the result is valid
// until State next changes.
buildContextMenu :: proc(
	state: ^State,
	facts: ContextMenuFacts,
	allocator := context.temp_allocator,
) -> (
	view: ContextMenuView,
) {
	menu := &state.contextMenu
	entries := make([dynamic]ContextMenuEntry, 0, 8, allocator)
	switch target in menu.target {
	case nil:
		return
	case ChannelMenuTarget:
		room := State_roomSummary(state, target.serverID, target.roomID)
		if room == nil {
			return
		}
		connected := State_isServerConnected(state, target.serverID)
		append(
			&entries,
			ContextMenuEntry {
				action = .MarkRead,
				label = "Mark as read",
				enabled = connected && room.unreadCount > 0,
			},
		)
		switch roomVoiceHeaderAction(state, target.serverID, target.roomID) {
		case .Join:
			append(
				&entries,
				ContextMenuEntry{action = .JoinVoice, label = "Join voice", enabled = true},
			)
		case .Leave:
			append(
				&entries,
				ContextMenuEntry{action = .LeaveVoice, label = "Leave voice", enabled = true},
			)
		case .None:
			// A text-only room has no voice to join; otherwise voice is just unavailable now.
			if State_roomAllowsVoice(state, target.serverID, target.roomID) {
				append(&entries, ContextMenuEntry{action = .JoinVoice, label = "Join voice"})
			}
		}
		append(
			&entries,
			ContextMenuEntry{action = .CopyRoomName, label = "Copy room name", enabled = true},
		)
		// Protocol 15: the Members page for members of a non-public room and admins, and
		// Leave room for members of a non-public room (it takes a second click).
		rights := roomMemberRights(state, target.serverID, target.roomID)
		if rights.canView {
			append(
				&entries,
				ContextMenuEntry {
					action = .RoomMembers,
					label = "Members…",
					enabled = connected,
				},
			)
		}
		if rights.canLeave {
			append(
				&entries,
				ContextMenuEntry {
					action = menu.confirmLeave ? .ConfirmLeaveRoom : .LeaveRoom,
					label = menu.confirmLeave ? CONTEXT_MENU_CONFIRM_LEAVE_TEXT : "Leave room…",
					enabled = connected,
					danger = true,
					separatorBefore = true,
				},
			)
		}
		// The server checks ManageRooms (protocol 24: or the room's EditRoom for an edit) on
		// every request; this only decides what is offered.
		if State_canEditRoom(state, target.serverID, target.roomID) &&
		   target.serverID == state.selected_server_id {
			append(
				&entries,
				ContextMenuEntry {
					action = .EditRoom,
					label = "Edit room…",
					enabled = true,
					separatorBefore = true,
				},
			)
			if State_hasPermission(state, target.serverID, .ManageRooms) {
				append(
					&entries,
					ContextMenuEntry {
						action = .DeleteRoom,
						label = "Delete room…",
						enabled = true,
						danger = true,
					},
				)
			}
		}
	case ConversationMenuTarget:
		if !contextMenuUserKnown(state, target.serverID, target.peerUserID) {
			return
		}
		if menu.inviteOpen {
			contextMenuAppendInviteEntries(state, &entries, target.serverID, allocator)
			break
		}
		contextMenuAppendUserEntries(state, &entries, target.serverID, target.peerUserID)
		contextMenuAppendAdminEntries(state, &entries, target.serverID, target.peerUserID)
	case MemberMenuTarget:
		if !contextMenuUserKnown(state, target.serverID, target.userID) {
			return
		}
		if menu.inviteOpen {
			contextMenuAppendInviteEntries(state, &entries, target.serverID, allocator)
			break
		}
		contextMenuAppendUserEntries(state, &entries, target.serverID, target.userID)
		contextMenuAppendAdminEntries(state, &entries, target.serverID, target.userID)
	case VoiceParticipantMenuTarget:
		if _, found := contextMenuVoiceParticipant(state, target); !found {
			return
		}
		if menu.inviteOpen {
			contextMenuAppendInviteEntries(state, &entries, target.serverID, allocator)
			break
		}
		selfUserID := State_selfUserID(state, target.serverID)
		append(
			&entries,
			ContextMenuEntry {
				action = .SendMessage,
				label = "Send message",
				enabled = target.userID != selfUserID,
			},
			ContextMenuEntry{action = .CopyName, label = "Copy name", enabled = true},
		)
		contextMenuAppendInviteEntry(state, &entries, target.serverID, target.userID)
		// Volume and Mute for me (issue 47) are local: only this client plays them differently.
		if target.userID != selfUserID {
			volume, muted := State_userVoice(state, target.serverID, target.userID)
			append(
				&entries,
				ContextMenuEntry {
					action = muted ? .UnmuteForMe : .MuteForMe,
					label = muted ? "Unmute for me" : "Mute for me",
					enabled = true,
					separatorBefore = true,
				},
				ContextMenuEntry {
					action = .Volume,
					label = fmt.aprintf(
						"Volume: %d %%",
						int(volume * 100 + 0.5),
						allocator = allocator,
					),
					enabled = true,
					slider = true,
					value = volume,
				},
			)
		}
		contextMenuAppendAdminEntries(state, &entries, target.serverID, target.userID)
	case MessageMenuTarget:
		message, found := contextMenuMessage(
			state,
			target.serverID,
			target.kind,
			target.conversationID,
			target.messageID,
		)
		if !found {
			return
		}
		append(
			&entries,
			ContextMenuEntry{action = .CopyMessage, label = "Copy message", enabled = true},
		)
		if len(menu.selectionText) > 0 {
			append(
				&entries,
				ContextMenuEntry {
					action = .CopySelection,
					label = "Copy selected text",
					enabled = true,
				},
			)
		}
		append(
			&entries,
			ContextMenuEntry{action = .CopyName, label = "Copy name", enabled = true},
			ContextMenuEntry{action = .Quote, label = "Quote", enabled = true},
		)
		// In a direct conversation the sender's conversation is the one already open.
		selfUserID := State_selfUserID(state, target.serverID)
		if target.kind == .Room && message.senderID != selfUserID {
			append(
				&entries,
				ContextMenuEntry {
					action = .SendMessage,
					label = "Send message to sender",
					enabled = true,
					separatorBefore = true,
				},
			)
		}
	case SenderMenuTarget:
		message, found := contextMenuMessage(
			state,
			target.serverID,
			target.kind,
			target.conversationID,
			target.messageID,
		)
		if !found {
			return
		}
		if menu.inviteOpen {
			contextMenuAppendInviteEntries(state, &entries, target.serverID, allocator)
			break
		}
		contextMenuAppendUserEntries(state, &entries, target.serverID, message.senderID)
		contextMenuAppendAdminEntries(state, &entries, target.serverID, message.senderID)
	case ServerMenuTarget:
		if _, found := State_serverConfig(state, target.serverID); !found {
			return
		}
		append(
			&entries,
			ContextMenuEntry{action = .ServerSettings, label = "Server settings", enabled = true},
		)
		if !State_isServerConnected(state, target.serverID) {
			append(
				&entries,
				ContextMenuEntry{action = .RetryConnection, label = "Retry now", enabled = true},
			)
		}
		append(
			&entries,
			ContextMenuEntry{action = .CopyAddress, label = "Copy address", enabled = true},
		)
		if menu.confirmRemove {
			append(
				&entries,
				ContextMenuEntry {
					action = .ConfirmRemoveServer,
					label = CONTEXT_MENU_CONFIRM_REMOVE_TEXT,
					enabled = true,
					danger = true,
					separatorBefore = true,
				},
			)
		} else {
			append(
				&entries,
				ContextMenuEntry {
					action = .RemoveServer,
					label = "Remove server…",
					enabled = true,
					danger = true,
					separatorBefore = true,
				},
			)
		}
	case AttachmentMenuTarget:
		file, found := State_attachmentFile(state, attachmentMenuRef(target))
		if !found {
			return
		}
		append(
			&entries,
			ContextMenuEntry {
				action = .SaveAttachment,
				label = "Save…",
				enabled = !file.removed,
			},
			ContextMenuEntry{action = .CopyFileName, label = "Copy file name", enabled = true},
		)
		// Admins only, with no assignable permission (D22); the server checks the role.
		if State_isServerAdmin(state, target.serverID) {
			append(
				&entries,
				ContextMenuEntry {
					action = .RemoveAttachment,
					label = "Remove attachment…",
					enabled = !file.removed && State_isServerConnected(state, target.serverID),
					danger = true,
					separatorBefore = true,
				},
			)
		}
	case TextFieldMenuTarget:
		if !facts.textFieldDrawn {
			return
		}
		selection := facts.textField.hasSelection
		append(
			&entries,
			ContextMenuEntry{action = .Cut, label = "Cut", enabled = selection},
			ContextMenuEntry{action = .Copy, label = "Copy", enabled = selection},
			ContextMenuEntry{action = .Paste, label = "Paste", enabled = facts.clipboardHasText},
			ContextMenuEntry {
				action = .SelectAll,
				label = "Select all",
				enabled = facts.textField.hasText,
				separatorBefore = true,
			},
		)
	}
	view.visible = true
	view.entries = entries[:]
	return
}

// Send message, Mark as read (when a conversation with them exists), and Copy name: the
// entries for a conversation row, a member row, and a sender name.
@(private = "file")
contextMenuAppendUserEntries :: proc(
	state: ^State,
	entries: ^[dynamic]ContextMenuEntry,
	serverID, userID: int,
) {
	isSelf := userID == State_selfUserID(state, serverID)
	append(
		entries,
		ContextMenuEntry{action = .SendMessage, label = "Send message", enabled = !isSelf},
	)
	if summary := State_directSummary(state, serverID, userID); summary != nil && !isSelf {
		append(
			entries,
			ContextMenuEntry {
				action = .MarkRead,
				label = "Mark as read",
				enabled = State_isServerConnected(state, serverID) && summary.unreadCount > 0,
			},
		)
	}
	append(entries, ContextMenuEntry{action = .CopyName, label = "Copy name", enabled = true})
	// The safety number dialog (e2ee-design.md 3.5); yourself has nothing to compare.
	if !isSelf {
		append(
			entries,
			ContextMenuEntry {
				action = .VerifyEncryption,
				label = "Verify encryption…",
				enabled = true,
			},
		)
	}
	contextMenuAppendInviteEntry(state, entries, serverID, userID)
}

// Invite to room… (protocol 15) for someone else, when this account may add people to a room.
@(private = "file")
contextMenuAppendInviteEntry :: proc(
	state: ^State,
	entries: ^[dynamic]ContextMenuEntry,
	serverID, userID: int,
) {
	if userID == State_selfUserID(state, serverID) {
		return
	}
	if len(State_invitableRooms(state, serverID)) == 0 {
		return
	}
	append(
		entries,
		ContextMenuEntry {
			action = .InviteToRoom,
			label = "Invite to room…",
			enabled = State_isServerConnected(state, serverID),
		},
	)
}

// The Invite to room… list: one entry per room this account may add people to.
@(private = "file")
contextMenuAppendInviteEntries :: proc(
	state: ^State,
	entries: ^[dynamic]ContextMenuEntry,
	serverID: int,
	allocator := context.temp_allocator,
) {
	for room in State_invitableRooms(state, serverID, allocator) {
		append(
			entries,
			ContextMenuEntry {
				action = .InviteToRoomPick,
				label = fmt.aprintf("Invite to #%s", room.name, allocator = allocator),
				enabled = true,
				roomID = room.id,
			},
		)
	}
}

// The account's roles other than admin, as one disabled line ("Roles: mods, hosts") that
// everyone sees (protocol 23); then, for an admin of serverID and an account the directory
// lists, Rename…, Make admin / Remove admin, Kick…, Ban… / Unban and Roles…, disabled where the
// server refuses them (buildAdminUserControls).
@(private = "file")
contextMenuAppendAdminEntries :: proc(
	state: ^State,
	entries: ^[dynamic]ContextMenuEntry,
	serverID, userID: int,
) {
	if names := State_userRoleNames(state, serverID, userID); len(names) > 0 {
		append(
			entries,
			ContextMenuEntry {
				action = .RoleNames,
				label = fmt.tprintf("Roles: %s", strings.join(names, ", ", context.temp_allocator)),
				separatorBefore = true,
			},
		)
	}
	if !State_isServerAdmin(state, serverID) {
		return
	}
	controls, known := buildAdminUserControls(state, serverID, userID)
	if !known {
		return
	}
	// Roles… only once the server has a role to give.
	assignable := false
	for role in State_roles(state, serverID) {
		assignable ||= !role.builtin
	}
	defer if assignable {
		append(entries, ContextMenuEntry{action = .MemberRoles, label = "Roles…", enabled = true})
	}
	append(
		entries,
		ContextMenuEntry {
			action = .AdminRename,
			label = controls.rename.label,
			enabled = controls.rename.enabled,
			separatorBefore = true,
		},
		ContextMenuEntry {
			action = controls.grant ? .MakeAdmin : .RemoveAdmin,
			label = controls.role.label,
			enabled = controls.role.enabled,
		},
		ContextMenuEntry {
			action = .AdminKick,
			label = controls.kick.label,
			enabled = controls.kick.enabled,
			danger = true,
		},
		ContextMenuEntry {
			action = controls.banning ? .AdminBan : .AdminUnban,
			label = controls.ban.label,
			enabled = controls.ban.enabled,
			danger = controls.banning,
		},
	)
}

// Whether the server's directory or conversation list knows the account.
@(private = "file")
contextMenuUserKnown :: proc(state: ^State, serverID, userID: int) -> bool {
	index := State_serverDirectCacheIndex(state^, serverID)
	if index < 0 || userID <= 0 {
		return false
	}
	cache := &state.serverDirectCaches[index]
	return(
		ServerDirectCache_userIndex(cache^, userID) >= 0 ||
		ServerDirectCache_conversationIndex(cache^, userID) >= 0 \
	)
}

@(private = "file")
contextMenuVoiceParticipant :: proc(
	state: ^State,
	target: VoiceParticipantMenuTarget,
) -> (
	common.VoiceParticipant,
	bool,
) {
	for participant in State_voiceRoomParticipants(state, target.serverID, target.roomID) {
		if participant.userId == target.userID {
			return participant, true
		}
	}
	return {}, false
}

// A cached message, borrowed from the room or direct-message cache.
ContextMenuMessage :: struct {
	senderID:       int,
	senderNickname: string,
	content:        string,
}

@(private = "file")
contextMenuMessage :: proc(
	state: ^State,
	serverID: int,
	kind: common.ReadMarkerKind,
	conversationID, messageID: int,
) -> (
	ContextMenuMessage,
	bool,
) {
	switch kind {
	case .Room:
		cacheIndex := State_serverRoomCacheIndex(state^, serverID)
		if cacheIndex < 0 {
			return {}, false
		}
		cache := &state.server_room_caches[cacheIndex]
		roomIndex := ServerRoomCache_roomCacheIndex(cache^, conversationID)
		if roomIndex < 0 {
			return {}, false
		}
		for message in cache.roomCaches[roomIndex].messages {
			if message.id == messageID {
				return {message.senderId, message.senderNickname, message.content}, true
			}
		}
	case .Direct:
		cacheIndex := State_serverDirectCacheIndex(state^, serverID)
		if cacheIndex < 0 {
			return {}, false
		}
		cache := &state.serverDirectCaches[cacheIndex]
		conversationIndex := ServerDirectCache_conversationCacheIndex(cache^, conversationID)
		if conversationIndex < 0 {
			return {}, false
		}
		for message in cache.caches[conversationIndex].messages {
			if message.id == messageID {
				return {message.senderId, message.senderNickname, message.content}, true
			}
		}
	}
	return {}, false
}

// The name shown for an account: "You" for yourself, its directory nickname, the nickname
// fallback, or "User N".
@(private = "file")
contextMenuUserName :: proc(state: ^State, serverID, userID: int, fallback: string) -> string {
	nickname := fallback
	if index := State_serverDirectCacheIndex(state^, serverID); index >= 0 {
		if known := ServerDirectCache_peerNickname(&state.serverDirectCaches[index], userID);
		   len(known) > 0 {
			nickname = known
		}
	}
	return userLabel(nickname, userID)
}

// What the view does after an action that needs the ui context or the clipboard.
ContextMenuEffect :: struct {
	copyText:    string, // Put on the clipboard (temp-allocated or borrowed from State)
	textCommand: ui.TextMenuCommand, // For the target text input
	textInputID: ui.ID,
	focusInput:  ui.ID, // A composer that should get focus with the caret at the end
	keepOpen:    bool, // The menu stays open (Remove server… only arms itself)
	// Save… on a file card: the view opens the save dialog for it (it needs the window).
	saveFile:    Maybe(AttachmentFileRef),
}

attachmentMenuRef :: proc(target: AttachmentMenuTarget) -> AttachmentFileRef {
	return AttachmentFileRef {
		serverID = target.serverID,
		kind = target.kind,
		conversationID = target.conversationID,
		messageID = target.messageID,
		index = target.index,
	}
}

// Runs the open menu's action. The menu closes afterwards unless effect.keepOpen is set.
State_runContextMenuAction :: proc(
	state: ^State,
	action: ContextMenuAction,
	now: time.Tick,
	roomID := 0,
) -> (
	effect: ContextMenuEffect,
) {
	menu := &state.contextMenu
	switch target in menu.target {
	case nil:
	case ChannelMenuTarget:
		#partial switch action {
		case .MarkRead:
			State_markConversationReadAll(state, .Room, target.serverID, target.roomID, now)
		case .JoinVoice:
			State_joinVoice(state, target.serverID, target.roomID)
		case .LeaveVoice:
			State_leaveVoice(state)
		case .CopyRoomName:
			if room := State_roomSummary(state, target.serverID, target.roomID); room != nil {
				effect.copyText = room.name
			}
		case .EditRoom:
			if target.serverID == state.selected_server_id {
				State_openRoomEditor(state, target.roomID)
			}
		case .DeleteRoom:
			// The form opens with its delete armed: the next click on "Confirm delete" sends.
			if target.serverID == state.selected_server_id {
				State_openRoomEditorForDelete(state, target.roomID)
			}
		case .RoomMembers:
			State_openRoomMembers(state, target.serverID, target.roomID)
		case .LeaveRoom:
			menu.confirmLeave = true
			effect.keepOpen = true
		case .ConfirmLeaveRoom:
			if errorMessage := State_leaveRoom(state, target.serverID, target.roomID);
			   len(errorMessage) > 0 {
				State_setChatStatus(state, errorMessage)
			}
		}
	case ConversationMenuTarget:
		effect = State_runUserMenuAction(
			state,
			action,
			target.serverID,
			target.peerUserID,
			"",
			now,
			roomID,
		)
	case MemberMenuTarget:
		effect = State_runUserMenuAction(
			state,
			action,
			target.serverID,
			target.userID,
			"",
			now,
			roomID,
		)
	case VoiceParticipantMenuTarget:
		participant, _ := contextMenuVoiceParticipant(state, target)
		effect = State_runUserMenuAction(
			state,
			action,
			target.serverID,
			target.userID,
			participant.nickname,
			now,
			roomID,
		)
	case SenderMenuTarget:
		message, found := contextMenuMessage(
			state,
			target.serverID,
			target.kind,
			target.conversationID,
			target.messageID,
		)
		if found {
			effect = State_runUserMenuAction(
				state,
				action,
				target.serverID,
				message.senderID,
				message.senderNickname,
				now,
				roomID,
			)
		}
	case MessageMenuTarget:
		message, found := contextMenuMessage(
			state,
			target.serverID,
			target.kind,
			target.conversationID,
			target.messageID,
		)
		if !found {
			break
		}
		#partial switch action {
		case .CopyMessage:
			effect.copyText = message.content
		case .CopySelection:
			effect.copyText = fmt.tprint(menu.selectionText)
		case .CopyName:
			effect.copyText = contextMenuUserName(
				state,
				target.serverID,
				message.senderID,
				message.senderNickname,
			)
		case .Quote:
			effect.focusInput = State_quoteIntoDraft(state, target, message.content)
		case .SendMessage:
			State_openDirectConversation(state, target.serverID, message.senderID)
		}
	case ServerMenuTarget:
		server, found := State_serverConfig(state, target.serverID)
		if !found {
			break
		}
		#partial switch action {
		case .ServerSettings:
			State_closeContextMenu(state)
			State_openServerSettings(state, target.serverID)
			return
		case .RetryConnection:
			State_retryConnection(state, target.serverID)
		case .CopyAddress:
			effect.copyText = fmt.tprintf("%s:%d", server.host, server.port)
		case .RemoveServer:
			menu.confirmRemove = true
			effect.keepOpen = true
		case .ConfirmRemoveServer:
			State_closeContextMenu(state)
			State_settingsRemoveServer(state, target.serverID)
			return
		}
	case AttachmentMenuTarget:
		ref := attachmentMenuRef(target)
		file, found := State_attachmentFile(state, ref)
		if !found {
			break
		}
		#partial switch action {
		case .SaveAttachment:
			effect.saveFile = ref
		case .CopyFileName:
			effect.copyText = fmt.tprint(file.name)
		case .RemoveAttachment:
			State_openAttachmentRemoveDialog(state, ref)
		}
	case TextFieldMenuTarget:
		effect.textInputID = target.inputID
		#partial switch action {
		case .Cut:
			effect.textCommand = .Cut
		case .Copy:
			effect.textCommand = .Copy
		case .Paste:
			effect.textCommand = .Paste
		case .SelectAll:
			effect.textCommand = .SelectAll
		}
	}
	if !effect.keepOpen {
		State_closeContextMenu(state)
	}
	return
}

@(private = "file")
State_runUserMenuAction :: proc(
	state: ^State,
	action: ContextMenuAction,
	serverID, userID: int,
	fallbackName: string,
	now: time.Tick,
	roomID := 0,
) -> (
	effect: ContextMenuEffect,
) {
	#partial switch action {
	case .InviteToRoom:
		state.contextMenu.inviteOpen = true
		effect.keepOpen = true
	case .InviteToRoomPick:
		if errorMessage := State_addRoomMember(state, serverID, roomID, userID);
		   len(errorMessage) > 0 {
			State_setChatStatus(state, errorMessage)
		}
	case .SendMessage:
		State_openDirectConversation(state, serverID, userID)
	case .MarkRead:
		State_markConversationReadAll(state, .Direct, serverID, userID, now)
	case .CopyName:
		effect.copyText = contextMenuUserName(state, serverID, userID, fallbackName)
	case .AdminRename:
		State_openAdminConfirm(state, serverID, .Rename, userID)
	case .AdminKick:
		State_openAdminConfirm(state, serverID, .Kick, userID)
	case .AdminBan:
		State_openAdminConfirm(state, serverID, .Ban, userID)
	case .MakeAdmin:
		State_adminSetRole(state, serverID, userID, true)
	case .RemoveAdmin:
		State_adminSetRole(state, serverID, userID, false)
	case .AdminUnban:
		State_adminUnban(state, serverID, userID)
	case .MemberRoles:
		State_openMemberRoles(state, serverID, userID)
	case .MuteForMe:
		State_setUserVoiceMuted(state, serverID, userID, true)
	case .UnmuteForMe:
		State_setUserVoiceMuted(state, serverID, userID, false)
	case .VerifyEncryption:
		State_openVerifyDialog(state, serverID, userID)
	}
	return
}

// The voice participant menu's volume slider moved (persist false while it is dragged) or was
// let go (persist true, which saves the config). The menu stays open.
State_setContextMenuVolume :: proc(state: ^State, volume: f32, persist: bool) -> bool {
	target, isParticipant := state.contextMenu.target.(VoiceParticipantMenuTarget)
	if !isParticipant || target.userID == State_selfUserID(state, target.serverID) {
		return false
	}
	return State_setUserVoiceVolume(state, target.serverID, target.userID, volume, persist)
}

// Marks a whole conversation read, including messages that are not loaded: up to its newest
// known message, or with CONTEXT_MENU_MARK_ALL_READ_ID (which the server clamps) when the
// newest messages were never loaded. The answer is ServerReadMarker, like every mark-read.
State_markConversationReadAll :: proc(
	state: ^State,
	kind: common.ReadMarkerKind,
	serverID, conversationID: int,
	now: time.Tick,
) -> bool {
	newest := State_newestLoadedMessageID(state, kind, serverID, conversationID)
	if kind == .Direct {
		if summary := State_directSummary(state, serverID, conversationID); summary != nil {
			newest = max(newest, summary.lastMessageID)
		}
	}
	if newest > State_lastReadMessageID(state, kind, serverID, conversationID) {
		return State_markConversationRead(state, kind, serverID, conversationID, newest, now)
	}
	// The unread messages are newer than anything loaded. The send bookkeeping keeps what it
	// had: the sentinel says nothing about which loaded message was marked, and the automatic
	// mark-read of the viewed conversation compares loaded IDs with it.
	previous := State_readMarkerSendState(state, kind, serverID, conversationID).sentMessageID
	sent := State_markConversationRead(
		state,
		kind,
		serverID,
		conversationID,
		int(CONTEXT_MENU_MARK_ALL_READ_ID),
		now,
	)
	State_readMarkerSendState(state, kind, serverID, conversationID).sentMessageID = previous
	return sent
}

// The composer's widget ID for a conversation (view.odin, view_direct.odin).
composerInputID :: proc(serverID: int, kind: common.ReadMarkerKind, conversationID: int) -> ui.ID {
	if kind == .Direct {
		return ui.idOf("dm-input", serverID, conversationID)
	}
	return ui.idOf("room-input", serverID, conversationID)
}

// Appends the message to the conversation's draft as "> " lines, on a line of its own, and
// returns the composer to focus. What does not fit in common.CHAT_MESSAGE_MAX_BYTES is cut at a
// character boundary.
State_quoteIntoDraft :: proc(state: ^State, target: MessageMenuTarget, content: string) -> ui.ID {
	draft: ^[dynamic]u8
	switch target.kind {
	case .Room:
		cache := State_serverRoomCache(state, target.serverID)
		draft = &ServerRoomCache_roomCache(cache, target.conversationID).draft
	case .Direct:
		cache := State_serverDirectCache(state, target.serverID)
		draft = &ServerDirectCache_conversationCache(cache, target.conversationID).draft
	}
	builder := strings.builder_make(context.temp_allocator)
	if len(draft) > 0 && draft[len(draft) - 1] != '\n' {
		strings.write_byte(&builder, '\n')
	}
	remaining := content
	for line in strings.split_lines_iterator(&remaining) {
		strings.write_string(&builder, "> ")
		strings.write_string(&builder, line)
		strings.write_byte(&builder, '\n')
	}
	quote := strings.to_string(builder)
	room := max(0, common.CHAT_MESSAGE_MAX_BYTES - len(draft))
	if len(quote) > room {
		quote = quote[:ui.prevGraphemeBoundary(quote, room + 1)]
	}
	append(draft, quote)
	return composerInputID(target.serverID, target.kind, target.conversationID)
}
