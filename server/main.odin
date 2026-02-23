package server

import "core:fmt"
import "core:net"
import "core:os"
import "core:sys/linux"
import "core:time"

// Main server entry point
main :: proc() {
	fmt.println("=== HayChat Server - Multi-process Architecture ===")
	fmt.println()

	// Load configuration from environment
	config := loadConfig()
	fmt.println("Configuration loaded:")
	fmt.printf("  Web Admin: %s:%d\n", config.webAdminHost, config.webAdminPort)
	fmt.printf(
		"  Database: %s@%s:%d/%s\n",
		config.databaseUser,
		config.databaseURL,
		config.databasePort,
		config.databaseName,
	)
	fmt.printf(
		"  Max Restarts: %d (backoff: %f-%f sec)\n",
		config.maxRestarts,
		config.restartBackoffMin,
		config.restartBackoffMax,
	)
	fmt.println()

	// Initialize process manager
	pm := initProcessManager(&config)

	fmt.println("=== Starting Child Processes ===")

	// Spawn all three child processes
	pm.config.networkSocketName = fmt.aprintf("%s_network.sock", SERVER_SOCKET)
	pm.config.webAdminSocketName = fmt.aprintf("%s_webadmin.sock", SERVER_SOCKET)
	pm.config.databaseSocketName = fmt.aprintf("%s_database.sock", SERVER_SOCKET)

	main_pid := linux.Pid(os.get_pid())
	pid: linux.Pid
	is_parent, is_child: bool
	is_network, is_webadmin, is_database: bool

	if pid, is_parent, is_child = spawnProcess(&pm, .Network); pid == -1 {
		fmt.println("[Network] Failed to start Network process")
		return
	} else if is_child {
		// In child process - run the network server loop
		is_network = true
		os.exit(0) // Ensure child process doesn't continue executing the main loop
	} else {
		pm.networkProcess = ProcessInfo {
			type      = .Network,
			pid       = pid,
			isRunning = true,
		}
		fmt.println("[Network] Spawned Network process with PID: %d", pid)
	}

	if pid, is_parent, is_child = spawnProcess(&pm, .WebAdmin); pid == -1 {
		fmt.println("[WebAdmin] Failed to start Web Admin process")
		return
	} else if is_child {
		// In child process - run the web admin server loop
		is_webadmin = true
		os.exit(0) // Ensure child process doesn't continue executing the main loop
	} else {
		pm.webAdminProcess = ProcessInfo {
			type      = .WebAdmin,
			pid       = pid,
			isRunning = true,
		}
		fmt.println("[WebAdmin] Spawned Web Admin process with PID: %d", pid)
	}

	if pid, is_parent, is_child = spawnProcess(&pm, .Database); pid == -1 {
		fmt.println("[Database] Failed to start Database process")
		return
	} else if is_child {
		// In child process - run the database server loop
		is_database = true
		os.exit(0) // Ensure child process doesn't continue executing the main loop
	} else {
		pm.databaseProcess = ProcessInfo {
			type      = .Database,
			pid       = pid,
			isRunning = true,
		}
		fmt.printfln("[Database] Spawned Database process with PID: %d", pid)
	}

	fmt.println("\n=== Server Running ===")
	fmt.printf("Main process PID: %d\n", main_pid)
	fmt.println("Press Ctrl+C to shutdown gracefully")
	fmt.println()

	// Main event loop
	if is_parent {
		mainLoop(&pm)
	} else {
		if is_network {
			networkServerLoop(&pm)
		} else if is_webadmin {
			webAdminServerLoop(&pm)
		} else if is_database {
			databaseServerLoop(&pm)
		}
	}

	fmt.println("\n=== Server Shutdown Complete ===")
}

// Main event loop - monitors child processes and handles IPC
@(private)
mainLoop :: proc(pm: ^ProcessManager) {
	running := true

	for running {
		time.sleep(500 * time.Millisecond)
		// TODO: Implement proper event loop with select/epoll on IPC sockets
		// TODO: Monitor child processes, restart on crash
		// TODO: Route messages between components
	}
}
