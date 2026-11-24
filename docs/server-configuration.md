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

Paths are resolved relative to the server's working directory. `HAYCHAT_FILE_STORAGE_PATH` is
the server's state directory: the server must be able to write to it at startup, and it holds
the default identity file. Nothing else is written there; attachment files go to
`HAYCHAT_ATTACHMENT_DIR` (see [Attachments](#attachments)).

### Runtime

| Variable | Default | Purpose |
| --- | --- | --- |
| `HAYCHAT_LOG_LEVEL` | `info` | Log level |
| `HAYCHAT_MAX_RESTARTS` | `5` | How many times the supervisor restarts a failed service thread before giving up |
| `HAYCHAT_RESTART_BACKOFF_MIN` | `0.1` | Shortest wait before a restart, in seconds |
| `HAYCHAT_RESTART_BACKOFF_MAX` | `10.0` | Longest wait before a restart, in seconds |
| `HAYCHAT_MAX_NETWORK_THREADS` | `4` | ENet peer capacity, 16 connections per unit (64 by default). It no longer starts threads; the name is historical |
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

### Attachments

Attachment files (protocols 26-28) are uploaded and downloaded over the same UDP port (ENet
channel 5). Their metadata is in PostgreSQL (the `attachments` table, migration 14); the files
are in `HAYCHAT_ATTACHMENT_DIR`, written by the server's storage worker thread as
`incoming/<hex>.part` while an upload runs and `blobs/<2 hex>/<hex>` once it is complete, with
mode 0600 for files and 0700 for directories. Back the directory up together with the database
([deploy/README.md "Backups"](../deploy/README.md#backups)). Out-of-range values are clamped to
the range; a value that does not parse uses the default. Byte values are plain numbers of bytes.

| Variable | Default | Purpose |
| --- | --- | --- |
| `HAYCHAT_ATTACHMENTS_ENABLED` | `true` | `false` refuses every new upload with "Attachments are disabled on this server". Stored files stay downloadable |
| `HAYCHAT_ATTACHMENT_DIR` | `./attachments` | The blob directory. Startup creates it (and `incoming/`, `blobs/`) and fails with `[Startup]` when it is `HAYCHAT_FILE_STORAGE_PATH`, contains the server identity file, or is not writable. The server image uses `/var/lib/haychat/attachments`, the `haychat-attachments` volume |
| `HAYCHAT_ATTACHMENT_MAX_BYTES` | `26214400` (25 MiB; 1 KiB to 4 GiB) | The largest file a client may upload, in stored bytes (in encrypted conversations the ciphertext with its padding and tags); larger ones are refused with "Attachment is too large". Clients learn it at sign-in and refuse such a file before uploading |
| `HAYCHAT_ATTACHMENT_ACCOUNT_QUOTA_BYTES` | `1073741824` (1 GiB; 0 = none, at most 1 TiB) | Bytes one account may have stored (removed files do not count; uploads in progress count with their declared size, which they reserve when they begin, so concurrent uploads cannot overshoot it); beyond it "Attachment storage quota exceeded". Clients learn it at sign-in |
| `HAYCHAT_ATTACHMENT_UPLOAD_BYTES_PER_HOUR` | `536870912` (512 MiB; 0 = none, at most 1 TiB) | Bytes one account may begin uploading in any hour, cancelled, failed and removed uploads included; beyond it "Attachment upload limit reached; try again later" |
| `HAYCHAT_ATTACHMENT_CAPACITY_BYTES` | `0` (none; at most 1 PiB) | Bytes the server stores for every account together; beyond it "Server storage is full". Admins see it in Server settings → Storage |
| `HAYCHAT_ATTACHMENT_MIN_FREE_BYTES` | `1073741824` (1 GiB; 0 to 1 TiB) | Free space the blob directory's volume must keep after an upload; an upload that would go below it is refused with "Server storage is full" |
| `HAYCHAT_ATTACHMENT_PENDING_HOURS` | `24` (1 to 720) | An upload that was never sent with a message is deleted this many hours after it began |
| `HAYCHAT_ATTACHMENT_SESSION_BYTES_PER_SECOND` | `4194304` (4 MiB/s; 64 KiB/s to 1 GiB/s) | Each connection's transfer pace, uploads and downloads together, so file chunks never crowd out chat |
| `HAYCHAT_ATTACHMENT_ALLOW_ORPHAN_PURGE` | `false` | One start's leave for the startup scan to delete files without a row past its guards (below). It is read only at startup, so set it for the one start that should delete them and remove it again; left set, it disables the guards on every later start |

The sweeper runs at startup and then hourly. It deletes uploads that received no chunk for an
hour, uploads and unbound files older than `HAYCHAT_ATTACHMENT_PENDING_HOURS`, files whose
message is gone (a deleted room, for example), and cancelled uploads, but never a row younger
than an hour or a file being transferred. It deletes the rows first and then the files, and
logs `[Attachments] Swept N attachment rows`. At startup the server also deletes every file in
the blob directory that is older than an hour and has no row (or whose row is a removed file),
logging each one and `[Attachments] Deleted N orphan attachment files`; this is why a restore
must load the database before the blob directory ([deploy/README.md
"Restoring"](../deploy/README.md#restoring)). Two guards keep a wrong restore order from
deleting a backup's files (#131); either keeps **every** such file, deletes nothing, and logs a
`[Attachments] Warning: ...` line with the counts that names `deploy/README.md (Restoring)` and
the override:

- The `attachments` table has no row at all while the scan found files (in `blobs/`, or
  `incoming/*.part`): even a single file stays.
- More than 10% of the files the scan found have no row, and more than 10 of them (the share
  and the floor are `ATTACHMENT_ORPHAN_PURGE_MAX_SHARE_PERCENT` and
  `ATTACHMENT_ORPHAN_PURGE_FLOOR` in `server/router_attachments.odin`). Up to 10 orphans are
  always deleted, so a stray file in a small directory still goes.

The scan counts only files older than an hour, and not the files of rows the startup sweep
deletes meanwhile (they go with their rows). `HAYCHAT_ATTACHMENT_ALLOW_ORPHAN_PURGE=1` lifts
both guards for that start, logging `[Attachments] HAYCHAT_ATTACHMENT_ALLOW_ORPHAN_PURGE is
set: deleting N orphan files of M past the guards` when a guard would have kept them. The
`[Status]` line counts kept orphans as `attachment_orphans_kept`.

Hourly and at startup the server also deletes the files of the newest 1000 removed files that
are still on a message again, which is how a removal made with
`deploy/sql/remove-attachment.sql` leaves the disk. An upload whose client process ended is
never resumed (the client uploads the file again as a new blob), so its part file goes with the
stalled uploads. The sweeper and this pass delete only by rows, so the guards do not apply to
them.

A download that finds a file missing from the blob directory marks its row removed, as an admin
removal would, with the reason "File missing from storage" in the removal log (#132; the server
is not a backup of its files). No variable controls it. The server marks nothing while `blobs/`
is missing, unreadable or empty, or the file's shard directory is missing, and at most 10 files
an hour; each case logs an `[Attachments] WARNING: ...` line naming `HAYCHAT_ATTACHMENT_DIR`
([protocol.md](protocol.md), Missing files).

### Retired Variables

The server no longer reads these. When one is set, startup prints `[Startup] NAME is no longer
used and is ignored (#31)` and carries on.

| Variable | Removed |
| --- | --- |
| `HAYCHAT_MAX_FILE_SIZE`, `HAYCHAT_MAX_STORAGE_CAPACITY` | #31: they limited the `ClientStoreFile` upload endpoint, which no client used and nothing could read back. It was removed. Attachments (protocol 26, #118) are limited by `HAYCHAT_ATTACHMENT_MAX_BYTES` and `HAYCHAT_ATTACHMENT_CAPACITY_BYTES` instead (see [Attachments](#attachments)); the old names are not reused |

## Registration Mode

Who may sign up is not an environment variable: it is stored in the database
(`server_settings.registration_mode`, protocol 25) so admins can change it live from the
client. A new or upgraded server is **Open**. Two SQL helpers change things without a client
(see [deploy/README.md](../deploy/README.md#first-time-setup)):

- `deploy/sql/set-registration-mode.sql` (`psql -v mode=open|invite|approval -f ...`) sets the
  mode; new sign-ins follow it at once.
- `deploy/sql/create-invite.sql` (`psql -v uses=1 -v days=7 -v note=... -f ...`) prints a new
  invite code, for an operator who has no admin account yet. Only its sha256 is stored.

`HAYCHAT_ADMIN_PUBLIC_KEY` can always sign up, whatever the mode. What each mode, invite codes
and restricted accounts mean is in
[rooms-and-accounts.md](rooms-and-accounts.md#registration); how sign-up looks in the client is
in the [user guide](user-guide.md#signing-up).

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
| 14 | Attachments (protocol 26): the `attachments` table (one row per uploaded file: its owner, room or direct conversation, state, size, hash and, once attachments go on messages, its message); it starts empty |

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
- The `*_running` and `*_restart_pending` pairs are the supervisor's view of the network,
  database and (protocol 26) storage service threads.
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
- Attachments (protocol 26): `attachment_uploads` and `attachment_downloads` count transfers in
  progress; `attachment_bytes_in` and `attachment_bytes_out` the file bytes received and sent
  since startup; `attachment_crypto_ms` the main thread's time sealing and opening channel 5
  packets; `attachment_blobs_swept` and `attachment_orphans` what the sweeper and the startup
  scan removed, and `attachment_orphans_kept` the files without a row the startup scan's guards
  kept ([Attachments](#attachments)).

The frame counters start over when the network service restarts. In the dev pod, read the latest
line with `./dev.sh logs | grep -F '[Status]' | tail -n 1`; in production, see [deploy/README.md
"Server Status"](../deploy/README.md#server-status).
