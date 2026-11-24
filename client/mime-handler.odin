package client

import "core:fmt"
import "core:os"
import "core:strings"

// Registering HayChat as the handler for haychat:// links (#110), for this user only, by
// `client --register-url-handler` (SCHEME_HANDLER_FLAG):
//
// - Linux: writes haychat.desktop (MimeType=x-scheme-handler/haychat;, Exec="EXE" %u) to
//   $XDG_DATA_HOME/applications (by default ~/.local/share/applications) and runs
//   `xdg-mime default haychat.desktop x-scheme-handler/haychat` (xdg-mime takes a desktop
//   file ID, not a path), then `update-desktop-database DIR` where it is installed.
// - Windows: `reg add` under HKCU\Software\Classes\haychat, which needs no admin rights: the
//   default value "URL:HayChat Protocol", an empty "URL Protocol" value, and
//   shell\open\command set to "EXE" "%1".
//
// Every command is an argument list handed to os.process_exec as it is: no shell, no joined
// command line. schemeRegistrationPlanLinux and schemeRegistrationPlanWindows only build the
// plan, so tests check the argument lists (and write the desktop file into a temporary
// directory) without touching the desktop; runSchemeRegistration carries a plan out.

SCHEME_HANDLER_FLAG :: "--register-url-handler"
SCHEME_MIME_TYPE :: "x-scheme-handler/haychat"
SCHEME_DESKTOP_FILE_ID :: "haychat.desktop"
SCHEME_WINDOWS_KEY :: "HKCU\\Software\\Classes\\haychat"
SCHEME_WINDOWS_DESCRIPTION :: "URL:HayChat Protocol"

// One command of a registration: the program and its arguments.
SchemeCommand :: struct {
	argv:     []string,
	// A failure is reported but does not fail the registration (update-desktop-database is
	// not installed everywhere, and xdg-mime default alone is enough).
	optional: bool,
}

// What a registration does. Owned (SchemeRegistrationPlan_deinit).
SchemeRegistrationPlan :: struct {
	// Linux: the desktop file written before the commands run. Empty on Windows.
	desktopFilePath: string,
	desktopFile:     string,
	commands:        [dynamic]SchemeCommand,
}

SchemeRegistrationPlan_deinit :: proc(plan: ^SchemeRegistrationPlan) {
	delete(plan.desktopFilePath)
	delete(plan.desktopFile)
	for command in plan.commands {
		for arg in command.argv {
			delete(arg)
		}
		delete(command.argv)
	}
	delete(plan.commands)
	plan^ = {}
}

@(private = "file")
SchemeRegistrationPlan_add :: proc(
	plan: ^SchemeRegistrationPlan,
	optional: bool,
	args: ..string,
) {
	argv := make([]string, len(args))
	for arg, index in args {
		argv[index] = strings.clone(arg)
	}
	append(&plan.commands, SchemeCommand{argv = argv, optional = optional})
}

// Whether a program path can go into a desktop file's Exec or a registry command: no line
// breaks or other control characters, and (Windows paths cannot hold one anyway) no '"'.
@(private = "file")
schemeExecutablePathOK :: proc(exe: string) -> bool {
	if len(exe) == 0 {
		return false
	}
	for index in 0 ..< len(exe) {
		if exe[index] < 0x20 || exe[index] == 0x7f || exe[index] == '"' {
			return false
		}
	}
	return true
}

// exe as one quoted argument of a desktop entry's Exec key (Desktop Entry Specification,
// "The Exec key"): '`', '$' and '\' are escaped with a backslash inside the quotes, '%' is
// doubled (it starts a field code), and then every backslash is doubled again by the general
// string escaping, which a reader undoes first. Allocated with allocator.
desktopExecQuote :: proc(exe: string, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	strings.write_byte(&builder, '"')
	for index in 0 ..< len(exe) {
		switch exe[index] {
		case '`', '$':
			strings.write_string(&builder, "\\\\")
			strings.write_byte(&builder, exe[index])
		case '\\':
			strings.write_string(&builder, "\\\\\\\\")
		case '%':
			strings.write_string(&builder, "%%")
		case:
			strings.write_byte(&builder, exe[index])
		}
	}
	strings.write_byte(&builder, '"')
	return strings.to_string(builder)
}

// The Linux registration for exe with dataHome as $XDG_DATA_HOME. Nothing is written or run.
// ok is false (and plan empty) for a path that cannot go into a desktop file.
schemeRegistrationPlanLinux :: proc(
	exe, dataHome: string,
) -> (
	plan: SchemeRegistrationPlan,
	ok: bool,
) {
	if !schemeExecutablePathOK(exe) || len(dataHome) == 0 {
		return {}, false
	}
	applications := strings.concatenate({dataHome, "/applications"}, context.temp_allocator)
	exec := desktopExecQuote(exe, context.temp_allocator)
	plan.desktopFilePath = strings.concatenate({applications, "/", SCHEME_DESKTOP_FILE_ID})
	plan.desktopFile = strings.concatenate(
		{
			"[Desktop Entry]\n",
			"Type=Application\n",
			"Name=HayChat\n",
			"Comment=Open haychat:// invite and join links\n",
			"Exec=",
			exec,
			" %u\n",
			"Terminal=false\n",
			"NoDisplay=true\n",
			"MimeType=",
			SCHEME_MIME_TYPE,
			";\n",
		},
	)
	SchemeRegistrationPlan_add(
		&plan,
		false,
		"xdg-mime",
		"default",
		SCHEME_DESKTOP_FILE_ID,
		SCHEME_MIME_TYPE,
	)
	SchemeRegistrationPlan_add(&plan, true, "update-desktop-database", applications)
	return plan, true
}

// The Windows registration for exe, with reg.exe from systemRoot (%SystemRoot%). Nothing is
// run. ok is false (and plan empty) for a path that cannot go into the command.
schemeRegistrationPlanWindows :: proc(
	exe, systemRoot: string,
) -> (
	plan: SchemeRegistrationPlan,
	ok: bool,
) {
	if !schemeExecutablePathOK(exe) || len(systemRoot) == 0 {
		return {}, false
	}
	reg := strings.concatenate(
		{strings.trim_right(systemRoot, "\\/"), "\\System32\\reg.exe"},
		context.temp_allocator,
	)
	commandKey := strings.concatenate(
		{SCHEME_WINDOWS_KEY, "\\shell\\open\\command"},
		context.temp_allocator,
	)
	openCommand := strings.concatenate({"\"", exe, "\" \"%1\""}, context.temp_allocator)
	SchemeRegistrationPlan_add(
		&plan,
		false,
		reg,
		"add",
		SCHEME_WINDOWS_KEY,
		"/ve",
		"/d",
		SCHEME_WINDOWS_DESCRIPTION,
		"/f",
	)
	// Without /d, reg add stores an empty string: os.process_exec cannot pass an empty
	// argument on Windows (it would vanish from the command line).
	SchemeRegistrationPlan_add(
		&plan,
		false,
		reg,
		"add",
		SCHEME_WINDOWS_KEY,
		"/v",
		"URL Protocol",
		"/f",
	)
	SchemeRegistrationPlan_add(
		&plan,
		false,
		reg,
		"add",
		commandKey,
		"/ve",
		"/d",
		openCommand,
		"/f",
	)
	return plan, true
}

// $XDG_DATA_HOME when it is an absolute path, else ~/.local/share. Allocated with allocator;
// empty without either.
schemeDataHome :: proc(allocator := context.allocator) -> string {
	dataHome := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if strings.has_prefix(dataHome, "/") {
		return strings.clone(dataHome, allocator)
	}
	home := os.get_env("HOME", context.temp_allocator)
	if len(home) == 0 {
		return ""
	}
	return strings.concatenate({home, "/.local/share"}, allocator)
}

// This system's registration for exe.
schemeRegistrationPlan :: proc(exe: string) -> (plan: SchemeRegistrationPlan, ok: bool) {
	when ODIN_OS == .Linux {
		dataHome := schemeDataHome(context.temp_allocator)
		return schemeRegistrationPlanLinux(exe, dataHome)
	} else when ODIN_OS == .Windows {
		systemRoot := os.get_env("SystemRoot", context.temp_allocator)
		if len(systemRoot) == 0 {
			systemRoot = "C:\\Windows"
		}
		return schemeRegistrationPlanWindows(exe, systemRoot)
	} else {
		return {}, false
	}
}

// Writes the plan's desktop file (Linux), creating its directory. True when there is none.
writeSchemeDesktopFile :: proc(plan: SchemeRegistrationPlan) -> bool {
	if len(plan.desktopFilePath) == 0 {
		return true
	}
	dir := plan.desktopFilePath[:strings.last_index_byte(plan.desktopFilePath, '/')]
	if err := os.make_directory_all(dir, os.perm(0o755)); err != nil && !os.is_dir(dir) {
		fmt.eprintln("[Error] Could not create", dir, err)
		return false
	}
	if err := writeFileAtomically(plan.desktopFilePath, transmute([]u8)plan.desktopFile);
	   err != nil {
		fmt.eprintln("[Error] Could not write", plan.desktopFilePath, err)
		return false
	}
	return true
}

// Carries a plan out: the desktop file, then each command in turn. A required command that
// fails stops it.
runSchemeRegistration :: proc(plan: SchemeRegistrationPlan) -> bool {
	if !writeSchemeDesktopFile(plan) {
		return false
	}
	for command in plan.commands {
		state, stdout, stderr, err := os.process_exec(
			os.Process_Desc{command = command.argv},
			context.allocator,
		)
		defer delete(stdout)
		defer delete(stderr)
		if err == nil && state.exited && state.exit_code == 0 {
			continue
		}
		label := command.optional ? "[Warning]" : "[Error]"
		if err != nil {
			fmt.eprintln(label, command.argv[0], "could not run:", err)
		} else {
			fmt.eprintln(
				label,
				command.argv[0],
				"failed with exit code",
				state.exit_code,
				strings.trim_space(string(stderr)),
			)
		}
		if !command.optional {
			return false
		}
	}
	return true
}

// Registers this executable as the haychat:// handler for this user. Returns whether it did.
registerSchemeHandler :: proc() -> bool {
	exe, exeErr := os.get_executable_path(context.allocator)
	if exeErr != nil {
		fmt.eprintln("[Error] Could not find HayChat's own executable:", exeErr)
		return false
	}
	defer delete(exe)
	plan, ok := schemeRegistrationPlan(exe)
	defer SchemeRegistrationPlan_deinit(&plan)
	if !ok {
		fmt.eprintln("[Error] HayChat cannot register a haychat:// handler for", exe)
		return false
	}
	if !runSchemeRegistration(plan) {
		fmt.eprintln("[Error] Registering the haychat:// handler failed")
		return false
	}
	fmt.println("[Info] HayChat now opens haychat:// links:", exe)
	return true
}

// Whether the command line asks for registerSchemeHandler (SCHEME_HANDLER_FLAG).
schemeRegistrationRequested :: proc(args: []string) -> bool {
	for arg in args {
		if arg == SCHEME_HANDLER_FLAG {
			return true
		}
	}
	return false
}

// Handles a haychat:// link from the command line before the window opens (main). When a
// HayChat window already runs, the link goes to it through the per-user hand-off file
// (invite_link.odin: mode 0600, created new, deleted once read; never /tmp) and this process
// should exit: handedOff is true. Otherwise this process opens the link itself after startup
// (init), which shows the confirmation. The link's invite code is never printed.
schemeHandler :: proc(url: string) -> (handedOff: bool) {
	if _, err := parseHaychatLink(url, context.temp_allocator); err != .None {
		fmt.eprintln("[Warning] Ignoring a link HayChat cannot use:", redactHaychatLink(url))
		return false
	}
	if !linkOtherInstanceRunning() {
		return false
	}
	if !writeLinkHandoff(url) {
		fmt.eprintln("[Warning] Could not pass the link to the running HayChat window")
		return false
	}
	fmt.eprintln("[Info] Passed the link to the running HayChat window:", redactHaychatLink(url))
	return true
}

// The first haychat:// argument, or "". Borrowed from args.
schemeLinkArgument :: proc(args: []string) -> string {
	for arg in args {
		if len(arg) >= len(HAYCHAT_LINK_SCHEME) &&
		   strings.equal_fold(arg[:len(HAYCHAT_LINK_SCHEME)], HAYCHAT_LINK_SCHEME) {
			return arg
		}
	}
	return ""
}
