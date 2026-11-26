package client

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// #110: the haychat:// handler registration's argument lists and desktop file, built without
// running anything. Nothing here touches the real $XDG_DATA_HOME or the registry.

@(private = "file")
testExpectArgv :: proc(t: ^testing.T, got: SchemeCommand, want: []string, what: string) {
	same := len(got.argv) == len(want)
	for index in 0 ..< min(len(got.argv), len(want)) {
		same = same && got.argv[index] == want[index]
	}
	testing.expect(t, same, fmt.tprintf("expected %s %v, got %v", what, want, got.argv))
}

@(test)
testSchemeRegistrationPlanLinux :: proc(t: ^testing.T) {
	plan, ok := schemeRegistrationPlanLinux("/opt/hay chat/haychat-client", "/home/u/.data")
	defer SchemeRegistrationPlan_deinit(&plan)
	testing.expect(t, ok, "expected a Linux plan")
	testExpectString(
		t,
		plan.desktopFilePath,
		"/home/u/.data/applications/haychat.desktop",
		"the desktop file's path",
	)
	testing.expect(
		t,
		strings.contains(plan.desktopFile, "\nMimeType=x-scheme-handler/haychat;\n") &&
		strings.contains(plan.desktopFile, "\nExec=\"/opt/hay chat/haychat-client\" %u\n") &&
		strings.has_prefix(plan.desktopFile, "[Desktop Entry]\nType=Application\n"),
		fmt.tprintf("expected the desktop entry, got %q", plan.desktopFile),
	)
	testing.expect(t, len(plan.commands) == 2, "expected two commands")
	if len(plan.commands) == 2 {
		testExpectArgv(
			t,
			plan.commands[0],
			{"xdg-mime", "default", "haychat.desktop", "x-scheme-handler/haychat"},
			"xdg-mime",
		)
		testing.expect(t, !plan.commands[0].optional, "expected xdg-mime required")
		testExpectArgv(
			t,
			plan.commands[1],
			{"update-desktop-database", "/home/u/.data/applications"},
			"update-desktop-database",
		)
		testing.expect(t, plan.commands[1].optional, "expected update-desktop-database optional")
	}

	// Exec quoting: '$', '`', '\' and '%' escaped, a line break refused.
	testExpectString(
		t,
		desktopExecQuote("/a$b`c\\d%e", context.temp_allocator),
		"\"/a\\\\$b\\\\`c\\\\\\\\d%%e\"",
		"the quoted Exec argument",
	)
	refused, refusedOK := schemeRegistrationPlanLinux("/a\nExec=/bin/evil", "/home/u/.data")
	defer SchemeRegistrationPlan_deinit(&refused)
	testing.expect(
		t,
		!refusedOK && len(refused.commands) == 0,
		"expected a path with a line break refused",
	)
	noHome, noHomeOK := schemeRegistrationPlanLinux("/a", "")
	defer SchemeRegistrationPlan_deinit(&noHome)
	testing.expect(t, !noHomeOK, "expected no plan without a data directory")
}

@(test)
testSchemeRegistrationPlanWindows :: proc(t: ^testing.T) {
	exe := "C:\\Users\\Hay User\\HayChat\\haychat-client.exe"
	plan, ok := schemeRegistrationPlanWindows(exe, "C:\\Windows\\")
	defer SchemeRegistrationPlan_deinit(&plan)
	testing.expect(t, ok, "expected a Windows plan")
	testing.expect(t, len(plan.desktopFilePath) == 0, "expected no desktop file on Windows")
	testing.expect(t, len(plan.commands) == 3, "expected three reg commands")
	if len(plan.commands) == 3 {
		reg := "C:\\Windows\\System32\\reg.exe"
		key := "HKCU\\Software\\Classes\\haychat"
		testExpectArgv(
			t,
			plan.commands[0],
			{reg, "add", key, "/ve", "/d", "URL:HayChat Protocol", "/f"},
			"the description",
		)
		testExpectArgv(
			t,
			plan.commands[1],
			{reg, "add", key, "/v", "URL Protocol", "/f"},
			"the URL Protocol value",
		)
		testExpectArgv(
			t,
			plan.commands[2],
			{
				reg,
				"add",
				"HKCU\\Software\\Classes\\haychat\\shell\\open\\command",
				"/ve",
				"/d",
				"\"C:\\Users\\Hay User\\HayChat\\haychat-client.exe\" \"%1\"",
				"/f",
			},
			"the open command",
		)
		for command in plan.commands {
			testing.expect(t, !command.optional, "expected every reg command required")
		}
	}
	refused, refusedOK := schemeRegistrationPlanWindows("C:\\a\"b.exe", "C:\\Windows")
	defer SchemeRegistrationPlan_deinit(&refused)
	testing.expect(t, !refusedOK, "expected a path with a quote refused")
}

// The desktop file is written into a temporary data directory (never the real one).
@(test)
testSchemeDesktopFileWrittenToDataHome :: proc(t: ^testing.T) {
	tempRoot, tempErr := os.temp_directory(context.temp_allocator)
	assert(tempErr == nil, "expected a temp directory")
	dataHome := fmt.tprintf("%s/haychat-scheme-test-%d", tempRoot, os.get_pid())
	_ = os.remove_all(dataHome)
	defer os.remove_all(dataHome)
	plan, ok := schemeRegistrationPlanLinux("/usr/bin/haychat-client", dataHome)
	defer SchemeRegistrationPlan_deinit(&plan)
	assert(ok, "expected a Linux plan")
	testing.expect(t, writeSchemeDesktopFile(plan), "expected the desktop file written")
	data, readErr := os.read_entire_file_from_path(plan.desktopFilePath, context.temp_allocator)
	testing.expect(
		t,
		readErr == nil && string(data) == plan.desktopFile,
		"expected the desktop file's contents",
	)
	// Writing it again replaces it.
	testing.expect(t, writeSchemeDesktopFile(plan), "expected the desktop file rewritten")
	testing.expect(
		t,
		schemeRegistrationRequested({"--register-url-handler"}) &&
		!schemeRegistrationRequested({"haychat://h:1/join"}),
		"expected the flag recognised",
	)
}

// #169: the startup registration's "already registered" decision, from what the queries would
// find. Nothing here runs xdg-mime or reads the registry.
@(test)
testSchemeRegistrationCurrentLinux :: proc(t: ^testing.T) {
	plan, ok := schemeRegistrationPlanLinux("/opt/haychat/haychat-client", "/home/u/.data")
	defer SchemeRegistrationPlan_deinit(&plan)
	assert(ok, "expected a Linux plan")
	testing.expect(
		t,
		schemeRegistrationCurrentLinux(plan, plan.desktopFile, "haychat.desktop\n"),
		"expected the same desktop file and xdg-mime default to count as registered",
	)
	moved, movedOK := schemeRegistrationPlanLinux("/home/u/haychat/haychat-client", "/home/u/.data")
	defer SchemeRegistrationPlan_deinit(&moved)
	assert(movedOK, "expected a plan for the moved executable")
	testing.expect(
		t,
		!schemeRegistrationCurrentLinux(moved, plan.desktopFile, "haychat.desktop\n"),
		"expected a desktop file naming another executable to register again",
	)
	testing.expect(
		t,
		!schemeRegistrationCurrentLinux(plan, plan.desktopFile, "other-app.desktop\n"),
		"expected another default handler to register again",
	)
	testing.expect(
		t,
		!schemeRegistrationCurrentLinux(plan, plan.desktopFile, ""),
		"expected no default handler to register again",
	)
	testing.expect(
		t,
		!schemeRegistrationCurrentLinux(plan, "", "haychat.desktop\n"),
		"expected a missing desktop file to register again",
	)
	testing.expect(
		t,
		!schemeRegistrationCurrentLinux({}, "", "haychat.desktop"),
		"expected an empty plan never to count as registered",
	)
}

@(test)
testSchemeRegistrationCurrentWindows :: proc(t: ^testing.T) {
	exe := "C:\\Users\\Hay User\\HayChat\\haychat-client.exe"
	command := "\"C:\\Users\\Hay User\\HayChat\\haychat-client.exe\" \"%1\""
	testing.expect(
		t,
		schemeRegistrationCurrentWindows(exe, command, true),
		"expected this executable's open command to count as registered",
	)
	testing.expect(
		t,
		!schemeRegistrationCurrentWindows(exe, command, false),
		"expected a missing URL Protocol value to register again",
	)
	testing.expect(
		t,
		!schemeRegistrationCurrentWindows(
			"D:\\HayChat\\haychat-client.exe",
			command,
			true,
		),
		"expected an open command naming another executable to register again",
	)
	testing.expect(
		t,
		!schemeRegistrationCurrentWindows(exe, "", true),
		"expected an empty open command to register again",
	)
	// The plan's open command is the one the check compares with.
	plan, ok := schemeRegistrationPlanWindows(exe, "C:\\Windows")
	defer SchemeRegistrationPlan_deinit(&plan)
	assert(ok && len(plan.commands) == 3, "expected a Windows plan")
	testExpectString(t, plan.commands[2].argv[5], command, "the plan's open command")
}
