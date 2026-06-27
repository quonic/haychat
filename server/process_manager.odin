package server

import "core:fmt"
import "core:math/rand"
import "core:sync"
import "core:thread"
import "core:time"

ProcessType :: enum {
	Network,
	WebAdmin,
	Database,
}

ProcessInfo :: struct {
	type:            ProcessType,
	threadHandle:    rawptr,
	threadID:        int,
	restartCount:    int,
	lastRestartTime: time.Time,
	restartAt:       time.Time,
	isRunning:       bool,
	stopRequested:   bool,
	restartPending:  bool,
}

ProcessManager :: struct {
	networkProcess:  ProcessInfo,
	webAdminProcess: ProcessInfo,
	databaseProcess: ProcessInfo,
	config:          ^ServerConfig,
	shouldShutdown:  bool,
	startTime:       time.Time,
	nextThreadID:    int,
	processMutex:    sync.Mutex,
}

ServiceThreadStartData :: struct {
	pm:       ^ProcessManager,
	procType: ProcessType,
}

initProcessManager :: proc(config: ^ServerConfig) -> ProcessManager {
	pm := ProcessManager {
		config         = config,
		shouldShutdown = false,
		startTime      = time.now(),
		nextThreadID   = 1,
	}

	pm.networkProcess.type = .Network
	pm.webAdminProcess.type = .WebAdmin
	pm.databaseProcess.type = .Database

	IPC_Server_init(&pm.config.networkSocket, pm.config.networkSocketName)
	IPC_Server_init(&pm.config.webAdminSocket, pm.config.webAdminSocketName)
	IPC_Server_init(&pm.config.databaseSocket, pm.config.databaseSocketName)
	pm.config.mainFd = IPC_Main_init()

	return pm
}

ProcessManager_getProcessInfo :: proc(pm: ^ProcessManager, procType: ProcessType) -> ^ProcessInfo {
	switch procType {
	case .Network:
		return &pm.networkProcess
	case .WebAdmin:
		return &pm.webAdminProcess
	case .Database:
		return &pm.databaseProcess
	case:
		return nil
	}
}

ProcessManager__serviceThreadEntry :: proc(startDataRaw: rawptr) {
	startData := cast(^ServiceThreadStartData)startDataRaw
	pm := startData.pm
	procType := startData.procType
	free(startData)

	sync.mutex_lock(&pm.processMutex)
	procInfo := ProcessManager_getProcessInfo(pm, procType)
	if procInfo != nil {
		procInfo.isRunning = true
	}
	sync.mutex_unlock(&pm.processMutex)

	switch procType {
	case .Network:
		networkServerLoop(pm)
	case .WebAdmin:
		webAdminServerLoop(pm)
	case .Database:
		databaseServerLoop(pm)
	}

	sync.mutex_lock(&pm.processMutex)
	procInfo = ProcessManager_getProcessInfo(pm, procType)
	if procInfo != nil {
		procInfo.isRunning = false
	}
	sync.mutex_unlock(&pm.processMutex)
}

ProcessManager_restartBackoff :: proc(pm: ^ProcessManager, restartCount: int) -> time.Duration {
	backoff := pm.config.restartBackoffMin
	for i in 1 ..< restartCount {
		_ = i
		if backoff >= pm.config.restartBackoffMax {
			break
		}
		backoff *= 2
	}

	if backoff > pm.config.restartBackoffMax {
		backoff = pm.config.restartBackoffMax
	}
	jitter := time.Duration(rand.float64() * f64(pm.config.restartBackoffMin))
	return backoff + jitter
}

ProcessManager_signalProcess :: proc(pm: ^ProcessManager, procType: ProcessType, msg: Message) {
	switch procType {
	case .Network:
		IPC_Server_send(&pm.config.networkSocket, pm.config.networkFd, msg)
	case .WebAdmin:
		IPC_Server_send(&pm.config.webAdminSocket, pm.config.webAdminFd, msg)
	case .Database:
		IPC_Server_send(&pm.config.databaseSocket, pm.config.databaseFd, msg)
	case:
	}
}

ProcessManager_shouldScheduleRestart :: proc(pm: ^ProcessManager, procType: ProcessType) -> bool {
	sync.mutex_lock(&pm.processMutex)
	defer sync.mutex_unlock(&pm.processMutex)

	if pm.shouldShutdown {
		return false
	}

	procInfo := ProcessManager_getProcessInfo(pm, procType)
	if procInfo == nil {
		return false
	}

	return !procInfo.isRunning && !procInfo.restartPending && !procInfo.stopRequested
}

spawnProcess :: proc(pm: ^ProcessManager, procType: ProcessType) -> bool {
	sync.mutex_lock(&pm.processMutex)
	procInfo := ProcessManager_getProcessInfo(pm, procType)
	if procInfo == nil {
		sync.mutex_unlock(&pm.processMutex)
		return false
	}
	if procInfo.isRunning {
		sync.mutex_unlock(&pm.processMutex)
		return true
	}

	threadID := pm.nextThreadID
	pm.nextThreadID += 1
	sync.mutex_unlock(&pm.processMutex)

	startData := new(ServiceThreadStartData)
	startData.pm = pm
	startData.procType = procType

	threadHandle := thread.create_and_start_with_data(
		startData,
		ProcessManager__serviceThreadEntry,
		nil,
		thread.Thread_Priority.Normal,
		true,
	)
	if threadHandle == nil {
		fmt.printfln("[Supervisor] Failed to start %v thread\n", procType)
		free(startData)
		return false
	}

	sync.mutex_lock(&pm.processMutex)
	procInfo = ProcessManager_getProcessInfo(pm, procType)
	procInfo.threadHandle = threadHandle
	procInfo.threadID = threadID
	procInfo.isRunning = true
	procInfo.stopRequested = false
	procInfo.restartPending = false
	sync.mutex_unlock(&pm.processMutex)

	fmt.printfln("[Supervisor] Started %v thread (ID: %d)\n", procType, threadID)
	return true
}

restartProcess :: proc(pm: ^ProcessManager, procType: ProcessType) -> bool {
	now := time.now()
	backoff := time.Duration(0)
	restartCount := 0
	shouldSignal := false

	sync.mutex_lock(&pm.processMutex)
	procInfo := ProcessManager_getProcessInfo(pm, procType)
	if procInfo == nil || pm.shouldShutdown {
		sync.mutex_unlock(&pm.processMutex)
		return false
	}
	if procInfo.restartPending {
		sync.mutex_unlock(&pm.processMutex)
		return true
	}

	restartCount = procInfo.restartCount + 1
	procInfo.lastRestartTime = now
	if restartCount > pm.config.maxRestarts {
		procInfo.restartCount = restartCount
		procInfo.stopRequested = true
		sync.mutex_unlock(&pm.processMutex)
		fmt.printfln("[Supervisor] %v exceeded max restart attempts, not restarting\n", procType)
		return false
	}

	backoff = ProcessManager_restartBackoff(pm, restartCount)
	procInfo.restartCount = restartCount
	procInfo.restartPending = true
	procInfo.stopRequested = true
	procInfo.restartAt = time.time_add(now, backoff)
	shouldSignal = procInfo.isRunning
	if !procInfo.isRunning {
		procInfo.threadHandle = nil
	}
	sync.mutex_unlock(&pm.processMutex)

	fmt.printfln(
		"[Supervisor] Scheduled restart for %v in %v (attempt %d)\n",
		procType,
		backoff,
		restartCount,
	)
	if shouldSignal {
		ProcessManager_signalProcess(pm, procType, ProcessRestart{})
	}
	return true
}

ProcessManager_restartDue :: proc(pm: ^ProcessManager, procType: ProcessType, now: time.Time) {
	shouldSpawn := false

	sync.mutex_lock(&pm.processMutex)
	procInfo := ProcessManager_getProcessInfo(pm, procType)
	if procInfo != nil &&
	   !pm.shouldShutdown &&
	   procInfo.restartPending &&
	   !procInfo.isRunning &&
	   time.time_to_unix_nano(now) >= time.time_to_unix_nano(procInfo.restartAt) {
		procInfo.restartPending = false
		procInfo.stopRequested = false
		shouldSpawn = true
	}
	sync.mutex_unlock(&pm.processMutex)

	if !shouldSpawn {
		return
	}

	if spawnProcess(pm, procType) {
		return
	}

	sync.mutex_lock(&pm.processMutex)
	procInfo = ProcessManager_getProcessInfo(pm, procType)
	if procInfo != nil && !pm.shouldShutdown {
		procInfo.restartPending = true
		procInfo.restartAt = time.time_add(time.now(), pm.config.restartBackoffMin)
	}
	sync.mutex_unlock(&pm.processMutex)
}

ProcessManager_pumpRestarts :: proc(pm: ^ProcessManager) {
	now := time.now()
	ProcessManager_restartDue(pm, .Network, now)
	ProcessManager_restartDue(pm, .WebAdmin, now)
	ProcessManager_restartDue(pm, .Database, now)
}

shutdownAllProcesses :: proc(pm: ^ProcessManager) {
	sync.mutex_lock(&pm.processMutex)
	pm.shouldShutdown = true
	pm.networkProcess.stopRequested = true
	pm.webAdminProcess.stopRequested = true
	pm.databaseProcess.stopRequested = true
	pm.networkProcess.restartPending = false
	pm.webAdminProcess.restartPending = false
	pm.databaseProcess.restartPending = false
	sync.mutex_unlock(&pm.processMutex)

	fmt.println("[Shutdown] Signaling service threads to stop...")
	ProcessManager_signalProcess(pm, .Network, ProcessShutdown{})
	ProcessManager_signalProcess(pm, .WebAdmin, ProcessShutdown{})
	ProcessManager_signalProcess(pm, .Database, ProcessShutdown{})
	shutdownWebAdminHTTPServer()

	shutdownStart := time.now()
	for time.since(shutdownStart) < 10 * time.Second {
		sync.mutex_lock(&pm.processMutex)
		allStopped :=
			!pm.networkProcess.isRunning &&
			!pm.webAdminProcess.isRunning &&
			!pm.databaseProcess.isRunning
		if allStopped {
			pm.networkProcess.threadHandle = nil
			pm.webAdminProcess.threadHandle = nil
			pm.databaseProcess.threadHandle = nil
			sync.mutex_unlock(&pm.processMutex)
			fmt.println("[Shutdown] All service threads exited")
			return
		}
		sync.mutex_unlock(&pm.processMutex)
		thread.yield()
	}

	fmt.println("[Shutdown] Timed out waiting for all service threads to stop")
}
