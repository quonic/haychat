# HayChat: admin interface, per-server settings, and context menus (2026-11-14)

Follows `docs/plan/2026-11-05-after-first-testers.md`, whose packages all merged, plus #30
(web admin removed) and #48 (global push-to-talk). `main` is at protocol 13 and schema
migration 2.

Read this whole file, `AGENTS.md`, `client/AGENTS.md` and `server/AGENTS.md` before starting a
package.

## Goals

1. **Context menus.** Right-click menus on channels, direct-message rows, members, voice
   participants, chat messages and sender names, the server rail, and text fields. Today the
   UI toolkit has no popups at all.
2. **Server settings (per-server user settings).** One screen per server, opened from the
   server's right-click menu and the sidebar header, with settings that apply only to that
   server: its label, address and key, a display name for that server only, and a voice
   volume and local mute per user (#47). Kept in the client's `config.json`, so they are not
   synced between devices (maintainer decision 2026-11-14).
3. **Admin interface.** An Admin section in the same screen, shown to admins only, plus admin
   entries in the context menus:
   - grant and revoke the admin role from the client, pushed live to the target's sessions
     (#41);
   - admin rename (the admin half of #42);
   - kick, ban and unban an account;
   - per-room type, text / voice / both (#39, package A4 of the last plan).

Out of scope this round (maintainer decision 2026-11-14): private rooms and member management
(#40), closed sign-up and `ClientRegister` (#43), moving an account to another key (the rest of
#42), and server-side message edit and delete. The message menu offers only client actions.

## Decisions

| #   | Decision                                                                                                                                                                                                                                                                                                                                                                         |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| D1  | Per-server settings are client-local (`Server` entries in `config.json`). No protocol change for them.                                                                                                                                                                                                                                                                         |
| D2  | A per-server display name overrides `display_name` for that server only. The transport connects with it, so changing it renames the account on that server only.                                                                                                                                                                                                                 |
| D3  | Admin rename **locks** the account's nickname (`users.nickname_locked`): while locked, a login keeps the account's name whatever the client asks for, so the next connection does not undo the rename. `ServerAuthSuccess.nickname` (new) tells the client its real name; the client shows it in Server settings as set by an admin. An admin can unlock it again. |
| D4  | A ban is per account (`users.banned_at`, `users.ban_reason`). The server ends every session of the account and refuses its sign-in with a fixed failure the client treats as not retryable. Since sign-up is open, a banned person can still connect with a new key as a new account; the docs say so, and closed sign-up (#43) is the fix.                                         |
| D5  | Kick ends every session of the account with a reason. The client treats it as not retryable until the user presses Retry, so a kick is not undone by the next automatic reconnect a second later.                                                                                                                                                                              |
| D6  | Admin actions are refused with `ServerProtocolError` for: yourself as the target of kick, ban or role revoke (renaming yourself is allowed), another admin for kick and ban (revoke the role first), and a revoke that would leave the server with no admin.                                                                                                                                           |
| D7  | `UserSummary` gains `isAdmin` and `isBanned`, visible to every account (banned accounts stay listed because history names them). A role, ban or admin rename sends a new `ServerUserUpdated` with the full `UserSummary` to every authenticated session, so user lists update in place.                                                                                         |
| D8  | Role changes made directly in the database (`deploy/sql/make-admin.sql`) still show only on the next connection. The live push covers changes made from the client. LISTEN/NOTIFY is left for later.                                                                                                                                                                              |
| D9  | Room type reuses `common.RoomType` with only `Chat`, `Voice` and `ChatAndVoice` accepted (`Container` and `Forum` are refused). Existing rooms become `ChatAndVoice`. A voice-only room refuses chat posts and has no composer; a text-only room refuses voice joins ("voice is disabled in this room"). Changing a room to text-only removes its voice participants with `ServerVoiceLeft`. |
| D10 | Context menus are built from pure view models (`buildContextMenu…` in `client/context_menu.odin`) so the entries and their enabled state are testable without a window. The toolkit part (`client/ui/overlay.odin`) knows nothing about HayChat.                                                                                                                             |

## Packages

Four PRs. P1, P2 and P3 start in parallel from `main`. P4 starts after all three merge.

| Package                  | Branch                   | Touches                                    | Protocol | Migration |
| ------------------------ | ------------------------ | ------------------------------------------ | -------- | --------- |
| P1 Context menus         | `ui-context-menus`       | `client/ui`, client views, `ui_script.odin` | –        | –         |
| P2 Server settings       | `server-user-settings`   | client config, settings, voice engine      | –        | –         |
| P3 Admin server+protocol | `admin-server-protocol`  | `common`, `server`, client transport, harness | 14       | 3         |
| P4 Admin UI              | `admin-ui`               | client views, menus, settings, smoke test  | –        | –         |

### P1 Context menus (client only)

Toolkit (`client/ui`, no HayChat types):

- An overlay layer: `ui.beginOverlay(ctx, id, rect)` / `ui.endOverlay(ctx)` draw widgets on top
  of everything else. The overlay's rect from the previous frame blocks the pointer for every
  widget outside the overlay (`mouseOver` returns false for them while the pointer is inside
  it), so a click on a menu item never also hits the row under it. Wheel input is blocked the
  same way.
- `ui.contextMenuRequested(ctx, id, rect) -> bool`: the right button went down over `rect`
  this frame (honouring clip rects and the overlay). The caller records what was clicked.
- A menu: `ui.menuBegin(ctx, id, anchor, itemCount…)`, `ui.menuItem(ctx, label, enabled,
  danger) -> bool`, `ui.menuSeparator`, `ui.menuEnd`. Kept inside the window (flip left or up
  at the edges), sized to its widest label. Closes on an item click, a press outside it (that
  press is consumed, not passed to the widget under it), Esc, window focus loss, and when its
  target disappears. Keyboard: Up/Down move, Enter activates.
- Menu labels go through the automation text hook (so `click "Copy message"` works) and each
  item has a stable ID.
- Tests in `client/ui/ui_test.odin` for the pure parts: placement inside the window and
  blocking (`overlayBlocks`).

Client:

- `State.contextMenu`: the open menu's target, a tagged union (channel, conversation, member,
  voice participant, message, sender name, server, text field) with server ID, room or user
  ID, message ID, and the click position. The view records the target when
  `ui.contextMenuRequested` fires; `viewContextMenu`, called last in `viewApp`, draws
  `buildContextMenu(state, target)` and runs the chosen action after the menu is drawn.
- Entries with today's actions (admin entries come in P4, Server settings in P2 or P4):
  - **Channel:** Mark as read, Join voice / Leave voice, Copy room name; for admins Edit
    room…, Delete room… (opens the room form with delete confirmation armed).
  - **Conversation and member rows:** Send message, Mark as read (conversations with
    unread), Copy name.
  - **Voice participant:** Send message, Copy name.
  - **Message (transcript):** Copy message, Copy selected text (when there is a selection),
    Copy name, Quote (appends `> text` lines to the draft), Send message to sender (not for
    your own messages). `ui.transcript` reports the unit under a right-click; `TranscriptLine`
    gains `senderUserID`.
  - **Sender name:** the member entries.
  - **Server rail button:** Retry now (when not connected), Copy address, Remove server…
    (confirmation inside the menu: the item turns into "Click again to remove").
  - **Text fields (composer, settings fields):** Cut, Copy, Paste, Select all, through the
    existing `TextEditState`.
- GUI automation: `right-click "TEXT"`, `right-click X Y` and `right-click-id NAME [INT…]` in
  `ui_script.odin` (synthetic `MOUSE_BUTTON_DOWN/UP` with `SDL.BUTTON_RIGHT`), documented in
  `docs/testing-harness.md`.
- Tests: `client/context_menu_test.odin` (entries per target, admin entries only for admins,
  disabled states, actions), and a `dev/ui-smoke.sh` step that right-clicks a message and
  copies it and right-clicks a channel and marks it read.

### P2 Server settings (client only)

- A Server settings screen in the main pane (like the room form, `State.serverSettings`,
  `server_settings.odin` + `view_server_settings.odin`), opened by `State_openServerSettings(
  state, serverID)` from a button in the sidebar header (and from the rail menu after P1 and
  P2 meet, in P4). Sections:
  - **Profile:** display name on this server (empty uses the global one). Validated like the
    global name. Changing it reconnects only that server
    (`ClientServerTransport_matchesConfig` compares the effective name).
  - **Server:** label and short label (rail), host and port (moved here from General, which
    keeps adding servers and the global display name), the pinned key fingerprint with
    "Forget key", and Remove server.
  - **Voice:** a row per known user of that server (the user directory, voice participants
    first) with a volume slider (0–200 %) and Mute for me (#47). Applied live to the joined
    engine.
- Config: `Server` gains `display_name` (string, omitempty) and `user_voice` (a list of
  `{user_id, volume, muted}`, omitempty; entries equal to the default are dropped). Validated
  and documented per `AGENTS.md` (`config.odin`, `config_test.odin`, README).
- Voice engine: `VoiceEngine_setSpeakerGain(engine, userID, gain)` and mute, read by the voice
  thread when it creates or steps a speaker stream (a fixed table, no allocation per frame),
  applied as the speaker's `SDL_AudioStream` gain and in the file and null sink mix. A local
  mute drops that speaker's frames before decoding.
- Harness: `voice-volume USER_ID PERCENT` and `voice-mute-user USER_ID on|off`, and the
  effective values in `voice-stats`. Tests: config round trip and validation, engine gain on
  the file sink (a tone at 50 % measures about −6 dB), the screen's actions, the reconnect
  rule for the per-server name.

### P3 Admin server and protocol (protocol 14, migration 3)

Schema (migration 3, `admin`): `users.nickname_locked BOOLEAN NOT NULL DEFAULT false`,
`users.banned_at TIMESTAMPTZ NULL`, `users.ban_reason VARCHAR(256) NOT NULL DEFAULT ''`,
`rooms.room_type SMALLINT NOT NULL DEFAULT <ChatAndVoice> CHECK (…)`. Checks and an SQL
migration test from version 2 with rows, per "Schema Migrations" in `server/AGENTS.md`.

Protocol 14, new `MessageType` members at the end, each pinned in `protocol_test.odin`:

- `ClientAdminSetRole{userId, isAdmin}`, `ClientAdminRenameUser{userId, nickname, locked}`,
  `ClientAdminKickUser{userId, reason}`, `ClientAdminBanUser{userId, banned, reason}`.
- `ServerAdminActionResult{action, userId, message}` to the asking session (success; refusals
  stay `ServerProtocolError` with a human message).
- `ServerUserUpdated{user: UserSummary}` to every authenticated session (D7).
- `ServerAccountUpdated{isAdmin, nickname, nicknameLocked}` to every session of the target
  account (#41, D3).
- `ServerSessionEnded{reason, kind}` (kicked or banned) sent before the server disconnects a
  session.
- `ServerAuthSuccess` gains `nickname` and `nicknameLocked`; `UserSummary` gains `isAdmin` and
  `isBanned`; `RoomSummary`, `ClientCreateRoom` and `ClientEditRoom` gain `roomType` (D9).
- Every admin request checks the role in the database (`DatabaseUserServerAdminRequest`
  pattern) and applies D6 in the same statement as the change where it can (last admin,
  admin targets).
- Identity statement: a locked account keeps its nickname; a banned account resolves with a
  `banned` flag and the router answers `ServerAuthFailure` with
  `"This account is banned from this server"` (plus the reason when set).
- Voice and chat enforcement for room types (D9).
- Client transport and runtime events for every new server message (decode, ownership,
  `ClientTransportRuntimeEvent_deinit`), `State` updates that need no UI: `isAdmin` and
  nickname from `ServerAccountUpdated`, user list updates from `ServerUserUpdated`, room type
  in the room cache, kicked and banned as non-retryable connect failures
  (`classifyConnectFailure`) with a clear banner text.
- Harness: `admin-role`, `admin-rename`, `admin-kick`, `admin-ban`, `admin-unban`;
  `room-create` and `room-edit` take a type; events `user_updated`, `account_updated`,
  `session_ended`, `admin_result`.
- Tests: router tests for each action and refusal, SQL tests (identity with lock and ban,
  last-admin guard), migration test, and a live proof in `dev/live-proof.sh`: admin alice
  makes bob admin (bob's harness sees `account_updated isAdmin true` without reconnecting),
  renames him (his reconnect keeps the new name), kicks him, bans him (his reconnect is
  refused), unbans him, and makes a room text-only (bob's voice join is refused).

### P4 Admin UI (client, after P1–P3)

- Server settings gains an **Admin** section (admins only): a member table (name, online, role,
  banned) with Rename…, Make admin / Remove admin, Kick…, Ban… / Unban, each with a short
  confirmation and a reason field where it applies; a rooms list with Create, Edit, Delete
  and the room type.
- The room form gets the room type selector. A voice-only room has no composer and says so;
  a text-only room has no Join voice.
- Admin entries in the member, conversation, voice participant and sender-name menus, and
  Server settings in the rail menu; Volume and Mute for me in the voice participant menu.
- The banner shows kicked and banned states (D4, D5); the Profile section shows a name set by
  an admin as read-only.
- Tests: view models and actions for each admin entry (shown only to admins, disabled for
  yourself and for other admins where D6 refuses), and `dev/ui-smoke.sh` steps: GUI admin
  alice makes headless bob admin and bob's harness sees it live; alice bans bob from the member
  menu.

## Coordination rules

- **Protocol and schema.** Only P3 changes the protocol (14) and the schema (migration 3).
  P1, P2 and P4 must not.
- **Conflicts.** P1 and P2 both edit `client/view.odin` and `view_model.odin`. Keep changes
  there small and additive: new code in new files, a single call in `viewApp` and the sidebar
  header. P2 must not add context menu entries; the rail menu's "Server settings" entry and
  P2's volume entries arrive in P4.
- **One PR per package** on Forgejo `quonic/haychat`, from the package's own worktree and branch.
  Agents do not merge; the lead reviews, waits for CI, merges, and closes the PR.
- **Dev pod.** The lead owns the shared dev pod. Agents use only throwaway containers:
  `./dev.sh check`, `live`, `ci` and `shell`.
- **Verification.** `./dev.sh check` while editing, `./dev.sh live --all` for anything that
  touches the wire or the database, and `./dev.sh ci` on the final tree before the PR. Wait
  for it to finish before reporting.
- **Docs.** Each package updates `client/AGENTS.md` / `server/AGENTS.md`, README (config keys,
  Known Limitations), and `docs/testing-harness.md` for new commands.

## Issues

#39 and #41 close with P3 + P4. #47 closes with P2 (and P4's menu entries). #42 gets a comment:
admin rename done, the key move left open.

## Status (2026-11-14)

Every package merged; `main` is at protocol 14 and schema migration 3.

| Package | PR | Merge |
| --- | --- | --- |
| P1 Context menus | #51 | 495f8cb |
| P2 Server settings | #50 | 5ac02aa |
| P3 Admin server and protocol | #52 | a3e6604 |
| P4 Admin UI | #53 | fa0ce06 |

Also merged: #49 (`HAYCHAT_DEV_UI_SCREENSHOTS` under SELinux) and, in #52, a fix for a race
in `dev/harness-lib.sh` (a client that answers and exits at once was reported as exited).
#39, #41 and #47 are closed; #42 has a comment (admin rename done, moving an account to
another key still open).

Changes from the plan made while building:

- P3: each admin action is one SQL statement that checks the role, applies the D6 guards and
  makes the change; there is no separate admin check first. An empty rename name changes only
  the lock (how an admin unlocks a name). A banned account cannot be made an admin.
- P3: router-commanded disconnects use `peer_disconnect_later`, so the last packets
  (`ServerSessionEnded`, `ServerAuthFailure`, protocol errors) reach the client, and the router
  gets `NetworkPeerDisconnected` for those peers instead of keeping their sessions.
- P4: a kick or ban clears the voice re-join, so Retry does not rejoin voice. The Admin member
  table is sorted by name only. UI scripts gained `wait-gone` and `scroll`.

Follow-ups:

- The last-admin guard relies on the one database worker running statements in order; two
  servers sharing one database could let two admins revoke each other at once. One server per
  database is the supported setup.
- The Admin member table has no search or paging (README Known Limitations).
- Roles changed directly in the database still reach clients only on their next connection (D8).
- Out of scope this round and still open: private rooms (#40), closed sign-up (#43), moving an
  account to another key (#42), server-side message edit and delete.
