#+feature dynamic-literals
package client

import "../common"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

// The admin UI (admin_ui.odin): the Admin section of Server settings (shown only to admins,
// disabled per D6), its confirmations and the request each sends through adminSendBridge, the
// room type selector and the voice-only and text-only room views, and the Profile section of
// a name an admin locked.

ADMIN_UI_TEST_SELF :: 3
ADMIN_UI_TEST_BOB :: 9
ADMIN_UI_TEST_CAROL :: 11 // Another admin
ADMIN_UI_TEST_DAVE :: 12 // Banned

// Signed in on serverID as user 3 with the admin flag given, a directory of self, bob, carol
// (an admin) and dave (banned), and rooms 1 (general) and 2 (lounge).
@(private = "file")
adminUITestState :: proc(serverID: int, isAdmin: bool) -> State {
	state := testUpdateStateForServer(testRoomAdminServer(serverID))
	testApplyConnectedAs(&state, serverID, ADMIN_UI_TEST_SELF, isAdmin)
	testApplyNamedRooms(&state, serverID, {id = 1, name = "general"}, {id = 2, name = "lounge"})
	testApplyUserList(
		&state,
		serverID,
		{id = ADMIN_UI_TEST_SELF, nickname = "alice", isOnline = true, isAdmin = isAdmin},
		{id = ADMIN_UI_TEST_BOB, nickname = "bob", isOnline = true},
		{id = ADMIN_UI_TEST_CAROL, nickname = "carol", isAdmin = true},
		{id = ADMIN_UI_TEST_DAVE, nickname = "dave", isBanned = true},
	)
	return state
}

// "label" or "label (off: reason)".
@(private = "file")
adminUITestControl :: proc(control: AdminControl) -> string {
	if control.enabled {
		return control.label
	}
	return fmt.tprintf("%s (off: %s)", control.label, control.reason)
}

@(private = "file")
adminUITestControls :: proc(state: ^State, serverID, userID: int) -> string {
	controls, known := buildAdminUserControls(state, serverID, userID)
	if !known {
		return "unknown"
	}
	return fmt.tprintf(
		"%s|%s|%s|%s",
		adminUITestControl(controls.rename),
		adminUITestControl(controls.role),
		adminUITestControl(controls.kick),
		adminUITestControl(controls.ban),
	)
}

@(test)
testAdminControlsAreDisabledWhereTheServerRefuses :: proc(t: ^testing.T) {
	state := adminUITestState(1101, true)
	defer State_deinit(&state)

	testExpectString(
		t,
		adminUITestControls(&state, 1101, ADMIN_UI_TEST_SELF),
		fmt.tprintf(
			"Rename…|Remove admin (off: %s)|Kick… (off: %s)|Ban… (off: %s)",
			ADMIN_REASON_SELF_REVOKE,
			ADMIN_REASON_SELF_KICK,
			ADMIN_REASON_SELF_BAN,
		),
		"yourself: rename only",
	)
	testExpectString(
		t,
		adminUITestControls(&state, 1101, ADMIN_UI_TEST_BOB),
		"Rename…|Make admin|Kick…|Ban…",
		"a member: everything",
	)
	testExpectString(
		t,
		adminUITestControls(&state, 1101, ADMIN_UI_TEST_CAROL),
		fmt.tprintf(
			"Rename…|Remove admin|Kick… (off: %s)|Ban… (off: %s)",
			ADMIN_REASON_ADMIN_KICK,
			ADMIN_REASON_ADMIN_BAN,
		),
		"another admin: revoke first",
	)
	testExpectString(
		t,
		adminUITestControls(&state, 1101, ADMIN_UI_TEST_DAVE),
		fmt.tprintf("Rename…|Make admin (off: %s)|Kick…|Unban", ADMIN_REASON_BANNED_GRANT),
		"a banned account: unban, no role",
	)
	testExpectString(t, adminUITestControls(&state, 1101, 77), "unknown", "an unlisted account")
}

@(test)
testAdminSectionIsShownOnlyToAdmins :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	{
		state := adminUITestState(1102, false)
		defer State_deinit(&state)
		testing.expect(t, State_openServerSettings(&state, 1102), "expected the screen to open")
		view := buildServerSettingsView(&state)
		testing.expect(t, view.visible && !view.admin.visible, "expected no Admin section")
		testing.expect(
			t,
			!State_openAdminConfirm(&state, 1102, .Kick, ADMIN_UI_TEST_BOB),
			"expected no confirmation for a member",
		)
	}

	state := adminUITestState(1102, true)
	defer State_deinit(&state)
	testing.expect(t, State_openServerSettings(&state, 1102), "expected the screen to open")
	view := buildServerSettingsView(&state)
	testing.expect(t, view.admin.visible, "expected the Admin section for an admin")
	labels := make([dynamic]string, context.temp_allocator)
	for member in view.admin.members {
		append(
			&labels,
			fmt.tprintf(
				"%s%s%s",
				member.label,
				member.isAdmin ? "+admin" : "",
				member.isBanned ? "+banned" : "",
			),
		)
	}
	testExpectString(
		t,
		strings.join(labels[:], ",", context.temp_allocator),
		"alice (you)+admin,bob,carol+admin,dave+banned",
		"the member table, by name",
	)
	rooms := make([dynamic]string, context.temp_allocator)
	for room in view.admin.rooms {
		append(&rooms, fmt.tprintf("%s:%s", room.label, room.typeLabel))
	}
	testExpectString(
		t,
		strings.join(rooms[:], ",", context.temp_allocator),
		"# general:Text and voice,# lounge:Text and voice",
		"the rooms list",
	)

	// Losing the role hides the section at once (ServerAccountUpdated).
	event := ClientTransportRuntimeEvent {
		kind     = .AccountUpdated,
		serverID = 1102,
		isAdmin  = false,
	}
	State_applyRuntimeEvent(&state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
	testing.expect(
		t,
		!buildServerSettingsView(&state).admin.visible,
		"expected the section gone with the role",
	)
}

@(test)
testAdminConfirmationsSendTheRightRequest :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	sync.mutex_lock(&adminSendBridgeTestMutex)
	defer sync.mutex_unlock(&adminSendBridgeTestMutex)
	testAdminUseStub()
	defer testAdminRestore()

	state := adminUITestState(1103, true)
	defer State_deinit(&state)
	confirm := &state.serverSettings.adminConfirm

	// Rename from a menu opens the screen with the confirmation; the lock starts on.
	testing.expect(
		t,
		State_openAdminConfirm(&state, 1103, .Rename, ADMIN_UI_TEST_BOB),
		"expected the rename confirmation",
	)
	testing.expect(
		t,
		State_serverSettingsVisible(&state) &&
		confirm.kind == .Rename &&
		confirm.userID == ADMIN_UI_TEST_BOB &&
		confirm.lockName &&
		confirm.scrollTo,
		fmt.tprintf("expected Server settings open on bob's rename, got %v", confirm^),
	)
	view := buildServerSettingsView(&state)
	testExpectString(t, view.admin.confirm.title, "Rename bob", "the confirmation title")
	testExpectString(t, view.admin.confirm.lockLabel, "Lock name: on", "the lock label")
	append(&confirm.text, " robert ")
	testing.expect(t, State_submitAdminConfirm(&state), "expected the rename sent")
	testing.expect(
		t,
		adminSendBridgeTestLast.action == .Rename &&
		adminSendBridgeTestLast.userID == ADMIN_UI_TEST_BOB &&
		adminSendBridgeTestLast.nickname == "robert" &&
		adminSendBridgeTestLast.flag,
		fmt.tprintf("expected a locked rename to robert, got %v", adminSendBridgeTestLast),
	)
	testing.expect(t, confirm.kind == .None, "expected the confirmation closed once sent")
	view = buildServerSettingsView(&state)
	testExpectString(t, view.admin.status, "Waiting for the server…", "the waiting status")
	testing.expect(t, view.admin.statusUserID == ADMIN_UI_TEST_BOB, "expected it on bob's row")

	// Lock off with an empty name unlocks the current name.
	State_openAdminConfirm(&state, 1103, .Rename, ADMIN_UI_TEST_BOB)
	State_toggleAdminConfirmLock(&state)
	State_submitAdminConfirm(&state)
	testing.expect(
		t,
		adminSendBridgeTestLast.action == .Rename &&
		adminSendBridgeTestLast.nickname == "" &&
		!adminSendBridgeTestLast.flag,
		fmt.tprintf("expected an unlock, got %v", adminSendBridgeTestLast),
	)

	// A name the server would refuse is caught here and the confirmation stays open.
	count := adminSendBridgeTestCount
	State_openAdminConfirm(&state, 1103, .Rename, ADMIN_UI_TEST_BOB)
	append(&confirm.text, "ab")
	testing.expect(t, !State_submitAdminConfirm(&state), "expected a short name refused")
	testing.expect(
		t,
		adminSendBridgeTestCount == count && confirm.kind == .Rename,
		"expected nothing sent and the confirmation kept",
	)
	view = buildServerSettingsView(&state)
	testing.expect(
		t,
		view.admin.statusTone == .Error &&
		strings.has_prefix(view.admin.status, "Names must be 3 to 32 bytes"),
		fmt.tprintf("expected the reason as the status, got %q", view.admin.status),
	)
	State_cancelAdminConfirm(&state)
	testing.expect(t, confirm.kind == .None && len(confirm.text) == 0, "expected cancel clears")

	// Kick and ban with a reason.
	State_openAdminConfirm(&state, 1103, .Kick, ADMIN_UI_TEST_BOB)
	append(&confirm.text, "cool off")
	State_submitAdminConfirm(&state)
	testing.expect(
		t,
		adminSendBridgeTestLast.action == .Kick && adminSendBridgeTestLast.reason == "cool off",
		fmt.tprintf("expected the kick, got %v", adminSendBridgeTestLast),
	)
	State_openAdminConfirm(&state, 1103, .Ban, ADMIN_UI_TEST_BOB)
	testExpectString(t, buildServerSettingsView(&state).admin.confirm.title, "Ban bob", "title")
	append(&confirm.text, "spam")
	State_submitAdminConfirm(&state)
	testing.expect(
		t,
		adminSendBridgeTestLast.action == .Ban &&
		adminSendBridgeTestLast.flag &&
		adminSendBridgeTestLast.reason == "spam",
		fmt.tprintf("expected the ban, got %v", adminSendBridgeTestLast),
	)

	// Unban, Make admin, Remove admin act at once.
	testing.expect(t, State_adminUnban(&state, 1103, ADMIN_UI_TEST_DAVE), "expected the unban")
	testing.expect(
		t,
		adminSendBridgeTestLast == AdminRequest{action = .Ban, userID = ADMIN_UI_TEST_DAVE},
		fmt.tprintf("expected an unban, got %v", adminSendBridgeTestLast),
	)
	testing.expect(t, State_adminSetRole(&state, 1103, ADMIN_UI_TEST_BOB, true), "make admin")
	testing.expect(
		t,
		adminSendBridgeTestLast ==
		AdminRequest{action = .SetRole, userID = ADMIN_UI_TEST_BOB, flag = true},
		fmt.tprintf("expected a grant, got %v", adminSendBridgeTestLast),
	)
	testing.expect(t, State_adminSetRole(&state, 1103, ADMIN_UI_TEST_CAROL, false), "revoke")
	testing.expect(
		t,
		adminSendBridgeTestLast == AdminRequest{action = .SetRole, userID = ADMIN_UI_TEST_CAROL},
		fmt.tprintf("expected a revoke, got %v", adminSendBridgeTestLast),
	)

	// What D6 refuses is never sent.
	count = adminSendBridgeTestCount
	testing.expect(
		t,
		!State_openAdminConfirm(&state, 1103, .Kick, ADMIN_UI_TEST_SELF) &&
		!State_openAdminConfirm(&state, 1103, .Ban, ADMIN_UI_TEST_CAROL) &&
		!State_openAdminConfirm(&state, 1103, .Ban, ADMIN_UI_TEST_DAVE) &&
		!State_adminSetRole(&state, 1103, ADMIN_UI_TEST_SELF, false) &&
		!State_adminSetRole(&state, 1103, ADMIN_UI_TEST_DAVE, true) &&
		!State_adminUnban(&state, 1103, ADMIN_UI_TEST_BOB),
		"expected the refused actions not to start",
	)
	testing.expect(t, adminSendBridgeTestCount == count, "expected nothing sent for them")

	// The server's answer becomes the status.
	result := ClientTransportRuntimeEvent {
		kind        = .AdminActionResult,
		serverID    = 1103,
		adminAction = .SetRole,
		peerUserID  = ADMIN_UI_TEST_CAROL,
		message     = strings.clone("carol is no longer an admin"),
	}
	State_applyRuntimeEvent(&state, &result)
	ClientTransportRuntimeEvent_deinit(&result)
	view = buildServerSettingsView(&state)
	testing.expect(
		t,
		view.admin.statusTone == .Success && view.admin.status == "carol is no longer an admin",
		fmt.tprintf("expected the server's sentence, got %q", view.admin.status),
	)
	// A new visit starts without the old answer, and closing drops the confirmation.
	State_openAdminConfirm(&state, 1103, .Kick, ADMIN_UI_TEST_BOB)
	State_closeServerSettings(&state)
	testing.expect(t, confirm.kind == .None, "expected close to drop the confirmation")
	State_openServerSettings(&state, 1103)
	testExpectString(t, buildServerSettingsView(&state).admin.status, "", "no stale status")
}

@(test)
testRoomFormTypeSelectorSendsTheType :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	sync.mutex_lock(&roomAdminSendBridgeTestMutex)
	defer sync.mutex_unlock(&roomAdminSendBridgeTestMutex)
	testRoomAdminUseStub()
	defer testRoomAdminRestore()

	state := adminUITestState(1104, true)
	defer State_deinit(&state)

	State_openRoomCreator(&state)
	view := buildRoomEditorView(&state)
	testing.expect(t, view.roomType == .ChatAndVoice, "expected Create to start at both")
	State_setRoomEditorType(&state, .Voice)
	State_setRoomEditorType(&state, .Forum) // Not offered: ignored
	view = buildRoomEditorView(&state)
	testing.expect(t, view.roomType == .Voice, fmt.tprintf("expected voice, got %v", view.roomType))
	testExpectString(t, view.typeNote, roomTypeNote(.Voice), "the voice-only note")
	append(&state.roomEditor.name, "stage")
	State_submitRoomEditor(&state)
	testing.expect(
		t,
		roomAdminSendBridgeTestKind == .Create && roomAdminSendBridgeTestRoomType == .Voice,
		fmt.tprintf("expected a voice-only create, got %v", roomAdminSendBridgeTestRoomType),
	)

	// Edit to text-only warns about the people in its voice and sends the type.
	State_closeRoomEditor(&state)
	voice := ClientTransportRuntimeEvent {
		kind     = .VoiceParticipants,
		serverID = 1104,
		roomID   = 2,
	}
	append(
		&voice.voiceParticipants,
		common.VoiceParticipant{userId = ADMIN_UI_TEST_BOB, nickname = strings.clone("bob")},
	)
	State_applyRuntimeEvent(&state, &voice)
	ClientTransportRuntimeEvent_deinit(&voice)
	State_openRoomEditor(&state, 2)
	testing.expect(t, buildRoomEditorView(&state).typeWarning == "", "expected no warning yet")
	State_setRoomEditorType(&state, .Chat)
	testExpectString(
		t,
		buildRoomEditorView(&state).typeWarning,
		"1 person in this room's voice will be removed from it when you save.",
		"the text-only warning",
	)
	State_submitRoomEditor(&state)
	testing.expect(
		t,
		roomAdminSendBridgeTestKind == .Edit &&
		roomAdminSendBridgeTestRoomID == 2 &&
		roomAdminSendBridgeTestRoomType == .Chat,
		fmt.tprintf("expected a text-only edit, got %v", roomAdminSendBridgeTestRoomType),
	)
}

@(test)
testVoiceOnlyAndTextOnlyRoomViews :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := adminUITestState(1105, false)
	defer State_deinit(&state)
	testApplyNamedRooms(
		&state,
		1105,
		{id = 1, name = "general"},
		{id = 2, name = "stage", roomType = .Voice},
		{id = 3, name = "notes", roomType = .Chat},
	)

	view := buildRoomView(&state)
	testing.expect(t, view.allowsChat && view.voiceOnlyNote == "", "expected #general to chat")
	testing.expect(
		t,
		roomVoiceHeaderAction(&state, 1105, 1) == .Join,
		"expected Join voice in #general",
	)

	State_switchToChannel(&state, 1105, 2)
	view = buildRoomView(&state)
	testing.expect(
		t,
		!view.allowsChat && view.voiceOnlyNote == ROOM_VOICE_ONLY_NOTE,
		"expected a voice-only room to have no composer",
	)
	testing.expect(t, roomVoiceHeaderAction(&state, 1105, 2) == .Join, "expected Join voice")

	State_switchToChannel(&state, 1105, 3)
	view = buildRoomView(&state)
	testing.expect(t, view.allowsChat, "expected a text-only room to chat")
	testing.expect(
		t,
		roomVoiceHeaderAction(&state, 1105, 3) == .None,
		"expected no Join voice in a text-only room",
	)
}

@(test)
testProfileShowsANameAnAdminLocked :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := testUpdateStateForServer(testRoomAdminServer(1106))
	defer State_deinit(&state)
	testApplyConnected(&state, 1106, ADMIN_UI_TEST_SELF)
	State_openServerSettings(&state, 1106)
	view := buildServerSettingsView(&state)
	testing.expect(t, !view.nameLocked, "expected an unlocked name to be editable")

	event := ClientTransportRuntimeEvent {
		kind           = .AccountUpdated,
		serverID       = 1106,
		nickname       = strings.clone("Robert"),
		nicknameLocked = true,
	}
	State_applyRuntimeEvent(&state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
	view = buildServerSettingsView(&state)
	testing.expect(
		t,
		view.nameLocked && view.lockedName == "Robert",
		fmt.tprintf("expected the locked name shown, got %v %q", view.nameLocked, view.lockedName),
	)

	// The lock comes with sign-in too, and goes away with the connection.
	lost := ClientTransportRuntimeEvent {
		kind     = .Disconnected,
		serverID = 1106,
		message  = strings.clone("gone"),
	}
	State_applyRuntimeEvent(&state, &lost)
	ClientTransportRuntimeEvent_deinit(&lost)
	testing.expect(t, !buildServerSettingsView(&state).nameLocked, "expected no lock offline")
	connected := ClientTransportRuntimeEvent {
		kind           = .Connected,
		serverID       = 1106,
		userID         = ADMIN_UI_TEST_SELF,
		nickname       = strings.clone("Robert"),
		nicknameLocked = true,
	}
	State_applyRuntimeEvent(&state, &connected)
	ClientTransportRuntimeEvent_deinit(&connected)
	view = buildServerSettingsView(&state)
	testing.expect(t, view.nameLocked && view.lockedName == "Robert", "expected the lock again")
}
