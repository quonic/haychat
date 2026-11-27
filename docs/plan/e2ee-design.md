# End-to-end encryption: design

**Date:** 2026-11-14
**Base:** `main` at `8fcc63b`
**Status:** Design. Nothing is implemented. Every open question was decided by the maintainer on
2026-11-14 (section 10).
**Audience:** HayChat maintainers and the agents that will implement package E2EE

This document designs end-to-end encryption (E2EE) for HayChat's direct messages and rooms:
the threat model, the keys each account holds, how clients learn and pin each other's keys,
encrypted direct messages, the room access modes that encrypted rooms need, encrypted rooms with
per-sender keys and a signed member list, voice, the wire and schema changes, a test plan that
runs headless, and a PR-sized work breakdown. Each section makes a recommendation and lists the
alternatives it rejects. Section 10 records the maintainer's decisions.

MLS (RFC 9420) is out of scope and recorded as a possible later step (section 11).

## Summary

| Decision | Recommendation |
| --- | --- |
| Scope | Direct messages first, then encrypted invite-only rooms. Public rooms stay unencrypted and the client says so: encrypting a room anyone can join protects nothing. |
| Room access | Three modes, chosen at creation: **Public** (every account, as today), **Member invite** (any member can invite), **Admin invite** (only admins can invite). An admin may create a room they are not a member of and still manage its access or delete it. Encrypted rooms hold at most 100 members; unencrypted rooms have no limit. |
| Primitives | Only `core:crypto`: X25519, Ed25519, HKDF-SHA256, XChaCha20-Poly1305. No new native dependency. |
| Account keys | The existing Ed25519 identity key stays the root of trust. Each profile adds one X25519 *encryption key*, signed by the identity key, published to every server it signs in to. |
| Key trust | Trust on first use per server and user ID, like the server key pin today. Accounts never change keys, so a changed key blocks sending and asks the user. A safety number lets two people verify each other. |
| Direct messages | Each message is sealed once with a random message key; that key is wrapped for the recipient's and the sender's encryption keys and the whole envelope is signed by the sender's identity key. |
| Plaintext fallback | When a peer cannot receive encrypted messages, sending is refused by default. The sender can turn on **Send without encryption** for that conversation; such messages are signed but readable by the server, and both clients mark each one "Unencrypted". |
| Rooms | Sender keys: each sender has a hash-ratchet chain per room and epoch, shared with every member through the same sealed envelopes as direct messages. Messages are signed by the sender's identity key. |
| Membership | An encrypted room's member list is a hash-chained log of membership changes, each signed by someone the room's access mode allows to make it; clients share keys only with members the log proves. The server can remove members on its own but cannot add a reader. |
| Epochs | Every membership change starts a new epoch; senders start new chains in it. A removed member gets no keys for anything sent after the removal. |
| History for new members | A room setting fixed at creation: **From join** (the default) or **Full history**, where members' clients forward the older chain keys to the newcomer. |
| Key storage | Key envelopes stay on the server, sealed to their recipients, so a client's key cache can be rebuilt from its `config.json` alone. User pins live in a per-server key store file next to `config.json`. |
| Forward secrecy | Not in this design. The client keeps no message cache and re-reads history from the server, which needs long-lived keys. Recorded as a limitation and a later step. |
| Voice | Later phase: Opus payloads sealed with a per-sender voice key derived from the room's sender chain, relayed unchanged by the server (SFrame-style). |
| Transport | Unchanged. The per-hop transport encryption stays and still hides metadata from the network. |

**Biggest risk:** usability, not cryptography. A client that loses its `config.json` loses
every key and therefore every encrypted message, and a key-change warning that people learn to
click through protects nothing. Sections 3.4 and 7.4 keep both rare and visible.

## 0. What exists today

### 0.1 Identity and transport

- Every client and server has an Ed25519 identity key (`common/auth.odin`). The client keeps its
  key in `config.json` (`private_key`, `public_key`, mode `0600`) and uses the same key for every
  server it connects to.
- An account *is* its identity key on a server (`users.public_key`, unique). There is no way to
  move an account to another key or device; a second machine is a copy of the profile directory
  and so holds the same key.
- The handshake uses X25519 and HKDF to derive four transport keys; packets are sealed with
  XChaCha20-Poly1305. The client pins the server's identity key on first connect
  (`servers[].pinned_server_public_key`) and shows **Trust the new key** / **Forget key** when it
  changes.
- `docs/protocol.md` says plainly: the server decrypts every message and stores it in plain text.

### 0.2 Rooms and messages

- Rooms are open: every account is a member of every room, and sign-up is open. `room_members`
  is still checked for every send and history request. `ClientAddRoomMember` and
  `ClientRemoveRoomMember` exist and are admin-only on the server; the client never sends them.
- `chat_messages.content` and `direct_messages.content` are `TEXT`, 1..4000 characters
  (`CHAT_MESSAGE_MAX_BYTES`). History is paged by server message ID. Direct messages reach the
  sender only through the server's echo.
- `DirectConversationSummary.lastContent` gives the conversation list a preview of each
  conversation's newest message.
- The client has no on-disk message cache: every start fetches history from the server again.
  This decides a lot below (section 3.3).

### 0.3 What `core:crypto` offers

`x25519`, `ed25519`, `hkdf`, `sha2`, `chacha20poly1305` (with XChaCha), `argon2id`, `mlkem`,
`mldsa`, `noise`, `ristretto255`. There is no HPKE and no Ed25519-to-X25519 conversion; the
sealed envelope in section 4 is built from the primitives directly.

## 1. Threat model

### 1.1 Protects against

- **The operator and the database.** Someone with the server's database, its backups, its logs or
  a debugger on the server process reads no message content of encrypted conversations.
- **Forged messages.** The server cannot make a message appear to come from another account, change
  one, or move it to another conversation or server.
- **Added readers.** In an encrypted room, the server cannot add an account that gets the keys:
  every addition needs the signature of someone the room's access mode allows to add (section
  6.2).
- **Forged plaintext.** Even an unencrypted fallback direct message (4.6) is signed, so the server
  can read it but cannot forge or change it.
- **Removed members.** A member removed from an encrypted room gets no key for anything sent after
  every remaining client has seen the removal.

### 1.2 Does not protect against

- **Metadata.** The server still sees who talks to whom, in which room, when, roughly how long the
  messages are (padding blurs this, section 4.4), who is online, nicknames, room names and room
  descriptions.
- **Availability.** The server can drop, delay, withhold or delete messages and key envelopes, and
  can refuse service. Clients notice some of this (missing keys, a stale member log) but cannot
  prevent it.
- **First contact.** Until two people compare safety numbers, a server that lies about a key the
  first time a client sees it can read that conversation. Pins make it a one-time chance, and a
  later swap is caught.
- **Key theft.** Anyone who gets a `config.json` can read every encrypted message its owner could,
  past and future (no forward secrecy, section 3.3).
- **The endpoint.** Malware on a member's machine, a screenshot, a member forwarding a message.
- **Public rooms.** They stay unencrypted. Anyone can sign up and join them, the operator included.
- **The people who control access.** Whoever may add members may add themselves: a room manager
  who is not a member, or any member of a member-invite room inviting someone. E2EE protects a
  room from the server, not from its own managers. Every addition shows in the room (6.2).
- **Messages sent without encryption.** The plaintext fallback (4.6) is readable by the server by
  design; the warning on each such message is the protection.

### 1.3 Non-goals for this design

Forward secrecy and post-compromise security, deniability (messages are signed, section 4.3),
hiding metadata, encrypted file transfer (no file transfer exists), encrypted search, and more
than one key per account.

## 2. Keys

### 2.1 Identity key (exists)

Ed25519, in `config.json`. It signs the transport handshake today. In this design it also signs:
the profile's encryption key bundle, every encrypted message, every sender-key distribution, and
room membership changes. It never encrypts.

### 2.2 Encryption key (new)

One X25519 key pair per profile, generated on first start after the upgrade, and kept in
`config.json` next to the identity key:

| Key | Contents |
| --- | --- |
| `encryption_private_key` | 32 bytes, hex. Secret, like `private_key`. |
| `encryption_public_key` | 32 bytes, hex. |
| `encryption_key_signature` | 64 bytes, hex: the identity key's signature over the bundle below. |

The signed bundle is the byte string

```
"haychat-e2ee-encryption-key-v1" || identityPublicKey (32) || encryptionPublicKey (32)
|| createdAtUnixSeconds (u64 LE)
```

and `createdAt` is stored with it (`encryption_key_created_at`). Like the identity key, it is one
key for every server.

Rejected: deriving the X25519 key from the Ed25519 key with the birational map. `core:crypto` does
not expose it, using one key for both signing and key agreement is discouraged, and a separate key
can be replaced later without changing the account.

Rotation is out of scope: a profile has one encryption key for its life. Section 10, Q5
records why.

### 2.3 Keys derived per conversation

| Key | Where | Section |
| --- | --- | --- |
| Message key | One random 32-byte key per direct message | 4 |
| Sender chain key | One per room, epoch and sender, advanced per message | 6.3 |
| Voice key | Derived from a sender chain key, per voice session | 8 |

## 3. Publishing, fetching and pinning keys

### 3.1 Publishing

After `ServerAuthSuccess`, the client sends its bundle once per session:

```
ClientPublishEncryptionKey { encryptionPublicKey, createdAt, signature }
```

The server checks the signature against the session's identity key and stores the bundle in
`user_encryption_keys` (section 9.2). A bundle that matches the stored one is a no-op. A
different valid bundle replaces it. This only happens when a profile's `config.json` lost its
encryption key and made a new one, and every peer then sees a key change (3.4).

### 3.2 Fetching

`UserSummary` gains `identityPublicKey` (32 bytes) and `hasEncryptionKey` (bool), so the user
list says who can receive encrypted messages without carrying every bundle. Bundles are fetched on
demand:

```
ClientFetchUserKeys   { userIds: [dynamic]int }          // at most USER_KEYS_FETCH_MAX (64)
ServerUserKeys        { keys: [dynamic]UserKeyBundle }
UserKeyBundle         { userId, identityPublicKey, encryptionPublicKey, createdAt, signature }
ServerUserKeyChanged  { bundle: UserKeyBundle }           // to every session, on replacement
```

The client verifies every bundle's signature against the bundle's identity key, and that identity
key against its pin (3.3), before it uses the encryption key.

### 3.3 The key store

Pins and room key material live in a per-server file next to `config.json`:

- Linux: `$XDG_CONFIG_HOME/haychat/keys/<server fingerprint>.json`, Windows:
  `%APPDATA%\haychat\keys\<server fingerprint>.json`, mode `0600`, written atomically like
  `config.json`. The server fingerprint is the pinned server key's fingerprint, so a server that
  changes its key (and is trusted again) gets a fresh key store, and its users are pinned again.
- Contents: `users` (user ID → identity public key, encryption public key, `verified` flag, and
  `firstSeen`), `rooms` (room ID → verified member log head, section 6.2, and the chain keys the
  client holds, section 6.3), and `directConversations` (peer ID → `encrypted` flag, 4.5).

Two parts of the store behave differently:

- **Pins are security state.** If they are lost, the next contact is a new first contact.
- **Chain keys are a cache.** The server keeps every key envelope sealed to its recipient
  (sections 4 and 6.4), so a client that lost its key store but kept `config.json` fetches its
  envelopes again and opens them with its encryption key.

The client has no message cache and re-fetches history at every start, which is why keys are
long-lived here. Forward secrecy would need a local encrypted message cache and deleting keys
after use; section 11 keeps it for later.

The headless harness writes the key store like the GUI client does, so a script that runs a
profile twice reads its old messages. (The harness does not write `config.json` back today; the
key store is a separate file.)

### 3.4 Trust on first use and key changes

- The first bundle a client sees for a user ID on a server is pinned and marked unverified.
- A later bundle for the same user ID with a **different identity key** is a hard error: accounts
  never change identity keys, so the server is lying or its database was replaced. The client
  refuses to encrypt to that user, shows "<name>'s key changed" in the conversation and the user
  list, and offers **Verify** and **Trust the new key**, like the server key flow.
- A new **encryption key** under the same identity key, correctly signed, is accepted and shown as
  a notice in the conversation ("<name> set up encryption again"), because only the identity key's
  owner can sign it. It clears `verified`.
- A user without a bundle can receive no encrypted message: see 4.6.

### 3.5 Verification

A safety number per pair of accounts, independent of the server:

```
SHA-512("haychat-safety-number-v1" || min(idA, idB) || max(idA, idB))   // identity keys, bytewise
```

The first 60 bytes become 60 decimal digits in 12 groups of 5: each 5-byte chunk, read as a
big-endian integer, is reduced mod 100000 (Signal's encoding). The user's context menu gets
**Verify encryption…**, which shows the number and **Mark as verified**. Verified state is per
server, but the number is the same on every server where the two identity keys meet, because
profiles use one identity key everywhere.

The UI shows three states on a direct conversation and on each member of an encrypted room:
unverified (pinned on first use), verified, and key changed (sending blocked).

## 4. Sealed envelopes and encrypted direct messages

### 4.1 Envelope

One envelope format carries direct messages, sender-key distributions and forwarded room keys:

```
SealedEnvelope {
	version:      u8              // 1
	kind:         u8              // DirectMessage, SenderKey, RoomKeyForward
	ephemeralKey: [32]u8          // X25519, fresh per envelope
	wraps:        [dynamic]KeyWrap
	nonce:        [24]u8          // XChaCha20-Poly1305
	ciphertext:   []u8            // padded plaintext, with the 16-byte tag
	signature:    [64]u8          // sender's identity key, over the AAD and every field above
}
KeyWrap { recipientUserId: int, wrappedKey: [48]u8 }   // 32-byte key + 16-byte tag
```

Sealing, for message key `K` (32 random bytes) and each recipient `R`:

```
ss_R        = X25519(ephemeralPrivate, R.encryptionPublicKey)
wrapKey_R   = HKDF-SHA256(ikm = ss_R,
                          salt = ephemeralPublic || R.encryptionPublicKey,
                          info = "haychat-e2ee-wrap-v1" || kind || AAD)
wrappedKey  = XChaCha20-Poly1305(wrapKey_R, nonce = 0^24, plaintext = K)
ciphertext  = XChaCha20-Poly1305(K, nonce, pad(plaintext), AAD)
signature   = Ed25519(senderIdentity, "haychat-e2ee-envelope-v1" || AAD
                      || every envelope field before the signature)
```

The all-zero nonce is safe because each `wrapKey_R` is used once. The AAD (4.2) is not carried in
the envelope; both sides rebuild it from the conversation, and the server cannot change it without
breaking both the tag and the signature.

Opening: rebuild the AAD, check the signature against the sender's **pinned** identity key first,
then find the wrap for one's own user ID, unwrap `K`, open the ciphertext, strip the padding. Any
failure shows "This message could not be decrypted" in place of the message and is never retried
silently with other keys.

Rejected: libsodium sealed boxes (a native dependency, and they cannot be decrypted by the sender)
and HPKE (not in `core:crypto`; this is the same DH-KEM shape, written out).

### 4.2 Direct message AAD

```
"haychat-dm-v1" || serverIdentityPublicKey (32) || senderUserId (i64 LE)
|| recipientUserId (i64 LE) || senderIdentityKey (32) || recipientIdentityKey (32)
|| clientMessageId (16)
```

The server identity key stops replay onto another server; the user IDs and identity keys stop
the server moving a message to another conversation. `clientMessageId` is 16 random bytes the
sender chooses: the server's message ID is assigned after the message is sealed, so it cannot be
bound, but the client's ID can, and it lets the client detect a replayed or duplicated envelope
within a conversation.

### 4.3 Signed, not deniable

Every envelope carries an Ed25519 signature, so a recipient can prove to a third party that the
sender wrote the message. Without a signature, anyone who knows the recipient's public key could
seal a message "from" anyone. Deniable authentication (the Signal approach) needs interactive
key agreement and ratchets, which conflict with history that is re-read from the server. Accepted
for this design; section 11 records it.

### 4.4 Plaintext and padding

The sealed plaintext is CBOR:

```
SealedDirectMessagePlaintext { content: string }   // 1..CHAT_MESSAGE_MAX_BYTES bytes of UTF-8
```

Padded to the next multiple of 256 bytes (a 0x80 byte, then zeros) before sealing, so the server
learns length only in 256-byte steps. CBOR leaves room for later fields (replies, edits) inside
the encryption.

### 4.5 Wire, server and client behaviour

```
ClientSealedDirectMessage { recipientUserId, clientMessageId: [16]u8, envelope: []u8 }
ServerSealedDirectMessage { id, senderId, senderNickname, recipientId, recipientNickname,
                            timestamp, clientMessageId, envelope }
```

`StoredDirectMessage` and `DirectConversationSummary` gain `clientMessageId` and `envelope`
fields; `content` / `lastContent` stay for older plaintext messages and are empty on encrypted
ones. The client decrypts the newest message for the conversation-list preview.

The server:

- checks that the recipient exists and is not the sender, as today;
- checks the envelope's size (`SEALED_ENVELOPE_MAX_BYTES`, 8192), its version and kind byte, and
  that it carries exactly two wraps naming the sender and the recipient;
- verifies the signature: it knows every AAD field and the sender's identity key, so it can refuse
  garbage early, though it learns nothing about the content;
- stores the envelope and echoes it to every session of both users, as today. The sender's wrap is
  what lets the sender read its own history later.

The client:

- encrypts a direct message whenever the peer has a pinned, unchanged bundle;
- marks the conversation `encrypted` in its key store after the first encrypted message either
  way, and from then on never sends plaintext to that peer unless the user turns on the fallback
  of 4.6 (no silent downgrade);
- shows a lock on encrypted messages and "Not encrypted" on plaintext ones from before the upgrade.

### 4.6 When encryption is not possible: the plaintext fallback

Encryption to a peer is not possible when:

- the peer has no bundle and this client has never pinned one: the peer has not signed in since the
  upgrade, or its client failed to make its key ("<name> has not set up encryption yet");
- the peer's identity key changed (3.4) and the user has not trusted the new one ("<name>'s key
  changed");
- the client has a pin for the peer but the server now says it has no bundle. Bundles are never
  deleted, so this is the server misbehaving; the client says "The server is not providing
  <name>'s key".

In each case the composer is disabled by default and a banner above it says why. The banner has a
**Send without encryption** switch, off by default, so the user can still reach the peer, for
example to tell them to update their client:

- The switch is per conversation and is never saved: it turns off when the client restarts, when
  the conversation is closed, and by itself as soon as encryption becomes possible again.
- While it is on, the composer shows a red "Unencrypted: the server can read this" label and the
  send button reads **Send unencrypted**.
- The first time it is turned on in a conversation, a confirmation explains that the server and its
  operator can read these messages.

A fallback message goes out as today's `ClientDirectMessage`, with two additions that let the
recipient check who wrote it:

```
ClientDirectMessagePayload { recipientUserId, content, clientMessageId: [16]u8, signature: [64]u8 }
signature = Ed25519(senderIdentity, "haychat-dm-plain-v1" || serverIdentityPublicKey
                    || senderUserId || recipientUserId || clientMessageId || content)
```

The server checks the signature like an envelope's and stores `client_message_id` and `signature`
with the message. Both clients show every plaintext message of a conversation that has been
encrypted before, and every fallback message, with an "Unencrypted" badge in the warning colour,
and the conversation list shows the badge on a plaintext preview. A plaintext message whose
signature does not verify against the sender's pin shows "Unencrypted, sender not verified".
Messages from before the upgrade carry no signature and show "Not encrypted" only.

Rejected: refusing with no way around it (it strands a user whose peer's client is broken, and
the people involved would just use another channel), and a fallback that stays on (it would turn
into the default without anyone noticing).

## 5. Room access modes (prerequisite)

A room every account joins automatically cannot keep its keys from anyone, so encrypted rooms are
invite-only. Invite-only rooms are worth having without encryption too, so access modes ship first,
as their own package. The server enforces them for every room, encrypted or not; section 6 adds
what encryption needs on top.

### 5.1 The three modes

The admin who creates a room chooses its mode (`rooms.access`, `RoomSummary.access`):

| Mode | Who is a member | Who can add members | Who can remove members |
| --- | --- | --- | --- |
| **Public** | Every account, as today: new accounts join it and a new room includes everyone | Nobody needs to | Admins |
| **Member invite** | Whoever has been invited | Any member, and admins | Admins (section 10, Q8) |
| **Admin invite** | Whoever has been invited | Admins only | Admins |

In every mode, any member can leave a non-public room, and admins can still rename, edit and delete
the room. Existing rooms become Public, so nothing changes for them.

### 5.2 Creating a room without joining it

`ClientCreateRoomPayload` gains `access`, `historyVisibility` (5.4), `encrypted` (6.1) and
`creatorJoins` (default true). An admin who clears **Join this room** creates a room they are not a
member of. That is their choice: they do not see its messages or get its keys, but they can still
add and remove members and delete it, from the room's entry in the Admin section (a non-member does
not have the room in their room list).

### 5.3 Wire and UI

- `ClientAddRoomMember` and `ClientRemoveRoomMember` (they exist today, admin-only) follow the table
  above: the server allows an add from a member of a member-invite room as well as from an admin,
  and refuses adds to public rooms. `ClientLeaveRoom` lets a member leave a non-public room.
- `ClientFetchRoomMembers { roomId }` → `ServerRoomMembers { roomId, userIds }`, for members and
  admins.
- A non-public room appears in `ServerListRooms` only for its members. An admin's Admin section
  lists every room through a new `ClientAdminListRooms` → `ServerAdminRooms`. Removing a member
  sends them `ServerRoomMembershipChanged{joined:false}`, as today.
- The create-room form gets the mode, **Join this room**, **History for new members** and
  **Encrypt this room**. The room's settings get a **Members** page (add and remove, as the mode
  allows), the user context menu gets **Invite to room…** for the rooms the user may invite to, and
  rooms get a **Leave room** entry.
- Changing a room's mode after creation: an admin may switch an unencrypted room between any two
  modes (switching to Public adds every account); an encrypted room may switch only between Member
  invite and Admin invite (6.2).

### 5.4 History for new members

`rooms.history_visibility`, chosen at creation and fixed afterwards:

- **From join** (the default): a member reads messages sent after they were added. For an
  unencrypted room the server enforces it, serving history only after `room_members.joined_at`; for
  an encrypted room the keys enforce it too (6.6).
- **Full history**: a new member reads everything the room has, as members of public rooms do
  today. For an encrypted room, members' clients forward the older keys (6.6).

Public rooms always have full history. Someone who is removed and later added again counts as new
from the second addition.

## 6. Encrypted rooms

### 6.1 Creating one

`ClientCreateRoomPayload.encrypted` (5.2). An encrypted room must be Member invite or Admin
invite, and **Encrypt this room** is checked by default for those modes (section 10, Q9). The
flag never changes: the server refuses `ClientEditRoom` that clears it, and turning an existing room
into an encrypted one is not offered (create a new room instead; section 10, Q3).

An encrypted room has at most `ENCRYPTED_ROOM_MEMBERS_MAX` (100) members (section 10, Q6).
Managers who are not members do not count. The server refuses an `Add` that would exceed it with
`ServerProtocolError "This encrypted room is full"`, and the Members page says so before sending.
Unencrypted rooms, public or invite-only, have no member limit.

Creating an encrypted room writes the first entry of its member log (6.2), signed by the creator.

### 6.2 The member log

The server's `room_members` is authoritative for access (sends, history), but in an encrypted room
it cannot be the authority for *who gets keys*, or the operator could add an account and read
along. Membership of an encrypted room is therefore a hash chain of signed entries:

```
RoomLogEntry {
	roomId:        int
	version:       int             // 1, 2, 3, … ; also the room's epoch
	prevHash:      [32]u8          // SHA-256 of the previous entry's bytes; zeros for version 1
	action:        enum { Create, Add, Remove, AddManager, RemoveManager, Leave, SetAccess }
	targetUserId:  int
	targetIdentityKey: [32]u8
	actorUserId:   int             // 0 for a server removal
	actorIdentityKey: [32]u8       // zeros for a server removal
	createdAt:     u64
	settings:      RoomLogSettings // Create and SetAccess only
	signature:     [64]u8          // actor's identity key, over "haychat-room-log-v1"
	                               //   || serverIdentityPublicKey || everything above
}
RoomLogSettings {
	access:            u8          // MemberInvite or AdminInvite
	historyVisibility: u8          // FromJoin or Full; set by Create, never changed
	creatorJoins:      bool        // Create only
	managers:          [dynamic]{userId: int, identityKey: [32]u8}   // Create only
}
```

**Managers.** A manager is an account the log allows to manage access. Being a manager and being a
member are separate: a manager who is not a member gets no keys and reads nothing, but can sign
additions and removals. That is how an admin who created a room without joining it (5.2) keeps
managing it.

The server's admin role cannot decide who signs, because the admin role is server state: a server
that could name admins could name itself a manager. So the managers are fixed in the log instead:

- The create form lists every account the creator's client sees as an admin, all checked; the
  creator is always a manager. The `Create` entry names the checked ones with their pinned identity
  keys. A server that lists a fake admin at that moment gets in only if the creator leaves its
  name checked, and the room's Members page shows the managers to every member.
- Later admins become managers through `AddManager`, signed by a current manager. Until then, an
  admin who is not a manager can still remove members and delete the room (server actions, below),
  but cannot add anyone to an encrypted room. The client says so: "Only this room's managers can add
  members; ask <names>."
- An admin who loses the admin role stays a manager until a manager removes them, and the server
  stops accepting their requests at once: an add needs both the server's permission and a valid
  signature.

Rules every client checks when it replays the log:

- Version 1 is `Create`, signed by the creator, who is a manager and, with `creatorJoins`, the
  first member.
- `Add` needs the signature of a current manager or, in a Member invite room, of a current member.
  Each target's identity key must match the client's pin for that user ID, or the client pins it now
  (first use).
- `AddManager`, `RemoveManager` and `SetAccess` (switching between Member invite and Admin invite)
  need a current manager's signature. A manager may add themselves as a member like anyone else,
  and that shows in the room like any addition.
- **Changed in protocol 33 (#195, 2026-11-26):** `RemoveManager` may also be unsigned
  (`actorUserId` 0, a zero actor key and signature), written by the server when it bans a
  manager. It is valid only when its target is no longer a member (so a manager who is a member
  first gets the server's `Remove`), and the last-manager rule below does not apply to it.
  Nothing in the entry ties it to a ban: the server is not trusted, so clients cannot tell a ban
  from any other reason. What a malicious server gains is the power to take any manager away
  (one who is a member only together with a visible removal), up to leaving the room with no
  manager. That freezes the room's membership changes, which the server could already do by
  refusing every append, and is less than it could already do by removing every member. It
  still cannot add a member or a manager, and every such demotion shows in the room ("the
  server removed alice as a manager").
- `Remove` is valid when a manager signs it, *or* unsigned (`actorUserId` 0): the server may always
  remove a member (an admin's removal, a ban, an account deleted). Removing can only take readers
  away, so the server needs no signature for it.
- `Leave` is signed by the member who leaves.
- The last manager cannot be removed while the room has members, except by the server's unsigned
  `RemoveManager` (protocol 33). If every manager loses their key, or a ban removed the last one,
  nobody can add members any more (in a Member invite room members still can), change the
  managers or switch the access; members still talk, and an admin can still remove members and
  delete the room. The server never promotes anyone.

The server keeps the log in `room_log_entries`, applies each entry to `room_members` in the same
transaction, and refuses an entry whose `version` or `prevHash` does not follow its head. Its own
rules from 5.1 still apply on top, so an addition needs both the server's permission (an admin, or
a member of a Member invite room) and a valid signature. An admin's removal arrives as an ordinary
`ClientRemoveRoomMember`, and the server writes the unsigned `Remove` entry itself. A ban
(protocol 32) writes that `Remove` in every encrypted room the account is a member of, and since
protocol 33 then an unsigned `RemoveManager` in every encrypted room whose log names it as a
manager.

```
ClientAppendRoomLog   { entry }                         // Add, Remove, managers, Leave
ClientFetchRoomLog    { roomId, afterVersion }
ServerRoomLog         { roomId, entries, headVersion }  // the answer, and the fan-out of each
                                                        // new entry to the room's members
```

Each client keeps the verified head (version and hash) per room in its key store. It refuses a log
that rewrites an entry it already verified (a fork) and shows "This room's member list was changed
on the server" with sending disabled.

The room shows each verified change as an event line ("alice added carol", "the server removed
dave", "erin (manager) added herself"), so additions are visible to every member.

Rejected: trusting `room_members` and showing changes (the server could add a silent reader); the
current admin role as the signer set (the server decides who is an admin, so it could make itself
one); only the creator as manager (one lost `config.json` would freeze the room's membership).

### 6.3 Sender chains

Each member who sends in an epoch has one chain for it:

```
chainKey_0         = 32 random bytes
messageKey_i       = HKDF-SHA256(chainKey_i, salt = none, info = "haychat-room-msg-v1")
chainKey_{i+1}     = HKDF-SHA256(chainKey_i, salt = none, info = "haychat-room-chain-v1")
chainId            = 16 random bytes
```

A chain ends with its epoch, or after `SENDER_CHAIN_MAX_MESSAGES` (1000) messages or
`SENDER_CHAIN_MAX_AGE` (7 days), whichever comes first; the sender then starts a new chain in the
same epoch. The cap bounds how far a reader steps a chain forward to reach message `i` (at most
1000 HKDF calls), so random access for history paging needs no skip structure like Megolm's.

A recipient keeps `chainKey_0` (or the first key it was given) and derives forward. Keeping the
start of the chain is what lets history be re-read after a restart; it also means a stolen key store
reads the whole chain (1.2).

### 6.4 Distributing chains

The first time a sender sends in an epoch (and each time it starts a chain), it seals a
distribution to every member of the epoch, *as the verified log shows them*, before the first
message:

```
SenderKeyDistributionPlaintext { roomId, epoch, chainId, startIndex, chainKey }
```

It is one `SealedEnvelope` of kind `SenderKey` with one wrap per member (the sender included), and
AAD

```
"haychat-room-key-v1" || serverIdentityPublicKey || roomId || epoch || senderUserId || chainId
```

```
ClientRoomKeyEnvelope { roomId, epoch, chainId, envelope }
ServerRoomKeyEnvelope { roomId, epoch, senderId, chainId, envelope }
ClientFetchRoomKeys   { roomId, sinceEpoch }      // on connect and on a missing key
```

The server stores it once in `room_key_envelopes` and delivers it to the members' sessions, live
and on fetch. A wrap per member keeps this one row per chain, not one per member. For rooms of tens
of members an envelope is a few kilobytes, and at the limit of 100 members (6.1) about 5 KB.

A recipient checks the signature against the sender's pin, that the sender is a member of that
epoch in its verified log, and that its own user ID is in the wraps.

A client that sees a message for a chain it has no key for shows "Waiting for this message's key
from <sender>" and sends `ClientRequestRoomKey { roomId, epoch, chainId }`, which the server passes
to the sender's online sessions; the sender re-seals the chain to the requester if the requester was
a member of that epoch. This covers a member who was added while the sender's distribution was in
flight.

### 6.5 Messages

```
SealedRoomMessage {
	version: u8, epoch: int, chainId: [16]u8, index: u32,
	nonce: [24]u8, ciphertext: []u8, signature: [64]u8
}
AAD = "haychat-room-v1" || serverIdentityPublicKey || roomId || senderUserId || epoch
      || chainId || index || clientMessageId
```

The ciphertext is `XChaCha20-Poly1305(messageKey_index, nonce, pad(plaintext), AAD)`, the
plaintext is the same CBOR as for direct messages (4.4), and the signature is the sender's identity
key over the AAD and the message bytes. Signing per message is what stops one member from forging
another member's message with the shared chain key.

`ClientChatMessagePayload` and `ServerChatMessagePayload` / `StoredChatMessage` gain
`clientMessageId` and `sealed` fields, as for direct messages. The server checks membership, size,
and that `epoch` is the room's current log version; it refuses a stale epoch with
`ServerProtocolError "Room key is out of date"` and the client fetches the log, starts a chain in
the new epoch and sends again. That forces a removal to take effect at the server, not only at
clients that saw it.

### 6.6 Epochs and history

- Every log entry is a new epoch. Senders start new chains lazily on their next send.
- **Removal:** the removed member is not in the new epoch's wraps, so it gets nothing sent after the
  removal. It keeps what it already had.
- **Addition, From join rooms:** the new member gets every chain of its first epoch on and nothing
  before. Clients never forward older chains in these rooms, and the server serves history only
  from the member's `joined_at` (5.4), so the client does not show a page of messages it cannot
  open.
- **Addition, Full history rooms:** older chains are forwarded to the new member as
  `RoomKeyForward` envelopes:
  - The client that signs the `Add` forwards every chain it holds right after the addition, in one
    envelope per epoch, sealed to the newcomer only.
  - The inviter may not hold everything (they may have joined later themselves, or be a manager who
    is not a member and holds nothing). For the rest, the newcomer's client sends
    `ClientRequestRoomKey` for each chain it meets in history without a key. The server passes the
    request to the online members, and any member whose verified log shows the room as Full history
    and the requester as a current member re-seals the chain. The first answer wins; the others are
    dropped by the newcomer's client as duplicates.
  - Messages stay signed by their real senders, so a forwarder cannot forge history, only give
    access to it. A forwarded chain is checked against the sender's pin and the log like any other.
  - A chain that no online member holds stays unopened until one connects. The message shows
    "Waiting for this message's key".
  - **Checking a forwarded key** (changed 2026-11-26, protocol 34, #78, the maintainer's option
    B2). The server stores the first copy of a chain per recipient, so a member could forward a
    wrong chain key, validly signed, ahead of the real one, and a wrap made for the recipient's
    old encryption key would block every later copy in the same way. Both only hide messages:
    each message is still checked against its sender's pin. Now:
    - A client keeps a chain someone else sent **unchecked**, in memory only, until a message (or
      sealed edit) of that chain opens with it. The message's signature is verified against the
      sender's pin first, as always. A chain with no message yet stays unchecked until its first
      message arrives. An unchecked chain is never written to the key store, so after a restart
      its envelope is fetched and checked again.
    - A key whose message fails the AEAD, or whose start index is past the message's index, is
      dropped. So is an envelope addressed to the client that does not open or that the client
      may not take. The client then sends `ClientRejectRoomKeyEnvelope{envelopeId}` and never
      opens that envelope again. The failure is logged on the client only and reported to
      nobody.
    - The server takes the requester off that envelope's wraps in the statement that checks it.
      The envelope must have a wrap for the requester and must be of a chain the requester did
      not send. The row is deleted when the requester was its only recipient, which is always
      the case for a forward and for a re-seal answering the requester. A SenderKey distribution
      from the chain's own sender may be rejected the same way, because its wrap for the
      requester can be just as unopenable (the sender's pin was stale) and it blocks forwards
      just as much. The other recipients keep their wraps. The next forward or re-seal for the
      requester is then stored. The server allows at most 20 rejects per session per minute.
    - After a reject the client fetches the room's envelopes again and asks for the chain again
      (`ClientRequestRoomKey`) after a back-off of 2, 8 and then 30 seconds. It does this at most
      three times per chain and session, and sends at most four rejects per chain and session,
      so one hostile member cannot make a newcomer loop. Members answer the same request again
      only after 1.5 seconds.
    - The `held` check ignores a wrap stored before the recipient's current encryption key
      (`user_encryption_keys.updated_at`). An envelope does not name the key its wraps were made
      for, so the stored times decide, with no migration. A bundle that is stored again with the
      same key lets one more copy through. A wrap made for an old key that the server stored
      after the change, because the sender's pin was stale, is rejected by the client as above.
    - The envelope layout is unchanged.

### 6.7 What servers and admins can still do

Delete the room or any message, remove members, refuse sends, rename the room, and see who is a
member. An admin who is a manager can also add members, themselves included, visibly. An admin who
is neither a member nor a manager cannot read the room or add anyone to it. Nobody outside the
room can read encrypted content to moderate it; reports would need message franking (section 11).
Room names and descriptions stay plaintext.

## 7. Client

### 7.1 Module layout

- `common/e2ee.odin`: envelope sealing and opening, the sender chain, AAD builders, the log entry
  encoding and verification, padding, safety numbers. Pure functions on caller buffers, so the
  server's validation and both clients share them. Known-answer tests in `common/e2ee_test.odin`.
- `client/keystore.odin`: the key store file (3.3): load, save, pins, chain cache, log heads.
- `client/e2ee_state.odin`: the state machine on top: fetching bundles, deciding whether a
  conversation is encrypted, queuing sends that wait for keys or bundles, opening incoming messages
  and history pages, key requests.
- Views: lock and state icons in `client/view_direct.odin` and the room header, the plaintext
  fallback banner, switch and "Unencrypted" badges (4.6), **Verify encryption…** and **Invite to
  room…** in `client/context_menu.odin`, the create-room options and the Members page from section
  5, and log events in the message list.

### 7.2 Sending

A send in an encrypted conversation does not go out until its prerequisites are there: the peer's
bundle (direct), or the verified log head and a current chain (room). The composer shows "Setting up
encryption…" while it waits, at most a few round trips. The message still appears only through the
server's echo, as today.

### 7.3 Receiving and history

History pages arrive with envelopes. The client opens each with the keys it has, fetches missing
room keys once per page, and marks what it cannot open. Pagination by server message ID is
unchanged.

### 7.4 Losing `config.json`

The encryption key lives only in `config.json`. A user who loses it gets a new identity, so a new
account (0.1), and loses every encrypted message; the user guide says so next to the existing
warning about the identity key. Section 11 lists key backup as a later step.

## 8. Voice (later phase)

> **Superseded.** Voice in encrypted rooms was designed again in
> [e2ee-voice-design.md](e2ee-voice-design.md) and built as protocol 21 (E6): the voice key is a
> fresh random key in its own `VoiceKey` envelope, not derived from the text chain below. This
> section is kept as the historical record.

For encrypted rooms only. Each participant derives a voice key from its current sender chain at
join, with a fresh random 16-byte `voiceSessionId` that its join announces to the other
participants, and seals each Opus payload inside the existing voice frame plaintext:

```
voiceKey = HKDF-SHA256(chainKey_0, salt = voiceSessionId, info = "haychat-voice-v1")
inner    = XChaCha20-Poly1305(voiceKey, nonce = frameSequence (u64 LE, zero-padded to 24),
                              opus, AAD)
AAD      = "haychat-voice-e2ee-v1" || roomId || senderUserId || epoch || chainId
           || voiceSessionId || frameSequence
```

A key is used for one voice session only, so the frame sequence alone makes every nonce unique.

The server's relay already opens the per-hop datagram and reseals it per listener
(`server/voice_relay.odin`); it would forward `inner` unchanged. That adds 16 bytes per frame.
Joining voice in an encrypted room distributes the chain first if the joiner has not sent in this
epoch. Per-frame signatures are too expensive; the AEAD tag under a key shared with the room
authenticates "a member", not which one, and the relay's sender ID tells which, which matches what
SFrame offers. Voice packet-loss handling is unchanged.

**Superseded by `docs/plan/e2ee-voice-design.md` (E6, 2026-11-15):** the voice key is a fresh
random key in its own `VoiceKey` envelope instead of a derivation from `chainKey_0`, which Full
history forwarding (E5) would have exposed to later members.

## 9. Wire and schema changes

### 9.1 Protocol

Every change bumps `protocolVersion` and appends `MessageType` members at the end of the enum,
each pinned in `common/protocol_test.odin`:

| Phase | Version | New messages |
| --- | --- | --- |
| E1 | 15 | `ClientPublishEncryptionKey`, `ClientFetchUserKeys`, `ServerUserKeys`, `ServerUserKeyChanged`; `UserSummary.identityPublicKey`, `hasEncryptionKey` |
| E2 | 16 | `ClientSealedDirectMessage`, `ServerSealedDirectMessage`; envelope fields on stored direct messages and conversation summaries; `clientMessageId` and `signature` on `ClientDirectMessagePayload` and stored plaintext direct messages (4.6) |
| E3 | 17 | `ClientFetchRoomMembers`, `ServerRoomMembers`, `ClientAdminListRooms`, `ServerAdminRooms`; `RoomSummary.access`, `historyVisibility`; `ClientCreateRoomPayload.access`, `historyVisibility`, `creatorJoins`; members may send `ClientAddRoomMember` and `ClientLeaveRoom` |
| E4 | 18 | `ClientAppendRoomLog`, `ClientFetchRoomLog`, `ServerRoomLog`, `ClientRoomKeyEnvelope`, `ServerRoomKeyEnvelope`, `ClientFetchRoomKeys`, `ClientRequestRoomKey`, `ServerRoomKeyRequest`; `RoomSummary.encrypted`, `ClientCreateRoomPayload.encrypted`, sealed fields on chat messages |
| E5 | 19 | `RoomKeyForward` envelopes, and key requests answered by any member in Full history rooms (6.6) |

Envelopes, log entries and sealed room messages are fixed binary layouts encoded by
`common/e2ee.odin` and carried as CBOR byte strings, so their signed bytes never depend on a CBOR
encoder's choices.

### 9.2 Schema

| Migration | Phase | Change |
| --- | --- | --- |
| 4 | E1 | `user_encryption_keys (user_id PK → users, encryption_public_key BYTEA, created_at_unix BIGINT, signature BYTEA, updated_at)` |
| 5 | E2 | `direct_messages`: `content` may be empty, add `client_message_id BYTEA`, `envelope BYTEA`, `signature BYTEA` (fallback messages); `CHECK` exactly one of non-empty `content` or `envelope`, and `octet_length(envelope) <= 8192`; unique `(sender_user_id, client_message_id)` |
| 6 | E3 | `rooms.access SMALLINT NOT NULL DEFAULT 1` (Public), `rooms.history_visibility SMALLINT NOT NULL DEFAULT 1` (From join; ignored for Public rooms) |
| 7 | E4 | `rooms.encrypted BOOLEAN NOT NULL DEFAULT false`, `rooms.log_version BIGINT NOT NULL DEFAULT 0`; `room_log_entries (room_id, version, entry BYTEA, PK (room_id, version))`; `room_key_envelopes (id, room_id, epoch, sender_user_id, chain_id, envelope, created_at)` indexed by `(room_id, epoch)`; `chat_messages` gets the same columns and checks as `direct_messages` in migration 5 |

Read markers and unread counts are unaffected: they count message IDs and senders, which stay
plaintext.

### 9.3 Configuration

New client keys (`docs/client-configuration.md`, `client/config.odin`, `client/config_test.odin`):
`encryption_private_key`, `encryption_public_key`, `encryption_key_signature`,
`encryption_key_created_at`, generated on first start when missing or invalid. A key that fails
its own signature check is replaced, and peers see a new encryption key (3.4). The key store's
location and format are documented on the same page. No new server variables.

## 10. Decisions

Every question was decided by the maintainer on 2026-11-14. The numbers are the ones the questions
had while they were open; the sections named carry the details.

| Question | Decision |
| --- | --- |
| **Q1. Peers without a key** | Sending is refused by default, with an explicit per-conversation option to send without encryption and a visible warning on every such message (4.6). |
| **Q2. History for new room members** | Both, as a setting chosen at room creation: From join (the default) or Full history (5.4, 6.6). |
| **Q3. Converting rooms** | Encryption is chosen at creation and never changes (6.1). Encrypting an existing room from then on was rejected: its old history would stay readable to the server and the UI would have to explain a mixed room. |
| **Q4. Who can add members** | Three access modes chosen by the admin who creates the room: Public, Member invite and Admin invite. An admin may create a room they do not join and still manage its access or delete it (5.1, 5.2). In encrypted rooms, managing access goes through the managers named in the member log (6.2). |
| **Q5. Encryption key rotation** | None in this design (2.2). Rotation is only useful together with deleting old keys, which needs the local message cache of section 11. |
| **Q6. Room size** | Encrypted rooms have at most 100 members, where a distribution envelope is about 5 KB (6.1); larger encrypted rooms are what MLS is for. Unencrypted rooms have no member limit. |
| **Q7. Plaintext direct messages from before the upgrade** | They stay as they are, marked "Not encrypted" (4.5, 4.6). |
| **Q8. Removing members of a Member invite room** | Admins, and in encrypted rooms managers, only. Members can invite and leave but not remove each other (5.1). Letting the inviter remove whom they invited was rejected: the server would have to remember who invited whom. |
| **Q9. Encryption by default** | **Encrypt this room** is checked by default for Member invite and Admin invite rooms (6.1). |
| **Q10. Initial managers** | Every admin the creator's client sees, checked by default in the create form (6.2). Only the creator was rejected: one lost key would freeze the room's membership. |

## 11. Later steps

- **MLS (RFC 9420)** for large rooms or post-compromise security. The server would act as the
  Delivery Service that orders commits, which it already does for the member log; the log of 6.2
  maps onto MLS commits. It needs an Odin implementation of TreeKEM and the MLS key schedule, or a
  binding to OpenMLS or mlspp.
- **Forward secrecy:** a local encrypted message cache, then deleting chain and message keys after
  use, and shorter chains.
- **Key backup:** the encryption and identity keys exported under a passphrase (`argon2id`), so a
  lost `config.json` is recoverable.
- **More than one device per account**, each with its own keys: today a second device is a copy of
  the profile.
- **Message franking** for verifiable abuse reports in encrypted rooms.
- **Deniable authentication** in place of signatures.
- **Post-quantum key agreement:** ML-KEM (`core:crypto/mlkem`) next to X25519 in the envelope's key
  wrap.

## 12. Test plan

### 12.1 Unit tests (`odin test common`)

- Envelope round trip for one and many recipients; the sender's own wrap opens.
- Every tamper fails: a flipped bit in each field, a wrap moved to another recipient, a changed AAD
  field (server key, user IDs, room, epoch, chain, index, client message ID), a signature by another
  key, a truncated envelope.
- Padding: every length from 1 to `CHAT_MESSAGE_MAX_BYTES` round-trips; a bad padding byte fails.
- Sender chain: known-answer vectors for the first keys; deriving index `i` from `chainKey_0` equals
  stepping; the cap.
- Member log: valid chains; an add signed by a non-manager in an Admin invite room (refused) and
  by a member in a Member invite room (accepted); a manager who is not a member signing an add; a
  `SetAccess` by a non-manager; a broken `prevHash`, a rewritten entry (fork), an unsigned add, and
  an unsigned removal (accepted).
- Fallback signature: a plaintext direct message's signature verifies, and fails when any bound
  field changes.
- Safety number: symmetric in the two keys and stable (a known-answer vector).

### 12.2 Server tests (`odin test server -define:ODIN_TEST_THREADS=1`)

The server stores envelopes byte for byte and returns them in history; refuses oversized and
malformed envelopes, wraps for the wrong users, stale epochs, and log entries that do not follow
the head, and an `Add` past `ENCRYPTED_ROOM_MEMBERS_MAX` (but not in an unencrypted room); applies
log entries and `room_members` in one transaction; refuses a fallback direct
message with a bad signature. Access modes: who may add, remove and leave in each mode (5.1), an
admin creating a room without joining it, non-public rooms missing from non-members' room lists,
From join history starting at `joined_at`, and mode changes (5.3). Migrations 4–7 on an rc1
database.

### 12.3 Client tests (`odin test client`)

Key store load and save, pinning, a changed identity key blocking sends, a new encryption key
accepted with a notice, no downgrade in an encrypted conversation, sends queued until a bundle or a
chain arrives, missing-key placeholders and key requests, and a fake server that swaps a key or
adds an unsigned member, which the client refuses. The fallback switch: off by default, never
saved, off again once encryption is possible, and the badges on both sides. Full history: the
inviter forwards what it holds, other members answer key requests, From join rooms never forward.

### 12.4 Live proof (`dev/e2ee-proof.sh`, in `dev/live-proof.sh --e2ee` and `--all`)

Three headless clients against a throwaway server:

1. alice and bob exchange encrypted direct messages; both see them, and alice's history, after a
   restart of her client, still opens.
2. A SQL check: no message text appears in `direct_messages` or `chat_messages`
   (`position(convert_to('marker-text', 'UTF8') in envelope)` is 0 on every row, and `content` is
   empty).
3. admin alice creates an encrypted Admin invite room and adds bob; carol, not a member, cannot
   fetch its history or keys.
4. alice removes bob; a message sent after that does not open for bob, and bob's client shows the
   removal.
5. A row inserted into `room_members` behind the server's back adds carol: she can fetch the
   room's history and envelopes, but no envelope has a wrap for her, so nothing opens. Then an
   unsigned `Add` for carol inserted into `room_log_entries`: alice's and bob's clients refuse the
   log, show the member-list warning, and stop sending.
6. Deleting bob's key store and restarting bob: his old messages open again from the stored
   envelopes.
7. dave, a fixture account that never published a key: alice's `dm` to dave is refused, and
   `dm-plain` reaches him with `encrypted` false and a valid signature on both sides; the SQL check
   finds that message's text, as it should.
8. A Member invite room with From join history: bob (a member) invites carol, who reads only what
   is sent after. A Full history room: alice invites carol, who reads the older messages, including
   a chain alice never held, which bob forwards on request.
9. An admin creates an encrypted Admin invite room without joining it, adds alice and bob, and
   cannot open its messages; a non-manager admin's add is refused by the clients' log check.

The harness gets `verify USER_ID`, `trust-key USER_ID`, `dm-plain USER_ID TEXT...` (the fallback,
through the same action as the GUI switch), `room-create` options for the access mode, history,
encryption and joining, `room-members ROOM_ID`, `room-add ROOM_ID USER_ID`,
`room-remove ROOM_ID USER_ID` and `room-leave ROOM_ID`, and `encrypted`, `signed`, `decryptError`
and `keyState` fields on its message and user events. `dev/ui-smoke.sh` checks the lock icon, the
fallback banner and badge, and the **Verify encryption…** dialog.

## 13. Work breakdown

| Package | Contents | Depends on |
| --- | --- | --- |
| E0 | `common/e2ee.odin` primitives and unit tests (12.1). No protocol change. | — |
| E1 | Encryption key in `config.json`, key bundles and fetching, the key store, pins, key-change handling, safety numbers and the verify dialog. Protocol 15, migration 4. | E0 |
| E2 | Encrypted direct messages, previews, no-downgrade rule, the signed plaintext fallback with its switch and badges, harness fields and `dm-plain`, live proof steps 1, 2, 6 (direct messages) and 7. Protocol 16, migration 5. | E1 |
| E3 | Room access modes: Public, Member invite and Admin invite, creating without joining, From join and Full history for unencrypted rooms, member fetch, leave, the Members page, **Invite to room…**, the admin room list, harness member commands. Protocol 17, migration 6. Useful on its own. | — |
| E4 | Encrypted rooms: member log with managers and access modes, sender chains, distribution and key requests, epochs, From join rooms, room UI, live proof steps 3–6, 8 (From join) and 9. Protocol 18, migration 7. | E2, E3 |
| E5 | Full history in encrypted rooms: the inviter's forwarding and key requests answered by any member (6.6), live proof step 8 (Full history). Protocol 19. | E4 |
| E6 | Voice in encrypted rooms (section 8), after its own design note. | E4 |

Documentation ships with each package: the "Not end-to-end" section of `docs/protocol.md`, the
user guide's encryption and room access sections, `docs/rooms-and-accounts.md` (access modes,
managers) and `docs/client-configuration.md` (the new keys and the key store).

E3 can run in parallel with E0–E2. E4 is the large one and may split into the log (E4a) and chains
and messages (E4b).

## 14. Risks

- **Usability of key changes.** Too many warnings train people to accept them. Accounts never change
  identity keys, which keeps real warnings rare; the design must not add routine ones.
- **The plaintext fallback becoming a habit.** It exists for reaching someone whose client cannot
  receive encrypted messages. It is never saved and turns itself off, so it cannot quietly become
  the way a conversation works.
- **Manager confusion.** Admins, managers and members are three different things in an encrypted
  room. The Members page shows all three, and the client says who to ask when someone may not add.
- **Key loss.** One file holds everything (7.4). Key backup (section 11) is the fix.
- **Hand-built envelope.** This is not a standard construction like HPKE. Known-answer vectors,
  tamper tests, and an outside review before release reduce the risk.
- **Log complexity.** The signed member log is the part that makes room encryption meaningful and
  the part most likely to have edge cases (concurrent appends, last manager, forks). The server's
  head check serialises appends; the client tests in 12.3 cover the rest.
- **Large rooms.** Sender-key distribution grows with members times senders per epoch; the size
  limit of 100 members (Q6) keeps it bounded until MLS.

## Appendix: files and sources checked

- `common/auth.odin` (identity keys, transport sealing), `common/protocol.odin` (message types,
  chat and direct payloads, `UserSummary`, limits), `server/database_migrations.odin` (schema),
  `server/main.odin` (room member handlers).
- `docs/protocol.md`, `docs/rooms-and-accounts.md`, `docs/client-configuration.md`,
  `docs/testing-harness.md`, `docs/plan/voice-rooms-design.md`.
- `$HOME/Odin/core/crypto` (available primitives).
- Signal's Sender Keys and safety numbers, Matrix's Megolm, RFC 9180 (HPKE, for the DH-KEM shape),
  RFC 9420 (MLS), and the SFrame draft (voice).
