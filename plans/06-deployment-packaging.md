# Phase 2: Deployment And Packaging

## Objective

Define the source-based handoff and runtime layout for the internal-only tester wave.

## Current State

- The repo currently exposes source-level build commands only.
- The server defaults assume Linux filesystem locations and environment-variable configuration.
- The client has a runnable Odin entry point but no installer, desktop bundle, or release bundle definition.
- The server has a localhost web admin endpoint that could help support packaged test runs.

## Assumptions

- The first tester cohort is internal-only.
- The first handoff is source-based, so testers compile from source rather than install packaged binaries.
- Support remains limited to "does it work or not?" setup and run triage.

## Dependencies

- [01-product-readiness.md](01-product-readiness.md) for supported platform scope.
- [03-stability-bug-fixing.md](03-stability-bug-fixing.md) for path and startup defaults.
- [05-developer-experience.md](05-developer-experience.md) for bootstrap and run scripts.
- [04-test-coverage.md](04-test-coverage.md) for release validation gates.

## Prioritized Tasks

1. Document the source-based handoff steps and required build commands for internal testers.
2. Define a server runtime bundle with env file, writable data directory, log directory, and startup script.
3. Define client runtime expectations after local source builds, including config location and required runtime assets.
4. Package PostgreSQL expectations clearly, either as an external prerequisite or via a disposable local environment.
5. Add a repeatable source-build command path that maintainers and testers both use.
6. Document ports, runtime paths, and upgrade/reset behavior for packaged builds.
7. Ensure source revisions and build metadata are captured so testers can report exactly what they ran.

## Risks

- If source build prerequisites are unclear, even internal testers will lose time during setup.
- If runtime paths remain hard-coded to privileged locations, packaged trials will fail on ordinary machines.
- If artifact assembly is manual, each tester build will be subtly different.

## Open Questions

- Should the first server bundle target a single local-host test environment or a small shared test deployment?
- What minimum source-build automation should be added to reduce setup time for internal testers?
- Should Windows client packaging be included in the same milestone or deferred?

## Exit Criteria

- A maintainer can generate a release bundle from a clean checkout using documented steps.
- A tester can compile and run the agreed source-based handoff path from a clean checkout.
- The packaged layout includes all config, asset, and runtime path expectations.
- Each artifact is traceable to a version and validation result.

## Recommended Execution Order

- Begin once [02-core-functionality.md](02-core-functionality.md) and [03-stability-bug-fixing.md](03-stability-bug-fixing.md) have narrowed the runtime shape.
- Finish before [08-tester-onboarding.md](08-tester-onboarding.md) is finalized.
- Keep the first packaging milestone intentionally simple.
