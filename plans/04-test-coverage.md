# Phase 1-2: Test Coverage

## Objective

Turn the current build and test baseline into release confidence for a tester-facing build.

## Current State

- `odin test server` passes with router, restart scheduling, queue, auth lookup, and file-store validation coverage.
- `odin test common` passes with crypto, key encoding, and replay-protection coverage.
- There are no client test files under `client/`.
- There are no end-to-end tests that start a server, connect clients, and exchange user-visible messages.
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
2. Add client-side tests for config loading, transport state transitions, and any new connect/send logic.
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
- The project has a single release validation entry point that team members can run consistently.
- Known gaps in coverage are listed and accepted explicitly.

## Recommended Execution Order

- Start as soon as the MVP flow is chosen.
- Add tests alongside core functionality and stability changes, not after them.
- Finish the release smoke gate before [06-deployment-packaging.md](06-deployment-packaging.md) is declared complete.
