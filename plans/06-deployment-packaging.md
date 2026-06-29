# Phase 2: Deployment And Packaging

## Objective

Produce artifacts and runtime layouts that testers can install and run without building the project by hand unless explicitly intended.

## Current State

- The repo currently exposes source-level build commands only.
- The server defaults assume Linux filesystem locations and environment-variable configuration.
- The client has a runnable Odin entry point but no installer, desktop bundle, or release bundle definition.
- The server has a localhost web admin endpoint that could help support packaged test runs.

## Assumptions

- The first handoff can prioritize simple, inspectable distribution over polished installers.
- A packaged server plus packaged client is preferable for external testers.
- Internal testers may accept a source-based option as a fallback if the packaged path is not yet ready.

## Dependencies

- [01-product-readiness.md](01-product-readiness.md) for supported platform scope.
- [03-stability-bug-fixing.md](03-stability-bug-fixing.md) for path and startup defaults.
- [05-developer-experience.md](05-developer-experience.md) for bootstrap and run scripts.
- [04-test-coverage.md](04-test-coverage.md) for release validation gates.

## Prioritized Tasks

1. Decide the first release artifact types: source-only bundle, binary tarball, or both.
2. Define a server runtime bundle with env file, writable data directory, log directory, and startup script.
3. Define a client bundle with config location expectations and any required runtime assets.
4. Package PostgreSQL expectations clearly, either as an external prerequisite or via a disposable local environment.
5. Add a release assembly script that builds artifacts and stages the expected directory structure.
6. Document ports, runtime paths, and upgrade/reset behavior for packaged builds.
7. Add checksums and version identifiers so testers can report exactly what they ran.

## Risks

- If the only supported path is source build from scratch, external tester participation will stay low.
- If runtime paths remain hard-coded to privileged locations, packaged trials will fail on ordinary machines.
- If artifact assembly is manual, each tester build will be subtly different.

## Open Questions

- Should the first server bundle target a single local-host test environment or a small shared test deployment?
- Are Linux tarballs sufficient, or is OS-native packaging required for the first wave?
- Should Windows client packaging be included in the same milestone or deferred?

## Exit Criteria

- A maintainer can generate a release bundle from a clean checkout using documented steps.
- A tester can install and run the agreed artifact type without editing source files.
- The packaged layout includes all config, asset, and runtime path expectations.
- Each artifact is traceable to a version and validation result.

## Recommended Execution Order

- Begin once [02-core-functionality.md](02-core-functionality.md) and [03-stability-bug-fixing.md](03-stability-bug-fixing.md) have narrowed the runtime shape.
- Finish before [08-tester-onboarding.md](08-tester-onboarding.md) is finalized.
- Keep the first packaging milestone intentionally simple.
