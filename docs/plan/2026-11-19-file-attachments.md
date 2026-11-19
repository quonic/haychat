# HayChat: file attachments (#118) (2026-11-19)

`main` is at protocol 25 and schema migration 13. #31 removed the write-only `ClientStoreFile`
endpoint (option A), so HayChat has no file uploads. This document designs attachments for room
messages and direct messages: storage, transfer, access checks, client-side encryption, limits,
lifecycle, moderation and the client UI. It ends with the packages to implement it.

Read this whole file, `AGENTS.md`, `client/AGENTS.md`, `server/AGENTS.md` and sections 4 and 6 of
`docs/plan/e2ee-design.md` before starting a package. Protocol and migration numbers are
placeholders: each package takes the next free number when it merges.

## Goals

1. **Attach files to messages.** Up to four files on a room message or a direct message, with or
   without text. They show as file cards with name, size, progress and **Save…**.
2. **Server-authoritative access.** Whoever may read a message's history may download its files,
   and nobody else may. The server binds every file to exactly one message.
3. **End-to-end encryption where the conversation is encrypted.** In encrypted rooms and encrypted
   direct messages the server stores only ciphertext, and the file key and name travel inside the
   sealed message. Plaintext conversations sign the file's hash with the message (protocol 22).
4. **Bounded storage.** Per-file size, per-account quota, an upload rate, an optional global cap
   and a free-disk reserve, all `HAYCHAT_*` variables. Unused uploads and files of deleted rooms
   are swept.
5. **Moderation.** Admins see storage use per account and can remove any attachment.

Out of scope: image previews (decided **later**, D23), message edit and delete (#76; it gets
blob cleanup for free from D17), more than one device per account (#86), forwarding an
attachment to another conversation without uploading it again, and video or voice messages.

## What #31 left behind

- Wire values 120/121 (`ClientStoreFile`, `ServerStoreFileResponse`) are retired and pinned.
- `ClientUploadFile` … `ServerDeleteFileResponse` (123-128) are unhandled placeholders and are
  **not** pinned in `common/protocol_test.odin`. `server/router_test.odin` uses
  `.ClientUploadFile` as its example of an unsupported message.
- `HAYCHAT_MAX_FILE_SIZE`/`HAYCHAT_MAX_STORAGE_CAPACITY` are retired (`RETIRED_CONFIG_VARIABLES`,
  `server/config.odin`). The names are not reused (D21).
- `HAYCHAT_FILE_STORAGE_PATH` is the server's state directory (`server_identity.json`).
- The server's `NetworkChannel` enum already names `FileTransfer = 5`, but `enet_host_create` is
  given 5 channels (0..4), so channel 5 does not exist yet. The router drops every channel but
  Chat (`server/main.odin` near line 1560). The client creates 5 channels too
  (`STARTUP_AUTH_CHANNEL_COUNT`).

## Decisions

The maintainer decided D20, D21, D22 and D23 on 2026-11-19. The rest are the lead's
recommendations, written as decisions so the packages can be briefed. The maintainer may change
any of them in review of this document.

| #   | Decision |
| --- | --- |
| D1  | **Upload first, then reference.** A client uploads each file to a conversation and gets a blob ID. It then sends the message with the blob IDs. The server binds the blobs to the new message in the same statement that stores the message. A blob that is never bound is swept after `HAYCHAT_ATTACHMENT_PENDING_HOURS`. |
| D2  | **Blob IDs are 16 random bytes chosen by the server**, not content addresses. The SHA-256 of the stored bytes (ciphertext in encrypted conversations) is recorded, checked when the upload finishes, and carried in the signed or sealed message, so the recipient checks it too. File names on disk come from the blob ID, never from client data. |
| D3  | **No deduplication**, not even within one owner. Cross-owner dedup lets anyone confirm that someone else stored a given file. Within-owner dedup saves little and needs reference counts. |
| D4  | **Blobs live in their own directory** (`HAYCHAT_ATTACHMENT_DIR`, default `attachments`; `/var/lib/haychat/attachments` and a new `haychat-attachments` volume in `deploy/`). Startup refuses an attachment directory that equals `HAYCHAT_FILE_STORAGE_PATH` or contains the server identity file. Metadata lives in PostgreSQL. PostgreSQL large objects were rejected: the server has one database connection, and streaming megabytes through it would stall every chat query behind the transfer. They would also bloat `pg_dump`. |
| D5  | **A storage worker thread** does all file I/O and the running SHA-256. It has its own IPC ring next to network and database. It never talks to PostgreSQL. The router orchestrates: the database worker decides, the storage worker writes. |
| D6  | **Transfers use ENet channel 5** (`NetworkChannel.FileTransfer`, now allocated on both sides: channel count 6), reliable, with its own transport keys (`TransportChannel.File`, the key schedule becomes `"haychat transport v3"` with six keys) and a strict receive counter like control. ENet sequences each channel on its own, so file chunks never sit in channel 1's ordering ahead of chat packets. |
| D7  | **Chunks are binary, not CBOR** (`common/attachment_wire.odin`, like `voice_wire.odin`): `kind u8 ‖ blobId 16 ‖ offset u64 LE ‖ data`, at most `ATTACHMENT_CHUNK_BYTES` (64 KiB) of data. Acks are the same shape with no data. The control requests (begin, finish, download, cancel) are ordinary CBOR on channel 1. |
| D8  | **Credit-based flow control.** At most `ATTACHMENT_WINDOW_CHUNKS` (8, so 512 KiB) unacknowledged chunks per transfer, at most 2 uploads and 4 downloads per session, and a per-session byte rate (`HAYCHAT_ATTACHMENT_SESSION_BYTES_PER_SECOND`, default 4 MiB/s) paced by the router. The server acks an upload chunk only after the storage worker wrote it. The client acks each download chunk. This keeps ENet's queue short so control packets interleave. |
| D9  | **Resumable within limits.** An upload resumes by blob ID at the offset the server last acked, while the blob is still Uploading (until the pending sweep). A download takes a start offset. A client never resends an acked chunk, and an encrypted upload never re-encrypts a chunk (D12), so an upload whose client restarted starts over as a new blob. |
| D10 | **Access to download = access to read the message.** A room attachment needs `room_members` membership and the same From join rule as history (`created_at` after `joined_at` unless the room is Full history). A direct message attachment needs the requester to be its sender or recipient. Restricted accounts follow D17 of the registration plan: DM history stays readable, so do its files. Admins get no bypass, as for history. The owner may download its own blob before it is bound. |
| D11 | **Upload needs the right to post there now.** Begin checks, in one statement with the insert: room membership plus `SendMessages` and `AttachFiles` (D20) through the room permission subquery, or for a DM the same recipient and restricted-visibility checks as a DM send. Binding checks it again (owner, conversation, state Ready, not yet bound, encryption matches) in the message's insert statement. |
| D12 | **Client-side encryption in encrypted rooms and encrypted DMs.** A random 32-byte file key per file. The file is padded (Padmé, D13) and encrypted in 64 KiB chunks with XChaCha20-Poly1305 (`common/attachment_e2ee.odin`, layout below). Each chunk is encrypted exactly once, and its ciphertext is kept in memory until it is acked. The key, plaintext size, name and media type travel inside the sealed message. The server learns the ciphertext size, the count per message, and who uploads and downloads. |
| D13 | **Padmé padding** of the plaintext length before encryption (at most 12% overhead, it leaks O(log log n) bits of the size). Plaintext attachments are not padded. |
| D14 | **Plaintext conversations sign their attachments.** A message with at least one attachment is signed with new labels `"haychat-room-plain-v2"` / `"haychat-dm-plain-v2"`, over the v1 prefix, the length-prefixed content and every attachment's blob ID, SHA-256, size, name and media type. Messages without attachments keep the v1 bytes, so stored history still verifies. The verifier picks the label from the attachment count, and a server that adds or strips attachments makes the signature fail either way. The DM plaintext fallback (design 4.6) uses v2 the same way. |
| D15 | **Text is optional when files are attached.** `content` may be empty when the message has 1..4 attachments, in all three forms (plaintext room, sealed room, DM). The sealed CBOR decoder (`cborFindContent`) accepts an empty content only with a non-empty `attachments`. A new `attachment_count` column lets the database's CHECKs say the same. |
| D16 | **At most 4 attachments per message** (`ATTACHMENTS_PER_MESSAGE_MAX`, a wire constant). Names are 1..255 bytes of UTF-8 with no control characters or path separators. Media types are declared by the sender, at most 100 bytes of `type/subtype` ASCII, and are never trusted for anything but the label on the card. With 4000 bytes of text, four entries still fit `SEALED_ENVELOPE_MAX_BYTES` (about 6.4 KB). `DIRECT_MESSAGE_PLAINTEXT_MAX_SIZE` grows, and the envelope limit does not change. |
| D17 | **Lifecycle.** `attachments.chat_message_id`/`direct_message_id` are `ON DELETE SET NULL`. A bound blob whose message is gone (room deleted, and later #76) is swept: the storage worker deletes the file, then the database deletes the row. Stale uploads (no chunk for an hour, or unbound after the pending window) are swept the same way. A startup scan deletes files older than an hour that have no row, and logs them. Accounts are never deleted. |
| D18 | **The server announces its limits** in `ServerAuthSuccess.attachments` (`enabled`, `maxBytes`, `quotaBytes`, `usedBytes`), so the client refuses early and hides the attach button when attachments are off. The server enforces everything anyway. |
| D19 | **The client never opens, runs or previews a file.** **Save…** writes to a path the user chose: it downloads into `PATH.part` in the same directory, verifies (D2, D12), then renames. The suggested name is sanitized (no separators, control characters, leading dots or Windows reserved names). A failed check deletes the part file and shows "This attachment was changed on the server". |
| D20 | **New room permission `AttachFiles` (bit 4)**, needed together with `SendMessages` (maintainer, 2026-11-19). It joins the default everyone set. The migration adds it to every existing room's `everyone_permissions`, so nothing changes until a manager takes it away. `ManageRooms`/`EditRoom` holders may grant it, like the other room bits. |
| D21 | **Default limits** (maintainer): 25 MiB per file (`HAYCHAT_ATTACHMENT_MAX_BYTES`), 1 GiB stored per account (`HAYCHAT_ATTACHMENT_ACCOUNT_QUOTA_BYTES`), 512 MiB uploaded per account per hour (`HAYCHAT_ATTACHMENT_UPLOAD_BYTES_PER_HOUR`), no global cap (`HAYCHAT_ATTACHMENT_CAPACITY_BYTES`, 0 = none), and a free-disk reserve of 1 GiB (`HAYCHAT_ATTACHMENT_MIN_FREE_BYTES`). The begin statement reserves the declared size, so concurrent uploads cannot overshoot a quota. |
| D22 | **Admin moderation** (maintainer): admins see storage use per account (Admin → Storage) and remove any attachment from its card's context menu. The blob becomes Removed (its file is deleted, the row stays as a tombstone, and it no longer counts toward the quota). The message stays and shows "Attachment removed by an admin". This is admin-only, like kick and ban, with no assignable permission. `deploy/sql/attachment-usage.sql` and `remove-attachment.sql` serve operators without a client (a removal by SQL reaches clients on their next history fetch, as for #75). |
| D23 | **Image previews come later** (maintainer): a follow-up package decodes PNG/JPEG/GIF/WebP from the downloaded file in the client (SDL3_image), loaded automatically up to a size limit, which works in encrypted rooms too. Round one shows file cards only. |
| D24 | **Retire the placeholders.** `ClientUploadFile` … `ServerDeleteFileResponse` (123-128) are retired and pinned as unused, as #33 does for others. New messages go at the end of `MessageType`. `router_test.odin`'s unsupported-message example moves to another retired value. |

## Design

### Schema (migration +1, in F1; `attachment_count` and the permission bit in F2)

```
attachments(
  id                 BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  blob_id            BYTEA NOT NULL UNIQUE CHECK (octet_length(blob_id) = 16),
  owner_user_id      BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  room_id            BIGINT NULL REFERENCES rooms(id) ON DELETE SET NULL,
  peer_user_id       BIGINT NULL REFERENCES users(id) ON DELETE SET NULL,  -- DM recipient
  encrypted          BOOLEAN NOT NULL,
  state              SMALLINT NOT NULL,   -- Uploading 0, Ready 1, Bound 2, Removed 3
  size               BIGINT NOT NULL,     -- declared at begin, exact at finish (stored bytes)
  received           BIGINT NOT NULL DEFAULT 0,
  sha256             BYTEA NULL,          -- set at finish
  chat_message_id    BIGINT NULL REFERENCES chat_messages(id) ON DELETE SET NULL,
  direct_message_id  BIGINT NULL REFERENCES direct_messages(id) ON DELETE SET NULL,
  created_at, last_chunk_at, completed_at, bound_at TIMESTAMPTZ,
  removed_by_user_id BIGINT NULL REFERENCES users(id) ON DELETE SET NULL,
  removed_at         TIMESTAMPTZ NULL,
  CHECK (room_id IS NULL OR peer_user_id IS NULL),
  CHECK (chat_message_id IS NULL OR direct_message_id IS NULL)
)
-- indexes: (owner_user_id, state), (chat_message_id), (direct_message_id), (state, last_chunk_at)
```

The quota sums `size` over the owner's rows that are not Removed. The hourly rate sums `size`
over the owner's rows created in the last hour in any state. The sweeper never deletes a row
younger than an hour, so a cancelled or swept upload still counts toward the rate for that hour.

F2 adds `chat_messages.attachment_count` and `direct_messages.attachment_count` (`SMALLINT NOT
NULL DEFAULT 0`, 0..4), relaxes the plaintext content CHECK to "1..4000 characters, or 0 with
attachments", and adds `AttachFiles` to every room's `everyone_permissions` and to the column
default.

### Transfer protocol

Control (CBOR, sealed, channel 1). Every name is a placeholder until the merge:

```
ClientAttachmentUploadBegin   { requestId u32, roomId, recipientUserId, size u64, encrypted }
ServerAttachmentUploadReady   { requestId, blobId [16]u8, received u64, chunkBytes, windowChunks }
ClientAttachmentUploadResume  { blobId }                     -- answered by UploadReady
ClientAttachmentUploadFinish  { blobId, sha256 [32]u8 }
ServerAttachmentUploadDone    { blobId, size, sha256 }
ClientAttachmentDownload      { blobId, offset u64 }
ServerAttachmentDownloadBegin { blobId, size, offset }
ClientAttachmentCancel        { blobId }                     -- upload or download
ServerAttachmentRefused       { requestId, blobId, message } -- every refusal, by request or blob
```

Exactly one of `roomId`/`recipientUserId` is set. Channel 5 carries binary packets with kind
`UploadChunk`, `UploadAck`, `DownloadChunk` and `DownloadAck`, sealed as
`sealFilePacket`/`openFilePacket` (AAD = the transport AAD for channel 5 ‖ the kind byte, as
`makeVoiceAAD` does for voice).

**Upload:** begin → database statement (D11 checks, quota, rate, capacity, insert Uploading, new
random blob ID) → storage worker (free-disk reserve via `statvfs`/`GetDiskFreeSpaceEx`, create
`incoming/<hex>.part` 0600) → `UploadReady`. A refusal from the storage worker deletes the row
again ("Server storage is full"). The client sends chunks in order from `received`. The router
checks the session owns the transfer and that `offset == received`, then hands the chunk to the
storage worker, which appends it, updates the running SHA-256 and answers. The router seals an
`UploadAck`. On finish, the storage worker compares size and hash, fsyncs, renames into
`blobs/<2 hex>/<32 hex>` and fsyncs the directory. The database then marks the blob Ready →
`UploadDone`. A mismatch deletes the blob ("Upload did not match"). On resume, the storage worker
re-reads the part file to rebuild the hash state.

**Download:** request → database statement (D10) → `DownloadBegin` → the router asks the storage
worker for up to `windowChunks` chunks from `offset` and refills as `DownloadAck`s arrive, paced
by D8. A session's transfers end with the session: the router cancels them on disconnect.

**Where the bytes go:** the network thread hands channel 5 packets to the router like control
packets (transport keys live there). The router opens and seals them, and plaintext chunks move
between the router and the storage worker by IPC. That puts file-rate crypto on the main thread.
XChaCha20-Poly1305 at the D8 caps costs little next to it, but F1 measures it (see Risks).

### Encrypted attachment format (`common/attachment_e2ee.odin`)

```
stored blob   = header ‖ chunk_0 ‖ … ‖ chunk_n
header        = version u8 (1) ‖ chunkBytes u32 LE (65536)
plaintext     = file ‖ zero padding up to padme(size)
chunk_i       = XChaCha20-Poly1305(fileKey, nonce_i, plaintext[i*chunkBytes : …], AAD_i) (with tag)
nonce_i       = i u64 LE ‖ 16 zero bytes
AAD_i         = "haychat-attachment-v1" ‖ version ‖ chunkBytes u32 LE ‖ i u64 LE ‖ last u8
```

The key is fresh per file and used for one blob, so a counter nonce is safe, as long as each
chunk is encrypted once (D12). The `last` flag stops truncation. Chunk-wise opening lets the
client write only authenticated bytes to the part file. After the last chunk the client checks
the whole blob's SHA-256 against the sealed one and checks that the padding is zero.

Sealed message plaintext (design 4.4) gains an optional key:

```
{ "content": text,                       -- may be empty with attachments (D15)
  "attachments": [ { "blobId": bytes16, "key": bytes32, "sha256": bytes32,
                     "size": uint, "name": text, "type": text }, … ] }   -- 1..4
```

The outer payload carries only `attachmentIds` (for the server's binding). The client downloads
by the inner IDs. If the outer list differs from the inner one, the client shows the files as
unavailable ("This message's attachments were changed on the server"). Old history has no
`attachments` key and decodes as today.

### Wire payload changes (F2)

```
AttachmentRef { blobId [16]u8, size u64, sha256 [32]u8, name, mediaType, removed bool }
```

`ClientChatMessagePayload`, `ServerChatMessagePayload` and `StoredChatMessage`, and the
plaintext and sealed direct message payloads, gain `attachments: [dynamic]AttachmentRef`.
Plaintext messages fill every field and sign it (D14). Sealed messages fill only `blobId` and
`size` (stored bytes) and `removed`, and the rest is inside the seal. The `*_deinit` helpers free
the names. `ServerAuthSuccess` gains `attachments: AttachmentLimits` (D18).

### Moderation (F3)

```
ClientAdminAttachmentUsage   {}
ServerAdminAttachmentUsage   { usedBytes, capacityBytes, freeBytes,
                               accounts: [{ userId, bytes, count }] }   -- top 100 by bytes
ClientAdminRemoveAttachment  { blobId, reason }    -- answered by ServerAdminActionResult
ServerAttachmentRemoved      { blobId, roomId, senderId, recipientId }
```

The removal is checked with `DATABASE_ACTOR_IS_ADMIN_SQL` in the update statement. The router
asks the storage worker to delete the file and fans `ServerAttachmentRemoved` out to the room's
members, or to both DM participants. Active downloads of that blob are cancelled.

### Client

- **Transfers** run on a client transfer worker thread (file reads and writes, hashing, chunk
  encryption). The network worker only moves sealed packets. Progress and results come back as
  events, and the harness prints them as `attachment_progress`, `attachment_done` and
  `attachment_error` JSON lines.
- **Composer:** a paperclip button (`SDL_ShowOpenFileDialog`) and drag-and-drop
  (`SDL_EVENT_DROP_FILE`) add file chips with a progress bar and a remove button. **Send** waits
  for the uploads and is disabled with a reason while any fails. An attachment that is too large
  or over quota is refused before upload, from D18's limits. The composer's encryption rule is
  the conversation's: an encrypted conversation uploads encrypted, and the DM plaintext fallback
  switch covers its files too.
- **Message rows:** the transcript today draws only text units (`client/ui/transcript.odin`). It
  needs a file-card unit: name, size, media type label, and **Save…** (`SDL_ShowSaveFileDialog`)
  with progress, **Cancel**, and the D19 and D12 failure texts. For admins, the card's context
  menu offers **Remove attachment**, with a confirmation.
- **Admin → Storage:** used, capacity and free space, and the account list by usage.
- **Nothing on disk** but the file the user saved. No cache in round one, and keys never reach
  disk outside the key store's existing chain cache (the file keys are in the messages
  themselves).

### Configuration (F1, `docs/server-configuration.md` and `.env.example`)

| Variable | Default | Meaning |
| --- | --- | --- |
| `HAYCHAT_ATTACHMENTS_ENABLED` | `true` | Off: begin is refused and clients hide the attach button. Stored files stay readable. |
| `HAYCHAT_ATTACHMENT_DIR` | `attachments` | Blob directory (D4). |
| `HAYCHAT_ATTACHMENT_MAX_BYTES` | 25 MiB | Largest stored blob (ciphertext with padding and tags counts). |
| `HAYCHAT_ATTACHMENT_ACCOUNT_QUOTA_BYTES` | 1 GiB | Stored per account; 0 = none. |
| `HAYCHAT_ATTACHMENT_UPLOAD_BYTES_PER_HOUR` | 512 MiB | Uploaded per account in any hour; 0 = none. |
| `HAYCHAT_ATTACHMENT_CAPACITY_BYTES` | 0 | Global cap; 0 = none. |
| `HAYCHAT_ATTACHMENT_MIN_FREE_BYTES` | 1 GiB | Free-disk reserve on the blob directory's volume. |
| `HAYCHAT_ATTACHMENT_PENDING_HOURS` | 24 | Unbound uploads are swept after this. |
| `HAYCHAT_ATTACHMENT_SESSION_BYTES_PER_SECOND` | 4 MiB | Per-session transfer pace, both directions together. |

Each one gets a `_MIN`/`_MAX` clamp in `validateAndNormalizeConfig` like the voice variables.
`docs/server-configuration.md`'s Retired Variables section names the new variables next to the
old ones.

## Packages

Strictly sequential, each launched from fresh `main` after the previous one merges. Each
package is a Forgejo issue that depends on the one before it.

### F1: Blob store and transfer (#120; protocol +1, migration +1)

- `attachments` table, the storage worker thread and its IPC ring, the configuration above,
  startup checks (D4), and the sweeper (stale uploads, unbound blobs, orphan file scan). The
  router runs it hourly and at startup through the database and storage workers.
- Channel 5 on both sides, `TransportChannel.File` and transport v3, `common/attachment_wire.odin`,
  and begin, resume, finish, cancel and download with D8 flow control and the per-session caps.
  Until F2 the download check is "owner only", so F1 ships no reader for other accounts.
- Retire 123-128 (D24).
- Client transfer worker and the harness commands `attach-upload ROOM|@USER FILE`,
  `attach-resume BLOB`, `attach-download BLOB OUT`, `attach-cancel BLOB`.
- Tests: wire round trips and pins, the begin statement's every refusal (no membership, no Send,
  DM to a restricted account without a shared room, quota, rate, capacity, size), hash
  mismatch, resume offsets, the sweeper, flow-control caps, and a two-process round trip of a
  25 MiB file that measures control-packet latency during the transfer.

### F2: Attachments on messages (#121; protocol +1, migration +1)

- `AttachmentRef` on every message payload, `attachment_count`, binding in the room, sealed room,
  DM and sealed DM insert statements, and the D10 download check (sharing its history predicate
  with the history statements, not a copy).
- `RoomPermission.AttachFiles` (bit 4, pinned) in `ROOM_PERMISSIONS_DEFAULT` and
  `ROOM_PERMISSIONS_ALL`, its migration, begin and bind checking it, and its checkbox on the room
  Permissions page.
- `signPlaintextRoomMessage`/DM v2 (D14), the sealed CBOR `attachments` key and empty content
  (D15), `common/attachment_e2ee.odin` with Padmé, and new vectors in `dev/tools/e2ee-vectors.py`.
- `ServerAuthSuccess.attachments` (D18).
- Harness: `send`/`dm` gain `--attach BLOB` (repeatable), and message events carry
  `attachments`. `attach-download` verifies and decrypts by message.
- Tests: tamper tests for every v2 signature field and every encrypted-format field (chunk
  swap, truncation, last-flag, padding, wrong key, outer/inner ID mismatch), binding refusals
  (someone else's blob, another conversation, bound twice, plaintext blob in an encrypted room),
  From join newcomers refused older files, removed members refused, and room deletion sweeping
  the files.

### F3: Moderation and usage (#122; protocol +1)

- `ClientAdminAttachmentUsage`, `ClientAdminRemoveAttachment`, `ServerAttachmentRemoved` (D22),
  `deploy/sql/attachment-usage.sql` and `remove-attachment.sql`, and the harness commands
  `attach-usage` and `attach-remove BLOB`.
- Tests: non-admin refused, tombstone frees quota, fan-out reaches exactly the readers, and an
  active download is cancelled.

### F4: Client UI (#123)

- Composer attach button, drag-and-drop, chips with progress, send gating, file cards with
  **Save…** and **Cancel**, the failure texts, the admin **Remove attachment** menu item and
  Admin → Storage. The GUI IDs go in `client/AGENTS.md` for the ui-smoke step.
- `dev/ui-smoke.sh`: GUI alice attaches a file in a room (the file dialog is bypassed by a
  ui-script command that adds a path, since automation cannot drive a native dialog), headless
  bob downloads it, alice saves bob's file, and admin alice removes one.

### F5: Proof and docs (#124)

- `dev/attachment-proof.sh` in `dev/live-proof.sh --attachments` and `--all`: plaintext room,
  encrypted room and encrypted DM round trips with hash checks; refusals (non-member, From join
  newcomer, AttachFiles revoked, quota, size); resume after killing the uploader mid-file;
  admin removal; room deletion empties the blob from the directory; chat latency during a
  25 MiB transfer stays under a bound.
- Docs: `docs/protocol.md` (Attachments), `docs/rooms-and-accounts.md` (AttachFiles,
  moderation), `docs/server-configuration.md` and `.env.example`, `deploy/README.md` (the
  volume, backing it up with the database, and restore order), `docs/user-guide.md`,
  `docs/testing-harness.md`, the three `AGENTS.md` files, and the `docs/README.md` index.

### Later

- **F6: image previews** (D23).
- A local download cache, if previews want one, encrypted at rest for encrypted conversations.
- Per-role quotas, and an assignable `ManageAttachments` permission if admins want delegated
  moderation (D22 chose admin-only).
- Moving file crypto off the router thread if F1's measurement asks for it.

## Threat model notes

- **Encrypted conversations:** the server learns ciphertext sizes (Padmé-rounded), how many
  files each message has, who uploaded and who downloaded each blob, and when. It cannot read
  names, media types or content, and cannot swap a file without the recipient's hash check
  failing. A removed member keeps files already saved but cannot fetch more.
- **Plaintext conversations:** the server sees everything, as with their text today. The sender's
  signature stops another account or the server from swapping the file under the message.
- **Malicious files:** nothing is opened, executed or decoded in round one (D19). Previews (F6)
  are the first decoding of untrusted bytes and get their own review.
- **Storage abuse:** quotas, the hourly rate, the per-session pace and the free-disk reserve
  bound one account. The per-IP registration limit (#105) bounds how many accounts one person
  makes.

## Risks

- **Main-thread crypto and IPC copies** at file rates could slow chat routing. F1 measures it
  with a 25 MiB transfer. The fix, if it is needed, is giving the storage worker the File
  channel keys.
- **ENet head-of-line:** channels are sequenced separately, but the peer's reliable window is
  shared. The 8-chunk window keeps the queue short, and F1's latency measurement checks it.
- **One database connection:** begin, finish and bind are small statements, and no file bytes
  touch PostgreSQL.
- **Backups:** the database and the blob directory must be backed up together. Rows without
  files show "unavailable". Files without rows are swept by the startup scan.
- **Disk full:** the free-disk reserve refuses uploads before the volume that also holds logs
  fills. `deploy/` puts blobs on their own volume.

## Round Status (2026-11-19)

All five packages merged in order, each from fresh `main`:

| Package | Issue | PR | Numbers |
| --- | --- | --- | --- |
| F1: blob store and transfer | #120 | #126 | protocol 26, migration 14 (`attachments`), transport v3 |
| F2: attachments on messages | #121 | #127 | protocol 27, migration 15 (`attachment_count`, AttachFiles) |
| F3: moderation and usage | #122 | #128 | protocol 28, no migration |
| F4: client UI | #123 | #129 | no protocol or migration change |
| F5: proof and docs | #124 | F5_PR | no protocol or migration change |

The documents in `docs/` describe what was built. These departures changed a decision above:

- **The sweeper deletes rows before files** (D17 said files, then rows). A blob whose row is gone
  can no longer be bound, resumed or downloaded, so there is no race with a bind; a file a crash
  leaves behind has no row and the startup scan removes it.
- **Cancelled and mismatched uploads become tombstones** (state Removed) instead of being
  deleted, so they leave the quota at once but still count toward the hourly rate. Only the
  free-disk refusal at begin deletes its row, since nothing was stored.
- **Begin checks the room's encryption flag and that the room has chat** (D11 left the encryption
  match to binding), so a plaintext blob never enters an encrypted room. Binding checks again.
- **`attachments.name`, `media_type` and `position` columns** (F2) hold a plaintext message's
  file names, which the plan did not place; a tombstone keeps them with `sha256` and `size`,
  because the message's v2 signature covers them. Binding also checks the listed size and
  plaintext hash against the stored blob.
- **`AttachDenied`** ("You cannot attach files in this room") is reported apart from
  `SendDenied`, at begin and at binding.
- **A direct message with files is not queued** while the peer's key is fetched (F2, kept in
  F4): it stays in the draft with "Setting up encryption…".
- **The hourly tombstone pass** (F3) deletes the files of the newest 1000 bound tombstones again,
  which is how a removal made in SQL (`deploy/sql/remove-attachment.sql`) leaves the disk.
- **Admin → Storage is a subsection** of Server settings after the Admin section (F4), not a page.
- **D9 in practice** (F5): the server lets the owner resume an Uploading blob from any session,
  but the client keeps transfer state only in memory, so only an upload its own process started
  can be resumed. After the uploader's process ends, plaintext and encrypted uploads alike start
  over as a new blob, and the old one goes with the stalled uploads. `dev/attachment-proof.sh`
  proves this (step 14) next to the resume after a reconnect (step 5).
- **Live proof of the sweeper** (F5): the proof starts a second server of its own (fresh
  database, small limits, port 12347), backdates rows with psql while it is stopped and starts it
  again, so the startup sweep and scan run without a production knob. The chat latency bound is
  now 250 ms (`ATTACHMENT_PROOF_P95_LIMIT_MS`); measured p95s during 25 MiB transfers were 11 to
  16 ms on every run.

## Follow-ups After F5 (2026-11-19)

Collected from the PRs of F1-F5. The lead files them as issues.

1. **Router-thread crypto** (F1): move file crypto off the router thread if concurrent
   full-pace transfers become common. F1 measured about 130 MB/s, roughly 3% of the thread per
   session transferring at full pace; the fix is handing the storage worker the session's file
   channel halves, as the voice halves go to the network thread.
2. **Startup orphan scan size** (F1): the scan sends every file older than an hour in one
   message and one `Known` lookup; batch both for large blob directories.
3. **Capacity and usage scans** (F1, F3): the capacity check and the usage statement scan every
   live row; use a running total or an index on `state`.
4. **Client network worker cadence** (F1): its 5 ms sleep sets the chat latency floor (about
   10 ms) and the download cadence; wake it on transfer activity.
5. **Lost session notice** (F1): the transfer worker notices a lost session by polling every
   20 ms; have the network worker notify it.
6. **Queued direct messages with files** (F2, F4): a DM with files is not queued while the
   peer's key is being fetched.
7. **Protocol errors name no message** (F2): one refused sealed message sends all of a room's
   in-flight messages back to the draft.
8. **`file_deleted_at`** (F3): a column (a migration) so the hourly tombstone pass skips files it
   already deleted, instead of repeating up to 1000 idempotent deletes an hour.
9. **`messageId` in `ServerAttachmentRemoved`** (F3), so a client finds the entry without
   scanning its caches.
10. **Removal audit trail** (F3): an optional `attachment_removals` table for admins to see past
    removals and their reasons in the client; today the reason is only logged.
11. **Transfer worker unit tests** (F3): the client transfer worker has no unit test harness, and
    `ClientTransferWorker_abandonDownloads` has only live coverage.
12. **Retry on a failed upload chip** (F4), using the worker's resume.
13. **Stale chips** (F4): clear chips when a server is removed or the account loses AttachFiles.
14. **Hidden chips** (F4): chips stay hidden while a room's composer is replaced (read-only or
    voice-only) and come back with it.
15. **"Saved as" for the whole session** (F4): saves are kept per file until the app restarts.
16. **Native file dialogs** (F4): a manual check on a real Linux desktop (portal or zenity) and
    on Windows; CI exercises only the automation path.
17. **Long Storage list** (F4): the account list can be 100 rows long at the end of Server
    settings.
18. **Later** (D23, D22): F6 image previews, a local download cache, and per-role quotas or an
    assignable ManageAttachments permission.
19. **A missing blob file reads as "Server storage error"** (F5): a row whose file is gone (a
    database restored without its blob directory) fails the download with the storage error,
    not "Attachment not found", so the card does not say "Attachment unavailable". The storage
    worker could report a missing file apart from a read error.
20. **A guard for a wrong restore order** (F5): a server started with a restored blob directory
    and an empty or older database deletes every file older than an hour as an orphan. The
    startup scan could refuse to delete more than a share of the directory (or anything, when
    the table is empty) without an operator's say-so. `deploy/README.md` now gives the order.
21. **Resume after a client restart** (F5, D9): a plaintext upload could resume at the acked
    offset after a restart if the client kept the blob ID and path on disk; encrypted uploads
    cannot (their sealed chunks are never re-encrypted). Only worth it if users upload large
    files over unreliable links.
22. **A clock hook for sweeper tests** (F5): the live proof backdates rows with psql and
    restarts its own server; a test-only way to run a sweep pass on demand would let the main
    live server prove the hourly path (and the tombstone pass) without a restart.
