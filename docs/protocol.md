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
- **End-to-end only for direct messages.** Since protocol 17 a direct message is end-to-end
  encrypted whenever both sides can: the sender's client seals it to the recipient's pinned
  key, and the server stores and forwards an envelope it cannot open
  ([below](#encrypted-direct-messages-protocol-17)). When the recipient cannot receive
  encrypted messages, sending is refused unless the user turns on **Send without encryption**
  for that conversation; such a message is signed but the server can read it, and both
  clients mark it "Unencrypted". Room chat is not end-to-end encrypted yet: the server decrypts
  it and stores it unencrypted in its PostgreSQL database, so the server and its operator can
  read it, and direct messages from before protocol 17. Voice is relayed and never stored or
  logged. Invite-only rooms (protocol 15) limit which accounts the server lets read a room;
  they do not hide it from the server. The server always sees who writes to whom and when.

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
  clients check it against the sender's pin. Badges: a lock on encrypted messages,
  "Unencrypted" on signed plaintext, "Unencrypted, sender not verified" when the signature
  does not verify, and "Not encrypted" on messages from before protocol 17, which carry no
  signature. See the [user guide](user-guide.md#encrypted-direct-messages).
- **What the server still learns.** Who writes to whom, when, and each message's length in
  256-byte steps. It can also withhold or delete messages, and it can insert an unsigned
  message that looks like one from before protocol 17 ("Not encrypted"); it cannot read,
  change or forge an encrypted or signed one.

## End-to-end encryption primitives

`common/e2ee.odin` holds the building blocks of the end-to-end encryption design
([plan/e2ee-design.md](plan/e2ee-design.md)). Protocol 16 uses the encryption key bundle and
safety numbers, protocol 17 the direct message envelopes and the signed plaintext fallback; the
sender chains and the member log are not on the wire yet.

- **What is there.** The signed encryption key bundle (X25519 key, signed by the identity key),
  sealed envelopes (one random message key wrapped per recipient, the body sealed with
  XChaCha20-Poly1305, the whole envelope signed with Ed25519), the AAD builders for direct
  messages, room key distributions and room messages, the signed plaintext fallback, padding to
  256-byte blocks, sender chains, sealed room messages, the signed member log with its replay
  rules, and safety numbers.
- **Byte layouts.** Every structure has a fixed, versioned, little-endian layout, documented byte
  for byte at the top of the file. Later protocol versions carry them as CBOR byte strings, so
  signed bytes never depend on a CBOR encoder.
- **Opening.** Every procedure that opens or verifies checks the signature against the caller's
  pinned identity key before it touches key material, and each failure has its own error value
  (`E2EEError`, `RoomLogError`); nothing is retried with another key.
- **Known answers.** `common/e2ee_test.odin` pins vectors produced by
  `dev/tools/e2ee-vectors.py`, an independent implementation with Python's `cryptography`
  package. Rerun it after changing a layout, a domain string or an HKDF label.
