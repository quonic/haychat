# Phase 0: Product Readiness

## Objective

Define the smallest HayChat release that internal-only testers can compile from source, run, and
evaluate with limited support.

## Current State

- The repo compiles and has passing `server` and `common` tests.
- The README is high-level and does not contain a practical quickstart.
- `docs/` is empty.
- The protocol surface is much broader than the implemented user flow.
- The client UI and server architecture exist, but the tester story is not yet narrowed to a concrete supported scenario.

## Assumptions

- The first tester cohort is internal-only.
- Support for the first wave is limited to "does it work or not?" triage.
- The first release format is source-based and expects testers to compile from source.
- The first tester wave should prioritize Linux because the client Linux target is already checked and server paths are Linux-oriented.
- Windows can be kept as a secondary target if packaging is cheap.
- A first tester build only needs one successful core scenario: start server, start two clients, authenticate, and exchange text messages.

## Dependencies

- Inputs from [02-core-functionality.md](02-core-functionality.md) on the actual MVP flow.
- Inputs from [06-deployment-packaging.md](06-deployment-packaging.md) on what can be distributed.
- Inputs from [08-tester-onboarding.md](08-tester-onboarding.md) on what testers must do manually.

## Prioritized Tasks

1. Keep the tester persona for the first release internal-only.
2. Freeze the supported matrix for the first wave: server on Linux, client on Linux, optional Windows client.
3. Define the minimum evaluable workflow and explicitly exclude everything else from release scope.
4. Write a release checklist that requires build success, smoke validation, docs, known limitations, and onboarding assets.
5. Keep the first release handoff source-based so testers compile from source.
6. Publish a short list of features intentionally deferred until after feedback.

## Risks

- If scope is not frozen early, the large protocol surface in `common/protocol.odin` will keep pulling work away from tester readiness.
- If external testers are included too early, packaging, documentation, and support requirements expand sharply.
- If Linux and Windows are both treated as mandatory on day one, delivery risk increases for no clear tester value.

## Open Questions

- Is the first release intended to validate networking and chat only, or also file upload and web admin?
- Are testers expected to self-host PostgreSQL, or should the release bundle its runtime dependencies?
- What minimum build and run commands must be documented so internal testers can compile reliably?

## Exit Criteria

- A written release definition exists and is accepted by the maintainers.
- The supported OS and install model are fixed for the first wave.
- The MVP workflow is explicit, and all non-MVP features are marked deferred.
- Every later plan file can trace its tasks back to this release definition.

## Recommended Execution Order

- Start first.
- Complete before committing to packaging or external tester outreach.
- Revisit only if [02-core-functionality.md](02-core-functionality.md) exposes that the chosen MVP is still too large.
