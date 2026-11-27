package client

import "../common"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// Room access modes on the client (protocol 15): what each mode offers, the Members page, Invite
// to room…, Leave room, the create form's new fields, a room created without joining, and the
// Admin section's list of every room. Requests go through roomMemberSendBridge and
// roomAdminSendBridge stubs; the server's rules are tested in server/.

roomMemberSendBridgeTestMutex: sync.Mutex

// Tests on other threads may send through the bridge while a stub is in place (an admin's
// Server settings asks for the room list), so the stub records only this file's server, in a
// fixed array that never allocates.
ROOM_MEMBERS_TEST_SERVER :: 957
RoomMemberTestRequests :: struct {
	items: [64]RoomMemberRequest,
	count: int,
}
roomMemberSendBridgeTestSent: RoomMemberTestRequests

roomMemberSendBridgeTestStub :: proc(
	transport: ^ClientServerTransport,
	request: RoomMemberRequest,
) -> bool {
	sent := &roomMemberSendBridgeTestSent
	if transport.serverID == ROOM_MEMBERS_TEST_SERVER && sent.count < len(sent.items) {
		sent.items[sent.count] = request
		sent.count += 1
	}
	return true
}

testRoomMembersUseStub :: proc() {
	roomMemberSendBridgeTestSent = {}
	roomMemberSendBridge = roomMemberSendBridgeTestStub
}

testRoomMembersRestore :: proc() {
	roomMemberSendBridge = ClientServerTransport_sendRoomMemberRequest
}

testRoomMembersSent :: proc() -> []RoomMemberRequest {
	return roomMemberSendBridgeTestSent.items[:roomMemberSendBridgeTestSent.count]
}

testRoomMembersLastRequest :: proc() -> RoomMemberRequest {
	sent := testRoomMembersSent()
	if len(sent) == 0 {
		return {}
	}
	return sent[len(sent) - 1]
}

// alice (user 3) on server 957 with #general (Public), #team (Member invite) and #ops (Admin
// invite), and a directory of alice, bob (4) and carol (5).
testRoomMembersState :: proc(isAdmin: bool) -> State {
	server := testRoomAdminServer(ROOM_MEMBERS_TEST_SERVER)
	state := testUpdateStateForServer(server)
	testApplyConnectedAs(&state, server.id, 3, isAdmin)
	testApplyNamedRooms(
		&state,
		server.id,
		{id = 1, name = "general"},
		{id = 2, name = "team", access = .MemberInvite, historyVisibility = .FromJoin},
		{id = 3, name = "ops", access = .AdminInvite, historyVisibility = .Full},
	)
	testApplyUserList(
		&state,
		server.id,
		{id = 3, nickname = "alice", isOnline = true, isAdmin = isAdmin},
		{id = 4, nickname = "bob", isOnline = true},
		{id = 5, nickname = "carol"},
	)
	return state
}

testRoomMembersApply :: proc(state: ^State, roomID: int, members: ..int) {
	event := ClientTransportRuntimeEvent {
		kind     = .RoomMembersReceived,
		serverID = 957,
		roomID   = roomID,
	}
	append(&event.userIDs, ..members)
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

@(test)
testRoomMemberRightsFollowTheAccessMode :: proc(t: ^testing.T) {
	member := testRoomMembersState(false)
	defer State_deinit(&member)
	Case :: struct {
		roomID:                                 int,
		canView, canAdd, canRemove, canLeave: bool,
	}
	for testCase in ([]Case {
			{1, false, false, false, false},
			{2, true, true, false, true},
			{3, true, false, false, true},
		}) {
		rights := roomMemberRights(&member, 957, testCase.roomID)
		testing.expect(
			t,
			rights.known &&
			rights.isMember &&
			rights.canView == testCase.canView &&
			rights.canAdd == testCase.canAdd &&
			rights.canRemove == testCase.canRemove &&
			rights.canLeave == testCase.canLeave,
			fmt.tprintf("expected %v for a member, got %v", testCase, rights),
		)
	}
	admin := testRoomMembersState(true)
	defer State_deinit(&admin)
	for testCase in ([]Case {
			{1, true, false, true, false},
			{2, true, true, true, true},
			{3, true, true, true, true},
		}) {
		rights := roomMemberRights(&admin, 957, testCase.roomID)
		testing.expect(
			t,
			rights.canView == testCase.canView &&
			rights.canAdd == testCase.canAdd &&
			rights.canRemove == testCase.canRemove &&
			rights.canLeave == testCase.canLeave,
			fmt.tprintf("expected %v for an admin, got %v", testCase, rights),
		)
	}
	testing.expect(
		t,
		!roomMemberRights(&member, 957, 99).known,
		"expected an unknown room to offer nothing",
	)
	// Invite to room… lists the rooms this account may add people to.
	memberRooms := State_invitableRooms(&member, 957)
	testing.expect(
		t,
		len(memberRooms) == 1 && memberRooms[0].name == "team",
		fmt.tprintf("expected only #team for a member, got %v", memberRooms),
	)
	adminRooms := State_invitableRooms(&admin, 957)
	testing.expect(
		t,
		len(adminRooms) == 2 && adminRooms[0].name == "ops" && adminRooms[1].name == "team",
		fmt.tprintf("expected #ops and #team for an admin, got %v", adminRooms),
	)
}

@(test)
testRoomMembersPageAddsAndRemovesThroughTheBridge :: proc(t: ^testing.T) {
	sync.mutex_lock(&roomMemberSendBridgeTestMutex)
	defer sync.mutex_unlock(&roomMemberSendBridgeTestMutex)
	testRoomMembersUseStub()
	defer testRoomMembersRestore()
	state := testRoomMembersState(false)
	defer State_deinit(&state)

	testing.expect(t, !State_openRoomMembers(&state, 957, 1), "expected no page for #general")
	testing.expect(t, State_openRoomMembers(&state, 957, 2), "expected #team's page to open")
	request := testRoomMembersLastRequest()
	testing.expect(
		t,
		request.kind == .Fetch && request.roomID == 2,
		fmt.tprintf("expected a fetch of #team, got %v", request),
	)
	view := buildRoomMembersView(&state)
	testing.expect(
		t,
		view.visible && view.loading && view.title == "Members of #team",
		fmt.tprintf("expected the page loading, got %v", view),
	)
	testing.expect(
		t,
		!State_isConversationViewed(&state, .Room, 957, 2),
		"expected nothing viewed while the page is shown",
	)

	testRoomMembersApply(&state, 2, 3, 4)
	view = buildRoomMembersView(&state)
	testing.expect(
		t,
		len(view.members) == 2 &&
		view.members[0].label == "alice (you)" &&
		view.members[1].label == "bob" &&
		!view.members[1].canRemove &&
		len(view.candidates) == 1 &&
		view.candidates[0].label == "carol" &&
		view.canAdd &&
		view.canLeave &&
		!view.canEdit,
		fmt.tprintf("expected two members and carol to add, got %v", view),
	)

	testing.expect(
		t,
		State_addRoomMember(&state, 957, 2, 5) == "",
		"expected a member's invite to go out",
	)
	request = testRoomMembersLastRequest()
	testing.expect(
		t,
		request.kind == .Add && request.roomID == 2 && request.userID == 5,
		fmt.tprintf("expected carol added to #team, got %v", request),
	)
	testing.expect(t, buildRoomMembersView(&state).busy, "expected the page to wait")
	result := ClientTransportRuntimeEvent {
		kind       = .RoomMemberResult,
		serverID   = 957,
		roomID     = 2,
		peerUserID = 5,
		joined     = true,
		changed    = true,
	}
	State_applyRuntimeEvent(&state, &result)
	ClientTransportRuntimeEvent_deinit(&result)
	view = buildRoomMembersView(&state)
	testing.expect(
		t,
		!view.busy && view.notice == "Added carol to #team.",
		fmt.tprintf("expected the answer shown, got %v", view),
	)

	// Another member's join refreshes the list; it does not touch the room list.
	before := len(testRoomMembersSent())
	changed := ClientTransportRuntimeEvent {
		kind       = .RoomMembershipChanged,
		serverID   = 957,
		roomID     = 2,
		joined     = true,
		peerUserID = 5,
	}
	State_applyRuntimeEvent(&state, &changed)
	ClientTransportRuntimeEvent_deinit(&changed)
	testing.expect(
		t,
		len(testRoomMembersSent()) == before + 1 &&
		testRoomMembersLastRequest().kind == .Fetch,
		"expected the page to fetch the members again",
	)
	testing.expect(
		t,
		State_roomSummary(&state, 957, 2) != nil,
		"expected #team still listed after someone else joined",
	)

	// A member cannot remove anyone; the request never goes out.
	before = len(testRoomMembersSent())
	testing.expect(
		t,
		State_removeRoomMember(&state, 957, 2, 4) != "",
		"expected a member's removal refused locally",
	)
	testing.expect(
		t,
		len(testRoomMembersSent()) == before,
		"expected nothing sent for a refused removal",
	)

	// Leaving: this account's own membership change drops the room and closes the page.
	testing.expect(t, State_leaveRoom(&state, 957, 2) == "", "expected the leave to go out")
	testing.expect(t, testRoomMembersLastRequest().kind == .Leave, "expected a leave request")
	left := ClientTransportRuntimeEvent {
		kind       = .RoomMembershipChanged,
		serverID   = 957,
		roomID     = 2,
		joined     = false,
		peerUserID = 3,
	}
	State_applyRuntimeEvent(&state, &left)
	ClientTransportRuntimeEvent_deinit(&left)
	testing.expect(
		t,
		State_roomSummary(&state, 957, 2) == nil && state.roomEditor.mode == .Closed,
		"expected #team gone and its page closed after leaving",
	)
}

@(test)
testRoomMembersContextMenuInvitesAndLeaves :: proc(t: ^testing.T) {
	sync.mutex_lock(&roomMemberSendBridgeTestMutex)
	defer sync.mutex_unlock(&roomMemberSendBridgeTestMutex)
	testRoomMembersUseStub()
	defer testRoomMembersRestore()
	state := testRoomMembersState(false)
	defer State_deinit(&state)
	now := time.tick_now()

	hasEntry :: proc(view: ContextMenuView, action: ContextMenuAction) -> bool {
		for entry in view.entries {
			if entry.action == action {
				return true
			}
		}
		return false
	}

	// A member's menu on bob offers Invite to room…, which lists #team.
	State_openContextMenu(&state, MemberMenuTarget{serverID = 957, userID = 4}, {})
	view := buildContextMenu(&state, {})
	testing.expect(t, hasEntry(view, .InviteToRoom), "expected Invite to room… for bob")
	effect := State_runContextMenuAction(&state, .InviteToRoom, now)
	testing.expect(t, effect.keepOpen, "expected the menu to stay open with the room list")
	view = buildContextMenu(&state, {})
	testing.expect(
		t,
		len(view.entries) == 1 &&
		view.entries[0].action == .InviteToRoomPick &&
		view.entries[0].roomID == 2 &&
		view.entries[0].label == "Invite to #team",
		fmt.tprintf("expected only Invite to #team, got %v", view.entries),
	)
	State_runContextMenuAction(&state, .InviteToRoomPick, now, 2)
	request := testRoomMembersLastRequest()
	testing.expect(
		t,
		request.kind == .Add && request.roomID == 2 && request.userID == 4,
		fmt.tprintf("expected bob invited to #team, got %v", request),
	)
	testing.expect(t, state.contextMenu.target == nil, "expected the menu closed")
	// The answer to a menu invite shows as the chat status.
	result := ClientTransportRuntimeEvent {
		kind       = .RoomMemberResult,
		serverID   = 957,
		roomID     = 2,
		peerUserID = 4,
		joined     = true,
	}
	State_applyRuntimeEvent(&state, &result)
	ClientTransportRuntimeEvent_deinit(&result)
	testing.expect(
		t,
		state.chat_status_message == "bob is already a member of #team.",
		fmt.tprintf("expected the answer as the status, got %q", state.chat_status_message),
	)

	// Not on yourself.
	State_openContextMenu(&state, MemberMenuTarget{serverID = 957, userID = 3}, {})
	testing.expect(
		t,
		!hasEntry(buildContextMenu(&state, {}), .InviteToRoom),
		"expected no Invite to room… on yourself",
	)

	// Channel menus: Members… and Leave room… for invite rooms, neither for #general.
	State_openContextMenu(&state, ChannelMenuTarget{serverID = 957, roomID = 1}, {})
	view = buildContextMenu(&state, {})
	testing.expect(
		t,
		!hasEntry(view, .RoomMembers) && !hasEntry(view, .LeaveRoom),
		"expected no member entries on a public room for a member",
	)
	State_openContextMenu(&state, ChannelMenuTarget{serverID = 957, roomID = 3}, {})
	view = buildContextMenu(&state, {})
	testing.expect(
		t,
		hasEntry(view, .RoomMembers) && hasEntry(view, .LeaveRoom),
		"expected Members… and Leave room… on #ops",
	)
	effect = State_runContextMenuAction(&state, .LeaveRoom, now)
	testing.expect(
		t,
		effect.keepOpen && hasEntry(buildContextMenu(&state, {}), .ConfirmLeaveRoom),
		"expected Leave room… to arm itself",
	)
	before := len(testRoomMembersSent())
	State_runContextMenuAction(&state, .ConfirmLeaveRoom, now)
	testing.expect(
		t,
		len(testRoomMembersSent()) == before + 1 &&
		testRoomMembersLastRequest().kind == .Leave &&
		testRoomMembersLastRequest().roomID == 3,
		"expected the second click to leave #ops",
	)
}

@(test)
testRoomEditorCreatesWithAccessHistoryAndJoining :: proc(t: ^testing.T) {
	sync.mutex_lock(&roomAdminSendBridgeTestMutex)
	defer sync.mutex_unlock(&roomAdminSendBridgeTestMutex)
	testRoomAdminUseStub()
	defer testRoomAdminRestore()
	state := testRoomMembersState(true)
	defer State_deinit(&state)

	State_openRoomCreator(&state)
	view := buildRoomEditorView(&state)
	testing.expect(
		t,
		view.access == .Public &&
		view.history == .Full &&
		view.historyLocked &&
		view.joinLocked &&
		view.creatorJoins,
		fmt.tprintf("expected a Public room by default, got %v", view),
	)
	State_setRoomEditorAccess(&state, .AdminInvite)
	// Protocol 18: an invite room is encrypted by default (Q9); this test creates a plain one.
	testing.expect(
		t,
		buildRoomEditorView(&state).encrypted,
		"expected Encrypt this room on for an invite room",
	)
	State_toggleRoomEditorEncrypted(&state)
	State_setRoomEditorHistory(&state, .Full)
	State_toggleRoomEditorCreatorJoins(&state)
	view = buildRoomEditorView(&state)
	testing.expect(
		t,
		view.access == .AdminInvite &&
		view.history == .Full &&
		!view.historyLocked &&
		!view.creatorJoins &&
		strings.contains(view.joinNote, "not a member"),
		fmt.tprintf("expected an Admin invite room without joining, got %v", view),
	)
	testRoomAdminSetForm(&state, "secret", "")
	State_submitRoomEditor(&state)
	testing.expect(
		t,
		roomAdminSendBridgeTestCount == 1 &&
		roomAdminSendBridgeTestKind == .Create &&
		roomAdminSendBridgeTestAccess == .AdminInvite &&
		roomAdminSendBridgeTestHistory == .Full &&
		!roomAdminSendBridgeTestCreatorJoins,
		"expected the create to carry the access, history and joining",
	)

	// The answer: a room the admin is not in goes to the admin list and opens its Members page.
	sync.mutex_lock(&roomMemberSendBridgeTestMutex)
	defer sync.mutex_unlock(&roomMemberSendBridgeTestMutex)
	testRoomMembersUseStub()
	defer testRoomMembersRestore()
	created := ClientTransportRuntimeEvent {
		kind     = .RoomCreated,
		serverID = 957,
		room     = {
			id = 7,
			name = strings.clone("secret"),
			description = strings.clone(""),
			roomType = .Chat,
			access = .AdminInvite,
			historyVisibility = .Full,
		},
		isMember = false,
	}
	State_applyRuntimeEvent(&state, &created)
	ClientTransportRuntimeEvent_deinit(&created)
	testing.expect(
		t,
		State_roomSummary(&state, 957, 7) == nil && State_knownRoom(&state, 957, 7) != nil,
		"expected the room known from the admin list, not in the room list",
	)
	testing.expect(
		t,
		state.roomEditor.mode == .Members && state.roomEditor.roomID == 7,
		"expected the new room's Members page open",
	)
	members := buildRoomMembersView(&state)
	testing.expect(
		t,
		members.visible && !members.isMember && members.canAdd && !members.canLeave,
		fmt.tprintf("expected an admin who is not in it to add people, got %v", members),
	)
	kinds: [2]RoomMemberRequestKind
	sent := testRoomMembersSent()
	for request, index in sent[:min(2, len(sent))] {
		kinds[index] = request.kind
	}
	testing.expect(
		t,
		len(testRoomMembersSent()) == 2 && kinds == {.Fetch, .AdminList},
		fmt.tprintf("expected the members and the admin list asked for, got %v", kinds),
	)

	// Edit: the access selector offers every mode and warns what a switch to Public does.
	State_openRoomEditor(&state, 7)
	State_setRoomEditorAccess(&state, .Public)
	view = buildRoomEditorView(&state)
	testing.expect(
		t,
		view.historyLocked && strings.contains(view.accessWarning, "adds every account"),
		fmt.tprintf("expected the switch to Public explained, got %v", view),
	)
	testRoomAdminSetForm(&state, "secret", "")
	State_submitRoomEditor(&state)
	testing.expect(
		t,
		roomAdminSendBridgeTestKind == .Edit &&
		roomAdminSendBridgeTestRoomID == 7 &&
		roomAdminSendBridgeTestAccess == .Public,
		"expected the edit to carry the new access",
	)
}

@(test)
testAdminSectionListsEveryRoom :: proc(t: ^testing.T) {
	state := testRoomMembersState(true)
	defer State_deinit(&state)
	view := buildAdminSectionView(&state, 957)
	testing.expect(
		t,
		len(view.rooms) == 3 && view.rooms[0].isMember,
		fmt.tprintf("expected the joined rooms until the list arrives, got %v", view.rooms),
	)
	event := ClientTransportRuntimeEvent {
		kind     = .AdminRoomsReceived,
		serverID = 957,
	}
	append(
		&event.adminRooms,
		common.AdminRoomSummary {
			room = {id = 1, name = strings.clone("general"), description = strings.clone("")},
			isMember = true,
			memberCount = 3,
		},
		common.AdminRoomSummary {
			room = {
				id = 9,
				name = strings.clone("hidden"),
				description = strings.clone(""),
				access = .AdminInvite,
				historyVisibility = .FromJoin,
			},
			memberCount = 1,
		},
	)
	State_applyRuntimeEvent(&state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
	view = buildAdminSectionView(&state, 957)
	testing.expect(
		t,
		len(view.rooms) == 2 &&
		view.rooms[1].label == "# hidden" &&
		!view.rooms[1].isMember &&
		view.rooms[1].accessLabel == "Admin invite · not joined · 1 member",
		fmt.tprintf("expected the hidden room listed, got %v", view.rooms),
	)
	testing.expect(
		t,
		roomMemberRights(&state, 957, 9).canView,
		"expected an admin to manage a room they are not in",
	)
	// Deleting it drops it from the admin list too.
	testApplyRoomEvent(&state, .RoomDeleted, 957, 9)
	testing.expect(
		t,
		State_knownRoom(&state, 957, 9) == nil,
		"expected the deleted room gone from the admin list",
	)
}

@(test)
testHeadlessRoomAccessOptionsAndCommands :: proc(t: ^testing.T) {
	options, ok := headlessParseRoomOptions("both,admin-invite,full,no-join", true)
	testing.expect(
		t,
		ok &&
		options.roomType == .ChatAndVoice &&
		options.access == .AdminInvite &&
		options.hasAccess &&
		options.history == .Full &&
		!options.creatorJoins,
		fmt.tprintf("expected every option read, got %v", options),
	)
	options, ok = headlessParseRoomOptions("text", true)
	testing.expect(
		t,
		ok && options.access == .Public && options.history == .FromJoin && options.creatorJoins,
		fmt.tprintf("expected the defaults, got %v", options),
	)
	_, ok = headlessParseRoomOptions("text,full", false)
	testing.expect(t, !ok, "expected room-edit to refuse a history option")
	_, ok = headlessParseRoomOptions("both,secret", true)
	testing.expect(t, !ok, "expected an unknown option refused")

	sync.mutex_lock(&roomMemberSendBridgeTestMutex)
	defer sync.mutex_unlock(&roomMemberSendBridgeTestMutex)
	testRoomMembersUseStub()
	defer testRoomMembersRestore()
	builder := strings.builder_make()
	harness := testHeadlessHarness(&builder, 957)
	defer testHeadlessHarnessDeinit(&harness, &builder)
	testApplyConnectedAs(&harness.state, 957, 3, false)
	testApplyNamedRooms(
		&harness.state,
		957,
		{id = 1, name = "general"},
		{id = 2, name = "team", access = .MemberInvite},
		{id = 3, name = "ops", access = .AdminInvite},
	)

	// The harness sends what the GUI would refuse, so the server's answer shows.
	headlessHandleLine(&harness, "room-add 3 5")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":true,"cmd":"room-add","serverID":957,"roomID":3,"userID":5}` + "\n",
		"the room-add result",
	)
	request := testRoomMembersLastRequest()
	testing.expect(
		t,
		request.kind == .Add && request.roomID == 3 && request.userID == 5,
		fmt.tprintf("expected a member's add to an admin invite room sent, got %v", request),
	)
	headlessHandleLine(&harness, "room-leave 1")
	testing.expect(
		t,
		testRoomMembersLastRequest().kind == .Leave,
		"expected the leave of a public room sent",
	)
	headlessHandleLine(&harness, "room-members 2")
	testing.expect(
		t,
		testRoomMembersLastRequest().kind == .Fetch && testRoomMembersLastRequest().roomID == 2,
		"expected the member fetch sent",
	)
	headlessHandleLine(&harness, "room-remove 2")
	output := testHeadlessTakeOutput(&builder)
	testing.expect(
		t,
		strings.contains(output, `"ok":false`) && strings.contains(output, "usage: room-remove"),
		fmt.tprintf("expected room-remove without a user refused, got %s", output),
	)

	members := ClientTransportRuntimeEvent {
		kind     = .RoomMembersReceived,
		serverID = 957,
		roomID   = 2,
	}
	append(&members.userIDs, 3, 4)
	headlessHandleRuntimeEvent(&harness, &members)
	ClientTransportRuntimeEvent_deinit(&members)
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"event":"room_members","serverID":957,"roomID":2,"userIDs":[3,4]}` + "\n",
		"the room_members event",
	)
	result := ClientTransportRuntimeEvent {
		kind       = .RoomMemberResult,
		serverID   = 957,
		roomID     = 2,
		peerUserID = 5,
		joined     = true,
		changed    = true,
	}
	headlessHandleRuntimeEvent(&harness, &result)
	ClientTransportRuntimeEvent_deinit(&result)
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"event":"room_member_result","serverID":957,"roomID":2,"userID":5,"added":true,` +
		`"changed":true}` +
		"\n",
		"the room_member_result event",
	)
}

// Applies ServerAdminRoomChanged{roomID, change} (protocol 31).
@(private = "file")
testApplyAdminRoomChanged :: proc(state: ^State, roomID: int, change: common.AdminRoomChange) {
	event := ClientTransportRuntimeEvent {
		kind            = .AdminRoomChanged,
		serverID        = ROOM_MEMBERS_TEST_SERVER,
		roomID          = roomID,
		adminRoomChange = change,
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

@(private = "file")
testApplyAdminRooms :: proc(state: ^State, roomIDs: ..int) {
	event := ClientTransportRuntimeEvent {
		kind     = .AdminRoomsReceived,
		serverID = ROOM_MEMBERS_TEST_SERVER,
	}
	for roomID in roomIDs {
		append(
			&event.adminRooms,
			common.AdminRoomSummary {
				room = {
					id = roomID,
					name = strings.clone(fmt.tprintf("room-%d", roomID)),
					description = strings.clone(""),
					access = .AdminInvite,
					historyVisibility = .FromJoin,
				},
				memberCount = 1,
			},
		)
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

@(private = "file")
testAdminListRequestCount :: proc() -> int {
	count := 0
	for request in testRoomMembersSent() {
		if request.kind == .AdminList {
			count += 1
		}
	}
	return count
}

// Protocol 31 (#73): another manager's change to a room this admin is not in reaches the
// admin list without reopening Server settings, and changes that arrive while a fetch is out
// fetch once more after it.
@(test)
testAdminRoomChangedRefreshesTheAdminList :: proc(t: ^testing.T) {
	_ = t
	defer free_all(context.temp_allocator)
	sync.mutex_lock(&roomMemberSendBridgeTestMutex)
	defer sync.mutex_unlock(&roomMemberSendBridgeTestMutex)
	testRoomMembersUseStub()
	defer testRoomMembersRestore()
	state := testRoomMembersState(true)
	defer State_deinit(&state)

	// Before the Admin section ever listed rooms nothing is fetched.
	testApplyAdminRoomChanged(&state, 9, .Created)
	assert(
		testAdminListRequestCount() == 0,
		fmt.tprintf("expected no fetch before the list was loaded, got %v", testRoomMembersSent()),
	)

	State_requestAdminRooms(&state, ROOM_MEMBERS_TEST_SERVER)
	testApplyAdminRooms(&state, 1, 9)
	assert(testAdminListRequestCount() == 1, "expected the first fetch only")

	// Another admin creates room 10: the list is fetched again.
	testApplyAdminRoomChanged(&state, 10, .Created)
	assert(
		testAdminListRequestCount() == 2,
		fmt.tprintf("expected a fetch after the create, got %d", testAdminListRequestCount()),
	)
	// Two more changes while that fetch is out: one fetch after its answer, not two now.
	testApplyAdminRoomChanged(&state, 9, .Members)
	testApplyAdminRoomChanged(&state, 10, .Edited)
	assert(
		testAdminListRequestCount() == 2,
		"expected no second fetch while one is out",
	)
	testApplyAdminRooms(&state, 1, 9, 10)
	assert(
		testAdminListRequestCount() == 3,
		fmt.tprintf(
			"expected one more fetch after a stale answer, got %d",
			testAdminListRequestCount(),
		),
	)
	testApplyAdminRooms(&state, 1, 9, 10)
	assert(testAdminListRequestCount() == 3, "expected the fresh answer to end the fetches")
	assert(
		State_knownRoom(&state, ROOM_MEMBERS_TEST_SERVER, 10) != nil,
		"expected the other admin's new room listed",
	)

	// A deletion takes the room off the list at once, and fetches again.
	testApplyAdminRoomChanged(&state, 9, .Deleted)
	assert(
		State_knownRoom(&state, ROOM_MEMBERS_TEST_SERVER, 9) == nil,
		"expected the deleted room gone before the next list arrives",
	)
	assert(testAdminListRequestCount() == 4, "expected a fetch after the delete")
}

@(test)
testHeadlessPrintsAdminRoomChanged :: proc(t: ^testing.T) {
	_ = t
	event := ClientTransportRuntimeEvent {
		kind            = .AdminRoomChanged,
		serverID        = ROOM_MEMBERS_TEST_SERVER,
		roomID          = 12,
		adminRoomChange = .Permissions,
	}
	line, kind, rendered := headlessRenderRuntimeEvent(&event)
	defer delete(line)
	assert(
		rendered &&
		kind == .AdminRoomChanged &&
		line ==
			`{"event":"admin_room_changed","serverID":957,"roomID":12,"change":"permissions"}`,
		fmt.tprintf("expected admin_room_changed for room 12, got %q", line),
	)
}

// Protocol 32 (#72): a ban that could not change some encrypted rooms names them, by name when
// the client knows the room, as a warning under the banned account's row; the next answer
// replaces it.
@(test)
testAdminSectionNamesTheRoomsABanCouldNotChange :: proc(t: ^testing.T) {
	state := testRoomMembersState(true)
	defer State_deinit(&state)
	state.adminRequest.serverID = 957
	state.adminRequest.pending = true
	event := ClientTransportRuntimeEvent {
		kind        = .AdminActionResult,
		serverID    = 957,
		adminAction = .Ban,
		peerUserID  = 4,
		message     = strings.clone("Banned bob; 2 encrypted rooms could not be changed"),
	}
	append(&event.failedRoomIDs, 2, 77)
	State_applyRuntimeEvent(&state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
	view := buildAdminSectionView(&state, 957)
	expected :=
		"Banned bob; 2 encrypted rooms could not be changed. These encrypted rooms still " +
		"list them: # team, room 77. Their member lists are damaged or were busy: ban them " +
		"again to retry, and if one stays, use Check member logs under Member logs to " +
		"repair it."
	testing.expect(
		t,
		view.statusTone == .Warning && view.statusUserID == 4 && view.status == expected,
		fmt.tprintf("expected the rooms named as a warning, got %v %q", view.statusTone,
			view.status),
	)

	state.adminRequest.pending = true
	unban := ClientTransportRuntimeEvent {
		kind        = .AdminActionResult,
		serverID    = 957,
		adminAction = .Ban,
		peerUserID  = 4,
		message     = strings.clone("Unbanned bob"),
	}
	State_applyRuntimeEvent(&state, &unban)
	ClientTransportRuntimeEvent_deinit(&unban)
	view = buildAdminSectionView(&state, 957)
	testing.expect(
		t,
		view.statusTone == .Success && view.status == "Unbanned bob",
		fmt.tprintf("expected the next answer to replace the warning, got %q", view.status),
	)
}
