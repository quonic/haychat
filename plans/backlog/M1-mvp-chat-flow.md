# Milestone M1: MVP Chat Flow

## Goal

Turn the existing client and server skeleton into a real Linux-first text-chat flow that can be exercised by two testers on a clean setup.

## Exit Criteria

- Two clients can connect to one server and authenticate.
- One client message reaches the other through the server.
- The runtime fails with actionable errors when prerequisites are missing.
- The MVP flow is covered by at least one automated validation path and one manual smoke path.

## Issues

### HC-101 `P0` Define minimal runtime data model

- Outcome: the first release chooses a minimal chat topology, such as one shared room or one simplified DM flow, instead of trying to implement the full room system in `common/protocol.odin`.
- Depends on: `HC-003`.
- Touched areas: [common/protocol.odin](/home/jim/Projects/haychat/common/protocol.odin), [plans/02-core-functionality.md](/home/jim/Projects/haychat/plans/02-core-functionality.md).
- Acceptance criteria:
  - One concrete message path is selected.
  - Server and client tasks can target that path without ambiguity.

### HC-102 `P0` Add client network session orchestration

- Outcome: the client stops treating `client/transport.odin` as passive metadata and actually begins a server handshake for a configured server.
- Depends on: `HC-101`.
- Touched areas: [client/main.odin](/home/jim/Projects/haychat/client/main.odin), [client/transport.odin](/home/jim/Projects/haychat/client/transport.odin), [client/update.odin](/home/jim/Projects/haychat/client/update.odin).
- Acceptance criteria:
  - A configured server can transition out of idle transport state.
  - Handshake failures surface a user-visible or log-visible error.

### HC-103 `P0` Implement minimal connect and authenticate flow

- Outcome: the client can reach `ServerAuthSuccess` against a real server instance using seeded or otherwise supported credentials.
- Depends on: `HC-102`.
- Touched areas: [client/transport.odin](/home/jim/Projects/haychat/client/transport.odin), [server/main.odin](/home/jim/Projects/haychat/server/main.odin), [common/auth.odin](/home/jim/Projects/haychat/common/auth.odin).
- Acceptance criteria:
  - The client can establish an authenticated transport.
  - The server records the authenticated session consistently.

### HC-104 `P0` Implement server-side chat packet dispatch

- Outcome: `server/main.odin` handles `ClientChatMessage` and emits `ServerChatMessage` for the selected MVP flow.
- Depends on: `HC-101`, `HC-103`.
- Touched areas: [server/main.odin](/home/jim/Projects/haychat/server/main.odin), [common/protocol.odin](/home/jim/Projects/haychat/common/protocol.odin).
- Acceptance criteria:
  - Authenticated client chat packets are accepted.
  - The server forwards or broadcasts chat messages according to the MVP design.

### HC-105 `P0` Replace local-only client chat append path

- Outcome: `client/update.odin` stops simulating successful send locally and instead sends over the real transport and renders server-delivered messages.
- Depends on: `HC-103`, `HC-104`.
- Touched areas: [client/update.odin](/home/jim/Projects/haychat/client/update.odin), [client/view.odin](/home/jim/Projects/haychat/client/view.odin), [client/transport.odin](/home/jim/Projects/haychat/client/transport.odin).
- Acceptance criteria:
  - Local echo no longer fakes message delivery.
  - Received messages are distinguishable from unsent drafts and failures.

### HC-106 `P0` Add database bootstrap and test identities

- Outcome: the repo gains a concrete schema/bootstrap path plus sample accounts or seeded identities that support the MVP auth flow.
- Depends on: `HC-003`.
- Touched areas: [server/database.odin](/home/jim/Projects/haychat/server/database.odin), [server/config.odin](/home/jim/Projects/haychat/server/config.odin), [plans/05-developer-experience.md](/home/jim/Projects/haychat/plans/05-developer-experience.md).
- Acceptance criteria:
  - A fresh local environment can create required database state.
  - Testers do not need to invent raw SQL manually to authenticate.

### HC-107 `P0` Add startup preflight and actionable failure messages

- Outcome: the server checks for database reachability, writable storage, and writable logs or output paths before claiming success.
- Depends on: `HC-106`.
- Touched areas: [server/main.odin](/home/jim/Projects/haychat/server/main.odin), [server/config.odin](/home/jim/Projects/haychat/server/config.odin), [server/database.odin](/home/jim/Projects/haychat/server/database.odin).
- Acceptance criteria:
  - Common failure modes are reported clearly.
  - The clean-machine setup fails fast instead of partially starting into a broken state.

### HC-108 `P0` Switch server defaults to tester-safe paths

- Outcome: local runs do not require writing into `/var/log/haychat` or `/var/lib/haychat/files` by default.
- Depends on: `HC-107`.
- Touched areas: [server/config.odin](/home/jim/Projects/haychat/server/config.odin), [plans/03-stability-bug-fixing.md](/home/jim/Projects/haychat/plans/03-stability-bug-fixing.md).
- Acceptance criteria:
  - Fresh local runs succeed under a normal developer account.
  - The default runtime layout is easy to reset and document.

### HC-109 `P1` Review client config migration behavior

- Outcome: Linux config load and migration behavior is correct before it becomes part of release docs.
- Depends on: none.
- Touched areas: [client/config.odin](/home/jim/Projects/haychat/client/config.odin).
- Acceptance criteria:
  - Legacy path handling is intentional and tested or documented.
  - No surprising path concatenation or migration bugs remain in the tester path.

### HC-110 `P1` Decide URL scheme scope

- Outcome: URL scheme registration is either wired deliberately into startup or clearly excluded from the first release.
- Depends on: `HC-003`.
- Touched areas: [client/mime-handler.odin](/home/jim/Projects/haychat/client/mime-handler.odin), [client/main.odin](/home/jim/Projects/haychat/client/main.odin), [plans/03-stability-bug-fixing.md](/home/jim/Projects/haychat/plans/03-stability-bug-fixing.md).
- Acceptance criteria:
  - Tester-facing docs do not promise unsupported desktop integration.
  - Any retained flow has a clear invocation path.

### HC-111 `P1` Scope or implement inbound channel handling

- Outcome: `server/network.odin` no longer carries an unexplained TODO in the supported tester path.
- Depends on: `HC-101`.
- Touched areas: [server/network.odin](/home/jim/Projects/haychat/server/network.odin), [common/protocol.odin](/home/jim/Projects/haychat/common/protocol.odin).
- Acceptance criteria:
  - The release either documents chat-only transport semantics or implements enough channel handling for the MVP.

### HC-112 `P1` Hide unfinished client-visible feature families

- Outcome: the client and docs stop implying that friends, voice, video, forum, and other broad protocol features are part of the first tester build.
- Depends on: `HC-003`.
- Touched areas: [client/view.odin](/home/jim/Projects/haychat/client/view.odin), [README.md](/home/jim/Projects/haychat/README.md), [plans/02-core-functionality.md](/home/jim/Projects/haychat/plans/02-core-functionality.md).
- Acceptance criteria:
  - The tester UI and docs emphasize the supported MVP only.
  - Deferred features are labeled clearly.

### HC-118 `P0` Add MVP automated integration coverage

- Outcome: the project gains an automated validation path for startup, auth success, and one message round trip.
- Depends on: `HC-103`, `HC-104`, `HC-105`, `HC-106`.
- Touched areas: [server/router_test.odin](/home/jim/Projects/haychat/server/router_test.odin), [server/network_event_handler_test.odin](/home/jim/Projects/haychat/server/network_event_handler_test.odin), [common/auth_test.odin](/home/jim/Projects/haychat/common/auth_test.odin), `client/` test files to be added.
- Acceptance criteria:
  - The release gate covers the real MVP flow.
  - Failures point to regressions in connect, auth, or message exchange.

### HC-119 `P0` Create MVP manual smoke checklist

- Outcome: a short manual script exists for validating the exact tester path before each handoff.
- Depends on: `HC-105`, `HC-107`, `HC-118`.
- Touched areas: [plans/04-test-coverage.md](/home/jim/Projects/haychat/plans/04-test-coverage.md), [plans/08-tester-onboarding.md](/home/jim/Projects/haychat/plans/08-tester-onboarding.md).
- Acceptance criteria:
  - The checklist covers startup, connect, send, receive, restart, and log capture.
  - Team members can run it without tribal knowledge.
