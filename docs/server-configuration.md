# Server Configuration

The server reads its configuration from `HAYCHAT_*` environment variables. Where to set them
depends on how it runs:

- **Dev pod** (`./dev.sh up`): `./dev.sh` sets the database, listen, and path settings itself.
  Every other key can be set in `.env` (`cp .env.example .env`), which `./dev.sh up` and
  `./dev.sh restart` pass to the server. See [development.md](development.md).
- **Production** (the server image under quadlet or podman): the image and units set some keys,
  and the rest go in `server.env`. See [deploy/README.md "Environment
  Variables"](../deploy/README.md#environment-variables).
- **Directly** (`odin run server`, or the release binary): the same keys from the process
  environment.

## Variables

### Database

| Variable | Default |
| --- | --- |
| `HAYCHAT_DATABASE_URL` | `localhost` |
| `HAYCHAT_DATABASE_PORT` | `5432` |
| `HAYCHAT_DATABASE_USER` | `haychat` |
| `HAYCHAT_DATABASE_PASS` | `haychat` |
| `HAYCHAT_DATABASE_NAME` | `haychat` |

The role must be able to create and alter objects in its schema (`public`), because the server
migrates the schema itself (see [Schema Migrations](#schema-migrations)).

### Network and Paths

| Variable | Default |
| --- | --- |
| `HAYCHAT_LISTEN_ADDR` | `0.0.0.0` |
| `HAYCHAT_LISTEN_PORT` | `12345` (UDP; chat and voice share it) |
| `HAYCHAT_LOG_DIR` | `./logs` |
| `HAYCHAT_FILE_STORAGE_PATH` | `./storage` |
| `HAYCHAT_SERVER_IDENTITY_FILE` | `$HAYCHAT_FILE_STORAGE_PATH/server_identity.json` |

Paths are resolved relative to the server's working directory.

### Runtime

| Variable | Default | Purpose |
| --- | --- | --- |
| `HAYCHAT_LOG_LEVEL` | `info` | Log level |
| `HAYCHAT_MAX_RESTARTS` | `5` | How many times the supervisor restarts a failed service thread before giving up |
| `HAYCHAT_RESTART_BACKOFF_MIN` | `0.1` | Shortest wait before a restart, in seconds |
| `HAYCHAT_RESTART_BACKOFF_MAX` | `10.0` | Longest wait before a restart, in seconds |
| `HAYCHAT_MAX_NETWORK_THREADS` | `4` | ENet peer capacity, 16 connections per unit (64 by default). It no longer starts threads; the name is historical |
| `HAYCHAT_MAX_FILE_SIZE` | `10485760` | Bytes |
| `HAYCHAT_MAX_STORAGE_CAPACITY` | `1073741824` | Bytes |
| `HAYCHAT_SERVER_PRIVATE_KEY`, `HAYCHAT_SERVER_PUBLIC_KEY` | unset | A fixed server identity (hex). When both are unset, the server loads or generates `HAYCHAT_SERVER_IDENTITY_FILE` |
| `HAYCHAT_ADMIN_PUBLIC_KEY` | unset | Hex Ed25519 client public key allowed to claim keyless accounts that hold server roles, such as the seeded `admin`. Without it, those accounts cannot be claimed over the network. Ordinary keyless accounts are still bound to the first key that connects with their nickname (on an Open server). Since protocol 25 this key may also always sign up, in every registration mode, unrestricted and without approval. `./dev.sh key [PROFILE]` prints a dev client profile's key |

### Voice

Voice rides the same UDP port as chat (`HAYCHAT_LISTEN_PORT`, ENet channel 2), so it needs no
extra port or firewall rule. The server relays each voice frame to the room's other participants
on its network thread and never stores or logs audio. Out-of-range values are clamped to the
range; a value that does not parse uses the default.

| Variable | Default | Purpose |
| --- | --- | --- |
| `HAYCHAT_VOICE_ENABLED` | `true` | `false` (or `0`, `no`, `off`) turns voice off server-wide; every join is refused with "voice is disabled" |
| `HAYCHAT_VOICE_MAX_PARTICIPANTS` | `25` (1 to 200) | Voice sessions per room. An account has one voice session, so a user joining from a second device takes the first device's place. A join into a full room is refused with "voice room is full" |
| `HAYCHAT_VOICE_MAX_PACKETS_PER_SECOND` | `60` (1 to 1000) | Per-connection rate limit for voice datagrams, as a token bucket with a burst of a third of the rate. A client sends 50 per second while talking, so values below 50 cut speech up |
| `HAYCHAT_VOICE_MAX_FRAME_BYTES` | `512` (64 to 512) | The largest Opus payload the server forwards; 512 is the wire format's limit. A 24 kbit/s voice frame is about 60 bytes. In an encrypted room it counts the Opus bytes inside the sealed payload, without its 18 bytes of overhead |

## Registration Mode

Who may sign up is not an environment variable: it is stored in the database
(`server_settings.registration_mode`, protocol 25) so admins can change it live from the
client. A new or upgraded server is **Open**. Two SQL helpers change things without a client
(see [deploy/README.md](../deploy/README.md#first-time-setup)):

- `deploy/sql/set-registration-mode.sql` (`psql -v mode=open|invite|approval -f ...`) sets the
  mode; new sign-ins follow it at once.
- `deploy/sql/create-invite.sql` (`psql -v uses=1 -v days=7 -v note=... -f ...`) prints a new
  invite code, for an operator who has no admin account yet. Only its sha256 is stored.

`HAYCHAT_ADMIN_PUBLIC_KEY` can always sign up, whatever the mode.

## Startup and Exit Status

When startup fails (invalid configuration, an unreachable or incompatible database, or a service
thread that cannot start), the server prints a line starting with `[Startup]` and exits with
status 1. A clean shutdown (SIGINT) exits 0. A service manager's `Restart=on-failure` and scripts
can therefore tell the two apart. The server logs `=== Server Running ===` once it is ready.

## Schema Migrations

The server owns its schema and migrates it at startup, before it reports readiness. The
migrations (`DATABASE_MIGRATIONS` in `server/database_migrations.odin`) are numbered, applied in
order inside one transaction under an advisory lock (so two servers never migrate one database at
once), and recorded in the `schema_migrations` table.

| Migration | Contents |
| --- | --- |
| 1 | The v0.1.0-rc1 schema (baseline) |
| 2 | Read markers behind unread counts (protocol 11) |
| 3 | The name lock and ban columns of `users` and the room type of `rooms` (protocol 14); existing accounts stay unlocked and unbanned, existing rooms become text and voice |
| 13 | Registration (protocol 25): `server_settings` (the registration mode, migrated as Open), `invites`, `invite_roles`, `registration_requests`, and `users.restricted`/`invite_id`; existing accounts stay unrestricted |

- An empty database gets every migration.
- A database created before migrations existed (v0.1.0-rc1 and earlier dev databases) is adopted
  as version 1 with every row kept.
- An older version gets the missing migrations.
- The server never drops data. A database whose recorded version is newer than the server knows
  (a downgrade), or whose tables it does not recognise, stops startup with a `[Startup]` error and
  exit status 1 and is left exactly as it was. [deploy/README.md
  "Upgrades"](../deploy/README.md#upgrades) covers restoring a backup and resetting a throwaway
  database.

After migrating, a server whose `rooms` table is empty creates `#general` (see
[rooms-and-accounts.md](rooms-and-accounts.md#rooms)). `server/sql/auth_bootstrap.sql` is a
test-data fixture only and is not used by normal startup.

## Status Log

The server has no admin port or HTTP endpoint. Every five minutes
(`SERVER_STATUS_LOG_INTERVAL` in `server/status.odin`), and once when it shuts down, the main
thread logs one line of space-separated `key=value` pairs, for example:

```text
[Status] uptime=300 connected_peers=2 network_running=true database_running=true network_restart_pending=false database_restart_pending=false shutdown_requested=false voice_rooms=1 voice_participants=2 voice_frames_in=15000 voice_frames_relayed=14990 voice_frames_out=14990 voice_send_failures=0 voice_drops_unknown_peer=0 ...
```

- `uptime` is in seconds.
- The `*_running` and `*_restart_pending` pairs are the supervisor's view of the network and
  database service threads.
- `voice_rooms` and `voice_participants` count rooms with an active voice session and the
  sessions in them.
- `voice_frames_in` counts datagrams received on the voice channel, `voice_frames_relayed` frames
  that passed every check, `voice_frames_out` datagrams sent to recipients, and
  `voice_send_failures` failed sends.
- One `voice_drops_<reason>` pair per drop reason: `unknown_peer`, `not_in_room`,
  `rate_limited`, `malformed`, `replayed`, `too_old`, `bad_tag`, `inactive`, `malformed_frame`,
  `wrong_room`, `muted`, `oversize`, `bad_duration`, `not_sealed` (protocol 21: an encrypted
  room's frame that is not a sealed payload), `no_speak_permission` (protocol 24: the sender may
  not speak in the room). A dropped datagram never disconnects anyone.

The frame counters start over when the network service restarts. In the dev pod, read the latest
line with `./dev.sh logs | grep -F '[Status]' | tail -n 1`; in production, see [deploy/README.md
"Server Status"](../deploy/README.md#server-status).
