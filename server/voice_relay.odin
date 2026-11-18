package server

import "../common"
import "core:sync"

// The voice data plane (voice-rooms-design.md 4.3). The network thread owns one VoiceRelay. It
// holds each peer's voice crypto halves, which the router hands over once at auth success
// (NetworkVoiceSessionOpen), and the recipient set of every voice room, which the router
// replaces on every change (NetworkVoiceRoute). Each inbound datagram on ENet channel 2 is
// opened, checked and resealed for every other participant here, so voice never enters the IPC
// queues, the router loop or the database.
//
// The relay is a pure state machine: sending a datagram and reading the clock are injected, so
// tests drive it without ENet. Only the network thread touches it, so it has no mutex.
//
// Encrypted rooms (protocol 21, e2ee-voice-design.md 6): a route marked encrypted carries
// SealedVoicePayloads (common/voice_e2ee.odin) in the frames' opus field. The relay cannot read
// the Opus TOC there, so it skips the duration check, drops a payload that is not a version 1
// sealed payload with at least one Opus byte (NotSealed), applies maxFrameBytes to the payload
// minus VOICE_E2EE_OVERHEAD, and forwards the payload byte for byte. Unencrypted rooms are
// relayed exactly as before.

// Sends one sealed datagram to peerId, unreliable and unsequenced on the voice channel. The
// datagram is a scratch buffer that the relay reuses, so the sender must copy it (ENet's
// packet_create does). Returns false when the datagram could not be queued.
VoiceRelaySendProc :: #type proc(userData: rawptr, peerId: u32, datagram: []u8) -> bool

// Returns a monotonic time in nanoseconds; only differences matter.
VoiceRelayClockProc :: #type proc(userData: rawptr) -> i64

VoiceRelayConfig :: struct {
	maxPacketsPerSecond: int, // per-peer token bucket rate; the burst is a third of it
	maxFrameBytes:       int, // largest Opus payload forwarded
}

// Why a datagram was dropped. Every drop is counted and none of them disconnects the peer:
// ENet does not authenticate datagrams, so a spoofer must not be able to end a session.
VoiceRelayDropReason :: enum u8 {
	UnknownPeer, // no voice session for the sending peer
	NotInRoom, // the sender is in no voice room
	RateLimited, // the sender's token bucket was empty
	Malformed, // the datagram envelope was too short or of an unknown kind
	Replayed, // the sequence was already accepted
	TooOld, // the sequence is behind the replay window
	BadTag, // authentication failed: forged, corrupted, or sealed under another key
	Inactive, // the peer's voice receive state has no key
	MalformedFrame, // the plaintext is not a ClientVoiceFrame (truncated, no Opus bytes)
	WrongRoom, // the frame names a room other than the sender's
	Muted, // the sender is muted
	Oversize, // the Opus payload is over HAYCHAT_VOICE_MAX_FRAME_BYTES
	BadDuration, // the Opus TOC byte does not describe exactly 20 ms
	// Protocol 21: in an encrypted room, a payload shorter than a sealed one with one Opus byte,
	// or whose version byte is not VOICE_E2EE_VERSION, so plaintext never reaches listeners.
	NotSealed,
	// Protocol 24: the sender lacks SpeakInVoice in the room (NetworkVoiceRouteMember.speakDenied).
	NoSpeakPermission,
}

VoiceRelayStats :: struct {
	datagramsIn:   u64, // every datagram received on the voice channel
	framesRelayed: u64, // frames that passed every check and were fanned out
	datagramsOut:  u64, // sealed datagrams handed to the sender
	sendFailures:  u64, // seals or sends that failed for one recipient
	drops:         [VoiceRelayDropReason]u64,
}

// Token bucket for one peer. tokens is fractional so a rate that does not divide a second
// evenly still refills exactly.
VoiceTokenBucket :: struct {
	tokens:      f64,
	lastNanos:   i64,
	initialized: bool,
}

VoiceRelayPeer :: struct {
	userId:    int,
	sessionID: common.SessionID,
	// The only live copy of this peer's voice send state (Q8): the router's copy was zeroed by
	// TransportState_takeVoiceState and the IPC message's copy is wiped when it is freed. A
	// second copy in use would reuse voice nonces.
	send:      common.ChannelSendState,
	receive:   common.VoiceReceiveState,
	roomId:    int, // 0 when not in voice
	muted:     bool,
	deafened:  bool,
	// Protocol 24: the peer may not speak in its room; its frames are dropped.
	speakDenied: bool,
	// The room the peer is in is encrypted (NetworkVoiceRoute.encrypted).
	encrypted: bool,
	bucket:    VoiceTokenBucket,
}

VoiceRelay :: struct {
	config:    VoiceRelayConfig,
	send:      VoiceRelaySendProc,
	clock:     VoiceRelayClockProc,
	userData:  rawptr,
	// Peers are heap allocated one by one, so a map rehash never copies key material into
	// memory the relay cannot wipe; each one is wiped before it is freed.
	peers:     map[u32]^VoiceRelayPeer,
	rooms:     map[int][dynamic]u32, // roomId -> peer IDs, in route order
	// Scratch buffers, so a frame costs no allocation. plaintext holds the opened client frame
	// and then, rewritten in place, the server frame.
	plaintext: [common.SERVER_VOICE_FRAME_MAX_SIZE]u8,
	sealed:    [common.VOICE_DATAGRAM_MAX_SIZE]u8,
	stats:     VoiceRelayStats,
	// Set whenever stats change, so the network loop publishes them only when needed.
	statsDirty: bool,
}

VoiceRelay_init :: proc(
	relay: ^VoiceRelay,
	config: VoiceRelayConfig,
	send: VoiceRelaySendProc,
	clock: VoiceRelayClockProc,
	userData: rawptr,
) {
	relay^ = VoiceRelay {
		config   = config,
		send     = send,
		clock    = clock,
		userData = userData,
		peers    = make(map[u32]^VoiceRelayPeer),
		rooms    = make(map[int][dynamic]u32),
	}
}

VoiceRelay_deinit :: proc(relay: ^VoiceRelay) {
	VoiceRelay_reset(relay)
	delete(relay.peers)
	delete(relay.rooms)
	relay.peers = nil
	relay.rooms = nil
}

@(private = "file")
VoiceRelay__freePeer :: proc(peer: ^VoiceRelayPeer) {
	common.ChannelSendState_wipe(&peer.send)
	common.VoiceReceiveState_wipe(&peer.receive)
	free(peer)
}

// Forgets every peer and room and wipes every key. Used when the network service restarts.
VoiceRelay_reset :: proc(relay: ^VoiceRelay) {
	for _, peer in relay.peers {
		VoiceRelay__freePeer(peer)
	}
	clear(&relay.peers)
	for _, members in relay.rooms {
		delete(members)
	}
	clear(&relay.rooms)
	// The plaintext scratch held the last frame relayed.
	relay.plaintext = {}
	relay.sealed = {}
}

// Removes peerId from roomId's recipient list, and the room when that leaves it empty.
@(private = "file")
VoiceRelay__removeFromRoom :: proc(relay: ^VoiceRelay, roomId: int, peerId: u32) {
	members, ok := &relay.rooms[roomId]
	if !ok {
		return
	}
	for index := 0; index < len(members); index += 1 {
		if members[index] == peerId {
			ordered_remove(members, index)
			index -= 1
		}
	}
	if len(members) == 0 {
		delete(members^)
		delete_key(&relay.rooms, roomId)
	}
}

// Takes over the voice halves in msg and wipes them there, so the relay's copy is the only one.
// A second open for the same peer replaces the first, wiping its keys and leaving its room.
VoiceRelay_openSession :: proc(relay: ^VoiceRelay, msg: ^NetworkVoiceSessionOpen) {
	VoiceRelay_removePeer(relay, msg.peerId)

	peer := new(VoiceRelayPeer)
	peer.userId = msg.userId
	peer.sessionID = msg.sessionID
	peer.send = msg.send
	peer.receive = msg.receive
	common.ChannelSendState_wipe(&msg.send)
	common.VoiceReceiveState_wipe(&msg.receive)
	relay.peers[msg.peerId] = peer
}

// Forgets peerId at once, wiping its keys and removing it from its room. Called on disconnect,
// before the router hears about it, so frames stop flowing to and from the peer immediately.
VoiceRelay_removePeer :: proc(relay: ^VoiceRelay, peerId: u32) {
	peer, ok := relay.peers[peerId]
	if !ok {
		return
	}
	if peer.roomId != 0 {
		VoiceRelay__removeFromRoom(relay, peer.roomId, peerId)
	}
	delete_key(&relay.peers, peerId)
	VoiceRelay__freePeer(peer)
}

VoiceRelay_hasPeer :: proc(relay: ^VoiceRelay, peerId: u32) -> bool {
	return peerId in relay.peers
}

// Replaces roomId's recipient set with members. Members without a voice session (a peer that
// disconnected after the router built the route) are skipped. A member that was in another
// room leaves it, and a former member that is not listed leaves this one.
VoiceRelay_applyRoute :: proc(
	relay: ^VoiceRelay,
	roomId: int,
	members: []NetworkVoiceRouteMember,
	encrypted := false,
) {
	if roomId <= 0 {
		return
	}

	// Former members leave the room; the ones still listed are added back below.
	if previous, ok := relay.rooms[roomId]; ok {
		for peerId in previous {
			if peer, peerOK := relay.peers[peerId]; peerOK && peer.roomId == roomId {
				peer.roomId = 0
				peer.muted = false
				peer.deafened = false
				peer.speakDenied = false
				peer.encrypted = false
			}
		}
		delete(previous)
		delete_key(&relay.rooms, roomId)
	}

	// Members that are still in another room leave it first. This runs before the new list
	// exists, because removing an emptied room deletes a map key.
	for member in members {
		peer, peerOK := relay.peers[member.peerId]
		if peerOK && peer.roomId != 0 && peer.roomId != roomId {
			VoiceRelay__removeFromRoom(relay, peer.roomId, member.peerId)
			peer.roomId = 0
			peer.encrypted = false
		}
	}

	list := make([dynamic]u32, 0, len(members))
	for member in members {
		peer, peerOK := relay.peers[member.peerId]
		if !peerOK || peer.roomId == roomId {
			continue // no voice session, or listed twice
		}
		peer.roomId = roomId
		peer.muted = member.muted
		peer.deafened = member.deafened
		peer.speakDenied = member.speakDenied
		peer.encrypted = encrypted
		append(&list, member.peerId)
	}
	if len(list) == 0 {
		delete(list)
		return
	}
	relay.rooms[roomId] = list
}

// Refills the bucket for the time since the last datagram and takes one token.
VoiceTokenBucket_take :: proc(
	bucket: ^VoiceTokenBucket,
	nowNanos: i64,
	ratePerSecond: int,
) -> bool {
	rate := f64(max(ratePerSecond, 1))
	burst := max(rate / 3, 1)
	if !bucket.initialized {
		bucket.initialized = true
		bucket.tokens = burst
		bucket.lastNanos = nowNanos
	}
	elapsed := nowNanos - bucket.lastNanos
	if elapsed > 0 {
		bucket.tokens = min(burst, bucket.tokens + f64(elapsed) * rate / 1e9)
		bucket.lastNanos = nowNanos
	}
	if bucket.tokens < 1 {
		return false
	}
	bucket.tokens -= 1
	return true
}

@(private = "file")
VoiceRelay__drop :: proc(relay: ^VoiceRelay, reason: VoiceRelayDropReason) {
	relay.stats.drops[reason] += 1
}

// Handles one datagram that peerId sent on the voice channel. It never logs, never allocates,
// and never disconnects anyone; every outcome is counted in relay.stats. datagram is borrowed.
VoiceRelay_handleDatagram :: proc(relay: ^VoiceRelay, peerId: u32, datagram: []u8) {
	relay.stats.datagramsIn += 1
	relay.statsDirty = true

	sender, senderOK := relay.peers[peerId]
	if !senderOK {
		VoiceRelay__drop(relay, .UnknownPeer)
		return
	}
	if sender.roomId == 0 {
		VoiceRelay__drop(relay, .NotInRoom)
		return
	}
	// Before decryption, so a flood costs the server no AEAD work.
	if !VoiceTokenBucket_take(
		&sender.bucket,
		relay.clock(relay.userData),
		relay.config.maxPacketsPerSecond,
	) {
		VoiceRelay__drop(relay, .RateLimited)
		return
	}

	plaintextLength, openResult := common.openVoiceDatagram(
		&sender.receive,
		sender.sessionID,
		datagram,
		relay.plaintext[:],
	)
	switch openResult {
	case .Ok:
	case .Malformed:
		VoiceRelay__drop(relay, .Malformed)
		return
	case .Replayed:
		VoiceRelay__drop(relay, .Replayed)
		return
	case .TooOld:
		VoiceRelay__drop(relay, .TooOld)
		return
	case .BadTag:
		VoiceRelay__drop(relay, .BadTag)
		return
	case .Inactive:
		VoiceRelay__drop(relay, .Inactive)
		return
	}

	frame, frameResult := common.decodeClientVoiceFrame(relay.plaintext[:plaintextLength])
	switch frameResult {
	case .Ok:
	case .Truncated, .EmptyOpus:
		VoiceRelay__drop(relay, .MalformedFrame)
		return
	case .OpusTooLarge:
		VoiceRelay__drop(relay, .Oversize)
		return
	}
	// A frame sent before a room switch must not leak into the new room.
	if int(frame.roomId) != sender.roomId {
		VoiceRelay__drop(relay, .WrongRoom)
		return
	}
	if sender.muted {
		VoiceRelay__drop(relay, .Muted)
		return
	}
	if sender.speakDenied {
		VoiceRelay__drop(relay, .NoSpeakPermission)
		return
	}
	if sender.encrypted {
		// A sealed payload: its version byte and length are all the relay can check. The
		// receiving client checks the Opus duration after opening it.
		if !common.voicePayloadLooksSealed(frame.opus) {
			VoiceRelay__drop(relay, .NotSealed)
			return
		}
		if len(frame.opus) - common.VOICE_E2EE_OVERHEAD > relay.config.maxFrameBytes {
			VoiceRelay__drop(relay, .Oversize)
			return
		}
	} else {
		if len(frame.opus) > relay.config.maxFrameBytes {
			VoiceRelay__drop(relay, .Oversize)
			return
		}
		if !common.opusPacketIsVoiceFrameDuration(frame.opus) {
			VoiceRelay__drop(relay, .BadDuration)
			return
		}
	}

	// Rewrite the plaintext in place as the frame every recipient gets; frame.opus is a slice
	// of the same buffer, and the encoder moves it before writing the longer header.
	outgoingLength, encodeOK := common.encodeServerVoiceFrame(
		common.ServerVoiceFrame {
			roomId = frame.roomId,
			senderUserId = u32(sender.userId),
			frameSequence = frame.frameSequence,
			flags = frame.flags,
			opus = frame.opus,
		},
		relay.plaintext[:],
	)
	if !encodeOK {
		// Unreachable: the Opus length was checked above and the buffer fits the largest frame.
		VoiceRelay__drop(relay, .Oversize)
		return
	}
	relay.stats.framesRelayed += 1

	members := relay.rooms[sender.roomId]
	for recipientId in members {
		if recipientId == peerId {
			continue // never echo a frame to its sender
		}
		recipient, recipientOK := relay.peers[recipientId]
		if !recipientOK || recipient.deafened {
			continue
		}
		sealedLength, sealOK := common.sealVoiceDatagram(
			&recipient.send,
			recipient.sessionID,
			relay.plaintext[:outgoingLength],
			relay.sealed[:],
		)
		if !sealOK || !relay.send(relay.userData, recipientId, relay.sealed[:sealedLength]) {
			relay.stats.sendFailures += 1
			continue
		}
		relay.stats.datagramsOut += 1
	}
}

// The relay counters the network thread last published, read by the main thread for its
// periodic [Status] log line (Q9, status.odin). Each field is written and read with atomics: the counters are independent, so a
// reader may see one pass's datagramsIn with the previous pass's drops, which is fine for
// counters and costs no lock or IPC message on the voice path.
voiceRelayPublishedStats: VoiceRelayStats

VoiceRelayStats_publish :: proc(destination: ^VoiceRelayStats, stats: VoiceRelayStats) {
	sync.atomic_store_explicit(&destination.datagramsIn, stats.datagramsIn, .Relaxed)
	sync.atomic_store_explicit(&destination.framesRelayed, stats.framesRelayed, .Relaxed)
	sync.atomic_store_explicit(&destination.datagramsOut, stats.datagramsOut, .Relaxed)
	sync.atomic_store_explicit(&destination.sendFailures, stats.sendFailures, .Relaxed)
	for reason in VoiceRelayDropReason {
		sync.atomic_store_explicit(&destination.drops[reason], stats.drops[reason], .Relaxed)
	}
}

VoiceRelayStats_load :: proc(source: ^VoiceRelayStats) -> VoiceRelayStats {
	stats: VoiceRelayStats
	stats.datagramsIn = sync.atomic_load_explicit(&source.datagramsIn, .Relaxed)
	stats.framesRelayed = sync.atomic_load_explicit(&source.framesRelayed, .Relaxed)
	stats.datagramsOut = sync.atomic_load_explicit(&source.datagramsOut, .Relaxed)
	stats.sendFailures = sync.atomic_load_explicit(&source.sendFailures, .Relaxed)
	for reason in VoiceRelayDropReason {
		stats.drops[reason] = sync.atomic_load_explicit(&source.drops[reason], .Relaxed)
	}
	return stats
}

// Publishes the relay's counters if they changed since the last call.
VoiceRelay_publishStats :: proc(relay: ^VoiceRelay, destination: ^VoiceRelayStats) {
	if !relay.statsDirty {
		return
	}
	relay.statsDirty = false
	VoiceRelayStats_publish(destination, relay.stats)
}
