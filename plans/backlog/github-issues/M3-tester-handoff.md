# M3 Tester Handoff: GitHub Issue Drafts

## HC-301

**Title:** Rewrite the top-level README for the actual tester-ready release

**Milestone:** M3 Tester Handoff

**Priority:** P0

**Suggested labels:** `docs`, `release`, `p0`

**Depends on:** HC-003, HC-208 or HC-210

Summary:

Update the repo landing page so it reflects the current tester-ready release instead of the broader long-term product vision.

Deliverables:

- Updated README content.
- Clear pointers to install and run docs.

Acceptance Criteria:

- The README describes the supported tester path accurately.
- New users can find the right install and run instructions immediately.

## HC-302

**Title:** Add a quickstart guide for install, config, startup, and first message exchange

**Milestone:** M3 Tester Handoff

**Priority:** P0

**Suggested labels:** `docs`, `tester-readiness`, `p0`

**Depends on:** HC-201, HC-202, HC-203, HC-208 or HC-210

Summary:

Create a clean-machine quickstart guide that walks a tester through install, configuration, startup order, authentication, and first successful messaging.

Deliverables:

- Quickstart documentation.
- Paths and commands aligned with the supported release model.

Acceptance Criteria:

- A clean-machine user can follow the guide without source-level assistance.
- The quickstart matches the actual release artifact or source fallback path.

## HC-303

**Title:** Add configuration and troubleshooting reference for tester environments

**Milestone:** M3 Tester Handoff

**Priority:** P0

**Suggested labels:** `docs`, `server`, `client`, `p0`

**Depends on:** HC-107, HC-108, HC-202

Summary:

Document server env vars, client config location, health checks, and the most common startup and runtime failures.

Deliverables:

- Configuration reference.
- Troubleshooting guide.

Acceptance Criteria:

- Testers and maintainers can diagnose common setup failures from docs.
- Configuration values needed for the MVP release are documented accurately.

## HC-304

**Title:** Add a known limitations and deferred-features document for the first release

**Milestone:** M3 Tester Handoff

**Priority:** P0

**Suggested labels:** `docs`, `release`, `p0`

**Depends on:** HC-005, HC-112

Summary:

Publish a clear statement of intentional limitations so testers can separate expected omissions from regressions.

Deliverables:

- Known limitations document.
- Explicit deferred feature list.

Acceptance Criteria:

- Deferred protocol families and product gaps are easy to find.
- The document matches the actual first-release scope.

## HC-305

**Title:** Publish the tester smoke script and scenario matrix with the release

**Milestone:** M3 Tester Handoff

**Priority:** P0

**Suggested labels:** `docs`, `tests`, `tester-readiness`, `p0`

**Depends on:** HC-119, HC-205, HC-302

Summary:

Ship the exact evaluation steps testers should follow, including install verification, connect, messaging, restart, and log capture.

Deliverables:

- Tester scenario matrix.
- Included smoke script or checklist.

Acceptance Criteria:

- Testers have a concrete evaluation sequence to follow.
- The scenario matrix matches the supported MVP workflow and sample data.

## HC-306

**Title:** Add a feedback and bug-report template for tester builds

**Milestone:** M3 Tester Handoff

**Priority:** P0

**Suggested labels:** `docs`, `release`, `p0`

**Depends on:** HC-209, HC-303, HC-305

Summary:

Define what testers must include when reporting issues so the first wave produces actionable bug reports.

Deliverables:

- Bug-report template or issue form.
- Guidance on logs, version identifiers, and repro steps.

Acceptance Criteria:

- Reports request version, environment, steps, expected result, actual result, and logs.
- Maintainers can triage first-wave reports without basic follow-up questions.

## HC-307

**Title:** Add a maintainer support playbook for tester setup and repro failures

**Milestone:** M3 Tester Handoff

**Priority:** P1

**Suggested labels:** `docs`, `devex`, `p1`

**Depends on:** HC-303, HC-306

Summary:

Create a lightweight internal playbook for responding to setup failures and collecting the right diagnostic data quickly.

Deliverables:

- Support checklist for maintainers.
- References to logs, health checks, and reset steps.

Acceptance Criteria:

- Internal support steps are documented.
- The playbook reduces ad hoc triage work during the tester wave.

## HC-308

**Title:** Decide whether testers use self-hosted or centrally hosted environments

**Milestone:** M3 Tester Handoff

**Priority:** P1

**Suggested labels:** `planning`, `release`, `tester-readiness`, `p1`

**Depends on:** HC-001, HC-004, HC-302

Summary:

Choose whether testers run their own PostgreSQL and server or connect to a centrally managed environment so onboarding instructions stay internally consistent.

Deliverables:

- Environment model decision.
- Matching updates to onboarding docs.

Acceptance Criteria:

- The onboarding path does not mix incompatible environment assumptions.
- Support expectations match the chosen tester environment model.

## HC-309

**Title:** Add screenshots or lightweight walkthrough assets if the MVP UI is stable enough

**Milestone:** M3 Tester Handoff

**Priority:** P2

**Suggested labels:** `docs`, `ui`, `p2`

**Depends on:** HC-302, HC-304

Summary:

If the MVP client UI has stabilized, add a small set of screenshots or walkthrough assets that help testers orient themselves without promising unsupported features.

Deliverables:

- Screenshots or equivalent visual aids.
- Captions aligned with the supported flow.

Acceptance Criteria:

- Visual assets reflect the actual release UI.
- They do not imply support for deferred functionality.
