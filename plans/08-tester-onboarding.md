# Phase 3: Tester Onboarding

## Objective

Give testers a complete, low-friction path to install HayChat, exercise the intended scenarios, capture useful findings, and understand the current limits of the build.

## Current State

- There is no tester guide, no sample scenario list, no scripted account setup, and no feedback workflow in the repository.
- The client and server do not yet expose a clearly documented evaluator journey.
- The project has enough structure that a guided tester wave is realistic once setup and core flow are stabilized.

## Assumptions

- The first tester wave should be tightly scoped and scenario-driven.
- Testers should not need to invent their own accounts, data, or evaluation steps.
- The first tester cohort is internal-only and compiles from source.
- Support for the first wave is limited to "does it work or not?" and reproducible setup checks.

## Dependencies

- [02-core-functionality.md](02-core-functionality.md) for the actual scenario under test.
- [06-deployment-packaging.md](06-deployment-packaging.md) for the delivery format.
- [07-documentation.md](07-documentation.md) for install and troubleshooting instructions.
- [04-test-coverage.md](04-test-coverage.md) for the smoke checklist backing each build.

## Prioritized Tasks

1. Create a tester guide with explicit install, run, login, and message-exchange steps.
2. Provide sample accounts, seed data, or fixture generation so every tester starts from the same baseline.
3. Define a short scenario matrix for the first wave: install, start server, connect two clients, exchange messages, restart, and collect logs.
4. Create a known-issues list so testers can distinguish expected gaps from new regressions.
5. Define the feedback path: issue template, repro data to collect, logs to attach, and who receives reports.
6. Add a lightweight support playbook for maintainers responding to tester setup failures.
7. Keep onboarding instructions aligned with internal-only, source-build handoff expectations.

## Risks

- Without seeded data and scenario scripts, each tester will spend time discovering basic setup instead of evaluating the product.
- Without a feedback template, reports will be noisy and hard to triage.
- If known limitations are not shared up front, the first tester wave will mostly rediscover intentionally unfinished features.

## Open Questions

- Will testers run their own PostgreSQL and server, or connect to a centrally hosted test server?
- What logs should testers be asked to include by default?
- Is the first tester wave focused on correctness and deployment friction before broader usability feedback?

## Exit Criteria

- A tester can complete the intended scenario without source-level assistance.
- Every tester build ships with setup instructions, sample accounts or fixtures, and a known-issues list.
- Maintainers receive reproducible reports with the data needed to act on them.
- The onboarding path matches the actual packaged artifact and documentation set.

## Recommended Execution Order

- Start after packaging and docs are stable enough for outside consumption.
- Finalize last, immediately before the first tester handoff.
- Update after each tester wave to incorporate support learnings.
