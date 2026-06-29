# Milestone M2: Reproducible Release Candidate

## Goal

Make the MVP flow repeatable on clean machines and producible as a release candidate without maintainer-specific setup steps.

## Exit Criteria

- Bootstrap, run, reset, and validation steps are reproducible.
- The project can produce the agreed handoff artifact from a clean checkout.
- The artifact includes enough runtime structure for testers to use it without editing source files.

## Issues

### HC-201 `P0` Add dependency bootstrap path

- Outcome: the repo gains one supported path for installing Odin, shared libraries, PostgreSQL, and required OS packages.
- Depends on: `HC-004`, `HC-106`, `HC-108`.
- Touched areas: [README.md](/home/jim/Projects/haychat/README.md), [CONTRIBUTING.md](/home/jim/Projects/haychat/CONTRIBUTING.md), [plans/05-developer-experience.md](/home/jim/Projects/haychat/plans/05-developer-experience.md).
- Acceptance criteria:
  - A new maintainer can follow one bootstrap path from a clean machine.
  - The bootstrap instructions match the actual release target.

### HC-202 `P0` Add example server env configuration

- Outcome: maintainers and testers can start the server with a checked-in example env file or equivalent documented configuration.
- Depends on: `HC-108`.
- Touched areas: [server/config.odin](/home/jim/Projects/haychat/server/config.odin), [plans/05-developer-experience.md](/home/jim/Projects/haychat/plans/05-developer-experience.md).
- Acceptance criteria:
  - Required variables and safe defaults are obvious.
  - The example config is sufficient to launch a local test environment.

### HC-203 `P0` Add start and stop helper commands

- Outcome: the repo offers a standard way to start PostgreSQL, the server, and one or more clients for the MVP scenario.
- Depends on: `HC-201`, `HC-202`, `HC-106`.
- Touched areas: helper scripts or task files to be added, [client/AGENTS.md](/home/jim/Projects/haychat/client/AGENTS.md), [server/AGENTS.md](/home/jim/Projects/haychat/server/AGENTS.md).
- Acceptance criteria:
  - Team members do not need to reconstruct startup order manually.
  - Commands work against the agreed MVP setup.

### HC-204 `P0` Add local reset workflow

- Outcome: config, logs, file storage, and seeded database state can be reset between test runs.
- Depends on: `HC-202`, `HC-203`.
- Touched areas: helper scripts or task files to be added, [server/config.odin](/home/jim/Projects/haychat/server/config.odin), [client/config.odin](/home/jim/Projects/haychat/client/config.odin).
- Acceptance criteria:
  - The reset workflow clears stale local state predictably.
  - Testers and maintainers can reproduce a fresh environment quickly.

### HC-205 `P0` Add fixture or seed generation flow

- Outcome: sample accounts and required initial records can be created without manual SQL editing.
- Depends on: `HC-106`, `HC-203`.
- Touched areas: database bootstrap assets to be added, [server/database.odin](/home/jim/Projects/haychat/server/database.odin).
- Acceptance criteria:
  - The MVP test identities are reproducible.
  - The seed path integrates with local bootstrap or reset.

### HC-206 `P0` Add one-command release validation

- Outcome: a single script or documented command validates the release candidate using checks and smoke tests appropriate to the first wave.
- Depends on: `HC-118`, `HC-119`, `HC-203`, `HC-205`.
- Touched areas: validation scripts to be added, [plans/04-test-coverage.md](/home/jim/Projects/haychat/plans/04-test-coverage.md).
- Acceptance criteria:
  - Team members can run one release validation entry point.
  - The validation path reflects the actual tester experience.

### HC-207 `P1` Define artifact layout

- Outcome: maintainers standardize the runtime bundle structure for server config, logs, data, binaries, and assets.
- Depends on: `HC-004`, `HC-202`, `HC-203`.
- Touched areas: [plans/06-deployment-packaging.md](/home/jim/Projects/haychat/plans/06-deployment-packaging.md).
- Acceptance criteria:
  - The release bundle directory structure is explicit.
  - Runtime paths used by docs and scripts match the bundle layout.

### HC-208 `P1` Add release assembly workflow

- Outcome: the project can build and stage the agreed artifact from a clean checkout.
- Depends on: `HC-207`, `HC-206`.
- Touched areas: release scripts to be added, [plans/06-deployment-packaging.md](/home/jim/Projects/haychat/plans/06-deployment-packaging.md).
- Acceptance criteria:
  - Artifact assembly is repeatable and not manual.
  - The staged output matches the documented runtime layout.

### HC-209 `P1` Add versioning and checksums to artifacts

- Outcome: testers can report exactly which build they ran.
- Depends on: `HC-208`.
- Touched areas: release scripts to be added, [plans/06-deployment-packaging.md](/home/jim/Projects/haychat/plans/06-deployment-packaging.md).
- Acceptance criteria:
  - Release outputs include a version identifier.
  - Distributed artifacts include checksums or equivalent integrity markers.

### HC-210 `P2` Decide source-based fallback support

- Outcome: if packaged artifacts are incomplete, the repo documents whether a source-based tester path remains supported.
- Depends on: `HC-004`, `HC-208`.
- Touched areas: [README.md](/home/jim/Projects/haychat/README.md), [plans/06-deployment-packaging.md](/home/jim/Projects/haychat/plans/06-deployment-packaging.md).
- Acceptance criteria:
  - Maintainers know whether source setup is an official fallback.
  - Tester docs do not present conflicting installation models.
