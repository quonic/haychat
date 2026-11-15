# End-to-end encrypted voice: design (E6)

**Date:** 2026-11-15
**Base:** `main` at `33275a6` (protocol 20, schema migration 9)
**Status:** Design. Nothing is implemented. Every open question was decided by the maintainer on
2026-11-15 (section 10).
**Audience:** HayChat maintainers and the agent that will implement package E6

This note designs voice in encrypted rooms, the package that `docs/plan/e2ee-design.md` section 8
left for later and the E2EE round (`docs/plan/2026-11-14-e2ee-implementation.md`) left as its
first follow-up. Today the server refuses every voice join in an encrypted room
(`ENCRYPTED_ROOM_VOICE_MESSAGE`, `server/voice.odin`). After E6 voice in an encrypted room is end
to end encrypted: the relay forwards Opus it cannot read.

It keeps section 8's shape (a per-participant key, an AEAD layer inside the existing voice frame,
the relay forwarding the inner bytes unchanged, no per-frame signatures) and changes three things,
explained in section 2: the voice key is a fresh random key sealed in its own envelope rather
than derived from a text sender chain, it is never stored or forwarded, and it is rotated on
every member log change and on a timer.

## Summary

| Decision | Recommendation |
| --- | --- |
| Scope | Voice in encrypted rooms only. Unencrypted rooms keep today's voice, byte for byte. There is no plaintext fallback for voice: an encrypted room's voice is encrypted or silent. |
| Voice key | 32 random bytes per participant and *generation*, made by the participant's client. Not derived from any text sender chain (2.1). |
| Key distribution | One signed `SealedEnvelope` of a new kind `VoiceKey`, with a wrap for every member of the current epoch in the verified log, sent as `ClientVoiceKey`. The server checks it, keeps only the latest one per voice participant **in memory**, sends it to the room's other voice participants, and hands every participant's current key to each new joiner. Never stored in the database, never forwarded (3). |
| Rotation | A new generation on every join, every engine (re)open, every member log change, every 30 minutes, and on a listener's request (4). |
| Frames | The `opus` field of `ClientVoiceFrame`/`ServerVoiceFrame` carries `version (1) ‖ keyId (1) ‖ ciphertext ‖ tag (16)`: 18 bytes more per frame. XChaCha20-Poly1305 under the voice key, nonce from the frame sequence, AAD binding server, room, sender, epoch, session, generation, sequence and flags (5). |
| Relay | Unchanged crypto. In an encrypted room's route it skips the Opus TOC check (it cannot read the TOC), checks the inner version byte and the size without the overhead, and forwards the inner bytes as they are (6). |
| Client | The UI thread makes, seals and opens voice keys; the voice engine holds a small key table and seals and opens frames on the voice thread. Keys are wiped when the engine stops (7). |
| Freshness | A listener accepts a key only from a member of the epoch it has verified, only if it is newer than the last key it accepted from that sender, and only if it was made within the last hour by the listener's clock (4.3). |
| Leaks | Constant bitrate in encrypted rooms, so frame lengths do not follow speech (8). Who talks and when stays visible to the server, like all metadata (design 1.2). |
| Wire | Protocol 21: `ClientVoiceKey`, `ServerVoiceKey`, `ClientRequestVoiceKey`, `ServerVoiceKeyRequest`; `NetworkVoiceRoute` gains `encrypted`. No migration, no new configuration key. |
| Package | One package, `e2ee-voice` (E6), the size of E5. |

## 0. What exists today

- **Wire.** A voice frame is binary (`common/voice_wire.odin`): `ClientVoiceFrame { roomId u32,
  frameSequence u32, flags u8, opus 1..512 }`, sealed per hop in a voice datagram on ENet
  channel 2 with the transport's per-channel keys and a 64-packet replay window. The relay
  (`server/voice_relay.odin`) opens each datagram, checks the room, the mute state, the size
  (`HAYCHAT_VOICE_MAX_FRAME_BYTES`, default 512) and the Opus TOC byte (exactly 20 ms), rewrites
  it in place as a `ServerVoiceFrame` with `senderUserId`, and reseals it for each other
  participant. The server already sees every Opus byte.
- **Sequence.** `frameSequence` is the sender's 20 ms tick counter. A restarted engine
  (`State_voiceRestartEngine`, for a device change) continues the old one's clock and rounds up
  (`VoiceEngine_open`), so a sequence is never reused within a voice session.
- **Control.** `ClientJoinVoice`, `ServerVoiceParticipants` (`recipientJoined` is the join
  acknowledgement), `ServerVoiceLeft`, one voice session per user with device takeover
  (protocol 13). The router handles control (`server/voice.odin`); frames never reach it.
- **Encoder.** 24 kbit/s *constrained VBR*, in-band FEC, DTX off (`client/opus/opus.odin`); the
  gate sends frames only while the user talks.
- **Encrypted rooms.** A verified member log per room (epoch = log version), sender chains for
  text distributed as `SenderKey` envelopes with one wrap per member of the epoch, key requests
  and, in Full history rooms, `RoomKeyForward` envelopes (E4a, E4b, E5). At most 100 members
  (`ENCRYPTED_ROOM_MEMBERS_MAX`), so an envelope wrapping every member is about 6 KB
  (36 + 56 × 100 + 24 + 4 + 272 + 64 bytes).
- **Removal.** Removing a member evicts them from the room's voice (E3).

## 1. Threat model for voice

The design's model (1.1, 1.2) applies. For voice specifically:

**Protects against**

- The operator, the relay and anyone with a debugger on the server process hearing a call in an
  encrypted room.
- The server adding a listener: only members of the verified log get a wrap.
- A removed member hearing what is said after every remaining speaker has seen the removal
  (4.1), even if the server keeps relaying to them.
- The server inserting audio as a member, or replaying a recording more than an hour old, or
  from an earlier epoch (4.3).

**Does not protect against**

- **Metadata.** Who is in voice, who talks, when and for how long (the gate sends nothing in
  silence), and the bitrate.
- **Members impersonating members.** Every member of the epoch can open every speaker's key, so
  a member who controls the server, or colludes with it, can send audio under another member's
  key and `senderUserId`. Per-frame signatures would stop it and cost an Ed25519 signature 50
  times a second per speaker plus 64 bytes per frame; section 8 of the design rejected them, as
  SFrame does. An honest server stamps `senderUserId` from the session, so a member alone cannot.
- **Recent replays.** A server can replay a recording made in the last hour, in the same epoch,
  to a listener that has not yet seen a newer key from that speaker (4.3).
- **The few frames in flight at a removal.** A speaker who has not yet seen the removal keeps
  using the old key for a moment (4.1).

## 2. Why not derive the key from the text chain

Design section 8 proposed `voiceKey = HKDF(chainKey_0, salt = voiceSessionId, info =
"haychat-voice-v1")` from the speaker's current text sender chain. Building E4b and E5 showed
three problems with it:

1. **Voice would get history.** In a Full history room every chain, `chainKey_0` included, is
   forwarded to later members (E5). A server that records the ciphertext of a call could hand it
   to anyone added later, who could then derive the key and listen to calls from before they
   joined. Text history is the point of Full history; nobody expects it of a call.
2. **Not every holder has `chainKey_0`.** The distribution format carries a `startIndex`, and a
   recipient keeps "the first key it was given" (design 6.3). A listener holding a chain from a
   later index cannot derive a key bound to index 0.
3. **The chain's lifetime is the wrong one.** A chain lasts up to 7 days or 1000 messages and
   starts lazily on a send; a call wants a key per session, rotated on a timer and on every
   member change, and a joiner who never typed in the room would have to distribute a text chain
   only to talk.

A fresh random key in its own envelope fixes all three. It costs one envelope (at most about
6 KB) per participant per rotation, on the reliable control channel, which a call can afford.
Keys exist only in memory, on the server and the clients, so a call leaves nothing behind.

Rejected as well: sealing each speaker's key to the current voice participants only. Every
joiner would then need a re-seal from every speaker (a round trip per speaker), and a speaker
would have to rotate on every leave to keep a departed listener out, although that listener, a
member, may rejoin at any time anyway. Wrapping to every member of the epoch lets the server
hand a joiner the current keys at once, and confines rotation to member changes.

## 3. Voice keys

### 3.1 The key and its envelope

Each participant holds one *voice session* per join: a random 16-byte `voiceSessionId` made when
the join is acknowledged. Within it, each key has a `generation` (u32, from 0, +1 on every
rotation). A key is 32 random bytes from the OS generator.

```
VoiceKeyPlaintext, version 1           (sealed, so padded to 256 bytes like every plaintext)
  offset size field
  0      1    version = 1
  1      8    roomId          i64
  9      8    epoch           i64      the verified log version the key is for
  17     16   voiceSessionId
  33     4    generation      u32
  37     8    createdAtUnix   i64      seconds, the sender's clock
  45     32   voiceKey
```

It is sealed as a `SealedEnvelope` (design 4.1) of a new kind `VoiceKey = 4`, with one wrap per
member of `epoch` in the sender's verified log whose pin matches the log's identity, the sender
excluded, and AAD

```
"haychat-voice-key-v1" ‖ serverIdentityPublicKey ‖ roomId ‖ epoch ‖ senderUserId
                       ‖ voiceSessionId ‖ generation ‖ createdAtUnix
```

The opener checks that the plaintext repeats the AAD's fields. The envelope signature (identity
key over the domain, AAD and envelope bytes) binds the key to its sender. The label is new and
prefix-free against the existing ones (`haychat-room-key-v1`, `haychat-room-v1`, and so on).
`common/e2ee.odin` gains `makeVoiceKeyAAD`, `sealVoiceKey` and `openVoiceKey`, with known-answer
vectors from `dev/tools/e2ee-vectors.py`.

A member without a usable pin (not fetched yet, or with a blocked key) gets no wrap and asks
later (4.2), exactly like a chain distribution.

### 3.2 Wire

```
ClientVoiceKey        { roomId, epoch, voiceSessionId, generation, envelope }
ServerVoiceKey        { roomId, senderId, epoch, voiceSessionId, generation, envelope }
ClientRequestVoiceKey { roomId, senderId }
ServerVoiceKeyRequest { roomId, requesterId }
```

`voiceSessionId` and `envelope` are CBOR byte strings; `envelope` is at most
`SEALED_ENVELOPE_MAX_BYTES`. Decoded payloads own their byte strings and get `*_deinit` helpers.

### 3.3 Server

The router (`server/voice.odin`) handles all four; nothing touches the database.

- **`ClientVoiceKey`** is accepted only from a session that is in `roomId`'s voice (or whose join
  was just acknowledged), with an envelope of kind `VoiceKey` whose structure parses and whose
  signature verifies against the **session's** identity key (as the router does for
  `ClientRoomKeyEnvelope`), whose wraps name no more than `ENCRYPTED_ROOM_MEMBERS_MAX` users,
  and whose `epoch` is the room's current log version. Anything else gets
  `ServerProtocolError` ("Voice key is out of date" for a stale epoch, so the client rekeys);
  the session stays.
- **The current log version** comes with the join's membership check (the database result
  gains `logVersion`) and is updated in the router's voice state whenever the router fans out
  a `ServerRoomLog` append for that room. When it advances, the router drops every stored voice
  key of the room with an older epoch, so no joiner is handed one.
- **Storage.** The router keeps the latest accepted key per voice participant (replacing the
  previous one), and forgets it when the participant leaves voice, is taken over by another
  device, is evicted or disconnects.
- **Fan-out.** An accepted key goes as `ServerVoiceKey` to every other session in the room's
  voice. A session whose join is acknowledged (`ServerVoiceParticipants` with
  `recipientJoined`) gets, right after that list, a `ServerVoiceKey` for every other
  participant's stored key.
- **Requests.** `ClientRequestVoiceKey` from a session in the room's voice is passed to
  `senderId`'s voice session as `ServerVoiceKeyRequest`, at most once per requester and sender
  every 10 seconds; others are dropped silently.
- **Joins.** The refusal of voice in encrypted rooms goes. A join is still refused for a
  non-member and for a text-only room; a client that joins an encrypted room's voice and never
  sends a key is simply unheard.

The server does not check that the wraps name members: clients build them from the verified log,
and a wrap for a non-member gives nothing to anyone the server could not already give its own
keys. It also does not hold frames back until a key arrives: listeners drop what they cannot open.

## 4. Rotation, epochs and freshness

### 4.1 When a speaker makes a new key

A participant makes a new generation, seals it to the members of its current verified epoch and
sends it before any frame under it:

1. when its join is acknowledged (generation 0 of a new `voiceSessionId`);
2. whenever its engine is opened or reopened (a device change), so that a key never meets a
   second sequence counter;
3. when its verified log reaches a new epoch (a member added or removed, access changed). Frames
   of the new epoch wait for the key to be sent, at most one control round trip, and the old key
   is wiped;
4. every `VOICE_KEY_ROTATE_SECONDS` (30 minutes);
5. on a `ServerVoiceKeyRequest` from a member of its current epoch, at most once every 10
   seconds whoever asks. Rotating instead of re-sealing to the requester keeps one path, and
   the new envelope also reaches members whose pins arrived since.

When the server refuses a key as out of date, the client fetches the log (as for "Room key is
out of date" on a text send) and goes to step 3.

A removed member's client may still hold the keys of the old epoch. Speakers stop using them when
they see the removal (step 3), and the server evicts the removed member from voice (E3); the
frames between the two are exposed only if the server keeps relaying to the removed member.

### 4.2 Listener

A listener holds, per speaker, at most two keys: the current one and the previous one (for the
frames still in flight after a rotation). A key is accepted when

- the envelope opens with the sender's **pin** and the listener's own encryption key, and the
  plaintext matches the AAD fields;
- the sender is a member of `epoch` in the listener's verified log, with the identity the log
  names;
- `epoch` is the listener's verified epoch. A key for a later epoch waits (owned, wiped on
  drop) until the log catches up, and the listener fetches the log; a key for an earlier epoch
  is refused, unless it is the sender's current key and the listener reached the new epoch less
  than `VOICE_EPOCH_GRACE_SECONDS` (10 seconds) ago, which covers a speaker who has not seen
  the change yet;
- it is fresh (4.3).

When the listener's own log reaches a new epoch, it keeps each speaker's old-epoch key for
`VOICE_EPOCH_GRACE_SECONDS` and then wipes it. A frame from a speaker it holds no key for (or
whose `keyId` matches neither key) is dropped and counted, and after two seconds without a key
the listener sends `ClientRequestVoiceKey` once and shows "Waiting for <name>'s voice key" on
that participant.

Every failure to open a key envelope is final for that envelope, as for every other envelope
(design 4.1): the listener does not retry it and does not ask again for the same generation.

### 4.3 Freshness and replay

The server could record a call's key envelopes and frames and play them back later as live audio.
A listener refuses a key

- whose `createdAtUnix` is more than `VOICE_KEY_MAX_AGE_SECONDS` (1 hour) older, or more than
  5 minutes newer, than its own clock; speakers rotate every 30 minutes, so a live speaker's key
  is never older than 30 minutes plus the clock skew;
- with the same `voiceSessionId` as the last key it accepted from that sender and a generation
  that is not higher;
- with another `voiceSessionId` and a `createdAtUnix` lower than that of the last key it
  accepted from that sender.

Within a key, the frame sequence is the replay check: the jitter buffer already drops a frame
whose sequence it has played or passed, and the transport's replay window drops a datagram the
server replays per hop. What is left is section 1's residual: a recording under 1 hour old, from
the listener's current epoch, played to a listener who has not seen a newer key from that
speaker in this run.

A user whose clock is off by more than about 30 minutes cannot be heard in encrypted rooms (and
cannot hear speakers whose clocks are right, if theirs is ahead). The voice bar says so when it
refuses a key for its age, and the user guide says to keep the clock synchronised.

## 5. Frames

### 5.1 Layout

In an encrypted room the bytes in the `opus` field of `ClientVoiceFrame` and `ServerVoiceFrame`
are a sealed payload instead of Opus:

```
SealedVoicePayload, version 1
  offset size field
  0      1    version = 1
  1      1    keyId   u8 = generation & 0xFF
  2      m    ciphertext: XChaCha20-Poly1305(voiceKey, nonce, opus, AAD), m = len(opus)
  2+m    16   tag
```

```
nonce = frameSequence (u32 LE) ‖ 20 zero bytes
AAD   = "haychat-voice-frame-v1" ‖ serverIdentityPublicKey ‖ roomId i64 ‖ senderUserId i64
        ‖ epoch i64 ‖ voiceSessionId ‖ generation u32 ‖ frameSequence u32 ‖ flags u8
        ‖ version u8 ‖ keyId u8
```

- The Opus bytes are not padded: section 8's constant bitrate does that job.
- `VOICE_E2EE_OVERHEAD :: 18`, so the encoder's largest packet in an encrypted room is
  `VOICE_OPUS_MAX_BYTES - 18` (494 bytes, far above any HayChat bitrate). The 512-byte wire
  limit does not change.
- `flags` is in the AAD: the server copies it unchanged, and must not be able to mark a frame
  as the end of a spurt.
- `keyId` is the low byte of the generation. Two consecutive generations always differ in it, and
  a listener holds at most two keys per speaker, so it names one of them without ambiguity; the
  AAD binds the full generation.
- `common/voice_wire.odin` (or a new `common/voice_e2ee.odin`) gains `sealVoicePayload` and
  `openVoicePayload`, which work in caller buffers and never allocate, because they run 50 times
  a second per speaker on the voice thread.

### 5.2 Nonces

A voice key is random and used by exactly one engine instance, whose frame sequence strictly
increases (wrapping after 2³² frames, 2.7 years, far beyond the 30-minute rotation). Rotation
step 2 (4.1) makes the engine-reopen case explicit instead of relying on the resumed media clock.
So (key, nonce) never repeats, and the nonce needs no random bytes on the wire. The engine
refuses to seal a frame with a sequence at or behind the last one it sealed under the same key
(a test pins this).

## 6. Relay

`NetworkVoiceRoute` gains `encrypted: bool`, set from the join check's room record, and the relay
keeps it per room. For an encrypted room's frames the relay

- skips `opusPacketIsVoiceFrameDuration` (the TOC byte is ciphertext);
- drops a payload shorter than `VOICE_E2EE_OVERHEAD + 1` or whose first byte is not version 1
  (a new drop reason, `NotSealed`), so a buggy client's plaintext never reaches listeners;
- applies `HAYCHAT_VOICE_MAX_FRAME_BYTES` to the payload length minus `VOICE_E2EE_OVERHEAD`, so
  the setting keeps meaning "Opus bytes" (its minimum of 64 stays usable);
- forwards the payload unchanged inside the resealed `ServerVoiceFrame`.

Its rate limit, mute check and per-hop crypto are unchanged. Unencrypted rooms are relayed exactly
as today.

## 7. Client

### 7.1 Where the keys live

- **UI thread** (`client/voice_e2ee.odin`, new, next to `room_chains.odin`): makes keys, seals
  them with `State_e2eePeerKeyInfo` pins of the verified log's members, opens incoming
  `ServerVoiceKey`s, applies sections 4.2 and 4.3, answers requests, rotates on the triggers of
  4.1, and pushes the results into the engine.
- **Voice engine** (`client/voice_engine.odin`): a key table (own key; per speaker, current and
  previous), set from the UI thread with `VoiceEngine_setSendKey` / `VoiceEngine_setSpeakerKeys`
  under the inbound mutex and copied by the voice thread when it changes, like the other
  controls. The voice thread seals each encoded frame before `onOutbound` and opens each inbound
  frame before the jitter buffer, so a frame that does not open counts as a lost one for PLC and
  FEC. After opening, the engine checks the Opus duration the relay could not (`BadDuration`
  becomes a client-side drop in encrypted rooms). Keys are wiped when replaced, when voice
  leaves, and when the engine is destroyed.
- **Never stored.** Voice keys are not in the key store or `config.json`.
- **Never plaintext.** An engine joined to an encrypted room never sends a frame without a send
  key and never plays a frame that did not open, whatever the server says about the room. The
  room's `encrypted` flag comes from the verified state (`RoomSummary.encrypted` never changes,
  design 6.1), not from per-frame hints.

### 7.2 Joining

The join button in an encrypted room is enabled only when the room's verified log is loaded and
the profile has a valid encryption key; otherwise it shows why ("Setting up encryption…", "This
profile has no valid encryption key", "This room's member list was changed on the server"). The
user is joined as today; the client sends its first key right after the acknowledgement and
starts sending frames once the key is out. Re-join after a reconnect starts a new
`voiceSessionId`.

### 7.3 UI

- The voice bar and the room header's voice area show a lock and "Voice is end-to-end
  encrypted" in encrypted rooms.
- A participant whose key is missing or refused shows "Waiting for <name>'s voice key" (or "Clock
  out of sync" for a key refused for its age).
- Room log events already show member changes; a rotation is not shown.

### 7.4 Harness

- `voice-stats` gains the engine's E2EE counters: frames sealed and opened, and drops by reason
  (`NoKey`, `UnknownKeyId`, `BadTag`, `NotSealed`, `BadDuration`), plus keys sent, accepted and
  refused by reason.
- `voice_status` gains `encrypted` and the generation of the client's send key; a new
  `voice_key` event reports each accepted key (`senderId`, `epoch`, `generation`) and each
  refusal with its reason, so proofs can wait for a rotation.
- A harness command, `voice-key-rotate SECONDS`, shortens the rotation period of 4.1 for this
  process so the live proof can see one; the GUI has no way to change it.

## 8. Length leak and constant bitrate

The encoder runs constrained VBR, so each Opus packet's length follows the speech. Lengths of VBR
voice packets are known to leak phrases and languages to someone who sees only ciphertext
(Wright et al., "Spot me if you can", 2008; "Language identification of encrypted VoIP
traffic", 2007). The server sees every length.

Encrypted rooms therefore encode at **constant bitrate** (`SET_VBR_REQUEST 0`) at the user's
chosen bitrate: every 20 ms packet of a speaker has the same length. Quality at 24 kbit/s CBR is
slightly below constrained VBR, and bandwidth while talking is the same. The gate still sends
nothing in silence, so talk spurts remain visible (section 1). Measure it with
`dev/voice-manual-test.sh` before release, as AGENTS.md asks for any voice constant.

Rejected: padding Opus packets to a bucket size (it hides less than CBR at the same cost, and
needs a length field); sending frames continuously through silence (50 frames a second per
participant to hide who talks, which the server learns from the participant list and timing
anyway).

## 9. Wire and schema changes

- **Protocol 21.** `MessageType` appends `ClientVoiceKey`, `ServerVoiceKey`,
  `ClientRequestVoiceKey`, `ServerVoiceKeyRequest`, each pinned in `common/protocol_test.odin`.
  `EnvelopeKind` appends `VoiceKey = 4`. `ENCRYPTED_ROOM_VOICE_MESSAGE` is removed.
- **No migration.** Voice keys live only in the router's memory and the clients'.
- **No configuration key.** The constants (`VOICE_KEY_ROTATE_SECONDS`, `VOICE_KEY_MAX_AGE_SECONDS`,
  `VOICE_EPOCH_GRACE_SECONDS`, the 10-second request limit) are in `common/`; the harness command
  of 7.4 is documented in `docs/testing-harness.md`.
- **Internal.** `NetworkVoiceRoute.encrypted`; the join check's database result gains
  `logVersion`.

## 10. Decisions

The maintainer took every recommendation on 2026-11-15.

| Question | Decision | Rejected |
| --- | --- | --- |
| **V1. Key source** | A fresh random key per generation in a `VoiceKey` envelope, never stored or forwarded (2). | Design 8's derivation from the text chain's `chainKey_0`: no new envelope, but voice gets Full history and fails for holders without index 0. |
| **V2. Replay freshness** | A clock window: keys older than 1 hour are refused, speakers rotate every 30 minutes (4.3). Costs a dependency on roughly correct clocks. | No clock check: monotonic generations only, accepting that the server can replay any recording from the current epoch to a listener who joins later. |
| **V3. Bitrate in encrypted rooms** | Constant bitrate, so packet lengths do not follow speech (8). | Keep constrained VBR and accept the length leak as metadata. |
| **V4. Packaging** | One package, `e2ee-voice`. | Two: E6a (common primitives, protocol, server) and E6b (client, harness, proof). |

## 11. Test plan

### 11.1 Unit (`odin test common`)

- `VoiceKey` envelope: seal and open round trip; tampering with each AAD field, the plaintext
  fields that repeat it, the kind byte and the signature fails; a wrong pin fails before any
  key material is touched; a recipient without a wrap gets `NotARecipient`.
- `SealedVoicePayload`: round trip into caller buffers with no allocation (a tracking allocator
  sees none); each AAD field (room, sender, epoch, session, generation, sequence, flags,
  version, keyId) changed fails; truncated, version 2 and overhead-only payloads are refused;
  the largest Opus packet (494 bytes) fits and 495 is refused.
- Known-answer vectors for both, regenerated by `dev/tools/e2ee-vectors.py`.
- Wire values of the four new messages and `EnvelopeKind.VoiceKey` pinned.

### 11.2 Server (`odin test server -define:ODIN_TEST_THREADS=1`)

- A join to an encrypted room's voice is accepted; non-members and text-only rooms are still
  refused.
- `ClientVoiceKey` is refused from a session not in that room's voice, with a bad signature, the
  wrong envelope kind, or a stale epoch ("Voice key is out of date"); accepted keys reach the
  other participants and not the sender or non-participants.
- A joiner gets every other participant's current key right after its acknowledgement, and only
  the latest one per participant.
- Keys are dropped on leave, takeover, eviction and disconnect, and keys of an older epoch on a
  log append.
- Requests are relayed to the speaker's session and rate limited.
- Relay: an encrypted route forwards a sealed payload byte for byte, skips the TOC check, drops
  `NotSealed` and short payloads, and applies the frame size limit without the overhead; an
  unencrypted route behaves exactly as before (the existing relay tests stay green unchanged).

### 11.3 Client (`odin test client`)

- The engine seals and opens with its key table; a frame with no key, an unknown `keyId` or a
  bad tag is dropped and counted, and counts as a loss for PLC; a sequence at or behind the last
  sealed one is refused; keys are wiped on stop.
- A joined encrypted room never sends a frame before its first key is sent, and never plays a
  frame that did not open.
- Rotation on each trigger of 4.1, including a new generation after `State_voiceRestartEngine`.
- Listener rules of 4.2 and 4.3: wrong pin, sender not in the epoch, later epoch held until the
  log catches up, earlier epoch refused except within the grace, old keys wiped after the grace,
  stale `createdAtUnix`, future `createdAtUnix`, non-increasing generation, older session.
- The encoder is CBR in encrypted rooms and constrained VBR elsewhere.

### 11.4 Live proof

`dev/voice-proof.sh` gains an encrypted step (in `dev/live-proof.sh --voice` and `--all`), or
`dev/e2ee-proof.sh` gains a voice step, whichever reuses more of the existing setup:

1. Alice (admin) creates an encrypted Member invite room and adds Bob and Carol; all three join
   voice. Each sees `voice_status.encrypted` and a `voice_key` from both others.
2. Alice sends a 440 Hz tone; Bob and Carol record it and `dev/tools/voice-check` finds the tone.
   The engine counters show frames opened and no drops beyond the faults injected.
3. Alice removes Carol. Carol is evicted from voice; Alice and Bob each report a `voice_key` at
   the new epoch; the tone still reaches Bob after the rotation.
4. After `voice-key-rotate 5` on Alice, Bob sees at least one timed rotation without losing
   the tone.
5. The unencrypted voice steps that already exist run unchanged.

Manual: `dev/voice-manual-test.sh` measures CBR tone and speech quality and mouth-to-ear delay in
an encrypted room against the unencrypted baseline.

## 12. Work breakdown

One package, `e2ee-voice` (E6), branched from `main` after 33275a6, taking the protocol number
free at merge time (21 today):

1. `common/`: `VoiceKey` envelope (`sealVoiceKey`, `openVoiceKey`, `makeVoiceKeyAAD`),
   `SealedVoicePayload` (`sealVoicePayload`, `openVoicePayload`), constants, the four messages,
   tests and vectors.
2. `server/`: the router's voice key state, checks, fan-out and requests; `logVersion` in the
   join check and its update on log appends; `NetworkVoiceRoute.encrypted` and the relay's
   encrypted path; remove the encrypted-room refusal.
3. `client/`: `voice_e2ee.odin`, the engine's key table and seal/open, CBR in encrypted rooms,
   join gating and UI, harness counters, events and `voice-key-rotate`.
4. Live proof, then documentation: `docs/protocol.md`, `docs/user-guide.md` (encrypted voice,
   clocks), `docs/testing-harness.md`, the voice and E2EE parts of `AGENTS.md`, `client/AGENTS.md`
   and `server/AGENTS.md`, a pointer from design section 8 to this note, and the round plan's
   follow-up list.

The lead's crypto review checks the AAD binding (every field of 5.1 and 3.1), the nonce
invariant of 5.2, that openers use pins and never the server's bundle, that no key reaches disk,
and that an encrypted room can never send or play plaintext.

## 13. Risks

- **Clock dependency** (V2): users with badly wrong clocks go silent in encrypted rooms. The
  refusal reason is shown, and the window is wide.
- **Burst at join**: a joiner in a full room receives up to 24 envelopes of about 6 KB on the
  reliable channel, about 150 KB, before it hears everyone. Encrypted rooms hold 100 members at
  most; the default voice limit is 25 participants.
- **Seconds of audio at a removal** (4.1) are readable by the removed member if the server keeps
  relaying to them.
- **Member impersonation** with the server's help (section 1), as in SFrame.
- **CBR quality** at the default bitrate must be measured before release (8).
- **The hand-built envelope** gains a fourth kind; the outside review the round plan asks for
  before a release should include it.

## Appendix: files checked

`docs/plan/e2ee-design.md` (sections 4.1, 6.3-6.6, 8), `docs/plan/voice-rooms-design.md`,
`docs/plan/2026-11-14-e2ee-implementation.md`, `common/voice_wire.odin`, `common/e2ee.odin`,
`server/voice.odin`, `server/voice_relay.odin`, `server/ipc.odin`, `server/config.odin`,
`client/voice_engine.odin`, `client/voice_network.odin`, `client/room_chains.odin`,
`client/opus/opus.odin`.
