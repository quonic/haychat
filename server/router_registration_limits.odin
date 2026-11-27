package server

import "../common"
import "core:fmt"
import "core:time"
import ENet "vendor:ENet"

// Per-address sign-up limits (#105). They add to the per-session limits (D13) in
// router_registration.odin and live in the router's memory only, so a restart resets them.
//
// - Sessions: at most HAYCHAT_REGISTRATION_IP_SESSIONS of the common.REGISTERING_SESSIONS_MAX
//   registering sessions may come from one address, counted from MainRouterState.peerSessions.
// - Attempts: a token bucket per address (HAYCHAT_REGISTRATION_IP_ATTEMPTS_BURST tokens,
//   refilled at HAYCHAT_REGISTRATION_IP_ATTEMPTS_PER_MINUTE). Entering the registering state
//   and every ClientRegister take a token; a refusal takes none.
// - Requests: a second bucket (HAYCHAT_REGISTRATION_IP_REQUESTS_PER_HOUR tokens, refilled at
//   that many an hour) for sign-up requests the register statement creates (outcome Pending).
//   The router cannot know before the statement whether a ClientRegister will make a request,
//   so in Invite + approval mode it reserves a token when it sends one and gives the token back
//   when the answer is not Pending; a Pending answer it did not reserve for (the mode changed
//   meanwhile) takes one. Requests made with SQL or before a restart are not counted.
//
// A refused session start is ServerAuthFailure and a disconnect, as REGISTRATION_BUSY_MESSAGE
// is; a refused ClientRegister is ServerRegisterResponse Refused and counts as one of the
// session's attempts. No protocol change.
//
// The address is the peer address ENet reports (RegistrationAddress). The table of buckets
// holds at most REGISTRATION_ADDRESS_TABLE_MAX addresses: an address whose buckets are full
// again is forgotten by the once-a-second sweep (MainRouterState_pruneRegistrationAddresses),
// and when the table is still full the address used longest ago is forgotten for a new one,
// so the limiter cannot itself be used to fill memory.

// The address one sign-up limit counts against, as 16 IPv6 bytes. IPv4 addresses (all ENet
// reports today) and IPv4-mapped IPv6 addresses are the mapped form ::ffff:a.b.c.d, one
// address each. Any other IPv6 address keeps its /64 prefix with the interface identifier
// zeroed, because one host or household is commonly given a whole /64.
RegistrationAddress :: distinct [16]u8

// The most addresses the limiter tracks at once (a few hundred kilobytes).
REGISTRATION_ADDRESS_TABLE_MAX :: 4096

// One address's buckets. Tokens are refilled lazily from refilledAt.
RegistrationAddressEntry :: struct {
	attemptTokens: f64,
	requestTokens: f64,
	refilledAt:    time.Tick,
	lastUsed:      time.Tick,
}

// The configured limits; 0 turns sessions, attempts or requests off.
RegistrationLimits :: struct {
	sessions:          int,
	attemptsBurst:     int,
	attemptsPerMinute: int,
	requestsPerHour:   int,
}

registrationLimitsFromConfig :: proc(config: ^ServerConfig) -> RegistrationLimits {
	if config == nil {
		return {}
	}
	return RegistrationLimits {
		sessions = config.registrationIPSessions,
		attemptsBurst = config.registrationIPAttemptsBurst,
		attemptsPerMinute = config.registrationIPAttemptsPerMinute,
		requestsPerHour = config.registrationIPRequestsPerHour,
	}
}

// An IPv4 address as ENet keeps it (network byte order in memory).
registrationAddressFromIPv4 :: proc(octets: [4]u8) -> RegistrationAddress {
	address: RegistrationAddress
	address[10] = 0xff
	address[11] = 0xff
	address[12] = octets[0]
	address[13] = octets[1]
	address[14] = octets[2]
	address[15] = octets[3]
	return address
}

// An IPv6 address: IPv4-mapped ones are their IPv4 address, others their /64.
registrationAddressFromIPv6 :: proc(bytes: [16]u8) -> RegistrationAddress {
	mapped := bytes[10] == 0xff && bytes[11] == 0xff
	for index in 0 ..< 10 {
		mapped &&= bytes[index] == 0
	}
	if mapped {
		return registrationAddressFromIPv4({bytes[12], bytes[13], bytes[14], bytes[15]})
	}
	address := RegistrationAddress(bytes)
	for index in 8 ..< 16 {
		address[index] = 0
	}
	return address
}

registrationAddressFromENet :: proc(address: ENet.Address) -> RegistrationAddress {
	return registrationAddressFromIPv4(transmute([4]u8)address.host)
}

// The address for a log line, written into buffer: "a.b.c.d" or "xxxx:xxxx:xxxx:xxxx::/64".
registrationAddressText :: proc(address: RegistrationAddress, buffer: []u8) -> string {
	mapped := address[10] == 0xff && address[11] == 0xff
	for index in 0 ..< 10 {
		mapped &&= address[index] == 0
	}
	if mapped {
		return fmt.bprintf(
			buffer,
			"%d.%d.%d.%d",
			address[12],
			address[13],
			address[14],
			address[15],
		)
	}
	return fmt.bprintf(
		buffer,
		"%x:%x:%x:%x::/64",
		u16(address[0]) << 8 | u16(address[1]),
		u16(address[2]) << 8 | u16(address[3]),
		u16(address[4]) << 8 | u16(address[5]),
		u16(address[6]) << 8 | u16(address[7]),
	)
}

// Refills entry's buckets up to their sizes for the time since refilledAt. now may not be
// earlier than refilledAt; then nothing changes.
registrationAddressRefill :: proc(
	entry: ^RegistrationAddressEntry,
	limits: RegistrationLimits,
	now: time.Tick,
) {
	elapsed := time.duration_seconds(time.tick_diff(entry.refilledAt, now))
	if elapsed <= 0 {
		return
	}
	if limits.attemptsBurst > 0 {
		entry.attemptTokens = min(
			f64(limits.attemptsBurst),
			entry.attemptTokens + elapsed * f64(limits.attemptsPerMinute) / 60,
		)
	}
	if limits.requestsPerHour > 0 {
		entry.requestTokens = min(
			f64(limits.requestsPerHour),
			entry.requestTokens + elapsed * f64(limits.requestsPerHour) / 3600,
		)
	}
	entry.refilledAt = now
}

// Whether entry's buckets are as full as a new address's, so forgetting it changes nothing.
registrationAddressIsIdle :: proc(
	entry: RegistrationAddressEntry,
	limits: RegistrationLimits,
) -> bool {
	attemptsFull := limits.attemptsBurst <= 0 || entry.attemptTokens >= f64(limits.attemptsBurst)
	requestsFull :=
		limits.requestsPerHour <= 0 || entry.requestTokens >= f64(limits.requestsPerHour)
	return attemptsFull && requestsFull
}

// Forgets every address whose buckets are full again; with no bucket configured, every one.
MainRouterState_pruneRegistrationAddresses :: proc(
	state: ^MainRouterState,
	limits: RegistrationLimits,
	now: time.Tick,
) {
	if limits.attemptsBurst <= 0 && limits.requestsPerHour <= 0 {
		clear(&state.registrationAddresses)
		return
	}
	idle := make([dynamic]RegistrationAddress)
	defer delete(idle)
	for address, &entry in state.registrationAddresses {
		registrationAddressRefill(&entry, limits, now)
		if registrationAddressIsIdle(entry, limits) {
			append(&idle, address)
		}
	}
	for address in idle {
		delete_key(&state.registrationAddresses, address)
	}
}

// The buckets of address, refilled to now; a new address starts full. Makes room in a full
// table first (above). The pointer is valid until the table changes.
@(private = "file")
MainRouterState_registrationAddressEntry :: proc(
	state: ^MainRouterState,
	limits: RegistrationLimits,
	address: RegistrationAddress,
	now: time.Tick,
) -> ^RegistrationAddressEntry {
	if entry, ok := &state.registrationAddresses[address]; ok {
		registrationAddressRefill(entry, limits, now)
		entry.lastUsed = now
		return entry
	}
	if len(state.registrationAddresses) >= REGISTRATION_ADDRESS_TABLE_MAX {
		MainRouterState_pruneRegistrationAddresses(state, limits, now)
	}
	if len(state.registrationAddresses) >= REGISTRATION_ADDRESS_TABLE_MAX {
		oldest: RegistrationAddress
		oldestUsed: time.Tick
		found := false
		for candidate, entry in state.registrationAddresses {
			if !found || time.tick_diff(entry.lastUsed, oldestUsed) > 0 {
				oldest = candidate
				oldestUsed = entry.lastUsed
				found = true
			}
		}
		delete_key(&state.registrationAddresses, oldest)
	}
	state.registrationAddresses[address] = RegistrationAddressEntry {
		attemptTokens = f64(max(limits.attemptsBurst, 0)),
		requestTokens = f64(max(limits.requestsPerHour, 0)),
		refilledAt    = now,
		lastUsed      = now,
	}
	return &state.registrationAddresses[address]
}

// Takes one attempt token from address; false when its bucket is empty (nothing is taken).
// Always true without an attempt limit.
MainRouterState_registrationTakeAttempt :: proc(
	state: ^MainRouterState,
	limits: RegistrationLimits,
	address: RegistrationAddress,
	now: time.Tick,
) -> bool {
	if limits.attemptsBurst <= 0 {
		return true
	}
	entry := MainRouterState_registrationAddressEntry(state, limits, address, now)
	if entry.attemptTokens < 1 {
		return false
	}
	entry.attemptTokens -= 1
	return true
}

// Takes an attempt token for a ClientRegister from address; false (logged) when its bucket is
// empty.
MainRouterState_registrationAllowsAttempt :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	address: RegistrationAddress,
	now: time.Tick,
) -> bool {
	limits := registrationLimitsFromConfig(pm.config)
	if MainRouterState_registrationTakeAttempt(state, limits, address, now) {
		return true
	}
	MainRouterState_logRegistrationAddressRefusal(
		pm,
		address,
		common.REGISTRATION_ADDRESS_RATE_MESSAGE,
	)
	return false
}

// How many sessions from address are registering now.
MainRouterState_registeringSessionsFrom :: proc(
	state: ^MainRouterState,
	address: RegistrationAddress,
) -> int {
	count := 0
	for _, session in state.peerSessions {
		if session.isRegistering && session.peerAddress == address {
			count += 1
		}
	}
	return count
}

// Whether the session at peerID may start signing up: "" when it may, else the refusal. Takes
// an attempt token only when it may.
MainRouterState_registrationAddressAdmits :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	now: time.Tick,
) -> string {
	session, ok := state.peerSessions[peerID]
	if !ok {
		return ""
	}
	limits := registrationLimitsFromConfig(pm.config)
	refusal := ""
	if limits.sessions > 0 &&
	   MainRouterState_registeringSessionsFrom(state, session.peerAddress) >= limits.sessions {
		refusal = common.REGISTRATION_ADDRESS_BUSY_MESSAGE
	} else if !MainRouterState_registrationTakeAttempt(state, limits, session.peerAddress, now) {
		refusal = common.REGISTRATION_ADDRESS_RATE_MESSAGE
	}
	if len(refusal) > 0 {
		MainRouterState_logRegistrationAddressRefusal(pm, session.peerAddress, refusal)
	}
	return refusal
}

// Reserves a sign-up request token for a ClientRegister from address (above): reserved tells
// whether one was taken, and refused that the bucket is empty in Invite + approval mode, where
// the ClientRegister must not reach the database.
MainRouterState_registrationReserveRequest :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	address: RegistrationAddress,
	mode: common.RegistrationMode,
	now: time.Tick,
) -> (
	reserved: bool,
	refused: bool,
) {
	limits := registrationLimitsFromConfig(pm.config)
	if limits.requestsPerHour <= 0 || mode != .InviteApproval {
		return false, false
	}
	entry := MainRouterState_registrationAddressEntry(state, limits, address, now)
	if entry.requestTokens < 1 {
		MainRouterState_logRegistrationAddressRefusal(
			pm,
			address,
			common.REGISTRATION_ADDRESS_REQUESTS_MESSAGE,
		)
		return false, true
	}
	entry.requestTokens -= 1
	return true, false
}

// Settles a register statement's answer against its address's request bucket: a reserved
// token comes back unless the statement made a request, and a request made without a
// reservation takes one (never below zero).
MainRouterState_registrationSettleRequest :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	madeRequest: bool,
	now: time.Tick,
) {
	limits := registrationLimitsFromConfig(pm.config)
	if limits.requestsPerHour <= 0 || request.registrationRequestReserved == madeRequest {
		return
	}
	if request.registrationRequestReserved {
		// Only an address still tracked gets it back; a forgotten one starts full anyway.
		if entry, ok := &state.registrationAddresses[request.registrationAddress]; ok {
			registrationAddressRefill(entry, limits, now)
			entry.requestTokens = min(f64(limits.requestsPerHour), entry.requestTokens + 1)
		}
		return
	}
	entry := MainRouterState_registrationAddressEntry(
		state,
		limits,
		request.registrationAddress,
		now,
	)
	entry.requestTokens = max(0, entry.requestTokens - 1)
}

// A refusal is logged only at debug level, like the other sign-up refusals: a flood of them
// must not flood the log.
@(private = "file")
MainRouterState_logRegistrationAddressRefusal :: proc(
	pm: ^ProcessManager,
	address: RegistrationAddress,
	refusal: string,
) {
	if pm.config == nil || !serverLogLevelIsDebug(pm.config.logLevel) {
		return
	}
	buffer: [64]u8
	fmt.printfln(
		"[Main] Sign-up refused for %s: %s",
		registrationAddressText(address, buffer[:]),
		refusal,
	)
}
