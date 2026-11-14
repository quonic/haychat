package client

import "../common"
import "core:fmt"
import "core:strings"

// Room management for admins: creating, renaming, describing, and deleting rooms. The server
// decides who is an admin; the client only learns it from ServerAuthSuccess.isAdmin (kept in
// ServerConnection.isAdmin) and uses it to decide which controls to draw. Every request is
// still checked by the server, which answers a non-admin with "Admin permission required".
//
// The editor is one form in the main pane (view_room_admin.odin), opened from the sidebar's
// "+ New room" control or the room header's "Edit room" control. It never changes the room
// list itself: the server's answers do (ServerCreateRoom, ServerEditRoom, ServerDeleteRoom,
// and the ServerRoomMembershipChanged that makes every client fetch the list again).

RoomEditorMode :: enum u8 {
	Closed,
	Create,
	Edit,
}

// The request the editor sent and is waiting on. Protocol errors do not say which request
// failed, so a protocol error on the editor's server while one is pending is taken as its
// answer and shown in the form.
RoomEditorPending :: enum u8 {
	None,
	Create,
	Save,
	Delete,
}

RoomEditor :: struct {
	mode:          RoomEditorMode,
	serverID:      int,
	roomID:        int, // The room being edited; 0 while creating
	name:          [dynamic]u8, // Edited in place by the text inputs
	description:   [dynamic]u8,
	// Text, voice, or both (protocol 14). Create starts at ChatAndVoice; Edit at the room's.
	roomType:      common.RoomType,
	pending:       RoomEditorPending,
	// Delete takes two clicks: the first turns the button into "Confirm delete".
	confirmDelete: bool,
	error:         string, // Owned
}

RoomEditor_deinit :: proc(editor: ^RoomEditor) {
	delete(editor.name)
	delete(editor.description)
	delete(editor.error)
	editor^ = {}
}

@(private = "file")
RoomEditor_setError :: proc(editor: ^RoomEditor, message: string) {
	delete(editor.error)
	editor.error = strings.clone(message)
}

// One request to the server's room management. Strings are borrowed.
RoomAdminRequestKind :: enum u8 {
	Create,
	Edit,
	Delete,
}

RoomAdminRequest :: struct {
	kind:        RoomAdminRequestKind,
	roomID:      int,
	name:        string,
	description: string,
	// Create and Edit (protocol 14): Chat, Voice or ChatAndVoice.
	roomType:    common.RoomType,
}

RoomAdminSendBridge :: #type proc(
	transport: ^ClientServerTransport,
	request: RoomAdminRequest,
) -> bool

// Tests swap this to observe requests without a live session.
roomAdminSendBridge: RoomAdminSendBridge = ClientServerTransport_sendRoomAdminRequest

ClientServerTransport_sendRoomAdminRequest :: proc(
	transport: ^ClientServerTransport,
	request: RoomAdminRequest,
) -> bool {
	switch request.kind {
	case .Create:
		return ClientServerTransport_createRoom(
			transport,
			request.name,
			request.description,
			request.roomType,
		)
	case .Edit:
		return ClientServerTransport_editRoom(
			transport,
			request.roomID,
			request.name,
			request.description,
			request.roomType,
		)
	case .Delete:
		return ClientServerTransport_deleteRoom(transport, request.roomID)
	}
	return false
}

// Checks a room's name and description the way the server will, so mistakes get a readable
// message instead of "Invalid room metadata". Surrounding spaces are dropped, and so is one
// leading '#', since the sidebar already draws one. The results borrow from the inputs.
validateRoomMetadata :: proc(
	name, description: string,
) -> (
	cleanName: string,
	cleanDescription: string,
	errorMessage: string,
) {
	cleanName = strings.trim_space(name)
	if strings.has_prefix(cleanName, "#") {
		cleanName = strings.trim_space(cleanName[1:])
	}
	cleanDescription = strings.trim_space(description)
	if len(cleanName) == 0 {
		return cleanName, cleanDescription, "Enter a room name."
	}
	if strings.contains_any(cleanName, "\r\n\t") {
		return cleanName, cleanDescription, "The room name cannot contain line breaks or tabs."
	}
	if len(cleanName) > common.ROOM_NAME_MAX_BYTES {
		return cleanName,
			cleanDescription,
			"The room name must be at most 64 bytes long. Most letters take 1 byte; accented " +
			"letters and emoji take 2 to 4."
	}
	if strings.contains_any(cleanDescription, "\r\n") {
		return cleanName, cleanDescription, "The description cannot contain line breaks."
	}
	if len(cleanDescription) > common.ROOM_DESCRIPTION_MAX_BYTES {
		return cleanName, cleanDescription, "The description must be at most 256 bytes long."
	}
	return cleanName, cleanDescription, ""
}

// Room names are unique on a server (exactly, as PostgreSQL compares them). Checking the
// cached list first turns the server's constraint error into a sentence; a room another admin
// created a moment ago can still slip past, and then the server's error is shown instead.
@(private = "file")
State_roomNameTaken :: proc(
	state: ^State,
	serverID: int,
	name: string,
	exceptRoomID: int,
) -> bool {
	index := State_serverRoomCacheIndex(state^, serverID)
	if index < 0 {
		return false
	}
	for room in state.server_room_caches[index].rooms {
		if room.id != exceptRoomID && room.name == name {
			return true
		}
	}
	return false
}

// Validates and sends one request. Returns an empty string when the transport accepted it,
// otherwise the reason (allocated with the temp allocator, or static).
@(private = "file")
State_sendRoomAdminRequest :: proc(
	state: ^State,
	serverID: int,
	request: RoomAdminRequest,
) -> string {
	request := request
	if request.kind != .Delete {
		name, description, errorMessage := validateRoomMetadata(
			request.name,
			request.description,
		)
		if len(errorMessage) > 0 {
			return errorMessage
		}
		if State_roomNameTaken(state, serverID, name, request.roomID) {
			return fmt.tprintf("A room named #%s already exists.", name)
		}
		if !common.roomTypeIsSupported(request.roomType) {
			return "Choose text, voice, or both for the room."
		}
		request.name = name
		request.description = description
	} else if request.roomID <= 0 {
		return "No room to delete."
	}

	transportIndex := State_selectedTransportIndexForServerID(state^, serverID)
	if transportIndex < 0 {
		return "No server transport selected"
	}
	if !State_isServerConnected(state, serverID) {
		return NOT_CONNECTED_MESSAGE
	}
	transport := &state.serverTransports[transportIndex]
	// The worker may replace lastError at any time, so copy it while holding the lock.
	ClientNetworkWorker_lock(state.networkWorker)
	sent := roomAdminSendBridge(transport, request)
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

// Asks the server for a new room of roomType (protocol 14; text and voice unless told
// otherwise). The answer arrives as RoomCreated (to this session only) and as
// RoomMembershipChanged (to everyone). Returns the reason when nothing was sent.
State_sendCreateRoom :: proc(
	state: ^State,
	serverID: int,
	name, description: string,
	roomType: common.RoomType = .ChatAndVoice,
) -> string {
	return State_sendRoomAdminRequest(
		state,
		serverID,
		RoomAdminRequest {
			kind = .Create,
			name = name,
			description = description,
			roomType = roomType,
		},
	)
}

// Renames a room and replaces its description and type; the answer arrives as RoomEdited. The
// type has no default, so an edit never changes it by accident: pass the room's own to keep it.
// Making a room text-only ends its voice session on the server.
State_sendEditRoom :: proc(
	state: ^State,
	serverID, roomID: int,
	name, description: string,
	roomType: common.RoomType,
) -> string {
	if roomID <= 0 {
		return "No room to edit."
	}
	return State_sendRoomAdminRequest(
		state,
		serverID,
		RoomAdminRequest {
			kind = .Edit,
			roomID = roomID,
			name = name,
			description = description,
			roomType = roomType,
		},
	)
}

// The type of a cached room, or ChatAndVoice when it is not cached.
State_roomType :: proc(state: ^State, serverID, roomID: int) -> common.RoomType {
	index := State_serverRoomCacheIndex(state^, serverID)
	if index < 0 {
		return .ChatAndVoice
	}
	for room in state.server_room_caches[index].rooms {
		if room.id == roomID {
			return room.roomType
		}
	}
	return .ChatAndVoice
}

// Deletes a room with its history; the answer arrives as RoomDeleted.
State_sendDeleteRoom :: proc(state: ^State, serverID, roomID: int) -> string {
	return State_sendRoomAdminRequest(
		state,
		serverID,
		RoomAdminRequest{kind = .Delete, roomID = roomID},
	)
}

// Whether the editor is open on the selected server, which is when the main pane shows it.
State_roomEditorVisible :: proc(state: ^State) -> bool {
	return(
		state.roomEditor.mode != .Closed &&
		state.roomEditor.serverID == state.selected_server_id \
	)
}

@(private = "file")
State_resetRoomEditor :: proc(state: ^State, mode: RoomEditorMode, serverID, roomID: int) {
	editor := &state.roomEditor
	editor.mode = mode
	editor.serverID = serverID
	editor.roomID = roomID
	clear(&editor.name)
	clear(&editor.description)
	editor.roomType = .ChatAndVoice
	editor.pending = .None
	editor.confirmDelete = false
	delete(editor.error)
	editor.error = ""
}

// Opens the empty "New room" form for the selected server. Only admins get it.
State_openRoomCreator :: proc(state: ^State) {
	serverID := state.selected_server_id
	if !State_isServerAdmin(state, serverID) {
		return
	}
	state.selected_dm_peer_id = 0
	State_closeServerSettings(state)
	State_resetRoomEditor(state, .Create, serverID, 0)
}

// Opens the edit form for one of the selected server's rooms, filled with its current name
// and description. Only admins get it.
State_openRoomEditor :: proc(state: ^State, roomID: int) {
	serverID := state.selected_server_id
	if !State_isServerAdmin(state, serverID) {
		return
	}
	index := State_serverRoomCacheIndex(state^, serverID)
	if index < 0 {
		return
	}
	for room in state.server_room_caches[index].rooms {
		if room.id == roomID {
			state.selected_dm_peer_id = 0
			State_closeServerSettings(state)
			State_resetRoomEditor(state, .Edit, serverID, roomID)
			append(&state.roomEditor.name, room.name)
			append(&state.roomEditor.description, room.description)
			state.roomEditor.roomType = room.roomType
			return
		}
	}
}

// Opens the edit form with its delete armed: the next click on "Confirm delete" sends. The
// channel menu's Delete room… and the Admin section's Delete use it.
State_openRoomEditorForDelete :: proc(state: ^State, roomID: int) {
	State_openRoomEditor(state, roomID)
	editor := &state.roomEditor
	if editor.mode == .Edit && editor.roomID == roomID {
		editor.confirmDelete = true
	}
}

State_closeRoomEditor :: proc(state: ^State) {
	State_resetRoomEditor(state, .Closed, 0, 0)
}

// Closes the editor when it belongs to serverID, e.g. because that server's session or
// transport went away.
State_closeRoomEditorForServer :: proc(state: ^State, serverID: int) {
	if state.roomEditor.mode != .Closed && state.roomEditor.serverID == serverID {
		State_closeRoomEditor(state)
	}
}

// The type selector: Text (Chat), Voice, or Text and voice. Nothing is sent until Create or
// Save.
State_setRoomEditorType :: proc(state: ^State, roomType: common.RoomType) {
	editor := &state.roomEditor
	if editor.mode == .Closed ||
	   editor.pending != .None ||
	   !common.roomTypeIsSupported(roomType) {
		return
	}
	editor.roomType = roomType
	editor.confirmDelete = false
}

// Create or Save. The form stays open until the server answers: RoomCreated or RoomEdited
// closes it, a protocol error shows in it.
State_submitRoomEditor :: proc(state: ^State) {
	editor := &state.roomEditor
	if editor.mode == .Closed || editor.pending != .None {
		return
	}
	editor.confirmDelete = false
	name := string(editor.name[:])
	description := string(editor.description[:])
	errorMessage: string
	pending: RoomEditorPending
	if editor.mode == .Create {
		errorMessage = State_sendCreateRoom(
			state,
			editor.serverID,
			name,
			description,
			editor.roomType,
		)
		pending = .Create
	} else {
		errorMessage = State_sendEditRoom(
			state,
			editor.serverID,
			editor.roomID,
			name,
			description,
			editor.roomType,
		)
		pending = .Save
	}
	if len(errorMessage) > 0 {
		RoomEditor_setError(editor, errorMessage)
		return
	}
	delete(editor.error)
	editor.error = ""
	editor.pending = pending
}

// The first click arms the delete ("Confirm delete"); the second sends it. RoomDeleted
// closes the form.
State_deleteRoomFromEditor :: proc(state: ^State) {
	editor := &state.roomEditor
	if editor.mode != .Edit || editor.pending != .None {
		return
	}
	if !editor.confirmDelete {
		editor.confirmDelete = true
		return
	}
	editor.confirmDelete = false
	if errorMessage := State_sendDeleteRoom(state, editor.serverID, editor.roomID);
	   len(errorMessage) > 0 {
		RoomEditor_setError(editor, errorMessage)
		return
	}
	delete(editor.error)
	editor.error = ""
	editor.pending = .Delete
}

// The editor's view of a room that changed or went away on the server: the form closes when
// its room was edited (by this admin or another one) or deleted.
State_roomEditorRoomChanged :: proc(state: ^State, serverID, roomID: int) {
	editor := &state.roomEditor
	if editor.mode == .Edit && editor.serverID == serverID && editor.roomID == roomID {
		State_closeRoomEditor(state)
	}
}

// A protocol error on the editor's server answers its pending request, if any.
State_roomEditorProtocolError :: proc(state: ^State, serverID: int, message: string) {
	editor := &state.roomEditor
	if editor.mode == .Closed || editor.serverID != serverID || editor.pending == .None {
		return
	}
	editor.pending = .None
	editor.confirmDelete = false
	RoomEditor_setError(editor, len(message) > 0 ? message : "The server refused the request.")
}

// A pending request died with the session; the form stays so the admin can try again.
State_roomEditorConnectionReset :: proc(state: ^State, serverID: int) {
	editor := &state.roomEditor
	if editor.mode == .Closed || editor.serverID != serverID || editor.pending == .None {
		return
	}
	editor.pending = .None
	RoomEditor_setError(editor, "The connection dropped before the server answered. Try again.")
}

// Takes ownership of room and clears the caller's copy. ServerCreateRoom goes only to the
// session that asked, so the new room is this admin's: it joins the room list right away
// (the refresh that RoomMembershipChanged starts replaces the list moments later) and, on the
// selected server, becomes the selected room.
State_roomCreated :: proc(state: ^State, serverID: int, room: ^common.RoomSummary) {
	if room.id <= 0 {
		return
	}
	roomID := room.id
	cache := State_serverRoomCache(state, serverID)
	if ServerRoomCache_roomIsJoined(cache, roomID) {
		delete(room.name)
		delete(room.description)
	} else {
		append(&cache.rooms, room^)
	}
	room^ = {}
	if state.roomEditor.mode == .Create && state.roomEditor.serverID == serverID {
		State_closeRoomEditor(state)
	}
	if serverID == state.selected_server_id {
		State_switchToChannel(state, serverID, roomID)
	}
}
