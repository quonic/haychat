# HayChat Server Agents Documentation

## Build & Commands

- Typecheck: `odin check server`
- Test: `odin test server`
- Build: `odin build server`
- Run: `odin run server`

## Multi-Channel Server

- Room visibility, chat sends, live-message fanout, and history retrieval are membership-scoped. Never trust a client-provided room ID without checking membership through the database flow.
- Persist a room message before fanout. Fan out the durable message fields, including its ID and timestamp, only to the room's current members.
- Router database work follows the typed request/continuation pattern in `MainRouterState`: queue a `common.DatabaseQuery`, record the matching pending request type, and handle its result in the exhaustive database-result switch. `common.DatabaseQueryRequest` and `common.DatabaseQueryResult` are tagged unions; the cleanup switches in `ipc.odin` are exhaustive, so a new variant will not compile until its cleanup is written.
- Prefer one SQL statement per client action when correctness depends on a check, as `PostRoomChatMessage` (membership check, insert, and recipients) and room history (membership check and page) do. Separate round trips let state change between the check and the action.
- Rooms are open: `DATABASE_RESOLVE_USER_IDENTITY_SQL` joins a newly created account to every room in the same statement as the identity upsert, and `DATABASE_CREATE_ROOM_SQL` adds every account to a new room. Keep membership in `room_members` and keep checking it, because private rooms will narrow it later.
- Admin room create/edit/delete and membership mutations require the database-backed server-admin role. Room creation notifies every authenticated session with `ServerRoomMembershipChanged`; membership and deletion changes must notify affected users so their clients refresh the authoritative room list.
- Chat messages carry `senderNickname`, joined from `users` by the post and history statements. It is an owned string like the other `StoredChatMessage` fields; free it in `IPC__stored_chat_message_deinit`.
- Direct messages (`router_direct_messages.odin`, `database_direct_messages.odin`) are between two accounts on this server, never to oneself. The router refuses a self-addressed message before the database, and `DATABASE_POST_DIRECT_MESSAGE_SQL` checks that the recipient exists and is not the sender in the same statement as the insert. Persist before fanout, then send `ServerDirectMessage` to every authenticated session of the sender and of the recipient and to no one else; the sending session gets the echo too, which is how clients learn the stored ID and timestamp. `StoredDirectMessage` owns its two nicknames, timestamp, and content; free them in `IPC__stored_direct_message_deinit`.
- Presence is derived, not stored: a user is online while one of their sessions in `peerSessions` is authenticated. Send `ServerUserPresence` when that count goes from zero to one (auth success, to every other authenticated session) and from one to zero (`MainRouterState_handlePeerDisconnected`, or `MainRouterState_protocolViolation`, which de-authenticates a session before its disconnect event arrives). Any new path that ends or de-authenticates a session must call `MainRouterState_noteSessionEnded`. `ServerUserList` online flags come from the same sessions, never from the database.
- Router tests that authenticate two different user IDs must consume the presence notice the second one causes: client transports accept only the next sequence number, so a skipped packet breaks every later open for that session.
- `server/database_direct_messages_test.odin` runs the direct message SQL against a real PostgreSQL when `HAYCHAT_DATABASE_SQL_TEST=1`; it writes and then deletes its own accounts, so point it only at a throwaway database. `./dev.sh live --sql` (and `--all`) runs it.
- For deterministic router/database validation, use `odin test server -define:ODIN_TEST_THREADS=1`. Database-backed runtime tests require a role that can create, alter, and drop the server-owned schema in `public`.

## Network Thread And IPC

- `server/networking.md` describes the threads, the IPC queues, and the network loop.
- The network loop drains every queued IPC message (up to `NETWORK_IPC_DRAIN_LIMIT`) before it services ENet, flushes once per pass, and waits at most `NETWORK_SERVICE_TIMEOUT_MS` (2 ms) in `host_service`. Do not add per-send `host_flush` calls or longer service timeouts: fan-out depends on the drain keeping up.
- `networkDrainIPC` takes the IPC fd and a `NetworkIPCHandlers` callback set, so tests drive it through the real queue without ENet (`network_throughput_test.odin`). Handlers borrow `msg.data`; the drain frees it.
- IPC queues are `IPC_Ring` ring buffers. A consumer that finds its queue empty calls `IPC_Client_wait` with a timeout instead of `thread.yield()` or a fixed sleep; every push signals the destination's condition variable.
- Per-packet logging goes behind `serverLogLevelIsDebug(config.logLevel)` (`HAYCHAT_LOG_LEVEL=debug`). Never log every packet at the default level.
- `NetworkSendData.unreliable` and `NetworkBroadcast.unreliable` default to `false`, which is reliable delivery. Only real-time media should set it.
- There is no network worker pool. Do work that must happen on the network thread in the loop itself, or design a pool that parks on a condition variable.

## Dev Workflow

- `./dev.sh up` starts the dev pod: PostgreSQL 17 and a server built from the working tree. `./dev.sh restart` rebuilds and restarts the server; a compile error leaves the running one up.
- The server creates and validates its schema before it accepts traffic, so the database role must be able to create, alter, and drop objects in `public`. The dev pod's role owns its database.
- `./dev.sh logs [-f]` shows server output, `./dev.sh admin PATH` calls web admin routes from inside the pod (the web admin binds `127.0.0.1` only), `./dev.sh seed` loads `server/sql/auth_bootstrap.sql`, and `./dev.sh psql` opens the dev database.
- Server settings for the pod go in `.env` (see `.env.example`). `./dev.sh` owns the database, listen, and path keys and ignores them there.
- The web admin's `core:nbio` event loop needs io_uring. `./dev.sh` runs server containers with an io_uring-enabled seccomp profile and without SELinux confinement; a plain `podman run` of the server fails `nbio.acquire_thread_event_loop`.
- `./dev.sh live` is the end-to-end proof: `dev/live-proof.sh` builds the server, starts it against a throwaway database, loads `server/sql/auth_bootstrap.sql` for `#general`, and runs the live client tests. `--all` (what CI runs) includes the two-client room chat proof, the harness smoke test, and the server SQL proof.
