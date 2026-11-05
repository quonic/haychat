package server

import "../common"
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
	defer webAdminHTTPServer = nil

	// Set up routing
	router: http.Router
	http.router_init(&router)
	defer http.router_destroy(&router)

	// Routes are tried in order.
	// Route matching is implemented using an implementation of Lua patterns, see the docs on them here:
	// https://www.lua.org/pil/20.2.html
	// They are very similar to regex patterns but a bit more limited, which makes them much easier to implement since Odin does not have a regex implementation.
	// /status stays open as a health probe; every other route requires the bearer token.
	http.route_get(&router, "/status", http.handler(statusWebAdmin))
	http.route_get(&router, "/peers", http.handler(peersWebAdmin))
	http.route_get(&router, "/logs", http.handler(logsWebAdmin))
	http.route_post(&router, "/shutdown", http.handler(shutdownWebAdmin))
	http.route_post(&router, "/restart", http.handler(restartWebAdmin))

	// Matches every get request that did not match another route.
	http.route_get(&router, "(.*)", http.handler(webAdmin404))

	routed := http.router_handler(&router)

	fmt.printfln("Listening on http://localhost:%d", pm.config.webAdminPort)
	if len(os.get_env("HAYCHAT_WEB_ADMIN_TOKEN", context.temp_allocator)) == 0 {
		fmt.printfln("[WebAdmin] Bearer token stored in %s", pm.config.webAdminTokenFilePath)
	}

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
	for {
		message, err := IPC_Client_poll(clientFd)
		if err == nil {
			return message, true
		}
		remaining := timeout - time.since(start)
		if remaining <= 0 {
			return Message{}, false
		}
		IPC_Client_wait(clientFd, remaining)
	}
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
		http.respond_plain(res, webAdminFormatStatus(msg))
	case:
		fmt.eprintfln("[WebAdmin] Received unexpected message type")
		http.respond_plain(res, "Error retrieving status")
	}
}

// One key=value line per field. The voice lines follow the process lines; drops are one line
// per VoiceRelayDropReason, named voice_drops_<reason in snake case>.
webAdminFormatStatus :: proc(
	msg: AdminQueryStatusResponse,
	allocator := context.allocator,
) -> string {
	builder := strings.builder_make(allocator)
	fmt.sbprintf(
		&builder,
		"uptime=%d\nconnected_peers=%d\nnetwork_running=%v\nweb_admin_running=%v\n" +
		"database_running=%v\nnetwork_restart_pending=%v\nweb_admin_restart_pending=%v\n" +
		"database_restart_pending=%v\nshutdown_requested=%v",
		msg.uptime,
		msg.connectedPeers,
		msg.networkRunning,
		msg.webAdminRunning,
		msg.databaseRunning,
		msg.networkRestartPending,
		msg.webAdminRestartPending,
		msg.databaseRestartPending,
		msg.shutdownRequested,
	)
	fmt.sbprintf(
		&builder,
		"\nvoice_rooms=%d\nvoice_participants=%d\nvoice_frames_in=%d\n" +
		"voice_frames_relayed=%d\nvoice_frames_out=%d\nvoice_send_failures=%d",
		msg.voiceRooms,
		msg.voiceParticipants,
		msg.voiceRelay.datagramsIn,
		msg.voiceRelay.framesRelayed,
		msg.voiceRelay.datagramsOut,
		msg.voiceRelay.sendFailures,
	)
	for reason in VoiceRelayDropReason {
		fmt.sbprintf(
			&builder,
			"\nvoice_drops_%s=%d",
			WEB_ADMIN_VOICE_DROP_NAMES[reason],
			msg.voiceRelay.drops[reason],
		)
	}
	return strings.to_string(builder)
}

WEB_ADMIN_VOICE_DROP_NAMES := [VoiceRelayDropReason]string {
	.UnknownPeer    = "unknown_peer",
	.NotInRoom      = "not_in_room",
	.RateLimited    = "rate_limited",
	.Malformed      = "malformed",
	.Replayed       = "replayed",
	.TooOld         = "too_old",
	.BadTag         = "bad_tag",
	.Inactive       = "inactive",
	.MalformedFrame = "malformed_frame",
	.WrongRoom      = "wrong_room",
	.Muted          = "muted",
	.Oversize       = "oversize",
	.BadDuration    = "bad_duration",
}

peersWebAdmin :: proc(req: ^http.Request, res: ^http.Response) {
	if !webAdminAuthorize(req, res) {
		return
	}
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
	if !webAdminAuthorize(req, res) {
		return
	}
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
	if !webAdminAuthorize(req, res) {
		return
	}
	err := IPC_Client_send(pmWebAdmin.config.webAdminFd, ProcessShutdown{})
	if err != nil {
		fmt.eprintfln("[WebAdmin] IPC send error: %s", err)
		http.respond_plain(res, "Error sending shutdown signal")
		return
	}
	http.respond_plain(res, "Server is shutting down")
}

restartWebAdmin :: proc(req: ^http.Request, res: ^http.Response) {
	if !webAdminAuthorize(req, res) {
		return
	}
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

WEB_ADMIN_BEARER_PREFIX :: "Bearer "

// Reports whether an Authorization header carries the expected bearer token. The custom
// header also forces a CORS preflight, so browsers cannot forge these requests cross-site.
webAdminAuthorizationValid :: proc(authorization: string, expectedToken: string) -> bool {
	if len(expectedToken) == 0 || !strings.has_prefix(authorization, WEB_ADMIN_BEARER_PREFIX) {
		return false
	}
	presented := authorization[len(WEB_ADMIN_BEARER_PREFIX):]
	if len(presented) != len(expectedToken) {
		return false
	}
	return common.constantTimeEqual(transmute([]u8)presented, transmute([]u8)expectedToken)
}

// Guards a protected handler. Responds 401 and returns false when the token is missing or wrong.
webAdminAuthorize :: proc(req: ^http.Request, res: ^http.Response) -> bool {
	authorization, _ := http.headers_get(req.headers, "authorization")
	if webAdminAuthorizationValid(authorization, pmWebAdmin.config.webAdminToken) {
		return true
	}
	http.respond_with_status(res, .Unauthorized)
	return false
}
