# HayChat Server Agents Documentation

## Build & Commands

- Typecheck: `odin check server`
- Test: `odin test server`
- Build: `odin build server`
- Run: `odin run server`

## Multi-Channel Server

- Room visibility, chat sends, live-message fanout, and history retrieval are membership-scoped. Never trust a client-provided room ID without checking membership through the database flow.
- Persist a room message before fanout. Fan out the durable message fields, including its ID and timestamp, only to the room's current members.
- Router database work follows the typed request/continuation pattern in `MainRouterState`: queue a `common.DatabaseQuery`, record the matching pending request type, and handle its result in the exhaustive database-result switch. Keep request/response allocation cleanup in `ipc.odin` in sync with new payload fields.
- Admin room create/edit/delete and membership mutations require the database-backed server-admin role. Room creators are automatically added as members; membership and deletion changes must notify affected users so their clients refresh the authoritative room list.
- For deterministic router/database validation, use `odin test server -define:ODIN_TEST_THREADS=1`. Database-backed runtime tests require a bootstrap role with `USAGE, CREATE` on schema `public`.

## MVP Workflow

- Load the supported local env with `cp ./.env.example ./.env && source ./.env >/dev/null 2>&1`.
- Before using `./run-test-server.sh bootstrap-start-background`, ensure local PostgreSQL is already available or matching `HAYCHAT_DATABASE_*` overrides are set. If you reuse an existing HayChat database instead of provisioning a fresh one, the configured role must own that database or have `USAGE, CREATE` on schema `public` before running the helper bootstrap.
- Start the supported server helper seam with `./run-test-server.sh bootstrap-start-background` as the primary MVP start path.
- Supported helper commands are exactly: `bootstrap`, `start`, `start-background`, `wait-ready [timeout_secs]`, `stop`, `bootstrap-start`, `bootstrap-start-background`, and `hc118-gate`.
- Helper ownership stops at the server lifecycle. Launch clients manually with `odin run client` in separate terminals.
- Use `./run-test-server.sh stop` to stop the helper-managed background server.
- Keep `odin run server` for direct server-focused work when you intentionally are not using the helper seam.
