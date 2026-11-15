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
| 1 | Bad arguments, the config and identity key could not be loaded or created, or the profile has no display name (pass `--name`) |
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
| `status` | `connection` (`connecting`, `connected`, `retrying`, `failed`, or `none` without a server), `connected` (true when signed in), `retryInMS` (time until the next attempt while `retrying`), `serverID`, `server` (`host:port`), `userID`, `nickname`, `isAdmin` (the server's admin flag for this session, see `connected`; `account_updated` changes it), `nicknameLocked` (an admin set and locked the name), `selectedRoomID`, `lastError` (the last raw failure or disconnect reason) |
| `reconnect` | Connects the selected server again now: drops any session in progress, skips the remaining retry delay, and also restarts after a failure that stopped retrying. The outcome arrives as `connecting` and then `connected` or `connect_failed` events. |
| `rooms` | The joined rooms from the cache: `loaded`, `loading`, `rooms` (`[{"id","name","description","lastReadMessageId","unreadCount","roomType","access","historyVisibility"}]`, see [Read State](#read-state); `roomType` is 1 text, 2 voice, 3 both; `access` 1 Public, 2 Member invite, 3 Admin invite; `historyVisibility` 1 From join, 2 Full, always 2 for a Public room). When the list is not loaded yet it is requested and arrives as a `room_list` event. |
| `history ROOM_ID [BEFORE_MESSAGE_ID]` | Requests one page of history (newest first page with no cursor, older pages with the oldest loaded message ID). The page arrives as a `room_history` event. |
| `send ROOM_ID TEXT...` | Sends the rest of the line to the room, through the same action as the GUI composer. `ok` means the transport accepted it; the message itself comes back as a `room_chat` event, and a rejection as a `protocol_error` event. In an encrypted room (protocol 19) the text is sealed with this session's sender chain: the result says `"encrypted":true`, and `"queued":true` while the chain is being set up (the message goes out once the server stored its distribution; `room_queue` says so). |
| `users` | The server's accounts from the cache, yourself included: `loaded`, `loading`, `users` (`[{"id","nickname","isOnline","lastReadMessageId","unreadCount","identityPublicKey","hasEncryptionKey","keyState","isAdmin","isBanned"}]`, ordered by nickname; `lastReadMessageId` and `unreadCount` are the read state of your conversation with that account, 0 without one; the key fields are explained under [Encryption Keys](#encryption-keys)). The list is fetched when the client connects and kept current by `presence` and `user_updated` events; when it is not loaded yet it is requested and arrives as a `user_list` event. |
| `conversations` | Your direct conversations from the cache, most recent first: `loaded`, `loading`, `conversations` (same shape as the `conversations` event). Fetched at connect; a live `direct_message` moves its conversation to the top. Requested when not loaded yet. |
| `dm USER_ID TEXT...` | Sends the rest of the line as an end-to-end encrypted direct message to that account, through the same action as the GUI's direct-message composer (protocol 17). The result carries `encrypted` (it went out encrypted) and `queued` (the account's key is still being fetched: the message waits and a `direct_queue` event says when it went out, or that it went back into the draft). It is refused, with the reason, when encryption to the account is not possible (no key, a changed key, or a key the server no longer provides); use `dm-plain` then. The stored message comes back as a `direct_message` event to every session of both users (the sender's included), and a rejection as a `protocol_error` event (`Unknown direct message recipient`, `Cannot send a direct message to yourself`, `Invalid encrypted direct message`, `Duplicate direct message`). |
| `dm-plain USER_ID TEXT...` | The plaintext fallback: turns on the conversation's **Send without encryption** switch through the GUI's action (accepting the first-time confirmation), sends a signed plaintext message, and turns the switch off again. Refused while encryption to the account is possible or its key is still being checked. See [Encrypted Direct Messages](#encrypted-direct-messages). |
| `dm-history USER_ID [BEFORE_MESSAGE_ID]` | Requests one page (up to 50 messages, both directions) of the conversation with that account: the newest page with no cursor, older pages with the oldest loaded message ID. It arrives as a `direct_history` event. |
| `room-create TYPE[,OPTION...] NAME [DESCRIPTION...]` | Admins: (protocol 18 options `encrypted`, for an invite room, and `managers=ID+ID` or `managers=none`: the other managers to name; without `managers=` every admin this client sees is named, as in the form, after their keys are fetched; the room's Create entry is signed and sent when `room_created` arrives, and `room_log` reports it) asks the server for a new room of type TYPE (`text` takes chat only, `voice` voice only, `both` both; `chat` is a synonym of `text`) named NAME (one word here; a leading `#` is dropped) with the rest of the line as its description. Comma-separated options after the type (protocol 15): the access mode `public` (the default), `member-invite` or `admin-invite`; the history `from-join` (the default) or `full` (ignored for a Public room, which always has full history); and `no-join` to create an invite room you are not a member of. For example `room-create both,admin-invite,full,no-join ops`. The result echoes `serverID`, `roomID` (0), `name`, `description`, `roomType` (1 text, 2 voice, 3 both), `access`, `historyVisibility` and `creatorJoins` once the request is out. The new room arrives as a `room_created` event (to you only; it also becomes the selected room unless you did not join it), and its members (every connected client for a Public room, only you for an invite room you joined) get `room_membership` with `joined` true and then a fresh `room_list`. The same checks as the GUI form run first: an empty or over-long name, an over-long description, or the name of a listed room is an `ok:false` result. A non-admin gets `protocol_error "Admin permission required"`. |
| `room-edit ROOM_ID TYPE[,ACCESS] NAME [DESCRIPTION...]` | Admins: sets the room's type and, with `public`, `member-invite` or `admin-invite` after it, its access mode (without one it keeps the mode the client knows; the history cannot change), renames it, and replaces its description (an empty one without DESCRIPTION). Making a room Public adds every account, and each gets `room_membership` with `joined` true. Every member, you included, gets `room_edited`. Making a room `text` first removes everyone from its voice (`voice_left` "voice is disabled in this room"). A voice-only room refuses `send` (`protocol_error "Chat is disabled in this room"`), a text-only room refuses `voice-join` (`voice_join_rejected` "voice is disabled in this room"). |
| `room-delete ROOM_ID` | Admins: deletes the room and its history. Every member, you included, gets `room_deleted`; a client whose selected room it was falls back to `#general` (room 1) while it exists, otherwise to the first room. Room 1 can be deleted too; the server recreates `#general` on its next start only when no rooms are left. |
| `admin-role USER_ID on\|off` | Admins: grants or revokes the server's admin role (protocol 14). `ok` (`serverID`, `userID`) means the request went out. The answer is `admin_result`; every connected client gets `user_updated`, and the target's sessions get `account_updated` with the new `isAdmin`, without reconnecting. Refusals are `protocol_error`: `Admin permission required`, `Unknown user`, `You cannot remove your own admin role`, `The server must keep at least one admin`, `Unban the account before making it an admin`. |
| `admin-rename USER_ID lock\|unlock [NAME...]` | Admins: renames the account to NAME (3 to 32 bytes; without NAME only the lock changes) and locks or unlocks its name. While locked, the account signs in under that name whatever its client asks for, so the target's next `connected` carries it with `"nicknameLocked":true`. The answer is `admin_result`, then `user_updated` everywhere, `account_updated` on the target's sessions, and `presence` with the new name while it is online. A name another account holds is `protocol_error "That name is already in use on this server"`. Renaming yourself is allowed. |
| `admin-kick USER_ID [REASON...]` | Admins: ends every session of the account. The target's sessions print `session_ended` (`kind` `kicked`) and do not reconnect by themselves; `reconnect` signs in again. Refused for yourself (`You cannot kick yourself`) and for another admin (`Remove the admin role before kicking an admin`). Reasons are at most 256 bytes; a longer one is an `ok:false` result. |
| `admin-ban USER_ID [REASON...]` | Admins: bans the account and ends its sessions (`session_ended` `kind` `banned`); its next sign-in is refused with `connect_failed` `failure` `Banned` (`detail` "This account is banned from this server", plus ": REASON" when there is one). Everyone gets `user_updated` with `"isBanned":true`. Refused for yourself (`You cannot ban yourself`) and for another admin (`Remove the admin role before banning an admin`), like a kick. Sign-up is open, so a banned person can still connect with a new identity key as a new account. |
| `admin-unban USER_ID` | Admins: lifts a ban; everyone gets `user_updated` with `"isBanned":false`, and the account can sign in again. |
| `room-members ROOM_ID` | Members of the room, and admins (members or not), get its members as a `room_members` event (protocol 15); anyone else gets `protocol_error "Not a room member"`, whether or not the room exists. `ok` (`serverID`, `roomID`) means the request went out. |
| `room-add ROOM_ID USER_ID` | Adds the account to the room as its mode allows: admins in Member invite and Admin invite rooms, members in Member invite rooms. The answer is `room_member_result` (`changed` false when the account already was a member); the account, the room's members and you get `room_membership` with that `userID`. Refusals are `protocol_error`: `Public rooms include every account`, `Admin permission required` (an Admin invite room), `Not a room member`, `Room not found` (admins only; others get `Not a room member`), `Unknown user`. The harness checks none of this itself, so the server's refusal shows. |
| `room-remove ROOM_ID USER_ID` | Admins: removes the account from the room, in every mode. The answer is `room_member_result` with `added` false; the account (whose client drops the room), the remaining members and you get `room_membership` with `joined` false. Removing someone who is not a member changes nothing. Anyone else gets `protocol_error "Admin permission required"`. |
| `room-leave ROOM_ID` | Leaves a non-public room you are a member of; the answer is `room_membership` with `joined` false and your `userID` (also to the room's other members), and the room leaves your `rooms`. Refusals: `You cannot leave a public room`, `Not a room member`. |
| `admin-rooms` | Admins: every room on the server, joined or not, as an `admin_rooms` event; others get `protocol_error "Admin permission required"`. |
| `room-log ROOM_ID` | An encrypted room's member log as this client verified it (protocol 18): prints a `room_log` event at once, then its result (`serverID`, `roomID`), and fetches what the client lacks (the whole log the first time, else what follows its verified version), which prints another `room_log` once applied. A client whose log failed fetches nothing more. Non-members who are neither managers nor admins get `protocol_error "Not a room member"`. See [Encrypted Rooms](#encrypted-rooms). |
| `room-keys ROOM_ID [fetch]` | Protocol 19: the sender chains of an encrypted room this profile holds (`chains`: epoch, sender, chain ID and start index, never a key), the log's `epoch`, and how sending stands (`sending`, `sendingEpoch`, `sendingChain`, `nextIndex`, `distribution` none/sent/stored, `queued`, `inFlight`, `keysFetched`). With `fetch` it first asks the server for the room's envelopes again (`room_key` events follow; a non-member gets `protocol_error` "Not a room member"). |
| `room-manager ROOM_ID USER_ID on\|off` | Signs an AddManager or RemoveManager entry for an encrypted room. The account's key must be pinned (the change waits for a fetch otherwise). |
| `room-access ROOM_ID member-invite\|admin-invite` | Signs a SetAccess entry (a manager who is also an admin). |
| `room-log-entry ROOM_ID add\|remove\|add-manager\|remove-manager\|leave USER_ID [unsigned]` | Builds the next entry on this client's verified head, signed by this account or (`unsigned`) with no actor and no signature, and prints it as hex (`entry`, `version`) without sending it or checking the log's rules, so a proof can insert it behind the server's back. The target's key must be pinned or named by the log. |
| `user-keys USER_ID` | Asks the server for the account's encryption key bundle (protocol 16). The result is `serverID`, `userID` and `requested` (false when a fetch for it was already on its way); the answer, checked and pinned, arrives as a `user_keys` event. Not for yourself. See [Encryption Keys](#encryption-keys). |
| `verify USER_ID` | Mark as verified, after comparing `safetyNumber` with the other side's: the result has the `user_keys` fields with `keyState` `verified`. In `key_changed` it trusts the key the server now offers and marks it verified, like the GUI dialog. `ok:false` ("refused in key state ...") without a pin, or while the key is missing or invalid. |
| `trust-key USER_ID` | Trust the new key: in `key_changed`, pins the key the server now offers, unverified (`ok:false` in any other state, or before the new bundle arrived). |
| `read room\|dm ID [MESSAGE_ID]` | Marks room ID, or the direct conversation with user ID, read up to MESSAGE_ID; without it, up to the newest message loaded for that conversation (an `ok:false` result when nothing is loaded: fetch it with `history` or `dm-history` first). `ok` means the request went out (`serverID`, `kind`, `conversationID`, `messageID`). When the marker moved, every session of your account, this one included, gets a `read_marker` event; a read that moves nothing (the marker is already there) gets no answer. Not a member, or no such user, is a `protocol_error` (`Not a room member`, `Unknown user`). |
| `voice-join ROOM_ID` | Joins the room's voice on the selected server (leaving any other first). `ok` (`serverID`, `roomID`, `status` `joining`) means the request went out; the join completes with `voice_participants` carrying `"recipientJoined":true`, then `voice_status` `joined` once the engine runs. A refusal arrives as `voice_join_rejected`. See [Voice](#voice). |
| `voice-leave` | Leaves voice and stops the engine (`serverID` and `roomID` it left, 0 when it was not in voice, and the `status` after it). A file sink is closed, complete, at this point. |
| `voice-source SPEC` | What the next join sends: `tone:HZ[:AMP]` (a sine, amplitude 0 to 1, default 0.5), `file:PATH` (raw F32LE mono 48 kHz, silent after its end), `silence` (the default), or `device[:NAME]` (an SDL recording device; the only way SDL audio is initialised). |
| `voice-sink SPEC` | Where the next join plays: `file:PATH` (every speaker mixed into raw F32LE mono 48 kHz, silence written while nobody speaks), `null` (the default: decode and discard), or `device[:NAME]` (an SDL playback device). |
| `voice-gate vad [THRESHOLD_DB]\|ptt\|open` | Voice activity (threshold in dBFS, -100 to below 0, default -45), push-to-talk, or `open`: push-to-talk with the key held, so every frame is sent. Applies at once and to the next join. |
| `voice-mute on\|off`, `voice-deafen on\|off` | Mute closes the gate at once and deafen stops playback at once; both are then sent to the server (which shows them in `voice_participants`) and carried by the next join. |
| `voice-ptt down\|up` | Presses or releases push-to-talk (local only). |
| `voice-volume USER_ID PERCENT` | How loud this client plays that user on the selected server, 0 to 200 (percent), through the same action as the Server settings slider: stored in the server's config entry for this run (the harness does not write `config.json` back) and applied at once to a running engine, otherwise from the next join. Local only: the server and the user are not told. The result is the user's setting: `serverID`, `userID`, `volumePercent`, `muted`, and what the engine applies (`engineRunning`, `engineVolumePercent`, `engineMuted`; 100 and false without an engine on that server). 100 with mute off removes the entry. |
| `voice-mute-user USER_ID on\|off` | Mute for me: this client stops playing that user's voice (frames are dropped before decoding and counted in `engine.inboundLocallyMuted`) and keeps its volume. Same result as `voice-volume`. |
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
| `connected` | `{"event":"connected","serverID":1,"userID":3,"nickname":"alice-1","isAdmin":false,"nicknameLocked":false}` (`isAdmin`: the account holds the server's `admin` role; `nickname` is the account's name on the server, which an admin may have set and locked, `nicknameLocked`) |
| `connect_failed` | `{"event":"connect_failed","serverID":1,"message":"timed out connecting to the server","detail":"timed out connecting to the server","failure":"Unreachable","retryable":true,"retryInMS":2000}` |
| `room_list` | `{"event":"room_list","serverID":1,"rooms":[{"id":1,"name":"general","description":"...","lastReadMessageId":12,"unreadCount":0,"roomType":3}]}` (`roomType`: 1 text, 2 voice, 3 both) |
| `room_chat` | `{"event":"room_chat","serverID":1,"roomID":1,"messageID":12,"senderID":3,"senderNickname":"alice","timestamp":"...","encrypted":false,"decryptError":"","epoch":0,"protection":"plain","content":"hi"}` (printed after the client opened it: in an encrypted room `encrypted` true, `epoch` the chain's, `protection` `encrypted` with the opened `content`, or `failed` with `decryptError` such as `BadSignature`, `not_sealed`, `not_member`, `replayed`; a live message that waits for its key or the log is printed once it opens) |
| `room_history` | `{"event":"room_history","serverID":1,"roomID":1,"hasOlder":false,"messages":[{"id":12,"senderID":3,"senderNickname":"alice","timestamp":"...","encrypted":false,"decryptError":"","epoch":0,"protection":"plain","content":"hi"}]}` (messages as for `room_chat`; one that waits shows `protection` `pending` with `decryptError` `no_key` or `log`) |
| `room_opened` | Same shape as `room_chat`: a message from a history page that waited for its key or the member log and is now opened or settled |
| `room_key` | `{"event":"room_key","serverID":1,"roomID":5,"epoch":2,"senderID":3,"chainID":"<hex>","requesterID":0,"outcome":"stored","error":""}` (a key envelope this client handled: `stored`, `duplicate`, `not_for_me` (no wrap for this account), `pending` (waits for the log), `not_member` (the sender was not a member of that epoch), `failed` with `error`) |
| `room_key_request` | Same shape as `room_key`: another member asked for this account's chain (`requesterID`); `outcome` `stored` when it was re-sealed for them, `refused` when they were not a member of that epoch in the verified log |
| `room_queue` | `{"event":"room_queue","serverID":1,"roomID":5,"state":"sent","count":1,"reason":""}` (messages `send` queued for the sender chain went out; `state` `refused` with `reason` when they went back into the draft) |
| `room_membership` | `{"event":"room_membership","serverID":1,"roomID":2,"joined":true,"userID":4}` (`userID` joined or left the room: your own account, or another member of a room you are in, or the target of your own add or removal) |
| `room_edited` | `{"event":"room_edited","serverID":1,"roomID":2,"name":"...","description":"...","roomType":3,"access":1,"historyVisibility":2,"isMember":false}` (`isMember` is only set on `room_created`) |
| `room_members` | `{"event":"room_members","serverID":1,"roomID":2,"userIDs":[3,4]}` (the answer to `room-members`) |
| `room_member_result` | `{"event":"room_member_result","serverID":1,"roomID":2,"userID":4,"added":true,"changed":true}` (the answer to your own `room-add`, or with `added` false to `room-remove`) |
| `admin_rooms` | `{"event":"admin_rooms","serverID":1,"rooms":[{"room":{"id":2,"name":"ops",...,"access":3,"historyVisibility":1},"isMember":false,"memberCount":2}]}` (the answer to `admin-rooms`, by name) |
| `room_deleted` | `{"event":"room_deleted","serverID":1,"roomID":2}` |
| `room_created` | `{"event":"room_created","serverID":1,"roomID":2,"name":"random","description":"...","roomType":3,"access":1,"historyVisibility":2,"isMember":true,"encrypted":false,"logVersion":0}` (the answer to your own `room-create`; `isMember` false for an invite room created with `no-join`, and for every encrypted room, which starts empty at `logVersion` 0; `room_edited` carries `encrypted` and `logVersion` too, and so does every room in `room_list` and `rooms`) |
| `room_log` | `{"event":"room_log","serverID":1,"roomID":5,"status":"verified","logVersion":2,"serverLogVersion":2,"headHash":"<hex>","access":3,"historyVisibility":1,"members":[3,4],"managers":[3],"logError":"","warning":"","events":["alice created this encrypted room (admins invite, 1 manager)","alice added bob"]}` (protocol 18: an encrypted room's member log after this client applied a `ServerRoomLog`, and for `room-log`; `status` `unknown`, `loading`, `verified` or `failed`, with `logError` naming the rule that failed and `warning` "This room's member list was changed on the server") |
| `protocol_error` | `{"event":"protocol_error","serverID":1,"message":"..."}` |
| `disconnected` | `{"event":"disconnected","serverID":1,"message":"connection lost","retryInMS":900}` |
| `direct_message` | `{"event":"direct_message","serverID":1,"id":7,"senderID":3,"senderNickname":"alice","recipientID":4,"recipientNickname":"bob","timestamp":"...","encrypted":true,"signed":true,"decryptError":"","protection":"encrypted","content":"hi"}` (printed after the client opened it; see [Encrypted Direct Messages](#encrypted-direct-messages)) |
| `direct_history` | `{"event":"direct_history","serverID":1,"peerUserID":4,"hasOlder":false,"messages":[{"id":7,"senderID":3,"senderNickname":"alice","recipientID":4,"recipientNickname":"bob","timestamp":"...","encrypted":true,"signed":true,"decryptError":"","protection":"encrypted","content":"hi"}]}` |
| `direct_opened` | Same shape as `direct_message`: a message from a history page that waited for its sender's key (`protection` `pending` in `direct_history`) and is now opened or settled |
| `direct_queue` | `{"event":"direct_queue","serverID":1,"peerUserID":4,"state":"sent","count":1,"reason":""}` (messages `dm` queued for a key went out encrypted; `state` `refused` when they went back into the draft, with the reason) |
| `user_list` | `{"event":"user_list","serverID":1,"users":[{"id":3,"nickname":"alice","isOnline":true,"identityPublicKey":"3bac...","hasEncryptionKey":true,"keyState":"unverified","isAdmin":false,"isBanned":false}]}` (`keyState` as before the list was applied; see [Encryption Keys](#encryption-keys)) |
| `user_updated` | `{"event":"user_updated","serverID":1,"user":{"id":4,"nickname":"bob","isOnline":true,"identityPublicKey":"d14b...","hasEncryptionKey":true,"keyState":"verified","isAdmin":true,"isBanned":false}}` (an admin changed an account's role, ban, or name; the full directory entry) |
| `user_keys` | `{"event":"user_keys","serverID":1,"userID":4,"nickname":"bob","keyState":"unverified","canEncrypt":true,"verified":false,"hasPin":true,"identityPublicKey":"d14b...","encryptionPublicKey":"8a6d...","createdAt":1731600000,"safetyNumber":"68114 90353 ...","notice":"","message":""}` (what the client concluded about an account's key after a `ServerUserKeys` or `ServerUserKeyChanged`; see [Encryption Keys](#encryption-keys)) |
| `account_updated` | `{"event":"account_updated","serverID":1,"isAdmin":true,"nickname":"bob","nicknameLocked":false}` (an admin changed this account's role or name while it is connected) |
| `admin_result` | `{"event":"admin_result","serverID":1,"action":"role","userID":4,"message":"bob is an admin"}` (your admin request succeeded; `action` is `role`, `rename`, `kick`, or `ban`, an unban included) |
| `session_ended` | `{"event":"session_ended","serverID":1,"kind":"kicked","message":"An admin removed you from this server (reason: calm down). Press Retry to connect again.","reason":"calm down","retryable":false}` (an admin kicked or banned this account; the connection stays stopped until `reconnect`) |
| `conversations` | `{"event":"conversations","serverID":1,"conversations":[{"peerUserID":4,"peerNickname":"bob","lastMessageID":7,"lastSenderID":3,"lastTimestamp":"...","encrypted":true,"signed":true,"decryptError":"","protection":"encrypted","conversationEncrypted":true,"lastContent":"hi","lastReadMessageId":0,"unreadCount":0}]}` (`lastContent` is the opened preview, the next four fields describe the newest message as in `direct_message`, and `conversationEncrypted` is the key store's no-downgrade flag) |
| `presence` | `{"event":"presence","serverID":1,"userID":4,"nickname":"bob","isOnline":true}` |
| `read_marker` | `{"event":"read_marker","serverID":1,"kind":"room","conversationID":1,"lastReadMessageId":12,"unreadCount":0}` (`kind` is `room` or `dm`; for `dm`, `conversationID` is the peer's user ID) |
| `voice_participants` | `{"event":"voice_participants","serverID":1,"roomID":1,"recipientJoined":true,"participants":[{"userID":3,"nickname":"alice","muted":false,"deafened":false}]}` (a room's full voice participant set; `"participants":[]` when the last one left) |
| `voice_join_rejected` | `{"event":"voice_join_rejected","serverID":1,"roomID":1,"reason":"voice room is full"}` |
| `voice_left` | `{"event":"voice_left","serverID":1,"roomID":1,"reason":"the room was deleted"}` (the server removed this session from that room's voice) |
| `voice_status` | `{"event":"voice_status","serverID":1,"roomID":1,"status":"joined","wantRoomID":1,"error":""}` (the client's voice state changed: `idle`, `joining`, `joined`, or `unavailable`; printed by the harness, not the server) |
| `voice_speaking` | `{"event":"voice_speaking","serverID":1,"roomID":1,"userID":3,"speaking":true,"self":false}` (a speaker started or stopped being heard; `self` is this client's own sending; printed by the harness) |

In `connect_failed`, `message` is the explanation the GUI shows, `detail` the raw reason from
the transport or server, and `failure` its kind: `Unreachable` or `Other` (both retried),
`NameUnavailable`, `ServerKeyChanged`, `ProtocolMismatch`, `InvalidName`, `InvalidIdentity`,
`Kicked`, `Banned` (protocol 14: a banned account's sign-in), or the harness's own `NoServer`
and `Timeout`. `retryable` is true when the worker will try again
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
(protocol 8). A role an admin changes from a client (`admin-role`) reaches the account's
sessions at once as `account_updated` (protocol 14). A role changed directly in the database
(for example with `deploy/sql/make-admin.sql`) shows only on the next connection: send
`reconnect` and wait for `connected`. The server checks the role again for every admin
request, so a stale `true` only earns a `protocol_error "Admin permission required"`.

`session_ended` means the server is about to drop this session because an admin kicked or
banned the account. The client does not reconnect by itself afterwards (`status` reports
`failed`); `reconnect` tries again, which a kick allows and a ban refuses with `connect_failed`
`failure` `Banned`.

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
  12). Naming your `userID` is not enough, because a list also names you while your account is
  in voice on another device. A list names each user at most once (protocol 13).
- `voice_status` is the harness's view of the client's voice state, printed whenever it
  changes: `joining` after `voice-join` (or a re-join after a reconnect), `joined` once the
  server acknowledged this session and the engine runs, `idle` after a leave, a rejection, a
  removal or a lost connection (`wantRoomID` is the room a reconnect joins again, 0 when none),
  and `unavailable` when the engine could not start. `error` is why voice last stopped or
  failed: the server's reason after a rejection or a removal, or for `unavailable` no libopus
  or a device or file that cannot be opened.
- `voice_speaking` is printed on each edge of a speaker being heard. For another participant
  (`"self":false`, `userID` is the sender) it follows the engine's talk spurt for that speaker:
  it starts with the first frame and ends on the sender's end-of-spurt flag, or 200 ms after
  its frames stop (a leave or a mute). For this client (`"self":true`) it is whether the gate
  is sending. Both already have their own hysteresis (the jitter buffer's spurt, the gate's
  attack and hangover), so the edges are stable enough to `wait` for; when the engine stops,
  every speaker still speaking gets a `false` edge.
- `voice_join_rejected` answers a join the server refused: `not a room member`, `voice room is
  full`, `voice is disabled` (voice is off on the server), `voice is disabled in this room` (a
  text-only room, protocol 14), `invalid room`, `voice is unavailable, try again`, `invalid
  voice device ID`, or `voice is active on another device` (an automatic re-join while another
  device of the account is in voice).
- `voice_left` means the server took this session out of a room's voice: `removed from the
  room`, `the room was deleted` (it comes before `room_deleted`), `voice is disabled in this
  room` (an admin made the room text-only), `joined another voice room`, or `joined voice on
  another device` (another session of the account joined voice).
- An account has one voice session (protocol 13). `voice-join` is a join the user asked for, so
  it takes voice over from the account's other session. Two harness clients count as two
  devices only with different `device_id` values in their profiles' `config.json`: a profile
  copied for the same identity keeps the original's ID, so change or delete the key in the copy.
- Voice does not survive a reconnect. The client joins the same room again after `connected`
  (until it leaves, or a rejection or `voice_left` ends voice). That re-join is automatic: it
  replaces only a stale session of the same device and is refused while another device is in
  voice.
- Voice frames are never events: they go from the network thread straight to the voice engine.

### Voice Stats

`voice-stats` reports the flat fields scripts need first, then every counter:

```json
{"ok":true,"cmd":"voice-stats","status":"joined","serverID":1,"roomID":1,"running":true,
 "joinedMS":4104,"sent":0,"received":211,"lost":0,"fec":0,"plc":0,"late":0,"jitterMS":1.18,
 "depth":3,"maxGapRun":0,"playoutDelayMS":60.4,"playoutDelayMaxMS":66.1,"injectedLoss":0,
 "inputLevelDB":-100.0,"transmitting":false,"frameSequence":233,
 "engine":{"framesCaptured":233,"framesSent":0,...},"jitter":{"received":211,...},
 "speakers":[{"userID":3,"volumePercent":100,"speaking":true,"levelDB":-9.0,"bufferedFrames":3,
 "targetDepth":3,"jitterMS":1.18}],
 "network":{"datagramsReceived":211,"framesDelivered":211,"receiveDropped":{"Malformed":0,...},
 "framesSent":0,"sendDropped":{"NotJoined":0,...}},"userVoice":[]}
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
| `speakers` | Each current remote speaker: `userID`, `volumePercent` (the per-user volume the engine applies), `speaking`, `levelDB`, `bufferedFrames`, `targetDepth`, `jitterMS` |
| `network` | The transport's `ClientVoiceNetworkStats` for the voice server, read under the network worker's lock: datagrams received and delivered, frames sent, and every drop by reason |
| `userVoice` | Every per-user volume and mute stored for that server (`voice-volume`, `voice-mute-user`, Server settings), each as in the `voice-volume` result: `userID`, `volumePercent`, `muted`, `engineRunning`, `engineVolumePercent`, `engineMuted` |

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
every window's dominant frequency within `--tolerance` Hz (default 5) of `--freq` and its SNR
(the target bin over the median bin) at least `--min-snr` dB (default 20); the stretch's RMS
level within `--level-tolerance` dB (default 6) of the expected level; and the stretch at least
`--min-seconds` long (default 1). It prints the measured frequency (median and worst window),
level and SNR either way, and exits 0 on a pass, 1 on a failure and 2 on a usage or file error.
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
4. One session per user (protocol 13): G and H share one identity key (H's profile is a copy
   of G's, with the copy's `device_id` changed in its `config.json`), so both sign in as the
   same user. G joins room 1, then H joins room 1: G must print `voice_left` "joined voice on
   another device" and `voice_status` `idle` with `wantRoomID` 0 (no re-join), H a
   `voice_participants` with `recipientJoined` true and G one with `recipientJoined` false,
   both naming the user exactly once.

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

## Encryption Keys

Protocol 16 gives every profile an encryption key and lets clients pin each other's keys
(e2ee-design.md section 3); protocol 17 encrypts direct messages with them (below).

- **The profile's key.** `config.json` in `--config-dir` holds the encryption key next to the
  identity key ([client configuration](client-configuration.md#keys)). The harness creates both
  on the first run of a profile and saves them at once, so a profile run twice keeps the same
  keys; every session publishes the bundle after signing in.
- **The key store.** Pins are written to `DIR/haychat/keys/<server fingerprint>.json` like the
  GUI writes them ([key store](client-configuration.md#key-store)), so a profile run twice keeps
  its pins and its verified marks.
- **`keyState`.** `unknown` (no pin, nothing heard yet), `not_set_up` (no pin and the server has
  no key: the account has not set up encryption yet), `unverified` (pinned on first use),
  `verified`, `key_changed` (the server names another identity key than the pin; `canEncrypt`
  false until `verify` or `trust-key`), `not_provided` (pinned, but the server has no key for
  it now), `invalid_key` (the server sent a key whose signature does not verify, or one older
  than the pin; the pin stays).
- **`user_keys` fields.** `identityPublicKey` and `encryptionPublicKey` are the **pinned** keys
  in hex (empty without a pin), never the server's. `safetyNumber` is the number to compare (12
  groups of 5 digits, the same on both sides; in `key_changed` it is the new key's). `notice` is
  `set_up_again` after a newer encryption key under the same identity key (the pin was updated
  and is no longer verified). `message` is the sentence the GUI shows, empty when all is well.
- **When they arrive.** A `user_keys` event follows every account in a `ServerUserKeys` (the
  answer to `user-keys`, to opening a conversation, and to the fetch of every pinned account a
  new session makes) and every `ServerUserKeyChanged` (an account published a key it did not
  have before). This account itself is never pinned or reported.

### Encrypted Direct Messages

Protocol 17 (e2ee-design.md 4.5, 4.6). Direct message events are printed **after** the client
opened them, from what it concluded, never from the raw envelope:

- **`encrypted`** the message is an envelope; **`signed`** its signature verified against the
  sender's pinned key (every opened envelope, and a valid plaintext fallback);
  **`decryptError`** why an envelope could not be opened: `no_key` (the server has no key for
  the sender and none was ever pinned), `own_key` (this profile has no valid encryption key),
  `replayed` (another message from the same sender carries the same client message ID), or the
  `E2EEError` from `common/e2ee.odin` (`BadSignature`, `NoWrapForRecipient`, …), else `""`.
- **`protection`** `encrypted`; `signed` (plaintext sent through the fallback, the GUI's
  "Unencrypted"); `unverified` (plaintext whose signature does not verify: "Unencrypted, sender
  not verified"); `plain` (from before protocol 17, no signature: "Not encrypted"); `failed`
  (`content` empty: "This message could not be decrypted"); `pending` (waiting for the sender's
  key; `content` empty for an envelope).
- **Waiting for a key.** A live message from someone this profile has not pinned yet waits while
  the client fetches the key, and its `direct_message` is printed once it opened. A message in a
  history page that waits is listed as `pending` and printed again as `direct_opened`.
- **Sending.** `dm` encrypts like the GUI and is refused when encryption is not possible;
  `dm-plain` is the fallback switch. The key store's `direct_conversations` remembers which
  conversations were encrypted ([key store](client-configuration.md#key-store)).

`./dev.sh live --e2ee` runs `dev/e2ee-proof.sh` (also part of `--all`): alice and bob pin each
other and see the same safety number, alice verifies bob, bob restarts with the same key and is
still verified, then SQL hands out a third account's key as bob's, which alice sees as
`key_changed` until `trust-key`. Then carol and dan exchange encrypted direct messages both ways
(carol's first one is queued until dan's key arrives) and carol's history opens after a restart;
SQL finds no message text in `direct_messages` (envelopes only, empty content); dan's key store is
deleted and his old messages open again; and dave, whose key bundle SQL removed while he stays
signed in, cannot get carol's `dm`, while her `dm-plain` reaches him unencrypted and signed and
SQL finds its text. No client may print its encryption private key or log a message's text.

## Encrypted Rooms

Protocol 18 ([protocol.md](protocol.md#encrypted-rooms-and-the-member-log-protocol-18)).
`room-create text,admin-invite,encrypted NAME` creates an encrypted room: the server answers
`room_created` with `"encrypted":true,"logVersion":0`, the client signs the log's Create entry,
and the server's echo arrives as `room_log` with `logVersion` 1. In encrypted rooms
`room-add`, `room-remove` and `room-leave` sign log entries (a removal by an admin who is not a
manager goes to the server, which writes an unsigned Remove), `room-manager` and `room-access`
sign manager changes and access switches, and every change reaches the room's members and
managers as `room_log`. Like the other room commands, the harness does not check the log's
rules before sending, so the server's refusal shows (`protocol_error` "You may not make this
change to the member list", "The member list changed on the server; try again", "This
encrypted room is full", …); the GUI checks them first and says who to ask.

Since protocol 19 `send` to an encrypted room seals the message with this session's sender
chain ([protocol.md](protocol.md#sender-chains-in-encrypted-rooms-protocol-19)): the first one
in a session (and in each epoch) answers `"queued":true` and goes out once the server stored the
chain's distribution (`room_queue` with `state` `sent`). Room messages are printed after the
client opened them, with `encrypted`, `decryptError`, `epoch` and `protection`; one that waits
for its key is printed when it opens (`room_chat` for a live one, `room_opened` for history).
`room_key` and `room_key_request` show what happened to key envelopes and key requests, and
`room-keys ROOM_ID [fetch]` lists the chains a profile holds (never a key). `voice-join` is
refused ("voice is not available in encrypted rooms yet").

`dev/e2ee-proof.sh` (`./dev.sh live --e2ee`) creates encrypted rooms, adds and removes members,
inserts an unsigned and a non-manager's entry by SQL with `room-log-entry`, and checks that the
clients refuse those logs. For sender chains it exchanges sealed messages, checks that a
non-member gets neither keys nor history, that a restart of the sender starts a new chain (every
stored message at its own chain position), that no message text is in `chat_messages`, that a
deleted key store is rebuilt from the server, that an account invited to a From join room reads
only what follows, that a removed member gets no key for what follows, and that an account
inserted into `room_members` by SQL opens nothing.

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
< {"event":"connected","serverID":1,"userID":3,"nickname":"alice-1","isAdmin":false,"nicknameLocked":false}
< {"event":"room_list","serverID":1,"rooms":[{"id":1,"name":"general","description":"...","lastReadMessageId":0,"unreadCount":0,"roomType":3}]}
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
< {"ok":true,"cmd":"users","serverID":1,"loaded":true,"loading":false,"users":[{"id":3,"nickname":"alice-1","isOnline":true,"lastReadMessageId":0,"unreadCount":0,"isAdmin":false,"isBanned":false},{"id":4,"nickname":"bob-1","isOnline":true,"lastReadMessageId":0,"unreadCount":0,"isAdmin":false,"isBanned":false}]}
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

`./dev.sh live --admin` runs `dev/admin-proof.sh` (also part of `--all`) with two headless
clients: A becomes an admin with `make-admin.sql` and makes B an admin, and B must print
`account_updated` `"isAdmin":true` and report it in `status` without reconnecting; A renames B
with a lock and B's `reconnect` must sign in under the new name; A kicks B (`session_ended`
`kicked`, no reconnect by itself, then `reconnect` works); A bans B (`session_ended` `banned`,
B's `reconnect` gets `connect_failed` `Banned`) and unbans it; A creates a room for text and
voice, B joins its voice, A makes it text-only, and B must print `voice_left` and have its next
`voice-join` refused, both with "voice is disabled in this room".

`./dev.sh live --access` runs `dev/room-access-proof.sh` (also part of `--all`, after the GUI
proof) with three headless clients: admin A creates an Admin invite room and adds B, and C (not
a member) does not list it and is refused its history and its members, while B's add of C is
refused; in a Member invite room with From join history B invites C, who reads B's later message
but not A's earlier one, and B cannot remove C; in a Full history room C reads A's earlier
message; B leaves the Admin invite room and C cannot leave `#general`; A removes C, who is then
refused the history; and A creates an Admin invite room with `no-join`, finds it only in
`admin-rooms`, adds B, lists its members, is refused its history, makes it Public (C is added
and reads the whole history) and deletes it.

`./dev.sh live --all` runs it after the live client tests. Step 2 relies on Public rooms: a new
account joins every Public room, and the server creates `#general` (room 1) on an empty
database before it reports readiness, which `dev/live-proof.sh` checks before any client
connects. If the sender is not a member of room 1 the server answers with
`protocol_error "Not a room member"` and step 2 fails with a `[two-client]` message.

### Step Timeouts

`dev/live-proof.sh` runs every step under `timeout`, so a hung client, proof script or test
binary (such as an SQL test runner that does not exit after a failed assertion) fails the run
within minutes instead of using up CI's two-hour job limit. A step that runs out prints
`[live] STEP timed out after N s` and the run fails with its status. The limits are several
times a normal run, the compile included:

| Step | Limit |
| --- | --- |
| Live client tests (startup auth, room chat, direct message, in-process voice) | 20 min |
| `dev/harness-smoke.sh`, `dev/admin-proof.sh`, `dev/room-access-proof.sh` | 10 min each |
| `dev/voice-proof.sh`, `dev/ui-smoke.sh` | 15 min each |
| `dev/e2ee-proof.sh` | 20 min |
| Server SQL proof (`HAYCHAT_DATABASE_SQL_TEST=1 odin test server`) | 20 min |
| Failed startup exit check | 1 min |

`HAYCHAT_LIVE_STEP_TIMEOUT_SECS` replaces every limit, for a slow machine or a short limit while
debugging. `timeout` signals the step's whole process group (the clients a proof started
included) and kills what is left 30 seconds later.

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
| `--name`, `--server`, `--config-dir` | Exactly as in headless mode (the same parser). Without a name or server the window opens the first-run screen, which a script can fill in. `--headless` and `--connect-timeout` are refused. |
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
| `wait-count N "TEXT" [TIMEOUT_MS]` | Waits until TEXT is drawn at least N times, N from 1 to 1000 (e.g. a user under both Direct Messages and Members). |
| `wait-gone "TEXT" [TIMEOUT_MS]` | Waits until TEXT is no longer drawn (e.g. `wait-gone "Join voice"` after a room became text-only). |
| `assert-text "TEXT"` | Fails unless TEXT is drawn in the current frame. |
| `click "TEXT"` | Clicks the centre of the most recently drawn TEXT that lies on a widget (button, sidebar row, rail button, input placeholder), or else the most recent TEXT anywhere. A sidebar row therefore wins over a header repeating its label. |
| `click-id NAME [INT...]` | Clicks the widget whose ID is `ui.idOf(NAME, INT...)`, the same name and values the view passes (up to 4 integers), e.g. `click-id dm-input 1 7` for the DM composer with user 7 on server 1, or `click-id room-input 1 1`. |
| `click X Y` | Clicks at window coordinates. |
| `right-click "TEXT"`, `right-click-id NAME [INT...]`, `right-click X Y` | The same lookups as `click`, `click-id` and `click X Y`, with the right mouse button: this opens a context menu (see [Context Menus](#context-menus)). |
| `scroll X Y N` | Moves the pointer to window coordinates X Y and turns the wheel N notches (-100 to 100; positive scrolls the content down), for widgets below the fold of a scrolling screen. |
| `type "TEXT"` | Delivers TEXT as one `SDL_EVENT_TEXT_INPUT` to the focused text field (click the field first). |
| `key NAME` | Presses and releases a key. Names (any case): `Return`, `Enter`, `Escape`, `Tab`, `Backspace`, `Delete`, `Space`, `Up`, `Down`, `Left`, `Right`, `Home`, `End`, `PageUp`, `PageDown`, `A`, `C`, `V`, `X`, with optional `Shift+`, `Ctrl+`, `Alt+`, `Gui+`/`Cmd+` prefixes, e.g. `Shift+Return`, `Ctrl+A`. |
| `screenshot FILE.bmp` | Writes the next frame to FILE as a BMP (SDL has no PNG writer). Convert with `magick FILE.bmp FILE.png`. |
| `quit` | Ends the script and closes the window. Reaching the end of the file does the same. |

After every click and right-click command (by text, ID or coordinates), `scroll`, `type` and
`key` the next command waits until two more frames are drawn, so the input has been handled
and its effects are on screen. Waits re-check every frame and at least every 10 ms.

### Context Menus

A right-click on a channel, a Direct Messages or Members row, a voice participant, a message or
a sender name in a transcript, a server's rail button, or any text field opens its context menu
at the pointer (`client/context_menu.odin` lists the entries). The menu's labels are drawn
through the automation hook, so `click "Copy message"` picks an entry, and every entry also has
a stable widget ID, `ui.idOf("menu-item", ACTION)`, with ACTION the entry's
`ContextMenuAction` value. A transcript reports the right-clicked unit only when the press is
on a unit's text line, so `right-click "TEXT"` with a message's full text (or a sender name)
is the reliable way to reach it. While a menu is open, the pointer and the wheel do not reach
what is under it, keys go to the menu (`key Down`, `key Up`, `key Return`, `key Escape`), and a
left click outside it only closes it. Text field entries (Cut, Copy, Paste, Select all) apply
on the field's next frame, and the clipboard is SDL's, which works on the `offscreen` driver
within the process.

A voice participant's menu (not your own) holds **Mute for me** / **Unmute for me** and a
volume slider labelled "Volume: N %" (0 to 200 %), whose widget ID is
`ui.idOf("menu-slider", ACTION)` with the `Volume` action's value; moving it keeps the menu
open. For an admin, the Direct Messages, Members, voice participant and sender name menus end
with **Rename…**, **Make admin** / **Remove admin**, **Kick…** and **Ban…** / **Unban**,
disabled where the server would refuse them (yourself, another admin, a banned account).
**Rename…**, **Kick…** and **Ban…** open Server settings → Admin with that account's
confirmation already open and scrolled into view (see [Admin Screens](#admin-screens)); the
others send at once. A server's rail button menu starts with **Server settings**.

```text
right-click "hello from bob"
wait-text "Copy message"
click "Copy message"
right-click "Message #general (Enter to send, Shift+Enter for newline)"
click "Paste"
key Return
```

### Admin Screens

Server settings (`click-id server-settings SERVER` or the rail menu's **Server settings**;
`click-id server-settings-close SERVER` closes it) has a Voice section that lists every other
account on the server with its volume slider, `server-voice-volume SERVER USER`, and its
**Mute for me** / **Muted for me** button, `server-voice-mute SERVER USER`: the same local
setting as the harness's `voice-volume` and `voice-mute-user`. It shows an Admin section to
admins, below Voice. Its widget IDs take the server ID and then the user or room ID:

| Widget | Meaning |
| --- | --- |
| `admin-member-rename`, `admin-member-role`, `admin-member-kick`, `admin-member-ban` | A member's Rename…, Make admin / Remove admin, Kick… and Ban… / Unban. A disabled one draws no widget (its tooltip says why), so `click-id` on it fails. |
| `admin-confirm-text`, `admin-confirm-lock`, `admin-confirm`, `admin-confirm-cancel` | The open confirmation under that member: its field (the new name, or the reason), Lock name (rename only, on by default), and the Rename / Kick / Ban and Cancel buttons. |
| `admin-room-members`, `admin-room-edit`, `admin-room-delete` | A room's Members… (its Members page), Edit… (the room form) and Delete… (the room form with **Confirm delete** armed). The list holds every room on the server (`ClientAdminListRooms`, protocol 15), also those the admin is not in. |
| `admin-room-create` | Create room… (server ID only). |

The server's answer to the last request ("Waiting for the server…", its sentence, or its
refusal) is drawn under the row of the account it concerns (for example "Banned bob"), or
under the section's note when that account is not listed. The room form's type selector is
`click-id room-type N`, N the protocol's type number (1 text, 2 voice, 3 text and voice); its
access selector `click-id room-access N` (1 Public, 2 Member invite, 3 Admin invite), its
history selector `click-id room-history N` (1 From join, 2 Full; Create only), **Join this
room** `click-id room-editor-join`, and in an edit **Members…** `click-id room-editor-members`.
A room's Members page (from **Members…**) has `room-members-add` and `room-members-remove`
(server, room and user ID), `room-members-leave`, `room-members-edit` and `room-members-close`
(server and room ID). A
voice-only room shows "This room is voice only" where the composer would be, and a text-only
room has no **Join voice**. When an admin locked your name, Server settings shows it under
"Name on this server" with "Set by an admin of this server." instead of the field.

```text
right-click-id dm-member 1 7
click "Ban…"
wait-text "Ban bob"
click-id admin-confirm-text 1 7
type "spam"
click-id admin-confirm 1 7
wait-text "Banned bob"
click-id admin-member-ban 1 7
wait-text "Unbanned bob"
```

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
| 1 | Usage error: bad options, an unreadable script, a parse error, a profile whose config and identity key could not be loaded or created, or SDL could not start. |
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
she opens the server's settings from the sidebar header (`click-id server-settings 1`), mutes
bob for herself in the Voice section and unmutes him again, and closes them; she clicks
**+ New room**, types a name, clicks **Create**, and waits until the room is drawn;
bob must receive `room_membership` and list the room. Then, on SDL's dummy audio driver, she
clicks **Join voice**, waits for "Voice connected", mutes, opens Settings → Voice, and leaves
again, while bob must see her join, mute and leave in `voice_participants`. Last come the
context menus: she right-clicks her `#general` message, clicks **Copy message**, right-clicks
the empty composer, clicks **Paste** and sends it again (bob must receive it a second time);
then bob posts in her new room, which she is not viewing, and once its unread badge is drawn
she right-clicks the channel and clicks **Mark as read**: a second headless session of her
account (a copy of her profile, so the two never write one key store) must get the room's `read_marker` with `unreadCount` 0. Then the admin
steps (plan P4): alice right-clicks bob in Members and clicks **Make admin**, and bob's harness
must print `account_updated` with `"isAdmin":true` without reconnecting; she removes the role
again (another admin cannot be banned), clicks **Ban…** in his menu, types a reason into the
confirmation that opens in Server settings → Admin and confirms, and bob must get
`session_ended` `banned` with that reason. She unbans him with the section's **Unban**, bob's
`reconnect` signs in again, and he joins `#general`'s voice; alice right-clicks his voice row,
which holds the volume slider, and mutes him for herself. Last, she edits her room to voice
only in the room form ("This room is voice only" replaces the composer) and then to text only:
**Join voice** disappears from its header and its menu, and bob's `rooms` must list it with
`"roomType":1`. She opens Server settings from the rail button's menu and scrolls to the
Admin section's rooms list. Then the access modes (protocol 15): she creates an Admin invite
room from the form (`room-access 3`), invites bob from his member menu (**Invite to room…** →
**Invite to #room**, "Added bob to #room." under the composer), and opens the room's Members
page from its channel menu, which offers **Leave room**; bob must get `room_membership` for it
and list it with `"access":3`. Last, the encryption keys (protocol 16): she opens bob's **Verify
encryption…** dialog from his member menu, waits for "Not verified yet." (his key arrived and
the safety number is drawn), clicks **Mark as verified** (`verify-mark 1 BOB`) and closes it
(`verify-close 1 BOB`); her key store file must then hold bob verified. Bob's direct message
and her reply are end-to-end encrypted (protocol 17), so her pane shows the 🔒 badge; last she
opens the conversation with headless dave, whose key bundle SQL removed, sees the banner saying
he has not set up encryption, turns on **Send without encryption** (`dm-fallback-switch 1
DAVE`), accepts the confirmation (**Turn on**), sees "Unencrypted: the server can read this",
and sends with **Send unencrypted**: her message shows **Unencrypted**, and dave must receive it
with `"encrypted":false,"signed":true`. Last, the encrypted rooms (protocol 18): she opens the
room form, picks Admin invite, sees **Encrypt this room: on** with herself checked as a
manager, and creates the room; its Members page opens with her as member and manager and the
Managers section, and SQL must find the room encrypted at log version 1. Then (protocol 19) she
sends a message in it: the header shows "🔒 # room", the message carries the 🔒 badge, and SQL
must find one sealed row without its text. alice takes 38 screenshots on the way (`01-…` to
`37-…` and `06b-server-settings.bmp`); the script prints the paths of the 37 numbered
`NN-*.bmp` ones and checks that all 37 exist. They stay in `HAYCHAT_UI_SCREENSHOT_DIR` when set and
otherwise in a new temporary directory, which disappears with the container under `./dev.sh`; set
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
