# HayChat Client Agents Documentation

## Build & Commands

- Typecheck: `odin check client`
- Test: `odin test client`
- Build: `odin build client`
- Run: `odin run client`

## Multi-Channel Client

- `State` owns room data in server-scoped caches. Cache identity is `(serverID, roomID)` because room IDs can overlap between configured servers. Do not reintroduce a global room transcript or global channel draft as the source of truth.
- Keep every loaded history page and live message in its room cache. A live message for an inactive room or inactive server must update only that cache; render updates are limited to the selected server and selected room.
- Drafts are client-local and belong to their room cache. Switching rooms restores that room's draft without sending or persisting it.
- `transport.odin` owns encrypted runtime packet construction and decoded runtime-event cleanup. Event conversion in `main.odin` transfers dynamic payload ownership into `Msg`; clear transferred fields before the runtime event is deinitialized.
- `network_worker.odin` services every live server session on a background thread and queues decoded runtime events; `view` only drains that queue (`State_drainNetworkEvents`). Any UI-thread code that sends through a transport or reads its mutable fields (`lastError`, crypto state) must hold `ClientNetworkWorker_lock`. Startup auth runs in `init` before the worker starts.
- Room discovery starts after authenticated startup has adopted a live ENet session. Test startup bridges may establish transport state without a live ENet session, so do not make discovery failure invalidate authentication.
- Build sidebar rooms from the selected server's joined-room list. The chat view derives its transcript from structured cached messages and only shows pagination when `hasOlder` is true.
- Add reducer tests for cache isolation, history page merge/de-duplication, and selected-room removal fallback whenever channel behavior changes.

## MVP Workflow

- Load the supported local env with `cp ./.env.example ./.env && source ./.env >/dev/null 2>&1`.
- Before using `./run-test-server.sh bootstrap-start-background`, ensure local PostgreSQL is already available or matching `HAYCHAT_DATABASE_*` overrides are set. If you reuse an existing HayChat database instead of provisioning a fresh one, the configured role must own that database or have `USAGE, CREATE` on schema `public` before running the helper bootstrap.
- Start the supported server helper seam with `./run-test-server.sh bootstrap-start-background` as the primary MVP start path.
- Supported helper commands are exactly: `bootstrap`, `start`, `start-background`, `wait-ready [timeout_secs]`, `stop`, `bootstrap-start`, `bootstrap-start-background`, and `hc118-gate`.
- Helper ownership stops at the server lifecycle. Launch clients manually with `odin run client` in separate terminals.
- Stop the helper-managed server with `./run-test-server.sh stop`.
