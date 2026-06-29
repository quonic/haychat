# Phase 2: Developer Experience

## Objective

Make it easy for maintainers and internal testers to set up, run, reset, and validate HayChat without tribal knowledge.

## Current State

- Build commands exist in `client/AGENTS.md` and `server/AGENTS.md`.
- The top-level README only points users at `client/` and `server/` without a real setup guide.
- There are no helper scripts, no checked-in env example, no bootstrap command, and no seed/reset workflow.
- The server relies on PostgreSQL and several Odin shared/vendor dependencies that are not explained in onboarding docs.

## Assumptions

- Internal teams need a repeatable local workflow before external testers can be supported well.
- Source-based workflows will remain important even if binary artifacts are added later.
- Resettable local environments are more important than production deployment fidelity for the first tester release.

## Dependencies

- [03-stability-bug-fixing.md](03-stability-bug-fixing.md) for sane defaults.
- [06-deployment-packaging.md](06-deployment-packaging.md) for artifact layout decisions.
- [07-documentation.md](07-documentation.md) for final presentation.

## Prioritized Tasks

1. Add a single documented bootstrap path for Odin, shared libraries, PostgreSQL, and any OS packages.
2. Create an example env file for server configuration with tester-safe paths and ports.
3. Add helper scripts or commands to start the database, server, and one or more clients in a known-good configuration.
4. Add a reset flow for local state, including config, logs, file storage, and test data.
5. Provide seed data or fixture generation for test accounts and any required initial records.
6. Add a release validation script that runs the minimal required checks before handoff.
7. Document the existing web admin endpoints as part of the local support workflow.

## Risks

- If maintainers cannot reproduce setups quickly, external tester support will collapse into one-off debugging.
- If env values are copied manually from chat or memory, release candidates will drift.
- If reset flows are missing, old state will contaminate tester results.

## Open Questions

- Should helper automation live in shell scripts, a Makefile, just/task files, or Odin tooling?
- Is Docker acceptable for the database dependency, or should the primary workflow stay system-native?
- Should client startup accept explicit server arguments for test automation?

## Exit Criteria

- A new team member can prepare a working local environment from repository docs alone.
- Test accounts and runtime state can be created and reset predictably.
- The team has a standard way to launch the full tester scenario.
- Release candidate validation is repeatable and not dependent on a specific maintainer machine.

## Recommended Execution Order

- Start once the MVP flow is stable enough to automate.
- Complete before external tester distribution.
- Keep this aligned tightly with [07-documentation.md](07-documentation.md) so instructions do not drift.
