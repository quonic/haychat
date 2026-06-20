package client

import "core:fmt"
import "core:log"
import "core:os"
import filepath "core:path/filepath"
import "core:strings"
import "core:sys/linux"
import "core:sys/windows"
import "core:text/regex"


xScheme :: "x-scheme-handler/haychat"

// Function to register the custom URL scheme handler for "haychat" on Linux using xdg-utils. This allows the application to be launched when a URL with the "haychat" scheme is clicked.
registerSchemeHandler :: proc() {
	when ODIN_OS == .Linux {
		registerSchemeHandlerLinux()
	} else when ODIN_OS == .Windows {
		registerSchemeHandlerWindows()
	} else {
		log.info("Unsupported operating system for URL scheme handler registration.")
	}
}

registerSchemeHandlerWindows :: proc() {
	// Check if the reg command is available
	if !os.exists("C:\\Windows\\System32\\reg.exe") {
		log.info(
			"reg command not found. Please ensure you have the necessary permissions to modify the registry.",
		)
		return
	}

	// Register the custom URL scheme handler for "haychat"
	currentExecutablePath, err_exe := os.get_executable_path(context.allocator)
	if err_exe != nil {
		log.info("Failed to get executable path:", err_exe)
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
		log.info("Failed to concatenate command:", concat_err)
		return
	}
	if _, _, _, err := os.process_exec(os.Process_Desc{command = {cmd}}, context.allocator);
	   err != nil {
		log.info("Failed to register URL scheme handler:", err)
	} else {
		log.info("Successfully registered URL scheme handler for haychat.")
	}
}

registerSchemeHandlerLinux :: proc() {
	// Check if the xdg-mime command is available
	if !os.exists("/usr/bin/xdg-mime") {
		log.info("xdg-mime command not found. Please ensure xdg-utils is installed.")
		return
	}

	// Get the current executable path to use as the handler for the haychat scheme
	currentExecutablePath, err_exe := os.get_executable_path(context.allocator)
	if err_exe != nil {
		log.info("Failed to get executable path:", err_exe)
		return
	}

	// Check if the current executable is already registered as the handler for the haychat scheme
	{
		checkCmd, concat_err := strings.concatenate(
			{"/bin/sh", "-c", "xdg-mime query default", xScheme},
		)
		if concat_err != nil {
			log.info("Failed to concatenate command:", concat_err)
			return
		}
		if state, stdout, stderr, err := os.process_exec(
			os.Process_Desc{command = {checkCmd}},
			context.allocator,
		); err != nil {
			log.info("Failed to check existing URL scheme handler:", err)
		} else {
			existingHandler := strings.trim(string(stdout), "\n")
			if existingHandler == currentExecutablePath {
				log.info(
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
			log.info("Failed to concatenate command:", concat_err)
			return
		}
		if _, _, _, err := os.process_exec(os.Process_Desc{command = {cmd}}, context.allocator);
		   err != nil {
			log.info("Failed to register URL scheme handler:", err)
		} else {
			log.info("Successfully registered URL scheme handler for haychat.")
		}
	}
}

// Path to the temporary file
getJoinFilePath :: proc() -> string {
	when ODIN_OS == .Windows {
		tempDir, tempDirErr := os.temp_directory(context.allocator)
		if tempDirErr != nil {
			return ""
		}
		tempJoinFilePath, joinErr := filepath.join({tempDir, "haychat_url_handler"})
		if joinErr != nil {
			return ""
		}
		return tempJoinFilePath
	} else when ODIN_OS == .Linux {
		return "/tmp/haychat_url_handler"
	} else {
		return ""
	}
}

// Function to handle incoming URLs with the "haychat" scheme. This function parses the URL, extracts relevant information, and saves it to a temporary file for the main application to read and act upon.
schemeHandler :: proc(url: string) -> (host: string, port: string) {
	// Example URL: haychat://example.com:1234/join
	if strings.starts_with(url, "haychat://") {
		// Extract the relevant part of the URL (e.g., the chat ID or action)
		action := strings.trim_prefix(url, "haychat://")
		log.info("Received haychat URL with action:", action)

		// We are looking for a patter like "example.com:1234/join"
		regex_create_result, regex_err := regex.create(
			`^([^:/]+):(\d+)/(join)?$`,
			{.Case_Insensitive, .Ignore_Whitespace},
		)
		if regex_err != nil {
			log.info("Failed to create regex:", regex_err)
			return
		}

		capture, success := regex.match_and_allocate_capture(regex_create_result, action)
		if !success {
			log.info("Failed to match regex")
			return
		}
		host = capture.groups[1]
		port = capture.groups[2]
		join := capture.groups[3] == "join"
		log.info("Parsed URL - Host:", host, "Port:", port, "Join:", join)
		// Save the host and port to a temporary file
		when ODIN_OS == .Windows {
			path := getJoinFilePath()
			writeErr := os.write_entire_file(path, fmt.tprintf("%s:%s\n", host, port))
			if writeErr != nil {
				log.info("Failed to write to temporary file:", writeErr)
				return
			}
			log.info("Saved URL data to temporary file:", path)
		} else when ODIN_OS == .Linux {
			path := getJoinFilePath()
			writeErr := os.write_entire_file(path, fmt.tprintf("%s:%s\n", host, port))
			if writeErr != nil {
				log.info("Failed to write to temporary file:", writeErr)
				return
			}
			log.info("Saved URL data to temporary file:", path)
			// Check if we are already running and if so, exit to allow the existing instance to handle the URL
			pid_list, err := os.process_list(context.allocator)
			if err != nil {
				log.info("Failed to list processes:", err)
				return
			}
			currentPid := os.get_pid()
			for pid in pid_list {
				{
					process_info, err := os.process_info_by_pid(
						pid,
						{.Command_Line},
						context.allocator,
					)
					if err != nil {
						continue
					}
					if pid != currentPid && process_info.command_line == "haychat" {
						log.info(
							"Another instance of haychat is already running. Exiting to allow it to handle the URL.",
						)
						os.exit(0)
					}
				}
			}
		} else {
			log.info("Unsupported operating system for URL scheme handling.")
		}
		return host, port
	} else {
		log.info("Received URL with unsupported scheme:", url)
		os.exit(1) // Exit with an error code for unsupported schemes
	}
}
