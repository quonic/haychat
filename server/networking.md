# Server Network Architecture

The server is one OS process. Its "processes" are threads that talk through in-memory IPC
queues (`server/ipc.odin`).

```text
clients ◄─ENet/UDP─► network thread ◄─IPC─► main thread ◄─IPC─► database thread
                     networkServerLoop        mainLoop           databaseServerLoop
                     PeerManager              router, crypto
                     ENet host                supervisor ◄─IPC─► web admin thread
```

- network → main: `NetworkPeerConnected`, `NetworkDataReceived`, `NetworkPeerDisconnected`.
- main → network: `NetworkSendData`, `NetworkBroadcast`, `NetworkDisconnectPeer`, and the
  `ProcessShutdown` / `ProcessRestart` signals.
- main ↔ database: `DatabaseQuery` / `DatabaseQueryResult`; main ↔ web admin: `Admin*`.

The listen port is `HAYCHAT_LISTEN_PORT` (default `12345`, `common.DEFAULT_SERVER_PORT`).

## IPC queues

- Each endpoint (main, network, database, web admin) has one FIFO queue, an `IPC_Ring`: a
  growable ring buffer behind the global `ipcState.state_mutex`. Push and pop are O(1). The
  ring never drops messages; it doubles when full.
- `IPC_Client_poll` pops one message without blocking. `IPC_Client_wait(fd, timeout)` sleeps
  on the queue's condition variable until a push or the timeout, so idle consumers do not
  spin. The main loop waits up to 5 ms, the database thread up to 100 ms, and web admin
  handlers until their request timeout.
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

Received packets are copied into `NetworkDataReceived` and go straight to the router; the
network thread does not decrypt or parse them. The router owns per-peer transport state.

`NetworkSendData` and `NetworkBroadcast` carry `unreliable` (default `false`): reliable sends
use `ENet.PacketFlag.RELIABLE`, unreliable ones use no flag (sequenced, may drop). Nothing sends
unreliable packets yet; voice will.

## Logging

Per-packet lines (each send, broadcast, and receive) print only with
`HAYCHAT_LOG_LEVEL=debug`. Connects, disconnects, and errors always print.

## Configuration

`HAYCHAT_MAX_NETWORK_THREADS` (default `4`) no longer starts threads: the worker pool it sized
only logged packets and spun on `thread.yield()`, so it was removed. The key still sets the
ENet peer capacity, 16 peers per unit (64 by default).
