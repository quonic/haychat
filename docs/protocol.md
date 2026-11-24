# Transport and Protocol Versions

How a HayChat client and server talk to each other, and what changed in each protocol version.
For the wire rules that code must follow (packet ownership, enum numbering, voice framing), see
"Chat Protocol And Ownership" in [AGENTS.md](../AGENTS.md).

## Transport Encryption

- **Identities.** Every client and server has an Ed25519 identity key. The client pins the
  server's key on its first connection and refuses a different one later (see "Failures that
  stop retrying" in the [user guide](user-guide.md#connection-status-and-reconnecting)).
- **Key exchange and packets.** The handshake uses X25519 and derives six keys with HKDF
  (`"haychat transport v3"` since protocol 26): control, voice and file, one per direction.
  Packets are sealed with XChaCha20-Poly1305.
- **Channels.** Everything runs over ENet on one UDP port. The control channel (ENet channel 1)
  carries CBOR packets and keeps a strict sequence counter; the voice channel (ENet channel 2)
  carries binary voice datagrams with a 64-packet replay window, and each datagram's kind byte
  is bound into its authentication tag. The file channel (ENet channel 5, protocol 26) carries
  binary attachment chunks and acknowledgements, reliable and ordered, with a strict sequence
  counter like control ([below](#attachment-transfers-protocol-26)).
- **End-to-end for direct messages and encrypted rooms.** Since protocol 17 a direct message is
  end-to-end encrypted whenever both sides can: the sender's client seals it to the recipient's
  pinned key, and the server stores and forwards an envelope it cannot open
  ([below](#encrypted-direct-messages-protocol-17)). When the recipient cannot receive
  encrypted messages, sending is refused unless the user turns on **Send without encryption**
  for that conversation; such a message is signed but the server can read it, and both
  clients mark it "Unencrypted". Since protocol 19 every message in an encrypted room is
  end-to-end encrypted with its sender's chain key, which only the members the room's signed
  member list names receive ([below](#sender-chains-in-encrypted-rooms-protocol-19)); the
  server stores sealed bytes only; since protocol 20 members of a Full history encrypted room
  hand the older keys to a new member ([below](#full-history-in-encrypted-rooms-protocol-20)).
  Unencrypted rooms (every Public room, and invite rooms
  created without **Encrypt this room**) are not end-to-end encrypted: the server decrypts
  their messages and stores them unencrypted in its PostgreSQL database, so the server and its
  operator can read them; since protocol 22 each one is signed by its sender, so the server
  cannot forge one ([below](#signed-messages-protocol-22)). Voice is relayed and
  never stored or logged; since protocol 21 voice in an encrypted room is end-to-end encrypted
  too ([below](#encrypted-voice-protocol-21)), while voice in an unencrypted room is readable
  by the server as it relays it. Invite-only rooms
  (protocol 15) limit which accounts the server lets read a room; without encryption they do
  not hide it from the server. The server always sees who writes to whom and when.

No TLS certificate is involved: the pinned identity key takes its place.

## Protocol Versions

A client and a server must speak the same protocol version (`protocolVersion` in
`common/protocol.odin`). Otherwise they refuse each other with "Unsupported protocol version",
which the client shows as "This client and the server speak different protocol versions". Every
version below therefore needs clients and servers rebuilt together.

| Version | What it added |
| --- | --- |
| 7 | Direct messages, the user list and presence |
| 8 | `ServerAuthSuccess.isAdmin`, which tells a client to show the room management controls |
| 9 | The per-channel key schedule: four HKDF keys, the control sequence counter, and the voice replay window |
| 10 | Voice control messages (join, leave, mute and deafen state, participant lists), and the voice datagram's kind byte in its authentication tag |
| 11 | Server-side read state: read markers and unread counts (schema migration 2) |
| 12 | `ServerVoiceParticipants.recipientJoined`, so a client completes a voice join only on the acknowledgement of its own session, not on any list that names its account |
| 13 | One voice session per account: every voice join carries the profile's device ID and whether it is the automatic re-join after a reconnect; a join without a device ID is refused |
| 14 | Admin actions on accounts (role, rename with name lock, kick, ban and unban) and room types (text, voice, or both), with schema migration 3 |
| 15 | Room access modes (Public, Member invite, Admin invite) and history for new members (From join or Full), creating a room without joining it, `ClientLeaveRoom`, member adds by members of Member invite rooms, `ClientFetchRoomMembers`/`ServerRoomMembers`, `ClientAdminListRooms`/`ServerAdminRooms`, and `ServerRoomMembershipChanged.userId`, with schema migration 4 |
| 16 | Account encryption keys (end-to-end encryption, part 1): `ClientPublishEncryptionKey` (each profile's X25519 key, signed by its identity key, sent once per session), `ClientFetchUserKeys`/`ServerUserKeys` (at most 64 accounts per request; accounts without a key are listed as missing), `ServerUserKeyChanged` (an account stored a new key), and `UserSummary.identityPublicKey`/`hasEncryptionKey`, with schema migration 5 (`user_encryption_keys`). No message is encrypted yet |
| 17 | Encrypted direct messages (end-to-end encryption, part 2): `ClientSealedDirectMessage`/`ServerSealedDirectMessage` (an envelope the sender sealed for itself and the recipient, carried byte for byte), the envelope, client message ID and signature fields of `StoredDirectMessage` and `DirectConversationSummary`, and the signed plaintext fallback (`ClientDirectMessage` now needs `clientMessageId` and `signature`; unsigned messages are refused), with schema migration 6 |
| 18 | Encrypted rooms and their signed member log (end-to-end encryption, part 3a): `ClientAppendRoomLog`, `ClientFetchRoomLog`, `ServerRoomLog`, `RoomSummary.encrypted`/`logVersion`, `ClientCreateRoomPayload.encrypted` and `ClientEditRoomPayload.encrypted`, with schema migration 7 (`rooms.encrypted`, `rooms.log_version`, `room_log_entries`, `room_log_managers`). Encrypted rooms take no message and no voice yet |
| 19 | Sender chains in encrypted rooms (end-to-end encryption, part 3b): sealed room messages (`ClientChatMessagePayload`, `ServerChatMessagePayload` and `StoredChatMessage` gain `clientMessageId` and `sealed`), `ClientRoomKeyEnvelope`/`ServerRoomKeyEnvelope`, `ClientFetchRoomKeys`/`ServerRoomKeys`, `ClientRequestRoomKey`/`ServerRoomKeyRequest`, with schema migration 8 (sealed `chat_messages` columns, `room_key_envelopes`). Plaintext in an encrypted room is refused |
| 20 | Full history in encrypted rooms (end-to-end encryption, part 4): `RoomKeyForward` envelopes (`ClientRoomKeyEnvelopePayload.senderId` names the chain's sender, `RoomKeyEnvelope.forwarderId` the forwarding account), `ServerRoomKeyRequest.senderId`, and key requests relayed to every member of a Full history room, with schema migration 9 (`room_key_envelopes.forwarder_user_id`) |
| 21 | Encrypted voice in encrypted rooms (end-to-end encryption, part 5): voice joins of encrypted rooms are accepted, `ClientVoiceKey`/`ServerVoiceKey` (a participant's `VoiceKey` envelope, kind 4), `ClientRequestVoiceKey`/`ServerVoiceKeyRequest`, and sealed voice payloads in the frames of encrypted rooms. No schema migration: voice keys are never stored |
| 22 | Signed room messages (#90): `ClientChatMessagePayload`, `ServerChatMessagePayload` and `StoredChatMessage` gain `signature`, and every plaintext room message carries a random `clientMessageId` and its sender's signature (`signPlaintextRoomMessage`); the server refuses unsigned plaintext ("Invalid room message signature") and a reused client message ID, and clients show no room or direct message without its sender's valid signature (#82). Schema migration 10 deletes every unsigned message ([below](#signed-messages-protocol-22)) |
| 23 | Roles and server permissions (#95, [below](#roles-and-server-permissions-protocol-23)): `ServerPermission`/`ServerPermissions`, `RoleSummary`, `UserSummary.roleIds`, `permissions` in `ServerAuthSuccess` and `ServerAccountUpdated`, `ClientAdminListRoles`/`ServerRoleList`, `ClientAdminSaveRole`, `ClientAdminDeleteRole`, `ClientAdminSetUserRoles`, `ServerRoleUpdated`, `ServerRoleDeleted`, the `SaveRole`, `DeleteRole` and `SetUserRoles` admin actions with `ServerAdminActionResult.roleId`, with schema migration 11. Room management and member management check the permissions instead of the admin role. The never-sent role placeholders `ClientGetRoles` … `ServerRemovedRole` are retired |
| 24 | Room permissions and role rooms (#96, [below](#room-permissions-and-role-rooms-protocol-24)): `RoomPermission`/`RoomPermissions`, `RoomSummary.myPermissions`, `RoomAccess.Role` (4) with `accessRoleIds` on `ClientCreateRoom` and `ClientEditRoom`, `ClientAdminSetRoomPermissions`, `ClientAdminFetchRoomPermissions`/`ServerAdminRoomPermissions`, with schema migration 12. Posts, voice, member changes and edits check room permissions; role changes add and remove Role room members |
| 25 | Registration (#43 G1, [below](#registration-protocol-25)): the plaintext handshake answer `ServerRegistrationRequired`, `ClientAuthRequestPayload.registering`, encrypted `ClientRegister{inviteCode, reason}` and `ServerRegisterResponse{status, message, auth}` (wire values 14 and 15 kept), the registration mode, invite codes, sign-up requests, restricted accounts (`UserSummary.isRestricted`, `registrationMode` and `isRestricted` in `ServerAuthSuccess`, `isRestricted` in `ServerAccountUpdated`), with schema migration 13. Restricted accounts see and message only accounts they share a room with |
| 26 | Attachment transfers (attachments F1, [below](#attachment-transfers-protocol-26)): the transport key schedule `"haychat transport v3"` (six keys, adding the file channel's pair), ENet channel 5 on both sides (six channels), `ClientAttachmentUploadBegin` … `ServerAttachmentRefused` (wire values 203 to 211) and the binary chunks of `common/attachment_wire.odin`, with schema migration 14 (`attachments`). The never-sent `ClientUploadFile` … `ServerDeleteFileResponse` (123 to 128) are retired. Files are not on messages yet: only a blob's owner may download it |
| 27 | Attachments on messages (attachments F2, [below](#attachments-on-messages-protocol-27)): `AttachmentRef` on every room and direct message payload (`attachments`) and `DirectConversationSummary.lastAttachments`, the v2 plaintext signatures (`"haychat-room-plain-v2"`, `"haychat-dm-plain-v2"`) for messages with files, the sealed plaintext's `"attachments"` key and the encrypted file format (`common/attachment_e2ee.odin`), `RoomPermission.AttachFiles` (4), `ServerAuthSuccess.attachments` (`AttachmentLimits`), the refusals "Invalid message attachments", "An attachment cannot be sent with this message" and "You cannot attach files in this room", with schema migration 15 (`attachment_count` on both message tables, the `attachments.position`/`name`/`media_type` columns, and Attach files added to every room's Everyone grant). The message inserts bind the listed blobs, and whoever may read a message may download its files |
| 28 | Attachment moderation (attachments F3, [below](#attachment-moderation-protocol-28)): `ClientAdminAttachmentUsage`, `ServerAdminAttachmentUsage`, `ClientAdminRemoveAttachment` and `ServerAttachmentRemoved` (wire values 212 to 215), `AdminAction.RemoveAttachment` (11) and `ServerAdminActionResult.blobId`. Admins see storage use per account and remove any file; the message stays and lists it as removed, and a reader's download of it is refused with "Attachment removed by an admin". No schema migration |
| 29 | Attachment removal log (#138, [below](#attachment-removal-log-protocol-29)): `ClientAdminListAttachmentRemovals{beforeId}` and `ServerAdminAttachmentRemovals{beforeId, entries, hasMore}` (wire values 216 and 217, `AttachmentRemovalEntry`), and `chatMessageId`/`directMessageId` in `ServerAttachmentRemoved`, with schema migration 16 (`attachment_removals`). Every removal, by an admin or `deploy/sql/remove-attachment.sql`, keeps a row with its reason that admins list in the client |
| 30 | Editing and deleting messages (#76, [below](#editing-and-deleting-messages-protocol-30)): `ClientEditRoomMessage` … `ServerMessageEdits` (wire values 218 to 227), `MessageEdit`, `MessageDeletion` and `MessageEditsKind`, `editCount`/`lastEdit`/`deleted`/`deletion` on `StoredChatMessage` and `StoredDirectMessage` and `lastEditCount`/`lastEdit`/`lastDeleted`/`lastDeletion` on `DirectConversationSummary`, and the signatures `"haychat-room-edit-v1"`, `"haychat-dm-edit-v1"`, `"haychat-room-delete-v1"` and `"haychat-dm-delete-v1"`, with schema migration 17 (edit and tombstone columns on both message tables, `chat_message_edits`, `direct_message_edits`). Authors edit and delete their messages, admins delete any room message, and a deleted message leaves a tombstone with its ID |
| 31 | Room changes for room managers (#73, [below](#room-changes-for-room-managers-protocol-31)): `ServerAdminRoomChanged{roomId, change}` (wire value 228) and `AdminRoomChange` (Created 0, Edited 1, Deleted 2, Members 3, Permissions 4). Holders of ManageRooms or ManageRoomMembers hear of every change to every room, so their list of every room and an open Permissions page follow other managers' changes. No schema migration |

Wire values 120 and 121 (`ClientStoreFile`, `ServerStoreFileResponse`) are retired placeholders
(#31): no client sent them, and the server answers `ClientStoreFile` with "Unsupported message
type". Nothing else on the wire changed, so the protocol version stayed 25.

The behaviour behind these versions is described in [rooms-and-accounts.md](rooms-and-accounts.md)
(rooms, admins, direct messages, read state) and the [user guide](user-guide.md#voice) (voice).

## Attachments

Files on room and direct messages, in three protocol versions (design and history in
`docs/plan/2026-11-19-file-attachments.md`): transfers (26), files on messages (27) and
moderation (28). The user-facing behaviour is in
[rooms-and-accounts.md](rooms-and-accounts.md#attachments) and the
[user guide](user-guide.md#files), the server variables in
[server-configuration.md](server-configuration.md#attachments).

### Attachment transfers (protocol 26)

The first part of attachments (`docs/plan/2026-11-19-file-attachments.md`, F1): a client uploads
a file and gets a blob ID. Protocol 27 (below) attaches blobs to messages and lets the
conversation's readers download them.

- **Control** (CBOR, encrypted, channel 1). `ClientAttachmentUploadBegin{requestId, roomId |
  recipientUserId, size, encrypted}` asks to upload `size` bytes to a room or a direct
  conversation. One database statement checks membership and SendMessages (or, for a direct
  message, a recipient the sender may message), the size, the account's quota and hourly upload
  limit and the server's capacity, and reserves the size; the storage worker then checks the
  free-disk reserve. The answer is `ServerAttachmentUploadReady{requestId, blobId, received,
  chunkBytes, windowChunks}`: a new random 16-byte blob ID. `ClientAttachmentUploadResume{blobId}`
  asks to continue an upload (answered by Ready with the bytes the server holds),
  `ClientAttachmentUploadFinish{blobId, sha256}` ends one (the server compares size and hash and
  answers `ServerAttachmentUploadDone{blobId, size, sha256}`), `ClientAttachmentDownload{blobId,
  offset}` is answered by `ServerAttachmentDownloadBegin{blobId, size, offset}`, and
  `ClientAttachmentCancel{blobId}` stops an upload (for good: it becomes a tombstone) or a
  download, with no answer. Every refusal is `ServerAttachmentRefused{requestId, blobId,
  message}` (the sentences are under [Attachment lifecycle](#attachment-lifecycle)).
  `ServerAttachmentDownloadBegin` carries no hash: the downloading client checks the one in the
  signed or sealed message. Since protocol 27 an upload to a room
  needs AttachFiles too ("You cannot attach files in this room"), and a download is allowed to
  whoever may read the message the blob is bound to (below), or to its owner before then.
- **Chunks** (binary, channel 5). `kind u8 ‖ blobId 16 ‖ offset u64 LE ‖ data`, kinds
  UploadChunk 1, UploadAck 2, DownloadChunk 3, DownloadAck 4; a chunk carries 1 to 65536 bytes
  and an ack none. Each is sealed as `kind ‖ sequence u64 LE ‖ ciphertext ‖ tag` with the
  session's file key for its direction, the nonce derived from the sequence, and the transport
  AAD for channel 5 followed by the kind byte. A packet that does not open, or arrives out of
  sequence, ends the session.
- **Flow control.** At most 8 unacknowledged chunks per transfer (the server acknowledges an
  upload chunk only once it is on disk; the client acknowledges each download chunk), at most 2
  uploads and 4 downloads per session, and a per-session pace for both directions together
  (`HAYCHAT_ATTACHMENT_SESSION_BYTES_PER_SECOND`), so chat packets never wait behind a file. A
  chunk outside the window or out of order ends that transfer. A session's transfers end with
  it, and its upload's part file stays: the owner may resume it from another session (see
  [Attachment lifecycle](#attachment-lifecycle) for what the client does).

### Attachments on messages (protocol 27)

The second part of attachments (`docs/plan/2026-11-19-file-attachments.md`, F2: D10-D16, D18,
D20). A message lists up to four uploaded blobs; the text may then be empty.

- **References.** `AttachmentRef{blobId, size, sha256, name, mediaType, removed}` in
  `ClientChatMessage`, `ServerChatMessage`, `StoredChatMessage` (history), `ClientDirectMessage`,
  `ClientSealedDirectMessage`, `ServerDirectMessage`, `ServerSealedDirectMessage`,
  `StoredDirectMessage` and `DirectConversationSummary.lastAttachments`, in the message's order.
  A plaintext message (an unencrypted room, or the direct message fallback) fills every field
  but `removed`: `size` and `sha256` are the stored file's, `name` is 1..255 bytes of UTF-8 with
  no control character, `/` or `\` (and not `.` or `..`), `mediaType` 1..100 bytes of ASCII
  `type/subtype`, a label only. A sealed message (encrypted room or direct message) fills only
  `blobId` and `size` (the stored ciphertext's); the rest is inside the seal. `removed` is the
  server's (an admin removed the file, F3) and is never signed. The router refuses a list that
  does not have this shape ("Invalid message attachments").
- **Binding.** The statement that stores the message binds the blobs it lists, or stores
  nothing: each must be the sender's, finished and bound to no message, uploaded to this room
  (or to a direct conversation with this recipient), encrypted exactly when the message is
  sealed, and have the size and (plaintext) hash the message names; no blob twice. A refusal is
  "An attachment cannot be sent with this message"; in a room without AttachFiles it is "You
  cannot attach files in this room". Echoes and history carry the bound list.
- **Signatures (D14).** A plaintext message without files keeps the v1 bytes (below, protocol
  22 and 17), so stored history still verifies. One with files is signed under
  `"haychat-room-plain-v2"` (or `"haychat-dm-plain-v2"`) over the v1 fields prefix followed by
  `contentLength u32 LE ‖ content ‖ count u8 ‖` for each file `blobId (16) ‖ sha256 (32) ‖
  size u64 LE ‖ nameLength u16 LE ‖ name ‖ typeLength u16 LE ‖ type`. The verifier picks the
  label from the count, so adding, dropping, reordering or changing a file fails the signature
  either way and the message is not shown.
- **Sealed messages (D12, D15).** The sealed plaintext map gains an optional `"attachments"`
  array of 1..4 maps `{"blobId": bytes(16), "key": bytes(32), "sha256": bytes(32), "size": uint,
  "name": text, "type": text}` (`size` is the file's own size, `sha256` the stored blob's).
  `content` may be empty only with it. A client compares the outer list with the inner one
  (same blob IDs in the same order, each outer size the sealed layout of the inner size) and
  otherwise shows the files as unavailable ("This message's attachments were changed on the
  server").
- **Encrypted files** (`common/attachment_e2ee.odin`): the stored blob is `version u8 (1) ‖
  chunkBytes u32 LE (65536) ‖ chunk_0 ‖ … ‖ chunk_{n-1}`, the file zero-padded to its Padmé
  length and sealed in 64 KiB chunks with XChaCha20-Poly1305 under a fresh 32-byte file key,
  nonce `index u64 LE ‖ 16 zero bytes`, AAD `"haychat-attachment-v1" ‖ version ‖ chunkBytes u32
  LE ‖ index u64 LE ‖ last u8`. Each chunk is sealed exactly once. A downloading client opens
  chunk by chunk, writes only authenticated bytes, checks that the padding is zero and the
  whole blob's SHA-256 is the sealed one, and otherwise deletes what it wrote ("This attachment
  was changed on the server"). The same hash check applies to plaintext files.
- **Downloads (D10).** `ClientAttachmentDownload` is allowed for a blob bound to a room message
  when the requester is a member of the room and may read the message (a From join member only
  messages created after it joined, as for history), for a blob of a direct message when the
  requester is its sender or recipient (also a restricted account whose shared rooms are gone),
  and for the owner's own blob before it is bound. Admins get no bypass; a removed blob is never
  downloadable.
- **Limits (D18).** `ServerAuthSuccess.attachments` is `AttachmentLimits{enabled, maxBytes,
  quotaBytes, usedBytes}`: whether uploads are on, the largest stored blob, the account quota
  (0 = none) and the account's stored bytes. Clients refuse a file early with them; the server
  checks every limit again at begin.

### Attachment moderation (protocol 28)

The third part of attachments (`docs/plan/2026-11-19-file-attachments.md`, F3: D22). Admins
only, like kick and ban: there is no assignable permission, and the server checks the admin
role in the statement that reads or changes, so a holder of every other permission is refused
("Admin permission required").

- **Removal.** `ClientAdminRemoveAttachment{blobId, reason}` makes a Ready or Bound blob a
  Removed tombstone and deletes its file. The row keeps every field a plaintext message's v2
  signature covers (size, hash, name, media type, position) and its message link, so the
  message still verifies and lists the file with `removed` set. An unknown, uploading or already
  removed blob is "Attachment not found". `reason` is optional: at most 500 bytes of UTF-8
  without control characters (otherwise "The reason must be at most 500 bytes, without control
  characters"). The server logs it with the blob, the admin and the owner and (protocol 29)
  keeps it in the removal log, which only admins list; it is never sent to anyone else. The
  answer is `ServerAdminActionResult{action = RemoveAttachment (11), userId = the owner,
  blobId}`.
- **Who hears.** `ServerAttachmentRemoved{blobId, roomId, senderId, recipientId,
  chatMessageId, directMessageId}` goes to every
  session of each account that may read the message: a room message's members who may read
  its history (a From join member who joined after the message hears nothing), both sides of a
  direct message, and the owner of a blob no message lists. For a room message `roomId` is the
  room and `senderId` the owner; for a direct message `senderId` and `recipientId` are its two
  sides; an unbound blob names the conversation it was uploaded to. Since protocol 29
  `chatMessageId` or `directMessageId` is the message the file was on (both 0 for an unbound
  blob), so a client marks that entry without scanning its caches; it scans only when both are
  0. Clients mark the file removed wherever they show it. The restricted-account rules hide this
  from nobody who could already read the message.
- **Downloads.** Every running download of the blob ends with `ServerAttachmentRefused{blobId,
  "Attachment removed by an admin"}`. A later download by a reader of the message is refused
  with the same sentence, and by anyone else with "Attachment not found".
- **Quota.** A tombstone counts toward no quota, capacity or `ServerAuthSuccess.attachments
  .usedBytes`; it still counts toward the hourly upload limit for the hour after its upload.
- **Usage.** `ClientAdminAttachmentUsage{}` is answered by `ServerAdminAttachmentUsage{usedBytes,
  capacityBytes, freeBytes, freeBytesKnown, accounts}`: every stored byte that is not a tombstone
  (an upload in progress counts with the size it reserved), `HAYCHAT_ATTACHMENT_CAPACITY_BYTES`
  (0 = no cap), the free space on the blob directory's volume (`freeBytesKnown` false when the
  server could not read it), and the top 100 accounts by those bytes as
  `AttachmentAccountUsage{userId, bytes, count}`, largest first.
- **Removal without a client.** `deploy/sql/remove-attachment.sql` makes the same tombstone
  (with no `removed_by_user_id`, and since protocol 29 a removal log row with no admin and an
  optional `-v reason=...`) but cannot reach the server: the server's hourly pass deletes
  the files of the newest bound tombstones again (and cuts off a download of one), its startup
  scan deletes every Removed blob's file, and clients see the file as removed on their next
  history fetch. `deploy/sql/attachment-usage.sql` shows the usage. See `deploy/README.md`.

### Attachment removal log (protocol 29)

Issue #138. Admins see past removals and their reasons in the client.

- **The log.** `attachment_removals` (migration 16) keeps one row per removal: the blob, its
  owner, the removing admin (none for `deploy/sql/remove-attachment.sql`, or for an admin
  account deleted since), the time, the reason, the room or whether it was for a direct
  conversation, the message the file was on, and a plaintext file's name. An encrypted file's
  name is inside its message's seal, which the server cannot open, so it has none. The admin
  removal statement writes its row in the same statement as the tombstone, so a removal never
  happens without its row; a refused removal writes none. Rows are kept indefinitely (removals
  are rare and a row is small) and are not tied to `attachments`, so a row outlives the sweeper
  deleting a tombstone's row; its room and message links turn empty when those go. Migration 16
  backfilled a row, without a reason, for every earlier removal (a tombstone that had been Ready
  or Bound), and none for cancelled or mismatched uploads.
- **Listing.** `ClientAdminListAttachmentRemovals{beforeId}` (admins only, checked in the
  statement; anyone else gets "Admin permission required", a negative cursor "Invalid admin
  request") is answered by `ServerAdminAttachmentRemovals{beforeId, entries, hasMore}`: at most
  50 entries, newest first, with IDs below `beforeId` (0 for the newest page), the cursor history
  uses; `hasMore` says older entries follow. Each `AttachmentRemovalEntry{id, blobId,
  ownerUserId, removedByUserId, removedAt, reason, roomId, direct, encrypted, chatMessageId,
  directMessageId, name}` has `removedByUserId` 0 for a removal made in SQL, `removedAt` as
  PostgreSQL `timestamptz` text, `roomId` 0 for a direct message or a deleted room, and `name`
  empty for an encrypted file or one never sent.

### Attachment lifecycle

- **States.** A blob is Uploading (0) until its finish matches, then Ready (1), Bound (2) once a
  message names it, and Removed (3) as a tombstone. A cancelled upload and one whose finish did
  not match ("Upload did not match") become tombstones too, so they stop counting toward the
  quota at once but still count toward the hourly limit. A begin the storage worker refuses
  (the free-disk reserve: "Server storage is full") leaves no row, since nothing was stored.
- **Begin refusals**, as `ServerAttachmentRefused`: "Attachments are disabled on this server",
  "Attachment is too large", "Attachment storage quota exceeded", "Attachment upload limit
  reached; try again later", "Server storage is full" (the capacity or the free-disk reserve),
  "Not a room member", "You cannot send messages in this room", "You cannot attach files in this
  room", "Chat is disabled in this room" (voice only), "Attachment encryption does not match
  the room" (begin
  checks the room's encryption flag, so a plaintext blob never enters an encrypted room),
  "Unknown direct message recipient", "You no longer share a room with this person" (a
  restricted account's direct message rule), and "Too many uploads at once".
- **Resume (D9).** While a blob is Uploading, its owner may resume it from any session at the
  offset the server holds (`ClientAttachmentUploadResume`): the storage worker rebuilds the hash
  from the part file. The client resumes only uploads its own process started, because it keeps
  each transfer's file path, its acknowledged offset and, for an encrypted upload, the sealed
  chunks still in flight in memory and never re-encrypts a chunk. An upload whose client process
  ended (it quit, crashed or was killed) is therefore never resumed: attaching the file again
  starts a new blob, and the old one is deleted by the sweeper as a stalled upload.
  `dev/attachment-proof.sh` proves both a resume after a reconnect and a killed uploader.
- **Sweeper (D17).** Hourly and at startup, one statement deletes the rows (then the storage
  worker the files) of blobs at least an hour old that no message holds and that are an upload
  without data for an hour, an upload or a Ready blob older than
  `HAYCHAT_ATTACHMENT_PENDING_HOURS`, a Bound blob whose message is gone (`ON DELETE SET NULL`:
  a deleted room's files), or an unbound tombstone. Rows go before files, so a blob whose row is
  gone can no longer be bound, resumed or downloaded; a blob with a transfer in progress is
  never swept. At startup the storage worker also lists every file older than an hour, and the
  server deletes those without a row, or whose row is in a state that has no such file (a part
  file of a finished blob, any file of a tombstone). Two guards against a wrong restore order
  (#131) keep every such file instead, with a warning: the `attachments` table has no row at
  all, or more than 10% of the listed files and more than 10 of them are orphans (the files of
  rows the startup sweep deletes meanwhile count as neither).
  `HAYCHAT_ATTACHMENT_ALLOW_ORPHAN_PURGE` lifts both for one start
  (`docs/server-configuration.md`, Attachments). The sweeper is not guarded: it deletes files
  only with their rows.
- **Missing files (#132).** A download whose row passes the check but whose file is not in the
  blob directory (a database restored without it) is refused with "Attachment not found", the
  same sentence as a blob the reader may not have, so the client shows "Attachment unavailable";
  the server logs the blob ID ("File of attachment … is missing from storage"). Any other read
  failure (a file that exists but cannot be read) is "Server storage error" and changes nothing.
  The server is not a backup of its files, so it then makes the row the same Removed tombstone
  an admin removal leaves (one statement, only while the row is still Ready or Bound: a removal,
  a message delete or a sweep that came first wins): the signed fields and the message link
  stay, so history lists the file as removed; every reader the statement names gets
  `ServerAttachmentRemoved` (with the message's ID); the removal log gets a row with no admin
  and the reason "File missing from storage", which admins see under Server settings → Removed
  files (removed by "an operator"); and later downloads are refused at the check without a disk
  read. No message or field is new: clients show the card as "Attachment removed by an admin",
  as for every removal. Two guards keep a volume that did not mount from turning many rows into
  tombstones at once; when one holds, nothing is marked, the download is still "Attachment not
  found", and the row stays as it is for the next download to try again:
  - **The blob directory looks absent or incomplete:** `blobs/` is missing, unreadable or
    empty, or the blob's shard directory `blobs/<2 hex>` is missing (the server never deletes
    shard directories, so a row's file always had one). The server logs a warning naming
    `HAYCHAT_ATTACHMENT_DIR` each time.
  - **Too many marks:** at most 10 marks in an hour (a window that starts with the first mark
    and is kept in memory, so a restart starts a new one). Past it the server logs one warning
    for the hour and marks nothing more until the hour ends.
- **Room deletion.** Deleting a room deletes its messages, which unlinks their files (and the
  room's unsent uploads). The first sweep pass after the deletion deletes them, so they leave
  the blob directory within an hour of it (or at the server's next start); a file uploaded less
  than an hour before the deletion waits for a later pass. The room's unsent uploads go after
  `HAYCHAT_ATTACHMENT_PENDING_HOURS`.

## Editing and deleting messages (protocol 30)

Issue #76, plan `docs/plan/2026-11-19-message-edit-delete.md` (decisions D1-D14). The author
edits and deletes their own room and direct messages; admins delete any room message. A delete
leaves a tombstone with the same ID, so history pagination and read markers stay stable.

- **Edits.** `ClientEditRoomMessage{roomId, messageId, originalClientMessageId,
  clientMessageId, content, signature, sealed}` and `ClientEditDirectMessage{peerUserId,
  messageId, originalClientMessageId, clientMessageId, content, signature, envelope}`.
  `clientMessageId` is the edit's own new random ID; `originalClientMessageId` repeats the
  message's, which the signature covers and the server compares with the stored message. A
  plaintext edit is signed by the author (`signRoomMessageEdit`, `signDirectMessageEdit`;
  layouts at the top of `common/e2ee.odin`) and checked by the router against the session's
  identity key. An edit of a sealed message must be sealed (D11): a `SealedRoomMessage` at the
  room's current epoch on the sender's chain, checked like a new sealed message, or a direct
  message envelope, verified by the database worker against the recipient's current identity
  key; the server stores it byte for byte. An edit changes the text only (D9): the message keeps
  its files, and an edit may be empty only when the message has some. At most
  `MESSAGE_EDITS_MAX` (100) edits per message (D12), with no time limit.
- **Sealed edits.** A sealed edit's `clientMessageId` is the edit's own, bound into the seal's
  AAD like a new message's, and its plaintext (the sealed message plaintext at the top of
  `common/e2ee.odin`) carries `"replaces": bytes(16)`, the edited message's `clientMessageId`,
  after `"content"` and never `"attachments"`; its content may be empty only when the message
  has files, which the reader checks. A room edit takes the next index on the sender's current
  chain, so it is distributed exactly as a new message (it may wait for the chain's
  distribution); a DM edit is a `DirectMessage` envelope to the sender's and the recipient's
  pinned keys. New messages have no `"replaces"`, and a reader treats a new message with one, or
  an edit without one, as invalid. No protocol change was needed for this (no wire or enum
  change; plan package M2).
- **What an edit needs (D10).** What a new message there needs at the time of the edit:
  membership, SendMessages, a room type with chat and, sealed, the room's current log version;
  in a direct conversation the restricted-account rule and, sealed, the recipient's current
  key. The message must be the author's, not deleted, and one the author can still read (the
  From join cut). A client message ID or chain index the sender used before, for a message or an
  edit, is refused, and so is a new message reusing an edit's.
- **Deletes.** `ClientDeleteRoomMessage{roomId, messageId, originalClientMessageId,
  signature}`: the author signs (`signRoomMessageDelete`), in encrypted rooms too, and needs
  only to be able to read the message; a zero signature asks for an admin's moderation delete
  (D5; the admin role, checked in the statement; the admin need not be a member).
  `ClientDeleteDirectMessage{peerUserId, messageId, originalClientMessageId, signature}`: only
  the sender, always signed (`signDirectMessageDelete`). A delete erases the content, sealed
  bytes, signature and every edit (D7); the tombstone keeps the ID, sender, time, client message
  ID and chain position, so replay checks still hold. Its files become Removed tombstones in the
  same statement (D8): their downloads end with "Attachment removed by an admin", the files are
  deleted, and every reader hears `ServerAttachmentRemoved` for each before the tombstone. An
  admin's delete also writes the files to the removal log (reason "Message deleted").
- **Notices.** `ServerRoomMessageEdited{roomId, messageId, senderId, editCount, edit}` and
  `ServerRoomMessageDeleted{roomId, messageId, senderId, deletion}` go to every session of each
  account that may read the message (room members past the From join cut) and to the admin who
  deleted it; `ServerDirectMessageEdited{senderId, recipientId, messageId, editCount, edit}` and
  `ServerDirectMessageDeleted{senderId, recipientId, messageId, deletion}` to both sides.
  `MessageEdit{id, clientMessageId, timestamp, content, signature, sealed}` is one version;
  `MessageDeletion{deletedAt, signature}` has a zero signature for an admin's delete.
- **History.** Room and direct history pages carry each message's `editCount`, its latest edit
  (`lastEdit`, D14) and whether it is a tombstone (`deleted`, `deletion`); a tombstone carries
  no content, sealed bytes, signature, attachments or edit. The conversation list carries the
  same for its newest message. `ClientFetchMessageEdits{kind, conversationId, messageId}` (kind
  Room 1 with the room, Direct 2 with the peer) is answered by `ServerMessageEdits{kind,
  conversationId, messageId, edits}`, oldest first; the original is the message itself, and a
  deleted message has none.
- **Unread counts.** Edits do not count as unread and do not move read markers; a deleted
  message does not count as unread (D13).
- **Refusals.** `ServerProtocolError` with the refused message named: "Invalid message edit
  (message N)", "Invalid message edit signature (message N)", "Invalid message delete signature
  (message N)", "Message not found (message N)", "You can only edit or delete your own messages
  (message N)", "This message was deleted (message N)", "An edit must be sealed exactly when its
  message is (message N)", "This message cannot be edited again (message N)", "Duplicate
  message edit (message N)", "Admin permission required (message N)", and the D10 refusals of a
  new message ("Not a room member", "You cannot send messages in this room", "Chat is disabled in
  this room", "Room key is out of date", "You no longer share a room with this person",
  "Invalid encrypted direct message") with " (message N)" added.
- **Clients.** A client shows an edit only when its signature verifies against the author's
  pinned identity key; one that does not is not shown, and the last good version stays, marked
  "An edit could not be verified". A sealed edit is opened like a new sealed message of the
  same author (a room's after the verified log reaches its epoch and the author's membership of
  it, its signature checked before any key is looked for, then the chain key; a DM's with both
  pinned identity keys), and is shown only when its `"replaces"` names this message and it has
  no files. One whose chain key or log has not arrived waits ("edited, not verified yet") and
  opens when it does; a Full history newcomer reads edits through the chains forwarded to it.
  Every failure is final. A copy of an edit (the same client message ID, or chain position, as
  an earlier edit or as the message) is a replay and fails. A tombstone always hides the
  content: it reads "Message deleted" when the author's signature verifies, and "Removed by the
  server" otherwise (D6). Clients cannot tell which admin removed a message.

The server can still withhold edits, reorder them, show an older version as the latest, or
delete a message and show it as "Removed by the server". It cannot forge an edit or an author's
delete, or move either to another message.

## Roles and server permissions (protocol 23)

The rules are in [rooms-and-accounts.md](rooms-and-accounts.md#roles-and-permissions).

- **Permissions** are `common.ServerPermission` bit numbers carried as one unsigned integer, the
  `ServerPermissions` `bit_set` (u64), and stored as `server_roles.permissions` (BIGINT). Pinned
  values: ManageRooms 0, ManageRoomMembers 1, CreateInvites 2, ApproveRegistrations 3,
  ManageRoles 4, ManageRegistration 5, KickUsers 6, BanUsers 7, RenameUsers 8. Only the first
  four can be given to a role other than admin. Receivers drop unknown bits.
- `ServerAuthSuccess.permissions` and `ServerAccountUpdated.permissions` are the account's
  effective set (every bit for an admin). `ServerAccountUpdated` now also goes out when only the
  set changed. `isAdmin` stays.
- `RoleSummary{id, name, permissions, builtin, position}`: `builtin` is true only for `admin`,
  whose permissions read as every bit; `position` orders the list and means nothing else.
  `UserSummary.roleIds` lists every role an account holds, `admin` included.
- `ClientAdminListRoles` (any account) is answered by `ServerRoleList`. `ClientAdminSaveRole`
  (role ID 0 creates), `ClientAdminDeleteRole` and `ClientAdminSetUserRoles` (every role of one
  account other than admin) are admins only and answered by `ServerAdminActionResult` (action
  `SaveRole` 4, `DeleteRole` 5 or `SetUserRoles` 6, with `roleId`) or a `ServerProtocolError`.
  A change sends `ServerRoleUpdated` or `ServerRoleDeleted` (no `ServerUserUpdated` follows for
  the deleted role's holders: clients drop the ID themselves) or `ServerUserUpdated` to every
  session, and `ServerAccountUpdated` to the sessions of each account whose set changed.
- Room create, edit and delete need ManageRooms ("Room management permission required"); member
  adds and removals, member lists of rooms one is not in, the admin room list and encrypted
  room logs need ManageRoomMembers (ManageRooms for a log's Create and SetAccess).
- Wire values: `ClientAdminListRoles` 180, `ServerRoleList` 181, `ClientAdminSaveRole` 182,
  `ClientAdminDeleteRole` 183, `ClientAdminSetUserRoles` 184, `ServerRoleUpdated` 185,
  `ServerRoleDeleted` 186. The retired placeholders `ClientGetRoles` … `ServerRemovedRole` keep
  24..31 and are never sent.

## Room permissions and role rooms (protocol 24)

The rules are in [rooms-and-accounts.md](rooms-and-accounts.md#room-permissions).

- **Room permissions** are `common.RoomPermission` bit numbers carried as one unsigned integer,
  the `RoomPermissions` `bit_set` (u64), and stored as `rooms.everyone_permissions` and
  `room_role_permissions.permissions` (BIGINT). Pinned values: SendMessages 0, SpeakInVoice 1,
  ManageMembers 2, EditRoom 3, and (protocol 27) AttachFiles 4. The default everyone grant is
  SendMessages + SpeakInVoice + AttachFiles (migration 15 added AttachFiles to every room).
  Receivers drop unknown bits.
- `RoomSummary.myPermissions` is the receiving account's set in the room (server permissions
  included: ManageRoomMembers gives ManageMembers, ManageRooms EditRoom, an admin every bit). It
  is filled in `ServerListRooms`, `ServerAdminRooms` and the creator's `ServerCreateRoom`; other
  payloads carry an empty set and a client keeps the one it has. A change of a room's grants,
  an account's roles, a role's deletion, the admin role or a role's server permissions sends
  the accounts concerned a fresh `ServerListRooms`.
- `ClientAdminFetchRoomPermissions{roomId}` and `ClientAdminSetRoomPermissions{roomId,
  everyone, roles: [{roleId, permissions}]}` need ManageRooms or the room's EditRoom ("Room
  management permission required"). A set replaces every grant (a role sent without
  permissions loses its grant), refuses a grant to an unknown or the built-in role ("Invalid
  role request") and any bit added or taken away that the requester may not grant ("You cannot
  grant a room permission you do not hold"; ManageRooms may grant SendMessages, SpeakInVoice,
  EditRoom and AttachFiles). Both are answered by `ServerAdminRoomPermissions{roomId, everyone, roles,
  accessRoleIds, myPermissions}`.
- Checks: a message (plaintext or sealed) needs SendMessages ("You cannot send messages in this
  room"). A voice join needs only membership; without SpeakInVoice the relay drops the session's
  frames (the `[Status]` counter `voice_drops_no_speak_permission`). Adds and removals need
  ManageMembers in the room (or, to add, membership of a Member invite room), also for an
  encrypted room's signed Add. An edit needs ManageRooms, or EditRoom with the room's own
  access and access roles.
- **Role rooms** (`RoomAccess.Role`, 4): `accessRoleIds` are 1..32 distinct role IDs for a Role
  room and none otherwise ("Invalid room metadata" or "Invalid room edit"); an unknown or
  built-in role is "Unknown access role". The members become exactly the roles' holders;
  `ClientAdminSetUserRoles`, `ClientAdminDeleteRole` and a change of a room's access roles add
  and remove members in the same statement, each announced with `ServerRoomMembershipChanged`
  (a removal also ends the account's voice in that room). `ClientAddRoomMember`,
  `ClientRemoveRoomMember` and `ClientLeaveRoom` are refused ("This room's members come from
  its access roles"), and so is an encrypted Role room ("Encrypted rooms cannot take their
  members from roles").
- Wire values: `ClientAdminSetRoomPermissions` 187, `ClientAdminFetchRoomPermissions` 188,
  `ServerAdminRoomPermissions` 189. The older never-sent placeholders `ClientChangeRoomPermissions`,
  `ServerRoomPermissions` and `ServerRoomPermissionsChange` stay unused.

## Room changes for room managers (protocol 31)

Room managers (holders of ManageRooms or ManageRoomMembers; admins hold both) list every room
with `ClientAdminListRooms`, also rooms they are not in, and so get no room events for those
(#73). Since protocol 31 the server also sends them `ServerAdminRoomChanged{roomId, change}`:

- To every session whose account holds ManageRooms or ManageRoomMembers, whether it is in the
  room or not, after a room is created (`Created`), edited (`Edited`), deleted (`Deleted`), or
  someone joins or leaves it (`Members`: adds, removals, leaves, a switch to Public, Role room
  changes, the member log of an encrypted room; not a new account joining every Public room as
  it signs up). The sessions' permissions follow role and admin
  changes, so an account that gains or loses them hears of the next change or stops hearing.
- After `ClientAdminSetRoomPermissions` changes a room's grants (`Permissions`), to those
  sessions and to every session of the room's members, since a member holding the room's
  EditRoom may show its Permissions page.
- It carries no room data. A client that keeps the list of every room fetches it again
  (`ClientAdminListRooms`); one that keeps the room's grants or shows its Permissions page
  fetches them (`ClientAdminFetchRoomPermissions`), so each recipient reads only what the server
  lets it read. A client fetches the list once more when a change arrives while a fetch is out,
  takes a deleted room off its lists at once, and closes an Edit form open on an edited room (as
  `ServerEditRoom` does for members). A Permissions page without unsaved changes takes the new
  grants; one with unsaved changes keeps them and says "Someone else changed these permissions.
  Saving replaces their change with yours."
- The events members already get (`ServerEditRoom`, `ServerDeleteRoom`,
  `ServerRoomMembershipChanged`, a fresh `ServerListRooms`) are unchanged; a manager who is a
  member gets both.

## Registration (protocol 25)

Packages G1 (server), G2 (client and harness) and G3 (proof and documentation) of
[the roles and registration plan](plan/2026-11-18-roles-and-registration.md) (decisions
D7-D19). The rules in user terms are in
[rooms-and-accounts.md](rooms-and-accounts.md#registration), and `dev/registration-proof.sh`
(`./dev.sh live --registration`, part of CI) proves them end to end.

- **Handshake (D12, D13).** `ClientHello` → `ServerHello` + `ServerAuthChallenge` →
  `ClientAuthRequest{sessionID, signature, registering}` as before. The server activates its
  transport, then runs the identity statement. A key that owns an account signs in with
  `ServerAuthSuccess` whatever the mode and `registering` say. A key without one gets an
  account at once only when the server is Open and `registering` is false, the key has an
  approved request, or it is `HAYCHAT_ADMIN_PUBLIC_KEY` (D15: never restricted, never pending,
  in every mode). Otherwise the answer is the **plaintext**
  `ServerRegistrationRequired{mode, status, message}` (`status`: None 0, Pending 1, Declined 3
  with the approver's reason in `message`), and both sides activate the transport exactly as on
  `ServerAuthSuccess`. The session is then registering: the server accepts only encrypted
  `ClientRegister` and `Ping` (ignored); anything else ends the session with a sealed
  `ServerProtocolError`, and a plaintext `ClientRegister` is refused. The invite code never
  travels in plaintext.
- **`ClientRegister{inviteCode, reason}`** (sealed; the name is the `ClientHello` nickname):
  `inviteCode` at most 64 bytes, read by `common.parseInviteCode` (spaces and dashes ignored,
  either case, O for 0, I and L for 1); empty only on an Open server, which then creates a plain
  account. `reason` 0..500 characters, needed (1..) when the code needs approval; clients leave
  that check to the server, since only it knows whether the code skips approval. One at a time.
  The client wipes the sealed packet's CBOR plaintext before freeing it.
- **`ServerRegisterResponse{status, message, auth}`** (sealed): `Created` 0 (the session is
  authenticated now; `auth` holds the `ServerAuthSuccess` fields, and the `NetworkVoiceSession`,
  the new account's `ServerUserUpdated` and its presence follow as after a sign-in, with no
  second handshake), `Pending` 1 (a request
  waits; the session stays registering and gets `Created` or `Declined` when an approver
  decides), `Refused` 2 (`message` says why; the session stays registering), `Declined` 3 (an
  approver declined; the session is disconnected). A session gets 5 answers and 10 minutes
  before it is ended with `Refused` ("Too many sign-up attempts" or "Sign-up took too long");
  at most 64 sessions register at once, more get `ServerAuthFailure` "Too many sign-ups are in
  progress; try again later". An invalid code is always "This invite code is not valid", whether
  it is unknown, revoked, expired or used up.
- **Modes (D7, D8):** `RegistrationMode` Open 1, InviteOnly 2, InviteApproval 3
  (`server_settings.registration_mode`, migrated as Open). `ClientAdminSetRegistrationMode{mode}`
  (admins) is answered by `ServerAdminActionResult{SetRegistrationMode 8}`; a change sends
  `ServerRegistrationMode{mode}` to every session. `ServerAuthSuccess.registrationMode` carries
  it at sign-in. `deploy/sql/set-registration-mode.sql` sets it without a client.
- **Invite codes (D9, D10):** 20 random bytes shown as 8 groups of 4 Crockford base32 symbols;
  the server stores only their sha256. `ClientCreateInvite{note, expiresInSeconds, maxUses,
  roleIds, roomId, skipApproval}` (CreateInvites; note ≤ 200 bytes, expiry 0 = never or ≤ 365
  days, uses 0 = unlimited or ≤ 1000) is answered by `ServerInviteCreated{invite, code}`, the
  only time the code is sent. Non-admins must set an expiry of at most 7 days, may not attach
  roles, a room or skip approval, and hold at most 25 usable codes. A room code targets an
  unencrypted Member or Admin invite room, and accounts it creates are restricted to it.
  `ClientListInvites` (every code for admins, one's own otherwise) → `ServerInviteList{invites}`;
  `ClientRevokeInvite{inviteId}` (admins any, others their own) → `ServerAdminActionResult
  {RevokeInvite 7, inviteId}`. A use is counted when a sign-up or a request is accepted.
- **Requests (D14, D18):** in Invite + approval mode a valid code without skip approval makes a
  request (one per key). `ClientListRegistrationRequests{includeDecided}` (ApproveRegistrations)
  → `ServerRegistrationRequests{requests, pendingCount}`; an approver's client sends it after
  sign-in for the badge. `ClientDecideRegistration{id, approve, reason}` → `ServerAdminActionResult
  {DecideRegistration 9, requestId}`. A new request and every decision send
  `ServerRegistrationRequestUpdated{request, pendingCount}` to every approver session. Approval
  creates nothing: the key's next sign-in (or at once, a still-registering session of it)
  creates the account with the code's roles, room and restriction and the name it signs in
  with then. A room code's request cannot be approved once its room is deleted or is no longer
  an unencrypted Member or Admin invite room (`ServerProtocolError` "The room this invite was
  for is no longer available"; declining still works, #115). When that happens after the
  approval, the sign-in creates no account: the server declines the request itself with the
  reason "The room this invite was for is no longer available; ask for a new invite", so the
  applicant gets `ServerRegistrationRequired{status Declined}` or, still registering,
  `ServerRegisterResponse{Declined}` and is disconnected.
- **Restricted accounts (D11, D17):** `UserSummary.isRestricted`. A restricted account never
  joins Public rooms automatically; only holders of ManageMembers in a room add it there
  ("Only a member manager can add this restricted account"). It sees, and exchanges direct
  messages with, only accounts it shares a room with and admins, and only those, admins and
  approvers see it: `ServerUserList`, `ServerUserPresence`, `ServerUserUpdated` and
  `ServerUserKeyChanged` are filtered per recipient, and a membership change involving a
  restricted account sends the affected sessions a fresh `ServerUserList`, one per session,
  including a room edit to Public or to Role access that adds accounts to a room with a
  restricted member (#104). A newly created account (any sign-up or Open sign-in, or a claimed
  keyless account) reaches every other session allowed to see it as a full `ServerUserUpdated`
  before its `ServerUserPresence` (#102), so clients add it with its restriction, identity key
  and roles. A refused direct
  message is "You no longer share a room with this person"; older history stays readable.
  `ClientAdminSetRestricted{userId, restricted}` (admins; never an admin) is answered by
  `ServerAdminActionResult{SetRestricted 10}` and `ServerAccountUpdated.isRestricted`; lifting
  it joins the Public rooms.
- **Invite links (D19, client only):** `haychat://HOST:PORT/invite/CODE?key=SERVER_PUBLIC_KEY_HEX`
  (and `haychat://HOST:PORT/join[?key=…]`), built by the client next to a new code. The client
  pins the link's key for the address (refusing a key that differs from an existing pin),
  connects with `registering` set and fills in the code, and signs up only when the user asks.
  Nothing about links is on the wire.
- Wire values: `ServerRegistrationRequired` 190, `ClientAdminSetRegistrationMode` 191,
  `ServerRegistrationMode` 192, `ClientCreateInvite` 193, `ServerInviteCreated` 194,
  `ClientListInvites` 195, `ServerInviteList` 196, `ClientRevokeInvite` 197,
  `ClientListRegistrationRequests` 198, `ServerRegistrationRequests` 199,
  `ClientDecideRegistration` 200, `ServerRegistrationRequestUpdated` 201,
  `ClientAdminSetRestricted` 202; `ClientRegister` 14 and `ServerRegisterResponse` 15 keep theirs.

## Account encryption keys (protocol 16)

The first part of end-to-end encryption ([plan/e2ee-design.md](plan/e2ee-design.md), sections
2 and 3). Protocol 17 encrypts direct messages with these keys
([below](#encrypted-direct-messages-protocol-17)).

- **Publishing.** Every profile has one X25519 encryption key in its `config.json`, signed by its
  identity key ([client configuration](client-configuration.md#keys)). After
  `ServerAuthSuccess` the client sends the bundle (`ClientPublishEncryptionKey`: the key,
  `createdAt`, the signature) once per session. The server verifies the signature against the
  session's own identity key and refuses anything else ("Invalid encryption key"), so an account
  can only publish a key it signed. It stores one bundle per account (`user_encryption_keys`):
  the same bundle again changes nothing, and a first or different one is announced to every
  session as `ServerUserKeyChanged`.
- **Fetching.** `ServerUserList` and `ServerUserUpdated` carry each account's identity key and
  whether it has a bundle. `ClientFetchUserKeys` asks for 1 to 64 distinct accounts' bundles;
  `ServerUserKeys` answers with the bundles and the IDs that have none.
- **Pinning.** The client checks every bundle's signature against the bundle's identity key and
  that identity key against its pin. The first bundle it sees for an account is pinned,
  unverified, in the per-server [key store](client-configuration.md#key-store). Another identity
  key later is a hard "key changed" state that blocks encryption to that account until the user
  verifies or trusts the new key; a newer encryption key under the same identity key is accepted
  with a notice; an older one, or one that does not verify, is refused and the pin stays.
- **Verification.** Two people compare a safety number (12 groups of 5 digits, the same for both
  and on every server) from **Verify encryption…** in the account's menu; see the
  [user guide](user-guide.md#encryption-keys).

## Encrypted direct messages (protocol 17)

The second part of end-to-end encryption ([plan/e2ee-design.md](plan/e2ee-design.md), sections
4.5, 4.6 and 7). Room chat is still not encrypted.

- **Sealing.** The sender's client encrypts a message whenever it has a pinned, unchanged key
  for the peer. It picks 16 random bytes as the message's client message ID and seals the
  text with `sealDirectMessage` (`common/e2ee.odin`): one random message key, wrapped for the
  sender's and the recipient's encryption keys, the body padded to 256-byte steps, and the
  envelope signed by the sender's identity key. The envelope's AAD binds the server's identity
  key, both user IDs, both pinned identity keys and the client message ID, so it opens in no
  other conversation and on no other server. While the peer's key is still being fetched the
  message waits ("Setting up encryption…") and goes out as soon as the key arrives.
- **The server.** `ClientSealedDirectMessage` carries the recipient, the client message ID and
  the envelope (at most 8192 bytes). The server checks its structure, then verifies its
  signature (`verifyDirectMessageEnvelope`) against the session's identity key and the
  recipient's identity key from its database, and stores it byte for byte with an empty
  content, only while the recipient still has that key. It refuses an envelope that does not
  verify ("Invalid encrypted direct message") and a client message ID the sender used before
  ("Duplicate direct message"). The stored message goes to every session of both users as
  `ServerSealedDirectMessage`; history pages and the conversation list carry the envelope, and
  the sender reads its own messages through its own wrap.
- **Opening.** A client opens an envelope only with the pinned identity key of its sender (its
  own for its own messages) and its own encryption key. One that does not open shows "This
  message could not be decrypted" and is never retried with another key. One whose sender is
  not pinned yet waits for the fetch the client starts. A second message from the same sender
  with the same client message ID (a replay by the server) is shown the same way. The newest
  message of each conversation is opened for the conversation list's preview.
- **No downgrade.** After the first encrypted message either way, the key store marks the
  conversation encrypted ([key store](client-configuration.md#key-store)); a plaintext message
  goes out only through the switch below, there or anywhere else.
- **The plaintext fallback.** When encryption to the peer is not possible (the peer has not set
  up encryption, their key changed, or the server no longer provides a key the client pinned)
  the composer is replaced by a banner saying why, with **Send without encryption**, off by
  default. With it on, `ClientDirectMessage` carries the text, a client message ID and the
  sender's signature (`signPlaintextDirectMessage`: the server's identity key, both user IDs,
  the client message ID and the text); the server verifies it against the session's identity
  key and refuses a message without a valid one ("Invalid direct message signature"). Both
  clients check it against the sender's pin. Badges: a lock on encrypted messages and
  "Unencrypted" on signed plaintext. See the [user guide](user-guide.md#encrypted-direct-messages).
- **Only signed messages are shown** (protocol 22, #82). A client never shows a direct message
  whose sender's signature it did not verify against its pin: one without a signature, one
  whose signature does not verify, one whose sender has no key to check it with, and an
  envelope that fails at or before its signature check are left out of the conversation, its
  preview and its unread count. An envelope whose signature verified but which does not open
  still shows "This message could not be decrypted". Migration 10 deleted the unsigned
  messages from before protocol 17.
- **What the server still learns.** Who writes to whom, when, and each message's length in
  256-byte steps. It can also withhold or delete messages; it cannot read, change, forge or
  insert one a client shows.

## Signed messages (protocol 22)

Every message a client shows is signed by its sender (#82, #90), so a server can no longer
write a message in anyone's name.

- **Room messages.** A plaintext room message carries a random, non-zero client message ID and
  the sender's signature (`signPlaintextRoomMessage`: `"haychat-room-plain-v1"`, the server's
  identity key, the room ID, the sender's user ID, the client message ID and the text). The
  server checks it against the session's identity key and refuses a message without a valid
  one ("Invalid room message signature") and a client message ID the sender used before
  ("Duplicate room message"). It stores the signature with the message and sends it with the
  live message and in history pages. A message with files is signed under the v2 label
  ([protocol 27](#attachments-on-messages-protocol-27)).
- **What clients show.** A client checks every room message against the sender's pinned
  identity key (its own key for its own messages); a sender it has not pinned yet is fetched
  first, and the message shows "Checking who sent this message…" meanwhile, never its text.
  A message without a signature, with one that does not verify, or from a sender who has no
  key is not shown at all: no line, no unread count. The same holds for direct messages, and
  for sealed messages in encrypted rooms, where a message that fails at or before its
  signature check is left out and one whose signature verified but which cannot be opened
  shows "This message could not be decrypted".
- **Migration 10** deleted every unsigned message: every plaintext room message (none had a
  signature before protocol 22) and every direct message from before protocol 17. Clients
  would never show them again.

## Encrypted rooms and the member log (protocol 18)

The third part of end-to-end encryption, first half ([plan/e2ee-design.md](plan/e2ee-design.md),
sections 6.1, 6.2 and 6.7): encrypted rooms and their membership as a signed log. Their
messages are sealed with sender chains since protocol 19
([below](#sender-chains-in-encrypted-rooms-protocol-19)); the server never stores anything
readable in one. Voice in one is end-to-end encrypted since protocol 21
([below](#encrypted-voice-protocol-21)); protocols 18 to 20 refused voice joins there.

- **Creating one.** An admin creates an encrypted room with `ClientCreateRoom{encrypted}`; it
  must be Member invite or Admin invite ("Public rooms cannot be encrypted"). The server
  creates it with no members and answers `ServerCreateRoom` with `logVersion` 0. Because the
  room ID is part of every signed entry, only then does the creator's client sign the log's
  first entry, `Create`, which names the room's access, its history setting, whether the
  creator joins, and its managers (every admin the creator's client sees, checked by default,
  with their pinned identity keys; the creator always is one). It sends it with
  `ClientAppendRoomLog`. The flag never changes: an edit that would set or clear it, or change
  an encrypted room's access, is refused.
- **The log.** Each entry is `common/e2ee.odin`'s `RoomLogEntry`, carried as a CBOR byte
  string: a version (also the room's epoch), the previous entry's SHA-256, an action (Create,
  Add, Remove, AddManager, RemoveManager, Leave, SetAccess), the target and actor with their
  identity keys, and the actor's Ed25519 signature over the server's identity key and the entry.
  Adds need a manager (or, in a Member invite room, a member); manager changes and access
  switches need a manager; a Leave is signed by whoever leaves; a Remove is signed by a manager
  or written unsigned by the server (it can always take readers away, never add one). The last
  manager cannot be removed while the room has members; an encrypted room holds at most 100
  members ("This encrypted room is full").
- **The server.** It replays the stored log on every append, validates the new entry as the
  next one (version and previous hash must follow the head, so concurrent appends cannot both
  win: "The member list changed on the server; try again"), requires every identity key it
  names to be the named account's own, applies its own rules on top (an add needs an admin or a
  member of a Member invite room as well as a valid signature; an access switch needs an admin;
  the actor must be the sender), and stores the entry and applies it to `room_members` in one
  transaction. Every stored entry goes out as `ServerRoomLog` to the room's members and
  managers and to whoever it removed. An admin's `ClientRemoveRoomMember` on an encrypted room
  becomes an unsigned Remove the server writes; `ClientAddRoomMember` and `ClientLeaveRoom` are
  refused for encrypted rooms in favour of the log. `ClientFetchRoomLog` serves members,
  managers and admins.
- **Clients.** A client replays the whole log against its own pins, keeps the verified head
  (version and hash) per room in its [key store](client-configuration.md#key-store), and
  refuses a log that rewrites a verified entry (a fork), ends before it (a rollback), or has any
  entry that does not verify. Every such failure is final for the session: the room shows
  "This room's member list was changed on the server" and nothing is signed for it. Accounts
  the log names that the client has not pinned are fetched and pinned on first use, and the
  log is checked against those pins once they arrive. Verified changes show in the room as
  event lines ("alice added carol", "the server removed dave").
- **What the server still can do.** Remove members, delete the room, refuse appends and
  withhold entries (a client then sees an older log, or a rollback once it has seen a newer
  one). It cannot add a member or a manager to a log that clients accept.

## Sender chains in encrypted rooms (protocol 19)

The third part of end-to-end encryption, second half ([plan/e2ee-design.md](plan/e2ee-design.md),
sections 6.3 to 6.6): the messages of encrypted rooms. Full history for new members came with
protocol 20 ([below](#full-history-in-encrypted-rooms-protocol-20)).

- **Chains.** Each member that sends in an epoch (the member log's version) has a sender chain:
  a random 32-byte chain key and a 16-byte chain ID. Message `i` is sealed with the key derived
  from the chain at index `i` (HKDF-SHA256), and a chain ends after 1000 messages, after seven
  days, or with its epoch. A client keeps the sending side of a chain only in memory and starts
  a new chain in every run, so no index is ever used twice (a restart, a crash or a copy of the
  profile cannot reuse one); the server refuses a reused `(sender, chain, index)` as well.
- **Distribution.** Before its first message with a chain the sender seals it in one
  `SenderKey` envelope with a wrap for every member of the epoch as its verified member log
  shows them, itself included, each to the encryption key it pinned, and signs it
  (`ClientRoomKeyEnvelope`). The server checks the envelope's structure and its signature
  against the sender's identity key, that the sender is a member, that every wrap names a
  member, and that the epoch is the room's current log version (an older epoch only for a chain
  it already stores, which is how key requests are answered), and stores it once. It sends it
  as `ServerRoomKeyEnvelope` to the accounts its wraps name. A message waits on the sender's
  side ("Setting up encryption…") until the server stored the distribution.
- **Messages.** A sealed message is `common/e2ee.odin`'s `SealedRoomMessage` in
  `ClientChatMessagePayload.sealed` with an empty `content` and a random `clientMessageId`: the
  epoch, chain ID and index, the body sealed with the message key, and the sender's signature
  over the AAD (this server, the room, the sender, the chain position and the client message
  ID) and the bytes. The server checks the structure and the signature, membership, and that
  the epoch is the room's current log version; a stale one is refused with "Room key is out of
  date", and the client then fetches the member log, starts a chain in the new epoch and sends
  again. Every removal therefore takes effect at the server: nothing sent after it is sealed to
  the removed member. The server stores the bytes unchanged and serves them in history, which
  for a From join member starts when they joined.
- **Receiving.** A client opens a distribution only when its verified log shows the sender as
  a member of that epoch, with the sender's pinned identity key, and keeps the chain key in its
  [key store](client-configuration.md#key-store). The key store is a cache: `ClientFetchRoomKeys`
  returns the envelopes with a wrap for the requester (members only), so a lost key store is
  rebuilt from the server. A message whose chain the client lacks shows "Waiting for this
  message's key from <name>"; after a fetch the client asks the sender with
  `ClientRequestRoomKey`, which the server relays to the sender's online sessions as
  `ServerRoomKeyRequest` when both are members and the chain is stored. The sender re-seals the
  chain to the requester only if the requester was a member of that epoch in its verified log.
  Every other failure (a bad signature, a sender who was not a member, plaintext in an encrypted
  room, a replayed message) shows "This message could not be decrypted" and is never retried.
- **What the server still can do.** Withhold, delay or delete messages and envelopes, refuse
  sends, and see who sends how much and when (lengths in 256-byte steps). A row it inserts
  into `room_members` behind the log gives that account the history's sealed bytes but no key
  to open them.

## Full history in encrypted rooms (protocol 20)

The fourth part of end-to-end encryption ([plan/e2ee-design.md](plan/e2ee-design.md), section
6.6). In an encrypted room created with **Full history**, a new member reads the messages from
before they joined; members' clients hand them the older chains. A From join encrypted room
never does any of this.

- **Who decides.** Every client decides from the history setting its *verified* member log
  names (the `Create` entry fixes it), never from the server's room list. The server enforces
  its own copy (`rooms.history_visibility`) on top.
- **Forwards.** A member hands a chain it holds (its own or another member's) to one other
  member as a `RoomKeyForward` envelope: the same plaintext as a distribution (the chain key at
  the index the forwarder holds it from), exactly one wrap for the recipient's pinned encryption
  key, signed by the forwarder, under its own AAD (`"haychat-room-key-forward-v1"`, this server,
  the room, the epoch, the chain's original sender, the chain ID, the forwarder and the
  recipient). A member re-seals its own chain as an ordinary `SenderKey` envelope instead. It is
  sent as `ClientRoomKeyEnvelope` with `senderId` set to the chain's sender; the server checks
  the structure and the forwarder's signature, then stores it only in a Full history encrypted
  room, from a member to a member, for a chain it already stores (any epoch), and drops it
  without an answer when the recipient already has a wrap for that chain, so the first copy
  wins. A forward elsewhere is refused with "This room does not share its history with new
  members". Stored forwards carry `forwarderId` in `ServerRoomKeyEnvelope` and
  `ServerRoomKeys`, and a lost key store fetches them again like any envelope.
- **When.** The client that signs an `Add` forwards every chain it holds from before the
  addition right after the server confirms it, one envelope per chain. For the rest (the
  inviter may have joined later itself, or be a manager who is not a member and holds
  nothing), the newcomer asks: in a Full history room the server relays `ClientRequestRoomKey`
  to every online member, not only the chain's sender (`ServerRoomKeyRequest.senderId` names
  the chain), and any member whose verified log shows the requester as a current member and
  the sender as a member of that epoch answers with what it holds. The requests go out again
  when another member of the room comes online. A chain that no online member holds stays
  "Waiting for this message's key".
- **Checks on the newcomer's side.** A forward is accepted only in a Full history room, from a
  forwarder who was a member at the same time as the recipient, for a chain whose sender was a
  member of its epoch, and only when its signature verifies against the forwarder's pin (or the
  identity the log names). Messages are still verified against their real senders' keys, so a
  forwarder can give access to history but never forge a message in it.

## Encrypted voice (protocol 21)

The fifth part of end-to-end encryption ([plan/e2ee-voice-design.md](plan/e2ee-voice-design.md)):
voice in an encrypted room is end-to-end encrypted. The relay forwards Opus it cannot read. An
encrypted room's voice is encrypted or silent; there is no plaintext fallback. Unencrypted
rooms keep their voice exactly as before.

- **Voice keys.** Every participant makes its own voice key: 32 random bytes per voice session
  (a random 16-byte `voiceSessionId` per join) and *generation* (from 0, one more on every
  rotation). It is sealed as a `VoiceKey` envelope (kind 4 of the end-to-end envelope) with a
  wrap for every other member of the current epoch in the sender's verified member log, each
  to the encryption key the sender pinned, and signed by the sender under its own AAD
  (`"haychat-voice-key-v1"`, this server, the room, the epoch, the sender, the voice session,
  the generation and the creation time). The plaintext repeats those fields. A voice key is
  never derived from a text sender chain, so Full history never reaches calls.
- **Wire.** `ClientVoiceKey{roomId, epoch, voiceSessionId, generation, createdAt, envelope}` and
  `ServerVoiceKey` (the same plus `senderId`); `ClientRequestVoiceKey{roomId, senderId}` and
  `ServerVoiceKeyRequest{roomId, requesterId}`. `createdAt` (Unix seconds by the sender's clock)
  travels next to the envelope because the AAD binds it and the server checks the signature.
- **Server.** The router accepts a `ClientVoiceKey` only from a session in that room's voice,
  for an encrypted room, at the room's current member log version ("Voice key is out of date"
  for an older one, so the client fetches the log and makes a new key; "Invalid voice key"
  otherwise), with a valid `VoiceKey` envelope without a wrap for its sender, signed by the
  session's identity key. It keeps the latest key per participant **in memory only** (never in
  the database), sends it as `ServerVoiceKey` to every other session in the room's voice, and
  hands each joiner every other participant's current key right after its participant list. It
  forgets a key when its participant leaves voice, is taken over by another device, is evicted
  or disconnects, and drops keys of an older epoch when the member log moves on. A key request
  goes to the speaker's voice session at most once per requester and speaker every 10 seconds.
- **Rotation.** A participant makes a new generation when its join is acknowledged, whenever
  its voice engine is reopened (a device change), when its verified log reaches a new epoch (a
  member added or removed: frames wait for the new key, and the old one is never used again),
  every 30 minutes, and when a member asks (at most once every 10 seconds).
- **Freshness.** A listener accepts a key only from a member of its epoch in the verified log,
  checked against the sender's pin; for the epoch it has verified (a later one waits for the
  log, an earlier one is accepted only within 10 seconds of the log moving on); made no more
  than an hour before and no more than 5 minutes after the listener's own clock; and newer than
  the last key it accepted from that sender. A user whose clock is off by more than about half
  an hour cannot be heard in encrypted rooms.
- **Frames.** In an encrypted room the `opus` field of `ClientVoiceFrame`/`ServerVoiceFrame`
  holds `version (1) ‖ keyId (1) ‖ ciphertext ‖ tag (16)`: XChaCha20-Poly1305 under the
  sender's voice key, the nonce is the frame sequence followed by 20 zero bytes, and the AAD
  (`"haychat-voice-frame-v1"`) binds the server, the room, the sender, the epoch, the voice
  session, the generation, the sequence, the flags, the version and the key ID. The relay skips
  its Opus duration check there, drops a payload that is not sealed, applies
  `HAYCHAT_VOICE_MAX_FRAME_BYTES` to the Opus bytes inside, and forwards the payload unchanged.
  In encrypted rooms every Opus packet is padded with Opus's own padding to one size per
  bitrate (1.6 times the nominal 20 ms frame), so the packet lengths the server sees do not
  follow the speech.
- **What the server still sees.** Who is in voice, who talks and when (nothing is sent in
  silence), and the bitrate. A member who controls or colludes with the server can speak under
  another member's key (there are no per-frame signatures), and the server can replay a
  recording less than an hour old to a listener that has not seen a newer key from that
  speaker. See section 1 of the design note.

## End-to-end encryption primitives

`common/e2ee.odin` holds the building blocks of the end-to-end encryption design
([plan/e2ee-design.md](plan/e2ee-design.md)). Protocol 16 uses the encryption key bundle and
safety numbers, protocol 17 the direct message envelopes and the signed plaintext fallback,
protocol 18 the member log, protocol 19 the sender chains, their distributions and sealed
room messages, protocol 20 the forwarded chains of Full history rooms, protocol 21 the
voice key envelopes (sealed voice payloads are in `common/voice_e2ee.odin`), and protocol 22
the signed plaintext room messages.

- **What is there.** The signed encryption key bundle (X25519 key, signed by the identity key),
  sealed envelopes (one random message key wrapped per recipient, the body sealed with
  XChaCha20-Poly1305, the whole envelope signed with Ed25519), the AAD builders for direct
  messages, room key distributions and room messages, the signed plaintext fallback and signed
  plaintext room messages, padding to
  256-byte blocks, sender chains, sealed room messages, the signed member log with its replay
  rules, and safety numbers.
- **Byte layouts.** Every structure has a fixed, versioned, little-endian layout, documented byte
  for byte at the top of the file. Later protocol versions carry them as CBOR byte strings, so
  signed bytes never depend on a CBOR encoder.
- **Opening.** Every procedure that opens or verifies checks the signature against the caller's
  pinned identity key before it touches key material, and each failure has its own error value
  (`E2EEError`, `RoomLogError`); nothing is retried with another key.
- **Known answers.** `common/e2ee_test.odin` and `common/voice_e2ee_test.odin` pin vectors
  produced by `dev/tools/e2ee-vectors.py`, an independent implementation with Python's
  `cryptography` package. Rerun it after changing a layout, a domain string or an HKDF label.
