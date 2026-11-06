# Headless Client Harness

`client --headless` runs the HayChat client without a window, so an AI agent or a shell
script can act as a user. It is the normal client binary: it uses the same `State`, actions,
encrypted transport, and network worker as the GUI, and only skips SDL. Commands go in on
stdin, one per line; results and events come out on stdout, one JSON object per line.
Diagnostics (config notes, connection errors) go to stderr, so stdout is always a clean
stream of JSON lines.

The code lives in `client/headless.odin`; its unit tests are in `client/headless_test.odin`.
To drive the real window instead (clicks, typing, screenshots), see
[GUI Automation](#gui-automation).

## Running It

```sh
odin build client -out:haychat-client
./haychat-client --headless --name alice-1 --server 127.0.0.1:12345 --config-dir ./profiles/alice
```

| Option | Meaning |
| --- | --- |
| `--name NAME` | Display name, 3 to 32 bytes (UTF-8). Saved to the profile. Required for a new profile. |
| `--server HOST:PORT` | The profile's only server. Saved to the profile. Required for a new profile: there is no built-in default server. |
| `--config-dir DIR` | Config root for this profile, like `XDG_CONFIG_HOME` (`APPDATA` on Windows): the profile is `DIR/haychat/config.json`. Without it the harness uses your real client config. |
| `--connect-timeout MS` | How long startup waits for the first connection, 1 to 600000 ms (default 15000). |

Options also accept the `--name=NAME` form.

A profile directory is a stable identity. Its Ed25519 identity key is created on first use, and
the server's account belongs to that key. Reuse the directory to come back as the same user; use
a new directory and a new name for a new user. Reusing a directory with a different `--name`
renames that user's account (same user ID), and other connected clients get a `presence`
event with the new name. Two clients with the same name and different directories cannot both
log in (`user identity is unavailable`), and neither can a rename to a name another account
holds. Give every
scripted run unique names, for example by appending a timestamp.

`--server` makes the profile hold exactly that one server. An existing entry for the same
address keeps its pinned server key; a different address replaces the entry and its pin.

A profile with neither a saved server nor `--server` prints `connect_failed` with
`"message":"no server is configured"` and exits with code 2.

At startup the harness starts the network worker, which connects in the background exactly as
the GUI does, and waits for the selected server to sign in. Every attempt prints a
`connecting` event. An attempt that fails for a reason that can go away (the server is down or
unreachable) prints `connect_failed` with `"retryable":true` and is retried after 1, 2, 4, …
seconds, capped at 30 s. Startup ends with:

- `connected`: commands are read from then on.
- `connect_failed` with `"retryable":false`: a failure retrying cannot fix (the name is taken,
  the server key changed, a protocol version mismatch, an invalid name or identity key).
  `message` explains it in the GUI's words; exit code 2.
- `connect_failed` with `"failure":"Timeout"` when `--connect-timeout` passes first; exit
  code 2.

After that the worker keeps the session alive while the harness waits for commands. If the
session drops (for example the server restarts) the harness prints `disconnected`, and the
worker reconnects by itself, printing `connecting` and then `connected` (or `connect_failed`)
again, so an agent can `wait connected` to see it come back.

### Exit Codes

| Code | When |
| --- | --- |
| 0 | `quit`, or EOF on stdin |
| 1 | Bad arguments, or the config and identity key could not be loaded or created |
| 2 | No server is configured, connecting failed for a reason retrying cannot fix, or `--connect-timeout` passed (a `connect_failed` event says why) |

Closing stdin counts as `quit`. A script that wants a client to stay online between commands
must keep its stdin open (a named pipe held open on a file descriptor, or a coprocess).

## Commands

Blank lines and lines starting with `#` are ignored. Commands run one at a time in the order
received; every command prints exactly one result line, `{"ok":true,"cmd":"NAME",...}` or
`{"ok":false,"cmd":"NAME","error":"..."}`. Events that arrive while a command runs (for
example during `wait` or `sleep`) are printed as they arrive, before the result.

| Command | Result |
| --- | --- |
| `status` | `connection` (`connecting`, `connected`, `retrying`, `failed`, or `none` without a server), `connected` (true when signed in), `retryInMS` (time until the next attempt while `retrying`), `serverID`, `server` (`host:port`), `userID`, `nickname`, `isAdmin` (the server's admin flag for this session, see `connected`), `selectedRoomID`, `lastError` (the last raw failure or disconnect reason) |
| `reconnect` | Connects the selected server again now: drops any session in progress, skips the remaining retry delay, and also restarts after a failure that stopped retrying. The outcome arrives as `connecting` and then `connected` or `connect_failed` events. |
| `rooms` | The joined rooms from the cache: `loaded`, `loading`, `rooms` (`[{"id","name","description","lastReadMessageId","unreadCount"}]`, see [Read State](#read-state)). When the list is not loaded yet it is requested and arrives as a `room_list` event. |
| `history ROOM_ID [BEFORE_MESSAGE_ID]` | Requests one page of history (newest first page with no cursor, older pages with the oldest loaded message ID). The page arrives as a `room_history` event. |
| `send ROOM_ID TEXT...` | Sends the rest of the line to the room, through the same action as the GUI composer. `ok` means the transport accepted it; the message itself comes back as a `room_chat` event, and a rejection as a `protocol_error` event. |
| `users` | The server's accounts from the cache, yourself included: `loaded`, `loading`, `users` (`[{"id","nickname","isOnline","lastReadMessageId","unreadCount"}]`, ordered by nickname; the last two are the read state of your conversation with that account, 0 without one). The list is fetched when the client connects and kept current by `presence` events; when it is not loaded yet it is requested and arrives as a `user_list` event. |
| `conversations` | Your direct conversations from the cache, most recent first: `loaded`, `loading`, `conversations` (same shape as the `conversations` event). Fetched at connect; a live `direct_message` moves its conversation to the top. Requested when not loaded yet. |
| `dm USER_ID TEXT...` | Sends the rest of the line as a direct message to that account, through the same action as the GUI's direct-message composer. `ok` means the transport accepted it; the stored message comes back as a `direct_message` event to every session of both users (the sender's included), and a rejection as a `protocol_error` event (`Unknown direct message recipient`, `Cannot send a direct message to yourself`, `Invalid direct message`). |
| `dm-history USER_ID [BEFORE_MESSAGE_ID]` | Requests one page (up to 50 messages, both directions) of the conversation with that account: the newest page with no cursor, older pages with the oldest loaded message ID. It arrives as a `direct_history` event. |
| `room-create NAME [DESCRIPTION...]` | Admins: asks the server for a new room named NAME (one word here; a leading `#` is dropped) with the rest of the line as its description. The result echoes `serverID`, `roomID` (0), `name`, and `description` once the request is out. The new room arrives as a `room_created` event (to you only; it also becomes the selected room), and every connected client, yours included, gets `room_membership` with `joined` true and then a fresh `room_list`. The same checks as the GUI form run first: an empty or over-long name, an over-long description, or the name of a listed room is an `ok:false` result. A non-admin gets `protocol_error "Admin permission required"`. |
| `room-edit ROOM_ID NAME [DESCRIPTION...]` | Admins: renames the room and replaces its description (an empty one without DESCRIPTION). Every member, you included, gets `room_edited`. |
| `room-delete ROOM_ID` | Admins: deletes the room and its history. Every member, you included, gets `room_deleted`; a client whose selected room it was falls back to `#general` (room 1) while it exists, otherwise to the first room. Room 1 can be deleted too; the server recreates `#general` on its next start only when no rooms are left. |
| `read room\|dm ID [MESSAGE_ID]` | Marks room ID, or the direct conversation with user ID, read up to MESSAGE_ID; without it, up to the newest message loaded for that conversation (an `ok:false` result when nothing is loaded: fetch it with `history` or `dm-history` first). `ok` means the request went out (`serverID`, `kind`, `conversationID`, `messageID`). When the marker moved, every session of your account, this one included, gets a `read_marker` event; a read that moves nothing (the marker is already there) gets no answer. Not a member, or no such user, is a `protocol_error` (`Not a room member`, `Unknown user`). |
| `voice-join ROOM_ID` | Joins the room's voice on the selected server (leaving any other first). `ok` (`serverID`, `roomID`, `status` `joining`) means the request went out; the join completes with `voice_participants` carrying `"recipientJoined":true`, then `voice_status` `joined` once the engine runs. A refusal arrives as `voice_join_rejected`. See [Voice](#voice). |
| `voice-leave` | Leaves voice and stops the engine (`serverID` and `roomID` it left, 0 when it was not in voice). A file sink is closed, complete, at this point. |
| `voice-source SPEC` | What the next join sends: `tone:HZ[:AMP]` (a sine, amplitude 0 to 1, default 0.5), `file:PATH` (raw F32LE mono 48 kHz, silent after its end), `silence` (the default), or `device[:NAME]` (an SDL recording device; the only way SDL audio is initialised). |
| `voice-sink SPEC` | Where the next join plays: `file:PATH` (every speaker mixed into raw F32LE mono 48 kHz, silence written while nobody speaks), `null` (the default: decode and discard), or `device[:NAME]` (an SDL playback device). |
| `voice-gate vad [THRESHOLD_DB]\|ptt\|open` | Voice activity (threshold in dBFS, -100 to below 0, default -45), push-to-talk, or `open`: push-to-talk with the key held, so every frame is sent. Applies at once and to the next join. |
| `voice-mute on\|off`, `voice-deafen on\|off` | Mute closes the gate at once and deafen stops playback at once; both are then sent to the server (which shows them in `voice_participants`) and carried by the next join. |
| `voice-ptt down\|up` | Presses or releases push-to-talk (local only). |
| `voice-stats` | The engine's counters and the transport's voice counters; see [Voice](#voice). |
| `voice-flush` | With a file sink: replies once every frame played so far is in the file (`path`, `bytes`, `seconds`, `running`), so a script can analyse it without leaving. Without a running engine it reports the file as the engine closed it. |
| `wait EVENT_KIND [TIMEOUT_MS]` | Waits for an event of that kind (default 5000 ms, at most 600000). `ok:false` on timeout. |
| `sleep MS` | Keeps servicing the connection for `MS` milliseconds, printing events. |
| `help` | Lists the commands and event kinds. |
| `quit` | Prints its result, disconnects, and exits with code 0. |

`wait` counts events, so it never misses one that arrived before it was sent: every printed
event adds one to its kind's count, and each successful `wait` takes one away. `wait room_list`
right after connecting therefore returns at once if the room list already arrived. To wait for
a specific message, follow `wait room_chat` with a check of the printed event.

The commands are a table in `client/headless.odin` (`HEADLESS_COMMANDS`): name, argument
counts, usage, and handler. A new command is one row and one handler procedure.

## Events

Every runtime event the client applies is printed first. Keys always come in the order shown.

| Event | Example |
| --- | --- |
| `connecting` | `{"event":"connecting","serverID":1,"attempt":1}` (`attempt` counts from 1 since the last `connected` or `disconnected`) |
| `connected` | `{"event":"connected","serverID":1,"userID":3,"nickname":"alice-1","isAdmin":false}` (`isAdmin`: the account holds the server's `admin` role) |
| `connect_failed` | `{"event":"connect_failed","serverID":1,"message":"timed out connecting to the server","detail":"timed out connecting to the server","failure":"Unreachable","retryable":true,"retryInMS":2000}` |
| `room_list` | `{"event":"room_list","serverID":1,"rooms":[{"id":1,"name":"general","description":"...","lastReadMessageId":12,"unreadCount":0}]}` |
| `room_chat` | `{"event":"room_chat","serverID":1,"roomID":1,"messageID":12,"senderID":3,"senderNickname":"alice","timestamp":"...","content":"hi"}` |
| `room_history` | `{"event":"room_history","serverID":1,"roomID":1,"hasOlder":false,"messages":[{"id":12,"senderID":3,"senderNickname":"alice","timestamp":"...","content":"hi"}]}` |
| `room_membership` | `{"event":"room_membership","serverID":1,"roomID":2,"joined":true}` |
| `room_edited` | `{"event":"room_edited","serverID":1,"roomID":2,"name":"...","description":"..."}` |
| `room_deleted` | `{"event":"room_deleted","serverID":1,"roomID":2}` |
| `room_created` | `{"event":"room_created","serverID":1,"roomID":2,"name":"random","description":"..."}` (the answer to your own `room-create`) |
| `protocol_error` | `{"event":"protocol_error","serverID":1,"message":"..."}` |
| `disconnected` | `{"event":"disconnected","serverID":1,"message":"connection lost","retryInMS":900}` |
| `direct_message` | `{"event":"direct_message","serverID":1,"id":7,"senderID":3,"senderNickname":"alice","recipientID":4,"recipientNickname":"bob","timestamp":"...","content":"hi"}` |
| `direct_history` | `{"event":"direct_history","serverID":1,"peerUserID":4,"hasOlder":false,"messages":[{"id":7,"senderID":3,"senderNickname":"alice","recipientID":4,"recipientNickname":"bob","timestamp":"...","content":"hi"}]}` |
| `user_list` | `{"event":"user_list","serverID":1,"users":[{"id":3,"nickname":"alice","isOnline":true}]}` |
| `conversations` | `{"event":"conversations","serverID":1,"conversations":[{"peerUserID":4,"peerNickname":"bob","lastMessageID":7,"lastSenderID":3,"lastTimestamp":"...","lastContent":"hi","lastReadMessageId":0,"unreadCount":0}]}` |
| `presence` | `{"event":"presence","serverID":1,"userID":4,"nickname":"bob","isOnline":true}` |
| `read_marker` | `{"event":"read_marker","serverID":1,"kind":"room","conversationID":1,"lastReadMessageId":12,"unreadCount":0}` (`kind` is `room` or `dm`; for `dm`, `conversationID` is the peer's user ID) |
| `voice_participants` | `{"event":"voice_participants","serverID":1,"roomID":1,"recipientJoined":true,"participants":[{"userID":3,"nickname":"alice","muted":false,"deafened":false}]}` (a room's full voice participant set; `"participants":[]` when the last one left) |
| `voice_join_rejected` | `{"event":"voice_join_rejected","serverID":1,"roomID":1,"reason":"voice room is full"}` |
| `voice_left` | `{"event":"voice_left","serverID":1,"roomID":1,"reason":"the room was deleted"}` (the server removed this session from that room's voice) |
| `voice_status` | `{"event":"voice_status","serverID":1,"roomID":1,"status":"joined","wantRoomID":1,"error":""}` (the client's voice state changed: `idle`, `joining`, `joined`, or `unavailable`; printed by the harness, not the server) |
| `voice_speaking` | `{"event":"voice_speaking","serverID":1,"roomID":1,"userID":3,"speaking":true,"self":false}` (a speaker started or stopped being heard; `self` is this client's own sending; printed by the harness) |

In `connect_failed`, `message` is the explanation the GUI shows, `detail` the raw reason from
the transport or server, and `failure` its kind: `Unreachable` or `Other` (both retried),
`NameUnavailable`, `ServerKeyChanged`, `ProtocolMismatch`, `InvalidName`, `InvalidIdentity`, or
the harness's own `NoServer` and `Timeout`. `retryable` is true when the worker will try again
in `retryInMS`; when it is false nothing retries until `reconnect` (or, at startup, the harness
exits with code 2).

After `disconnected` the worker reconnects with the same backoff; `retryInMS` is the delay
before its first attempt.

Every `connected` is followed by `room_list`, `user_list`, and `conversations` events, because
the client fetches all three for a new session. A `direct_message` belongs to the conversation
with `recipientID` when `senderID` is your own `userID` (from `connected`), and with `senderID`
otherwise. `presence` arrives when another account's first session signs in (`isOnline` true)
or its last one ends (false); other sessions of an account that is already online send none.
A login that renames an account also sends `presence` with the new `nickname`, even when that
account was already online; the client updates the name in `users` and `conversations`.
Direct messages belong to one server: user IDs from different servers are unrelated.

`isAdmin` in `connected` and `status` is what the server said when this session signed in
(protocol 8). An account made admin while connected (for example with
`deploy/sql/make-admin.sql`) learns it on its next connection: send `reconnect` and wait for
`connected`. The server checks the role again for every room request, so a stale `true` only
earns a `protocol_error "Admin permission required"`.

## Voice

A harness client can join a room's voice, send a tone or a file, record what it hears into a
file, and report the engine's counters, so two scripted clients can prove voice end to end
without an audio device. `dev/voice-proof.sh` (below) is a complete example.

### Sources, Sinks and Files

`voice-source`, `voice-sink` and `voice-gate` change the engine template, the config every
**new** engine starts from: they take effect at the next `voice-join`. A running engine keeps
the source and sink it opened with (the result says `"pendingRejoin":true`), so set them
before joining, or `voice-leave` and `voice-join` again. The gate mode, mute, deafen and
push-to-talk also reach a running engine at once.

A harness client starts with `silence`, `null` and voice activity, so voice never opens an
audio device, and SDL audio is never initialised, unless a script asks for `device`. Under
`SDL_AUDIO_DRIVER=disk`, `device` reads `SDL_AUDIO_DISK_INPUT_FILE` and writes
`SDL_AUDIO_DISK_OUTPUT_FILE` instead of real hardware.

Every file is **raw F32LE samples at 48 kHz, mono**, with no header: the file source, the
file sink, and `dev/tools/voice-check`. The one exception is SDL's disk driver output for a
`device` sink, which has the playback device's format, F32LE **stereo** 48 kHz
(`voice-check --channels 2`). A file sink starts when the engine starts (at the join) and
writes 20 ms of silence for every frame nobody speaks, so the file's time base is the join.

### Voice Events

- `voice_participants` arrives for every room of the account whenever its voice participant set
  or a participant's mute or deafen changes, and after every `room_list` for each room with
  anyone in voice. It doubles as the join acknowledgement: a join is complete when a list for
  that room arrives with `"recipientJoined":true`, which the server sets per session (protocol
  12). Naming your `userID` is not enough, because a list also names you for your other
  devices. A second device of the same account is a second entry with the
  same `userID`.
- `voice_status` is the harness's view of the client's voice state, printed whenever it
  changes: `joining` after `voice-join` (or a re-join after a reconnect), `joined` once the
  server acknowledged this session and the engine runs, `idle` after a leave, a rejection, a
  removal or a lost connection (`wantRoomID` is the room a reconnect joins again, 0 when none),
  and `unavailable` when the engine could not start; `error` then says why (no libopus, a
  device or file that cannot be opened).
- `voice_speaking` is printed on each edge of a speaker being heard. For another participant
  (`"self":false`, `userID` is the sender) it follows the engine's talk spurt for that speaker:
  it starts with the first frame and ends on the sender's end-of-spurt flag, or 200 ms after
  its frames stop (a leave or a mute). For this client (`"self":true`) it is whether the gate
  is sending. Both already have their own hysteresis (the jitter buffer's spurt, the gate's
  attack and hangover), so the edges are stable enough to `wait` for; when the engine stops,
  every speaker still speaking gets a `false` edge.
- `voice_join_rejected` answers a join the server refused: `not a room member`, `voice room is
  full`, `voice is disabled`, `invalid room`, or `voice is unavailable, try again`.
- `voice_left` means the server took this session out of a room's voice: `removed from the
  room`, `the room was deleted` (it comes before `room_deleted`), or `joined another voice room`.
- Voice does not survive a reconnect. The client joins the same room again after `connected`
  (until it leaves, or a rejection or `voice_left` ends voice).
- Voice frames are never events: they go from the network thread straight to the voice engine.

### Voice Stats

`voice-stats` reports the flat fields scripts need first, then every counter:

```json
{"ok":true,"cmd":"voice-stats","status":"joined","serverID":1,"roomID":1,"running":true,
 "joinedMS":4104,"sent":0,"received":211,"lost":0,"fec":0,"plc":0,"late":0,"jitterMS":1.18,
 "depth":3,"maxGapRun":0,"playoutDelayMS":60.4,"playoutDelayMaxMS":66.1,"injectedLoss":0,
 "inputLevelDB":-100.0,"transmitting":false,"frameSequence":233,
 "engine":{"framesCaptured":233,"framesSent":0,...},"jitter":{"received":211,...},
 "speakers":[{"userID":3,"speaking":true,"levelDB":-9.0,"bufferedFrames":3,"targetDepth":3,
 "jitterMS":1.18}],
 "network":{"datagramsReceived":211,"framesDelivered":211,"receiveDropped":{"Malformed":0,...},
 "framesSent":0,"sendDropped":{"NotJoined":0,...}}}
```

(Wrapped here; the harness prints one line.)

| Field | Meaning |
| --- | --- |
| `status`, `serverID`, `roomID` | As in `voice_status` |
| `running` | Whether an engine runs (only while joined) |
| `joinedMS` | Time since the join completed (`voice_status` `joined`); 0 when not joined. At 20 ms a frame, an open gate sends `joinedMS / 20` frames |
| `sent` | Frames this client encoded and handed to the network |
| `received` | Frames accepted into the jitter buffers (every speaker, expired ones included) |
| `lost`, `fec`, `plc` | Frames missing at playout (`fec + plc + silent`), those rebuilt from the next frame's redundancy, and those concealed |
| `late` | Frames that arrived after their playout time |
| `jitterMS`, `depth` | The largest interarrival jitter estimate and jitter-buffer target depth (frames) over the current speakers |
| `maxGapRun` | The longest run of frames inside a talk spurt that were heard as neither decoded nor rebuilt by FEC (concealed, or silent after the PLC limit; pre-roll does not count). A maximum over every speaker, not a sum |
| `playoutDelayMS`, `playoutDelayMaxMS` | The mean and largest time a received frame waited between arriving and being decoded for playout: the jitter buffer's share of the latency. A device sink adds SDL's stream queue (up to 40 ms) on top |
| `injectedLoss` | Frames the test-only fault hook dropped ([Loss and Jitter Injection](#loss-and-jitter-injection)); always 0 in a normal build |
| `inputLevelDB`, `transmitting`, `frameSequence` | The last captured frame's level, whether the gate sent it, and the capture sequence |
| `engine` | `VoiceEngineStats` (`client/voice_engine.odin`): capture, gate, encode, inbound, decode and sink counters |
| `jitter` | `JitterStats` (`client/voice_jitter.odin`) summed over every speaker |
| `speakers` | Each current remote speaker: `userID`, `speaking`, `levelDB`, `bufferedFrames`, `targetDepth`, `jitterMS` |
| `network` | The transport's `ClientVoiceNetworkStats` for the voice server, read under the network worker's lock: datagrams received and delivered, frames sent, and every drop by reason |

A speaker's frames stop without an end-of-spurt flag when it leaves, so the listener conceals
a few (`plc`, then `silent`) before its spurt times out. Take stats while the speaker still
talks when counting losses.

### Voice Check and the Live Proof

`dev/tools/voice-check` is a small Odin program that checks a recording for a tone with the
same Goertzel analysis as the client's voice tests (the `client/toneanalysis` package):

```sh
odin run dev/tools/voice-check -- b.f32 --freq 440 --tolerance 5 --min-seconds 3
odin run dev/tools/voice-check -- --write-tone mic.f32 --freq 440 --seconds 10   # a test input
```

It finds the longest stretch of 20 ms blocks within 20 dB of the expected level (from
`--amplitude`, default 0.5), trims 100 ms from each end, and checks it in half-second windows:
every window's dominant frequency within `--tolerance` Hz of `--freq` and its SNR (the target
bin over the median bin) at least `--min-snr` dB (default 20); the stretch's RMS level within
`--level-tolerance` dB (default 6) of the expected level; and the stretch at least
`--min-seconds` long. It prints the measured frequency (median and worst window), level and
SNR either way, and exits 0 on a pass, 1 on a failure and 2 on a usage or file error.
`--channels N` reads interleaved files (the first channel is checked) and `--rate HZ` another
sample rate. `--freq` must lie inside the analyser's scan range, 50 to 4050 Hz; anything else
is a usage error (exit 2), since the check could only fail. `--write-tone` takes any frequency
below half the rate.

`./dev.sh live --voice` runs `dev/voice-proof.sh` against a throwaway server (`--all`, and so
`./dev.sh ci` and Forgejo CI, run it too):

1. File path: B sets `voice-sink file:...` and joins room 1; A sets `voice-source
   tone:440:0.5` and `voice-gate open` and joins. Each waits for its `voice_participants` with
   `recipientJoined` and its `voice_status` `joined`; B must list A and print A's
   `voice_speaking` `true`. After `HAYCHAT_VOICE_PROOF_SECONDS` (default 4) both report
   `voice-stats` and A leaves; B must print A's `voice_speaking` `false` and a list with only
   itself, then `voice-flush`. `voice-check` must pass on B's file with at least 3 s of tone,
   A must have sent at least 95 % of `joinedMS / 20` frames, B must have received at least
   95 % of what A sent, and FEC plus PLC must stay under 2 % of what B received.
2. SDL devices: the same with C on `voice-source device` and D on `voice-sink device`, both
   under `SDL_AUDIO_DRIVER=disk`. C's input file is a tone from `voice-check --write-tone`;
   D's disk output (stereo) must pass `voice-check --channels 2`, and D must receive 95 % of
   what C sent with FEC plus PLC under 2 %. The disk driver paces capture by its own clock, so
   C's frame count is not checked against time.
3. Faults: the file path again, E speaking for `HAYCHAT_VOICE_PROOF_FAULT_SECONDS` (default 8)
   to F, a client built with `-define:HAYCHAT_TEST_FAULTS=true` and started with
   `HAYCHAT_TEST_VOICE_LOSS=0.05`, `HAYCHAT_TEST_VOICE_JITTER_MS=20` and
   `HAYCHAT_TEST_VOICE_SEED=1`. The pass criteria are those of design 6.5: `voice-check` passes
   on F's file with at least 7 s of tone; FEC plus PLC equals the frames lost (`injectedLoss`
   plus `late`) within 3 frames plus 10 % of `injectedLoss` (the stats are read while E still
   talks, so the last drop may not have been played yet, and a dropped first frame of the
   spurt is pre-roll rather than a repair); `maxGapRun` is at most 2; and F received at least
   95 % of what E sent and the hook did not drop. The script also checks that the normal
   client binary does not contain the hook. `HAYCHAT_VOICE_PROOF_FAULTS=0` skips the stage.

It needs libopus (in the dev image and CI) and nothing else: no audio server, no device, no
display. Each stage prints its counters, including the jitter buffer's playout delay.

### Loss and Jitter Injection

Rootless CI has no `tc netem`, so a test build of the client can impair its own voice receive
path (design 6.5). Build it with `-define:HAYCHAT_TEST_FAULTS=true`; then, as frames leave the
engine's inbound queue on the voice thread:

| Variable | Effect |
| --- | --- |
| `HAYCHAT_TEST_VOICE_LOSS` | Fraction of received frames dropped, 0 to 1 (e.g. `0.05`) |
| `HAYCHAT_TEST_VOICE_JITTER_MS` | Each kept frame is held for a uniformly random 0 to N ms (at most 500), so frames also arrive out of order |
| `HAYCHAT_TEST_VOICE_SEED` | Seed of the splitmix64 generator (default 1). One sender gives the same loss pattern on every run |

The network counters still count every frame as delivered; the drops and delays are counted
in `voice-stats` (`injectedLoss`, and `engine.faultDropped` and `engine.faultDelayed`). A
normal build compiles none of it and ignores the variables. Across five runs of the faults
stage at seed 1 the counts were identical (23 dropped, FEC 22, PLC 1, longest gap 1 frame),
and seeds 2 to 5 passed with 19 to 22 drops and gaps of at most 1.

### Latency

The in-process live voice test (`testClientVoiceLiveToneReachesSecondClientThroughServer`,
run by `dev/live-proof.sh --all`) measures latency without a protocol change: both clients run
in one process, and `VoiceEngineConfig.onFrameTiming` reports each frame A encodes and each
frame B decodes on the shared monotonic clock, matched by `frameSequence`. The span runs from
A having a whole 20 ms frame to B writing it to its file sink: encoding, sealing, the server
relay, ENet on loopback, the inbound queue and the jitter buffer. Mouth-to-ear adds 20 ms of
framing and the audio devices' buffers. The test logs p50, p95 and the maximum and fails if
p95 reaches 300 ms; on loopback it measures about 65 ms at p50 and 69 ms at p95 (target 150 ms).

## Read State

The server keeps a read marker (the newest message ID read) per account and room and per
account and direct conversation (protocol 11). `rooms`, `room_list`, `conversations`, and
`users` carry each conversation's `lastReadMessageId` (0 when never marked) and
`unreadCount`: in a room, messages from others after the marker, or without a marker, those
that arrived after you joined; in a conversation, the peer's messages after the marker, or all
of them without one. Counts stop at 100. Between lists, the harness counts live messages the
way the GUI does: a `room_chat` or `direct_message` from someone else, newer than the marker,
adds one; your own never do. A `read_marker` event replaces the marker and the count.

**The harness never marks anything read by itself.** The GUI marks the conversation that is
selected while its window has input focus; the harness has no window, so nothing is ever
"viewed" and every message from someone else counts until an agent sends `read`. That keeps
counts deterministic for scripts: `send` selects its room, but nothing clears a badge behind
the agent's back.

## Example: Two Agents Chatting

Each agent runs its own client with its own profile. Alice's side (`>` is stdin, `<` stdout):

```text
< {"event":"connecting","serverID":1,"attempt":1}
< {"event":"connected","serverID":1,"userID":3,"nickname":"alice-1","isAdmin":false}
< {"event":"room_list","serverID":1,"rooms":[{"id":1,"name":"general","description":"..."}]}
> wait room_list
< {"ok":true,"cmd":"wait","event":"room_list","waitedMS":0}
> send 1 hello bob
< {"ok":true,"cmd":"send","serverID":1,"roomID":1}
< {"event":"room_chat","serverID":1,"roomID":1,"messageID":12,"senderID":3,"senderNickname":"alice-1","timestamp":"...","content":"hello bob"}
> wait room_chat
< {"ok":true,"cmd":"wait","event":"room_chat","waitedMS":0}
> wait room_chat 30000
< {"event":"room_chat","serverID":1,"roomID":1,"messageID":13,"senderID":4,"senderNickname":"bob-1","timestamp":"...","content":"hi alice"}
< {"ok":true,"cmd":"wait","event":"room_chat","waitedMS":2140}
> quit
< {"ok":true,"cmd":"quit"}
```

Alice's own message comes back as a `room_chat` event too, and `wait` counts every event that
has been printed, so her first `wait room_chat` is satisfied at once by that echo. The second
`wait` is the one that blocks until Bob answers; check `senderID` against the `userID` from
`connected` (or `senderNickname`) to tell the two apart. Bob runs the same with
`--name bob-1 --config-dir ./profiles/bob`, waits for `room_chat`, and replies with
`send 1 hi alice`.

## Example: Two Agents Exchanging a Direct Message

Alice is online first, so she hears Bob come online. She finds his user ID with `users` and
messages him:

```text
< {"event":"presence","serverID":1,"userID":4,"nickname":"bob-1","isOnline":true}
> users
< {"ok":true,"cmd":"users","serverID":1,"loaded":true,"loading":false,"users":[{"id":3,"nickname":"alice-1","isOnline":true},{"id":4,"nickname":"bob-1","isOnline":true}]}
> dm 4 hello bob
< {"ok":true,"cmd":"dm","serverID":1,"peerUserID":4}
< {"event":"direct_message","serverID":1,"id":7,"senderID":3,"senderNickname":"alice-1","recipientID":4,"recipientNickname":"bob-1","timestamp":"...","content":"hello bob"}
```

The `direct_message` Alice sees is the server's echo of her own message. Bob's side:

```text
> wait direct_message 30000
< {"event":"direct_message","serverID":1,"id":7,"senderID":3,"senderNickname":"alice-1","recipientID":4,"recipientNickname":"bob-1","timestamp":"...","content":"hello bob"}
< {"ok":true,"cmd":"wait","event":"direct_message","waitedMS":1730}
> dm-history 3
< {"ok":true,"cmd":"dm-history","serverID":1,"peerUserID":3,"beforeMessageID":0}
< {"event":"direct_history","serverID":1,"peerUserID":3,"hasOlder":false,"messages":[{"id":7,"senderID":3,"senderNickname":"alice-1","recipientID":4,"recipientNickname":"bob-1","timestamp":"...","content":"hello bob"}]}
> dm 3 hi alice
< {"ok":true,"cmd":"dm","serverID":1,"peerUserID":3}
```

As with rooms, Alice's own echo already counts for `wait direct_message`, so she takes it with
one `wait direct_message` before a second one waits for Bob's reply.

From a shell script, give each client a named pipe for stdin and a file for stdout:

```sh
mkfifo alice.in
./haychat-client --headless --name alice-1 --server 127.0.0.1:12345 \
	--config-dir ./profiles/alice <alice.in >alice.out 2>alice.err &
exec {alice}>alice.in          # hold the pipe open so the client keeps running
echo "send 1 hello bob" >&$alice
grep -F '"cmd":"send"' alice.out
```

`dev/harness-smoke.sh` is a complete example.

## Smoke Test

`./dev.sh live --harness` builds and starts a server against a throwaway PostgreSQL (see
`dev/live-proof.sh`) and runs `dev/harness-smoke.sh`, which builds the client and checks:

1. One client connects, reports `status`, receives its room list, and lists `rooms`. It then
   sends `reconnect` and waits for the worker to sign in again.
2. A second client connects; the first sends a unique message to room 1 and the second must
   print a `room_chat` event with that text.
3. The first client prints a `presence` event for the second, finds its user ID with `users`,
   and sends it a unique direct message with `dm`; the second must print a `direct_message`
   event with that text, and its `dm-history` with the first must contain it.
4. The second client quits and comes back from the same profile under a new name; the first
   must print a `presence` event for the same user ID with the new nickname, and list it under
   that name in `users`.
5. The first client is made an admin with `deploy/sql/make-admin.sql` (`make_admin` in
   `dev/harness-lib.sh` runs it with `psql` against the `HAYCHAT_DATABASE_*` database), sends
   `reconnect`, and must report `"isAdmin":true` in `status`. It creates a room; the second
   client must print `room_membership`, list the room in `rooms`, and send to it. The first
   renames the room and the second must print `room_edited`; the first deletes it and the
   second must print `room_deleted` and report `#general` (room 1) as its selected room.
6. Read state: a new client D signs up and quits; a new client C sends two messages to room 1
   and a direct message to D. D comes back from its profile and must list 2 unread in room 1
   (`rooms`) and 1 from C (`conversations`). A second session of D, from the same profile, is
   connected when D loads both conversations and sends `read room 1` and `read dm C`; the
   second session must print both `read_marker` events with `unreadCount` 0 and then list 0,
   and a third session started afterwards must list 0 straight from the server.

`./dev.sh live --all` runs it after the live client tests. Step 2 relies on open rooms: a new
account joins every existing room, and `dev/live-proof.sh` loads the `#general` fixture before
any client connects. If the sender is not a member of room 1 the server answers with
`protocol_error "Not a room member"` and step 2 fails with a `[two-client]` message.

## GUI Automation

The headless harness acts as a user without the window. Its sibling, `client --ui-script FILE`,
drives the real window from a script: it clicks widgets, types, presses keys, waits until text
appears, and captures screenshots. Nothing is injected through the operating system (KDE
Wayland offers no input injection): the script runs on the UI thread between frames and pushes
synthetic SDL events, which travel the same path as real input (`handleAppEvent` →
`ui.handleEvent` → widgets). The interpreter lives in `client/ui_script.odin`; the drawn-text
registry it reads is `client/ui/automation.odin`, which records the strings drawn by
`ui.label`, `ui.wrappedLabel`, `ui.button`, transcript units and empty text inputs'
placeholders, plus every widget's hit-test rect, only while a script runs.

```sh
odin build client -out:haychat-client
SDL_VIDEO_DRIVER=offscreen ./haychat-client --ui-script smoke.uis \
	--name alice-1 --server 127.0.0.1:12345 --config-dir ./profiles/alice --window 1280x800
```

| Option | Meaning |
| --- | --- |
| `--ui-script FILE` | The script to run. Every line is parsed before the window opens, so a bad line runs nothing. |
| `--name`, `--server`, `--config-dir` | Exactly as in headless mode (the same parser). Without a name or server the window opens the first-run screen, which a script can fill in. |
| `--window WxH` | Window size in window coordinates, at least `800x480` (default `1280x800`), so screenshots have a known size. |

### Running Without a Display

SDL3's `offscreen` video driver renders into memory with no display server; the Fedora SDL3
package (the dev image and CI) includes it and renders through EGL (`opengl` renderer, Mesa
in the dev image). Set `SDL_VIDEO_DRIVER=offscreen` for headless machines and containers; the
client prints what it got on stderr (`[Info] UI script: video driver offscreen renderer
opengl`). `SDL_VIDEO_DRIVER=dummy` works too, with SDL's `software` renderer. On a desktop,
leave the variable unset (or set `wayland`/`x11`) to watch the window being driven.
Use `--config-dir` (or an isolated `XDG_CONFIG_HOME`) so a scripted run never touches your own
identity in `~/.config/haychat`.

A scripted window counts as focused whatever the driver reports (`offscreen` never reports
focus), so, unlike the headless harness, it marks the room or conversation it shows read, as a
user sitting at it would (see [Read State](#read-state)).

### Script Language

One command per line. A word starting with `#` outside quotes begins a comment, so
`click "# general"  # the channel` works. TEXT is a bare word or a `"quoted string"` with the
escapes `\"`, `\\`, `\n` and `\t`. Text matches are exact and case sensitive against whole
drawn strings (a sidebar row whose text is cut off on screen still matches its full text).
Timeouts default to 5000 ms and may be at most 600000.

| Command | Effect |
| --- | --- |
| `wait MS` | Lets the UI run and draw for MS milliseconds. |
| `wait-text "TEXT" [TIMEOUT_MS]` | Waits until TEXT is drawn in the current frame. |
| `wait-count N "TEXT" [TIMEOUT_MS]` | Waits until TEXT is drawn at least N times (e.g. a user under both Direct Messages and Members). |
| `assert-text "TEXT"` | Fails unless TEXT is drawn in the current frame. |
| `click "TEXT"` | Clicks the centre of the most recently drawn TEXT that lies on a widget (button, sidebar row, rail button, input placeholder), or else the most recent TEXT anywhere. A sidebar row therefore wins over a header repeating its label. |
| `click-id NAME [INT...]` | Clicks the widget whose ID is `ui.idOf(NAME, INT...)`, the same name and values the view passes (up to 4 integers), e.g. `click-id dm-input 1 7` for the DM composer with user 7 on server 1, or `click-id room-input 1 1`. |
| `click X Y` | Clicks at window coordinates. |
| `type "TEXT"` | Delivers TEXT as one `SDL_EVENT_TEXT_INPUT` to the focused text field (click the field first). |
| `key NAME` | Presses and releases a key. Names (any case): `Return`, `Enter`, `Escape`, `Tab`, `Backspace`, `Delete`, `Space`, `Up`, `Down`, `Left`, `Right`, `Home`, `End`, `PageUp`, `PageDown`, `A`, `C`, `V`, `X`, with optional `Shift+`, `Ctrl+`, `Alt+`, `Gui+`/`Cmd+` prefixes, e.g. `Shift+Return`, `Ctrl+A`. |
| `screenshot FILE.bmp` | Writes the next frame to FILE as a BMP (SDL has no PNG writer). Convert with `magick FILE.bmp FILE.png`. |
| `quit` | Ends the script and closes the window. Reaching the end of the file does the same. |

After `click`, `type` and `key` the next command waits until two more frames are drawn, so
the input has been handled and its effects are on screen. Waits re-check every frame and at
least every 10 ms.

### Output and Exit Codes

stdout carries one JSON line per command and a final summary; diagnostics go to stderr.

```json
{"ok":true,"cmd":"wait-text","line":2,"text":"# general","waitedMS":42}
{"ok":true,"cmd":"click","line":3,"text":"# general","x":184.0,"y":107.0}
{"ok":true,"cmd":"screenshot","line":4,"file":"shots/01.bmp"}
{"ok":false,"cmd":"assert-text","line":5,"text":"bye","error":"the text is not drawn in the current frame"}
{"event":"ui_script_done","failed":1,"skipped":1}
```

The script stops at the first failed command; the commands after it count as `skipped`. A
bad line prints `{"ok":false,"cmd":"parse","line":N,"error":"..."}` before anything runs.

| Code | Meaning |
| --- | --- |
| 0 | Every command succeeded. |
| 1 | Usage error: bad options, an unreadable script, a parse error, or SDL could not start. |
| 3 | A wait timed out, an assertion failed, a lookup found nothing, or the window was closed before the script finished. |

### Screenshot of a Given State

Write a script that reaches the state, waits for text that proves it is drawn, and captures:

```text
wait-text "# general" 15000
click "# general"
wait-text "No messages yet"
screenshot /tmp/general-empty.bmp
quit
```

Combine it with headless clients to set the scene: `dev/ui-smoke.sh` starts a headless bob,
writes a script for the GUI alice with bob's user ID filled in, and lets bob answer while the
window waits.

### GUI Smoke Test

`./dev.sh live --ui` (also part of `--all` and so of `./dev.sh ci`) runs `dev/ui-smoke.sh`
against the throwaway server. alice, in the window on the offscreen driver, clicks `# general`
and the composer, sends a message that headless bob must receive, waits for bob's direct
message under Direct Messages, opens it, asserts its text, and replies from the DM composer;
bob must receive the reply as a `direct_message`. alice is an admin (her profile connects
once headlessly before the window opens, so `make_admin` has an account to grant the role to):
she clicks **+ New room**, types a name, clicks **Create**, and waits until the room is drawn;
bob must receive `room_membership` and list the room. Then, on SDL's dummy audio driver, she
clicks **Join voice**, waits for "Voice connected", mutes, opens Settings → Voice, and leaves
again, while bob must see her join, mute and leave in `voice_participants`. alice takes twelve
screenshots on the way and the script prints their paths. They stay in `HAYCHAT_UI_SCREENSHOT_DIR` when set and otherwise
in a new temporary directory, which disappears with the container under `./dev.sh`; set
`HAYCHAT_DEV_UI_SCREENSHOTS=DIR` to have `./dev.sh live` mount a host directory for them.
`dev/ui-smoke.sh 127.0.0.1:12345` also runs on the host against any server.

## Voice Engine Loopback

`client --voice-loopback` is a hidden debug mode for the voice engine (`client/voice_engine.odin`).
It opens no window and no server connection: audio goes from a source through the gate, the
Opus encoder, the per-speaker jitter buffer and the decoder to a sink, with the encoder's
output fed straight back in as a fake remote speaker. Use it to check a microphone, the
speakers, and the codec settings by ear, or to produce files for analysis. To run voice
through a server instead, use the harness's voice commands (see [Voice](#voice)).

```sh
odin build client -out:haychat-client
./haychat-client --voice-loopback --seconds 10              # microphone → speakers (use headphones)
./haychat-client --voice-loopback --source tone:440 --sink file:/tmp/out.f32 --seconds 3
./haychat-client --voice-loopback --loss 15 --always-on     # hear FEC and concealment
```

| Option | Meaning |
| --- | --- |
| `--seconds N` | How long to run, 1 to 600 (default 10) |
| `--source SPEC` | `device[:NAME]` (default: the system default microphone), `tone:HZ[:AMP]`, `file:PATH` (raw F32LE mono 48 kHz), or `silence` |
| `--sink SPEC` | `device[:NAME]` (default: the system default output), `file:PATH` (every speaker mixed, raw F32LE mono 48 kHz, silence included), or `null` |
| `--loss PCT` | Drop this share of loopback frames (0 to 90) |
| `--threshold DB` | Voice activity threshold in dBFS (default -45) |
| `--always-on` | Send every frame (push-to-talk held) instead of gating on voice activity |

Device names are SDL's, which on PipeWire are the device descriptions (`pactl list sinks`
shows them as `Description`); an unknown name falls back to the default device with a
warning. The input level and whether the gate is sending print every second on stderr, and
the engine counters print as one JSON line on stdout when it ends:

```json
{"result":"voice-loopback","captured":200,"sent":199,"gated":1,"captureDropped":0,"loopbackDropped":0,"decoded":198,"fec":0,"plc":0,"late":0,"decodeErrors":0}
```

Raw files are what SDL's `disk` driver reads and writes, so the device path also runs with no
audio server, for example in `./dev.sh shell`:

```sh
SDL_AUDIO_DRIVER=disk SDL_AUDIO_DISK_INPUT_FILE=/tmp/out.f32 \
	SDL_AUDIO_DISK_OUTPUT_FILE=/tmp/disk.f32 ./haychat-client --voice-loopback --seconds 2
```

The disk driver's output file has the playback device's format: F32LE **stereo** 48 kHz.
To listen to a raw file on the host: `pw-cat --playback --format f32 --rate 48000
--channels 1 /tmp/out.f32` (or `sox -t f32 -r 48000 -c 1 /tmp/out.f32 -d`). To try it against
virtual devices without touching your real ones, create a PipeWire null sink
(`pactl load-module module-null-sink sink_name=hc_test sink_properties=device.description=HC-Test`),
pass `--sink device:HC-Test`, record it with `pw-record --target hc_test -P
stream.capture.sink=true out.wav`, and unload the module afterwards.
