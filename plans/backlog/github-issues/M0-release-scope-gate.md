# M0 Release Scope Gate: GitHub Issue Drafts

## HC-001

**Title:** Define first tester cohort for the tester-ready release

**Milestone:** M0 Release Scope Gate

**Priority:** P0

**Suggested labels:** `planning`, `release`, `tester-readiness`, `p0`

**Depends on:** None

Summary:

Decide whether the first tester wave is internal-only, trusted external, or mixed so packaging, docs, and support expectations are scoped correctly.

Deliverables:

- One written decision on the intended tester cohort.
- A short note describing how that choice affects support expectations and release format.

Acceptance Criteria:

- The intended tester cohort is documented in the release planning docs.
- Later packaging and onboarding work references the same cohort without ambiguity.

## HC-002

**Title:** Freeze the supported platform matrix for the first tester wave

**Milestone:** M0 Release Scope Gate

**Priority:** P0

**Suggested labels:** `planning`, `release`, `tester-readiness`, `p0`

**Depends on:** HC-001

Summary:

Lock the supported platforms for the first release so implementation and packaging work can target a real matrix instead of an aspirational one.

Deliverables:

- A documented first-wave matrix.
- Explicit out-of-scope notes for unsupported platforms.

Acceptance Criteria:

- Linux and Windows support are confirmed for both server and client.
- macOS is explicitly marked unsupported for the first tester wave.

## HC-003

**Title:** Freeze the MVP evaluator workflow for the first release

**Milestone:** M0 Release Scope Gate

**Priority:** P0

**Suggested labels:** `planning`, `release`, `tester-readiness`, `p0`

**Depends on:** HC-001, HC-002

Summary:

Define the exact first-release workflow testers must be able to complete: install, configure, authenticate, exchange text messages, restart cleanly, and inspect logs.

Deliverables:

- A written MVP workflow.
- A list of explicit non-goals for the first release.

MVP workflow (release gate):

1. Install required dependencies and build server and client from source on a supported OS.
2. Configure PostgreSQL and HayChat server/client settings using the documented sample values.
3. Start PostgreSQL and the HayChat server, then verify the server stays healthy at startup.
4. Start two HayChat clients and authenticate both with documented test identities.
5. Exchange at least one text message from client A to client B through the server.
6. Restart server and clients on a clean run, then repeat authentication and one message round trip.
7. Collect and inspect server and client logs for startup, auth, message, and restart events.

Explicit first-release non-goals:

- Voice, video, and screensharing flows.
- Forum-style and other long-form social content.
- Rich presence and broad social graph features.
- macOS support.
- Polished URL scheme integration.
- Any feature path not required to complete the release-gate workflow above.

Acceptance Criteria:

- The first-release flow is short, concrete, and tester-evaluable.
- Deferred features are named explicitly and removed from the release-critical path.

## HC-004

**Title:** Decide whether the first handoff is source-based, packaged, or both

**Milestone:** M0 Release Scope Gate

**Priority:** P0

**Suggested labels:** `planning`, `release`, `packaging`, `p0`

**Depends on:** HC-001, HC-002

Summary:

Choose the supported delivery model for the first tester wave so setup, packaging, and documentation can be planned against a stable target.

Decision:

- Source-based only for the first tester wave.

Rationale:

- The current project and plan assumptions already target internal-only testers compiling from source.
- Deferring packaged binaries keeps first-wave support expectations realistic while allowing packaging and onboarding work to proceed against one stable model.

Deliverables:

- A handoff model decision.
- A brief rationale for why that model is acceptable for the first release.

Acceptance Criteria:

- The first tester handoff model is documented.
- Packaging and onboarding tasks can proceed without re-opening this decision.

## HC-005

**Title:** Define included versus deferred feature families for the first release

**Milestone:** M0 Release Scope Gate

**Priority:** P1

**Suggested labels:** `planning`, `release`, `p1`

**Depends on:** HC-003

Summary:

Separate the MVP text-chat release from the wider protocol surface so the backlog does not drift toward voice, video, forum, or richer social features.

Deliverables:

- A release-scope list.
- A deferred-features list.

Acceptance Criteria:

- The release scope stays aligned with the MVP evaluator workflow.
- Deferred features are visible in planning and later release notes.

## HC-006

**Title:** Create a canonical release decision record for the tester-ready milestone

**Milestone:** M0 Release Scope Gate

**Priority:** P1

**Suggested labels:** `planning`, `release`, `docs`, `p1`

**Depends on:** HC-002, HC-003, HC-004

Summary:

Capture the release contract in one canonical document so later implementation, packaging, and onboarding tasks can refer back to a single baseline.

Deliverables:

- A short release decision record.
- Cross-links from backlog and plan files.

Acceptance Criteria:

- Scope, platform, and handoff model decisions are all captured in one reference.
- The team can point to a single document to resolve scope drift.
