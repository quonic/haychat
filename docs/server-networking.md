# Server Network Architecture

The server is one OS process. Its "processes" are threads that talk through in-memory IPC
queues (`server/ipc.odin`).

```text
clients ◄─ENet/UDP─► network thread ◄─IPC─► main thread ◄─IPC─► database thread
                     networkServerLoop        mainLoop           databaseServerLoop
                     PeerManager              router, crypto
                     ENet host                supervisor, [Status] log
```

- network → main: `NetworkPeerConnected`, `NetworkDataReceived`, `NetworkPeerDisconnected`.
- main → network: `NetworkSendData`, `NetworkBroadcast`, `NetworkDisconnectPeer`, the voice
  commands `NetworkVoiceSessionOpen`, `NetworkVoiceRoute` and `NetworkVoiceReset`, and the
  `ProcessShutdown` / `ProcessRestart` signals.
- main ↔ database: `DatabaseQuery` / `DatabaseQueryResult`.
- database listener → main (#116): `DatabaseChangeNotification` (a channel and the IDs it
  reported in one pass) and `DatabaseChangeListening` (connected and listening, so the router
  reads each channel's state again). The listener is a thread the database thread starts once
  it is ready and stops before it returns, with a PostgreSQL connection of its own that
  `LISTEN`s, so waiting for notifications or reconnecting never delays a query
  (`server/database_notifications.odin`).

The listen port is `HAYCHAT_LISTEN_PORT` (default `12345`, `common.DEFAULT_SERVER_PORT`).

## IPC queues

- Each endpoint (main, network, database) has one FIFO queue, an `IPC_Ring`: a
  growable ring buffer behind the global `ipcState.state_mutex`. Push and pop are O(1). The
  ring never drops messages; it doubles when full.
- `IPC_Client_poll` pops one message without blocking. `IPC_Client_wait(fd, timeout)` sleeps
  on the queue's condition variable until a push or the timeout, so idle consumers do not
  spin. The main loop waits up to 5 ms and the database thread up to 100 ms.
- Payloads (`data`, strings, arrays) are owned allocations that move with the message. The
  consumer frees them; `IPC__message_deinit` frees any message type, and `IPC__state_deinit`
  frees whatever is still queued.

## Network loop

Each pass of `networkServerLoop`:

1. `networkDrainIPC` pops every queued message for the network endpoint, up to
   `NETWORK_IPC_DRAIN_LIMIT` (1024), and queues the sends in ENet. It stops at
   `ProcessShutdown` or `ProcessRestart` and leaves later messages queued.
2. `host_flush` once if anything was queued, instead of once per packet.
3. `networkServiceENet` handles every ready ENet event, up to `NETWORK_ENET_EVENT_LIMIT`
   (1024). Only the first `host_service` call waits: 2 ms
   (`NETWORK_SERVICE_TIMEOUT_MS`), or 0 when the IPC pass hit its limit.

ENet cannot wait on its socket and the IPC queue at once, so an outbound message waits at
most about 2 ms for the network thread to see it. Before this design the loop popped one IPC
message per `host_service(…, 100)` call, so outbound traffic drained at one message per
inbound event plus ten per second and fan-out queued without bound.

Received control packets (channel 1) are copied into `NetworkDataReceived` and go straight to
the router; the network thread does not decrypt or parse them. The router owns their
transport state.

`NetworkSendData` and `NetworkBroadcast` carry `unreliable` (default `false`): reliable sends
use `ENet.PacketFlag.RELIABLE`, unreliable ones use no flag (sequenced, may drop). Nothing sends
unreliable packets through them; voice goes through the relay below.

## Voice channel (ENet channel 2)

Voice datagrams never leave the network thread. `networkServerLoop` owns a `VoiceRelay`
(`server/voice_relay.odin`) with each authenticated peer's voice send and receive state and the
recipient list of every voice room:

```text
client ─ch2─► handlePeerData ─► VoiceRelay_handleDatagram ─► peer_send(ch2, UNSEQUENCED) × N-1
                                  │                                      ▲
router ─NetworkVoiceSessionOpen──►┤ (keys, once, at auth success)        │ one host_flush
       ─NetworkVoiceRoute────────►┤ (full room recipient set per change)  │ per loop pass
       ─NetworkVoiceReset────────►┘ (network service stop)
```

Per datagram, in order, each failure counted by reason and none of them disconnecting the peer:

1. Unknown peer (no voice session) or not in a room: drop.
2. Token bucket: `HAYCHAT_VOICE_MAX_PACKETS_PER_SECOND`, burst a third of it. Before any AEAD
   work, so a flood costs little.
3. `openVoiceDatagram`: malformed, replayed, too old, bad tag, inactive.
4. `decodeClientVoiceFrame`; then wrong room ID, muted sender, Opus payload over
   `HAYCHAT_VOICE_MAX_FRAME_BYTES`, or a TOC byte that is not exactly 20 ms
   (`opusPacketIsVoiceFrameDuration`; the server needs no libopus). In an encrypted room
   (protocol 21) the payload is sealed end to end: the relay drops one that is not a version 1
   sealed payload with at least one Opus byte (`NotSealed`), applies the size limit to the
   payload minus its 18 bytes of overhead, and skips the TOC check, which it cannot read.
5. `encodeServerVoiceFrame` in place with the sender's user ID, then for every other room
   member that is not deafened: `sealVoiceDatagram` with that member's send state and
   `ENet.peer_send` on channel 2 with `UNSEQUENCED`, so a late frame still reaches the jitter
   buffer. The sender never gets its own frame back.

The relay uses fixed scratch buffers, so a frame costs no allocation of its own (ENet copies each
packet). It logs nothing per packet. A disconnect (`handlePeerDisconnect`, or a router-commanded
`NetworkDisconnectPeer`) removes the peer from the relay at once and wipes its keys, before the
router hears about it. A router-commanded disconnect uses `peer_disconnect_later`, so the
router's last packets to the peer (a `ServerAuthFailure`, a protocol error, or
`ServerSessionEnded` for a kick or ban) are delivered first; the peer leaves the peer manager,
and the router gets `NetworkPeerDisconnected`, when ENet reports the disconnect. A
`NetworkVoiceSessionOpen` for a peer that already disconnected is dropped and wiped. The
counters are published with atomic stores (`voiceRelayPublishedStats`) for the main thread's
periodic `[Status]` log line (`server/status.odin`).

## Logging

Per-packet lines (each send, broadcast, and receive) print only with
`HAYCHAT_LOG_LEVEL=debug`. Connects, disconnects, and errors always print.

## Configuration

`HAYCHAT_MAX_NETWORK_THREADS` (default `4`) no longer starts threads: the worker pool it sized
only logged packets and spun on `thread.yield()`, so it was removed. The key still sets the
ENet peer capacity, 16 peers per unit (64 by default).
