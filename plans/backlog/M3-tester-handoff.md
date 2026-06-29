# Milestone M3: Tester Handoff

## Goal

Turn the release candidate into a tester-usable package with clear setup docs, known limitations, seeded evaluation scenarios, and a support/reporting loop.

## Exit Criteria

- A clean-machine tester can follow the docs and complete the MVP scenario.
- Testers receive sample accounts or fixture flows, a known-issues list, and a feedback path.
- The exact artifact given to testers has passed the release validation gate.

## Issues

### HC-301 `P0` Rewrite top-level README for the current release

- Outcome: the repo landing page stops advertising broad aspirational features as if they are release-ready and instead points users at the actual tester workflow.
- Depends on: `HC-003`, `HC-208` or `HC-210`.
- Touched areas: [README.md](/home/jim/Projects/haychat/README.md).
- Acceptance criteria:
  - The README reflects the current release reality.
  - New users can find the supported install and run path immediately.

### HC-302 `P0` Add quickstart and setup guide

- Outcome: testers get a practical step-by-step guide for install, configuration, startup order, and first message exchange.
- Depends on: `HC-201`, `HC-202`, `HC-203`, `HC-208` or `HC-210`.
- Touched areas: `docs/` files to be added, [plans/07-documentation.md](/home/jim/Projects/haychat/plans/07-documentation.md).
- Acceptance criteria:
  - A clean-machine user can complete the MVP path from docs alone.
  - The guide matches the artifact model and helper commands exactly.

### HC-303 `P0` Add configuration and troubleshooting reference

- Outcome: server env vars, client config location, common failures, and health-check usage are documented.
- Depends on: `HC-107`, `HC-108`, `HC-202`.
- Touched areas: `docs/` files to be added, [server/config.odin](/home/jim/Projects/haychat/server/config.odin), [client/config.odin](/home/jim/Projects/haychat/client/config.odin), [server/web_admin.odin](/home/jim/Projects/haychat/server/web_admin.odin).
- Acceptance criteria:
  - The docs cover configuration values that matter to testers.
  - Common errors have actionable fixes.

### HC-304 `P0` Add known limitations and deferred-features doc

- Outcome: testers can distinguish intentionally missing behavior from regressions.
- Depends on: `HC-005`, `HC-112`.
- Touched areas: `docs/` files to be added, [plans/07-documentation.md](/home/jim/Projects/haychat/plans/07-documentation.md).
- Acceptance criteria:
  - Deferred protocol families and product gaps are listed explicitly.
  - The document matches the actual first-release scope.

### HC-305 `P0` Publish tester smoke script and scenario matrix

- Outcome: the tester package includes the exact evaluation steps for install, connect, send, receive, restart, and log capture.
- Depends on: `HC-119`, `HC-205`, `HC-302`.
- Touched areas: `docs/` files to be added, [plans/08-tester-onboarding.md](/home/jim/Projects/haychat/plans/08-tester-onboarding.md).
- Acceptance criteria:
  - Testers have a concrete script to follow.
  - The scenario matrix matches the supported MVP flow and sample data.

### HC-306 `P0` Add feedback and bug-report template

- Outcome: testers know what repro details, logs, and artifact version to include when filing issues.
- Depends on: `HC-209`, `HC-303`, `HC-305`.
- Touched areas: issue templates or docs to be added, [plans/08-tester-onboarding.md](/home/jim/Projects/haychat/plans/08-tester-onboarding.md).
- Acceptance criteria:
  - Reports request version, environment, steps, expected result, actual result, and logs.
  - Maintainers can triage the first wave without ad hoc follow-up for basic facts.

### HC-307 `P1` Add maintainer support playbook

- Outcome: internal maintainers have a lightweight checklist for responding to tester setup failures and collecting diagnostic data.
- Depends on: `HC-303`, `HC-306`.
- Touched areas: `docs/` files to be added, [plans/08-tester-onboarding.md](/home/jim/Projects/haychat/plans/08-tester-onboarding.md).
- Acceptance criteria:
  - Common support steps are documented.
  - The playbook points to health checks, logs, and reset procedures.

### HC-308 `P1` Decide hosted versus self-hosted tester path

- Outcome: the tester guide states whether users run their own PostgreSQL and server or connect to a shared environment.
- Depends on: `HC-001`, `HC-004`, `HC-302`.
- Touched areas: [plans/08-tester-onboarding.md](/home/jim/Projects/haychat/plans/08-tester-onboarding.md), quickstart docs to be added.
- Acceptance criteria:
  - The onboarding path does not mix incompatible environment assumptions.
  - Support expectations match the chosen delivery model.

### HC-309 `P2` Add screenshots or short walkthrough assets

- Outcome: tester-facing docs include UI references if the core flow has stabilized enough for screenshots to stay current.
- Depends on: `HC-302`, `HC-304`.
- Touched areas: `docs/` assets to be added.
- Acceptance criteria:
  - Visual assets reflect the actual MVP client.
  - Screenshots do not imply support for deferred features.
