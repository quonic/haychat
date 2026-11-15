# HayChat: implementing end-to-end encryption (2026-11-14)

Implements `docs/plan/e2ee-design.md` (merged in #57; every open question decided, section 10).
`main` is at protocol 14 and schema migration 3.

Read this whole file, the design, `AGENTS.md`, `client/AGENTS.md` and `server/AGENTS.md`
before starting a package. The design is the specification: where this file and the design
disagree, this file wins; where the design is silent or wrong, decide, say so in the PR, and
keep going.

## Packages

One PR per package, from its own worktree and branch. The order follows the design's section
13.

| Package | Branch | Design sections | Starts after |
| --- | --- | --- | --- |
| E0 Primitives | `e2ee-primitives` | 4.1–4.4, 3.5, 6.2 (encoding and replay), 6.3, 6.5, 9.1 last paragraph, 12.1 | – |
| E3 Room access modes | `room-access-modes` | 5, 9.1 (E3 row), 9.2 (E3 row), 12.2 (access modes), 12.4 step 8 without encryption | – |
| E1 Account keys | `e2ee-account-keys` | 2, 3, 9.3, 12.3 (key store, pins) | E0 |
| E2 Encrypted direct messages | `e2ee-direct-messages` | 4.5, 4.6, 7.2–7.4 for direct messages, 12.4 steps 1, 2, 6 (DMs), 7 | E1 |
| E4 Encrypted rooms | `e2ee-rooms` (may split E4a `e2ee-room-log`, E4b `e2ee-room-chains`) | 6.1–6.7 except Full history forwarding, 12.4 steps 3–6, 8 (From join), 9 | E2, E3 |
| E5 Full history in encrypted rooms | `e2ee-full-history` | 6.6 (Full history), 12.4 step 8 (Full history) | E4 |
| E6 Voice in encrypted rooms | – | 8 | E4; needs its own design note first (not this round) |

E0 and E3 start in parallel from `main`. E1 starts when E0 merges and runs alongside E3.

## Coordination rules

- **Protocol and schema numbers are taken at merge time.** The design's numbers (protocol
  15–19, migrations 4–7) assume the order E1, E2, E3, E4. Because E3 runs in parallel with
  E0–E2, a package takes the next free `protocolVersion` and the next free migration version
  when it rebases onto `main` before its PR merges. New `MessageType` members always go at the
  end of the enum, each pinned in `common/protocol_test.odin`. Never edit a merged migration.
- **E0 changes no protocol and no schema.** It adds `common/e2ee.odin` and
  `common/e2ee_test.odin` only (plus docs). Its API is what E1–E5 build on: pure procedures on
  caller buffers, no globals, no allocation where the caller can pass a buffer, owned
  allocations documented with their `*_deinit`.
- **E3 is not encrypted.** It adds access modes and history visibility for every room; it does
  not add `encrypted`, the member log or managers (E4). It must leave room in
  `ClientCreateRoomPayload` and the create-room form for E4's **Encrypt this room** without
  shipping a control that does nothing.
- **Conflicts.** E1 and E3 both touch `common/protocol.odin`, `UserSummary` / `RoomSummary`,
  the client transport, the harness and the docs. Keep changes additive; the second to merge
  rebases and renumbers.
- **Agents do not merge.** The lead reviews, waits for CI, merges, and closes the PR.
- **Dev pod.** The lead owns the shared dev pod. Agents use only throwaway containers:
  `./dev.sh check`, `live`, `ci` and `shell`.
- **Verification.** `./dev.sh check` while editing, `./dev.sh live --all` for anything that
  touches the wire or the database, and `./dev.sh ci` on the final tree before the PR. Wait for
  it to finish before reporting.
- **Docs.** Each package updates the documents that describe the behaviour it changes (see
  `docs/README.md`): `docs/protocol.md` ("Not end-to-end"), the user guide,
  `docs/rooms-and-accounts.md`, `docs/client-configuration.md`, `docs/testing-harness.md`,
  and `client/AGENTS.md` / `server/AGENTS.md`. It does not rewrite the design document; it
  records departures from it in its PR and the lead adds them to the status below.
- **Crypto review.** Every package that seals, opens, signs or verifies gets a review pass by
  the lead focused on the byte layouts, AAD binding, nonce use, and that every verification
  failure is fatal and never silently retried (design 4.1).

## Status

| Package | PR | Merge | Protocol | Migration |
| --- | --- | --- | --- | --- |
| E0 Primitives | #58 | da6c708 | – | – |
| E3 Room access modes | #59 | 076cbe3 | 15 | 4 |
| E1 Account keys | #60 | dfe6759 | 16 | 5 |
| E2 Encrypted direct messages | #61 | c262e91 | 17 | 6 |
| E4a Encrypted rooms: member log | #62 | d908114 | 18 | 7 |
| E4b Encrypted rooms: sender chains | #63 | dd5c3ec | 19 | 8 |

E0's departures from the design are listed in #58: an explicit domain on the room message
signature, explicit wrap count and ciphertext length in the envelope, small-order X25519 keys
refused, i64 LE for every protocol `int`, a fixed binary sender-key distribution plaintext, the
member log's encoding details (format byte, settings only on `Create` and `SetAccess`, access
values 2/3 and history values 1/2), pins looked up but never written during log replay, and a
strict CBOR reader for the sealed plaintext. E5 must give `RoomKeyForward` its own AAD label.

E3's decisions are listed in #59. The main ones: `rooms.history_visibility` defaults to Full
for existing rooms (they are Public, and stay readable if later made invite-only); a
non-admin asking about a room it cannot see gets "Not a room member" whether or not the room
exists; removing or leaving also deletes the read marker; `ServerRoomMembershipChanged` gained
`userId` and goes to the room's members, so Members pages refresh live. Known limitation: the
Admin section's room list does not refresh when another admin changes a room this admin is
not in.

E1's decisions are listed in #60. The main ones: `ServerUserKeys` also lists
`missingUserIds`; `ServerUserKeyChanged` goes out on a first publish too, and clients apply a
pushed bundle only to users they already pinned; a different encryption key that is not newer
than the pin is refused (rollback); a fourth blocking state, InvalidKey, never changes the pin;
users are pinned on demand (opening a DM, the Verify dialog, the harness), never from the user
list alone; a headless profile saves its generated encryption key on first run; `saveConfig`
now writes atomically. E2 builds on `State_e2eePeerKeyInfo` and must encrypt to and verify
against the pinned keys it returns.

E2's decisions are listed in #61. The main ones: the database worker verifies a sealed DM
(it holds the recipient's identity key) and the insert requires that same key; unsigned
plaintext DMs are refused; an all-zero client message ID or signature means none (rows from
before protocol 17), and summaries carry `lastSignature`; a message from an unpinned sender
waits for a key fetch; only messages that opened count for replay detection, and the later
copy is shown as undecryptable; queued messages are never sent as plaintext; the key store
is format 2. Known limitation: the server could insert unsigned rows that look like
pre-upgrade messages ("Not encrypted"), but cannot forge encrypted or signed ones.

E4 is split in two, run one after the other: E4a `e2ee-room-log` (encrypted rooms, the
member log with managers, and refusing plaintext chat in encrypted rooms) and E4b
`e2ee-room-chains` (sender chains, distribution, key requests, sealed room messages, epochs).

E4a's decisions are listed in #62. The main ones: an encrypted room is created empty and the
creator's client appends the signed `Create` once `ServerCreateRoom` arrives (the entry must
name the server-assigned room ID); the server replays the whole stored log on every append
under a row lock, with `users.public_key` standing in for pins; `room_log_managers` lets
non-member managers fetch the log; `SetAccess` needs the admin role too and every signed
entry's actor must be the sender; `ClientAddRoomMember`/`ClientLeaveRoom` are refused on
encrypted rooms; an admin's `ClientRemoveRoomMember` becomes an unsigned `Remove` written by
the server; plaintext chat and voice in encrypted rooms are refused; key store format 3.
Known limitation: two clients on one profile directory overwrite each other's key store.

E4b's decisions are listed in #63. The main ones: sealed room messages ride on the existing
chat payloads (`clientMessageId`, `sealed`); signatures on sealed messages and key envelopes
are checked in the router against the session's identity key; the sending side of a chain is
never stored, so every client run starts new chains, and the server refuses a reused
`(sender, chain_id, chain_index)`; `ServerRoomKeys` answers a fetch in pages of 32 and only
with envelopes that wrap the requester; a key request is answered only by the chain's sender
and only for a member of that epoch; members without a usable pin get no wrap and can ask
later; key store format 4 (`room_chains`, a cache). Follow-up: a failed SQL test assertion
made the test runner hang instead of exit; `dev/live-proof.sh` needs a timeout.
