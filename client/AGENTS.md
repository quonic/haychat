# HayChat Client Agents Documentation

## Build & Commands

- Typecheck: `odin check client`
- Test: `odin test client`
- Build: `odin build client`
- Run: `odin run client`

## MVP Workflow

- Load the supported local env with `cp ./.env.example ./.env && source ./.env >/dev/null 2>&1`.
- Before using `./run-test-server.sh bootstrap-start-background`, ensure local PostgreSQL is already available or matching `HAYCHAT_DATABASE_*` overrides are set. If you reuse an existing HayChat database instead of provisioning a fresh one, the configured role must own that database or have `USAGE, CREATE` on schema `public` before running the helper bootstrap.
- Start the supported server helper seam with `./run-test-server.sh bootstrap-start-background` as the primary MVP start path.
- Supported helper commands are exactly: `bootstrap`, `start`, `start-background`, `wait-ready [timeout_secs]`, `stop`, `bootstrap-start`, `bootstrap-start-background`, and `hc118-gate`.
- Helper ownership stops at the server lifecycle. Launch clients manually with `odin run client` in separate terminals.
- Stop the helper-managed server with `./run-test-server.sh stop`.
