package server

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:sys/linux"
import "core:time"

// ProcessType identifies which process type this is
ProcessType :: enum {
	Network,
	WebAdmin,
	Database,
}

// ProcessInfo tracks a child process
ProcessInfo :: struct {
	type:            ProcessType,
	pid:             linux.Pid,
	restartCount:    int,
	lastRestartTime: time.Time,
	isRunning:       bool,
}

// ProcessManager manages all child processes
ProcessManager :: struct {
	networkProcess:  ProcessInfo,
	webAdminProcess: ProcessInfo,
	databaseProcess: ProcessInfo,
	config:          ^ServerConfig,
	shouldShutdown:  bool,
}

// Initialize the process manager
initProcessManager :: proc(config: ^ServerConfig) -> ProcessManager {
	return ProcessManager{config = config, shouldShutdown = false}
}

// Spawn a child process
spawnProcess :: proc(
	pm: ^ProcessManager,
	procType: ProcessType,
) -> (
	pid: linux.Pid,
	is_parent: bool,
	is_child: bool,
) {
	environ, environ_err := os.environ(context.allocator)
	if environ_err != nil {
		fmt.println("[ProcessManager] Failed to get environment variables:", environ_err)
		return -1, false, false
	}

	workingDir, workingDir_err := os.get_working_directory(context.allocator)
	if workingDir_err != nil {
		fmt.println("[ProcessManager] Failed to get working directory:", workingDir_err)
		return -1, false, false
	}

	switch procType {
	case .Network:
		ipc_error := IPC_Server_init(&pm.config.networkSocket, pm.config.networkSocketName)
		if ipc_error != nil {
			fmt.println("[ProcessManager] Failed to initialize IPC server:", ipc_error)
			return -1, false, false
		}
		fmt.println("[ProcessManager] Spawning Network process...")
		pid, err := linux.fork()
		if err != .NONE {
			fmt.println("[ProcessManager] Failed to spawn Network process:", err)
			return -1, false, false
		}
		if pid == 0 {
			// In child process - execute the server binary with an argument to indicate which process type to run
			return 0, false, true
		} else if pid > 0 {
			// In parent process - return the child process info
			return pid, true, false
		} else {
			fmt.println("[ProcessManager] Unexpected fork result:", pid)
			return -1, false, false
		}
	case .WebAdmin:
		ipc_error := IPC_Server_init(&pm.config.webAdminSocket, pm.config.webAdminSocketName)
		if ipc_error != nil {
			fmt.println("[ProcessManager] Failed to initialize IPC server:", ipc_error)
			return -1, false, false
		}
		fmt.println("[ProcessManager] Spawning Web Admin process...")
		pid, err := linux.fork()
		if err != .NONE {
			fmt.println("[ProcessManager] Failed to spawn Web Admin process:", err)
			return -1, false, false
		}
		if pid == 0 {
			// In child process - execute the server binary with an argument to indicate which process type to run
			return 0, false, true
		} else if pid > 0 {
			// In parent process - return the child process info
			return pid, true, false
		} else {
			fmt.println("[ProcessManager] Unexpected fork result:", pid)
			return -1, false, false
		}
	case .Database:
		ipc_error := IPC_Server_init(&pm.config.databaseSocket, pm.config.databaseSocketName)
		if ipc_error != nil {
			fmt.println("[ProcessManager] Failed to initialize IPC server:", ipc_error)
			return -1, false, false
		}
		fmt.println("[ProcessManager] Spawning Database process...")
		pid, err := linux.fork()
		if err != .NONE {
			fmt.println("[ProcessManager] Failed to spawn Database process:", err)
			return -1, false, false
		}
		if pid == 0 {
			// In child process - execute the server binary with an argument to indicate which process type to run
			return 0, false, true
		} else if pid > 0 {
			// In parent process - return the child process info
			return pid, true, false
		} else {
			fmt.println("[ProcessManager] Unexpected fork result:", pid)
			return -1, false, false
		}
		return pid, false, false
	case:
		fmt.println("[ProcessManager] Unknown process type:", procType)
	}

	return -1, false, false
}

// Restart a child process with exponential backoff
restartProcess :: proc(pm: ^ProcessManager, procType: ProcessType) {
	IPC_Server_send(&pm.config.networkSocket, pm.config.networkFd, ProcessRestart{})
	// Update the process info with the restart attempt
	procInfo: ^ProcessInfo
	switch procType {
	case .Network:
		procInfo = &pm.networkProcess
	case .WebAdmin:
		procInfo = &pm.webAdminProcess
	case .Database:
		procInfo = &pm.databaseProcess
	}
	procInfo.restartCount += 1
	procInfo.lastRestartTime = time.now()
	// Check if we've exceeded the maximum restart attempts
	if procInfo.restartCount > pm.config.maxRestarts {
		fmt.printf(
			"[ProcessManager] Process %v has exceeded maximum restart attempts, not restarting\n",
			procType,
		)
		procInfo.isRunning = false
		return
	}
	// Calculate the backoff time with exponential backoff and jitter
	backoffTime :=
		time.Duration(
			time.Duration(procInfo.restartCount) * pm.config.restartBackoffMin * time.Second,
		) *
		time.Second
	if backoffTime > pm.config.restartBackoffMax {
		backoffTime = pm.config.restartBackoffMax
	}
	jitter := time.Duration(rand.float64() * f64(pm.config.restartBackoffMin * time.Second))
	backoffTime += jitter
	fmt.printf(
		"[ProcessManager] Restarting process %v in %v seconds (attempt %d)\n",
		procType,
		backoffTime,
		procInfo.restartCount,
	)
	time.sleep(backoffTime)
	// Spawn the process again
	pid, is_parent, is_child := spawnProcess(pm, procType)
	if pid == -1 {
		fmt.printf("[ProcessManager] Failed to restart process %v\n", procType)
		return
	} else if is_child {
		// In child process - run the appropriate server loop
		switch procType {
		case .Network:
			networkServerLoop(pm)
		case .WebAdmin:
			webAdminServerLoop(pm)
		case .Database:
			databaseServerLoop(pm)
		}
		os.exit(0) // Ensure child process doesn't continue executing the main loop
	} else {
		// In parent process - update the process info
		procInfo.pid = pid
		procInfo.isRunning = true
		fmt.printf(
			"[ProcessManager] Successfully restarted process %v with PID: %d\n",
			procType,
			pid,
		)
	}
}

// Handle a child process exit
handleChildExit :: proc(pid: linux.Pid, name: string) -> (exit_status: int) {
	status_update_delay := 100 * time.Millisecond
	still_waiting_delay := 1 * time.Second
	timeout := 30 * time.Second
	status: u32

	result, err := linux.waitpid(pid, &status, {.WNOHANG}, nil)
	current_time := time.now()
	for result == 0 {
		// Child is still running
		time.sleep(status_update_delay)
		result, err = linux.waitpid(pid, &status, {.WNOHANG}, nil)
		if time.since(current_time) > still_waiting_delay {
			fmt.printf(
				"[ProcessManager] Still waiting for process %s (%d) to exit...\n",
				name,
				pid,
			)
			current_time = time.now()
		} else if time.since(current_time) > timeout {
			fmt.printf(
				"[ProcessManager] Process %s (%d) is taking too long to exit, sending SIGKILL...\n",
				name,
				pid,
			)
			linux.kill(pid, .SIGKILL)
			current_time = time.now()
			return -1
		}
	}
	if linux.WIFEXITED(status) {exit_status = 1} else {exit_status = 0}
	if result == pid {
		fmt.printf(
			"[ProcessManager] Process %s (%d) exited with status %d\n",
			name,
			result,
			exit_status,
		)
		return exit_status
	} else if result == -1 {
		if err == linux.Errno.ECHILD {
			fmt.printf("[ProcessManager] No child process %s (%d) to wait for\n", name, pid)
			return -1
		}
		fmt.println("[ProcessManager] waitpid error:", err)
		return -1
	} else {
		fmt.printf(
			"[ProcessManager] Unexpected waitpid result for process %s (%d): %d, error: %v\n",
			name,
			pid,
			result,
			err,
		)
		return -1
	}
}

// Gracefully shutdown all child processes
shutdownAllProcesses :: proc(pm: ^ProcessManager) {
	pm.shouldShutdown = true
	fmt.println("[Shutdown] Sending ProcessShutdown to child processes...")
	IPC_Server_send(&pm.config.networkSocket, pm.config.networkFd, ProcessShutdown{})
	IPC_Server_send(&pm.config.webAdminSocket, pm.config.webAdminFd, ProcessShutdown{})
	IPC_Server_send(&pm.config.databaseSocket, pm.config.databaseFd, ProcessShutdown{})
	fmt.println("[Shutdown] Waiting for child processes to exit...")
	handleChildExit(pm.networkProcess.pid, "Network")
	handleChildExit(pm.webAdminProcess.pid, "Web Admin")
	handleChildExit(pm.databaseProcess.pid, "Database")
	fmt.println("[Shutdown] All child processes have exited")
}
