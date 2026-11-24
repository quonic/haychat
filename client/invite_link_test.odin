package client

import "../common"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// haychat:// links (plan D19): parsing, the pin check, the confirmation, and the hand-off file
// between processes.

INVITE_LINK_TEST_KEY :: "abababababababababababababababababababababababababababababababab"
INVITE_LINK_TEST_OTHER_KEY :: "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd"

@(test)
testInviteLinksParse :: proc(t: ^testing.T) {
	{
		link, err := parseHaychatLink(
			"haychat://chat.example:4000/invite/0123456789abcdefghjkmnpqrstvwxyz?key=" +
			INVITE_LINK_TEST_KEY,
		)
		defer HaychatLink_deinit(&link)
		key, _ := common.identityPublicKeyFromHex(INVITE_LINK_TEST_KEY)
		testing.expect(
			t,
			err == .None &&
			link.kind == .Invite &&
			link.host == "chat.example" &&
			link.port == 4000 &&
			link.hasKey &&
			link.key == key &&
			link.code == "0123-4567-89AB-CDEF-GHJK-MNPQ-RSTV-WXYZ",
			fmt.tprintf("expected a good invite link, got %v", err),
		)
	}
	{
		link, err := parseHaychatLink("HAYCHAT://[::1]:12345/join")
		defer HaychatLink_deinit(&link)
		testing.expect(
			t,
			err == .None && link.kind == .Join && link.host == "::1" && link.port == 12345 &&
			!link.hasKey,
			fmt.tprintf("expected an IPv6 join link, got %v", err),
		)
	}
	{
		link, err := parseHaychatLink("haychat://10.0.0.2:12345/")
		defer HaychatLink_deinit(&link)
		testing.expect(t, err == .None && link.kind == .Join, "expected the old join form")
	}
	cases := [?]struct {
		url:  string,
		want: HaychatLinkError,
	} {
		{"https://chat.example:4000/join", .NotHaychat},
		{"haychat://chat.example/join", .BadPort},
		{"haychat://chat.example:0/join", .BadPort},
		{"haychat://chat.example:70000/join", .BadPort},
		{"haychat://chat.example:12a/join", .BadPort},
		{"haychat://:4000/join", .BadHost},
		{"haychat://chat_ex$mple:4000/join", .BadHost},
		{"haychat://-chat.example:4000/join", .BadHost},
		{"haychat://[zz::1]:4000/join", .BadHost},
		{"haychat://user@chat.example:4000/join", .NotHaychat},
		{"haychat://chat.example:4000/leave", .BadPath},
		{"haychat://chat.example:4000/invite/AAAA/more?key=" + INVITE_LINK_TEST_KEY, .BadPath},
		{"haychat://chat.example:4000/invite/ABCD-EFGH?key=" + INVITE_LINK_TEST_KEY, .BadCode},
		{"haychat://chat.example:4000/invite/0123456789ABCDEFGHJKMNPQRSTVWXYU?key=" +
			INVITE_LINK_TEST_KEY, .BadCode},
		{"haychat://chat.example:4000/invite/0123456789ABCDEFGHJKMNPQRSTVWXYZ", .MissingKey},
		{"haychat://chat.example:4000/invite/0123456789ABCDEFGHJKMNPQRSTVWXYZ?key=abcd", .BadKey},
		{"haychat://chat.example:4000/join?key=" + INVITE_LINK_TEST_KEY + "&key=" +
			INVITE_LINK_TEST_KEY, .BadKey},
		{"haychat://chat.example:4000/join#frag", .NotHaychat},
	}
	for testCase in cases {
		link, err := parseHaychatLink(testCase.url)
		HaychatLink_deinit(&link)
		testing.expect(
			t,
			err == testCase.want,
			fmt.tprintf("expected %s to be %v, got %v", testCase.url, testCase.want, err),
		)
	}
	testExpectString(
		t,
		redactHaychatLink("haychat://h:1/invite/SECRET-CODE?key=" + INVITE_LINK_TEST_KEY),
		"haychat://h:1/invite/<code>?key=" + INVITE_LINK_TEST_KEY,
		"the redacted link",
	)
	testExpectString(
		t,
		redactHaychatLink("haychat://h:1/join"),
		"haychat://h:1/join",
		"a join link, unchanged",
	)
	// The link a created invite gets parses back to the same server, key and code.
	built := buildInviteLink(
		"chat.example",
		4000,
		"0123-4567-89AB-CDEF-GHJK-MNPQ-RSTV-WXYZ",
		INVITE_LINK_TEST_KEY,
	)
	defer delete(built)
	link, err := parseHaychatLink(built)
	defer HaychatLink_deinit(&link)
	testing.expect(
		t,
		err == .None && link.code == "0123-4567-89AB-CDEF-GHJK-MNPQ-RSTV-WXYZ" && link.port == 4000,
		"expected the built link to parse back",
	)
	v6 := buildInviteLink("::1", 5, "X", "Y")
	defer delete(v6)
	testExpectString(t, v6, "haychat://[::1]:5/invite/X?key=Y", "an IPv6 link")
}

@(test)
testInviteLinkKeyMustMatchThePin :: proc(t: ^testing.T) {
	fingerprintOf :: proc(hexKey: string) -> string {
		key, _ := common.identityPublicKeyFromHex(hexKey)
		fingerprint := common.fingerprintToHex(common.fingerprintIdentityPublicKey(key))
		result := strings.clone(fingerprint, context.temp_allocator)
		delete(fingerprint)
		return result
	}
	pinned := Server {
		id                        = 1301,
		name                      = "Pinned",
		short_name                = "P",
		host                      = "chat.example",
		port                      = 4000,
		pinned_server_public_key  = INVITE_LINK_TEST_KEY,
		pinned_server_fingerprint = fingerprintOf(INVITE_LINK_TEST_KEY),
	}
	state := testUpdateStateForServer(pinned)
	defer State_deinit(&state)
	code := "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

	// Another key for that address is refused: no confirm, nothing changes.
	State_openLink(
		&state,
		fmt.tprintf(
			"haychat://CHAT.example:4000/invite/%s?key=%s",
			code,
			INVITE_LINK_TEST_OTHER_KEY,
		),
	)
	view := buildLinkConfirmView(&state)
	testing.expect(
		t,
		state.pendingLink.match == .KeyDiffers && view.visible && !view.canConfirm,
		"expected a link with another key than the pin to be refused",
	)
	testing.expect(
		t,
		len(State_confirmPendingLink(&state)) > 0 && len(state.signUpForm.code) == 0,
		"expected a refused link not to be followed",
	)
	State_cancelPendingLink(&state)
	testing.expect(t, !state.pendingLink.open, "expected Cancel to close it")

	// The pinned key: the server is matched, the code waits in the form, nothing is sent.
	State_openLink(
		&state,
		fmt.tprintf("haychat://chat.example:4000/invite/%s?key=%s", code, INVITE_LINK_TEST_KEY),
	)
	view = buildLinkConfirmView(&state)
	testing.expect(
		t,
		state.pendingLink.match == .Pinned && view.canConfirm && view.confirmLabel == "Continue",
		"expected the pinned server matched",
	)
	testExpectString(t, State_confirmPendingLink(&state), "", "following the link")
	index := State_selectedTransportIndexForServerID(state, 1301)
	testing.expect(
		t,
		!state.pendingLink.open &&
		len(state.config.servers) == 1 &&
		state.serverTransports[index].registering &&
		state.serverTransports[index].connection.status == .Disconnected,
		"expected the server to connect with registering set",
	)
	testExpectString(
		t,
		string(state.signUpForm.code[:]),
		"0123-4567-89AB-CDEF-GHJK-MNPQ-RSTV-WXYZ",
		"the code in the sign-up form",
	)
	server, _ := State_serverConfig(&state, 1301)
	testing.expect(t, !server.use_invite_code, "expected the link not to change the setting")

	// A new server is added with the link's key pinned.
	State_openLink(&state, "haychat://new.example:5000/join?key=" + INVITE_LINK_TEST_OTHER_KEY)
	testing.expect(t, state.pendingLink.match == .NewServer, "expected a new server")
	testExpectString(t, State_confirmPendingLink(&state), "", "joining a new server")
	added := false
	for entry in state.config.servers {
		if entry.host == "new.example" && entry.port == 5000 {
			added =
				entry.pinned_server_public_key == INVITE_LINK_TEST_OTHER_KEY &&
				entry.pinned_server_fingerprint == fingerprintOf(INVITE_LINK_TEST_OTHER_KEY) &&
				state.selected_server_id == entry.id
		}
	}
	testing.expect(t, added, "expected the new server added, pinned and selected")
	testing.expect(t, len(state.signUpForm.code) == 0, "expected a join link to fill no code")

	// A malformed link shows why and offers only Close.
	State_openLink(&state, "haychat://new.example:5000/invite/short?key=" + INVITE_LINK_TEST_KEY)
	view = buildLinkConfirmView(&state)
	testing.expect(
		t,
		view.visible && !view.canConfirm && view.text == haychatLinkErrorText(.BadCode),
		"expected a malformed code refused",
	)
}

@(test)
testLinkHandoffFileIsPrivateAndReadOnce :: proc(t: ^testing.T) {
	tempRoot, tempErr := os.temp_directory(context.temp_allocator)
	assert(tempErr == nil, "expected a temp directory")
	dir := fmt.tprintf("%s/haychat-handoff-test-%d", tempRoot, os.get_pid())
	_ = os.remove_all(dir)
	assert(os.make_directory_all(dir, os.perm(0o700)) == nil, "expected the test directory")
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/%s", dir, LINK_HANDOFF_FILE)
	url := "haychat://chat.example:4000/invite/0123456789ABCDEFGHJKMNPQRSTVWXYZ?key=" +
		INVITE_LINK_TEST_KEY

	testing.expect(t, writePrivateFileNew(path, transmute([]u8)url), "expected the hand-off")
	when ODIN_OS != .Windows {
		info, statErr := os.lstat(path, context.temp_allocator)
		testing.expect(
			t,
			statErr == nil && transmute(u32)info.mode & 0o777 == 0o600,
			fmt.tprintf("expected mode 0600, got %o", transmute(u32)info.mode & 0o777),
		)
	}
	data, ok := readPrivateFileOnce(path, HAYCHAT_LINK_MAX_BYTES)
	defer delete(data)
	testing.expect(t, ok && string(data) == url, "expected the link read back")
	testing.expect(t, !os.exists(path), "expected the file deleted once read")
	_, again := readPrivateFileOnce(path, HAYCHAT_LINK_MAX_BYTES)
	testing.expect(t, !again, "expected nothing the second time")

	// A stale file is replaced, never appended to.
	assert(writePrivateFileNew(path, transmute([]u8)string("stale")), "expected a stale file")
	testing.expect(t, writePrivateFileNew(path, transmute([]u8)url), "expected a replacement")
	data2, ok2 := readPrivateFileOnce(path, HAYCHAT_LINK_MAX_BYTES)
	defer delete(data2)
	testing.expect(t, ok2 && string(data2) == url, "expected only the new link")

	when ODIN_OS == .Linux {
		// A planted symbolic link is removed, not followed.
		target := fmt.tprintf("%s/target", dir)
		assert(os.write_entire_file(target, "keep") == nil, "expected the target")
		assert(os.symlink(target, path) == nil, "expected the planted link")
		testing.expect(t, writePrivateFileNew(path, transmute([]u8)url), "expected the hand-off")
		kept, _ := os.read_entire_file_from_path(target, context.temp_allocator)
		testing.expect(t, string(kept) == "keep", "expected the link's target untouched")
		replaced, _ := os.lstat(path, context.temp_allocator)
		testing.expect(t, replaced.type == .Regular, "expected a regular file in the link's place")
		_ = os.remove(path)

		// A file others can read is not trusted (and is deleted).
		assert(os.write_entire_file(path, url) == nil, "expected a loose file")
		assert(os.change_mode(path, os.perm(0o644)) == nil, "expected its mode")
		_, loose := readPrivateFileOnce(path, HAYCHAT_LINK_MAX_BYTES)
		testing.expect(t, !loose && !os.exists(path), "expected a readable file refused")
	}
}

// #108: a confirmed invite link outlives the transport. A settings change that rebuilds it
// (here the display name) keeps registering and the code; signing in clears both, and the
// code is never in the config.
@(test)
testInviteLinkSurvivesTransportRebuild :: proc(t: ^testing.T) {
	key, _ := common.identityPublicKeyFromHex(INVITE_LINK_TEST_KEY)
	fingerprint := common.fingerprintToHex(common.fingerprintIdentityPublicKey(key))
	defer delete(fingerprint)
	state := testUpdateStateForServer(
		Server {
			id = 1302,
			name = "Pinned",
			short_name = "P",
			host = "chat.example",
			port = 4000,
			pinned_server_public_key = INVITE_LINK_TEST_KEY,
			pinned_server_fingerprint = fingerprint,
		},
	)
	defer State_deinit(&state)
	code := "0123-4567-89AB-CDEF-GHJK-MNPQ-RSTV-WXYZ"
	State_openLink(
		&state,
		"haychat://chat.example:4000/invite/0123456789ABCDEFGHJKMNPQRSTVWXYZ?key=" +
		INVITE_LINK_TEST_KEY,
	)
	testExpectString(t, State_confirmPendingLink(&state), "", "following the link")
	transport := &state.serverTransports[State_selectedTransportIndexForServerID(state, 1302)]
	testing.expect(
		t,
		transport.registering && State_hasLinkInvite(&state, 1302),
		"expected the link to set registering and keep its invite",
	)
	oldEphemeral := transport.clientEphemeralPublicKey

	// A new display name rebuilds the transport (matchesConfig compares the nickname).
	server, _ := State_serverConfig(&state, 1302)
	delete(server.display_name)
	server.display_name = strings.clone("Carol")
	State_reconfigureNetwork(&state)
	transport = &state.serverTransports[State_selectedTransportIndexForServerID(state, 1302)]
	testing.expect(
		t,
		transport.clientEphemeralPublicKey != oldEphemeral,
		"expected the display name change to rebuild the transport",
	)
	testing.expect(
		t,
		transport.registering,
		"expected the rebuilt transport to connect with registering set",
	)
	testExpectString(
		t,
		state.signUpForm.linkInvite.code,
		code,
		"the invite's code after the rebuild",
	)

	// Settings applied to the kept transport (use_invite_code off) leave it on, too.
	State_setUseInviteCode(&state, 1302, true)
	State_setUseInviteCode(&state, 1302, false)
	testing.expect(t, transport.registering, "expected Use an invite code off to keep it on")

	// The form was wiped (another server's screen, an ended session): the server's
	// ServerRegistrationRequired fills it again.
	State_wipeSignUpForm(&state)
	testApplyRegistrationRequired(&state, 1302, .InviteOnly)
	testExpectString(
		t,
		string(state.signUpForm.code[:]),
		code,
		"the code in the sign-up form again",
	)

	// The code never reaches the config file.
	data, marshalErr := json.marshal(state.config)
	defer delete(data)
	testing.expect(t, marshalErr == nil, "expected the config to marshal")
	testing.expect(
		t,
		!strings.contains(string(data), code) &&
		!strings.contains(string(data), "0123456789ABCDEFGHJKMNPQRSTVWXYZ"),
		"expected the invite code never in config.json",
	)

	// Created (Connected with registered set) clears both.
	created := ClientTransportRuntimeEvent {
		kind             = .Connected,
		serverID         = 1302,
		userID           = 41,
		nickname         = strings.clone("Carol"),
		registered       = true,
		registrationMode = .InviteOnly,
	}
	State_applyRuntimeEvent(&state, &created)
	ClientTransportRuntimeEvent_deinit(&created)
	testing.expect(
		t,
		!transport.registering &&
		!State_hasLinkInvite(&state, 1302) &&
		len(state.signUpForm.linkInvite.code) == 0 &&
		len(state.signUpForm.code) == 0,
		"expected Created to clear registering and the code",
	)
}

// #108: an invite whose server no longer pins the link's key (an address change clears the
// pin) is dropped, so its code never goes to another server; Pending and Declined clear it.
@(test)
testInviteLinkDroppedWhenNoLongerApplies :: proc(t: ^testing.T) {
	key, _ := common.identityPublicKeyFromHex(INVITE_LINK_TEST_KEY)
	fingerprint := common.fingerprintToHex(common.fingerprintIdentityPublicKey(key))
	defer delete(fingerprint)
	state := testUpdateStateForServer(
		Server {
			id = 1303,
			name = "Pinned",
			short_name = "P",
			host = "chat.example",
			port = 4000,
			pinned_server_public_key = INVITE_LINK_TEST_KEY,
			pinned_server_fingerprint = fingerprint,
		},
	)
	defer State_deinit(&state)
	link :=
		"haychat://chat.example:4000/invite/0123456789ABCDEFGHJKMNPQRSTVWXYZ?key=" +
		INVITE_LINK_TEST_KEY

	State_openLink(&state, link)
	testExpectString(t, State_confirmPendingLink(&state), "", "following the link")
	server, _ := State_serverConfig(&state, 1303)
	Server_setAddress(server, "other.example", 4000)
	State_reconfigureNetwork(&state)
	transport := &state.serverTransports[State_selectedTransportIndexForServerID(state, 1303)]
	testing.expect(
		t,
		!State_hasLinkInvite(&state, 1303) && !transport.registering,
		"expected an address change (its pin cleared) to drop the invite",
	)

	// Back at the pinned address: Pending uses the code.
	Server_setAddress(server, "chat.example", 4000)
	Server_setPins(server, INVITE_LINK_TEST_KEY, fingerprint)
	State_reconfigureNetwork(&state)
	State_openLink(&state, link)
	testExpectString(t, State_confirmPendingLink(&state), "", "following the link again")
	testApplyRegistrationRequired(&state, 1303, .InviteApproval)
	testApplyRegisterResult(&state, 1303, .Pending, "")
	transport = &state.serverTransports[State_selectedTransportIndexForServerID(state, 1303)]
	testing.expect(
		t,
		!State_hasLinkInvite(&state, 1303) && !transport.registering,
		"expected Pending to clear the invite",
	)

	// Removing the server drops it too.
	State_openLink(&state, link)
	testExpectString(t, State_confirmPendingLink(&state), "", "following the link a third time")
	testing.expect(t, State_hasLinkInvite(&state, 1303), "expected the invite kept")
	State_settingsRemoveServer(&state, 1303)
	testing.expect(
		t,
		state.signUpForm.linkInvite.serverID == 0 && len(state.signUpForm.linkInvite.code) == 0,
		"expected removing the server to drop the invite",
	)
}

// The "other window" the instance file tests treat as a live HayChat process.
INVITE_LINK_TEST_LIVE_PID :: 424242

@(private = "file")
testLinkInstanceLive :: proc(pid: int) -> bool {
	return pid == INVITE_LINK_TEST_LIVE_PID
}

// #109: one window owns the instance file. A second start keeps the first PID, an exit by
// the window that does not own it keeps the file, the owner's exit removes it, and a file
// naming a process that is gone is replaced.
@(test)
testLinkInstanceFileHasOneOwner :: proc(t: ^testing.T) {
	tempRoot, tempErr := os.temp_directory(context.temp_allocator)
	assert(tempErr == nil, "expected a temp directory")
	dir := fmt.tprintf("%s/haychat-instance-test-%d", tempRoot, os.get_pid())
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/%s", dir, LINK_INSTANCE_FILE)
	first := INVITE_LINK_TEST_LIVE_PID
	second := INVITE_LINK_TEST_LIVE_PID + 1

	testing.expect(
		t,
		claimLinkInstanceFile(dir, first, testLinkInstanceLive),
		"expected the first window to own the instance file",
	)
	pid, ok := readLinkInstancePID(dir)
	testing.expect(t, ok && pid == first, fmt.tprintf("expected PID %d, got %d", first, pid))
	when ODIN_OS != .Windows {
		info, statErr := os.lstat(path, context.temp_allocator)
		testing.expect(
			t,
			statErr == nil && transmute(u32)info.mode & 0o777 == 0o600,
			"expected the instance file to have mode 0600",
		)
	}

	testing.expect(
		t,
		!claimLinkInstanceFile(dir, second, testLinkInstanceLive),
		"expected a second start not to take the file while the first runs",
	)
	pid, ok = readLinkInstancePID(dir)
	testing.expect(t, ok && pid == first, fmt.tprintf("expected PID %d kept, got %d", first, pid))

	releaseLinkInstanceFile(dir, second)
	pid, ok = readLinkInstancePID(dir)
	testing.expect(
		t,
		ok && pid == first,
		"expected the exit of a window that does not own the file to keep it",
	)

	releaseLinkInstanceFile(dir, first)
	testing.expect(t, !os.exists(path), "expected the owner's exit to remove the file")

	// A crashed owner's file (a PID that is not a running HayChat) is replaced.
	assert(os.write_entire_file(path, "31337\n") == nil, "expected a stale instance file")
	testing.expect(
		t,
		claimLinkInstanceFile(dir, second, testLinkInstanceLive),
		"expected a stale owner replaced",
	)
	pid, ok = readLinkInstancePID(dir)
	testing.expect(t, ok && pid == second, fmt.tprintf("expected PID %d, got %d", second, pid))

	// The real check never counts this process as another window.
	testing.expect(t, !linkProcessIsHayChat(os.get_pid()), "expected this process excluded")
	testing.expect(t, !linkProcessIsHayChat(0), "expected PID 0 refused")
}
