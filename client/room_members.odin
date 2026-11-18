package client

import "../common"
import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"

// Room access modes (protocol 15): a room's Members page, inviting, leaving, and the admin's list
// of every room. The server decides who may do what (design 5.1); the client only offers what
// the room's mode allows (roomMemberRights) and shows the server's answer:
//
// - Public: every account is a member. Nobody adds; admins remove; nobody leaves.
// - Member invite: members and admins add; admins remove; members leave.
// - Admin invite: admins add; admins remove; members leave.
//
// The Members page is the room editor in mode Members (room_admin.odin), so it shares the main
// pane, the pending request, and the rules that close it. Members of a non-public room open it
// too, not only admins. Every request goes through roomMemberSendBridge (tests swap it under
// roomMemberSendBridgeTestMutex).

RoomMemberRequestKind :: enum u8 {
	Add,
	Remove,
	Leave,
	Fetch,
	AdminList,
}

RoomMemberRequest :: struct {
	kind:   RoomMemberRequestKind,
	roomID: int,
	userID: int,
}

RoomMemberSendBridge :: #type proc(
	transport: ^ClientServerTransport,
	request: RoomMemberRequest,
) -> bool

roomMemberSendBridge: RoomMemberSendBridge = ClientServerTransport_sendRoomMemberRequest

ClientServerTransport_sendRoomMemberRequest :: proc(
	transport: ^ClientServerTransport,
	request: RoomMemberRequest,
) -> bool {
	switch request.kind {
	case .Add:
		return ClientServerTransport_addRoomMember(transport, request.roomID, request.userID)
	case .Remove:
		return ClientServerTransport_removeRoomMember(transport, request.roomID, request.userID)
	case .Leave:
		return ClientServerTransport_leaveRoom(transport, request.roomID)
	case .Fetch:
		return ClientServerTransport_fetchRoomMembers(transport, request.roomID)
	case .AdminList:
		return ClientServerTransport_adminListRooms(transport)
	}
	return false
}

// Sends one request. Returns "" when the transport took it, otherwise the reason (temp or
// static).
@(private = "file")
State_sendRoomMemberRequest :: proc(
	state: ^State,
	serverID: int,
	request: RoomMemberRequest,
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
	sent := roomMemberSendBridge(transport, request)
	sendError := sent ? "" : strings.clone(transport.lastError, context.temp_allocator)
	ClientNetworkWorker_unlock(state.networkWorker)
	if sent {
		return ""
	}
	if len(sendError) > 0 {
		return sendError
	}
	return "Failed to send the room request"
}

// ── Labels ────────────────────────────────────────────────────────

// A room's access mode for what the client shows: one without a mode (never sent by a protocol
// 15 server) counts as Public, what every room was before access modes. It decides only what
// the client offers; the server checks every request.
roomAccessShown :: proc(access: common.RoomAccess) -> common.RoomAccess {
	return common.roomAccessIsSupported(access) ? access : .Public
}

// The modes the forms offer, in the selector's order.
ROOM_EDITOR_ACCESS_MODES := [4]common.RoomAccess{.Public, .MemberInvite, .AdminInvite, .Role}
ROOM_EDITOR_HISTORY_OPTIONS := [2]common.RoomHistoryVisibility{.FromJoin, .Full}

roomAccessLabel :: proc(access: common.RoomAccess) -> string {
	switch roomAccessShown(access) {
	case .Public:
		return "Public"
	case .MemberInvite:
		return "Member invite"
	case .AdminInvite:
		return "Admin invite"
	case .Role:
		return "Roles"
	}
	return "Admin invite"
}

roomAccessNote :: proc(access: common.RoomAccess) -> string {
	switch roomAccessShown(access) {
	case .Public:
		return "Every account on the server is a member, new accounts too."
	case .MemberInvite:
		return "Members and admins add people; only admins remove them. Members can leave."
	case .AdminInvite:
		return "Only admins add and remove people. Members can leave."
	case .Role:
		return "Members are the holders of the chosen roles; nobody adds, removes or leaves."
	}
	return ""
}

roomHistoryLabel :: proc(history: common.RoomHistoryVisibility) -> string {
	return history == .Full ? "Full history" : "From join"
}

roomHistoryNote :: proc(
	access: common.RoomAccess,
	history: common.RoomHistoryVisibility,
) -> string {
	if roomAccessShown(access) == .Public {
		return "Public rooms show everyone the whole history."
	}
	if history == .Full {
		return "New members read everything the room has."
	}
	return "New members read only messages sent after they were added."
}

// ── Admin room list ───────────────────────────────────────────────

// Asks for every room on the server (accounts holding ManageRooms or ManageRoomMembers,
// protocol 23); the answer is AdminRoomsReceived.
State_requestAdminRooms :: proc(state: ^State, serverID: int) {
	if !State_hasPermission(state, serverID, .ManageRooms) &&
	   !State_hasPermission(state, serverID, .ManageRoomMembers) {
		return
	}
	if State_serverRoomCache(state, serverID).adminRoomsLoading {
		return
	}
	State_sendAdminRoomList(state, serverID)
}

// Sends ClientAdminListRooms whatever the admin flag says (the harness uses it directly).
State_sendAdminRoomList :: proc(state: ^State, serverID: int) -> string {
	errorMessage := State_sendRoomMemberRequest(state, serverID, {kind = .AdminList})
	if len(errorMessage) == 0 {
		State_serverRoomCache(state, serverID).adminRoomsLoading = true
	}
	return errorMessage
}

// A known room's access mode, Public when the client does not know the room.
State_roomAccess :: proc(state: ^State, serverID, roomID: int) -> common.RoomAccess {
	if room := State_knownRoom(state, serverID, roomID); room != nil {
		return roomAccessShown(room.access)
	}
	return .Public
}

// Takes ownership of rooms and clears the caller's array.
State_receiveAdminRooms :: proc(
	state: ^State,
	serverID: int,
	rooms: ^[dynamic]common.AdminRoomSummary,
) {
	cache := State_serverRoomCache(state, serverID)
	AdminRoomSummaries_deinit(&cache.adminRooms)
	cache.adminRooms = rooms^
	rooms^ = nil
	cache.adminRoomsLoaded = true
	cache.adminRoomsLoading = false
}

// Records a room the admin created without joining it, until the next admin list replaces it.
// Takes ownership of room's strings and clears the caller's copy.
State_noteAdminRoom :: proc(state: ^State, serverID: int, room: ^common.RoomSummary) {
	cache := State_serverRoomCache(state, serverID)
	for &entry in cache.adminRooms {
		if entry.room.id == room.id {
			delete(entry.room.name)
			delete(entry.room.description)
			entry.room = room^
			room^ = {}
			return
		}
	}
	append(&cache.adminRooms, common.AdminRoomSummary{room = room^})
	room^ = {}
}

// ── Rights ────────────────────────────────────────────────────────

// What this account may do in a room, from its mode, its membership (the room list) and the
// admin flag; the server checks the same rules again.
RoomMemberRights :: struct {
	known:     bool, // The client knows the room (a member, or an admin with the list)
	isMember:  bool,
	isAdmin:   bool,
	access:    common.RoomAccess,
	canView:   bool, // Open the Members page
	canAdd:    bool,
	canRemove: bool,
	canLeave:  bool,
	// Protocol 18: the rights come from the verified member log (roomLogRights).
	encrypted: bool,
}

// The rights for a room. Pure but for reading State.
roomMemberRights :: proc(state: ^State, serverID, roomID: int) -> (rights: RoomMemberRights) {
	room := State_knownRoom(state, serverID, roomID)
	if room == nil {
		return
	}
	rights.known = true
	rights.access = roomAccessShown(room.access)
	// Protocol 23: "admin" here is whoever holds ManageRoomMembers (admins hold every
	// permission), the account the server lets manage members. Protocol 24: or the room's own
	// ManageMembers (room_permissions.odin).
	rights.isAdmin = State_hasRoomPermission(state, serverID, roomID, .ManageMembers)
	rights.isMember = ServerRoomCache_roomIsJoined(State_serverRoomCache(state, serverID), roomID)
	if room.encrypted {
		// Protocol 18: what the verified member log allows (room_log.odin), not room_members.
		log := roomLogRights(state, serverID, roomID)
		rights.encrypted = true
		rights.canView = rights.isAdmin || rights.isMember || log.isMember || log.isManager
		rights.canAdd = log.canAdd
		rights.canRemove = log.canRemove
		rights.canLeave = log.canLeave
		return
	}
	public := rights.access == .Public
	rights.canView = rights.isAdmin || (rights.isMember && !public)
	// Protocol 24: a Role room's members come only from its access roles.
	if rights.access == .Role {
		return
	}
	rights.canAdd =
		!public &&
		(rights.isAdmin || (rights.isMember && rights.access == .MemberInvite))
	rights.canRemove = rights.isAdmin
	rights.canLeave = rights.isMember && !public
	return
}

// The rooms this account may invite someone to: rooms it is in whose mode lets it add, and for
// an admin every non-public room, joined or not. By name. Borrowed from State, in allocator.
State_invitableRooms :: proc(
	state: ^State,
	serverID: int,
	allocator := context.temp_allocator,
) -> []common.RoomSummary {
	rooms := make([dynamic]common.RoomSummary, 0, allocator)
	index := State_serverRoomCacheIndex(state^, serverID)
	if index < 0 {
		return rooms[:]
	}
	cache := &state.server_room_caches[index]
	for room in cache.rooms {
		if roomMemberRights(state, serverID, room.id).canAdd {
			append(&rooms, room)
		}
	}
	if State_hasPermission(state, serverID, .ManageRoomMembers) {
		for entry in cache.adminRooms {
			if ServerRoomCache_roomIsJoined(cache, entry.room.id) {
				continue
			}
			if roomMemberRights(state, serverID, entry.room.id).canAdd {
				append(&rooms, entry.room)
			}
		}
	}
	slice.sort_by(rooms[:], proc(a, b: common.RoomSummary) -> bool {
		if a.name != b.name {
			return a.name < b.name
		}
		return a.id < b.id
	})
	return rooms[:]
}

// ── Members page ──────────────────────────────────────────────────

// Opens the Members page for a room on the selected server, or switches to that server first.
// Returns false when this account may not see the room's members.
State_openRoomMembers :: proc(state: ^State, serverID, roomID: int) -> bool {
	if !roomMemberRights(state, serverID, roomID).canView {
		return false
	}
	if serverID != state.selected_server_id {
		State_switchToServer(state, serverID)
	}
	State_closeDirectConversation(state)
	State_closeServerSettings(state)
	State_resetRoomEditor(state, .Members, serverID, roomID)
	State_requestRoomMembers(state)
	if State_roomIsEncrypted(state, serverID, roomID) {
		State_requestRoomLog(state, serverID, roomID)
	}
	return true
}

// Asks for the open Members page's list; the answer is RoomMembersReceived.
State_requestRoomMembers :: proc(state: ^State) {
	editor := &state.roomEditor
	if editor.mode != .Members || editor.membersLoading {
		return
	}
	request := RoomMemberRequest {
		kind   = .Fetch,
		roomID = editor.roomID,
	}
	if errorMessage := State_sendRoomMemberRequest(state, editor.serverID, request);
	   len(errorMessage) > 0 {
		RoomEditor_setError(editor, errorMessage)
		return
	}
	editor.membersLoading = true
}

// Takes ownership of userIDs when the Members page shows that room; otherwise the caller frees
// them.
State_receiveRoomMembers :: proc(state: ^State, serverID, roomID: int, userIDs: ^[dynamic]int) {
	editor := &state.roomEditor
	if editor.mode != .Members || editor.serverID != serverID || editor.roomID != roomID {
		return
	}
	delete(editor.members)
	editor.members = userIDs^
	userIDs^ = nil
	editor.membersLoaded = true
	editor.membersLoading = false
}

// A membership in roomID changed (anyone's): the Members page showing it fetches the list
// again, and an admin's list of every room refreshes its counts.
State_roomMembersChanged :: proc(state: ^State, serverID, roomID: int) {
	editor := &state.roomEditor
	if editor.mode == .Members && editor.serverID == serverID && editor.roomID == roomID {
		editor.membersLoading = false
		State_requestRoomMembers(state)
	}
	if index := State_serverRoomCacheIndex(state^, serverID); index >= 0 {
		if state.server_room_caches[index].adminRoomsLoaded {
			State_requestAdminRooms(state, serverID)
		}
	}
}

// Protocol errors do not say which request failed, so the loading flags of the requests they
// may answer are cleared (the editor's own pending request is handled by
// State_roomEditorProtocolError).
State_roomMembersProtocolError :: proc(state: ^State, serverID: int) {
	editor := &state.roomEditor
	if editor.mode == .Members && editor.serverID == serverID {
		editor.membersLoading = false
	}
	if index := State_serverRoomCacheIndex(state^, serverID); index >= 0 {
		state.server_room_caches[index].adminRoomsLoading = false
	}
}

// The connection changed: requests in flight died with it.
State_roomMembersConnectionReset :: proc(state: ^State, serverID: int) {
	State_roomMembersProtocolError(state, serverID)
}

// The open request (add, remove or leave) of the Members page, if it is about roomID.
@(private = "file")
State_roomMembersPageFor :: proc(state: ^State, serverID, roomID: int) -> ^RoomEditor {
	editor := &state.roomEditor
	if editor.mode == .Members && editor.serverID == serverID && editor.roomID == roomID {
		return editor
	}
	return nil
}

// checkRights false (the harness) sends whatever the mode says, so the server's refusal shows.
@(private = "file")
State_sendRoomMemberChange :: proc(
	state: ^State,
	serverID: int,
	request: RoomMemberRequest,
	checkRights: bool,
) -> string {
	rights := roomMemberRights(state, serverID, request.roomID)
	if !checkRights {
		rights.canAdd = true
		rights.canRemove = true
		rights.canLeave = true
	}
	switch request.kind {
	case .Add:
		if !rights.canAdd {
			return "You cannot add members to this room."
		}
	case .Remove:
		if !rights.canRemove {
			return "Only admins remove members."
		}
	case .Leave:
		if !rights.canLeave {
			return "You cannot leave this room."
		}
	case .Fetch, .AdminList:
	}
	errorMessage := State_sendRoomMemberRequest(state, serverID, request)
	if editor := State_roomMembersPageFor(state, serverID, request.roomID); editor != nil {
		if len(errorMessage) > 0 {
			RoomEditor_setError(editor, errorMessage)
		} else {
			delete(editor.error)
			editor.error = ""
			delete(editor.notice)
			editor.notice = ""
			editor.pending = .Member
		}
	}
	return errorMessage
}

// Adds userID to roomID (Members page, Invite to room…, harness). The answer is
// RoomMemberResult, or a protocol error.
State_addRoomMember :: proc(
	state: ^State,
	serverID, roomID, userID: int,
	checkRights := true,
) -> string {
	if userID <= 0 {
		return "No account to add."
	}
	if State_roomIsEncrypted(state, serverID, roomID) {
		return State_roomLogMemberChange(state, serverID, roomID, .Add, userID, checkRights)
	}
	return State_sendRoomMemberChange(
		state,
		serverID,
		{kind = .Add, roomID = roomID, userID = userID},
		checkRights,
	)
}

State_removeRoomMember :: proc(
	state: ^State,
	serverID, roomID, userID: int,
	checkRights := true,
) -> string {
	if userID <= 0 {
		return "No account to remove."
	}
	// Protocol 18: a manager signs the removal; an admin who is not one asks the server, which
	// writes the log's unsigned Remove itself.
	if State_roomIsEncrypted(state, serverID, roomID) &&
	   roomLogRights(state, serverID, roomID).isManager {
		return State_roomLogMemberChange(state, serverID, roomID, .Remove, userID, checkRights)
	}
	return State_sendRoomMemberChange(
		state,
		serverID,
		{kind = .Remove, roomID = roomID, userID = userID},
		checkRights,
	)
}

// Leaves a non-public room. The answer is RoomMembershipChanged for this account, which drops
// the room from the list.
State_leaveRoom :: proc(state: ^State, serverID, roomID: int, checkRights := true) -> string {
	if State_roomIsEncrypted(state, serverID, roomID) {
		return State_roomLogMemberChange(state, serverID, roomID, .Leave, 0, checkRights)
	}
	return State_sendRoomMemberChange(
		state,
		serverID,
		{kind = .Leave, roomID = roomID},
		checkRights,
	)
}

// A signed change of an encrypted room's member log, with the Members page's notice. The answer
// is the server's ServerRoomLog echo (which updates the page), or a protocol error.
State_roomLogMemberChange :: proc(
	state: ^State,
	serverID, roomID: int,
	action: common.RoomLogAction,
	userID: int,
	checkRights := true,
	access := common.RoomLogAccess.MemberInvite,
) -> string {
	errorMessage, queued := State_roomLogAppend(
		state,
		serverID,
		roomID,
		action,
		userID,
		access,
		checkRights,
	)
	if editor := State_roomMembersPageFor(state, serverID, roomID); editor != nil {
		if len(errorMessage) > 0 {
			RoomEditor_setError(editor, errorMessage)
		} else {
			delete(editor.error)
			editor.error = ""
			delete(editor.notice)
			editor.notice = queued ? strings.clone("Fetching the account's key first…") : ""
		}
	}
	return errorMessage
}

// Asks for a room's members without opening its page (the harness); the answer is
// RoomMembersReceived, or "Not a room member".
State_fetchRoomMembers :: proc(state: ^State, serverID, roomID: int) -> string {
	return State_sendRoomMemberRequest(state, serverID, {kind = .Fetch, roomID = roomID})
}

// The server's answer to this session's add (added true) or removal of userID.
State_roomMemberResult :: proc(state: ^State, serverID, roomID, userID: int, added, changed: bool) {
	name := "User"
	if index := State_serverDirectCacheIndex(state^, serverID); index >= 0 {
		name = ServerDirectCache_peerNickname(&state.serverDirectCaches[index], userID)
	}
	name = userLabel(name, userID)
	roomName := fmt.tprintf("room %d", roomID)
	if room := State_knownRoom(state, serverID, roomID); room != nil {
		roomName = fmt.tprintf("#%s", room.name)
	}
	message: string
	switch {
	case added && changed:
		message = fmt.tprintf("Added %s to %s.", name, roomName)
	case added:
		message = fmt.tprintf("%s is already a member of %s.", name, roomName)
	case changed:
		message = fmt.tprintf("Removed %s from %s.", name, roomName)
	case:
		message = fmt.tprintf("%s is not a member of %s.", name, roomName)
	}
	if editor := State_roomMembersPageFor(state, serverID, roomID); editor != nil {
		editor.pending = .None
		delete(editor.notice)
		editor.notice = strings.clone(message)
		return
	}
	// Sent from a menu: the answer shows where protocol errors do.
	State_setChatStatus(state, message)
}

// ── View model ────────────────────────────────────────────────────

RoomMemberRow :: struct {
	userID:    int,
	label:     string, // In the view allocator
	isOnline:  bool,
	isSelf:    bool,
	canRemove: bool,
	// Encrypted rooms (protocol 18): the account's key state ("Verified", "Key changed", …),
	// whether the verified log names it a manager, and the manager controls.
	keyState:  string,
	isManager: bool,
	canMakeManager:   bool,
	canRemoveManager: bool,
}

RoomMembersView :: struct {
	visible:     bool,
	title:       string,
	accessLabel: string,
	accessNote:  string,
	historyNote: string,
	// Members of the room, then (when this account may add) the accounts that are not, by
	// name. Names come from the server's user directory.
	members:     []RoomMemberRow,
	candidates:  []RoomMemberRow,
	loading:     bool,
	canAdd:      bool,
	canLeave:    bool,
	isMember:    bool,
	busy:        bool,
	notice:      string,
	error:       string,
	// For admins: the room's settings (Edit room…).
	canEdit:     bool,
	// Encrypted rooms (protocol 18): members come from the verified member log, managers and
	// admins are listed apart, and logWarning replaces the lists when the log failed.
	encrypted:   bool,
	logWarning:  string,
	managers:    []RoomMemberRow,
	admins:      []RoomMemberRow,
	// Why an admin who is not a manager cannot add ("ask <names>").
	addNote:     string,
	// Managers who are admins switch between Member invite and Admin invite.
	canSetAccess: bool,
	otherAccess: common.RoomAccess,
}

// The Members page of the selected server, or visible false when it is not shown.
buildRoomMembersView :: proc(
	state: ^State,
	allocator := context.temp_allocator,
) -> (
	view: RoomMembersView,
) {
	editor := &state.roomEditor
	if !State_roomEditorVisible(state) || editor.mode != .Members {
		return
	}
	serverID, roomID := editor.serverID, editor.roomID
	room := State_knownRoom(state, serverID, roomID)
	rights := roomMemberRights(state, serverID, roomID)
	view.visible = true
	view.title = "Members"
	if room != nil {
		view.title = fmt.aprintf("Members of #%s", room.name, allocator = allocator)
		view.historyNote = roomHistoryNote(room.access, room.historyVisibility)
	}
	view.accessLabel = roomAccessLabel(rights.access)
	view.accessNote = roomAccessNote(rights.access)
	view.loading = !editor.membersLoaded
	view.canAdd = rights.canAdd
	view.canLeave = rights.canLeave
	view.isMember = rights.isMember
	view.canEdit = State_canEditRoom(state, serverID, roomID)
	view.busy = editor.pending != .None
	view.notice = editor.notice
	view.error = editor.error

	selfUserID := State_selfUserID(state, serverID)
	if room != nil && room.encrypted {
		buildEncryptedRoomMembersView(state, &view, serverID, roomID, allocator)
		return
	}
	users: []common.UserSummary
	if index := State_serverDirectCacheIndex(state^, serverID); index >= 0 {
		users = slice.clone(state.serverDirectCaches[index].users[:], allocator)
		slice.sort_by(users, proc(a, b: common.UserSummary) -> bool {
			a, b := a, b
			a.isOnline = false
			b.isOnline = false
			return memberLess(a, b)
		})
	}
	members := make([dynamic]RoomMemberRow, 0, allocator)
	candidates := make([dynamic]RoomMemberRow, 0, allocator)
	listed := make(map[int]bool, allocator = allocator)
	isMember :: proc(ids: []int, userID: int) -> bool {
		for id in ids {
			if id == userID {
				return true
			}
		}
		return false
	}
	for user in users {
		row := RoomMemberRow {
			userID   = user.id,
			label    = userLabel(user.nickname, user.id, allocator),
			isOnline = user.isOnline,
			isSelf   = user.id == selfUserID,
		}
		if row.isSelf {
			row.label = fmt.aprintf("%s (you)", row.label, allocator = allocator)
		}
		if isMember(editor.members[:], user.id) {
			row.canRemove = rights.canRemove
			append(&members, row)
			listed[user.id] = true
		} else if rights.canAdd && editor.membersLoaded {
			append(&candidates, row)
		}
	}
	// Members the directory does not list yet still show, by ID.
	for userID in editor.members {
		if !listed[userID] {
			append(
				&members,
				RoomMemberRow {
					userID = userID,
					label = userLabel("", userID, allocator),
					isSelf = userID == selfUserID,
					canRemove = rights.canRemove,
				},
			)
		}
	}
	view.members = members[:]
	view.candidates = candidates[:]
	return
}

// The Members page of an encrypted room (protocol 18): the verified log's members, its
// managers, and the server's admins, each with its key state.
@(private = "file")
buildEncryptedRoomMembersView :: proc(
	state: ^State,
	view: ^RoomMembersView,
	serverID, roomID: int,
	allocator := context.temp_allocator,
) {
	view.encrypted = true
	log := State_findRoomLog(state, serverID, roomID)
	rights := roomLogRights(state, serverID, roomID)
	view.canAdd = rights.canAdd
	view.canLeave = rights.canLeave
	view.isMember = rights.isMember
	view.addNote = rights.addNote
	view.loading = log == nil || log.status == .Unknown || log.status == .Loading
	if log != nil && log.status == .Failed {
		view.logWarning = roomLogFailureText(log, allocator)
		view.canAdd = false
		view.canLeave = false
		view.loading = false
		return
	}
	if log == nil || log.status != .Verified {
		return
	}
	if log.state.version == 0 {
		view.logWarning = ROOM_LOG_NOT_SET_UP_NOTE
		return
	}
	view.accessLabel = roomAccessLabel(common.RoomAccess(u8(log.state.access)))
	view.canSetAccess = rights.canSetAccess
	view.otherAccess = log.state.access == .MemberInvite ? .AdminInvite : .MemberInvite

	selfUserID := State_selfUserID(state, serverID)
	users: []common.UserSummary
	if index := State_serverDirectCacheIndex(state^, serverID); index >= 0 {
		users = state.serverDirectCaches[index].users[:]
	}
	row :: proc(
		state: ^State,
		serverID, userID, selfUserID: int,
		users: []common.UserSummary,
		allocator: runtime.Allocator,
	) -> RoomMemberRow {
		result := RoomMemberRow {
			userID = userID,
			isSelf = userID == selfUserID,
		}
		nickname := ""
		for user in users {
			if user.id == userID {
				nickname = user.nickname
				result.isOnline = user.isOnline
			}
		}
		result.label = userLabel(nickname, userID, allocator)
		if result.isSelf {
			result.label = fmt.aprintf("%s (you)", result.label, allocator = allocator)
			result.keyState = "You"
		} else {
			result.keyState = roomMemberKeyStateLabel(
				State_e2eePeerKeyInfo(state, serverID, userID).state,
			)
		}
		return result
	}
	sorted :: proc(
		ids: map[int]common.IdentityPublicKeyBytes,
		allocator: runtime.Allocator,
	) -> []int {
		list := make([dynamic]int, 0, len(ids), allocator)
		for userID in ids {
			append(&list, userID)
		}
		slice.sort(list[:])
		return list[:]
	}
	members := make([dynamic]RoomMemberRow, 0, allocator)
	for userID in sorted(log.state.members, allocator) {
		member := row(state, serverID, userID, selfUserID, users, allocator)
		member.isManager = userID in log.state.managers
		member.canRemove = rights.canRemove
		member.canMakeManager = rights.canManageManagers && !member.isManager
		append(&members, member)
	}
	managers := make([dynamic]RoomMemberRow, 0, allocator)
	lastManager := len(log.state.managers) == 1 && len(log.state.members) > 0
	for userID in sorted(log.state.managers, allocator) {
		manager := row(state, serverID, userID, selfUserID, users, allocator)
		manager.isManager = true
		manager.canRemoveManager = rights.canManageManagers && !lastManager
		append(&managers, manager)
	}
	admins := make([dynamic]RoomMemberRow, 0, allocator)
	candidates := make([dynamic]RoomMemberRow, 0, allocator)
	for user in users {
		if user.isAdmin {
			admin := row(state, serverID, user.id, selfUserID, users, allocator)
			admin.isManager = user.id in log.state.managers
			admin.canMakeManager = rights.canManageManagers && !admin.isManager
			append(&admins, admin)
		}
		if rights.canAdd && user.id not_in log.state.members && !user.isBanned {
			append(&candidates, row(state, serverID, user.id, selfUserID, users, allocator))
		}
	}
	view.members = members[:]
	view.managers = managers[:]
	view.admins = admins[:]
	view.candidates = candidates[:]
}

// The key state a Members row shows next to an encrypted room's member.
roomMemberKeyStateLabel :: proc(keyState: E2EEKeyState) -> string {
	switch keyState {
	case .Verified:
		return "Verified"
	case .Unverified:
		return "Not verified"
	case .KeyChanged:
		return "Key changed"
	case .NotSetUp, .NotProvided, .InvalidKey:
		return "No key"
	case .Unknown:
		return "Key not fetched"
	}
	return ""
}
