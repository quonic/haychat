package client

import "../common"
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
