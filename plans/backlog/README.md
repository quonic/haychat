# HayChat Tester-Ready Milestone Backlog

This backlog converts the critical-path plans into milestone-sized execution slices with issue-sized
tasks. It is intentionally biased toward a first tester release that proves one real end-to-end text
chat workflow on a reproducible setup for the supported first-wave platform matrix.

## Release Target

- Primary target: Linux and Windows support for both server and client.
- First evaluable scenario: start PostgreSQL, start server, start two clients, authenticate, exchange text messages, restart cleanly, collect logs.
- Deferred from this backlog unless needed to unblock the first release: voice, video, screenshare,
  forum flows, rich presence, macOS support, and polished URL scheme integration.

## Milestone Order

1. [M0-release-scope-gate.md](M0-release-scope-gate.md): lock the release contract and prevent scope drift.
2. [M1-mvp-chat-flow.md](M1-mvp-chat-flow.md): make the end-to-end chat path real and stable enough to test.
3. [M2-reproducible-release-candidate.md](M2-reproducible-release-candidate.md): make setup, validation, and packaging repeatable.
4. [M3-tester-handoff.md](M3-tester-handoff.md): document, package, and support the tester wave.

## How To Use This Backlog

- Treat each `HC-###` item as an issue-sized unit of work.
- Use milestone exit criteria as the go/no-go gate for starting the next milestone.
- Pull `P0` tasks first; do not start `P1` or `P2` items that depend on unresolved `P0` decisions.
- Keep `HC-118`, `HC-119`, `HC-206`, and `HC-305` as release-gate tasks that must stay green as the backlog advances.

## Priority Legend

- `P0`: blocks tester readiness directly.
- `P1`: needed for a practical handoff but can follow once the core path works.
- `P2`: useful follow-up if time remains before the first tester wave.

## Dependency Summary

- M0 unlocks M1 and constrains packaging and docs.
- M1 provides the real product flow that M2 automates and M3 documents.
- M2 produces the repeatable artifact and validation flow needed before M3 can complete.
- M3 closes the loop with tester instructions, fixtures, and reporting.

## Release Gate Checklist

- MVP scope frozen and documented.
- End-to-end connect/auth/message flow works on a clean setup.
- Startup and failure modes are actionable.
- Bootstrap, reset, and validation commands are reproducible.
- A release artifact or clearly supported source-based handoff exists.
- Quickstart, troubleshooting, known limitations, and tester guide exist.
- Smoke validation is run on the exact artifact handed to testers.

## GitHub Issue Drafts

- [github-issues/README.md](github-issues/README.md): issue draft index and usage notes.
- [github-issues/M0-release-scope-gate.md](github-issues/M0-release-scope-gate.md): issue drafts for release-definition decisions.
- [github-issues/M1-mvp-chat-flow.md](github-issues/M1-mvp-chat-flow.md): issue drafts for the first real end-to-end chat flow.
- [github-issues/M2-reproducible-release-candidate.md](github-issues/M2-reproducible-release-candidate.md): issue drafts for reproducible setup, validation, and packaging.
- [github-issues/M3-tester-handoff.md](github-issues/M3-tester-handoff.md): issue drafts for docs, onboarding, and tester support.
