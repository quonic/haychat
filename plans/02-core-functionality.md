# Phase 1: Core Functionality Gaps

## Objective

Deliver one real end-to-end HayChat experience that testers can evaluate without faking the network path.

## Current State

- `client/transport.odin` contains handshake and encrypted packet helpers.
- `client/main.odin` initializes transport state for configured servers.
- `client/view.odin` shows transport phase and a chat UI.
- `client/update.odin` handles send and receive events locally inside the UI state.
- `server/main.odin` supports handshake, auth lookup routing, file storage, and raw database query routing.
- `server/main.odin` does not currently dispatch chat, direct message, room, or presence packets as part of the post-auth application flow.
- `common/protocol.odin` defines many feature families that are not yet wired into client and server behavior.

## Assumptions

- The first tester release only needs text chat, not the full Discord-like feature set.
- A temporary simplified room model is acceptable if it supports meaningful tester evaluation.
- Registration can remain limited or scripted if authentication and seeded identities are reliable.

## Included vs Deferred Feature Families (First Release)

Included feature families (must align to the MVP evaluator workflow):

- Source build and startup on supported OS targets.
- Configuration and authentication for documented test identities.
- Server-mediated text chat message send and receive.
- Clean restart behavior and log inspection for the core flow.

Deferred feature families (non-blocking for first release):

- Voice, video, and screensharing.
- Forum-style and long-form social content.
- Rich presence and broader social graph features.
- Polished URL scheme integration and non-MVP transport/UI expansions.

## Dependencies

- [01-product-readiness.md](01-product-readiness.md) for the final MVP definition.
- [03-stability-bug-fixing.md](03-stability-bug-fixing.md) for startup and config reliability.
- [05-developer-experience.md](05-developer-experience.md) for sample config and seed workflows.
- [04-test-coverage.md](04-test-coverage.md) for smoke and regression validation.

## Prioritized Tasks

1. Wire the client to a real network transport path instead of only keeping local transport metadata.
2. Implement a minimal connect and authenticate flow from client startup or explicit user action.
3. Add a minimal post-auth message flow for `ClientChatMessage` and `ServerChatMessage` in `server/main.odin`.
4. Replace the local-only append behavior in `client/update.odin` with real send and receive handling.
5. Define a minimal room or DM model for the first release and keep it intentionally small.
6. Provide a way to authenticate test users consistently, either by seeded database data or a narrowly scoped registration flow.
7. Decide whether file upload is part of the first tester scope and either finish it or hide it.
8. Explicitly disable or hide unfinished protocol families in the client UI and release notes.

## Risks

- The current protocol enum surface invites overbuilding if the MVP flow is not aggressively constrained.
- If authentication depends on manual database edits, testers will not be able to reproduce results cleanly.
- UI polish work can easily mask the more important missing network integration.

## Open Questions

- Should the first release use server-backed DM-style messaging only, or a shared room model?
- Is registration needed for testers, or are seeded identities sufficient?
- Should the client auto-connect to the first configured server or expose an explicit connect action?

## Exit Criteria

- Two clean clients can connect to one clean server instance.
- Authentication succeeds for at least one documented test identity.
- A message sent by one client is received by another through the server, not through local UI state.
- The release hides or documents all major unfinished feature families.

## Recommended Execution Order

- Start immediately after [01-product-readiness.md](01-product-readiness.md).
- Treat this as the main gating workstream.
- Finish the minimal end-to-end path before spending significant time on packaging polish.
