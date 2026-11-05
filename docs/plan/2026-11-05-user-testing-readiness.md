# HayChat: user-testing readiness plan (2026-11-05)

Goal: get HayChat to a state where real people can test it. Text rooms and direct messages
must work end to end. Voice rooms are a stretch goal. Everything is orchestrated by one lead
agent; each work package below runs as a separate agent in its own git worktree and lands as
its own pull request on the Forgejo repo `jim/haychat` (https://git.spyingwind.com/jim/haychat).

Read this whole file before starting any work package. It is the only shared context.

## Repository orientation (as of main @ 60ea446)

- Odin project. `AGENTS.md` at the repo root is authoritative for style, ownership rules and
  commands; `client/AGENTS.md` and `server/AGENTS.md` add component rules. Read all three.
- `common/protocol.odin`: wire types shared by client and server. `MessageType` is an enum with
  automatic numbering after `Ping = 10`; `protocolVersion` is 5. Changing any payload or enum
  requires rebuilding both sides, and bumping `protocolVersion`.
- `server/main.odin`: the router. Pattern: a client packet handler validates and enqueues a
  typed database request (`common.DatabaseQueryRequest` union) with a `PendingDBRequest`
  continuation; `MainRouterState_handleDatabaseResult` switches on `request.requestType` and
  sends replies. Request/result unions are exhaustive; cleanup switches live in `server/ipc.odin`.
- `server/database.odin`: libpq via `shared:pg`. Schema is created/validated at startup
  (`DATABASE_SCHEMA_CREATE_SQL`, `DATABASE_SCHEMA_VALIDATION_SQL`); an incompatible schema is
  dropped and rebuilt. Prefer one SQL statement per client action when correctness depends on a
  check (see `DATABASE_POST_ROOM_CHAT_MESSAGE_SQL`).
- `client/`: SDL3 immediate-mode GUI. `app.odin` is the SDL loop; `main.odin` holds `State`,
  `init`, startup auth; `actions.odin` mutates `State`; `view.odin` draws from `State` and calls
  actions; `view_model.odin` builds pure snapshots for drawing; `transport.odin` is the
  encrypted ENet transport and runtime-event decoding; `network_worker.odin` services ENet on a
  background thread and queues `ClientTransportRuntimeEvent`s that the UI drains each frame.
  `client/ui` is a generic widget toolkit that must not import HayChat types.
- Tests: `*_test.odin`, `core:testing`, leak-checked (`ODIN_TEST_FAIL_ON_BAD_MEMORY`). Live
  tests gate on `HAYCHAT_LIVE_STARTUP_AUTH=1` and connect to `127.0.0.1:12345`.
- Dev environment is podman via `./dev.sh` (`./dev.sh help`). The host `odin` is newer than the
  pin and cannot build the server; it can `odin check client`. Use the container for anything
  authoritative.

## Current behaviour that matters

- Auth: a client connects with a nickname (`Config.display_name`) and an Ed25519 key. The server
  binds a nickname to the first key that uses it. A second device or a second person using the
  same nickname gets `ServerAuthFailure "user identity is unavailable"`.
- Rooms are membership scoped. New accounts are members of nothing. The seed fixture
  (`server/sql/auth_bootstrap.sql`) creates `general` (room ID 1, `common.GENERAL_ROOM_ID`) with
  only `admin` as member. Only admins (`user_server_roles` role `admin`) can create/edit/delete
  rooms and add/remove members, and the client has no UI for any of that.
- Chat payloads carry `senderId` only; the client renders "User 3".
- Direct messages: `ClientDirectMessage`/`ServerDirectMessage` exist in the enum only. No
  payloads, no server handling, no table, no client transport. The client's DM screen shows a
  fake friends list from `Config.friends`; `State_addFriend` appends "New Friend".
- Startup auth runs synchronously in `init` before the window appears, with 1 s timeouts, and a
  failure is only printed to stdout. A `.Disconnected` runtime event is ignored; there is no
  reconnect. There is no UI to set a display name or add a server; the default config points at
  `localhost:12345` with name "Test User".
- `./dev.sh live --all` fails on the two-client chat proof because the second user is not a
  member of `general`, and because that test expects the first event to be a chat message while
  the room list arrives first.

## Work packages

Each package: branch from current `main`, keep the PR focused, run `./dev.sh check` (and
`./dev.sh live` where relevant) before pushing, write tests, update docs (README, AGENTS.md
files, `.env.example`) for anything user- or agent-visible. Commit messages: imperative subject,
body explaining why, and end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
Do not touch the shared dev pod (`./dev.sh up/down/reset/restart/seed/client`): the lead owns
it. `./dev.sh check`, `./dev.sh live`, `./dev.sh ci` and `./dev.sh shell` use throwaway
containers and are safe to run concurrently with other agents.

### A. Server: everyone can chat (small, first)

1. New accounts join every existing room, and newly created rooms include every user.
   Keep `room_members` as the authoritative table (private rooms can come later). Do it in SQL:
   extend `DATABASE_RESOLVE_USER_IDENTITY_SQL` so the identity upsert and the membership insert
   are one statement (CTE), and extend the create-room statement to insert all users. Add
   `ServerRoomMembershipChanged` fan-out to connected users when a room is created so their room
   lists refresh (the router already does this for the creator).
2. Nicknames on the wire: add `senderNickname: string` to `common.StoredChatMessage` and
   `common.ServerChatMessagePayload`, filled by joining `users` in the post and history SQL.
   Client: `view_model.odin` shows the nickname instead of "User N" (keep "You" for self).
   Update ownership/cleanup for the new owned string everywhere a message is cloned or freed
   (client `RoomCache_mergeMessage`, `RoomCache_deinit`, `ClientTransportRuntimeEvent_deinit`,
   server IPC cleanup).
3. Bump `protocolVersion` to 6. Add a `common` test that pins the numeric value of every
   `MessageType` member currently in use on the wire (so accidental renumbering fails a test).
4. Fix `testClientServerTransportCanSendLiveRoomChatBetweenTwoAuthenticatedClients` to skip
   non-chat events, make `dev/live-proof.sh --all` pass, and switch CI and `./dev.sh ci` to
   run `--all`.
5. Docs: README "Known Limitations" loses the first bullet; describe the open-rooms model.
6. Also add this plan as `docs/plan/2026-11-05-user-testing-readiness.md` (copy this file).

### B. Direct messages end to end (large, after A merges)

Protocol (bump `protocolVersion` to 7):
- `ClientDirectMessagePayload{recipientUserId: int, content: string}`
- `ServerDirectMessagePayload{id, senderId, senderNickname, recipientId, recipientNickname,
  timestamp: string, content}` sent to every live session of both users.
- `ClientFetchDirectHistoryPayload{peerUserId, beforeMessageID, limit}` and
  `ServerDirectHistoryPayload{peerUserId, messages: [dynamic]StoredDirectMessage, hasOlder}`,
  cursor paginated exactly like room history.
- `ClientListUsers` / `ServerUserList{users: [dynamic]UserSummary{id, nickname, isOnline}}`:
  every account on the server, online flag from live sessions. Reuse the existing
  `ClientUserList`/`ServerUserList` enum members.
- `ClientListDirectConversations` / `ServerDirectConversations{conversations:
  [dynamic]DirectConversationSummary{peerUserId, peerNickname, lastMessageID, lastTimestamp,
  lastContent}}` ordered by most recent.
- `ServerUserPresence{userId, nickname, isOnline}` broadcast to all authenticated sessions when a
  user's first session authenticates or last session disconnects.
Database: `direct_messages(id identity, sender_user_id, recipient_user_id, content, created_at)`
with indexes on `(sender_user_id, recipient_user_id, id)` and the reverse; schema validation
updated. Post must verify the recipient exists in one statement.
Server router: handlers, pending request types, result handling, fan-out to both users.
Client: transport encode/decode into new runtime event kinds; `State` gets per-server DM
caches keyed by `(serverID, peerUserID)` with drafts, history paging, and a user directory;
replace the fake friends list. UI: inside the selected server's sidebar, a "Direct Messages"
section (recent conversations) and a "Members" section (all users, online first); clicking a
user opens the DM transcript in the main pane with a composer. Keep the rail "DM" button only
if it can list recent conversations across all servers cheaply; otherwise remove it and
`State_addFriend`. Delete `Config.friends` only if nothing else uses it.
Tests: router tests for post/history/list, client action tests for cache isolation and paging,
and a live two-client DM proof added to `dev/live-proof.sh --all`.

### C. Client: connection lifecycle and first run (large, parallel with A)

1. Non-blocking connect. Move the handshake onto the network worker: `ClientServerTransport`
   gains a connect state machine (`Connecting`, `Handshaking`, `Established`, `Failed`,
   `Disconnected`) driven from `ClientServerTransport_serviceRuntime`; the existing
   `handleIncomingPacket` already handles `ServerHello`/`ServerAuthChallenge`/`ServerAuthSuccess`.
   New runtime events: `Connected{userID}`, `ConnectFailed{message}`, plus the existing
   `Disconnected`. The window opens immediately. `State` requests the room list on `Connected`.
2. Reconnect with backoff (1, 2, 4, ... capped at 30 s) after `Disconnected` or a failed
   connect, with a manual "Retry now" action. Auth failures that will not fix themselves
   (nickname taken, server key changed, protocol version mismatch) stop retrying and show why.
3. Visible connection status per server in the UI (header or sidebar banner): Connecting,
   Connected as <name>, Reconnecting in N s, Failed: <reason>.
4. Human-readable failures. Map `"user identity is unavailable"` to "The name <name> is already
   in use on this server (or bound to another device). Choose another name." Server key change
   (`PeerTrustState.Changed`) must be explained with an explicit "Trust the new key" action
   that updates the pin.
5. First-run and settings screen: when the config has no display name or no servers, show a
   screen with Display name, Server host, Port, Connect. A settings button on the rail opens the
   same screen later to change the name or add/remove servers. Persist with `saveConfig`.
   Remove the hard-coded "Test User"/"Test Server" injection from `State_initFromConfig` for
   the GUI path, but keep a way for tests to get a default config.
6. Keep every existing client test passing or rewrite it deliberately; keep the live proofs in
   `dev/live-proof.sh` working (they use `startupAuthBridge`; adapt them to the new flow).
Avoid editing `common/protocol.odin` and `server/` in this package; A owns protocol changes.
Expect to add a new file for the connect/settings screen rather than growing `view.odin`.

### D. Headless client harness for agents (medium, parallel with A and C)

Purpose: let an agent (or a script) act as a user without a display. Build it into the client
binary so it reuses `State`, actions, transport and the network worker.
- `client --headless [--name NAME] [--server HOST:PORT] [--config-dir DIR]`. Without SDL
  initialisation. `--config-dir` (or `XDG_CONFIG_HOME`) isolates identities so several headless
  clients run side by side on one machine. `--name`/`--server` override and persist to that
  profile's config.
- Reads one command per line from stdin; writes one JSON object per line to stdout, both for
  command results and for every runtime event (`{"event":"room_chat", ...}`,
  `{"event":"connected", ...}`, `{"event":"error", ...}`). Commands at minimum: `status`,
  `rooms`, `history ROOM_ID [BEFORE_ID]`, `send ROOM_ID TEXT...`, `wait EVENT_KIND [TIMEOUT_MS]`,
  `sleep MS`, `quit`. Design the command table so DM commands (`users`, `dm USER_ID TEXT`,
  `dm-history USER_ID`) can be added by package B with a few lines.
- stdin reading must not block the network/event loop (reader thread + queue).
- Exit code 0 on `quit` or EOF, non-zero on connect failure or internal error.
- Add `dev/harness-smoke.sh`: builds the client in the container, starts two headless clients
  against the live-proof server, has A send in room 1 and asserts B receives it. Wire it as
  `dev/live-proof.sh --harness` (and into `--all`). Until package A merges, B is not a member of
  room 1, so make the smoke script's two-client assertion runnable but expected to fail; verify
  the single-client path (connect, status, rooms) passes now.
- Document in `docs/testing-harness.md` and reference it from `AGENTS.md` so future agents find it.
Keep the SDL loop in `app.odin` untouched except for a small branch in `main` on `--headless`;
put the harness in a new file (e.g. `client/headless.odin`).

### E. Voice rooms: design only (research, parallel)

Produce `docs/plan/voice-rooms-design.md`, no code. Cover: audio I/O via SDL3's audio subsystem
(already linked; PipeWire backend on Linux, WASAPI on Windows) versus `vendor:miniaudio`;
Opus via a small Odin FFI binding to libopus (dev image needs `opus-devel`; check Windows
distribution); packetisation (20 ms frames, 48 kHz mono); ENet unreliable/unsequenced channel
`Voice` and the replay-protection change the transport needs for out-of-order packets
(per-channel sequence window instead of one strict counter; see `common/auth.odin`); server
fan-out to voice participants (`ClientJoinVoice`/`ClientLeaveVoice`, speaking state); client UI
(join/leave, mute, speaking indicators); jitter buffer; and a test plan using PipeWire null
sinks/sources and `pw-cat`/`sox`/`ffmpeg`-generated tones so the headless harness can inject
a tone on one client and verify frequency on another. Estimate work in PR-sized steps.

### Later waves (lead decides after A–D land)

- F. Admin room management in the client (create room, rename, delete; add/remove member).
- G. Deployment: a production server container image and compose/quadlet file, release builds
  of the Linux client, Windows client build instructions, and a tester guide.
- H. Voice implementation per E.
- Schema migrations (`schema_version` table) before testers have data worth keeping.

## Acceptance for "ready for testers"

1. Two fresh clients on two machines connect to one server with distinct names, see `general`
   and every other room, and exchange messages with nicknames shown.
2. Either user opens a DM with the other from the member list and both see the conversation,
   including after restarting the client (history loads).
3. Restarting the server reconnects both clients without user action.
4. A wrong server address, a taken nickname, and a changed server key each show a clear message.
5. `./dev.sh ci` passes, including the two-client room and DM proofs and the harness smoke test.

## Status (2026-11-05, end of day)

Every package above landed on `main` the same day, each as its own reviewed PR on Forgejo:

| PR | Package | What landed |
| --- | --- | --- |
| #2 | A | Open rooms (every account is in every room), sender nicknames on the wire, protocol 6, `MessageType` value pin test, `live --all` in CI |
| #3 | D | `client --headless`: JSON-over-stdio harness for agents, `dev/harness-smoke.sh` |
| #4 | E | `docs/plan/voice-rooms-design.md` |
| #5 | C | Background connect with reconnect and backoff, connection status, readable failures, first-run and Settings screens |
| #6 | B1 | Direct messages, user directory and presence on the server, protocol 7 |
| #7 | A2 | The server creates `#general` on first start |
| #8 | H0 | Network loop drains IPC in full, ring-buffer IPC queues, thread pool removed |
| #9 | B2 | Direct messages in the client sidebar and pane, harness `users`/`dm`/`dm-history` |
| #10 | G | `deploy/Containerfile`, quadlet units, release workflow (Linux and Windows clients), `docs/tester-guide.md` |
| #11 | A3 | Changing the display name renames the same account; startup failures exit 1 |
| #12 | D2 | `client --ui-script`: scripted clicks, typing and screenshots of the real window; offscreen GUI proof in CI |

Acceptance (see above) was checked against the dev server with the headless harness and the
GUI: two fresh users chat in `#general` with nicknames, exchange direct messages and see the
history after a restart, reconnect without user action after a server restart, and get clear
messages for a wrong address, a taken name and a changed server key. `./dev.sh ci` is green.

Still open: F (admin room management in the client), the voice steps H1–H8, schema migrations
before testers have data worth keeping, server-side read state for DM unread counts, and the
`IPC__route_to` bug noted in #8.
