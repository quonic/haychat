# Transport and Protocol Versions

How a HayChat client and server talk to each other, and what changed in each protocol version.
For the wire rules that code must follow (packet ownership, enum numbering, voice framing), see
"Chat Protocol And Ownership" in [AGENTS.md](../AGENTS.md).

## Transport Encryption

- **Identities.** Every client and server has an Ed25519 identity key. The client pins the
  server's key on its first connection and refuses a different one later (see "Failures that
  stop retrying" in the [user guide](user-guide.md#connection-status-and-reconnecting)).
- **Key exchange and packets.** The handshake uses X25519 and derives four keys with HKDF:
  control and voice, one per direction. Packets are sealed with XChaCha20-Poly1305.
- **Channels.** Everything runs over ENet on one UDP port. The control channel (ENet channel 1)
  carries CBOR packets and keeps a strict sequence counter; the voice channel (ENet channel 2)
  carries binary voice datagrams with a 64-packet replay window, and each datagram's kind byte
  is bound into its authentication tag.
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
| 16 | Account encryption keys (end-to-end encryption, part 1): `ClientPublishEncryptionKey` (each profile's X25519 key, signed by its identity key, sent once per session), `ClientFetchUserKeys`/`ServerUserKeys` (at most 64 accounts per request; accounts without a key are listed as missing), `ServerUserKeyChanged` (an account stored a new key), and `UserSummary.identityPublicKey`/`hasEncryptionKey`, with schema migration 5 (`user_encryption_keys`). No message is encrypted yet |
| 17 | Encrypted direct messages (end-to-end encryption, part 2): `ClientSealedDirectMessage`/`ServerSealedDirectMessage` (an envelope the sender sealed for itself and the recipient, carried byte for byte), the envelope, client message ID and signature fields of `StoredDirectMessage` and `DirectConversationSummary`, and the signed plaintext fallback (`ClientDirectMessage` now needs `clientMessageId` and `signature`; unsigned messages are refused), with schema migration 6 |
| 18 | Encrypted rooms and their signed member log (end-to-end encryption, part 3a): `ClientAppendRoomLog`, `ClientFetchRoomLog`, `ServerRoomLog`, `RoomSummary.encrypted`/`logVersion`, `ClientCreateRoomPayload.encrypted` and `ClientEditRoomPayload.encrypted`, with schema migration 7 (`rooms.encrypted`, `rooms.log_version`, `room_log_entries`, `room_log_managers`). Encrypted rooms take no message and no voice yet |
| 19 | Sender chains in encrypted rooms (end-to-end encryption, part 3b): sealed room messages (`ClientChatMessagePayload`, `ServerChatMessagePayload` and `StoredChatMessage` gain `clientMessageId` and `sealed`), `ClientRoomKeyEnvelope`/`ServerRoomKeyEnvelope`, `ClientFetchRoomKeys`/`ServerRoomKeys`, `ClientRequestRoomKey`/`ServerRoomKeyRequest`, with schema migration 8 (sealed `chat_messages` columns, `room_key_envelopes`). Plaintext in an encrypted room is refused |
| 20 | Full history in encrypted rooms (end-to-end encryption, part 4): `RoomKeyForward` envelopes (`ClientRoomKeyEnvelopePayload.senderId` names the chain's sender, `RoomKeyEnvelope.forwarderId` the forwarding account), `ServerRoomKeyRequest.senderId`, and key requests relayed to every member of a Full history room, with schema migration 9 (`room_key_envelopes.forwarder_user_id`) |
| 21 | Encrypted voice in encrypted rooms (end-to-end encryption, part 5): voice joins of encrypted rooms are accepted, `ClientVoiceKey`/`ServerVoiceKey` (a participant's `VoiceKey` envelope, kind 4), `ClientRequestVoiceKey`/`ServerVoiceKeyRequest`, and sealed voice payloads in the frames of encrypted rooms. No schema migration: voice keys are never stored |
| 22 | Signed room messages (#90): `ClientChatMessagePayload`, `ServerChatMessagePayload` and `StoredChatMessage` gain `signature`, and every plaintext room message carries a random `clientMessageId` and its sender's signature (`signPlaintextRoomMessage`); the server refuses unsigned plaintext ("Invalid room message signature") and a reused client message ID, and clients show no room or direct message without its sender's valid signature (#82). Schema migration 10 deletes every unsigned message ([below](#signed-messages-protocol-22)) |
| 15 | Room access modes (Public, Member invite, Admin invite) and history for new members (From join or Full), creating a room without joining it, `ClientLeaveRoom`, member adds by members of Member invite rooms, `ClientFetchRoomMembers`/`ServerRoomMembers`, `ClientAdminListRooms`/`ServerAdminRooms`, and `ServerRoomMembershipChanged.userId`, with schema migration 4 |

The behaviour behind these versions is described in [rooms-and-accounts.md](rooms-and-accounts.md)
(rooms, admins, direct messages, read state) and the [user guide](user-guide.md#voice) (voice).

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
  live message and in history pages.
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
