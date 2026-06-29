# Phase 3: Documentation

## Objective

Replace the current high-level repository docs with practical instructions that let testers and maintainers install, configure, run, debug, and evaluate HayChat.

## Current State

- `README.md` describes vision and features but not a concrete install/run path.
- `CONTRIBUTING.md` is contributor-focused and does not explain runtime dependencies.
- `docs/` is empty.
- `server/networking.md` documents one internal subsystem but is not enough for release setup.
- Several important runtime behaviors exist only in code, such as server env vars, client config locations, and web admin endpoints.

## Assumptions

- The first documentation milestone should optimize for successful setup, not broad architecture coverage.
- Tester-facing docs can be separate from contributor and architecture docs.
- Known limitations should be explicit rather than hidden behind aspirational feature lists.

## Dependencies

- [05-developer-experience.md](05-developer-experience.md) for concrete commands and scripts.
- [06-deployment-packaging.md](06-deployment-packaging.md) for artifact layout.
- [08-tester-onboarding.md](08-tester-onboarding.md) for test scenarios and reporting guidance.

## Prioritized Tasks

1. Rewrite the top-level README around the current reality of the project and the first tester release.
2. Add a quickstart guide covering dependencies, build or install steps, configuration, startup order, and first login/message flow.
3. Add a server configuration reference for the current env vars in `server/config.odin`.
4. Add a client configuration reference for config file location and expected contents.
5. Add a troubleshooting guide for common failures: database unavailable, port conflict, permission errors, missing shared libraries, and auth/setup mistakes.
6. Add a known limitations document that separates current behavior from future protocol ambitions.
7. Link existing internal docs such as `server/networking.md` where they help maintainers understand support issues.

## Risks

- If the docs continue to describe the intended product instead of the implemented product, testers will file avoidable failures.
- If configuration is documented incompletely, each machine will become a special case.
- If known limitations are omitted, testers will report missing features as defects instead of expected omissions.

## Open Questions

- Should the tester quickstart live in the top-level README or in dedicated docs with the README kept short?
- How much architecture detail is worth exposing to external testers versus internal maintainers?
- Should screenshots be added now, or only after the core flow is stable?

## Exit Criteria

- A clean-machine user can follow the docs to install and run the agreed tester scenario.
- Runtime configuration, startup order, and troubleshooting steps are documented and accurate.
- Known limitations are visible before testers begin evaluation.
- Documentation is aligned with the packaged artifact and bootstrap workflow.

## Recommended Execution Order

- Start once setup steps and artifact layout stop changing every day.
- Finish before any external tester handoff.
- Update continuously as [05-developer-experience.md](05-developer-experience.md) and [06-deployment-packaging.md](06-deployment-packaging.md) land.
