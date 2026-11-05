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
- For deterministic router/database validation, use `odin test server -define:ODIN_TEST_THREADS=1`. Database-backed runtime tests require a role that can create, alter, and drop the server-owned schema in `public`.

## Dev Workflow

- `./dev.sh up` starts the dev pod: PostgreSQL 17 and a server built from the working tree. `./dev.sh restart` rebuilds and restarts the server; a compile error leaves the running one up.
- The server creates and validates its schema before it accepts traffic, so the database role must be able to create, alter, and drop objects in `public`. The dev pod's role owns its database.
- `./dev.sh logs [-f]` shows server output, `./dev.sh admin PATH` calls web admin routes from inside the pod (the web admin binds `127.0.0.1` only), `./dev.sh seed` loads `server/sql/auth_bootstrap.sql`, and `./dev.sh psql` opens the dev database.
- Server settings for the pod go in `.env` (see `.env.example`). `./dev.sh` owns the database, listen, and path keys and ignores them there.
- The web admin's `core:nbio` event loop needs io_uring. `./dev.sh` runs server containers with an io_uring-enabled seccomp profile and without SELinux confinement; a plain `podman run` of the server fails `nbio.acquire_thread_event_loop`.
- `./dev.sh live` is the end-to-end proof: `dev/live-proof.sh` builds the server, starts it against a throwaway database, loads `server/sql/auth_bootstrap.sql` for `#general`, and runs the live client tests. `--all` (what CI runs) includes the two-client room chat proof.
