# Headless Client Harness

`client --headless` runs the HayChat client without a window, so an AI agent or a shell
script can act as a user. It is the normal client binary: it uses the same `State`, actions,
encrypted transport, and network worker as the GUI, and only skips SDL. Commands go in on
stdin, one per line; results and events come out on stdout, one JSON object per line.
Diagnostics (config notes, connection errors) go to stderr, so stdout is always a clean
stream of JSON lines.

The code lives in `client/headless.odin`; its unit tests are in `client/headless_test.odin`.

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
the server binds a nickname to the first key that uses it. Reuse the directory to come back as
the same user; use a new directory and a new name for a new user. Two clients with the same name
and different directories cannot both log in (`user identity is unavailable`). Give every
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
| `status` | `connection` (`connecting`, `connected`, `retrying`, `failed`, or `none` without a server), `connected` (true when signed in), `retryInMS` (time until the next attempt while `retrying`), `serverID`, `server` (`host:port`), `userID`, `nickname`, `selectedRoomID`, `lastError` (the last raw failure or disconnect reason) |
| `reconnect` | Connects the selected server again now: drops any session in progress, skips the remaining retry delay, and also restarts after a failure that stopped retrying. The outcome arrives as `connecting` and then `connected` or `connect_failed` events. |
| `rooms` | The joined rooms from the cache: `loaded`, `loading`, `rooms`. When the list is not loaded yet it is requested and arrives as a `room_list` event. |
| `history ROOM_ID [BEFORE_MESSAGE_ID]` | Requests one page of history (newest first page with no cursor, older pages with the oldest loaded message ID). The page arrives as a `room_history` event. |
| `send ROOM_ID TEXT...` | Sends the rest of the line to the room, through the same action as the GUI composer. `ok` means the transport accepted it; the message itself comes back as a `room_chat` event, and a rejection as a `protocol_error` event. |
| `users` | The server's accounts from the cache, yourself included: `loaded`, `loading`, `users` (`[{"id","nickname","isOnline"}]`, ordered by nickname). The list is fetched when the client connects and kept current by `presence` events; when it is not loaded yet it is requested and arrives as a `user_list` event. |
| `conversations` | Your direct conversations from the cache, most recent first: `loaded`, `loading`, `conversations` (same shape as the `conversations` event). Fetched at connect; a live `direct_message` moves its conversation to the top. Requested when not loaded yet. |
| `dm USER_ID TEXT...` | Sends the rest of the line as a direct message to that account, through the same action as the GUI's direct-message composer. `ok` means the transport accepted it; the stored message comes back as a `direct_message` event to every session of both users (the sender's included), and a rejection as a `protocol_error` event (`Unknown direct message recipient`, `Cannot send a direct message to yourself`, `Invalid direct message`). |
| `dm-history USER_ID [BEFORE_MESSAGE_ID]` | Requests one page (up to 50 messages, both directions) of the conversation with that account: the newest page with no cursor, older pages with the oldest loaded message ID. It arrives as a `direct_history` event. |
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
| `connected` | `{"event":"connected","serverID":1,"userID":3,"nickname":"alice-1"}` |
| `connect_failed` | `{"event":"connect_failed","serverID":1,"message":"timed out connecting to the server","detail":"timed out connecting to the server","failure":"Unreachable","retryable":true,"retryInMS":2000}` |
| `room_list` | `{"event":"room_list","serverID":1,"rooms":[{"id":1,"name":"general","description":"..."}]}` |
| `room_chat` | `{"event":"room_chat","serverID":1,"roomID":1,"messageID":12,"senderID":3,"senderNickname":"alice","timestamp":"...","content":"hi"}` |
| `room_history` | `{"event":"room_history","serverID":1,"roomID":1,"hasOlder":false,"messages":[{"id":12,"senderID":3,"senderNickname":"alice","timestamp":"...","content":"hi"}]}` |
| `room_membership` | `{"event":"room_membership","serverID":1,"roomID":2,"joined":true}` |
| `room_edited` | `{"event":"room_edited","serverID":1,"roomID":2,"name":"...","description":"..."}` |
| `room_deleted` | `{"event":"room_deleted","serverID":1,"roomID":2}` |
| `protocol_error` | `{"event":"protocol_error","serverID":1,"message":"..."}` |
| `disconnected` | `{"event":"disconnected","serverID":1,"message":"connection lost","retryInMS":900}` |
| `direct_message` | `{"event":"direct_message","serverID":1,"id":7,"senderID":3,"senderNickname":"alice","recipientID":4,"recipientNickname":"bob","timestamp":"...","content":"hi"}` |
| `direct_history` | `{"event":"direct_history","serverID":1,"peerUserID":4,"hasOlder":false,"messages":[{"id":7,"senderID":3,"senderNickname":"alice","recipientID":4,"recipientNickname":"bob","timestamp":"...","content":"hi"}]}` |
| `user_list` | `{"event":"user_list","serverID":1,"users":[{"id":3,"nickname":"alice","isOnline":true}]}` |
| `conversations` | `{"event":"conversations","serverID":1,"conversations":[{"peerUserID":4,"peerNickname":"bob","lastMessageID":7,"lastSenderID":3,"lastTimestamp":"...","lastContent":"hi"}]}` |
| `presence` | `{"event":"presence","serverID":1,"userID":4,"nickname":"bob","isOnline":true}` |

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
Direct messages belong to one server: user IDs from different servers are unrelated.

## Example: Two Agents Chatting

Each agent runs its own client with its own profile. Alice's side (`>` is stdin, `<` stdout):

```text
< {"event":"connecting","serverID":1,"attempt":1}
< {"event":"connected","serverID":1,"userID":3,"nickname":"alice-1"}
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

`./dev.sh live --all` runs it after the live client tests. Step 2 relies on open rooms: a new
account joins every existing room, and `dev/live-proof.sh` loads the `#general` fixture before
any client connects. If the sender is not a member of room 1 the server answers with
`protocol_error "Not a room member"` and step 2 fails with a `[two-client]` message.
