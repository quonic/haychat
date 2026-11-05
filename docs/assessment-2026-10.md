# HayChat Codebase Assessment — October 2026

**Date:** 2026-10-07
**Branch:** `assessment-fixes` (five commits on top of `main`)
**Audience:** HayChat maintainers and contributors

This assessment covers the whole repository. It reviewed the shared protocol, the server router, database, storage, IPC and web admin, the client transport, state and config, and the docs, and it ran every check and test suite. Most findings were fixed on `assessment-fixes`. The rest are listed under [Open issues](#open-issues) in priority order.

## Summary

The foundation is solid:

- The transport cryptography is well chosen: Ed25519 identities, X25519 key exchange with HKDF, and XChaCha20-Poly1305 packets that bind the session ID and sequence number. Clients pin the server key on first connect.
- Room access is enforced by the server, and ownership rules are written down in `AGENTS.md`.
- The test suite is real and meaningful.

The biggest risks were:

- A few security holes left over from early scaffolding. One was critical: any logged-in user could run arbitrary SQL.
- A server crash on every successful login.
- A client networking model that would break as soon as more than one server was used.
- Docs that had drifted from the code.

All of those are fixed. The largest remaining gap is product-level: **new users aren't added to any room, so two testers can't chat with each other yet.**

| Area | Before | After |
|---|---|---|
| Client-supplied SQL | Any authenticated peer could run any SQL | Removed |
| Seeded `admin` account | Claimed by whoever connected first as `admin` | Only `HAYCHAT_ADMIN_PUBLIC_KEY` can claim it |
| Web admin `/shutdown`, `/restart`, `/peers`, `/logs` | No authentication (cross-site POSTs possible) | Bearer token required |
| Server on successful auth | Crashed (`free(): invalid pointer`) | Fixed |
| Live auth proof | Failing on `main` | Passing |
| Memory leaks in tests | 29 tests leaked | 0; CI fails on any leak |
| CI | None | GitHub Actions on Linux and Windows |
| Background servers in the client | Never serviced (ENet keepalives missed) | Serviced by a network worker |
| Chat send | 3 DB round trips, racy membership check | 1 atomic SQL statement |
| Tests | 4 / 22 / 31 (common / client / server) | 4 / 25 / 41 |

## Breaking changes

The project is unreleased, so these were acceptable. Anyone with local builds or scripts should still know about them:

- **Protocol version 5.** `ClientAuthLookup`, `ServerAuthLookupResponse`, `ClientDatabaseQuery` and `ServerDatabaseQueryResponse` are removed, which renumbers the `MessageType` values after them. Clients and servers must be rebuilt together.
- **Database IPC types.** `common.DatabaseQueryRequest` and `common.DatabaseQueryResult` are now tagged unions, and `DatabaseQueryType` is gone.
- **Web admin.** `/peers`, `/logs`, `/shutdown` and `/restart` now need `Authorization: Bearer <token>`. `/status` stays open as a health probe.
- **Admin login.** The seeded `admin` account can only be claimed by the key in `HAYCHAT_ADMIN_PUBLIC_KEY`.

New configuration keys, documented in `README.md` and `.env.example`:

| Key | Purpose | Default |
|---|---|---|
| `HAYCHAT_ADMIN_PUBLIC_KEY` | Hex Ed25519 client key allowed to claim keyless accounts that hold server roles | Unset: privileged accounts can't be claimed over the network |
| `HAYCHAT_WEB_ADMIN_TOKEN` | Bearer token for the protected web admin routes (at least 32 characters) | Generated and stored at `$HAYCHAT_FILE_STORAGE_PATH/web_admin_token` with mode `0600` |

To find your client's public key:

```sh
jq -r .public_key "${XDG_CONFIG_HOME:-$HOME/.config}/haychat/config.json"
```

## What changed

### 1. Security fixes — `19411f4`

- **Removed client-supplied raw SQL.** `ClientDatabaseQuery` was routed straight to the database worker and run as the server's role, which can create and drop the schema. Also removed `ClientAuthLookup`, which let anyone check which nicknames exist.
- **Gated privileged account claims.** The identity upsert bound a client's key to *any* keyless account, including the seeded admin. Now a keyless account that holds server roles can only be claimed by `HAYCHAT_ADMIN_PUBLIC_KEY`. Ordinary keyless accounts keep first-claim behavior.
- **Protected the web admin** with a bearer token, compared in constant time. The custom `Authorization` header also forces a CORS preflight, which blocks cross-site forged requests.
- **Wrote the server identity file with mode `0600`.** It contains the server's private key.
- **Fixed a pre-existing crash on every successful login.** Database responses returned string literals such as `"ok"`, and the router later freed them. The router tests built responses with `strings.clone("ok")`, which hid the bug. The live auth proof had been failing on `main` because of it.
- Gave the live tests unique nicknames. With fresh keys and a fixed nickname they could only ever pass once per database.

### 2. CI and leak-checked tests — `cc868bc`

- Added `check.sh`, which runs every compile check and test suite with `ODIN_TEST_FAIL_ON_BAD_MEMORY`. Any leak or bad free fails the run.
- Added `.github/workflows/ci.yml`:
  - The Linux job runs in a Fedora 44 container, because Ubuntu 24.04 doesn't package SDL3. It runs `check.sh` and then a live startup-auth proof against a Postgres service.
  - A Windows job checks the client for `windows_amd64`.
  - Odin and the shared libraries are pinned to exact commits in `.github/scripts/bootstrap-odin.sh`.
- Fixed real client leaks that the tests had been hiding: every draft keystroke, every sent message, every received message and protocol error, and every transcript clear. Also fixed `decodeHexIntoBuffer` leaking on invalid input.
- Gave the client explicit ownership:
  - `State` keeps a deep copy of its config.
  - `Config`, transports, room caches and transcript spans have deinit procedures.
  - `Msg.new_value` ownership is documented.
- Wrote the client config, which holds the private identity key, with mode `0600`.
- Running the bootstrap in a clean container showed that a fresh checkout also needs Odin's vendored STB libraries built for Skald. Both the CI bootstrap and `setup-dev-env.sh` now build them. (Superseded: the client no longer uses Skald, so the STB build step was removed with the SDL3 rewrite.)

### 3. Client network worker — `fce8259`

- The client used to poll ENet from inside `view()`, and only for the selected server. Background servers missed keepalives and acknowledgements, so their sessions would time out.
- A `ClientNetworkWorker` thread now services every live session and queues decoded events. `view()` only drains that queue.
- Code that sends through a transport, or reads its mutable fields, holds the worker's lock.
- Skald's `cmd_thread` returns one message per worker, so it can't express a long-lived receive loop. Draining in `view()` remains the delivery hook. (Superseded: after the SDL3 rewrite the worker wakes the frame loop with an SDL user event, and the loop drains the queue before drawing.)
- The live auth proof now checks that the worker delivers the startup room list from a real server.

### 4. Database flow and tagged unions — `8a9303d`

- Chat send went through three separate database round trips (check membership, list recipients, store), and a user's membership could change between the check and the insert. It is now one `PostRoomChatMessage` statement that checks membership, stores the message and lists recipients from the same snapshot.
- Room history checks membership in the same statement as the page read.
- Database requests and results are now tagged unions. Dispatch and the cleanup switches in `ipc.odin` cover every variant, so a new query won't compile until it is routed and its memory is handled.
- Database responses for unknown request IDs are now freed instead of leaked.
- Small helpers cut the parameter and row-reading boilerplate in `database.odin`.

### 5. Documentation — `4ee1d38`

- The README no longer claims end-to-end encryption, and it has a Known Limitations section.
- CONTRIBUTING now gives the correct license (AGPLv3, not GPLv3) and the working check command.
- `client/AGENTS.md` no longer lists helper commands that don't exist.
- `plans/README.md` has a current baseline.
- `setup-dev-env.sh` installs SDL3 and documents the supported distro releases.

## How this was verified

- `./check.sh` passes locally: common 4, client 25, server 41, all leak-checked.
- `./check.sh` also passes in a clean `fedora:44` container built from scratch with the CI bootstrap script.
- The live startup-auth proof passes against a real server and PostgreSQL, including the worker delivering the room list. No crash appears in the server log.
- The new SQL (identity claim, chat post, room history) was run against PostgreSQL in a rolled-back scratch schema, covering members, non-members, empty rooms, pagination, the configured admin key and attacker keys. This caught one bug before it shipped: `bool::text` gives `"true"`, not `"t"`.

**Not yet verified:**
- The GitHub Actions workflow hasn't run on GitHub. Its Linux steps were reproduced in a container, but the Postgres service step and the Windows job will first run when the branch is pushed.
- The client wasn't exercised interactively through the GUI.

## Open issues

These are in priority order. None of them was in scope for the five steps above.

1. **New users can't chat.** Nothing adds new accounts to a room. The seed fixture creates `general` with only `admin` as a member. This blocks the M1 "two testers exchange messages" goal and the two-client live proof.
   - Suggested fix: when an account is first created, add it to a configured default room, in the same statement as the identity upsert.
   - A second, smaller problem: the two-client live test expects the first event to be a chat message, but the room list arrives first. It should skip non-chat events.
2. **Decide what "end-to-end encryption" means.** Today the server can read every message. Options:
   - (a) Keep transport encryption and market HayChat as self-hosted.
   - (b) Add E2E for direct messages only.
   - (c) Add MLS-based E2E for rooms.

   Options (b) and (c) change the schema, history and search, so it's better to decide before testers create data.
3. **File storage hardening** (`server/storage.odin`):
   - Files are named by `murmur64a`, a non-cryptographic hash, and a matching name counts as "already stored". A crafted collision can stand in for someone else's file. Use SHA-256.
   - The owner is recorded as the transient peer ID, not the user ID.
   - Errors from parsing the JSON manifest are ignored.
   - The whole manifest is rewritten on every upload, on the main router thread.
   - Uploads have no rate limit.

   Moving file metadata into PostgreSQL fixes most of these.
4. **Explicit wire numbering.** `MessageType` uses automatic numbering, so inserting a value shifts every value after it, as this branch's version 5 bump shows. Give the values explicit numbers, or add a test that fixes them in place. Also remove the duplicate messages (`ClientRequestCreateRoom`/`ClientCreateRoom` and others).
5. **Schema migrations.** An incompatible schema is currently rebuilt and its data dropped. Add a `schema_version` table and numbered migrations before testers have data worth keeping.
6. **Per-channel replay protection.** There's one send/receive sequence counter per session, which works for the single reliable channel in use today. Voice and video on unreliable ENet channels will need per-channel counters or a replay window.
7. **Client state model.** `update` copies `State` by value while heap fields stay shared. Production code keeps a single lineage, so this is safe today. Tests that branch several updates from one state are not, and two such tests were rewritten. Consider making room caches and transcripts index-based or arena-owned.
8. **Startup auth blocks the UI.** `init` connects to the selected server with waits of up to a second before the window opens. Moving the handshake onto the network worker would remove the last network I/O from the UI thread.
9. **Server IPC.** The in-memory "IPC" uses made-up file descriptor numbers, routes by matching substrings of socket names, and polls with 1 ms sleeps. Typed channels (`core:sync/chan`) or condition variables would be simpler and lower-latency.
10. **Planning overhead.** `plans/`, `docs/plan/` and the backlog files make up a large share of the repo and drift easily. Consider moving the backlog into GitHub Issues and keeping one short roadmap.

## Running the checks yourself

```sh
./dev.sh ci      # what CI runs: ./check.sh, then the live startup auth proof
```

The helper scripts this assessment originally listed here (`run-test-server.sh` and friends) were replaced by `./dev.sh` in November 2026; see the README's Development Environment section.
