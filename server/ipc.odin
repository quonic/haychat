package server

import sa "core:container/small_array"
import "core:encoding/cbor"
import "core:log"
import "core:net"
import "core:slice"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "vendor:ENet"

SERVER_SOCKET :: "\x00haychat"
MAX_CLIENTS :: 64
BUF_SIZE :: 1024

IPC_Server_Context :: struct {
	server_fd:            linux.Fd,
	server_addr:          linux.Sock_Addr_Un,
	messages:             [dynamic]IPC_Message,
	_clients:             sa.Small_Array(MAX_CLIENTS, linux.Poll_Fd),
	_removed_clients:     sa.Small_Array(MAX_CLIENTS, linux.Fd),
	_volume_subscribers:  sa.Small_Array(MAX_CLIENTS, linux.Fd),
	_program_subscribers: sa.Small_Array(MAX_CLIENTS, linux.Fd),
	_buf:                 [BUF_SIZE]u8,
}

IPC_Message :: struct {
	msg_bytes: []u8,
	sender:    linux.Fd,
}

Message :: union {
	Wake,
	// Network process messages
	NetworkPeerConnected, // Sent by network process when a new peer connects
	NetworkPeerDisconnected, // Sent by network process when a peer disconnects
	NetworkDataReceived, // Sent by network process when data is received from a peer
	NetworkSendData, // Sent by main process to network process to send data to a peer
	NetworkBroadcast, // Sent by main process to network process to broadcast data to all peers
	NetworkDisconnectPeer, // Sent by main process to network process to disconnect a peer
	// Web admin messages
	AdminQueryStatus, // Sent by web admin process to query server status
	AdminQueryStatusResponse, // Sent by main process in response to AdminQueryStatus
	AdminGetPeers, // Sent by web admin process to request list of connected peers
	AdminGetPeersResponse, // Sent by main process in response to AdminGetPeers
	AdminGetLogs, // Sent by web admin process to request recent logs
	AdminGetLogsResponse, // Sent by main process in response to AdminGetLogs
	// Database messages
	DatabaseQuery, // Sent by main process to database process to execute a query
	DatabaseQueryResult, // Sent by database process in response to DatabaseQuery
	DatabaseError, // Sent by database process if a query fails
	// System messages
	ProcessShutdown, // Graceful shutdown of the process, can be used for all processes
	ProcessRestart, // Graceful restart of the process, can be used for all processes
	ProcessError, // Generic error message with string payload
}

NetworkPeerConnected :: struct {
	peerId:  u32,
	address: ENet.Address, // Remote peer address (IP4 or IP6)
}

NetworkPeerDisconnected :: struct {
	peerId: u32,
}

NetworkChannel :: enum u8 {
	None = 0,
	Chat,
	Voice,
	Video,
	Screenshare,
	FileTransfer,
}

NetworkDataReceived :: struct {
	peerId:  u32,
	channel: NetworkChannel,
	data:    []u8,
}

NetworkSendData :: struct {
	peerId:  u32,
	channel: NetworkChannel,
	data:    []u8,
}

NetworkBroadcast :: struct {
	channel: NetworkChannel,
	data:    []u8,
}

NetworkDisconnectPeer :: struct {
	peerId: u32,
}

AdminQueryStatus :: struct {
	// Empty - requests full server status
}

AdminQueryStatusResponse :: struct {
	uptime:         i64, // Seconds since startup
	connectedPeers: int,
}

AdminGetPeers :: struct {
	// Empty - requests list of connected peers
}

AdminGetPeersResponse :: struct {
	peers: []NetworkPeerInfo,
}

AdminGetLogs :: struct {
	// Empty - requests recent server logs
}

AdminGetLogsResponse :: struct {
	logs: []string, // Recent server logs
}

DatabaseQuery :: struct {
	query: string, // SQL query string
}

DatabaseQueryResult :: struct {
	result: string, // Query result
}

DatabaseError :: struct {
	error: string, // Error message
}

ProcessShutdown :: struct {}

ProcessRestart :: struct {}

ProcessError :: struct {
	error: string, // Error message
}

Wake :: struct {}


IPC_Server_init :: proc(ctx: ^IPC_Server_Context, socket_name: string) -> linux.Errno {
	posix.signal(.SIGPIPE, IPC_Server__handle_sigpipe)

	sock_err: linux.Errno
	ctx.server_fd, sock_err = linux.socket(.UNIX, .STREAM, {.NONBLOCK}, .HOPOPT)
	if sock_err != nil do log.panicf("could not create socket with error %v", sock_err)

	ctx.server_addr.sun_family = .UNIX
	copy(ctx.server_addr.sun_path[:], socket_name)

	linux.unlink(strings.clone_to_cstring(socket_name))
	linux.bind(ctx.server_fd, &ctx.server_addr) or_return
	listen_err := linux.listen(ctx.server_fd, 1024)
	sa.append(&ctx._clients, linux.Poll_Fd{fd = ctx.server_fd, events = {.IN}})
	return listen_err
}

IPC_Client_init :: proc(ctx: ^IPC_Server_Context) -> (linux.Fd, linux.Errno) {
	client_fd, sock_err := linux.socket(.UNIX, .STREAM, {.NONBLOCK}, .HOPOPT)
	if sock_err != nil do return 0, sock_err

	connect_err := linux.connect(client_fd, &ctx.server_addr)
	if connect_err != nil do return 0, connect_err

	return client_fd, nil
}

IPC_Server_poll :: proc(ctx: ^IPC_Server_Context) {
	_, poll_err := linux.poll(sa.slice(&ctx._clients), 5)
	if poll_err != nil do return

	if sa.get(ctx._clients, 0).revents >= {.IN} {
		client_fd, client_err := linux.accept(ctx.server_fd, &ctx.server_addr, {.NONBLOCK})
		if client_err != nil do log.panicf("accept error %v", client_err)
		log.debugf("client connected: socket %v", client_fd)
		sa.append(&ctx._clients, linux.Poll_Fd{fd = client_fd, events = {.IN}})
	}

	n_bytes: int
	clear(&ctx.messages)
	sa.clear(&ctx._removed_clients)
	#reverse for &client, idx in sa.slice(&ctx._clients)[1:] {
		if client.revents >= {.IN} {
			bytes_read, read_err := linux.read(client.fd, ctx._buf[n_bytes:])
			if read_err == .EWOULDBLOCK || read_err == .EAGAIN do continue
			if read_err != nil {
				log.debugf("client error %v disconnecting: socket %v", read_err, client.fd)
				sa.unordered_remove(&ctx._clients, idx + 1)
				sa.append(&ctx._removed_clients, client.fd)
			} else if bytes_read == 0 {
				log.debugf("client disconnected: socket %v", client.fd)
				sa.unordered_remove(&ctx._clients, idx + 1)
				sa.append(&ctx._removed_clients, client.fd)
			} else if bytes_read == 1024 {
				log.debugf("client error UNKNOWN disconnecting: socket %v", client.fd)
				sa.unordered_remove(&ctx._clients, idx + 1)
				sa.append(&ctx._removed_clients, client.fd)
			} else {
				log.debugf("read %v bytes: socket %v", bytes_read, client.fd)
				msg_bytes := ctx._buf[n_bytes:n_bytes + bytes_read]
				append(&ctx.messages, IPC_Message{msg_bytes, client.fd})
				n_bytes += bytes_read
			}
		}
	}

	for fd in sa.slice(&ctx._removed_clients) {
		// Example cleanup for a disconnected client - remove from subscription lists
		// IPC_Server_remove_volume_subscriber(ctx, fd)
		// IPC_Server_remove_program_subscriber(ctx, fd)
		linux.close(fd)
	}
}

IPC_Client_poll :: proc(client_fd: linux.Fd) -> (Message, linux.Errno) {
	buf: [BUF_SIZE]u8
	n_bytes, read_err := linux.read(client_fd, buf[:])
	if read_err != nil do return Message{}, read_err
	if n_bytes == 0 do return Message{}, linux.Errno(-1) // EOF

	msg: Message
	unmarshal_err := cbor.unmarshal(buf[:n_bytes], &msg)
	if unmarshal_err != nil do return Message{}, linux.Errno(-1)

	return msg, nil
}

IPC_Client_send :: proc(client_fd: linux.Fd, msg: Message) -> linux.Errno {
	cbor_msg, _ := cbor.marshal(msg)
	defer delete(cbor_msg)

	bytes_sent, send_err := linux.send(client_fd, cbor_msg, {})
	if send_err != nil {log.errorf("could not send with error %v: socket %v", send_err, client_fd)
	} else {log.debugf("sent %v bytes from client: socket %v", bytes_sent, client_fd)}
	return send_err
}

IPC_Server_send :: proc(ctx: ^IPC_Server_Context, client_fd: linux.Fd, msg: Message) {
	_, found := slice.linear_search(sa.slice(&ctx._removed_clients), client_fd)
	if found {
		log.debugf("attempted to send to removed socket: %v, skipping", client_fd)
		return
	}

	cbor_msg, _ := cbor.marshal(msg)
	defer delete(cbor_msg)

	bytes_sent, send_err := linux.send(client_fd, cbor_msg, {})
	if send_err != nil {
		log.errorf("could not send with error %v: socket %v", send_err, client_fd)
		sa.append(&ctx._removed_clients, client_fd)
		return
	}

	log.debugf("sent %v bytes from server: socket %v", bytes_sent, client_fd)
}

// Example subscription management functions for volume and program updates

// IPC_Server_add_volume_subscriber :: proc(ctx: ^IPC_Server_Context, client_fd: linux.Fd) {
// 	_, found := slice.linear_search(sa.slice(&ctx._volume_subscribers), client_fd)
// 	if !found do sa.append(&ctx._volume_subscribers, client_fd)
// }

// IPC_Server_remove_volume_subscriber :: proc(ctx: ^IPC_Server_Context, client_fd: linux.Fd) {
// 	idx, found := slice.linear_search(sa.slice(&ctx._volume_subscribers), client_fd)
// 	if found {
// 		log.debugf("removed volume subscriber: socket %v", client_fd)
// 		sa.unordered_remove(&ctx._volume_subscribers, idx)
// 	}
// }

// IPC_Server_add_program_subscriber :: proc(ctx: ^IPC_Server_Context, client_fd: linux.Fd) {
// 	_, found := slice.linear_search(sa.slice(&ctx._program_subscribers), client_fd)
// 	if !found do sa.append(&ctx._program_subscribers, client_fd)
// }

// IPC_Server_remove_program_subscriber :: proc(ctx: ^IPC_Server_Context, client_fd: linux.Fd) {
// 	idx, found := slice.linear_search(sa.slice(&ctx._program_subscribers), client_fd)
// 	if found {
// 		log.debugf("removed program subscriber: socket %v", client_fd)
// 		sa.unordered_remove(&ctx._program_subscribers, idx)
// 	}
// }

// IPC_Server_notify_volume_subscription :: proc(ctx: ^IPC_Server_Context, volume: f32) {
// 	msg := Volume{.Get, volume}
// 	for client_fd in sa.slice(&ctx._volume_subscribers) do IPC_Server_send(ctx, client_fd, msg)
// }

IPC_Server_deinit :: proc(ctx: ^IPC_Server_Context) -> linux.Errno {
	delete(ctx.messages)
	for client in sa.slice(&ctx._clients) do linux.close(client.fd)
	return linux.close(ctx.server_fd)
}

IPC_Client_deinit :: proc(ctx: ^IPC_Server_Context) -> linux.Errno {
	// Client cleanup can be handled by the server when it detects a disconnect
	return nil
}

// blank handler to ignore sigpipe
IPC_Server__handle_sigpipe :: proc "c" (signum: posix.Signal) {}
