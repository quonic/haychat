# HayChat Client Agents Documentation

## Build & Commands

- Typecheck: `odin check client`
- Test: `odin test client` and `odin test client/ui` (the UI toolkit is its own package)
- Build: `odin build client`
- Run: `odin run client`

## Multi-Channel Client

- `State` owns room data in server-scoped caches. Cache identity is `(serverID, roomID)` because room IDs can overlap between configured servers. Do not reintroduce a global room transcript or global channel draft as the source of truth.
- Keep every loaded history page and live message in its room cache. A live message for an inactive room or inactive server must update only that cache; render updates are limited to the selected server and selected room.
- Drafts are client-local and belong to their room cache. Switching rooms restores that room's draft without sending or persisting it.
- `transport.odin` owns encrypted runtime packet construction and decoded runtime-event cleanup. `State_applyRuntimeEvent` in `actions.odin` moves dynamic payloads (room lists, edited rooms) into `State` and clears the moved fields on the event; the caller still runs `ClientTransportRuntimeEvent_deinit` to free whatever was only borrowed.
- `network_worker.odin` services every live server session on a background thread and queues decoded runtime events, then wakes the UI loop through its `onEventQueued` callback. The frame loop in `app.odin` drains that queue (`State_drainNetworkEvents`) before drawing. Any UI-thread code that sends through a transport or reads its mutable fields (`lastError`, crypto state) must hold `ClientNetworkWorker_lock`. Startup auth runs in `init` before the worker starts.
- Room discovery starts after authenticated startup has adopted a live ENet session. Test startup bridges may establish transport state without a live ENet session, so do not make discovery failure invalidate authentication.
- The UI is immediate mode: `view.odin` draws every frame from `State` and calls `State_*` actions in `actions.odin` directly when a widget reports a click or submit. Keep logic in actions and pure view models (`view_model.odin`) so it stays testable without a window; `client/ui` must not depend on HayChat types. Run actions after a list loop when they can reallocate the arrays being drawn.
- Transcript lines label other senders with the message's `senderNickname` (an owned string in every cached `StoredChatMessage`; clone it on merge, free it on deinit) and the local user as "You". "User N" is only the fallback for an empty nickname.
- Build sidebar rooms from the selected server's joined-room list. The chat view derives its transcript from structured cached messages and only shows pagination when `hasOlder` is true.
- Add action tests for cache isolation, history page merge/de-duplication, and selected-room removal fallback whenever channel behavior changes.

## Dev Workflow

- Start the dev server with `./dev.sh up`; seed fixture users and `#general` with `./dev.sh seed`.
- `./dev.sh client [PROFILE]` builds the client from the working tree and opens it on the host's Wayland or X11 display, inside the dev pod. Each profile keeps its config and identity key in its own volume, and a new profile's display name is the profile name, so profiles are distinct users. `./dev.sh key PROFILE` prints a profile's public key.
- A client on the host (`odin run client`) also reaches the dev server at its default `localhost:12345`, but it uses the host's real `~/.config/haychat`.
- `headless.odin` is the headless harness (`client --headless`, see `docs/testing-harness.md`). It drives `State` and the actions with no SDL; `main` in `app.odin` only branches to it. Its connect step is one procedure (`headlessConnectAndWait`), so connection-flow changes adapt there. New runtime event kinds need a name and a case in `headlessRenderRuntimeEvent`; new user actions can get a row in `HEADLESS_COMMANDS`.
- Live client tests (`HAYCHAT_LIVE_STARTUP_AUTH=1`) run through `./dev.sh live`, which gives them a fresh server and database. They connect to `127.0.0.1:12345`.
