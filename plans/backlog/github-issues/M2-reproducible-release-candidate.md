# M2 Reproducible Release Candidate: GitHub Issue Drafts

## HC-201

**Title:** Add one supported dependency bootstrap path for local HayChat setup

**Milestone:** M2 Reproducible Release Candidate

**Priority:** P0

**Suggested labels:** `devex`, `docs`, `p0`

**Depends on:** HC-004, HC-106, HC-108

Summary:

Define one clean bootstrap path for Odin, PostgreSQL, shared libraries, and required OS packages so maintainers and internal testers can reproduce setup on a clean machine.

Deliverables:

- Bootstrap instructions or automation.
- Alignment with the first-release platform and handoff model.

Acceptance Criteria:

- A clean-machine maintainer can prepare the environment using one supported flow.
- The bootstrap path matches the actual release target.

## HC-202

**Title:** Add example server environment configuration for local tester runs

**Milestone:** M2 Reproducible Release Candidate

**Priority:** P0

**Suggested labels:** `server`, `devex`, `p0`

**Depends on:** HC-108

Summary:

Provide a checked-in example of the env-based server configuration used for tester-safe local runs.

Deliverables:

- Example env configuration.
- Documentation for required and optional values.

Acceptance Criteria:

- Local startup does not require guessing environment variables.
- The example config is sufficient to launch the MVP scenario.

## HC-203

**Title:** Add standard start and stop helper commands for the MVP environment

**Milestone:** M2 Reproducible Release Candidate

**Priority:** P0

**Suggested labels:** `devex`, `server`, `client`, `p0`

**Depends on:** HC-201, HC-202, HC-106

Summary:

Create a standard way to start PostgreSQL, the HayChat server, and one or more clients in the correct order for the MVP scenario.

Deliverables:

- Helper scripts or task commands.
- Basic startup and shutdown guidance.

Acceptance Criteria:

- Team members can launch the MVP environment without reconstructing steps manually.
- The commands match the supported workflow in the docs.

## HC-204

**Title:** Add a repeatable local reset workflow for runtime state and fixtures

**Milestone:** M2 Reproducible Release Candidate

**Priority:** P0

**Suggested labels:** `devex`, `stability`, `p0`

**Depends on:** HC-202, HC-203

Summary:

Provide a reset flow for config, logs, file storage, and test data so each trial run can start from a known baseline.

Deliverables:

- Reset command or script.
- Documentation of what state it clears.

Acceptance Criteria:

- Local environments can be reset without manual cleanup.
- The reset workflow supports reliable reproduction.

## HC-205

**Title:** Add fixture or seed generation for test identities and required records

**Milestone:** M2 Reproducible Release Candidate

**Priority:** P0

**Suggested labels:** `database`, `devex`, `p0`

**Depends on:** HC-106, HC-203

Summary:

Automate the creation of the sample identities and initial records needed by the MVP evaluator flow.

Deliverables:

- Seed or fixture generation.
- Integration with bootstrap or reset flows.

Acceptance Criteria:

- Test identities are reproducible.
- Maintainers do not need to seed the environment by hand.

## HC-206

**Title:** Add one-command release validation for the tester-ready candidate

**Milestone:** M2 Reproducible Release Candidate

**Priority:** P0

**Suggested labels:** `tests`, `release`, `devex`, `p0`

**Depends on:** HC-118, HC-119, HC-203, HC-205

Summary:

Create a single validation entry point that runs the required checks and smoke logic for the release candidate.

Deliverables:

- A one-command release validation flow.
- Output that makes pass/fail status clear.

Acceptance Criteria:

- Team members can run one command to validate a candidate build.
- The validation reflects the real tester experience closely enough to gate release handoff.

## HC-207

**Title:** Define the runtime artifact layout for the first tester release

**Milestone:** M2 Reproducible Release Candidate

**Priority:** P1

**Suggested labels:** `packaging`, `release`, `p1`

**Depends on:** HC-004, HC-202, HC-203

Summary:

Standardize the runtime bundle structure for binaries, config, logs, data, and assets so packaging and docs use the same layout.

Deliverables:

- Artifact layout definition.
- Path conventions that align with helper scripts and docs.

Acceptance Criteria:

- The release bundle structure is explicit.
- Runtime paths used by scripts and docs match the layout.

## HC-208

**Title:** Add a repeatable release assembly workflow for tester artifacts

**Milestone:** M2 Reproducible Release Candidate

**Priority:** P1

**Suggested labels:** `packaging`, `release`, `p1`

**Depends on:** HC-207, HC-206

Summary:

Automate the build and staging process for the agreed tester artifact so each candidate is assembled the same way.

Deliverables:

- Release assembly script or equivalent workflow.
- Staged output matching the documented artifact layout.

Acceptance Criteria:

- Release assembly is reproducible from a clean checkout.
- The staged output matches the documented runtime structure.

## HC-209

**Title:** Add version identifiers and checksums to tester artifacts

**Milestone:** M2 Reproducible Release Candidate

**Priority:** P1

**Suggested labels:** `packaging`, `release`, `p1`

**Depends on:** HC-208

Summary:

Ensure testers can report exactly which build they ran and that maintainers can identify artifact integrity.

Deliverables:

- Version identifier in release output.
- Checksums or equivalent artifact metadata.

Acceptance Criteria:

- Each tester artifact is traceable to a concrete build.
- Testers can include version details in bug reports.

## HC-210

**Title:** Decide whether source-based setup remains a supported fallback

**Milestone:** M2 Reproducible Release Candidate

**Priority:** P2

**Suggested labels:** `packaging`, `docs`, `p2`

**Depends on:** HC-004, HC-208

Summary:

Clarify whether source-based setup remains an officially supported fallback when packaged artifacts are incomplete or inconvenient.

Deliverables:

- A support decision.
- Documentation updates to match that decision.

Acceptance Criteria:

- The install story is internally consistent.
- Testers are not given conflicting handoff models.
