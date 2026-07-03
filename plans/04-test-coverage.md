# Phase 1-2: Test Coverage

## Objective

Turn the current build and test baseline into release confidence for a tester-facing build.

## Current State

- `odin test server` passes with router, restart scheduling, queue, auth lookup, and file-store validation coverage.
- `odin test common` passes with crypto, key encoding, and replay-protection coverage.
- `client/main_test.odin` covers selected/default startup-attempt kickoff and visible selected-server init failure surfacing.
- The supported Linux-first HC-118 gate entrypoint is `./run-test-server.sh hc118-gate`, which composes the baseline package tests with the live startup/connect/auth/message proof.
- There is no documented manual smoke checklist for release candidates.

## Assumptions

- The first tester release needs a small but trustworthy release gate, not exhaustive coverage.
- A mixture of automated smoke tests and a short manual checklist is acceptable.
- Integration coverage should follow the MVP flow rather than the full protocol surface.

## Dependencies

- [02-core-functionality.md](02-core-functionality.md) to define the message flow worth testing.
- [03-stability-bug-fixing.md](03-stability-bug-fixing.md) for deterministic startup behavior.
- [05-developer-experience.md](05-developer-experience.md) for reproducible commands and fixtures.

## Prioritized Tasks

1. Keep the existing `server` and `common` tests green as a non-negotiable baseline.
2. Extend client-side coverage from startup-attempt regression tests into transport state transitions and HC-103 connect/auth behavior.
3. Add integration tests for server startup, auth success, and one message round trip between two clients.
4. Add database-related tests for bootstrap, seed data expectations, and failure reporting.
5. Add storage tests if file upload remains in scope for the first tester release.
6. Define a short manual smoke checklist for every release candidate.
7. Gate packaging and handoff on a single repeatable validation command or script.

## Risks

- Without end-to-end coverage, the project can look healthy in unit tests while the tester path is still broken.
- If release validation is manual only, regressions in setup and auth will recur.
- If coverage is aimed at every protocol branch, the release will stall.

## Open Questions

- Should the end-to-end tests run against real PostgreSQL, a disposable database container, or a seeded local instance?
- Is it acceptable to create a lightweight headless client harness for integration tests instead of driving the GUI client?
- Do maintainers want the release gate to include Windows validation or Linux only for the first wave?

## Exit Criteria

- Automated tests cover the agreed MVP connect/auth/message flow.
- A documented smoke checklist exists and is used before every tester handoff.
- The project has a single Linux-first local validation entry point that team members can run consistently: `./run-test-server.sh hc118-gate`.
- Known gaps in coverage are listed and accepted explicitly.

## HC-119 Manual Smoke Checklist

Use this as the manual companion to `./run-test-server.sh hc118-gate`, not as a replacement for the automated gate.

1. Start from the Linux-first local default runtime layout unless overrides are set: `logs/`, `storage/`, and `storage/server_identity.json`.
2. Before starting the helper, ensure local PostgreSQL is already available or matching `HAYCHAT_DATABASE_*` overrides are set, and that the configured database/user can create and seed what bootstrap requires.
3. Start the supported helper-managed server path with `./run-test-server.sh bootstrap-start-background`.
4. Confirm the admin surface is live with `GET http://localhost:8080/status`.
5. Launch two local clients explicitly, for example with `odin run client` in two terminals.
6. For the default smoke path, do not manually edit client config. Auto-seeding and local startup attempt are only guaranteed when no servers are already configured; existing non-default client server settings are preserved.
7. Authenticate one client as `hayseed` and the other as `haypeer`.
8. Send one chat message from `hayseed` and verify it is received by `haypeer`.
9. Send one reply from `haypeer` and verify it is received by `hayseed`.
10. Verify restart behavior conservatively with `POST http://localhost:8080/restart`. After restart, relaunch the clients or reconnect explicitly, then confirm the pair can sign in again and exchange one more message.
11. If bootstrap or readiness fails before web admin is live, capture `.haychat-test-server/server.log` first. Otherwise capture server diagnostics with `GET http://localhost:8080/logs` and attach that output together with the relevant files from `logs/` if the run fails or looks suspicious.
12. Stop the helper-managed server with `./run-test-server.sh stop` when the smoke run completes.

Failure bucketing for triage should be obvious from the attached artifacts: startup or readiness failure, connect or auth failure, message send or receive failure, restart or reconnect failure, or missing runtime artifacts under `logs/` and `storage/`.

## Recommended Execution Order

- Start as soon as the MVP flow is chosen.
- Add tests alongside core functionality and stability changes, not after them.
- Finish the release smoke gate before [06-deployment-packaging.md](06-deployment-packaging.md) is declared complete.
