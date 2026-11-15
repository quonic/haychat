package client

// Voice networking (voice-rooms-design.md 1.4 and 5.2): the network worker's channel 2
// receive path into the voice engine, the voice thread's send path, and the control-message
// sends. State and actions are in voice_state.odin.
//
// Threads and ownership, all under ClientNetworkWorker_lock (the worker mutex):
//   - transport.voice (ClientTransportVoiceBinding) is written only by the UI thread, with the
//     lock held. It names the engine that may receive this server's frames and send on its
//     voice channel, the room, and the session it was made for.
//   - transport.transport.voiceReceive is used only by the network worker, in
//     ClientServerTransport_receiveVoiceDatagram, which runs inside the worker's service pass
//     with the lock held.
//   - transport.transport.voiceSend is used only by the voice thread, in
//     ClientServerTransport_sendVoiceFrame, with the lock held. The worker rewrites it when a
//     reconnect activates a new session (TransportState_activate) and wipes it when a session
//     ends, also with the lock held, so a seal never races either. Nothing copies it: it stays
//     the single live copy of the voice send counter, so no voice nonce is ever reused.
//   - The engine pointer in the binding is safe for the worker and the voice thread to use
//     while they hold the lock: the UI thread clears the binding under the lock before it
//     stops and destroys the engine (State_voiceStopEngine), and destroys the
//     ClientVoiceLink only after the engine's thread has been joined.
// Lock order: worker mutex, then the engine's inbound mutex (VoiceEngine_pushInbound). The
// voice thread never holds an engine lock while it waits for the worker mutex.

import "../common"
import "vendor:ENet"

// Voice datagrams one ClientServerTransport_serviceEstablishedSession call handles before it
// returns to the worker loop (about a second of audio from a full room per pass, at most).
CLIENT_VOICE_DATAGRAMS_PER_SERVICE :: 64

// The engine that owns this server's voice traffic, and what it was joined to.
ClientTransportVoiceBinding :: struct {
	engine:            ^VoiceEngine,
	roomID:            int,
	// transport.sessionGeneration when the join was acknowledged. A later session (after a
	// reconnect) has not joined voice, so its frames must neither be sent nor played.
	sessionGeneration: u64,
}

// Why a voice datagram was not delivered to the engine. The first five mirror
// common.VoiceOpenResult.
ClientVoiceReceiveDropReason :: enum u8 {
	Malformed, // short datagram, unknown kind, or larger than any voice frame
	Replayed,
	TooOld,
	BadTag,
	Inactive, // no voice key in this session
	FrameTruncated, // opened, but shorter than a ServerVoiceFrame header
	FrameEmpty, // a header and no Opus bytes
	FrameTooLarge, // more than common.VOICE_OPUS_MAX_BYTES of Opus
	NotJoined, // no engine bound for this session
	WrongRoom, // a frame for a room other than the joined one
	EngineRefused, // the engine is closed, deafened, or found the frame invalid
	BeforeSession, // channel 2 during the handshake
	WrongChannel, // a channel that is neither control nor voice
}

ClientVoiceSendDropReason :: enum u8 {
	NotJoined, // no live binding for this engine and room
	EncodeFailed,
	SealFailed, // no voice key, or the send counter is exhausted
	SendFailed, // ENet refused the packet or the session is gone
}

ClientVoiceNetworkStats :: struct {
	datagramsReceived: u64,
	framesDelivered:   u64,
	receiveDropped:    [ClientVoiceReceiveDropReason]u64,
	framesSent:        u64,
	sendDropped:       [ClientVoiceSendDropReason]u64,
}

// The voice thread's side of one running engine: its outbound userdata. It holds the
// buffers the voice thread seals into, so the send path allocates nothing. Allocated by
// State_voiceStartEngine and freed only after the engine is destroyed.
ClientVoiceLink :: struct {
	worker:    ^ClientNetworkWorker,
	transport: ^ClientServerTransport,
	engine:    ^VoiceEngine,
	roomID:    int,
	plaintext: [common.CLIENT_VOICE_FRAME_MAX_SIZE]u8,
	sealed:    [common.VOICE_DATAGRAM_MAX_SIZE]u8,
}

// Whether transport.voice names an engine joined in the current session. Needs the lock.
ClientServerTransport_voiceBindingIsLive :: proc(transport: ^ClientServerTransport) -> bool {
	return(
		transport.voice.engine != nil &&
		transport.voice.sessionGeneration == transport.sessionGeneration &&
		transport.connection.status == .Established &&
		transport.transport.phase == .Established \
	)
}

@(private = "file")
voiceReceiveDropReasonForOpen :: proc(
	result: common.VoiceOpenResult,
) -> ClientVoiceReceiveDropReason {
	switch result {
	case .Ok, .Malformed:
		return .Malformed
	case .Replayed:
		return .Replayed
	case .TooOld:
		return .TooOld
	case .BadTag:
		return .BadTag
	case .Inactive:
		return .Inactive
	}
	return .Malformed
}

// Handles one channel 2 datagram of the established session, on the network worker with the
// lock held: open it with the session's voice receive state, decode the ServerVoiceFrame, and
// hand it to the bound engine, which copies the Opus bytes. Every drop is counted and none
// ends the session, because ENet does not authenticate datagrams. Allocates nothing.
ClientServerTransport_receiveVoiceDatagram :: proc(
	transport: ^ClientServerTransport,
	datagram: []u8,
) {
	stats := &transport.voiceStats
	stats.datagramsReceived += 1
	plaintext: [common.SERVER_VOICE_FRAME_MAX_SIZE]u8
	length, openResult := common.openVoiceDatagram(
		&transport.transport.voiceReceive,
		transport.transport.sessionID,
		datagram,
		plaintext[:],
	)
	if openResult != .Ok {
		stats.receiveDropped[voiceReceiveDropReasonForOpen(openResult)] += 1
		return
	}
	frame, decodeResult := common.decodeServerVoiceFrame(plaintext[:length])
	switch decodeResult {
	case .Ok:
	case .Truncated:
		stats.receiveDropped[.FrameTruncated] += 1
		return
	case .EmptyOpus:
		stats.receiveDropped[.FrameEmpty] += 1
		return
	case .OpusTooLarge:
		stats.receiveDropped[.FrameTooLarge] += 1
		return
	}
	if !ClientServerTransport_voiceBindingIsLive(transport) {
		stats.receiveDropped[.NotJoined] += 1
		return
	}
	if int(frame.roomId) != transport.voice.roomID {
		stats.receiveDropped[.WrongRoom] += 1
		return
	}
	if !VoiceEngine_pushInbound(
		transport.voice.engine,
		frame.senderUserId,
		frame.frameSequence,
		frame.flags,
		frame.opus,
	) {
		stats.receiveDropped[.EngineRefused] += 1
		return
	}
	stats.framesDelivered += 1
}

// Hands one sealed datagram to the network. Tests swap it (under
// voiceDatagramSendBridgeTestMutex) to capture datagrams without ENet.
VoiceDatagramSendBridge :: #type proc(transport: ^ClientServerTransport, datagram: []u8) -> bool

voiceDatagramSendBridge: VoiceDatagramSendBridge = ClientServerTransport_sendVoiceDatagram

// Sends a sealed datagram on channel 2, unsequenced: a late voice frame is worth nothing, so
// ENet must neither retransmit nor reorder it. Flushes at once rather than waiting up to a
// worker pass, since voice latency is the point. Needs the lock.
ClientServerTransport_sendVoiceDatagram :: proc(
	transport: ^ClientServerTransport,
	datagram: []u8,
) -> bool {
	if !ClientServerTransport_hasLiveENetSession(transport) || len(datagram) == 0 {
		return false
	}
	packet := ENet.packet_create(raw_data(datagram), uint(len(datagram)), {.UNSEQUENCED})
	if packet == nil {
		return false
	}
	if ENet.peer_send(transport.enetPeer, STARTUP_AUTH_CHANNEL_VOICE, packet) != 0 {
		ENet.packet_destroy(packet)
		return false
	}
	ENet.host_flush(transport.enetHost)
	return true
}

// Encodes, seals and sends one outbound frame for link, with the lock held. It sends only
// while transport.voice still names link's engine and room in the current session, so a frame
// captured just before a leave, a room switch or a reconnect is dropped instead of reaching a
// session that has not joined. A failure never touches the control channel or the session.
ClientServerTransport_sendVoiceFrame :: proc(
	transport: ^ClientServerTransport,
	link: ^ClientVoiceLink,
	frame: VoiceOutboundFrame,
) -> bool {
	stats := &transport.voiceStats
	if !ClientServerTransport_voiceBindingIsLive(transport) ||
	   transport.voice.engine != link.engine ||
	   transport.voice.roomID != link.roomID {
		stats.sendDropped[.NotJoined] += 1
		return false
	}
	plaintextLength, encodeOK := common.encodeClientVoiceFrame(
		common.ClientVoiceFrame {
			roomId = u32(link.roomID),
			frameSequence = frame.frameSequence,
			flags = frame.flags,
			opus = frame.opus,
		},
		link.plaintext[:],
	)
	if !encodeOK {
		stats.sendDropped[.EncodeFailed] += 1
		return false
	}
	sealedLength, sealOK := common.sealVoiceDatagram(
		&transport.transport.voiceSend,
		transport.transport.sessionID,
		link.plaintext[:plaintextLength],
		link.sealed[:],
	)
	if !sealOK {
		stats.sendDropped[.SealFailed] += 1
		return false
	}
	if !voiceDatagramSendBridge(transport, link.sealed[:sealedLength]) {
		stats.sendDropped[.SendFailed] += 1
		return false
	}
	stats.framesSent += 1
	return true
}

// The engine's onOutbound seam, on the voice thread. Sealing takes microseconds, so holding
// the worker mutex for it delays the worker by no more than that.
clientVoiceOutbound :: proc(userdata: rawptr, frame: VoiceOutboundFrame) {
	link := (^ClientVoiceLink)(userdata)
	ClientNetworkWorker_lock(link.worker)
	defer ClientNetworkWorker_unlock(link.worker)
	_ = ClientServerTransport_sendVoiceFrame(link.transport, link, frame)
}

// ── Voice control messages (CBOR, control channel) ─────────────────

VoiceControlRequestKind :: enum u8 {
	Join, // ClientJoinVoice{roomID, muted, deafened, rejoin, deviceID}
	Leave, // ClientLeaveVoice
	State, // ClientVoiceState{muted, deafened}
	// Protocol 21 (voice_e2ee.odin).
	Key, // ClientVoiceKey{roomID, epoch, voiceSessionID, generation, createdAt, envelope}
	RequestKey, // ClientRequestVoiceKey{roomID, senderID}
}

VoiceControlRequest :: struct {
	kind:     VoiceControlRequestKind,
	roomID:   int,
	muted:    bool,
	deafened: bool,
	// Join only (protocol 13): whether this is the automatic re-join after a reconnect, which
	// the server never lets take voice from another device, and the profile's device ID
	// (borrowed from State.config).
	rejoin:   bool,
	deviceID: string,
	// Key and RequestKey only (protocol 21). envelope is borrowed for the call.
	epoch:          int,
	voiceSessionID: common.VoiceSessionID,
	generation:     u32,
	createdAt:      i64,
	envelope:       []u8,
	senderID:       int,
}

VoiceControlSendBridge :: #type proc(
	transport: ^ClientServerTransport,
	request: VoiceControlRequest,
) -> bool

// Tests swap this (under voiceControlSendBridgeTestMutex) to observe requests without a
// live session.
voiceControlSendBridge: VoiceControlSendBridge = ClientServerTransport_sendVoiceControl

ClientServerTransport_sendVoiceControl :: proc(
	transport: ^ClientServerTransport,
	request: VoiceControlRequest,
) -> bool {
	switch request.kind {
	case .Join:
		return ClientServerTransport_sendEncryptedRuntimeMessage(
			transport,
			.ClientJoinVoice,
			common.ClientJoinVoicePayload {
				roomId = request.roomID,
				muted = request.muted,
				deafened = request.deafened,
				rejoin = request.rejoin,
				deviceId = request.deviceID,
			},
		)
	case .Leave:
		return ClientServerTransport_sendEncryptedRuntimeMessage(
			transport,
			.ClientLeaveVoice,
			common.ClientLeaveVoicePayload{},
		)
	case .State:
		return ClientServerTransport_sendEncryptedRuntimeMessage(
			transport,
			.ClientVoiceState,
			common.ClientVoiceStatePayload{muted = request.muted, deafened = request.deafened},
		)
	case .Key:
		return ClientServerTransport_sendEncryptedRuntimeMessage(
			transport,
			.ClientVoiceKey,
			common.ClientVoiceKeyPayload {
				roomId = request.roomID,
				epoch = request.epoch,
				voiceSessionId = request.voiceSessionID,
				generation = request.generation,
				createdAt = request.createdAt,
				envelope = request.envelope,
			},
		)
	case .RequestKey:
		return ClientServerTransport_sendEncryptedRuntimeMessage(
			transport,
			.ClientRequestVoiceKey,
			common.ClientRequestVoiceKeyPayload {
				roomId = request.roomID,
				senderId = request.senderID,
			},
		)
	}
	return false
}
