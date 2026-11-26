package client

// The Linux half of schemeRegistrationStatus (mime-handler.odin, #169): the desktop file on
// disk and `xdg-mime query default x-scheme-handler/haychat`. Never called by a test.

import "core:fmt"
import "core:os"

// Whether the haychat:// handler already points at this executable (see SchemeRegistrationStatus).
schemeRegistrationStatus :: proc(
	exe: string,
	plan: SchemeRegistrationPlan,
) -> SchemeRegistrationStatus {
	state, stdout, stderr, err := os.process_exec(
		os.Process_Desc{command = {"xdg-mime", "query", "default", SCHEME_MIME_TYPE}},
		context.allocator,
	)
	defer delete(stdout)
	defer delete(stderr)
	if err != nil {
		// No xdg-utils (a container, a minimal desktop): xdg-mime default would fail too.
		fmt.eprintln(
			"[Warning] Not registering the haychat:// link handler: xdg-mime could not run:",
			err,
		)
		return .Unknown
	}
	if !state.exited || state.exit_code != 0 {
		return .Stale
	}
	onDisk, readErr := os.read_entire_file_from_path(plan.desktopFilePath, context.allocator)
	defer delete(onDisk)
	if readErr != nil {
		return .Stale
	}
	return schemeRegistrationCurrentLinux(plan, string(onDisk), string(stdout)) ? .Current : .Stale
}
