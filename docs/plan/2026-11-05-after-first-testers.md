# HayChat: after the first tester round (2026-11-05)

Follows `docs/plan/2026-11-05-user-testing-readiness.md`, whose packages A–G all merged and
produced the pre-release `v0.1.0-rc1`. Testers followed `docs/tester-guide.md` against an rc1
server and reported no significant problems. Text rooms and direct messages work.

That changes one thing about every later change: **the tester server now holds data that
people care about.** Today a server whose schema check fails drops every HayChat table and
recreates them empty (`databaseEnsureSchema` in `server/database.odin`), so the first schema
change would wipe the testers' accounts, rooms and history. Migrations therefore come before
any change to the schema.

Read this whole file, `AGENTS.md`, `client/AGENTS.md` and `server/AGENTS.md` before starting
a package. Voice packages also read `docs/plan/voice-rooms-design.md` in full.

## Goals for this phase

1. Upgrades keep data: schema migrations, no automatic drops (M1).
2. Unread state that survives a restart and follows the user across devices, for rooms and
   direct messages (B3). The tester guide currently has to explain that unread counts reset.
3. Voice rooms, the stretch goal of the last plan, built in the PR-sized steps H1–H8 of
   `docs/plan/voice-rooms-design.md` section 7. H0 already landed as PR #8.
4. Fix the latent `IPC__route_to` bug noted in PR #8 before voice depends on that path.

## Decisions on the voice design's open questions

The lead first adopted the recommendation of every question in `voice-rooms-design.md`
section 8 so work could start. The maintainer answered them on 2026-11-05; this table records
those answers, and packages follow it.

| # | Decision |
| --- | --- |
| Q1 | Every room carries voice in v1. After v1, admins can turn voice off per room and change a room's type; that needs a migration and admin UI (package A4, later). |
| Q2 | **One voice session per user.** The participant list shows each user once, and a newer join replaces the user's older voice session (package V1). The automatic re-join after a reconnect stays; it only replaces a stale session of the same device, never another device's voice. Built first as one session per device (H3/H5/H6); V1 changes that. |
| Q3 | Push-to-talk works while the window has focus. Voice activity is the default mode. A global hotkey can come later. |
| Q4 | Opus DTX off; the VAD gate covers silence. |
| Q5 | Constrained VBR, 24 kbit/s by default, and the bitrate setting capped at 64 kbit/s (confirmed by the maintainer). |
| Q6 | No noise suppression or echo cancellation in v1. The tester guide recommends headphones. |
| Q7 | Hop-by-hop encryption, as for chat (left to the lead). The binary envelope leaves room for end-to-end keys later. |
| Q8 | The network thread owns each peer's voice crypto state and relays frames (`VoiceRelay`). Voice frames never pass through the router, the IPC queues or the database. |
| Q9 | Voice counters (frames in, out and dropped; rooms; participants) on web admin `/status`. |
| Q10 | Windows release archives ship `libopus-0.dll` next to `SDL3.dll`, **with every third-party credit its licence requires**. Package L2 audits all release artifacts and completes the notices. |

## Coordination rules

- **Protocol version.** `common.protocolVersion` is 8 on `main`. H1 takes 9. Every later
  package that changes a payload or `MessageType` takes the next free number when it is
  rebased for merge, and keeps `common/protocol_test.odin` green (append enum members at the
  end, pin every member put on the wire, never renumber).
- **Schema version.** M1 introduces the migration list. Migration 1 is the schema `main` has
  today (identical to `v0.1.0-rc1`). B3 adds migration 2. Voice adds no migration (Q1). Never
  edit a migration that has merged; add a new one.
- **One PR per package** on Forgejo `jim/haychat`, from the package's own worktree and branch.
  Agents do not merge; the lead reviews, waits for CI and the `proval` review bot, merges and
  closes the PR.
- **Dev pod.** The lead owns the shared dev pod (`./dev.sh up`, `down`, `reset`, `restart`,
  `seed`, `client`). Agents use only throwaway containers: `./dev.sh check`, `live`, `ci` and
  `shell`, which are safe to run concurrently.
- **Verification.** `./dev.sh check` while editing, `./dev.sh live --all` for anything that
  touches the wire or the database, and `./dev.sh ci` on the final tree before the PR.
- **Commits.** Imperative subject, a body that explains why, and the trailer
  `Co-Authored-By: <the model that wrote it> <noreply@anthropic.com>`. PR descriptions end
  with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.

## Work packages

### M1. Server: schema migrations (`server-schema-migrations`, first)

- A `schema_migrations` table (one row per applied migration: version, name, applied time)
  and an ordered, append-only list of migrations in the server. Migration 1 is today's schema.
- Startup, in one transaction under a PostgreSQL advisory lock so two servers cannot migrate
  at once:
  - An empty database gets every migration.
  - A database with HayChat tables but no `schema_migrations` (every rc1 and dev database) is
    adopted: migration 1's idempotent statements run (they already upgrade protocol 7
    databases in place), the schema is validated, and version 1 is recorded. No row is lost.
  - A recorded version below the newest known one gets the missing migrations in order.
  - A recorded version above the newest known one, or a database that fails validation,
    stops startup with a `[Startup]` error and exit status 1 that says what is wrong and how
    to restore a backup or reset. **The server never drops tables on its own again.**
- Validation after migrating stays, as a safety net, checked against the newest schema.
- Tests: the migration list is gapless and ordered; SQL tests (gated like the existing ones
  and added to `SQL_TESTS` in `dev/live-proof.sh`) for a fresh database, an rc1-shaped
  database full of rows (accounts, roles, rooms, members, room messages, direct messages)
  that keeps every row, a protocol 7 `rooms` table, a second start being a no-op, a future
  version being refused, and an unrecognisable database being refused with its tables and
  rows intact.
- Docs: README Database section and Known Limitations, `deploy/README.md` (Upgrades,
  Backup), `server/AGENTS.md` (how to add a migration), `docs/tester-guide.md` if it mentions
  data loss.

### H1. Transport: per-channel keys and replay window (`transport-channel-crypto`)

`voice-rooms-design.md` section 3.2 and the `common` rows of section 6.1: four HKDF keys,
per-channel send and receive state, the 64-packet replay window, channel-bound AAD, the
deterministic voice nonce, `sealVoiceDatagram`/`openVoiceDatagram`,
`TransportState_takeVoiceState`, and check-then-commit for the control channel. Protocol 9.
Client and server compile against the new `TransportState` with the control path unchanged
in behaviour; nothing is sent on the Voice channel yet.

### H4. Client: audio and Opus foundation (`client-voice-audio`)

`voice-rooms-design.md` sections 1, 2, 5.2 and 6.1 (client rows): the `client/opus` binding
loaded with `core:dynlib`, `VoiceEngine` with device, file and tone sources and device, file
and null sinks, the jitter buffer, VAD and push-to-talk gate, a local loopback mode, and the
test-only frequency check. No networking. `opus` joins `dev/install-packages.sh`; release
archives get the Windows DLL (Q10) and the Linux runtime dependency note.

### L1. Server: `IPC__route_to` for `Main` senders (lead)

`IPC__route_to` switches on `typeid_of(type_of(msg))`, which is always `Message`, so a `Main`
endpoint that uses `IPC_Client_send` routes nothing. Use a type switch on the union and add a
test.

### B3. Read state for rooms and direct messages (`read-state`, after M1)

- Migration 2: per-user read markers for rooms and for direct conversations (last read
  message ID), with foreign keys that cascade when a room or an account goes away.
- Protocol: the client marks a conversation read up to a message ID (markers only move
  forward); the server stores it and tells the user's other sessions. The room list and the
  direct conversation list carry each conversation's unread count (messages from others
  after the marker) and marker, so a client starts with correct badges.
- Client: unread badges for rooms as well as direct messages; opening a conversation, or
  receiving a message while it is open, marks it read; a read on another device clears the
  badge here. Harness commands and events for read state, and a live proof that a badge
  survives a reconnect and clears on a second session.
- Docs: README, `docs/tester-guide.md` (remove "unread counts start at zero"),
  `docs/testing-harness.md`.

### Voice H2–H8 (in order; see `voice-rooms-design.md` section 7)

H0–H8 are implemented (H0 in PR #8, H1–H7 in their own PRs, H8 in two parts).

| Step | Branch | Starts after | Status |
| --- | --- | --- | --- |
| H2 voice wire format and control protocol | `voice-wire-protocol` | H1 | Implemented |
| H3 server voice: router control plane and network-thread relay | `server-voice-relay` | H2, L1 | Implemented |
| H5 client voice networking and actions | `client-voice-networking` | H3, H4 | Implemented |
| H6 client voice UI | `client-voice-ui` | H5 | Implemented |
| H7 harness commands and live voice proof | `voice-live-proof` | H5 | Implemented |
| H8a voice hardening | `voice-hardening` | H6, H7 | Implemented |
| H8b manual test kit and tuning | `voice-manual-test-kit` | H6, H7 | Implemented: `dev/voice-manual-test.sh`, `docs/voice-manual-test.md` |

H8 also takes two jitter buffer edges from the review of PR #17: `JitterBuffer_endSpurt`
may clip the start of a spurt after a fast push-to-talk re-press, and a spurt that starts
from idle after a sender restart may keep a high `hasTransit`-based depth for a few spurts.
H8 adds a test or a manual checklist item for each.

### V1. One voice session per user (`voice-single-session`, after H8a)

Q2: the participant list shows each user once, and a newer voice session of the same user
replaces the older one. A manual join from another device takes over and the older session gets
`ServerVoiceLeft` ("joined voice on another device"). An automatic re-join after a reconnect only
replaces a session of the same device (a stale session the server has not timed out yet); it
never takes voice away from another device. That needs a per-device ID the server can compare,
and a protocol bump.

### L2. Third-party notices in every release artifact (`release-notices`)

Q10: every artifact ships the notices its contents require. Found on 2026-11-05: the server
archive and image compile in `odin-http` and the `pg` bindings (both MIT) but ship only
HayChat's licence, and the Windows client ships FreeType inside `SDL3_ttf.dll` without the
FreeType licence's required credit sentence. Opus, SDL3, SDL3_ttf, HarfBuzz, PlutoSVG, PlutoVG,
ENet, Inter and Twemoji are already covered. A follow-up (#28) adds the code SDL compiles into
`SDL3.dll`: HIDAPI (under its BSD option, the maintainer's choice), yuv2rgb and SDL's fdlibm
notice, and pins `SDL3.dll`'s hash so that an SDL update makes the licence check fail until
someone re-reads what the new SDL bundles.

### A4. Room voice settings and room types (later, after v1)

Q1: admins turn voice off per room and change a room's type. Needs a migration, a protocol
change, server enforcement in the voice join path, and admin UI.

## Status (2026-11-05, evening)

Every package of this phase except A4 has merged:

| Package | PR | Merged as |
| --- | --- | --- |
| L1 `IPC__route_to` | #14 | 4d636c8 |
| H1 per-channel keys (protocol 9) | #15 | fbce66f |
| M1 schema migrations | #16 | 80ef1c8 |
| H4 audio and Opus | #17 | 53aa456 |
| H2 voice wire format (protocol 10) | #18 | d2807c6 |
| B3 read state (protocol 11, migration 2) | #19, polish #21 | e357351, 6f522f6 |
| H3 server voice relay | #20 | c1559f4 |
| H5 client voice networking (protocol 12) | #22 | 60d3d3d |
| H7 harness voice and live proof | #23 | 3267cad |
| H6 voice UI and settings | #24 | c484ed7 |
| H8a voice hardening | #25 | 30a3725 |
| L2 release notices | #26, follow-up #28 | f047c5c, 6227cf3 |
| V1 one voice session per user (protocol 13) | #27 | 8534308 |
| H8b manual voice test kit | #29 | 08d4521 |

## Follow-ups

Found while building and reviewing this phase; none blocks a release candidate.

- **Voice gate look-back.** The gate drops the frame that opens it, so each talk spurt loses
  about 20 ms of its first word (H8b measured it). Sending the frame before the opening one, a
  one-frame look-back in the engine, would recover it without the false openings of a
  one-frame attack.
- **Headless client and SIGTERM.** With SDL audio open, the headless client turns SIGTERM into
  an SDL quit event that its loop never reads, so it keeps running; scripts close its stdin
  instead. It should exit on SIGTERM.
- **SDL disk-driver voice proof timing.** One `./dev.sh ci` run during H8b failed the SDL
  disk-driver stage of `dev/voice-proof.sh` (65 late frames, 1.24 s of tone) and passed on the
  rerun. Watch it in CI and loosen or fix it if it fails again.
- **Windows voice checklist.** `docs/voice-manual-test.md` has the checklist; it needs a person
  on Windows before the release notes can say voice works there.
- **A4** (above), after v1.

## Release

`v0.1.0-rc2` can be tagged from `main` once its CI is green; tagging is the maintainer's call.
That server adopts an rc1 database in place (migration 1) and adds read markers (migration 2).
The protocol is now 13, so every tester must update the client together with the server; the
release notes must say so, and that voice is new (Linux tested, Windows unchecked by hand).
