package client

import "../common"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// haychat:// links (plan D19, #43 G2).
//
//   haychat://HOST:PORT/join[?key=SERVER_PUBLIC_KEY_HEX]
//   haychat://HOST:PORT/invite/CODE?key=SERVER_PUBLIC_KEY_HEX
//
// An invite link carries the server's identity key, so the client pins it and the code only
// ever goes to that server; a link whose key differs from the pin already kept for that
// address is refused. Opening a link never connects or signs up on its own: the client shows
// the server and asks first (State.pendingLink, view_registration.odin), and only Join then
// adds or matches the server entry, pins the key, and connects, for an invite with
// ClientAuthRequestPayload.registering set and the code in the sign-up form. The user still
// presses Sign up. A link's code is never logged (redactHaychatLink) or saved.
//
// Hand-off between processes: a link opened while HayChat already runs starts a second
// process (the scheme handler). That process writes the link to a file only the user can
// read, in the per-user runtime directory ($XDG_RUNTIME_DIR/haychat) or, without one, the
// config directory (on Windows %APPDATA%\haychat), created new (O_CREAT|O_EXCL, so it never
// follows a link someone planted) with mode 0600, and exits. The running instance reads it
// within LINK_HANDOFF_POLL_MS, deletes it, and shows the confirmation. Never /tmp.

HAYCHAT_LINK_SCHEME :: "haychat://"
HAYCHAT_LINK_JOIN_PATH :: "join"
HAYCHAT_LINK_INVITE_PATH :: "invite"
HAYCHAT_LINK_MAX_BYTES :: 512
HAYCHAT_LINK_HOST_MAX_BYTES :: 253
LINK_HANDOFF_FILE :: "link-handoff"
LINK_INSTANCE_FILE :: "instance"
LINK_HANDOFF_POLL_MS :: 1000

HaychatLinkKind :: enum u8 {
	Join,
	Invite,
}

HaychatLinkError :: enum u8 {
	None,
	NotHaychat, // Not a haychat:// link, too long, or not valid UTF-8
	BadHost,
	BadPort,
	BadPath, // Neither /join nor /invite/CODE, or something after them
	BadCode, // Not a valid invite code
	BadKey, // key= is not 64 hex characters, or appears twice
	MissingKey, // An invite link without key=
}

// A parsed link. host and code are owned (HaychatLink_deinit wipes the code). code is in the
// grouped form formatInviteCode makes.
HaychatLink :: struct {
	kind:   HaychatLinkKind,
	host:   string,
	port:   i32,
	code:   string,
	hasKey: bool,
	key:    common.IdentityPublicKeyBytes,
}

HaychatLink_deinit :: proc(link: ^HaychatLink) {
	delete(link.host)
	common.wipeAndDeleteString(&link.code)
	link^ = {}
}

haychatLinkErrorText :: proc(err: HaychatLinkError) -> string {
	switch err {
	case .None:
		return ""
	case .NotHaychat:
		return "This is not a HayChat link."
	case .BadHost:
		return "The link's server address is not valid."
	case .BadPort:
		return "The link's port must be a number from 1 to 65535."
	case .BadPath:
		return "The link is neither a join link nor an invite link."
	case .BadCode:
		return "The link's invite code is not valid."
	case .BadKey:
		return "The link's server key is not valid."
	case .MissingKey:
		return "The invite link does not name the server's key, so it cannot be trusted."
	}
	return ""
}

@(private = "file")
linkHostCharOK :: proc(c: u8) -> bool {
	switch c {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '.', '-', '_':
		return true
	}
	return false
}

@(private = "file")
linkIPv6CharOK :: proc(c: u8) -> bool {
	switch c {
	case 'a' ..= 'f', 'A' ..= 'F', '0' ..= '9', ':', '.':
		return true
	}
	return false
}

// Parses a haychat:// link. Strict: the host is a name or an IPv4 address (letters, digits,
// dots, dashes, underscores) or an IPv6 address in brackets, the port is required, and the
// only query parameter is key. Allocated with allocator on success; nothing to free on error.
parseHaychatLink :: proc(
	url: string,
	allocator := context.allocator,
) -> (
	link: HaychatLink,
	err: HaychatLinkError,
) {
	if len(url) > HAYCHAT_LINK_MAX_BYTES ||
	   !strings.has_prefix(strings.to_lower(url[:min(len(url), len(HAYCHAT_LINK_SCHEME))],
			   context.temp_allocator), HAYCHAT_LINK_SCHEME) {
		return {}, .NotHaychat
	}
	rest := url[len(HAYCHAT_LINK_SCHEME):]
	if strings.contains_any(rest, "#%@ \t\r\n\\") {
		return {}, .NotHaychat
	}
	query := ""
	if question := strings.index_byte(rest, '?'); question >= 0 {
		query = rest[question + 1:]
		rest = rest[:question]
	}
	authority := rest
	path := ""
	if slash := strings.index_byte(rest, '/'); slash >= 0 {
		authority = rest[:slash]
		path = rest[slash + 1:]
	}

	// HOST:PORT, or [IPv6]:PORT.
	host, portText := "", ""
	if strings.has_prefix(authority, "[") {
		close := strings.index_byte(authority, ']')
		if close < 0 || close + 1 >= len(authority) || authority[close + 1] != ':' {
			return {}, .BadHost
		}
		host = authority[1:close]
		portText = authority[close + 2:]
		if len(host) == 0 || !strings.contains_rune(host, ':') {
			return {}, .BadHost
		}
		for index in 0 ..< len(host) {
			if !linkIPv6CharOK(host[index]) {
				return {}, .BadHost
			}
		}
	} else {
		colon := strings.last_index_byte(authority, ':')
		if colon < 0 {
			return {}, .BadPort
		}
		host = authority[:colon]
		portText = authority[colon + 1:]
		if len(host) == 0 || len(host) > HAYCHAT_LINK_HOST_MAX_BYTES {
			return {}, .BadHost
		}
		for index in 0 ..< len(host) {
			if !linkHostCharOK(host[index]) {
				return {}, .BadHost
			}
		}
		if host[0] == '.' || host[0] == '-' || strings.contains(host, "..") {
			return {}, .BadHost
		}
	}
	if len(portText) == 0 || len(portText) > 5 {
		return {}, .BadPort
	}
	for index in 0 ..< len(portText) {
		if portText[index] < '0' || portText[index] > '9' {
			return {}, .BadPort
		}
	}
	port, portOK := strconv.parse_int(portText, 10)
	if !portOK || port < 1 || port > 65535 {
		return {}, .BadPort
	}

	// The path: join (or nothing, the old form), or invite/CODE.
	kind := HaychatLinkKind.Join
	codeText := ""
	path = strings.trim_suffix(path, "/")
	switch {
	case path == "" || strings.equal_fold(path, HAYCHAT_LINK_JOIN_PATH):
		kind = .Join
	case len(path) > len(HAYCHAT_LINK_INVITE_PATH) + 1 &&
	     strings.equal_fold(path[:len(HAYCHAT_LINK_INVITE_PATH)], HAYCHAT_LINK_INVITE_PATH) &&
	     path[len(HAYCHAT_LINK_INVITE_PATH)] == '/':
		kind = .Invite
		codeText = path[len(HAYCHAT_LINK_INVITE_PATH) + 1:]
		if strings.contains_rune(codeText, '/') {
			return {}, .BadPath
		}
	case:
		return {}, .BadPath
	}

	// The query: key=HEX, at most once. Other parameters are ignored.
	hasKey := false
	key: common.IdentityPublicKeyBytes
	remaining := query
	for parameter in strings.split_iterator(&remaining, "&") {
		if len(parameter) == 0 {
			continue
		}
		name, value := parameter, ""
		if equals := strings.index_byte(parameter, '='); equals >= 0 {
			name = parameter[:equals]
			value = parameter[equals + 1:]
		}
		if name != "key" {
			continue
		}
		lowerValue := strings.to_lower(value, context.temp_allocator)
		parsed, keyOK := common.identityPublicKeyFromHex(lowerValue)
		if hasKey || !keyOK || len(value) != 2 * len(common.IdentityPublicKeyBytes{}) {
			return {}, .BadKey
		}
		key = parsed
		hasKey = true
	}

	code := ""
	if kind == .Invite {
		parsedCode, codeOK := common.parseInviteCode(codeText)
		if !codeOK {
			return {}, .BadCode
		}
		if !hasKey {
			return {}, .MissingKey
		}
		code = common.formatInviteCode(parsedCode, allocator)
	}
	return HaychatLink {
			kind = kind,
			host = strings.clone(host, allocator),
			port = i32(port),
			code = code,
			hasKey = hasKey,
			key = key,
		},
		.None
}

// The link for logs: an invite code is replaced by "<code>", so it never reaches a log.
// Allocated with allocator.
redactHaychatLink :: proc(url: string, allocator := context.temp_allocator) -> string {
	marker := "/" + HAYCHAT_LINK_INVITE_PATH + "/"
	lower := strings.to_lower(url, context.temp_allocator)
	start := strings.index(lower, marker)
	if start < 0 {
		return strings.clone(url, allocator)
	}
	codeStart := start + len(marker)
	codeEnd := len(url)
	if question := strings.index_byte(url[codeStart:], '?'); question >= 0 {
		codeEnd = codeStart + question
	}
	return strings.concatenate({url[:codeStart], "<code>", url[codeEnd:]}, allocator)
}

// ── Matching the link with the config ─────────────────────────────

LinkServerMatch :: enum u8 {
	NewServer, // No server in the list has this address: it is added
	Pinned, // A server with this address has this key pinned
	Unpinned, // A server with this address has no key yet: the link's key is pinned
	KeyDiffers, // A server with this address has another key pinned: refused (D19)
}

// Which configured server the link names, and whether its key agrees with the pin.
linkServerMatch :: proc(
	config: Config,
	link: HaychatLink,
) -> (
	match: LinkServerMatch,
	serverID: int,
) {
	for server in config.servers {
		if !strings.equal_fold(server.host, link.host) || server.port != link.port {
			continue
		}
		if len(server.pinned_server_public_key) == 0 {
			return .Unpinned, server.id
		}
		if !link.hasKey {
			return .Pinned, server.id
		}
		if classifyServerIdentity(
			   server.pinned_server_public_key,
			   server.pinned_server_fingerprint,
			   link.key,
		   ) ==
		   .Trusted {
			return .Pinned, server.id
		}
		return .KeyDiffers, server.id
	}
	return .NewServer, 0
}

// A link waiting for the user's answer. Owned.
PendingLink :: struct {
	open:       bool,
	link:       HaychatLink,
	match:      LinkServerMatch,
	serverID:   int,
	// The server as the confirmation names it: its label, or the link's address.
	serverName: string,
	// Why the link cannot be followed; the confirmation then offers only Close.
	error:      string,
}

PendingLink_deinit :: proc(pending: ^PendingLink) {
	HaychatLink_deinit(&pending.link)
	delete(pending.serverName)
	delete(pending.error)
	pending^ = {}
}

State_deinitPendingLink :: proc(state: ^State) {
	PendingLink_deinit(&state.pendingLink)
}

// Opens a link: parses it and shows the confirmation (or why it is refused). Nothing connects
// until State_confirmPendingLink. url is borrowed.
State_openLink :: proc(state: ^State, url: string) {
	PendingLink_deinit(&state.pendingLink)
	pending := &state.pendingLink
	pending.open = true
	link, err := parseHaychatLink(url)
	if err != .None {
		pending.error = strings.clone(haychatLinkErrorText(err))
		pending.serverName = strings.clone("")
		fmt.eprintln("[Info] Refused a haychat link:", redactHaychatLink(url))
		return
	}
	pending.link = link
	pending.match, pending.serverID = linkServerMatch(state.config, link)
	if server, ok := State_serverConfig(state, pending.serverID); ok {
		pending.serverName = strings.clone(server.name)
	} else {
		pending.serverName = serverLabel(link.host, link.port)
	}
	if pending.match == .KeyDiffers {
		pending.error = fmt.aprintf(
			"This link names another key for %s than the one pinned for it. It was not " +
			"followed. If the server was reinstalled, forget its key in Server settings first.",
			pending.serverName,
		)
	}
}

// Cancel / Close: forgets the link, its code included.
State_cancelPendingLink :: proc(state: ^State) {
	PendingLink_deinit(&state.pendingLink)
}

// Join / Sign up: adds or matches the server entry, pins the link's key, selects the server
// and connects; an invite connects with registering set and puts the code in the sign-up
// form. Returns "" on success, otherwise why it did not (the dialog shows it).
State_confirmPendingLink :: proc(state: ^State) -> string {
	pending := &state.pendingLink
	if !pending.open || len(pending.error) > 0 {
		return pending.error
	}
	link := &pending.link
	keyHex, fingerprintHex := "", ""
	if link.hasKey {
		keyText := common.identityPublicKeyToHex(link.key)
		fingerprintText := common.fingerprintToHex(common.fingerprintIdentityPublicKey(link.key))
		keyHex = strings.clone(keyText, context.temp_allocator)
		fingerprintHex = strings.clone(fingerprintText, context.temp_allocator)
		delete(keyText)
		delete(fingerprintText)
	}
	// Check again: the config may have changed while the dialog was open.
	match, serverID := linkServerMatch(state.config, link^)
	invite := link.kind == .Invite
	switch match {
	case .KeyDiffers:
		delete(pending.error)
		pending.error = strings.clone("The link names another key than the one pinned for it.")
		return pending.error
	case .NewServer:
		serverID = 1
		for server in state.config.servers {
			serverID = max(serverID, server.id + 1)
		}
		name := serverLabel(link.host, link.port)
		append(
			&state.config.servers,
			Server {
				id = serverID,
				name = name,
				short_name = getShortServerName(name),
				host = strings.clone(link.host),
				port = link.port,
				pinned_server_public_key = strings.clone(keyHex),
				pinned_server_fingerprint = strings.clone(fingerprintHex),
			},
		)
		State_saveConfig(state)
		State_reconfigureNetwork(state)
	case .Unpinned:
		if server, ok := State_serverConfig(state, serverID); ok && link.hasKey {
			Server_setPins(server, keyHex, fingerprintHex)
			State_saveConfig(state)
			// matchesConfig compares the pin, so only this server's transport is rebuilt.
			State_reconfigureNetwork(state)
		}
	case .Pinned:
	}
	if state.settingsOpen && !State_needsFirstRunSetup(state.config) {
		State_closeSettings(state)
	}
	State_switchToServer(state, serverID)
	if invite {
		State_prefillSignUpCode(state, serverID, link.code)
	}
	// Signed in already: the account exists, so a code has nothing to do.
	if State_isServerConnected(state, serverID) {
		if invite {
			State_wipeSignUpFormFor(state, serverID)
			State_setChatStatus(state, "You already have an account on this server.")
		}
		PendingLink_deinit(pending)
		return ""
	}
	if transportIndex := State_selectedTransportIndexForServerID(state^, serverID);
	   transportIndex >= 0 {
		transport := &state.serverTransports[transportIndex]
		ClientNetworkWorker_lock(state.networkWorker)
		if invite {
			ClientServerTransport_setRegistering(transport, true)
		}
		configInvalid := transport.configInvalid
		ClientServerTransport_requestConnect(transport, {})
		ClientNetworkWorker_unlock(state.networkWorker)
		if !configInvalid {
			connection := State_serverConnection(state, serverID)
			connection.status = .Connecting
		}
	}
	PendingLink_deinit(pending)
	return ""
}

// ── Hand-off between processes ────────────────────────────────────

// The per-user directory for the hand-off and instance files (see the top of this file).
// Allocated with allocator; empty when there is none.
linkHandoffDir :: proc(allocator := context.allocator) -> string {
	when ODIN_OS == .Linux {
		runtimeDir := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
		if len(runtimeDir) > 0 && os.is_dir(runtimeDir) {
			return strings.concatenate({runtimeDir, "/", haychatFolder}, allocator)
		}
	}
	configDir := getConfigDir()
	defer delete(configDir)
	return strings.clone(configDir, allocator)
}

// Writes data to path as a new file only the user may read: created with O_CREAT|O_EXCL (a
// planted file or symbolic link is removed first, never followed) and mode 0600.
writePrivateFileNew :: proc(path: string, data: []u8) -> bool {
	for attempt in 0 ..< 2 {
		file, err := os.open(path, {.Write, .Create, .Excl}, os.perm(0o600))
		if err != nil {
			if attempt == 0 && linkPathExists(path) {
				// remove never follows a symbolic link: it removes the link itself.
				_ = os.remove(path)
				continue
			}
			return false
		}
		_, writeErr := os.write(file, data)
		_ = os.close(file)
		if writeErr != nil {
			_ = os.remove(path)
			return false
		}
		return true
	}
	return false
}

// Whether anything (a dangling symbolic link too) is at path.
@(private = "file")
linkPathExists :: proc(path: string) -> bool {
	_, err := os.lstat(path, context.temp_allocator)
	return err == nil
}

// Reads and deletes a private file: only a regular file (not a link), and only when it is
// not readable by others. Returns the data in allocator, or ok false.
readPrivateFileOnce :: proc(
	path: string,
	maxBytes: int,
	allocator := context.allocator,
) -> (
	data: []u8,
	ok: bool,
) {
	info, statErr := os.lstat(path, context.temp_allocator)
	if statErr != nil {
		return nil, false
	}
	defer _ = os.remove(path)
	if info.type != .Regular || info.size > i64(maxBytes) {
		return nil, false
	}
	when ODIN_OS != .Windows {
		if transmute(u32)info.mode & 0o077 != 0 {
			return nil, false
		}
	}
	read, readErr := os.read_entire_file_from_path(path, allocator)
	if readErr != nil {
		return nil, false
	}
	return read, true
}

// The scheme handler's second process: hands the link to the running instance. Returns false
// when it could not (the caller then opens it itself).
writeLinkHandoff :: proc(url: string) -> bool {
	dir := linkHandoffDir()
	defer delete(dir)
	if len(dir) == 0 {
		return false
	}
	if err := os.make_directory_all(dir, os.perm(0o700)); err != nil && !os.is_dir(dir) {
		return false
	}
	path := strings.concatenate({dir, "/", LINK_HANDOFF_FILE})
	defer delete(path)
	return writePrivateFileNew(path, transmute([]u8)url)
}

// The running instance: a link another process left, read and deleted. Allocated with
// allocator; ok false when there is none.
takeLinkHandoff :: proc(allocator := context.allocator) -> (url: string, ok: bool) {
	dir := linkHandoffDir(context.temp_allocator)
	if len(dir) == 0 {
		return "", false
	}
	path := strings.concatenate({dir, "/", LINK_HANDOFF_FILE}, context.temp_allocator)
	data, read := readPrivateFileOnce(path, HAYCHAT_LINK_MAX_BYTES + 2, allocator)
	if !read {
		return "", false
	}
	result := strings.clone(strings.trim_space(string(data)), allocator)
	wipeBytes(data)
	delete(data, allocator)
	return result, true
}

// The instance file: this process's ID and executable, so a second process can tell whether
// a HayChat window is running. Written by the GUI at start, removed at exit.
writeLinkInstanceFile :: proc() -> bool {
	dir := linkHandoffDir()
	defer delete(dir)
	if len(dir) == 0 {
		return false
	}
	if err := os.make_directory_all(dir, os.perm(0o700)); err != nil && !os.is_dir(dir) {
		return false
	}
	path := strings.concatenate({dir, "/", LINK_INSTANCE_FILE})
	defer delete(path)
	text := fmt.tprintf("%d\n", os.get_pid())
	return writePrivateFileNew(path, transmute([]u8)text)
}

removeLinkInstanceFile :: proc() {
	dir := linkHandoffDir(context.temp_allocator)
	if len(dir) > 0 {
		_ = os.remove(strings.concatenate({dir, "/", LINK_INSTANCE_FILE}, context.temp_allocator))
	}
}

// Whether another HayChat process (the one named by the instance file, running this same
// executable) is running.
linkOtherInstanceRunning :: proc() -> bool {
	dir := linkHandoffDir(context.temp_allocator)
	if len(dir) == 0 {
		return false
	}
	path := strings.concatenate({dir, "/", LINK_INSTANCE_FILE}, context.temp_allocator)
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return false
	}
	pid, pidOK := strconv.parse_int(strings.trim_space(string(data)), 10)
	if !pidOK || pid <= 0 || pid == os.get_pid() {
		return false
	}
	own, ownErr := os.get_executable_path(context.temp_allocator)
	if ownErr != nil {
		return false
	}
	info, infoErr := os.process_info_by_pid(pid, {.Executable_Path}, context.temp_allocator)
	defer os.free_process_info(info, context.temp_allocator)
	return infoErr == nil && info.executable_path == own
}

// The GUI's poll for links another process handed over (app.odin), at most every
// LINK_HANDOFF_POLL_MS.
State_pollLinkHandoff :: proc(state: ^State) -> bool {
	if !state.linkHandoffWatch {
		return false
	}
	now := time.tick_now()
	if state.linkHandoffPolledAt != {} &&
	   time.tick_diff(state.linkHandoffPolledAt, now) < LINK_HANDOFF_POLL_MS * time.Millisecond {
		return false
	}
	state.linkHandoffPolledAt = now
	url, ok := takeLinkHandoff()
	if !ok {
		return false
	}
	defer common.wipeAndDeleteString(&url)
	State_openLink(state, url)
	return true
}
