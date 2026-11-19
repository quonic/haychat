package client

import "../common"
import "core:fmt"
import "core:slice"
import "core:strings"

// Room permissions and role rooms (protocol 24, #96). The server decides every request; the
// client only reads what the room list says about this account and offers controls to match:
//
// - RoomSummary.myPermissions (ServerListRooms, ServerAdminRooms, and the creator's
//   ServerCreateRoom) is this account's set in the room. ServerEditRoom carries none, so an
//   edited room keeps the set it had (State_roomEdited). The server resends ServerListRooms
//   whenever a grant, a role or the admin role changes it.
// - State_roomPermissions adds what server permissions imply (ManageRoomMembers:
//   ManageMembers, ManageRooms: EditRoom, an admin: every one), as the server does.
// - Without SendMessages the composer gives way to ROOM_SEND_NOT_PERMITTED_NOTE and a send is
//   refused before it leaves (State_sendChannelChat). Without SpeakInVoice the account still
//   joins voice, but its engine stays muted and the voice bar says why
//   (State_voiceApplySpeakPermission); the relay would drop its frames anyway.
// - The Permissions page (RoomEditorMode.Permissions, view_room_admin.odin) is for ManageRooms
//   and the room's EditRoom: it fetches the grants (ClientAdminFetchRoomPermissions) and saves
//   them (ClientAdminSetRoomPermissions). Only bits this account may grant are offered
//   (State_roomGrantable). ServerAdminRoomPermissions fills ServerRoomCache.roomGrants, which a
//   Role room's edit form also reads its access roles from.

ROOM_SEND_NOT_PERMITTED_NOTE :: "You cannot send messages in this room"
VOICE_SPEAK_NOT_PERMITTED_NOTE :: "You cannot speak in this room"

// Every room permission in the order forms and the harness list them.
ROOM_PERMISSION_ORDER := [5]common.RoomPermission {
	.SendMessages,
	.SpeakInVoice,
	.ManageMembers,
	.EditRoom,
	.AttachFiles,
}

roomPermissionLabel :: proc(permission: common.RoomPermission) -> string {
	switch permission {
	case .SendMessages:
		return "Send messages"
	case .SpeakInVoice:
		return "Speak in voice"
	case .ManageMembers:
		return "Manage members"
	case .EditRoom:
		return "Edit room"
	case .AttachFiles:
		return "Attach files"
	}
	return ""
}

// The harness's word for a permission.
roomPermissionWord :: proc(permission: common.RoomPermission) -> string {
	switch permission {
	case .SendMessages:
		return "send"
	case .SpeakInVoice:
		return "speak"
	case .ManageMembers:
		return "manage-members"
	case .EditRoom:
		return "edit-room"
	case .AttachFiles:
		return "attach-files"
	}
	return ""
}

roomPermissionFromWord :: proc(word: string) -> (common.RoomPermission, bool) {
	for permission in common.RoomPermission {
		if roomPermissionWord(permission) == word {
			return permission, true
		}
	}
	return .SendMessages, false
}

// The cached grants of one room, from its last ServerAdminRoomPermissions.
RoomGrants :: struct {
	roomID:        int,
	everyone:      common.RoomPermissions,
	roles:         [dynamic]common.RoomRoleGrant, // owned, by role ID
	accessRoleIDs: [dynamic]int, // owned, ascending
	myPermissions: common.RoomPermissions,
}

RoomGrants_deinit :: proc(grants: ^RoomGrants) {
	delete(grants.roles)
	delete(grants.accessRoleIDs)
	grants^ = {}
}

RoomGrantsList_deinit :: proc(list: ^[dynamic]RoomGrants) {
	for &grants in list {
		RoomGrants_deinit(&grants)
	}
	delete(list^)
	list^ = nil
}

// What this account's server permissions give it in every room.
@(private = "file")
State_impliedRoomPermissions :: proc(state: ^State, serverID: int) -> common.RoomPermissions {
	if State_isServerAdmin(state, serverID) {
		return common.ROOM_PERMISSIONS_ALL
	}
	implied: common.RoomPermissions
	if State_hasPermission(state, serverID, .ManageRoomMembers) {
		implied += {.ManageMembers}
	}
	if State_hasPermission(state, serverID, .ManageRooms) {
		implied += {.EditRoom}
	}
	return implied
}

// This account's permissions in roomID: the room list's myPermissions plus what server
// permissions imply. A room the client does not know reads as the default grant, so nothing is
// disabled before the list arrives.
State_roomPermissions :: proc(state: ^State, serverID, roomID: int) -> common.RoomPermissions {
	permissions := State_impliedRoomPermissions(state, serverID)
	if room := State_knownRoom(state, serverID, roomID); room != nil {
		return permissions + room.myPermissions
	}
	return permissions + common.ROOM_PERMISSIONS_DEFAULT
}

State_hasRoomPermission :: proc(
	state: ^State,
	serverID, roomID: int,
	permission: common.RoomPermission,
) -> bool {
	return permission in State_roomPermissions(state, serverID, roomID)
}

// Whether this account may edit roomID's name, description and type and its grants:
// ManageRooms, or the room's EditRoom.
State_canEditRoom :: proc(state: ^State, serverID, roomID: int) -> bool {
	return(
		State_hasPermission(state, serverID, .ManageRooms) ||
		State_hasRoomPermission(state, serverID, roomID, .EditRoom) \
	)
}

// The bits this account may add to or take away from roomID's grants, as the server rules:
// its own room permissions, plus SendMessages, SpeakInVoice and EditRoom with ManageRooms.
State_roomGrantable :: proc(state: ^State, serverID, roomID: int) -> common.RoomPermissions {
	grantable := State_roomPermissions(state, serverID, roomID)
	if State_hasPermission(state, serverID, .ManageRooms) {
		grantable += {.SendMessages, .SpeakInVoice, .EditRoom, .AttachFiles}
	}
	return grantable
}

// The cached grants of roomID, nil before they arrived. Borrowed from State.
State_findRoomGrants :: proc(state: ^State, serverID, roomID: int) -> ^RoomGrants {
	index := State_serverRoomCacheIndex(state^, serverID)
	if index < 0 {
		return nil
	}
	for &grants in state.server_room_caches[index].roomGrants {
		if grants.roomID == roomID {
			return &grants
		}
	}
	return nil
}

// ── Requests ──────────────────────────────────────────────────────

// One room permissions request. roles[:roleCount] is a fixed array so the request stays
// comparable in tests.
RoomPermissionsRequest :: struct {
	set:       bool,
	roomID:    int,
	everyone:  common.RoomPermissions,
	roles:     [common.SERVER_ROLES_MAX]common.RoomRoleGrant,
	roleCount: int,
}

RoomPermissionsSendBridge :: #type proc(
	transport: ^ClientServerTransport,
	request: RoomPermissionsRequest,
) -> bool

// Tests swap this to observe requests without a live session, under
// roomAdminSendBridgeTestMutex.
roomPermissionsSendBridge: RoomPermissionsSendBridge = ClientServerTransport_sendRoomPermissions

ClientServerTransport_sendRoomPermissions :: proc(
	transport: ^ClientServerTransport,
	request: RoomPermissionsRequest,
) -> bool {
	if !request.set {
		return ClientServerTransport_fetchRoomPermissions(transport, request.roomID)
	}
	request := request
	return ClientServerTransport_setRoomPermissions(
		transport,
		request.roomID,
		request.everyone,
		request.roles[:request.roleCount],
	)
}

@(private = "file")
State_sendRoomPermissionsRequest :: proc(
	state: ^State,
	serverID: int,
	request: RoomPermissionsRequest,
) -> string {
	if request.roomID <= 0 {
		return "No room selected."
	}
	transportIndex := State_selectedTransportIndexForServerID(state^, serverID)
	if transportIndex < 0 {
		return "No server transport selected"
	}
	if !State_isServerConnected(state, serverID) {
		return NOT_CONNECTED_MESSAGE
	}
	transport := &state.serverTransports[transportIndex]
	ClientNetworkWorker_lock(state.networkWorker)
	sent := roomPermissionsSendBridge(transport, request)
	sendError := sent ? "" : strings.clone(transport.lastError, context.temp_allocator)
	ClientNetworkWorker_unlock(state.networkWorker)
	if sent {
		return ""
	}
	return len(sendError) > 0 ? sendError : "Failed to send the room permissions request"
}

// Asks for roomID's grants; they arrive as RoomPermissionsReceived. Returns "" when sent.
State_requestRoomPermissions :: proc(state: ^State, serverID, roomID: int) -> string {
	return State_sendRoomPermissionsRequest(state, serverID, {roomID = roomID})
}

// Replaces roomID's grants with everyone and roles (borrowed; roles without permissions are
// left out). Returns "" when sent; the answer is RoomPermissionsReceived.
State_sendSetRoomPermissions :: proc(
	state: ^State,
	serverID, roomID: int,
	everyone: common.RoomPermissions,
	roles: []common.RoomRoleGrant,
) -> string {
	request := RoomPermissionsRequest {
		set      = true,
		roomID   = roomID,
		everyone = everyone & common.ROOM_PERMISSIONS_ALL,
	}
	for grant in roles {
		if grant.permissions == {} {
			continue
		}
		if request.roleCount == len(request.roles) {
			return "Too many role grants."
		}
		request.roles[request.roleCount] = {
			roleId      = grant.roleId,
			permissions = grant.permissions & common.ROOM_PERMISSIONS_ALL,
		}
		request.roleCount += 1
	}
	return State_sendRoomPermissionsRequest(state, serverID, request)
}

// ServerAdminRoomPermissions: takes ownership of the payload's arrays and clears them. The
// grants replace the room's cached ones, and the Permissions page (or a Role room's edit form)
// open on the room takes them.
State_roomPermissionsReceived :: proc(
	state: ^State,
	serverID: int,
	payload: ^common.ServerAdminRoomPermissionsPayload,
) {
	if State_serverRoomCacheIndex(state^, serverID) < 0 {
		return
	}
	grants := State_findRoomGrants(state, serverID, payload.roomId)
	if grants == nil {
		cache := State_serverRoomCache(state, serverID)
		append(&cache.roomGrants, RoomGrants{roomID = payload.roomId})
		grants = &cache.roomGrants[len(cache.roomGrants) - 1]
	}
	delete(grants.roles)
	delete(grants.accessRoleIDs)
	grants.everyone = payload.everyone
	grants.roles = payload.roles
	grants.accessRoleIDs = payload.accessRoleIds
	grants.myPermissions = payload.myPermissions
	payload.roles = nil
	payload.accessRoleIds = nil
	State_roomEditorGrantsReceived(state, serverID, grants^)
}

// ── Voice ─────────────────────────────────────────────────────────

// Whether this account may speak in the voice room it is in (or joining). The engine stays
// muted while it may not, whatever the Mute control says; nobody else is told.
State_voiceApplySpeakPermission :: proc(state: ^State) {
	voice := &state.voice
	denied := false
	if voice.roomID != 0 && voice.status != .Idle && voice.status != .Unavailable {
		denied = !State_hasRoomPermission(state, voice.serverID, voice.roomID, .SpeakInVoice)
	}
	voice.speakDenied = denied
	if voice.engine != nil {
		VoiceEngine_setMuted(voice.engine, voice.muted || denied)
	}
}

// ── Room editor ───────────────────────────────────────────────────

// Fills the open editor from the room's cached grants and asks for fresh ones. An edit of a
// Role room needs its access roles before it can be saved.
State_roomEditorLoadGrants :: proc(state: ^State) {
	editor := &state.roomEditor
	if editor.roomID <= 0 {
		return
	}
	if grants := State_findRoomGrants(state, editor.serverID, editor.roomID); grants != nil {
		State_roomEditorGrantsReceived(state, editor.serverID, grants^)
	}
	State_requestRoomPermissions(state, editor.serverID, editor.roomID)
}

// The room's grants arrived (grants is borrowed): an Edit form takes its access roles once,
// the Permissions page its grants, and a save waiting on them is answered.
State_roomEditorGrantsReceived :: proc(state: ^State, serverID: int, grants: RoomGrants) {
	editor := &state.roomEditor
	if editor.serverID != serverID || editor.roomID != grants.roomID {
		return
	}
	#partial switch editor.mode {
	case .Edit:
		if !editor.accessRolesLoaded {
			clear(&editor.accessRoleIDs)
			append(&editor.accessRoleIDs, ..grants.accessRoleIDs[:])
			editor.accessRolesLoaded = true
		}
	case .Permissions:
		if editor.pending == .Permissions {
			editor.pending = .None
			delete(editor.notice)
			editor.notice = strings.clone("Saved the room's permissions.")
		} else if editor.grantsLoaded {
			return // keep unsaved changes; a save brings the server's version back
		}
		editor.grantsEveryone = grants.everyone
		clear(&editor.grantsRoles)
		append(&editor.grantsRoles, ..grants.roles[:])
		editor.grantsLoaded = true
	}
}

// Opens the Permissions page of roomID (ManageRooms or the room's EditRoom).
State_openRoomPermissions :: proc(state: ^State, serverID, roomID: int) {
	if !State_canEditRoom(state, serverID, roomID) ||
	   State_knownRoom(state, serverID, roomID) == nil {
		return
	}
	State_closeDirectConversation(state)
	State_closeServerSettings(state)
	State_resetRoomEditor(state, .Permissions, serverID, roomID)
	State_roomEditorLoadGrants(state)
}

// The grant of roleID on the Permissions page (empty without one).
State_roomEditorRoleGrant :: proc(editor: ^RoomEditor, roleID: int) -> common.RoomPermissions {
	for grant in editor.grantsRoles {
		if grant.roleId == roleID {
			return grant.permissions
		}
	}
	return {}
}

// Turns one bit of the everyone grant (roleID 0) or of a role's grant on or off. Only bits this
// account may grant change.
State_toggleRoomEditorGrant :: proc(
	state: ^State,
	roleID: int,
	permission: common.RoomPermission,
) {
	editor := &state.roomEditor
	if editor.mode != .Permissions || editor.pending != .None || !editor.grantsLoaded {
		return
	}
	if permission not_in State_roomGrantable(state, editor.serverID, editor.roomID) {
		return
	}
	delete(editor.notice)
	editor.notice = ""
	if roleID == 0 {
		editor.grantsEveryone ~= {permission}
		return
	}
	for &grant in editor.grantsRoles {
		if grant.roleId == roleID {
			grant.permissions ~= {permission}
			return
		}
	}
	append(&editor.grantsRoles, common.RoomRoleGrant{roleId = roleID, permissions = {permission}})
}

// Saves the Permissions page; RoomPermissionsReceived answers it.
State_saveRoomEditorPermissions :: proc(state: ^State) {
	editor := &state.roomEditor
	if editor.mode != .Permissions || editor.pending != .None || !editor.grantsLoaded {
		return
	}
	errorMessage := State_sendSetRoomPermissions(
		state,
		editor.serverID,
		editor.roomID,
		editor.grantsEveryone,
		editor.grantsRoles[:],
	)
	if len(errorMessage) > 0 {
		RoomEditor_setError(editor, errorMessage)
		return
	}
	delete(editor.error)
	editor.error = ""
	delete(editor.notice)
	editor.notice = ""
	editor.pending = .Permissions
}

// Checks or unchecks an access role of a Role room (Create, or Edit with ManageRooms).
State_toggleRoomEditorAccessRole :: proc(state: ^State, roleID: int) {
	editor := &state.roomEditor
	if (editor.mode != .Create && editor.mode != .Edit) ||
	   editor.pending != .None ||
	   editor.access != .Role ||
	   roleID <= 0 {
		return
	}
	if editor.mode == .Edit && !State_hasPermission(state, editor.serverID, .ManageRooms) {
		return
	}
	for existing, index in editor.accessRoleIDs {
		if existing == roleID {
			ordered_remove(&editor.accessRoleIDs, index)
			return
		}
	}
	append(&editor.accessRoleIDs, roleID)
	slice.sort(editor.accessRoleIDs[:])
}

// ── Permissions page view model ───────────────────────────────────

// One row of the Permissions page: Everyone (roleID 0) or a role, with a cell per permission
// in ROOM_PERMISSION_ORDER.
RoomPermissionsRow :: struct {
	roleID: int,
	label:  string, // Static or borrowed from State
	cells:  [len(ROOM_PERMISSION_ORDER)]RoomPermissionsCell,
}

RoomPermissionsCell :: struct {
	checked: bool,
	// This account may grant or take away the bit (State_roomGrantable).
	enabled: bool,
}

RoomPermissionsView :: struct {
	visible:   bool,
	title:     string,
	intro:     string,
	loaded:    bool,
	busy:      bool,
	rows:      []RoomPermissionsRow,
	saveLabel: string,
	notice:    string, // Borrowed from State
	error:     string, // Borrowed from State
}

ROOM_PERMISSIONS_INTRO ::
	"Permissions add up and nothing denies one: a member may do what the Everyone row or any " +
	"of their roles allows. Admins may do everything; Manage rooms implies Edit room and " +
	"Manage room members implies Manage members in every room."

buildRoomPermissionsView :: proc(
	state: ^State,
	allocator := context.temp_allocator,
) -> (
	view: RoomPermissionsView,
) {
	editor := &state.roomEditor
	if !State_roomEditorVisible(state) || editor.mode != .Permissions {
		return
	}
	view.visible = true
	view.intro = ROOM_PERMISSIONS_INTRO
	view.title = "Room permissions"
	if room := State_knownRoom(state, editor.serverID, editor.roomID); room != nil {
		view.title = fmt.aprintf("Permissions of #%s", room.name, allocator = allocator)
	}
	view.loaded = editor.grantsLoaded
	view.busy = editor.pending != .None
	view.saveLabel = editor.pending == .Permissions ? "Saving…" : "Save"
	view.notice = editor.notice
	view.error = editor.error
	if !view.loaded {
		return
	}
	grantable := State_roomGrantable(state, editor.serverID, editor.roomID)
	rows := make([dynamic]RoomPermissionsRow, 0, allocator)
	fill :: proc(
		row: ^RoomPermissionsRow,
		permissions, grantable: common.RoomPermissions,
		busy: bool,
	) {
		for permission, index in ROOM_PERMISSION_ORDER {
			row.cells[index] = {
				checked = permission in permissions,
				enabled = permission in grantable && !busy,
			}
		}
	}
	everyone := RoomPermissionsRow {
		label = "Everyone",
	}
	fill(&everyone, editor.grantsEveryone, grantable, view.busy)
	append(&rows, everyone)
	for role in State_roles(state, editor.serverID) {
		if role.builtin {
			continue
		}
		row := RoomPermissionsRow {
			roleID = role.id,
			label  = role.name,
		}
		fill(&row, State_roomEditorRoleGrant(editor, role.id), grantable, view.busy)
		append(&rows, row)
	}
	view.rows = rows[:]
	return
}
