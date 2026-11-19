# HayChat: edit and delete your own messages (#76) (2026-11-19)

Issue #76 asked for message edit and delete, which the admin and settings round
(`2026-11-14-admin-settings-menus.md`) left out. Room messages and direct messages cannot be
edited or deleted today, by the author or by an admin. The maintainer decided the open questions
on the issue (2026-11-19, comment 5301). This plan records those decisions, the lead's choices
for the details the decisions leave open, the design, and the packages.

## Goals

- Authors edit and delete their own room and direct messages, in plaintext and encrypted
  conversations alike.
- Admins delete any room message (moderation).
- A deleted message leaves a tombstone with the same ID, so history pagination and read markers
  stay stable.
- Edit history is kept, and a client shows it when the user hovers over the message.
- The server cannot forge an edit or an author's delete, and cannot move either to another
  message. It can still withhold, reorder or remove things (see "Threat model notes").

## Decisions

The maintainer's decisions (issue #76):

- **D1** The author edits and deletes their own messages. Admins delete any message (moderation).
- **D2** A delete is a tombstone that keeps the message ID, so history pagination and read markers
  stay stable (message IDs are cursors).
- **D3** In encrypted rooms and DMs the server cannot check an edit's content. An edit is a new
  sealed message that refers to the original's `clientMessageId` and is signed by the same sender,
  and clients verify the reference. A delete by the author is a signed request. An admin delete in
  an encrypted room is written by the server, and clients show it as removed by the server.
- **D4** Edit history is kept and shown: hovering over a message shows its edit history.

The lead's choices for what D1-D4 leave open (2026-11-19):

- **D5** Admin deletes apply to **room messages only**. Admins cannot read other accounts' direct
  messages, so a DM is deleted only by its author. The recipient of a DM cannot delete it.
  Moderation stays keyed to the admin role (`DATABASE_ACTOR_IS_ADMIN_SQL` in the statement), with
  no assignable permission. An assignable "manage messages" permission is a possible follow-up.
- **D6** Every author delete is signed, in plaintext conversations too, because every message is
  signed since protocol 22 and #82. Any delete without a valid author signature is shown as
  **"Removed by the server"**: an admin's moderation, or a delete whose signature fails against
  the author's pin. Clients cannot verify which admin removed a message, so they never name one.
- **D7** A delete erases the content on the server. The tombstone keeps the ID, sender,
  timestamp, `clientMessageId` and, for a sealed room message, its chain position, so replay
  checks still hold. It drops the content, the sealed bytes, the signature and **every edit**:
  the edit history goes with the message.
- **D8** Deleting a message removes its files in the same statement: the attachments become
  Removed tombstones and the router deletes the files (`StorageDeleteBlobs`), as an admin removal
  does. An admin's delete also writes the files to the removal log (`attachment_removals`,
  protocol 29) with the admin as the remover. An author's delete does not, because it is not
  moderation. The message tombstone carries no attachments.
- **D9** An edit changes the text only. It never adds, removes or replaces files; the message
  keeps its original attachments. An edit's content is 1..`CHAT_MESSAGE_MAX_BYTES` bytes, or may
  be empty only when the message has attachments.
- **D10** An edit needs what a new message in that conversation needs at the time of the edit.
  In a room that means membership, SendMessages, a chat room type and, when encrypted, the room's
  current log version. In a DM it means the DM rules: restricted accounts, and for a sealed edit
  the recipient's current key. Deleting your own message needs only that you can still read it
  (room membership, or being one of the DM's two sides).
- **D11** Plaintext stays plaintext and sealed stays sealed: an edit of a plaintext message is
  plaintext (signed), and an edit of a sealed message is sealed.
- **D12** At most `MESSAGE_EDITS_MAX` (100) edits per message. Edits have no time limit.
- **D13** Edits do not count as unread and do not move read markers. A deleted message does not
  count as unread in the server's counts. The client follows `client/read_state.odin`'s rule that
  it never lowers a count itself, except to drop a deleted message it counted live.
- **D14** History pages and live messages carry the **latest** version plus an edit count. The
  full history is fetched on demand (`ClientFetchMessageEdits`), the first time the user hovers
  over the "(edited)" marker, and cached for the session.

## Design

### Signatures (`common/e2ee.odin`, layouts documented at the top of the file)

Four new labels, all signed by the author's identity key. Every integer is i64 LE unless marked;
`original` is the edited or deleted message's `clientMessageId` and `edit` is the edit's own new
random `clientMessageId`:

- `"haychat-room-edit-v1"` ‖ serverKey (32) ‖ roomId ‖ senderId ‖ original (16) ‖ edit (16) ‖
  contentLength u32 ‖ content
- `"haychat-dm-edit-v1"` ‖ serverKey ‖ senderId ‖ recipientId ‖ original ‖ edit ‖ contentLength
  u32 ‖ content
- `"haychat-room-delete-v1"` ‖ serverKey ‖ roomId ‖ senderId ‖ original
- `"haychat-dm-delete-v1"` ‖ serverKey ‖ senderId ‖ recipientId ‖ original

Check that the labels stay prefix-free among all existing labels, and add vectors to
`dev/tools/e2ee-vectors.py`.

A **sealed edit** is an ordinary `SealedRoomMessage` (the next index on the sender's current
chain) or a `sealDirectMessage` envelope, whose `clientMessageId` is the edit's. Its plaintext map
gains `"replaces": bytes(16)`, the original's `clientMessageId`, and has no `"attachments"` key.
The decoder already skips unknown keys. `encodeSealedMessagePlaintext` writes the canonical form
with `"replaces"` after `"content"`. A client accepts a sealed edit only when it verifies against
the **original sender's** pin, its `"replaces"` equals the original's `clientMessageId`, and it
carries no attachments.

### Wire (protocol +1; `MessageType` members appended and pinned at merge)

- `MessageEdit{id, clientMessageId, timestamp, content, signature, sealed}`: one version.
  `sealed` holds the room's `SealedRoomMessage` or the DM's envelope, and is empty for plaintext.
- `MessageDeletion{deletedAt, signature}`: a zero signature means removed by the server.
- `StoredChatMessage`, `ServerChatMessagePayload`, `StoredDirectMessage`,
  `ServerDirectMessagePayload`, `ServerSealedDirectMessagePayload` and
  `DirectConversationSummary` (as `last*`) gain `editCount`, `lastEdit: MessageEdit` (zero when
  there are no edits), `deleted` and `deletion`. A deleted message carries no content, sealed
  bytes, signature, attachments or edit.
- `ClientEditRoomMessage{roomId, messageId, clientMessageId, content, signature, sealed}` →
  `ServerRoomMessageEdited{roomId, messageId, edit}`.
- `ClientDeleteRoomMessage{roomId, messageId, signature}`: a zero signature asks for an admin
  moderation delete → `ServerRoomMessageDeleted{roomId, messageId, deletion}`.
- `ClientEditDirectMessage{peerUserId, messageId, clientMessageId, content, signature, envelope}`
  → `ServerDirectMessageEdited{senderId, recipientId, messageId, edit}`.
- `ClientDeleteDirectMessage{peerUserId, messageId, signature}` (author only) →
  `ServerDirectMessageDeleted{senderId, recipientId, messageId, deletion}`.
- `ClientFetchMessageEdits{kind (room|direct), conversationId, messageId}` →
  `ServerMessageEdits{kind, conversationId, messageId, edits}`, oldest first. The original is the
  message itself, not part of the list. A deleted message has an empty list.
- Refusals are `ServerProtocolError` constants in `common/protocol.odin`. Each one names its
  message, as the #138 follow-up asked for (the protocol error names its message ID).

### Router and database (`server/`)

- The router verifies a plaintext edit's and a delete's signature against the **session's**
  identity key, and a sealed edit's seal as it verifies new sealed messages (session key, room
  epoch). The database worker checks everything else **in the statement that makes the change**:
  - the author is the sender;
  - the message exists in that conversation and is not deleted;
  - D10 and D11;
  - `MESSAGE_EDITS_MAX`;
  - a reused `(sender, clientMessageId)` or `(sender, chain, index)` across messages and edits
    is refused;
  - for an admin delete, `DATABASE_ACTOR_IS_ADMIN_SQL`.
- Fan-out goes to every session that can read the original: room members past the From join cut
  (`DATABASE_HISTORY_SINCE_*`, as `ServerAttachmentRemoved` does), and both sides of a DM. A
  delete in the same statement makes the message's attachments Removed tombstones (D8) and
  returns their blob IDs, so the router ends their downloads and deletes the files.
- Unread counts (`server/database_read_markers.odin` and the room and conversation lists) skip
  deleted rows. The direct conversation preview shows the latest edit, or the tombstone.

### Schema (migration +1)

- `chat_messages` and `direct_messages` gain `edit_count SMALLINT NOT NULL DEFAULT 0`,
  `edited_at TIMESTAMPTZ NULL`, `deleted_at TIMESTAMPTZ NULL`,
  `deleted_by_user_id BIGINT NULL REFERENCES users ON DELETE SET NULL` and
  `delete_signature BYTEA NULL` (64 bytes; NULL for an admin delete). The content checks are
  replaced under their names so that a deleted row has `content = ''`, NULL sealed or envelope
  bytes, a NULL signature and `attachment_count = 0`, and keeps `client_message_id` and the
  chain columns.
- `chat_message_edits` (`id`, `message_id` FK cascade, `sender_user_id`, `client_message_id`,
  `content`, `sealed`, `signature`, `chain_id`, `chain_index`, `created_at`) and
  `direct_message_edits` (the same, with `envelope` and no chain columns), indexed by
  `(message_id, id)` with unique `(sender_user_id, client_message_id)` (and chain) indexes. The
  insert statement also checks the other table for a reused ID.
- Schema validation checks for all of these, and migration tests.

### Client

- `State_editRoomMessage`, `State_deleteRoomMessage`, `State_editDirectMessage`,
  `State_deleteDirectMessage`, `State_fetchMessageEdits`; entries gain `editCount`, the latest
  edit, `deleted`/`removedByServer`, and a cached edit list.
- Verify every edit and every author delete against the sender's **pinned** identity key before
  showing it. An edit that fails verification is not shown: the entry keeps its last good
  version and is marked "An edit could not be verified". A tombstone always hides the content,
  whatever its signature says (D6).
- Harness: `msg-edit ROOM_ID MESSAGE_ID TEXT...`, `msg-delete ROOM_ID MESSAGE_ID [admin]`,
  `dm-edit USER_ID MESSAGE_ID TEXT...`, `dm-delete USER_ID MESSAGE_ID`, `msg-edits room|dm ID
  MESSAGE_ID`; events `message_edited`, `message_deleted`, `message_edits`; history and live
  message events gain `edit_count`, `edited`, `deleted` and `removed_by_server`.
- GUI (M3): the message context menu gains **Edit message** and **Delete message…** (own
  messages) and **Delete message…** (admins, others' room messages), each delete with a
  confirmation. Editing loads the text into the composer with an "Editing message" bar (Esc
  cancels, Enter saves), and Up in an empty composer edits your newest message. "(edited)" sits
  after the text, and hovering over it shows the versions with their times (fetched once). A
  tombstone reads "Message deleted" (signed by the author) or "Removed by the server".

### Notes from M1 (2026-11-19)

Where the code needed something the design above leaves open, M1 chose:

- **The original's ID on the wire.** `ClientEditRoomMessage`, `ClientDeleteRoomMessage`,
  `ClientEditDirectMessage` and `ClientDeleteDirectMessage` also carry
  `originalClientMessageId`, the message's client message ID, which the signatures cover. The
  router can then verify a plaintext edit's and a delete's signature against the session's key
  without the database, as this design says it does, and the statement refuses the change
  unless that ID is the stored message's ("Message not found").
- **Notices.** `ServerRoomMessageEdited` and `ServerRoomMessageDeleted` carry `senderId`, and
  both edited notices `editCount` (the count after the edit), so a client checks an edit against
  the right pin and keeps the server's count without counting itself. The live new-message
  payloads (`ServerChatMessagePayload`, `ServerDirectMessagePayload`,
  `ServerSealedDirectMessagePayload`) do not gain the edit fields: a message is never edited or
  deleted when it is first sent. Stored messages, history and the conversation summary do.
- **Who may delete.** An author's delete, like an edit, needs the message to be one the author
  can still read (membership and the From join cut). An admin's moderation delete needs only the
  admin role, not membership, and also reaches the admin's own session when it is not a reader.
- **Files of a deleted message (D8).** The attachments become Removed tombstones with the
  deleter as `removed_by_user_id`. Besides ending the downloads and deleting the files, the
  router sends every reader `ServerAttachmentRemoved` for each file before the tombstone, so
  clients give the quota back and abandon downloads through the protocol 28/29 path. A download
  of such a file is refused with the existing "Attachment removed by an admin", also after an
  author's delete (a follow-up may give it its own sentence). An admin's delete logs the files
  with the reason "Message deleted".
- **Edits of a deleted message (D7).** The delete removes the edit rows, so their client message
  IDs and chain indexes are no longer reserved on the server; only the tombstone's own are.
  Clients never reuse an ID or an index, and an edit's signature cannot be read as another
  message's (its label is its own), so nothing can be replayed with them.
- **Schema.** `chat_message_edits` has no `epoch` column: the sealed bytes carry it, and the
  edit statement checks it against `rooms.log_version`. A tombstone's `edit_count` goes back to 0.
- **Refusals** reuse the new-message sentences for D10 ("Not a room member", "You cannot send
  messages in this room", "Room key is out of date", …) and, like the new ones, name the message:
  " (message N)" is appended (`common.messageRefusal`). A client matches them by prefix.
- **Harness fields** are camelCase (`editCount`, `edited`, `editStatus`, `deleted`,
  `removedByServer`), like every other harness field, rather than the snake_case names above;
  the event names are as planned. `msg-edit`/`dm-edit` take `--forge` (a bad signature, for the
  proof) and `--unchecked` (skip the own-message check), and `msg-delete`/`dm-delete` take
  `unchecked`, so a proof sees the server refuse.
- **M1 client.** A sealed edit is kept as Pending ("edited, not verified yet") and never opened,
  and editing a sealed message is refused locally ("Editing encrypted messages is not available
  yet"); deletes are signed in encrypted conversations too. The window shows the latest verified
  version with " (edited)" and a tombstone's sentence as plain text until M3.

### M2 hooks

- Server: nothing to change. A sealed room edit (`ClientEditRoomMessage.sealed`) is checked by
  `MainRouterState_checkSealedRoomMessage` (with the edit's client message ID in the AAD) and
  stored in `chat_message_edits.sealed` with its chain position; a sealed DM edit
  (`ClientEditDirectMessage.envelope`) is verified by the database worker
  (`databaseExecuteEditDirectMessage`) and stored in `direct_message_edits.envelope`. Both come
  back as `MessageEdit.sealed` in `lastEdit`, the edited notices and `ServerMessageEdits`.
- Client: `State_editRoomMessage` and `State_editDirectMessage` refuse a sealed message with
  `MESSAGE_EDIT_SEALED_UNSUPPORTED_MESSAGE`; M2 replaces that branch with sealing (the room's
  chain through `room_chains.odin`'s queue, the DM's envelope through
  `direct_messages_e2ee.odin`) and sends `sealed`/`envelope` with an empty content and a zero
  signature. `messageEditCheck` returns Pending for a sealed edit; M2 opens it there (or in a
  State procedure that has the chains and keys) and checks `"replaces"`, the original sender and
  that it has no attachments. The harness's `msg-edit`/`dm-edit` go through those procedures, so
  they pick sealed or plaintext by the conversation as `send`/`dm` do.

### Notes from M2 (2026-11-19)

M2 needed no protocol change: no wire, enum or schema change, and the server is unchanged.
Where the design above leaves something open, M2 chose:

- **The codec is strict.** `decodeSealedDirectMessagePlaintext` refuses a `"replaces"` that is
  not a 16-byte byte string, an all-zero one, and a plaintext with both `"replaces"` and
  `"attachments"`; `encodeSealedMessagePlaintext(..., replaces)` refuses the same, and its edit
  form allows empty content (whether that is allowed depends on the message, which the client
  checks: Failed `Empty`). The client checks the empty rule for plaintext edits too. New
  messages encode byte for byte as before (vector `KAT_SEALED_EDIT_PLAINTEXT` added).
- **Invalid combinations.** A new sealed message (room or DM) whose plaintext has `"replaces"`
  is Failed (`BadPlaintext`), so an edit the server replays under its own client message ID is
  never shown as a message; a sealed plaintext without `"replaces"` that arrives as an edit is
  Failed `NotEdit`, one naming another message `Moved`.
- **Replays.** An edit is Failed `Replayed` when it carries the message's own client message ID
  or (rooms) chain position, when it repeats the shown edit under another edit ID, or, in the
  fetched list, an earlier edit's client message ID or chain position. Copies across different
  messages are left to the server, which refuses every reused ID and index.
- **Failures are final.** `MessageEditView.checkedEditID` records which edit a verdict is
  about; a Failed edit is never checked again, a Pending one is checked when keys, a chain or
  the log arrive (`State_messageEditsKeysChanged`, `State_roomChainsReopenPending`), and the
  room follow-up fetches or asks for the chains pending edits need.
- **Sending.** A room edit waits in the sender chain queue like a message ("Setting up
  encryption…" while its chain is distributed). A refusal naming the message ("Room key is out
  of date (message N)") sends it again first with a new chain; any other refusal drops it, and
  an edit's text never goes into the draft. A DM edit is sealed only while the peer's key can be
  encrypted to: it is never queued and never falls back to plaintext (D11), and is refused
  locally otherwise ("Setting up encryption…" while the key is fetched). A sealed message that
  did not open cannot be edited ("That message could not be opened, so it cannot be edited").
- **Harness.** `message_edited` gains `editFailure`. A sealed edit printed `pending` is not
  printed again when it opens; history, `room_opened` and `msg-edits` show it. `--forge` on a
  sealed edit spoils the seal's signature (the server answers "Invalid encrypted room message
  (message N)" or "Invalid encrypted direct message (message N)").
- **Proof.** In `dev/message-edit-proof.sh` (steps 4 and 7), not `dev/e2ee-proof.sh`, so the
  edit proof stays in one place. Step 7 has B reconnect first, because step 4 removes B's
  encryption key in the database.

### M3 hooks (from M2)

- `MessageEditView.failure` (`MessageEditFailure`) and `sealedError` say why the latest edit
  Failed; `status` Pending also covers a sealed edit waiting for its chain or the room's log.
- In the cached list (`State_messageEdits`) a Verified sealed edit's `content` is its opened
  text, so the hover list reads `content` for both kinds.
- `State_editRoomMessage` returns "" when a sealed edit is queued: the new version appears only
  with the server's notice, as for plaintext. Its refusals arrive as protocol errors naming the
  message.

### Notes from M3 (2026-11-19)

M3 needed no protocol change. Where the design above leaves something open, M3 chose:

- **The edit has its own field.** "Editing loads the text into the composer" is an edit field
  in the composer's place (`MessageEditComposer`), not the draft: the draft is never touched,
  so it is there again after a save or a cancel without being moved anywhere. Enter with the
  text unchanged closes the bar without sending; blank text is refused for a message without
  files (D9). The file chips and the paperclip are not drawn while editing (D9).
- **Menu entries.** Your own message that cannot be edited now (a room you may not send in, a
  sealed message that did not open, not connected) shows **Edit message** greyed out rather
  than hidden. A tombstone's menu has no Copy message, Quote, Edit or Delete. Copy message and
  Quote use the latest verified version.
- **The marker.** "(edited)" is a separate label after the text (never selected or copied);
  while an edit waits it reads "(edited, not verified yet)", and when the latest edit failed
  "(edited) · An edit could not be verified" in the warning colour. A click pins the history
  open (a press outside or Esc closes it); the popover is not modal, so typing goes on while
  the pointer rests on a marker. It shows at most 70 % of the window's height: the original
  and the newest edits, with "… N earlier edits not shown". Only the latest edit's failure
  reason is known (the cached list keeps a status per edit), so only it gets the small text.
- **Times** in the history are UTC ("YYYY-MM-DD HH:MM UTC"), like Removed files.
- **Tombstones** are drawn in a slanted regular face (`ui.FontID.Italic`, SDL_ttf's
  `TTF_STYLE_ITALIC`; the client ships no italic font), muted, without the encryption badge.
- **The DM preview.** The GUI's conversation list has no preview line, so the newest message's
  latest version or tombstone sentence goes into the row's tooltip ("Last message: …",
  `State_directPreviewText`). A tombstone no longer marks the row "Unencrypted" (the preview's
  tombstone was read as signed plaintext).
- **A pending DM edit.** "Setting up encryption…" keeps the bar open with that status, and the
  edit goes out by itself once the peer's key can be encrypted to (`State_messageEditPoll`), or
  when the user presses Enter again; a key that will not come says why.

## Packages

Strictly sequential, one PR each against `main`, each from fresh `main` after the previous merge.

### M1: Server, protocol and plaintext clients (protocol +1, migration +1)

- Everything above for the wire, the schema, the router and database, including the server's
  handling of **sealed** edits (stored byte for byte after the checks above), so that M2 needs no
  protocol change.
- `common/e2ee.odin`: the four signature procedures with vectors and tests.
- Client state, verification and the harness for **plaintext** rooms and DMs, plus signed
  deletes everywhere, encrypted conversations included.
- `dev/message-edit-proof.sh` (`live-proof.sh --edits`, part of `--all`): two clients edit and
  delete in a room and a DM; the other sees the edit and fetches the history; editing or
  deleting someone else's message is refused; an admin deletes another account's message and it
  shows as removed by the server; a From join newcomer gets no events for messages before its
  join; deleting a message with a file makes its download refused; a forged edit (`msg-edit`
  with a bad signature from a test hook, or the raw harness) is refused.
- Docs: `docs/protocol.md`, `server/AGENTS.md`, `client/AGENTS.md`, `docs/testing-harness.md`,
  and an Architecture bullet in `AGENTS.md`.

### M2: Encrypted edits (no protocol change expected)

- `"replaces"` in the sealed plaintext (encode, decode, vectors), sealing edits on the current
  chain and envelope, and opening and verifying them in rooms and DMs, with tests for a moved
  edit, a wrong signer, an edit with attachments and a replayed edit.
- A Full history newcomer reads edits through forwarded chains. From join rooms show the edits
  only of messages the reader can read.
- Proof steps in `dev/e2ee-proof.sh` (or the M1 proof): an encrypted room edit and delete, an
  encrypted DM edit and delete, and an admin delete in an encrypted room shown as "Removed by the
  server".
- Docs: Encrypted Room Messages and DMs in `client/AGENTS.md`, `docs/protocol.md`.

### M3: GUI and user docs (no protocol change expected)

- The GUI above (`client/context_menu.odin`, `client/view.odin`, `client/view_direct.odin`),
  ui-script support for the hover, and a `dev/ui-smoke.sh` step: edit, hover the history,
  delete, and an admin delete, with screenshots for review.
- `docs/user-guide.md` and `docs/tester-guide.md`.

## Threat model notes

- The server can withhold edits, reorder them, show an older version as the latest, or delete a
  message and show it as "Removed by the server". It cannot forge an edit or an author's delete,
  move either to another message (both bind the original `clientMessageId`, the conversation and
  the sender), or show a version the author never signed.
- An encrypted edit is readable by whoever holds the chain it was sealed on: the members of the
  room's current epoch, not those of the original's epoch. A member removed since the original
  never gets the edit. Edits do not change who can read the original.
- A delete erases the server's copy. Other clients may already hold the content, so a delete is
  not a recall.

## Round Status

- 2026-11-19: plan written. M1 in progress.
- 2026-11-19: M1 implemented (protocol 30, migration 17, wire values 218-227); departures are
  under "Notes from M1" in the Design section. M2 and M3 to follow.
- 2026-11-19: M1 merged (PR #150). M2 implemented with no protocol change: sealed edits in
  encrypted rooms and DMs, sent and opened; departures are under "Notes from M2" and the GUI's
  hooks under "M3 hooks (from M2)". M3 to follow.
- 2026-11-19: M2 merged (PR #151). M3 implemented with no protocol change: the message menu's
  Edit message and Delete message… (and an admin's Delete message… on room messages), the
  inline edit bar with Up and Esc, "(edited)" with its hover history, tombstones, the DM
  preview in the conversation row's tooltip, `hover` in GUI automation, `dev/ui-smoke.sh` step
  15 and the user and tester guides; departures are under "Notes from M3". Every package is
  done; the follow-ups below are left.

### Follow-ups

- (M1) A deleted message's files are refused with "Attachment removed by an admin", also after
  an author's delete: give that case its own sentence.
- (M1) An assignable "manage messages" permission for moderation deletes (D5 keeps them to
  admins).
- (M1) A delete removes the message's edit rows, so their client message IDs and chain indexes
  are no longer reserved on the server (harmless today: clients never reuse them and edit
  signatures have their own label).
- (M2) No event (in the harness or the client) when a sealed edit printed pending opens later;
  history, `room_opened` and `msg-edits` show it. The GUI redraws from State, so it shows there.
- (M2) No unit test for a Full history newcomer reading an edit through a forwarded chain (the
  live proof covers it).
- (M3) A visible preview line in the conversation list (today only the row's tooltip).
- (M3) The history popover does not scroll: past 70 % of the window older edits are left out
  with a count. Its times are UTC, not the local time zone.
- (M3) Keep each listed edit's failure reason, so the history can say why for every failed
  edit, not only the latest.
- (M3) A real italic face for tombstones (SDL_ttf's slanted regular is rough at small sizes).
- (M3) No keyboard way to open the edit history, and Up edits only from an empty composer.
