package server

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"
import http "shared:odin-http"

pmWebAdmin: ^ProcessManager // Global pointer to process manager for web admin handlers

webAdminServerLoop :: proc(pm: ^ProcessManager) {
	fmt.println("[WebAdmin] Web admin server loop started (PID: %d)", os.get_pid())
	pmWebAdmin = pm // Set global pointer so handlers can access process manager

	webAdminFd, ipcInitErr := IPC_Client_init(&pm.config.webAdminSocket)
	if ipcInitErr != nil {
		fmt.eprintfln("[WebAdmin] Failed to initialize coordinator endpoint:", ipcInitErr)
		return
	}
	pm.config.webAdminFd = webAdminFd
	defer IPC_Client_deinit(&pm.config.webAdminSocket)

	s: http.Server

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

statusWebAdmin :: proc(req: ^http.Request, res: ^http.Response) {
	err_send := IPC_Client_send(pmWebAdmin.config.webAdminFd, Wake{})
	if err_send != nil {
		fmt.eprintfln("[WebAdmin] IPC send error: %s", err_send)
		http.respond_plain(res, "Error sending wake signal")
		return
	}
	for {
		message, err := IPC_Client_poll(pmWebAdmin.config.webAdminFd)
		if err != nil {
			fmt.eprintfln("[WebAdmin] IPC poll error: %s", err)
			http.respond_plain(res, "Error retrieving peer list")
			return
		}
		if message != nil {
			switch typeid_of(type_of(message)) {
			case Wake:
				// This is just a wake signal to check if the main process is alive, we can ignore it and just respond with status
				http.respond_plain(res, "Server is running")
				return
			case:
				fmt.eprintfln(
					"[WebAdmin] Received unexpected message type: %s",
					typeid_of(type_of(message)),
				)
				http.respond_plain(res, "Error retrieving peer list")
				return
			}
		}
	}
}

peersWebAdmin :: proc(req: ^http.Request, res: ^http.Response) {
	http.respond_plain(res, "Peer list is currently unavailable")
	err_send := IPC_Client_send(pmWebAdmin.config.webAdminFd, AdminGetPeers{})
	if err_send != nil {
		fmt.eprintfln("[WebAdmin] IPC send error: %s", err_send)
		http.respond_plain(res, "Error sending peer list request")
		return
	}
	for {
		message, err := IPC_Client_poll(pmWebAdmin.config.webAdminFd)
		if err != nil {
			fmt.eprintfln("[WebAdmin] IPC poll error: %s", err)
			http.respond_plain(res, "Error retrieving peer list")
			return
		}
		if message != nil {
			switch typeid_of(type_of(message)) {
			case AdminGetPeersResponse:
				peer_list := message.(AdminGetPeersResponse)
				peer_list_str := ""
				for peer in peer_list.peers {
					peer_list_str, _ = strings.concatenate(
						{
							peer_list_str,
							fmt.aprintfln("Peer: %s (ID: %d)\n", peer.address, peer.peerId),
						},
					)
				}
				http.respond_plain(res, fmt.aprintf("Peers:\n%s", peer_list_str))
				return
			case:
				fmt.eprintfln(
					"[WebAdmin] Received unexpected message type: %s",
					typeid_of(type_of(message)),
				)
				http.respond_plain(res, "Error retrieving peer list")
				return
			}
		}
	}
}

logsWebAdmin :: proc(req: ^http.Request, res: ^http.Response) {
	http.respond_plain(res, "Logs are currently unavailable")
	err_send := IPC_Client_send(pmWebAdmin.config.webAdminFd, AdminGetLogs{})
	if err_send != nil {
		fmt.eprintfln("[WebAdmin] IPC send error: %s", err_send)
		http.respond_plain(res, "Error sending log request")
		return
	}
	for {
		message, err := IPC_Client_poll(pmWebAdmin.config.webAdminFd)
		if err != nil {
			fmt.eprintfln("[WebAdmin] IPC poll error: %s", err)
			http.respond_plain(res, "Error retrieving logs")
			return
		}
		if message != nil {
			switch typeid_of(type_of(message)) {
			case AdminGetLogsResponse:
				logs := message.(AdminGetLogsResponse)
				logs_str := ""
				for log_entry in logs.logs {
					logs_str, _ = strings.concatenate({logs_str, fmt.aprintfln("%s\n", log_entry)})
				}
				http.respond_plain(res, fmt.aprintf("Logs:\n%s", logs_str))
				return
			case:
				fmt.eprintfln(
					"[WebAdmin] Received unexpected message type: %s",
					typeid_of(type_of(message)),
				)
				http.respond_plain(res, "Error retrieving logs")
				return
			}
		}
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
