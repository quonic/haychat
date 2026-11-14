#+feature dynamic-literals
package client

import "../common"
import "core:fmt"
import "core:strings"
import "core:testing"

// The Server settings screen (server_settings.odin): opening and closing, Save with the
// reconnect rule for the per-server name and address, labels, Forget key, Remove server, and
// the Voice section's rows.

@(private = "file")
serverSettingsTestState :: proc() -> State {
	return testStateWithServers(
		{
			Server {
				id = 861,
				name = "Home",
				host = "home.example",
				port = 1,
				pinned_server_public_key = "aa",
				pinned_server_fingerprint = "AA:BB",
			},
			Server{id = 862, name = "Work", host = "work.example", port = 1},
		},
	)
}

@(private = "file")
serverSettingsTestTransport :: proc(state: ^State, serverID: int) -> ^ClientServerTransport {
	index := State_selectedTransportIndexForServerID(state^, serverID)
	assert(index >= 0, fmt.tprintf("expected a transport for server %d", serverID))
	return &state.serverTransports[index]
}

// Markers that survive only while a server's transport is kept (not rebuilt).
@(private = "file")
serverSettingsTestMarkTransports :: proc(state: ^State) {
	serverSettingsTestTransport(state, 861).authenticatedUserID = 5
	serverSettingsTestTransport(state, 862).authenticatedUserID = 6
}

@(private = "file")
serverSettingsTestKept :: proc(state: ^State, serverID: int) -> bool {
	marker := serverID == 861 ? 5 : 6
	return serverSettingsTestTransport(state, serverID).authenticatedUserID == marker
}

@(test)
testServerSettingsOpenAndClose :: proc(t: ^testing.T) {
	state := serverSettingsTestState()
	defer State_deinit(&state)
	assert(!State_openServerSettings(&state, 999), "expected an unknown server refused")

	// Opening another server's settings switches to it and closes the room form.
	state.selected_server_id = 861
	state.roomEditor.mode = .Create
	state.roomEditor.serverID = 861
	assert(State_openServerSettings(&state, 862), "expected the screen to open")
	assert(
		state.selected_server_id == 862 && State_serverSettingsVisible(&state),
		"expected server 862 selected with its settings shown",
	)
	assert(state.roomEditor.mode == .Closed, "expected the room form closed")
	form := &state.serverSettings
	assert(
		string(form.label[:]) == "Work" &&
		string(form.shortLabel[:]) == "Wo" &&
		string(form.host[:]) == "work.example" &&
		string(form.port[:]) == "1" &&
		len(form.displayName) == 0,
		"expected the fields filled from the config",
	)
	view := buildServerSettingsView(&state)
	assert(
		view.visible && view.title == "Work settings" && !view.hasPinnedKey,
		fmt.tprintf("unexpected view %v", view),
	)

	// The screen hides the room, so the room is not viewed (read state).
	state.windowFocused = true
	state.selected_channel_id = common.GENERAL_ROOM_ID
	assert(
		!State_isConversationViewed(&state, .Room, 862, common.GENERAL_ROOM_ID),
		"expected a room behind the screen not to count as viewed",
	)

	// Switching rooms or servers, opening a conversation, the room form or the general
	// settings closes it.
	State_switchToChannel(&state, 862, common.GENERAL_ROOM_ID)
	assert(!state.serverSettings.open, "expected a room switch to close the screen")
	assert(
		State_isConversationViewed(&state, .Room, 862, common.GENERAL_ROOM_ID),
		"expected the room viewed again",
	)
	State_openServerSettings(&state, 862)
	State_switchToServer(&state, 861)
	assert(!state.serverSettings.open, "expected a server switch to close the screen")
	State_openServerSettings(&state, 861)
	testApplyConnected(&state, 861, 40)
	State_openDirectConversation(&state, 861, 41)
	assert(!state.serverSettings.open, "expected a conversation to close the screen")
	State_openServerSettings(&state, 861)
	assert(state.selected_dm_peer_id == 41, "expected the conversation kept underneath")
	State_openSettings(&state)
	assert(!state.serverSettings.open, "expected the general settings to close the screen")
	State_closeSettings(&state)
	State_openServerSettings(&state, 861)
	State_closeServerSettings(&state)
	assert(!State_serverSettingsVisible(&state), "expected Close to close the screen")
	_ = t
}

// Save with a per-server display name renames the account on that server only: only its
// transport is rebuilt, with the new name, and the global name keeps working elsewhere. A
// global rename then skips the server that has a name of its own.
@(test)
testServerSettingsDisplayNameReconnectsOnlyThatServer :: proc(t: ^testing.T) {
	state := serverSettingsTestState()
	defer State_deinit(&state)
	serverSettingsTestMarkTransports(&state)
	testApplyRoomChat(&state, 861, common.GENERAL_ROOM_ID, 1, 1, "home")
	testApplyRoomChat(&state, 862, common.GENERAL_ROOM_ID, 1, 1, "work")

	State_openServerSettings(&state, 862)
	testSetDraft(&state.serverSettings.displayName, "x")
	assert(!State_applyServerSettings(&state), "expected a too short name refused")
	assert(len(state.serverSettings.error) > 0, "expected the refusal explained")
	assert(serverSettingsTestKept(&state, 862), "expected nothing rebuilt by a refusal")

	testSetDraft(&state.serverSettings.displayName, "  Tester at work ")
	assert(State_applyServerSettings(&state), "expected the name to apply")
	server, _ := State_serverConfig(&state, 862)
	assert(server.display_name == "Tester at work", "expected the trimmed name stored")
	assert(serverSettingsTestKept(&state, 861), "expected the other server's session kept")
	work := serverSettingsTestTransport(&state, 862)
	assert(
		work.authenticatedUserID == 0 && work.nickname == "Tester at work",
		fmt.tprintf("expected server 862 rebuilt as the new name, got %q", work.nickname),
	)
	assert(
		serverSettingsTestTransport(&state, 861).nickname == "Tester",
		"expected the global name on the other server",
	)
	assert(
		State_serverRoomCacheIndex(state, 861) >= 0 && State_serverRoomCacheIndex(state, 862) < 0,
		"expected only the renamed server to lose its room cache",
	)
	assert(
		state.serverSettings.open && strings.contains(state.serverSettings.notice, "Reconnect"),
		"expected the screen to stay open and say it reconnects",
	)

	// Saving again with nothing changed reconnects nothing.
	serverSettingsTestMarkTransports(&state)
	assert(State_applyServerSettings(&state), "expected an unchanged save to apply")
	assert(
		serverSettingsTestKept(&state, 861) && serverSettingsTestKept(&state, 862),
		"expected an unchanged save to keep every session",
	)

	// A new global name reconnects only the server that uses it.
	State_openSettings(&state)
	testSetDraft(&state.settings.displayName, "Renamed")
	assert(State_applySettings(&state), "expected the global rename to apply")
	assert(
		!serverSettingsTestKept(&state, 861) &&
		serverSettingsTestTransport(&state, 861).nickname == "Renamed",
		"expected the server without its own name to reconnect as the new global name",
	)
	assert(serverSettingsTestKept(&state, 862), "expected the server with its own name kept")

	// Clearing the per-server name goes back to the global one, which reconnects.
	serverSettingsTestMarkTransports(&state)
	State_openServerSettings(&state, 862)
	testSetDraft(&state.serverSettings.displayName, "")
	assert(State_applyServerSettings(&state), "expected the cleared name to apply")
	server, _ = State_serverConfig(&state, 862)
	assert(server.display_name == "", "expected no per-server name stored")
	assert(
		serverSettingsTestTransport(&state, 862).nickname == "Renamed" &&
		!serverSettingsTestKept(&state, 862) &&
		serverSettingsTestKept(&state, 861),
		"expected only server 862 to reconnect as the global name",
	)
	_ = t
}

// Labels change the rail and headers without reconnecting; an empty label or short label is
// filled in, and a new address reconnects only that server with its pin cleared.
@(test)
testServerSettingsLabelsAndAddress :: proc(t: ^testing.T) {
	state := serverSettingsTestState()
	defer State_deinit(&state)
	serverSettingsTestMarkTransports(&state)

	State_openServerSettings(&state, 861)
	form := &state.serverSettings
	testSetDraft(&form.label, "Family Chat")
	assert(State_applyServerSettings(&state), "expected the label to apply")
	server, _ := State_serverConfig(&state, 861)
	assert(
		server.name == "Family Chat" && server.short_name == "FC",
		fmt.tprintf("expected the short label to follow the label, got %q", server.short_name),
	)
	assert(
		serverSettingsTestKept(&state, 861) && serverSettingsTestKept(&state, 862),
		"expected a label change to reconnect nothing",
	)
	assert(form.notice == "Saved.", fmt.tprintf("expected a plain notice, got %q", form.notice))

	testSetDraft(&form.shortLabel, "Fam!")
	assert(!State_applyServerSettings(&state), "expected a 4-character short label refused")
	testSetDraft(&form.shortLabel, "F")
	testSetDraft(&form.label, "Family")
	assert(State_applyServerSettings(&state), "expected a chosen short label to apply")
	server, _ = State_serverConfig(&state, 861)
	assert(
		server.name == "Family" && server.short_name == "F",
		"expected a chosen short label kept when the label changes",
	)
	testSetDraft(&form.label, "")
	testSetDraft(&form.shortLabel, "")
	assert(State_applyServerSettings(&state), "expected empty labels to apply")
	server, _ = State_serverConfig(&state, 861)
	assert(
		server.name == "home.example:1" && server.short_name == "ho",
		fmt.tprintf("expected labels from the address, got %q %q", server.name, server.short_name),
	)
	testSetDraft(&form.label, "Line\tbreak")
	assert(!State_applyServerSettings(&state), "expected a tab in the label refused")
	// Opening again reloads the fields from the config.
	State_openServerSettings(&state, 861)
	assert(string(form.label[:]) == "home.example:1", "expected the stored label back")

	// Another server's address is refused; a new one reconnects only this server.
	testSetDraft(&form.host, "work.example")
	assert(!State_applyServerSettings(&state), "expected a duplicate address refused")
	testSetDraft(&form.host, "moved.example:2")
	testSetDraft(&form.port, "")
	assert(State_applyServerSettings(&state), "expected the new address to apply")
	server, _ = State_serverConfig(&state, 861)
	assert(
		server.host == "moved.example" &&
		server.port == 2 &&
		server.name == "moved.example:2" &&
		server.short_name == "mo" &&
		len(server.pinned_server_public_key) == 0,
		fmt.tprintf("expected the automatic labels to follow and the pin cleared, got %v", server^),
	)
	moved := serverSettingsTestTransport(&state, 861)
	assert(
		moved.authenticatedUserID == 0 && moved.serverHost == "moved.example",
		"expected the moved server to reconnect to its new address",
	)
	assert(serverSettingsTestKept(&state, 862), "expected the other server kept")
	_ = t
}

// Forget key takes two clicks, clears the pin and reconnects only that server; Remove server
// takes two clicks and closes the screen.
@(test)
testServerSettingsForgetKeyAndRemoveServer :: proc(t: ^testing.T) {
	state := serverSettingsTestState()
	defer State_deinit(&state)
	serverSettingsTestMarkTransports(&state)

	State_openServerSettings(&state, 861)
	view := buildServerSettingsView(&state)
	assert(
		view.hasPinnedKey && view.fingerprint == "AA:BB" && view.forgetKeyLabel == "Forget key",
		"expected the pinned fingerprint shown",
	)
	State_serverSettingsForgetKey(&state)
	view = buildServerSettingsView(&state)
	assert(view.forgetKeyLabel == "Confirm forget key", "expected the first click to arm it")
	server, _ := State_serverConfig(&state, 861)
	assert(len(server.pinned_server_public_key) > 0, "expected the pin kept after one click")
	assert(serverSettingsTestKept(&state, 861), "expected nothing reconnected after one click")
	State_serverSettingsForgetKey(&state)
	server, _ = State_serverConfig(&state, 861)
	assert(
		len(server.pinned_server_public_key) == 0 && len(server.pinned_server_fingerprint) == 0,
		"expected the pin cleared",
	)
	transport := serverSettingsTestTransport(&state, 861)
	assert(
		transport.authenticatedUserID == 0 && len(transport.pinnedServerPublicKey) == 0,
		"expected server 861 rebuilt without a pin",
	)
	assert(serverSettingsTestKept(&state, 862), "expected the other server kept")
	assert(!buildServerSettingsView(&state).hasPinnedKey, "expected no fingerprint shown")
	// Nothing to forget any more.
	State_serverSettingsForgetKey(&state)
	assert(!state.serverSettings.confirmForgetKey, "expected nothing armed without a pin")

	// Any other action disarms Remove.
	State_serverSettingsRemoveServer(&state)
	assert(state.serverSettings.confirmRemove, "expected the first click to arm Remove")
	State_applyServerSettings(&state)
	assert(!state.serverSettings.confirmRemove, "expected Save to disarm Remove")
	State_serverSettingsRemoveServer(&state)
	State_serverSettingsRemoveServer(&state)
	_, stillThere := State_serverConfig(&state, 861)
	assert(!stillThere, "expected the server removed")
	assert(!state.serverSettings.open, "expected the screen closed with its server")
	assert(
		len(state.serverTransports) == 1 && serverSettingsTestKept(&state, 862),
		"expected only the removed server's transport closed",
	)
	_ = t
}

// The Voice section lists every other user of the server, those in voice first, users in a
// participant list the directory does not have yet, and stored settings for users it cannot
// see; the screen's slider and Mute for me go through the State actions.
@(test)
testServerSettingsVoiceRows :: proc(t: ^testing.T) {
	state := serverSettingsTestState()
	defer State_deinit(&state)
	view := buildServerVoiceUserRows(&state, 861)
	assert(len(view) == 0, "expected no rows before the server is connected")
	State_setUserVoiceVolume(&state, 861, 70, 0.3)

	testApplyConnected(&state, 861, 10)
	users := make([dynamic]common.UserSummary)
	append(&users, common.UserSummary{id = 10, nickname = strings.clone("Tester"), isOnline = true})
	append(&users, common.UserSummary{id = 11, nickname = strings.clone("bob"), isOnline = true})
	append(&users, common.UserSummary{id = 12, nickname = strings.clone("carol")})
	append(&users, common.UserSummary{id = 13, nickname = strings.clone("dave"), isOnline = true})
	State_receiveUserList(&state, 861, &users)
	participants := make([dynamic]common.VoiceParticipant)
	append(&participants, common.VoiceParticipant{userId = 13, nickname = strings.clone("dave")})
	append(&participants, common.VoiceParticipant{userId = 14, nickname = strings.clone("erin")})
	append(&participants, common.VoiceParticipant{userId = 10, nickname = strings.clone("Tester")})
	State_receiveVoiceParticipants(&state, 861, common.GENERAL_ROOM_ID, &participants, false)
	State_setUserVoiceMuted(&state, 861, 11, true)

	rows := buildServerVoiceUserRows(&state, 861)
	labels := make([dynamic]string, context.temp_allocator)
	for row in rows {
		append(&labels, row.label)
	}
	expected := []string{"dave", "erin", "bob", "carol", "User 70"}
	assert(
		len(rows) == len(expected),
		fmt.tprintf("expected %v, got %v", expected, labels),
	)
	for label, index in expected {
		assert(labels[index] == label, fmt.tprintf("expected %v, got %v", expected, labels))
	}
	assert(rows[0].inVoice && rows[1].inVoice && !rows[2].inVoice, "expected voice users first")
	assert(rows[2].muted && rows[2].volume == 1, "expected bob muted for me")
	assert(rows[4].volume == 0.3 && !rows[4].isOnline, "expected the stored volume for user 70")
	_ = t
}
