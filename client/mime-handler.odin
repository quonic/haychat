package client

import "core:fmt"
import "core:os"
import "core:strings"


xScheme :: "x-scheme-handler/haychat"

// Function to register the custom URL scheme handler for "haychat" on Linux using xdg-utils. This allows the application to be launched when a URL with the "haychat" scheme is clicked.
registerSchemeHandler :: proc() {
	when ODIN_OS == .Linux {
		registerSchemeHandlerLinux()
	} else when ODIN_OS == .Windows {
		registerSchemeHandlerWindows()
	} else {
		fmt.println("Unsupported operating system for URL scheme handler registration.")
	}
}

registerSchemeHandlerWindows :: proc() {
	// Check if the reg command is available
	if !os.exists("C:\\Windows\\System32\\reg.exe") {
		fmt.println(
			"reg command not found. Please ensure you have the necessary permissions to modify the registry.",
		)
		return
	}

	// Register the custom URL scheme handler for "haychat"
	currentExecutablePath, err_exe := os.get_executable_path(context.allocator)
	if err_exe != nil {
		fmt.println("Failed to get executable path:", err_exe)
		return
	}
	cmd, concat_err := strings.concatenate(
		{
			"reg",
			"add",
			"HKEY_CLASSES_ROOT\\haychat\\shell\\open\\command",
			"/ve",
			"/d",
			fmt.aprint('"', currentExecutablePath, '"', " \"%1\""),
			"/f",
		},
	)
	if concat_err != nil {
		fmt.println("Failed to concatenate command:", concat_err)
		return
	}
	if _, _, _, err := os.process_exec(os.Process_Desc{command = {cmd}}, context.allocator);
	   err != nil {
		fmt.println("Failed to register URL scheme handler:", err)
	} else {
		fmt.println("Successfully registered URL scheme handler for haychat.")
	}
}

registerSchemeHandlerLinux :: proc() {
	// Check if the xdg-mime command is available
	if !os.exists("/usr/bin/xdg-mime") {
		fmt.println("xdg-mime command not found. Please ensure xdg-utils is installed.")
		return
	}

	// Get the current executable path to use as the handler for the haychat scheme
	currentExecutablePath, err_exe := os.get_executable_path(context.allocator)
	if err_exe != nil {
		fmt.println("Failed to get executable path:", err_exe)
		return
	}

	// Check if the current executable is already registered as the handler for the haychat scheme
	{
		checkCmd, concat_err := strings.concatenate(
			{"/bin/sh", "-c", "xdg-mime query default", xScheme},
		)
		if concat_err != nil {
			fmt.println("Failed to concatenate command:", concat_err)
			return
		}
		if state, stdout, stderr, err := os.process_exec(
			os.Process_Desc{command = {checkCmd}},
			context.allocator,
		); err != nil {
			fmt.println("Failed to check existing URL scheme handler:", err)
		} else {
			existingHandler := strings.trim(string(stdout), "\n")
			if existingHandler == currentExecutablePath {
				fmt.println(
					"Current executable is already registered as the handler for haychat scheme.",
				)
				return
			}
		}
	}

	// Register the custom URL scheme handler for "haychat"
	{
		cmd, concat_err := strings.concatenate(
			{"/bin/sh", "-c", "xdg-mime", "default", currentExecutablePath, xScheme},
		)
		if concat_err != nil {
			fmt.println("Failed to concatenate command:", concat_err)
			return
		}
		if _, _, _, err := os.process_exec(os.Process_Desc{command = {cmd}}, context.allocator);
		   err != nil {
			fmt.println("Failed to register URL scheme handler:", err)
		} else {
			fmt.println("Successfully registered URL scheme handler for haychat.")
		}
	}
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
