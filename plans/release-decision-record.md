# M0 Tester-Ready Release Decision Record

## Status

- Accepted baseline for milestone M0 release-scope gate.

## Canonical Decisions

### Scope (release gate workflow)

- Build server and client from source on a supported platform.
- Configure PostgreSQL plus HayChat server/client settings.
- Start PostgreSQL, start one server, and start two clients.
- Authenticate both clients and exchange text chat messages.
- Restart cleanly and verify startup/auth/message behavior in logs.

### Platform matrix

- Supported for first tester wave: Linux and Windows (server and client).
- Not in first-wave scope: macOS.

### Handoff model

- First-wave delivery is source-based only (no packaged binaries).
- Target cohort is internal-only testers.
- Support expectation is limited to "does it work or not?" triage.

## Notes For Downstream Milestones

- Use this file as the single baseline when implementation, packaging, and onboarding tasks conflict.
- Any scope changes should update this record first, then update dependent plan/backlog documents.
