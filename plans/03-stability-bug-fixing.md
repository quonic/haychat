# Phase 1: Stability And Bug Fixing

## Objective

Remove the setup errors, startup hazards, and runtime surprises most likely to stop testers before they can evaluate the product.

## Current State

- The server has a thread supervisor, restart scheduling, and graceful shutdown flow.
- The web admin process exposes `/status`, `/peers`, `/logs`, `/shutdown`, and `/restart` on localhost.
- The server configuration layer validates and normalizes many env-driven settings.
- The server auto-generates identity keys if not provided and persists them to `serverIdentityFilePath`.
- Default server paths point at `/var/log/haychat` and `/var/lib/haychat/files`, which may be inconvenient or permission-sensitive for non-root local testing.
- `server/network.odin` currently treats inbound packets as chat-channel traffic with a TODO for real channel extraction.
- `client/config.odin` contains legacy Linux migration logic that should be reviewed before relying on it in release docs.
- `client/mime-handler.odin` contains URL scheme support code, but it is not clearly wired into startup.

## Assumptions

- Early tester stability matters more than feature breadth.
- Local development and tester setups should prefer workspace-writable paths over privileged system directories.
- Console logging is acceptable for the first release if it is clear, consistent, and documented.

## Dependencies

- [02-core-functionality.md](02-core-functionality.md) for the final MVP flow.
- [05-developer-experience.md](05-developer-experience.md) for env defaults and helper scripts.
- [07-documentation.md](07-documentation.md) for troubleshooting and known limitations.

## Prioritized Tasks

1. Add startup preflight checks for PostgreSQL connectivity, writable file storage, and writable log/output directories.
2. Introduce tester-safe default paths for local runs so the first setup does not require `/var` access.
3. Improve error messages around database failure, bind failure, and missing runtime dependencies.
4. Review and fix Linux config migration behavior in `client/config.odin` before documenting it.
5. Either implement real channel handling in `server/network.odin` or explicitly scope the release to chat-only transport semantics.
6. Decide whether URL scheme registration is in scope and either wire it properly or remove it from tester-facing expectations.
7. Add a documented health-check flow using the existing web admin endpoints.
8. Ensure shutdown and restart behavior preserve useful logs for reproducing tester issues.

## Risks

- Packaging unstable defaults will generate false bug reports that are really environment problems.
- Silent or vague startup failures will overwhelm early testers and maintainers alike.
- Leaving half-wired desktop integration in place creates confusing platform-specific failures.

## Open Questions

- Should the first release write logs to stdout only, to files, or to both?
- Is the web admin endpoint intended for testers, internal support, or both?
- Do maintainers want a strict fail-fast startup, or degraded startup with warnings for optional services?

## Exit Criteria

- A clean-machine local run can fail only with actionable, documented errors.
- Server runtime directories are writable without ad hoc manual patching.
- The MVP flow survives normal start, connect, send, stop, and restart cycles.
- Known non-MVP behavior is documented instead of surfacing as undefined behavior.

## Recommended Execution Order

- Run in parallel with [02-core-functionality.md](02-core-functionality.md).
- Finish the environment and startup fixes before handing a build to anyone outside the core team.
- Keep smaller bug fixes flowing continuously into [04-test-coverage.md](04-test-coverage.md).
