package server

import "core:fmt"
import "core:log"
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
	isRunning:       bool,
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
		procInfo.threadHandle = nil
	}
	sync.mutex_unlock(&pm.processMutex)
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
	)
	if threadHandle == nil {
		fmt.printf("[Supervisor] Failed to start %v thread\n", procType)
		free(startData)
		return false
	}

	sync.mutex_lock(&pm.processMutex)
	procInfo = ProcessManager_getProcessInfo(pm, procType)
	procInfo.threadHandle = threadHandle
	procInfo.threadID = threadID
	procInfo.isRunning = true
	sync.mutex_unlock(&pm.processMutex)

	fmt.printf("[Supervisor] Started %v thread (ID: %d)\n", procType, threadID)
	return true
}

restartProcess :: proc(pm: ^ProcessManager, procType: ProcessType) {
	procInfo := ProcessManager_getProcessInfo(pm, procType)
	if procInfo == nil {
		return
	}

	sync.mutex_lock(&pm.processMutex)
	procInfo.restartCount += 1
	procInfo.lastRestartTime = time.now()
	restartCount := procInfo.restartCount
	sync.mutex_unlock(&pm.processMutex)

	if restartCount > pm.config.maxRestarts {
		fmt.printf("[Supervisor] %v exceeded max restart attempts, not restarting\n", procType)
		return
	}

	backoff := pm.config.restartBackoffMin * time.Duration(restartCount)
	if backoff > pm.config.restartBackoffMax {
		backoff = pm.config.restartBackoffMax
	}
	jitter := time.Duration(rand.float64() * f64(pm.config.restartBackoffMin))
	backoff += jitter

	fmt.printf("[Supervisor] Restarting %v in %v (attempt %d)\n", procType, backoff, restartCount)
	time.sleep(backoff)

	if !pm.shouldShutdown {
		spawnProcess(pm, procType)
	}
}

shutdownAllProcesses :: proc(pm: ^ProcessManager) {
	sync.mutex_lock(&pm.processMutex)
	pm.shouldShutdown = true
	sync.mutex_unlock(&pm.processMutex)

	log.info("[Shutdown] Signaling service threads to stop...")
	IPC_Server_send(&pm.config.networkSocket, pm.config.networkFd, ProcessShutdown{})
	IPC_Server_send(&pm.config.webAdminSocket, pm.config.webAdminFd, ProcessShutdown{})
	IPC_Server_send(&pm.config.databaseSocket, pm.config.databaseFd, ProcessShutdown{})

	shutdownStart := time.now()
	for time.since(shutdownStart) < 10 * time.Second {
		sync.mutex_lock(&pm.processMutex)
		allStopped :=
			!pm.networkProcess.isRunning &&
			!pm.webAdminProcess.isRunning &&
			!pm.databaseProcess.isRunning
		sync.mutex_unlock(&pm.processMutex)
		if allStopped {
			log.info("[Shutdown] All service threads exited")
			return
		}
		thread.yield()
	}

	log.info("[Shutdown] Timed out waiting for all service threads to stop")
}
