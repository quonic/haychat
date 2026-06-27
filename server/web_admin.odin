package server

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"
import http "shared:odin-http"

pmWebAdmin: ^ProcessManager // Global pointer to process manager for web admin handlers
webAdminHTTPServer: ^http.Server

shutdownWebAdminHTTPServer :: proc() {
	if webAdminHTTPServer != nil {
		http.server_shutdown(webAdminHTTPServer)
	}
}

webAdminServerLoop :: proc(pm: ^ProcessManager) {
	fmt.printfln("[WebAdmin] Web admin server loop started (PID: %d)", os.get_pid())
	pmWebAdmin = pm // Set global pointer so handlers can access process manager

	webAdminFd, ipcInitErr := IPC_Client_init(&pm.config.webAdminSocket)
	if ipcInitErr != nil {
		fmt.eprintfln("[WebAdmin] Failed to initialize coordinator endpoint:", ipcInitErr)
		return
	}
	pm.config.webAdminFd = webAdminFd
	defer IPC_Client_deinit(&pm.config.webAdminSocket)

	s: http.Server
	webAdminHTTPServer = &s
	defer {
		if webAdminHTTPServer == &s {
			webAdminHTTPServer = nil
		}
	}

	// Set up routing
	router: http.Router
	http.router_init(&router)
	defer http.router_destroy(&router)

	// Routes are tried in order.
	// Route matching is implemented using an implementation of Lua patterns, see the docs on them here:
	// https://www.lua.org/pil/20.2.html
	// They are very similar to regex patterns but a bit more limited, which makes them much easier to implement since Odin does not have a regex implementation.
	http.route_get(&router, "/status", http.handler(statusWebAdmin))
	http.route_get(&router, "/peers", http.handler(peersWebAdmin))
	http.route_get(&router, "/logs", http.handler(logsWebAdmin))
	http.route_post(&router, "/shutdown", http.handler(shutdownWebAdmin))
	http.route_post(&router, "/restart", http.handler(restartWebAdmin))

	// Matches every get request that did not match another route.
	http.route_get(&router, "(.*)", http.handler(webAdmin404))

	routed := http.router_handler(&router)

	fmt.printfln("Listening on http://localhost:%d", pm.config.webAdminPort)

	err := http.listen_and_serve(
		&s,
		routed,
		net.Endpoint{address = net.IP4_Loopback, port = pm.config.webAdminPort},
	)
	if err != nil {
		fmt.eprintfln("[WebAdmin] HTTP server error: %s", err)
	}

	fmt.eprintfln("[WebAdmin] Process shutting down")
}

WEB_ADMIN_POLL_TIMEOUT :: 250 * time.Millisecond

awaitWebAdminMessage :: proc(clientFd: linux.Fd, timeout: time.Duration) -> (Message, bool) {
	start := time.now()
	for time.since(start) < timeout {
		message, err := IPC_Client_poll(clientFd)
		if err == nil {
			return message, true
		}
		time.sleep(1 * time.Millisecond)
	}
	return Message{}, false
}

statusWebAdmin :: proc(req: ^http.Request, res: ^http.Response) {
	_ = req
	err_send := IPC_Client_send(pmWebAdmin.config.webAdminFd, AdminQueryStatus{})
	if err_send != nil {
		fmt.eprintfln("[WebAdmin] IPC send error: %s", err_send)
		http.respond_plain(res, "Error sending status request")
		return
	}

	message, ok := awaitWebAdminMessage(pmWebAdmin.config.webAdminFd, WEB_ADMIN_POLL_TIMEOUT)
	if !ok {
		http.respond_plain(res, "Timed out waiting for status response")
		return
	}

	#partial switch msg in message {
	case AdminQueryStatusResponse:
		http.respond_plain(
			res,
			fmt.aprintf(
				"uptime=%d\nconnected_peers=%d\nnetwork_running=%v\nweb_admin_running=%v\ndatabase_running=%v\nnetwork_restart_pending=%v\nweb_admin_restart_pending=%v\ndatabase_restart_pending=%v\nshutdown_requested=%v",
				msg.uptime,
				msg.connectedPeers,
				msg.networkRunning,
				msg.webAdminRunning,
				msg.databaseRunning,
				msg.networkRestartPending,
				msg.webAdminRestartPending,
				msg.databaseRestartPending,
				msg.shutdownRequested,
			),
		)
	case:
		fmt.eprintfln("[WebAdmin] Received unexpected message type")
		http.respond_plain(res, "Error retrieving status")
	}
}

peersWebAdmin :: proc(req: ^http.Request, res: ^http.Response) {
	_ = req
	err_send := IPC_Client_send(pmWebAdmin.config.webAdminFd, AdminGetPeers{})
	if err_send != nil {
		fmt.eprintfln("[WebAdmin] IPC send error: %s", err_send)
		http.respond_plain(res, "Error sending peer list request")
		return
	}

	message, ok := awaitWebAdminMessage(pmWebAdmin.config.webAdminFd, WEB_ADMIN_POLL_TIMEOUT)
	if !ok {
		http.respond_plain(res, "Timed out waiting for peer list response")
		return
	}

	#partial switch msg in message {
	case AdminGetPeersResponse:
		peerListStr := ""
		for peer in msg.peers {
			peerListStr, _ = strings.concatenate(
				{
					peerListStr,
					fmt.aprintfln(
						"Peer ID: %d auth=%v user_id=%d\n",
						peer.peerId,
						peer.isAuthenticated,
						peer.authenticatedId,
					),
				},
			)
		}
		http.respond_plain(res, fmt.aprintf("Peers:\n%s", peerListStr))
	case:
		fmt.eprintfln("[WebAdmin] Received unexpected message type")
		http.respond_plain(res, "Error retrieving peer list")
	}
}

logsWebAdmin :: proc(req: ^http.Request, res: ^http.Response) {
	_ = req
	err_send := IPC_Client_send(pmWebAdmin.config.webAdminFd, AdminGetLogs{})
	if err_send != nil {
		fmt.eprintfln("[WebAdmin] IPC send error: %s", err_send)
		http.respond_plain(res, "Error sending log request")
		return
	}

	message, ok := awaitWebAdminMessage(pmWebAdmin.config.webAdminFd, WEB_ADMIN_POLL_TIMEOUT)
	if !ok {
		http.respond_plain(res, "Timed out waiting for log response")
		return
	}

	#partial switch msg in message {
	case AdminGetLogsResponse:
		logsStr := ""
		for logEntry in msg.logs {
			logsStr, _ = strings.concatenate({logsStr, fmt.aprintfln("%s\n", logEntry)})
		}
		http.respond_plain(res, fmt.aprintf("Logs:\n%s", logsStr))
	case:
		fmt.eprintfln("[WebAdmin] Received unexpected message type")
		http.respond_plain(res, "Error retrieving logs")
	}
}

shutdownWebAdmin :: proc(req: ^http.Request, res: ^http.Response) {
	err := IPC_Client_send(pmWebAdmin.config.webAdminFd, ProcessShutdown{})
	if err != nil {
		fmt.eprintfln("[WebAdmin] IPC send error: %s", err)
		http.respond_plain(res, "Error sending shutdown signal")
		return
	}
	http.respond_plain(res, "Server is shutting down")
}

restartWebAdmin :: proc(req: ^http.Request, res: ^http.Response) {
	err := IPC_Client_send(pmWebAdmin.config.webAdminFd, ProcessRestart{})
	if err != nil {
		fmt.eprintfln("[WebAdmin] IPC send error: %s", err)
		http.respond_plain(res, "Error sending restart signal")
		return
	}
	http.respond_plain(res, "Server is restarting")
}

webAdmin404 :: proc(req: ^http.Request, res: ^http.Response) {
	http.respond_with_status(res, .Not_Found)
}
