# Milestone M0: Release Scope Gate

## Goal

Freeze the first tester release so implementation work stays focused on a text-chat evaluation build for
Linux and Windows instead of the full protocol surface.

## Exit Criteria

- Supported tester persona and platform matrix are documented.
- The first-release artifact strategy is chosen.
- The MVP workflow and deferred features are explicit.
- Downstream milestones can reference a stable release definition.

## Issues

### HC-001 `P0` Define first tester cohort

- Outcome: a short written decision on whether the first wave is internal-only, trusted external, or mixed.
- Depends on: none.
- Touched areas: [plans/01-product-readiness.md](/home/jim/Projects/haychat/plans/01-product-readiness.md), [plans/backlog/README.md](/home/jim/Projects/haychat/plans/backlog/README.md).
- Acceptance criteria:
  - The intended tester cohort is stated in one place.
  - Support expectations and artifact expectations are adjusted to that cohort.

### HC-002 `P0` Freeze supported platform matrix

- Outcome: the first release explicitly supports Linux and Windows for both server and client, with
  macOS explicitly out of scope.
- Depends on: `HC-001`.
- Touched areas: [plans/01-product-readiness.md](/home/jim/Projects/haychat/plans/01-product-readiness.md), [plans/backlog/README.md](/home/jim/Projects/haychat/plans/backlog/README.md).
- Acceptance criteria:
  - Required platforms are named for both server and client.
  - Non-target platforms are marked out of scope for milestone planning.

### HC-003 `P0` Freeze MVP evaluator workflow

- Outcome: the first release is limited to install, configure, authenticate, exchange text messages, restart, and inspect logs.
- Release-gate workflow: install and build from source on a supported OS, configure PostgreSQL and app settings, start server and two clients, authenticate both users, exchange text messages, restart cleanly, and inspect logs.
- Explicit non-goals: voice, video, screensharing, forum flows, rich presence, macOS support, polished URL scheme integration, and any path outside the release-gate workflow.
- Depends on: `HC-001`, `HC-002`.
- Touched areas: [plans/01-product-readiness.md](/home/jim/Projects/haychat/plans/01-product-readiness.md), [plans/02-core-functionality.md](/home/jim/Projects/haychat/plans/02-core-functionality.md).
- Acceptance criteria:
  - One end-to-end workflow is named as the release gate.
  - Features outside that workflow are listed as deferred.

### HC-004 `P0` Decide handoff model

- Outcome: maintainers choose between source-based setup, packaged binaries, or both for the first wave.
- Depends on: `HC-001`, `HC-002`.
- Touched areas: [plans/01-product-readiness.md](/home/jim/Projects/haychat/plans/01-product-readiness.md), [plans/06-deployment-packaging.md](/home/jim/Projects/haychat/plans/06-deployment-packaging.md).
- Acceptance criteria:
  - The supported handoff model is documented.
  - Milestones M2 and M3 can plan against a stable artifact assumption.

### HC-005 `P1` Define included and deferred features

- Outcome: the release notes and planning docs clearly distinguish text chat MVP work from deferred protocol families such as voice, video, forum, and rich presence.
- Depends on: `HC-003`.
- Touched areas: [plans/README.md](/home/jim/Projects/haychat/plans/README.md), [plans/02-core-functionality.md](/home/jim/Projects/haychat/plans/02-core-functionality.md).
- Acceptance criteria:
  - Deferred features are named explicitly.
  - No milestone issue depends on unfinished non-MVP protocol families unless they unblock the release.

### HC-006 `P1` Create release decision record

- Outcome: a short canonical markdown note captures scope, target platforms, artifact model, and release gate.
- Depends on: `HC-002`, `HC-003`, `HC-004`.
- Touched areas: [plans/backlog/README.md](/home/jim/Projects/haychat/plans/backlog/README.md), [plans/01-product-readiness.md](/home/jim/Projects/haychat/plans/01-product-readiness.md).
- Acceptance criteria:
  - The release contract is easy to reference from later issues.
  - Scope drift can be judged against a written baseline.
