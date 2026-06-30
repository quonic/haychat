# M1 MVP Chat Flow: GitHub Issue Drafts

## HC-101

**Title:** Define the minimal runtime chat model for the first tester release

**Milestone:** M1 MVP Chat Flow

**Priority:** P0

**Suggested labels:** `planning`, `server`, `client`, `p0`

**Depends on:** HC-003

Summary:

Choose the smallest message topology that supports tester evaluation, such as one shared room or one simplified DM flow, instead of trying to implement the full room model.

Decision (MVP runtime topology):

- One shared global chat room for all authenticated users.
- `ClientChatMessage` is valid only for the shared room (`roomId = 1`).
- `ServerChatMessage` is broadcast by the server to all authenticated clients in that room.
- DM and dynamic room routing are deferred beyond the first tester release.

Client/server treatment notes:

- Client: set outgoing chat packets to `roomId = 1`; do not expose DM or room selection in the
  MVP path.
- Server: accept authenticated `ClientChatMessage` packets for `roomId = 1` and broadcast as
  `ServerChatMessage`; reject or ignore unsupported room IDs in the MVP path.

Deliverables:

- A concrete first-release message topology.
- Notes on how client and server should treat that topology.

Acceptance Criteria:

- There is one unambiguous MVP message path.
- Client and server work can target this path without reopening the room model.

## HC-102

**Title:** Add client network session orchestration for configured servers

**Milestone:** M1 MVP Chat Flow

**Priority:** P0

**Suggested labels:** `client`, `networking`, `p0`

**Depends on:** HC-101

Summary:

Move the client from passive transport metadata to an actual connection lifecycle that can initiate handshake and session setup for a configured server.

Deliverables:

- Client-side session orchestration around the existing transport code.
- Error propagation for handshake and connect failures.

Acceptance Criteria:

- A configured server can leave idle state and begin a real session attempt.
- Failures are visible in logs or the client UI.

## HC-103

**Title:** Implement the minimal real connect and authenticate flow

**Milestone:** M1 MVP Chat Flow

**Priority:** P0

**Suggested labels:** `client`, `server`, `auth`, `p0`

**Depends on:** HC-102

Summary:

Connect the client to the existing server handshake and auth flow so the client can reach an authenticated session using supported test identities.

Deliverables:

- Working connect and auth flow across client and server.
- Clear failure handling for rejected or broken auth attempts.

Acceptance Criteria:

- A client can reach authenticated transport state against a real server.
- The server keeps consistent authenticated session state.

## HC-104

**Title:** Implement server-side dispatch for MVP chat packets

**Milestone:** M1 MVP Chat Flow

**Priority:** P0

**Suggested labels:** `server`, `protocol`, `p0`

**Depends on:** HC-101, HC-103

Summary:

Teach the server to handle `ClientChatMessage` and produce `ServerChatMessage` for the selected MVP flow.

Deliverables:

- Post-auth server dispatch for MVP chat packets.
- Message routing behavior aligned with the chosen runtime model.

Acceptance Criteria:

- Authenticated chat packets are accepted.
- The server forwards or broadcasts messages correctly for the MVP scenario.

## HC-105

**Title:** Replace local-only chat append behavior with real send and receive handling

**Milestone:** M1 MVP Chat Flow

**Priority:** P0

**Suggested labels:** `client`, `ui`, `p0`

**Depends on:** HC-103, HC-104

Summary:

Stop simulating successful message delivery inside the UI state and render messages based on real network send and receive behavior.

Deliverables:

- Real send path from the chat UI.
- Real receive rendering for server-delivered messages.

Acceptance Criteria:

- Local UI no longer fakes successful delivery by default.
- Received messages are rendered distinctly and consistently.

## HC-106

**Title:** Add database bootstrap and test identity support for the MVP flow

**Milestone:** M1 MVP Chat Flow

**Priority:** P0

**Suggested labels:** `database`, `server`, `devex`, `p0`

**Depends on:** HC-003

Summary:

Provide a concrete bootstrap path for database state and sample identities so testers do not need to write raw SQL by hand to authenticate.

Deliverables:

- A bootstrap flow for required database state.
- Seeded or scripted test identity setup.

Acceptance Criteria:

- A fresh environment can create required auth data.
- Testers can authenticate without ad hoc database editing.

## HC-107

**Title:** Add startup preflight checks and actionable server failure messages

**Milestone:** M1 MVP Chat Flow

**Priority:** P0

**Suggested labels:** `server`, `stability`, `p0`

**Depends on:** HC-106

Summary:

Make common startup failures obvious by checking database reachability and writable runtime paths before the server reports itself as healthy.

Deliverables:

- Startup preflight checks.
- Improved failure logging for missing prerequisites.

Acceptance Criteria:

- Broken environments fail fast with actionable messages.
- Startup success implies the MVP environment is actually usable.

## HC-108

**Title:** Switch server defaults to tester-safe local runtime paths

**Milestone:** M1 MVP Chat Flow

**Priority:** P0

**Suggested labels:** `server`, `stability`, `devex`, `p0`

**Depends on:** HC-107

Summary:

Replace privileged default runtime paths with tester-safe local defaults so ordinary users can launch HayChat without manual `/var` setup.

Deliverables:

- Revised default path behavior.
- Alignment with future bootstrap and reset scripts.

Acceptance Criteria:

- A normal user can launch the local server without privileged filesystem prep.
- Runtime state is easy to inspect and reset.

## HC-109

**Title:** Review and fix Linux client config migration behavior

**Milestone:** M1 MVP Chat Flow

**Priority:** P1

**Suggested labels:** `client`, `stability`, `p1`

**Depends on:** None

Summary:

Verify that Linux config loading and legacy migration behavior are correct before they become part of the release story.

Deliverables:

- A reviewed and corrected migration path if needed.
- Tests or docs covering the final behavior.

Acceptance Criteria:

- Config path behavior is intentional and documented.
- No obvious broken migration logic remains in the tester path.

## HC-110

**Title:** Decide whether URL scheme registration is in scope for the first release

**Milestone:** M1 MVP Chat Flow

**Priority:** P1

**Suggested labels:** `client`, `desktop`, `p1`

**Depends on:** HC-003

Summary:

Either wire URL scheme support deliberately into startup or remove it from tester-facing expectations for the first release.

Deliverables:

- A scope decision.
- Implementation or release-note cleanup to match that decision.

Acceptance Criteria:

- Tester docs do not promise unsupported desktop integration.
- Any retained URL scheme behavior has a clear supported path.

## HC-111

**Title:** Scope or implement inbound network channel handling for the MVP path

**Milestone:** M1 MVP Chat Flow

**Priority:** P1

**Suggested labels:** `server`, `networking`, `protocol`, `p1`

**Depends on:** HC-101

Summary:

Resolve the remaining TODO in the supported networking path by either documenting chat-only semantics or implementing the minimal required channel behavior.

Deliverables:

- Clear channel behavior for the MVP release.
- Code or docs that remove ambiguity from the current network path.

Acceptance Criteria:

- The supported release path has no unexplained channel-handling gap.
- Networking docs and implementation match each other.

## HC-112

**Title:** Hide unfinished feature families from the first-release client experience

**Milestone:** M1 MVP Chat Flow

**Priority:** P1

**Suggested labels:** `client`, `ui`, `release`, `p1`

**Depends on:** HC-003

Summary:

Stop the client and release-facing docs from implying support for broad unfinished features such as friends, voice, video, or forums.

Deliverables:

- UI cleanup or gating for unfinished features.
- Release-facing wording aligned with the MVP.

Acceptance Criteria:

- Testers are guided toward the supported flow only.
- Deferred features are labeled clearly instead of appearing half-ready.

## HC-118

**Title:** Add automated integration coverage for the MVP connect/auth/message flow

**Milestone:** M1 MVP Chat Flow

**Priority:** P0

**Suggested labels:** `tests`, `client`, `server`, `p0`

**Depends on:** HC-103, HC-104, HC-105, HC-106

Summary:

Extend automated validation to cover the real release-critical path: startup, auth success, and one message round trip.

Deliverables:

- Automated tests or harnesses for the MVP flow.
- Clear failure output for regressions in connect, auth, or messaging.

Acceptance Criteria:

- The real MVP path is covered automatically.
- Regressions in the release path are detectable before packaging.

## HC-119

**Title:** Create a manual smoke checklist for the MVP tester path

**Milestone:** M1 MVP Chat Flow

**Priority:** P0

**Suggested labels:** `tests`, `docs`, `release`, `p0`

**Depends on:** HC-105, HC-107, HC-118

Summary:

Add a short manual smoke checklist for the exact first-release workflow so every handoff is validated the same way.

Deliverables:

- A concise smoke script.
- Coverage of startup, connect, send, receive, restart, and log capture.

Acceptance Criteria:

- Team members can run the checklist without tribal knowledge.
- The checklist matches the supported tester journey exactly.
