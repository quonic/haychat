#+build !windows
package wasapi_probe

import "core:fmt"

// run on other systems: WASAPI is Windows only.
run :: proc(options: Options) -> int {
	fmt.eprintln("wasapi-probe: WASAPI is Windows only; build with -target:windows_amd64")
	return EXIT_USAGE
}
