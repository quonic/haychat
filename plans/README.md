# HayChat Tester-Ready Plan Index

This directory breaks the path to a tester-usable HayChat release into focused workstreams that map to the current repository, not an idealized future product.

## Current Baseline

- `odin check server` passes.
- `odin check client -target:linux_amd64` passes.
- `odin test server` passes with 16 tests.
- `odin test common` passes with 3 tests.
- The repository already contains a threaded server, a Skald-based client UI, shared protocol and crypto code, file storage helpers, a localhost web admin surface, and a small automated test suite.

## What Is Already Complete

- Shared transport/authentication primitives exist in `common/`.
- The server process manager, IPC, ENet network loop, database worker, and web admin worker exist in `server/`.
- The client has configuration persistence, a GUI shell, and transport handshake helpers in `client/`.
- The server and common packages already have meaningful unit and routing tests.

## What Blocks Tester Usage Today

- The client does not appear to use its transport layer to establish a real server connection.
- The client chat UI currently appends messages locally instead of sending them over the network.
- The server only dispatches a narrow set of post-auth application packets today: auth lookup, file store, and raw database query routing.
- There is no checked-in database schema, migration flow, seed data, or sample test accounts.
- The public docs are too thin for a clean-machine install and run.
- There is no packaging or release artifact flow for handing a build to testers.

## First-Release Feature Families (Included)

- Build and run the server and client from source on supported Linux and Windows targets.
- Configure PostgreSQL and HayChat settings with documented sample values.
- Authenticate two test users.
- Exchange text chat messages through the server.
- Restart server and clients cleanly and inspect logs for startup, auth, message, and restart events.

## What Can Be Deferred Until After First Tester Feedback

- Voice, video, screenshare, and forum flows already modeled in `common/protocol.odin`.
- Rich friend presence, discovery, and sync beyond static config entries.
- Desktop URL scheme registration polish.
- Production-grade log shipping, metrics, and signing.
- macOS support, which is out of scope for the first tester wave.

## Critical Path

1. [01-product-readiness.md](01-product-readiness.md): lock the tester target, supported platforms, and minimum release scope.
2. [02-core-functionality.md](02-core-functionality.md): make one real end-to-end tester flow work.
3. [03-stability-bug-fixing.md](03-stability-bug-fixing.md): remove the setup and runtime failures most likely to block evaluation.
4. [05-developer-experience.md](05-developer-experience.md): make local setup reproducible for internal team members preparing builds.
5. [06-deployment-packaging.md](06-deployment-packaging.md): produce artifacts testers can actually install and run.
6. [07-documentation.md](07-documentation.md): document install, config, known limits, and troubleshooting.
7. [08-tester-onboarding.md](08-tester-onboarding.md): give testers a script, accounts, fixtures, and reporting path.
8. [04-test-coverage.md](04-test-coverage.md): build smoke and regression coverage continuously, with release-gating checks complete before handoff.

## Recommended Execution Model

- Phase 0: Product readiness decisions.
- Phase 1: Core functionality and blocker stability work in parallel, with test coverage added alongside implementation.
- Phase 2: Developer experience and packaging once the core flow is stable enough to automate.
- Phase 3: Documentation and tester onboarding once the artifact format and setup steps stop changing daily.

## Plan Files

- [release-decision-record.md](release-decision-record.md): canonical M0 release contract (scope, platform, and handoff baseline).
- [01-product-readiness.md](01-product-readiness.md): scope, release definition, and go/no-go framing.
- [02-core-functionality.md](02-core-functionality.md): minimum feature set for a tester-usable build.
- [03-stability-bug-fixing.md](03-stability-bug-fixing.md): operational hardening and blocker fixes.
- [04-test-coverage.md](04-test-coverage.md): automated and manual validation needed for release confidence.
- [05-developer-experience.md](05-developer-experience.md): setup automation, scripts, and contributor/test-prep ergonomics.
- [06-deployment-packaging.md](06-deployment-packaging.md): build artifacts, runtime layout, and distribution.
- [07-documentation.md](07-documentation.md): install, config, troubleshooting, and known limitations docs.
- [08-tester-onboarding.md](08-tester-onboarding.md): accounts, scenarios, feedback loop, and support path.

## Backlog Conversion

- [backlog/README.md](backlog/README.md): milestone backlog index for the critical path.
- [backlog/M0-release-scope-gate.md](backlog/M0-release-scope-gate.md): release-definition decisions and scope guardrails.
- [backlog/M1-mvp-chat-flow.md](backlog/M1-mvp-chat-flow.md): implementation backlog for the first real chat flow.
- [backlog/M2-reproducible-release-candidate.md](backlog/M2-reproducible-release-candidate.md): reproducible setup, validation, and artifact production.
- [backlog/M3-tester-handoff.md](backlog/M3-tester-handoff.md): docs, onboarding, and release-handoff tasks.

Use the backlog files when turning the critical path into tracker tickets or milestone boards.
